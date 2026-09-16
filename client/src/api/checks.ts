import { apiFetch } from './client';

export interface HealthCheckResult {
  id: string;
  endpointId: string;
  timestamp: string;
  isHealthy: boolean;
  responseTimeMs: number | null;
  statusCode: number | null;
  failureReason: string | null;
  certificateExpiresAt: string | null;
}

export interface DailyStat {
  id: string;
  endpointId: string;
  date: string;
  totalChecks: number;
  downChecks: number;
  downtimeSeconds: string;
}

export interface Incident {
  id: string;
  endpointId: string;
  startedAt: string;
  endedAt: string | null;
  failureReason: string | null;
  isOngoing: boolean;
}

export interface UptimeResponse {
  uptimePercent: number;
  totalChecks: number;
  downChecks: number;
}

export function getCheckHistory(
  endpointId: string,
  params: { limit?: number; offset?: number } = {},
): Promise<HealthCheckResult[]> {
  const query = new URLSearchParams();
  if (params.limit !== undefined) query.set('limit', String(params.limit));
  if (params.offset !== undefined) query.set('offset', String(params.offset));
  const qs = query.toString();
  return apiFetch<HealthCheckResult[]>(`/endpoints/${endpointId}/checks${qs ? `?${qs}` : ''}`);
}

export function getLatestCheck(endpointId: string): Promise<HealthCheckResult | null> {
  return apiFetch<HealthCheckResult | null>(`/endpoints/${endpointId}/checks/latest`);
}

export function getDailyStats(endpointId: string, days = 30): Promise<DailyStat[]> {
  return apiFetch<DailyStat[]>(`/endpoints/${endpointId}/stats?days=${days}`);
}

export function getUptime(endpointId: string, days = 7): Promise<UptimeResponse> {
  return apiFetch<UptimeResponse>(`/endpoints/${endpointId}/uptime?days=${days}`);
}

export function getIncidents(endpointId: string, limit = 20): Promise<Incident[]> {
  return apiFetch<Incident[]>(`/endpoints/${endpointId}/incidents?limit=${limit}`);
}
