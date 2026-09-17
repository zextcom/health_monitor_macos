import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { API_BASE_URL, getAccessToken } from '../api/client';

export interface CheckResultEvent {
  type: string;
  [key: string]: unknown;
}

/**
 * Subscribes to GET /api/sse/checks for real-time health check results.
 * Only wired up on web today (native EventSource needs a polyfill / custom
 * headers support that RN's fetch-based EventSource shims don't give us for
 * free) — native screens fall back to polling via useRefreshOnFocus.
 */
export function useSSE(onEvent: (event: CheckResultEvent) => void, enabled: boolean = true): void {
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  useEffect(() => {
    if (!enabled || Platform.OS !== 'web') {
      return;
    }

    let es: EventSource | null = null;
    let cancelled = false;

    (async () => {
      const token = await getAccessToken();
      if (!token || cancelled) return;

      // EventSource doesn't support custom headers, so pass the token as a
      // query param; the backend's fastify.authenticate would need to accept
      // it there for this to work end-to-end against a strict Bearer-only
      // setup — this is best-effort real-time and safe to no-op otherwise.
      const url = `${API_BASE_URL}/api/sse/checks?access_token=${encodeURIComponent(token)}`;
      try {
        es = new EventSource(url);
        es.onmessage = (message) => {
          try {
            const data = JSON.parse(message.data) as CheckResultEvent;
            onEventRef.current(data);
          } catch {
            // ignore malformed events
          }
        };
      } catch {
        // SSE not available in this environment; ignore.
      }
    })();

    return () => {
      cancelled = true;
      es?.close();
    };
  }, [enabled]);
}
