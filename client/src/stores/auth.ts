import { create } from 'zustand';
import { loginRequest, logoutRequest, registerRequest, type User } from '../api/auth';
import { getAccessToken, getPersistedUser, getRefreshToken, setSessionExpiredHandler } from '../api/client';

interface AuthState {
  user: User | null;
  accessToken: string | null;
  refreshToken: string | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  error: string | null;
  login: (email: string, password: string) => Promise<void>;
  register: (email: string, password: string, name: string) => Promise<void>;
  logout: () => Promise<void>;
  restoreSession: () => Promise<void>;
  clearError: () => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  user: null,
  accessToken: null,
  refreshToken: null,
  isAuthenticated: false,
  isLoading: true,
  error: null,

  login: async (email, password) => {
    set({ isLoading: true, error: null });
    try {
      const user = await loginRequest(email, password);
      const [accessToken, refreshToken] = await Promise.all([getAccessToken(), getRefreshToken()]);
      set({ user, accessToken, refreshToken, isAuthenticated: true, isLoading: false });
    } catch (error) {
      set({ isLoading: false, error: error instanceof Error ? error.message : 'Login failed' });
      throw error;
    }
  },

  register: async (email, password, name) => {
    set({ isLoading: true, error: null });
    try {
      const user = await registerRequest(email, password, name);
      const [accessToken, refreshToken] = await Promise.all([getAccessToken(), getRefreshToken()]);
      set({ user, accessToken, refreshToken, isAuthenticated: true, isLoading: false });
    } catch (error) {
      set({ isLoading: false, error: error instanceof Error ? error.message : 'Registration failed' });
      throw error;
    }
  },

  logout: async () => {
    set({ isLoading: true });
    try {
      await logoutRequest();
    } finally {
      set({ user: null, accessToken: null, refreshToken: null, isAuthenticated: false, isLoading: false });
    }
  },

  restoreSession: async () => {
    set({ isLoading: true });
    try {
      const [accessToken, refreshToken] = await Promise.all([getAccessToken(), getRefreshToken()]);
      if (!accessToken || !refreshToken) {
        set({ isLoading: false, isAuthenticated: false });
        return;
      }
      // We don't have a "whoami" endpoint, so treat having both tokens as an
      // authenticated session; api/client.ts silently refreshes/clears them
      // if they turn out to be invalid on the first real request. The user
      // object is the one cached from the last successful login/register.
      const user = await getPersistedUser<User>();
      set({ user, accessToken, refreshToken, isAuthenticated: true, isLoading: false });
    } catch {
      set({ isLoading: false, isAuthenticated: false });
    }
  },

  clearError: () => set({ error: null }),
}));

// Wired once at module load: if a background token refresh ever fails,
// api/client.ts calls this so the store (and thus the UI) reflects the logout.
setSessionExpiredHandler(() => {
  useAuthStore.setState({
    user: null,
    accessToken: null,
    refreshToken: null,
    isAuthenticated: false,
    isLoading: false,
  });
});
