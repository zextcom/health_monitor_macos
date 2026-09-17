import { apiFetch, clearTokens, getRefreshToken, persistUser, setTokens } from './client';

export interface User {
  id: string;
  email: string;
  name: string;
  role: 'admin' | 'member';
  createdAt?: string;
  updatedAt?: string;
}

interface LoginResponse {
  accessToken: string;
  refreshToken: string;
  user: User;
}

interface RegisterResponse {
  user: User;
}

export async function loginRequest(email: string, password: string): Promise<User> {
  const data = await apiFetch<LoginResponse>('/api/auth/login', {
    method: 'POST',
    body: { email, password },
    skipAuth: true,
  });
  await setTokens(data.accessToken, data.refreshToken);
  await persistUser(data.user);
  return data.user;
}

// The backend registers the account but does not return tokens — the first
// user becomes admin, subsequent users need an invitation. We log in right
// after so the app can move straight into an authenticated session.
export async function registerRequest(email: string, password: string, name: string): Promise<User> {
  await apiFetch<RegisterResponse>('/api/auth/register', {
    method: 'POST',
    body: { email, password, name },
    skipAuth: true,
  });
  return loginRequest(email, password);
}

export async function logoutRequest(): Promise<void> {
  const refreshToken = await getRefreshToken();
  try {
    if (refreshToken) {
      await apiFetch('/api/auth/logout', { method: 'POST', body: { refreshToken } });
    }
  } finally {
    await clearTokens();
  }
}
