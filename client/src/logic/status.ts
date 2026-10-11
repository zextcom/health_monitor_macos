/**
 * Pure status derivation shared by every screen that shows an endpoint's state. No React Native
 * imports, so it runs under the Node test runner.
 *
 * Same semantics as the macOS app and the backend (docs/health-standard-monitor.md): a
 * health-standard `warn` is up (it counts for uptime) but degraded.
 */
import type { DashboardEndpoint, DashboardResponse, DashboardSummary } from '../api/dashboard';
import type { HealthStatus } from '../api/endpoints';

export type Status = 'healthy' | 'degraded' | 'unhealthy' | 'paused' | 'unknown';

/** The per-result states a single check can have (history dots, components). */
export type CheckState = 'healthy' | 'degraded' | 'unhealthy';

export interface StatusInput {
  isPaused: boolean;
  /** `null`/`undefined` when there's no check yet. */
  isHealthy: boolean | null | undefined;
  /** The dashboard's precomputed flag, when available. */
  isDegraded?: boolean | null;
  /** Health-standard status of the latest result, when available. */
  healthStatus?: HealthStatus | null;
}

/** Precedence: paused > down > degraded > healthy > unknown. */
export function deriveStatus(input: StatusInput): Status {
  if (input.isPaused) return 'paused';
  if (input.isHealthy === false) return 'unhealthy';
  if (input.isHealthy === true) {
    return input.isDegraded === true || input.healthStatus === 'warn' ? 'degraded' : 'healthy';
  }
  return 'unknown';
}

/** State of one check result, e.g. a history dot. A `warn` result is up but degraded. */
export function checkState(check: { isHealthy: boolean; healthStatus?: HealthStatus | null }): CheckState {
  if (!check.isHealthy) return 'unhealthy';
  return check.healthStatus === 'warn' ? 'degraded' : 'healthy';
}

/** Status of a dashboard endpoint, from its latest check. */
export function statusOfDashboardEndpoint(endpoint: Pick<DashboardEndpoint, 'isPaused' | 'latestCheck'>): Status {
  return deriveStatus({
    isPaused: endpoint.isPaused,
    isHealthy: endpoint.latestCheck?.isHealthy ?? null,
    isDegraded: endpoint.latestCheck?.isDegraded ?? null,
    healthStatus: endpoint.latestCheck?.healthStatus ?? null,
  });
}

/** Maps a health-standard status (e.g. a component's) onto the shared states. */
export function stateOfHealthStatus(status: HealthStatus): CheckState {
  if (status === 'pass') return 'healthy';
  if (status === 'warn') return 'degraded';
  return 'unhealthy';
}

export interface SummaryCounts {
  total: number;
  /** Healthy and not degraded. */
  healthy: number;
  degraded: number;
  unhealthy: number;
  paused: number;
}

/**
 * Display counts from the backend summary. The backend's `healthyEndpoints` includes degraded
 * ones; the display splits them so the numbers add up, like the macOS status page
 * ("2 of 4 healthy · 1 degraded"). A missing `degradedEndpoints` (older backend) counts as 0.
 */
export function summaryCounts(summary: DashboardSummary): SummaryCounts {
  const degraded = Math.max(0, Math.min(summary.degradedEndpoints ?? 0, summary.healthyEndpoints));
  return {
    total: summary.totalEndpoints,
    healthy: summary.healthyEndpoints - degraded,
    degraded,
    unhealthy: summary.unhealthyEndpoints,
    paused: summary.pausedEndpoints,
  };
}

/**
 * Recomputes the backend's summary counters from the endpoints, with the backend's rules: paused
 * first, endpoints without a check count nowhere, degraded is a subset of healthy. Used after a
 * live (SSE) update changes one endpoint's latest check. Total and uptime are kept.
 */
export function recomputeSummary(summary: DashboardSummary, endpoints: DashboardEndpoint[]): DashboardSummary {
  let healthyEndpoints = 0;
  let unhealthyEndpoints = 0;
  let degradedEndpoints = 0;
  let pausedEndpoints = 0;
  for (const endpoint of endpoints) {
    if (endpoint.isPaused) {
      pausedEndpoints += 1;
    } else if (endpoint.latestCheck) {
      if (endpoint.latestCheck.isHealthy) {
        healthyEndpoints += 1;
        if (endpoint.latestCheck.isDegraded === true || endpoint.latestCheck.healthStatus === 'warn') {
          degradedEndpoints += 1;
        }
      } else {
        unhealthyEndpoints += 1;
      }
    }
  }
  return { ...summary, healthyEndpoints, unhealthyEndpoints, degradedEndpoints, pausedEndpoints };
}

/** A check result pushed over SSE (backend `CheckResultEvent`). */
export interface CheckResultEvent {
  endpointId: string;
  isHealthy: boolean;
  responseTimeMs: number | null;
  statusCode: number | null;
  failureReason: string | null;
  /** `null` for non-standard endpoints; absent from older backends. */
  healthStatus?: HealthStatus | null;
  timestamp: string;
}

export function isCheckResultEvent(value: unknown): value is CheckResultEvent {
  if (!value || typeof value !== 'object') return false;
  const event = value as Record<string, unknown>;
  return (
    typeof event.endpointId === 'string' &&
    typeof event.isHealthy === 'boolean' &&
    typeof event.timestamp === 'string'
  );
}

/**
 * Applies a live check result to a dashboard response: replaces that endpoint's latest check
 * (keeping the certificate expiry, which events don't carry) and recomputes the summary. Returns
 * the same object when the event is for an unknown endpoint.
 */
export function applyCheckEvent(data: DashboardResponse, event: CheckResultEvent): DashboardResponse {
  const index = data.endpoints.findIndex((endpoint) => endpoint.id === event.endpointId);
  if (index === -1) return data;

  const previous = data.endpoints[index];
  const healthStatus = event.healthStatus ?? null;
  const updated: DashboardEndpoint = {
    ...previous,
    latestCheck: {
      isHealthy: event.isHealthy,
      responseTimeMs: event.responseTimeMs,
      statusCode: event.statusCode,
      failureReason: event.failureReason,
      timestamp: event.timestamp,
      certificateExpiresAt: previous.latestCheck?.certificateExpiresAt ?? null,
      healthStatus,
      isDegraded: event.isHealthy && healthStatus === 'warn',
    },
  };
  const endpoints = data.endpoints.slice();
  endpoints[index] = updated;
  return { summary: recomputeSummary(data.summary, endpoints), endpoints };
}
