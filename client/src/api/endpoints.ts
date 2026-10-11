import { apiFetch } from './client';

export interface JsonAssertion {
  path: string;
  expectedValue: string;
  matchMode: 'exact' | 'contains' | 'regex';
}

export type CheckType = 'http' | 'tcp';
export type AuthType = 'none' | 'bearer_token' | 'basic_auth' | 'custom_header';
export type MatchMode = JsonAssertion['matchMode'];
/** Zext Health Standard `status` of a response. */
export type HealthStatus = 'pass' | 'warn' | 'fail';

/** Optional periodic version check against a separate URL (docs/version-check.md). */
export interface VersionCheckConfig {
  isEnabled: boolean;
  url: string;
  everyNChecks: number;
  /** Dot-path to the version value in the JSON body, e.g. "data.version". */
  versionFieldPath: string;
  assertions: JsonAssertion[];
  authType: AuthType;
  authUsername: string | null;
  authHeaderName: string | null;
}

export interface Endpoint {
  id: string;
  userId: string;
  name: string;
  url: string;
  checkType: CheckType;
  expectedStatusCode: number;
  checkInterval: number;
  groupName: string | null;
  jsonAssertions: JsonAssertion[];
  authType: AuthType;
  authUsername: string | null;
  authHeaderName: string | null;
  isPaused: boolean;
  /** `null` when no version check is configured. Optional for older backends. */
  versionCheck?: VersionCheckConfig | null;
  /** Evaluates responses per the Zext Health Standard. Optional for older backends. */
  healthStandard?: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface CreateEndpointInput {
  name: string;
  url: string;
  checkType?: CheckType;
  expectedStatusCode?: number;
  checkInterval?: number;
  groupName?: string | null;
  jsonAssertions?: JsonAssertion[];
  authType?: AuthType;
  authUsername?: string | null;
  authHeaderName?: string | null;
  authSecret?: string;
  /** `null` removes the version check (and its secret). */
  versionCheck?: VersionCheckConfig | null;
  /** Secret for `versionCheck.authType`; stored encrypted, never returned. */
  versionAuthSecret?: string;
  healthStandard?: boolean;
}

export type UpdateEndpointInput = Partial<CreateEndpointInput>;

export interface ListEndpointsParams {
  group?: string;
  paused?: boolean;
}

export function listEndpoints(params: ListEndpointsParams = {}): Promise<Endpoint[]> {
  const query = new URLSearchParams();
  if (params.group) query.set('group', params.group);
  if (params.paused !== undefined) query.set('paused', String(params.paused));
  const qs = query.toString();
  return apiFetch<Endpoint[]>(`/api/endpoints${qs ? `?${qs}` : ''}`);
}

export function getEndpoint(id: string): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/api/endpoints/${id}`);
}

export function createEndpoint(input: CreateEndpointInput): Promise<Endpoint> {
  return apiFetch<Endpoint>('/api/endpoints', { method: 'POST', body: input });
}

export function updateEndpoint(id: string, input: UpdateEndpointInput): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/api/endpoints/${id}`, { method: 'PUT', body: input });
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

/** One flattened entry of a health-standard `checks` map (`key` is `component:measurement`). */
export interface HealthComponent {
  key: string;
  status: HealthStatus;
  componentId?: string;
  componentType?: string;
  observedValue?: number | string | boolean;
  observedUnit?: string;
  time?: string;
  output?: string;
}

export interface HealthDetails {
  status: HealthStatus;
  version: string | null;
  releaseId: string | null;
  output: string | null;
  checkedAt: string;
  components: HealthComponent[];
}

export interface HealthDetailsResponse {
  healthStandard: boolean;
  /** Latest parsed health-standard response, `null` until one is seen. */
  latest: HealthDetails | null;
}

export function getEndpointVersions(id: string): Promise<VersionHistoryResponse> {
  return apiFetch<VersionHistoryResponse>(`/api/endpoints/${id}/versions`);
}

export function getEndpointHealthDetails(id: string): Promise<HealthDetailsResponse> {
  return apiFetch<HealthDetailsResponse>(`/api/endpoints/${id}/health-details`);
}

export function deleteEndpoint(id: string): Promise<void> {
  return apiFetch<void>(`/api/endpoints/${id}`, { method: 'DELETE' });
}

export function pauseEndpoint(id: string): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/api/endpoints/${id}/pause`, { method: 'POST' });
}

export function resumeEndpoint(id: string): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/api/endpoints/${id}/resume`, { method: 'POST' });
}
