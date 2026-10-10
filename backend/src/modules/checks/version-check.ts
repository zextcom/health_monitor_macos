import { and, asc, desc, eq, inArray, sql } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { endpointVersionSecrets, endpointVersionState, versionHistory } from '../../db/schema.js';
import type { Endpoint, VersionCheckConfig } from '../../db/schema.js';
import { decrypt } from '../../utils/crypto.js';
import {
  notifyVersionChanged,
  notifyVersionCheckFailed,
  notifyVersionCheckRecovered,
} from '../notifications/notification.service.js';
import { buildAuthHeaders, getByPath, matchesAssertion } from './check-helpers.js';

/**
 * Optional secondary check: every N health checks, fetch JSON from `versionCheck.url`, read the
 * version at `versionFieldPath`, and evaluate `assertions`. Never affects the endpoint's own
 * health, incidents or uptime — mirrors the macOS app's `VersionStore`/`executeVersionCheck`.
 */

export const VERSION_HISTORY_LIMIT = 50;
const VERSION_HTTP_TIMEOUT_MS = 30_000;

export interface VersionCheckOutcome {
  isSuccess: boolean;
  /** Set whenever the field could be read, even if an assertion failed afterwards. */
  version: string | null;
  failureReason: string | null;
  statusCode: number | null;
  responseTimeMs: number | null;
}

export type VersionCheckEvent =
  | { type: 'changed'; from: string; to: string }
  | { type: 'failed'; reason: string }
  | { type: 'recovered' };

/** `checkCount` is 1-based: runs on the 1st, (N+1)th, (2N+1)th… check. */
export function shouldRunVersionCheck(checkCount: number, everyN: number): boolean {
  if (checkCount < 1) {
    return false;
  }
  return (checkCount - 1) % Math.max(1, Math.floor(everyN)) === 0;
}

function stringifyLeaf(value: unknown): string | null {
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  return null;
}

/** Pure evaluation of an already-fetched response: any 2xx, JSON body, readable version, assertions pass. */
export function evaluateVersionResponse(
  statusCode: number,
  bodyText: string,
  config: Pick<VersionCheckConfig, 'versionFieldPath' | 'assertions'>,
  responseTimeMs: number | null = null,
): VersionCheckOutcome {
  const failure = (reason: string, version: string | null = null): VersionCheckOutcome => ({
    isSuccess: false,
    version,
    failureReason: reason,
    statusCode,
    responseTimeMs,
  });

  if (statusCode < 200 || statusCode > 299) {
    return failure(`Expected 2xx, got ${statusCode}`);
  }

  let body: unknown;
  try {
    body = JSON.parse(bodyText);
  } catch {
    return failure('Response body is not valid JSON');
  }

  const path = config.versionFieldPath.trim();
  const version = stringifyLeaf(getByPath(body, path));
  if (version === null) {
    return failure(`Version field "${path}" not found`);
  }

  for (const assertion of config.assertions) {
    const value = getByPath(body, assertion.path);
    let matched: boolean;
    try {
      matched = matchesAssertion(value, assertion.expectedValue, assertion.matchMode);
    } catch {
      matched = false; // invalid regex never matches
    }
    if (!matched) {
      return failure(`Assertion failed: "${assertion.path}" did not match "${assertion.expectedValue}"`, version);
    }
  }

  return { isSuccess: true, version, failureReason: null, statusCode, responseTimeMs };
}

export async function performVersionCheck(
  config: VersionCheckConfig,
  secret: string | null,
): Promise<VersionCheckOutcome> {
  const controller = new AbortController();
  const timeoutHandle = setTimeout(() => controller.abort(), VERSION_HTTP_TIMEOUT_MS);
  const start = performance.now();

  try {
    const response = await fetch(config.url, {
      signal: controller.signal,
      headers: buildAuthHeaders(config, secret),
    });
    const bodyText = await response.text();
    return evaluateVersionResponse(response.status, bodyText, config, Math.round(performance.now() - start));
  } catch (error) {
    return {
      isSuccess: false,
      version: null,
      failureReason: error instanceof Error ? error.message : 'Unknown error during version check',
      statusCode: null,
      responseTimeMs: Math.round(performance.now() - start),
    };
  } finally {
    clearTimeout(timeoutHandle);
  }
}

/**
 * Pure transition logic (same rules as the macOS `VersionStore.apply`):
 * - failed/recovered only on a transition between two known results — the first result never notifies;
 * - a change is detected against the last *observed* version, not the last result, so a deploy that
 *   briefly fails and comes back on a new version still reports it; the first version is not a change.
 */
export function versionEvents(
  previousIsSuccess: boolean | null,
  lastKnownVersion: string | null,
  outcome: Pick<VersionCheckOutcome, 'isSuccess' | 'version' | 'failureReason'>,
): VersionCheckEvent[] {
  const events: VersionCheckEvent[] = [];

  if (previousIsSuccess === true && !outcome.isSuccess) {
    events.push({ type: 'failed', reason: outcome.failureReason ?? 'Version check failed' });
  } else if (previousIsSuccess === false && outcome.isSuccess) {
    events.push({ type: 'recovered' });
  }

  const observed = outcome.version?.trim();
  if (observed && lastKnownVersion !== null && observed !== lastKnownVersion) {
    events.push({ type: 'changed', from: lastKnownVersion, to: observed });
  }

  return events;
}

