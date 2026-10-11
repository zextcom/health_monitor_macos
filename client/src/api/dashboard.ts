import { apiFetch } from './client';
import type { HealthDetails, HealthStatus } from './endpoints';

export interface DashboardLatestCheck {
  isHealthy: boolean;
  responseTimeMs: number | null;
  statusCode: number | null;
  failureReason: string | null;
  timestamp: string;
  certificateExpiresAt: string | null;
  /** Health-standard `status` of this result; `null` for non-standard endpoints. */
  healthStatus?: HealthStatus | null;
  /** Up, but the service reported `warn` (counts as healthy for uptime). */
  isDegraded?: boolean;
}

export interface DashboardVersion {
  isEnabled: boolean;
  current: string | null;
  isFailing: boolean;
  failureReason: string | null;
  lastCheckedAt: string | null;
  /** An explicit version check, or the health-standard response. */
  source?: 'versionCheck' | 'healthStandard';
}

export interface DashboardActiveIncident {
  startedAt: string;
  failureReason: string | null;
}

export interface DashboardEndpoint {
  id: string;
  name: string;
  url: string;
  checkType: string;
  groupName: string | null;
  isPaused: boolean;
  latestCheck: DashboardLatestCheck | null;
  uptimePercent24h: number | null;
  activeIncident: DashboardActiveIncident | null;
  /** `null` without a version check or health-standard auto-tracking. */
  version?: DashboardVersion | null;
  healthStandard?: boolean;
  healthDetails?: HealthDetails | null;
}

export interface DashboardSummary {
  totalEndpoints: number;
  healthyEndpoints: number;
  unhealthyEndpoints: number;
  /** Subset of `healthyEndpoints` whose latest health-standard status is `warn`. Optional for older backends. */
  degradedEndpoints?: number;
  pausedEndpoints: number;
  overallUptimePercent: number;
}

export interface DashboardResponse {
  summary: DashboardSummary;
  endpoints: DashboardEndpoint[];
}

export function getDashboard(): Promise<DashboardResponse> {
  return apiFetch<DashboardResponse>('/api/dashboard');
}
