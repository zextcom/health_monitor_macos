import { apiFetch } from './client';

export interface DashboardLatestCheck {
  isHealthy: boolean;
  responseTimeMs: number | null;
  statusCode: number | null;
  failureReason: string | null;
  timestamp: string;
  certificateExpiresAt: string | null;
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
}

export interface DashboardSummary {
  totalEndpoints: number;
  healthyEndpoints: number;
  unhealthyEndpoints: number;
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
