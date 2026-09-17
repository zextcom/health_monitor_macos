import { storage } from './storage';

// Configurable via EXPO_PUBLIC_API_URL (inlined at build time by Expo).
// Defaults to localhost for local development against the backend.
export const API_BASE_URL = process.env.EXPO_PUBLIC_API_URL ?? 'http://localhost:3001';

const ACCESS_TOKEN_KEY = 'health_monitor.accessToken';
const REFRESH_TOKEN_KEY = 'health_monitor.refreshToken';
const USER_KEY = 'health_monitor.user';

export class ApiError extends Error {
  status: number;
  details?: unknown;

  constructor(status: number, message: string, details?: unknown) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.details = details;
  }
}

type SessionExpiredHandler = () => void;
let sessionExpiredHandler: SessionExpiredHandler | null = null;

/** Registered by the auth store so a failed silent-refresh can log the user out. */
export function setSessionExpiredHandler(handler: SessionExpiredHandler | null): void {
  sessionExpiredHandler = handler;
}

export async function getAccessToken(): Promise<string | null> {
  return storage.getItem(ACCESS_TOKEN_KEY);
}

export async function getRefreshToken(): Promise<string | null> {
  return storage.getItem(REFRESH_TOKEN_KEY);
}

export async function setTokens(accessToken: string, refreshToken: string): Promise<void> {
  await Promise.all([
    storage.setItem(ACCESS_TOKEN_KEY, accessToken),
    storage.setItem(REFRESH_TOKEN_KEY, refreshToken),
  ]);
}

export async function clearTokens(): Promise<void> {
  await Promise.all([
    storage.removeItem(ACCESS_TOKEN_KEY),
    storage.removeItem(REFRESH_TOKEN_KEY),
    storage.removeItem(USER_KEY),
  ]);
}

// There's no `/auth/me` endpoint, so the user object returned by login/register
// is cached locally and re-hydrated on app launch alongside the tokens.
export async function persistUser(user: unknown): Promise<void> {
  await storage.setItem(USER_KEY, JSON.stringify(user));
}

export async function getPersistedUser<T = unknown>(): Promise<T | null> {
  const raw = await storage.getItem(USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

// Coalesce concurrent 401s into a single refresh call.
let refreshPromise: Promise<string | null> | null = null;

async function refreshAccessToken(): Promise<string | null> {
  if (!refreshPromise) {
    refreshPromise = (async () => {
      const refreshToken = await getRefreshToken();
      if (!refreshToken) return null;

      try {
        const res = await fetch(`${API_BASE_URL}/api/auth/refresh`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ refreshToken }),
        });
        if (!res.ok) return null;

        const data = (await res.json()) as { accessToken: string; refreshToken: string };
        await setTokens(data.accessToken, data.refreshToken);
        return data.accessToken;
      } catch {
        return null;
      }
    })();
  }

  try {
    return await refreshPromise;
  } finally {
    refreshPromise = null;
  }
}

export interface ApiFetchOptions extends Omit<RequestInit, 'body'> {
  body?: unknown;
  /** Skip attaching the Authorization header / 401 refresh handling (login, register, refresh). */
  skipAuth?: boolean;
}

function extractErrorMessage(data: unknown, fallback: string): string {
  if (data && typeof data === 'object' && 'error' in data) {
    const error = (data as { error: unknown }).error;
    if (typeof error === 'string') return error;
    if (error && typeof error === 'object') {
      // zod's `flatten()` shape — surface the first field error if present.
      const flat = error as { formErrors?: string[]; fieldErrors?: Record<string, string[]> };
      const firstField = flat.fieldErrors && Object.values(flat.fieldErrors).find((v) => v?.length);
      return firstField?.[0] ?? flat.formErrors?.[0] ?? fallback;
    }
  }
  return fallback;
}

export async function apiFetch<T = unknown>(
  path: string,
  options: ApiFetchOptions = {},
  _isRetry = false,
): Promise<T> {
  const { body, skipAuth, headers, ...rest } = options;

  const finalHeaders: Record<string, string> = {
    'Content-Type': 'application/json',
    ...((headers as Record<string, string>) ?? {}),
  };

  if (!skipAuth) {
    const token = await getAccessToken();
    if (token) {
      finalHeaders.Authorization = `Bearer ${token}`;
    }
  }

  const res = await fetch(`${API_BASE_URL}${path}`, {
    ...rest,
    headers: finalHeaders,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (res.status === 401 && !skipAuth && !_isRetry) {
    const newToken = await refreshAccessToken();
    if (newToken) {
      return apiFetch<T>(path, options, true);
    }
    await clearTokens();
    sessionExpiredHandler?.();
    throw new ApiError(401, 'Session expired');
  }

  if (res.status === 204) {
    return undefined as T;
  }

  const text = await res.text();
  const data = text ? JSON.parse(text) : undefined;

  if (!res.ok) {
    throw new ApiError(res.status, extractErrorMessage(data, `Request failed (${res.status})`), data);
  }

  return data as T;
}
