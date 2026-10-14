import { eq } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { endpointHealthState } from '../../db/schema.js';
import type { Endpoint, HealthStatus, JsonAssertion } from '../../db/schema.js';
import {
  evaluateStandardResponse,
  trackedVersionValue,
  type ParsedHealthResponse,
} from '../standards/health-standard.js';
import {
  notifyEndpointDegraded,
  notifyEndpointNoLongerDegraded,
  notifyVersionChanged,
  notifyVersionCheckRecovered,
  notifyVersionCheckFailed,
} from '../notifications/notification.service.js';
import { evaluateAssertions } from './check-helpers.js';
import { recordVersionResult, type VersionCheckEvent } from './version-check.js';

/**
 * Health-standard (`zext-health/v1`) side of the check worker. Kept out of `checks.worker.ts`
 * because importing that module opens Redis connections. Same rules as the macOS app's
 * `HealthStandard`/`HealthCheckService` — see docs/health-standard-monitor.md.
 */

export interface StandardCheckEvaluation {
  isHealthy: boolean;
  healthStatus: HealthStatus | null;
  /** Down reason, or the warn reason for a degraded result. */
  failureReason: string | null;
  parsed: ParsedHealthResponse | null;
}

/** Standard evaluation plus the endpoint's JSON assertions, ANDed on top of a pass/warn body. */
export function evaluateStandardHttpCheck(
  endpoint: { jsonAssertions: JsonAssertion[] },
  statusCode: number,
  bodyText: string,
): StandardCheckEvaluation {
  const evaluation = evaluateStandardResponse(statusCode, bodyText);
  const result: StandardCheckEvaluation = {
    isHealthy: evaluation.isHealthy,
    healthStatus: evaluation.healthStatus,
    failureReason: evaluation.reason,
    parsed: evaluation.parsed,
  };
  if (evaluation.isHealthy && endpoint.jsonAssertions.length > 0) {
    const assertions = evaluateAssertions(evaluation.body, endpoint.jsonAssertions);
    if (!assertions.passed) {
      result.isHealthy = false;
      result.failureReason = assertions.reason;
    }
  }
  return result;
}

export type HealthState = 'healthy' | 'degraded' | 'down';

/** Degraded = up (for uptime/incidents) but the service reported `warn`. */
export function healthStateOf(result: { isHealthy: boolean; healthStatus: HealthStatus | null }): HealthState {
  if (!result.isHealthy) {
    return 'down';
  }
  return result.healthStatus === 'warn' ? 'degraded' : 'healthy';
}

export type DegradedEvent = 'degraded' | 'degraded_recovered';

/**
 * Degraded transitions on top of the incident-driven down/recovered notifications:
 * healthy → degraded is `degraded`, degraded → healthy is `degraded_recovered`. Down ↔ degraded is
 * left to the incident logic (degraded → down = "down", down → degraded = "recovered" with degraded
 * wording). No previous result means no transition, so the very first check never notifies here.
 */
export function degradedTransition(previous: HealthState | null, current: HealthState): DegradedEvent | null {
  if (previous === 'healthy' && current === 'degraded') {
    return 'degraded';
  }
  if (previous === 'degraded' && current === 'healthy') {
    return 'degraded_recovered';
  }
  return null;
}

export async function notifyDegradedTransition(
  endpointId: string,
  event: DegradedEvent | null,
  reason: string | null,
): Promise<void> {
  if (event === 'degraded') {
    await notifyEndpointDegraded(endpointId, reason);
  } else if (event === 'degraded_recovered') {
    await notifyEndpointNoLongerDegraded(endpointId);
  }
}

/** Overwrites the endpoint's latest parsed standard response (only the newest one is kept). */
export async function recordHealthDetails(
  endpointId: string,
  parsed: ParsedHealthResponse,
  now: Date = new Date(),
): Promise<void> {
  const values = {
    checkedAt: now,
    status: parsed.status,
    version: parsed.version,
    releaseId: parsed.releaseId,
    output: parsed.output,
  };
  await db
    .insert(endpointHealthState)
    .values({ endpointId, ...values })
    .onConflictDoUpdate({ target: endpointHealthState.endpointId, set: values });
}

export interface HealthDetails {
  status: HealthStatus;
  version: string | null;
  releaseId: string | null;
  output: string | null;
  checkedAt: string;
  /** Deprecated and always empty: components are no longer part of the standard. Kept only so clients
   * that still read `latest.components` don't break; remove once those clients are gone. */
  components: never[];
}

export function toHealthDetails(row: typeof endpointHealthState.$inferSelect): HealthDetails {
  return {
    status: row.status,
    version: row.version,
    releaseId: row.releaseId,
    output: row.output,
    checkedAt: row.checkedAt.toISOString(),
    components: [],
  };
}

export async function getHealthDetails(endpointId: string): Promise<HealthDetails | null> {
  const row = await db.query.endpointHealthState.findFirst({
    where: eq(endpointHealthState.endpointId, endpointId),
  });
  return row ? toHealthDetails(row) : null;
}

/** Auto version tracking applies only when the endpoint has no explicit, enabled version check. */
export function usesAutoVersion(endpoint: Pick<Endpoint, 'healthStandard' | 'versionCheck'>): boolean {
  return endpoint.healthStandard && endpoint.versionCheck?.isEnabled !== true;
}

/**
 * Feeds the health response's version into the existing version tracking (no extra request) and
 * sends the resulting notifications. Returns the events (for tests/logging).
 */
export async function recordAutoVersion(
  endpoint: Pick<Endpoint, 'id' | 'healthStandard' | 'versionCheck'>,
  parsed: ParsedHealthResponse | null,
  statusCode: number | null,
  responseTimeMs: number | null,
): Promise<VersionCheckEvent[]> {
  if (!usesAutoVersion(endpoint) || !parsed) {
    return [];
  }
  const value = trackedVersionValue(parsed.version, parsed.releaseId);
  if (!value) {
    return [];
  }
  const events = await recordVersionResult(endpoint.id, {
    isSuccess: true,
    version: value,
    failureReason: null,
    statusCode,
    responseTimeMs,
  });
  for (const event of events) {
    if (event.type === 'changed') {
      await notifyVersionChanged(endpoint.id, event.from, event.to);
    } else if (event.type === 'failed') {
      await notifyVersionCheckFailed(endpoint.id, event.reason);
    } else {
      await notifyVersionCheckRecovered(endpoint.id);
    }
  }
  return events;
}
