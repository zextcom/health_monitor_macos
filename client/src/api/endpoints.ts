import { apiFetch } from './client';

export interface JsonAssertion {
  path: string;
  expectedValue: string;
  matchMode: 'exact' | 'contains' | 'regex';
}

export type CheckType = 'http' | 'tcp';
export type AuthType = 'none' | 'bearer_token' | 'basic_auth' | 'custom_header';

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
  return apiFetch<Endpoint[]>(`/endpoints${qs ? `?${qs}` : ''}`);
}

export function getEndpoint(id: string): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/endpoints/${id}`);
}

export function createEndpoint(input: CreateEndpointInput): Promise<Endpoint> {
  return apiFetch<Endpoint>('/endpoints', { method: 'POST', body: input });
}

export function updateEndpoint(id: string, input: UpdateEndpointInput): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/endpoints/${id}`, { method: 'PUT', body: input });
}

export function deleteEndpoint(id: string): Promise<void> {
  return apiFetch<void>(`/endpoints/${id}`, { method: 'DELETE' });
}

export function pauseEndpoint(id: string): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/endpoints/${id}/pause`, { method: 'POST' });
}

export function resumeEndpoint(id: string): Promise<Endpoint> {
  return apiFetch<Endpoint>(`/endpoints/${id}/resume`, { method: 'POST' });
}