/**
 * Increments the endpoint's health-check counter and returns the new value. The row is created on
 * first use, so the very first health check yields 1 (and therefore runs the version check).
 */
export async function incrementVersionCheckCounter(endpointId: string): Promise<number> {
  const [row] = await db
    .insert(endpointVersionState)
    .values({ endpointId, checkCounter: 1 })
    .onConflictDoUpdate({
      target: endpointVersionState.endpointId,
      set: { checkCounter: sql`${endpointVersionState.checkCounter} + 1` },
    })
    .returning({ checkCounter: endpointVersionState.checkCounter });
  return row.checkCounter;
}

/** Called when an endpoint's version check config changes so the next health check runs it immediately. */
export async function resetVersionCheckCounter(endpointId: string): Promise<void> {
  await db
    .update(endpointVersionState)
    .set({ checkCounter: 0 })
    .where(eq(endpointVersionState.endpointId, endpointId));
}

/** Persists `outcome` (latest state + collapsed history, capped) and returns notification-worthy events. */
export async function recordVersionResult(
  endpointId: string,
  outcome: VersionCheckOutcome,
  now: Date = new Date(),
  historyLimit: number = VERSION_HISTORY_LIMIT,
): Promise<VersionCheckEvent[]> {
  return db.transaction(async (tx) => {
    const state = await tx.query.endpointVersionState.findFirst({
      where: eq(endpointVersionState.endpointId, endpointId),
    });
    const latest = await tx.query.versionHistory.findFirst({
      where: eq(versionHistory.endpointId, endpointId),
      orderBy: [desc(versionHistory.firstSeenAt)],
    });

    const events = versionEvents(state?.lastIsSuccess ?? null, latest?.value ?? null, outcome);

    const observed = outcome.version?.trim();
    if (observed) {
      if (latest && latest.value === observed) {
        await tx.update(versionHistory).set({ lastSeenAt: now }).where(eq(versionHistory.id, latest.id));
      } else {
        await tx.insert(versionHistory).values({ endpointId, value: observed, firstSeenAt: now, lastSeenAt: now });
        const overflow = await tx
          .select({ id: versionHistory.id })
          .from(versionHistory)
          .where(eq(versionHistory.endpointId, endpointId))
          .orderBy(desc(versionHistory.firstSeenAt))
          .offset(historyLimit);
        if (overflow.length > 0) {
          await tx.delete(versionHistory).where(
            and(
              eq(versionHistory.endpointId, endpointId),
              inArray(
                versionHistory.id,
                overflow.map((row) => row.id),
              ),
            ),
          );
        }
      }
    }

    const stateValues = {
      lastCheckedAt: now,
      lastIsSuccess: outcome.isSuccess,
      lastVersion: observed || (latest?.value ?? null),
      lastFailureReason: outcome.failureReason,
      lastStatusCode: outcome.statusCode,
      lastResponseTimeMs: outcome.responseTimeMs,
    };
    await tx
      .insert(endpointVersionState)
      .values({ endpointId, ...stateValues })
      .onConflictDoUpdate({ target: endpointVersionState.endpointId, set: stateValues });

    return events;
  });
}

export interface VersionHistoryResponse {
  current: {
    version: string | null;
    isFailing: boolean;
    failureReason: string | null;
    lastCheckedAt: string | null;
  } | null;
  /** Newest first. */
  history: Array<{ value: string; firstSeenAt: string; lastSeenAt: string }>;
}

export async function getVersionHistory(endpointId: string): Promise<VersionHistoryResponse> {
  const [state, rows] = await Promise.all([
    db.query.endpointVersionState.findFirst({ where: eq(endpointVersionState.endpointId, endpointId) }),
    db
      .select()
      .from(versionHistory)
      .where(eq(versionHistory.endpointId, endpointId))
      .orderBy(desc(versionHistory.firstSeenAt), asc(versionHistory.id)),
  ]);

  return {
    current:
      state && state.lastCheckedAt
        ? {
            version: state.lastVersion,
            isFailing: state.lastIsSuccess === false,
            failureReason: state.lastFailureReason,
            lastCheckedAt: state.lastCheckedAt.toISOString(),
          }
        : null,
    history: rows.map((row) => ({
      value: row.value,
      firstSeenAt: row.firstSeenAt.toISOString(),
      lastSeenAt: row.lastSeenAt.toISOString(),
    })),
  };
}

/**
 * Called by the worker after every health check of `endpoint`. Counts the check, and on every
 * `everyNChecks`-th one runs the version check, records it, and sends any resulting notifications.
 * Returns the events (for tests/logging); never throws for an unreachable version URL.
 */
export async function runVersionCheckIfDue(endpoint: Pick<Endpoint, 'id' | 'versionCheck'>): Promise<VersionCheckEvent[]> {
  const config = endpoint.versionCheck;
  if (!config || !config.isEnabled) {
    return [];
  }

  const count = await incrementVersionCheckCounter(endpoint.id);
  if (!shouldRunVersionCheck(count, config.everyNChecks)) {
    return [];
  }

  let secret: string | null = null;
  if (config.authType !== 'none') {
    const secretRow = await db.query.endpointVersionSecrets.findFirst({
      where: eq(endpointVersionSecrets.endpointId, endpoint.id),
    });
    if (secretRow) {
      secret = decrypt(secretRow.encryptedValue, secretRow.iv);
    }
  }

  const outcome = await performVersionCheck(config, secret);
  const events = await recordVersionResult(endpoint.id, outcome);

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
