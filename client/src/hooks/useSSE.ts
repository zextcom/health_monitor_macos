import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import { API_BASE_URL, getAccessToken } from '../api/client';
import { parseSSEBuffer, reconnectDelayMs } from '../logic/sse';
import { isCheckResultEvent, type CheckResultEvent } from '../logic/status';

export type { CheckResultEvent } from '../logic/status';

/**
 * Subscribes to GET /api/sse/checks for real-time health check results (`CheckResultEvent`,
 * including `healthStatus`, so a `warn` shows as degraded live).
 *
 * Web only: it streams the response with `fetch` so the access token can go in the Authorization
 * header, which is the only place the backend's `authenticate` reads it (EventSource can't set
 * headers). React Native's fetch has no streaming body, so native screens rely on
 * useRefreshOnFocus instead. Reconnects with backoff and re-reads the token each time, so a
 * token refreshed by another request is picked up. Best effort: failures are silent.
 */
export function useSSE(onEvent: (event: CheckResultEvent) => void, enabled: boolean = true): void {
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  useEffect(() => {
    if (!enabled || Platform.OS !== 'web' || typeof fetch !== 'function') {
      return;
    }

    let cancelled = false;
    let controller: AbortController | null = null;
    let retryTimer: ReturnType<typeof setTimeout> | null = null;
    let attempt = 0;

    const scheduleReconnect = () => {
      if (cancelled) return;
      retryTimer = setTimeout(connect, reconnectDelayMs(attempt));
      attempt += 1;
    };

    async function connect() {
      if (cancelled) return;
      const token = await getAccessToken();
      if (!token || cancelled) {
        scheduleReconnect();
        return;
      }

      controller = new AbortController();
      try {
        const res = await fetch(`${API_BASE_URL}/api/sse/checks`, {
          headers: { Authorization: `Bearer ${token}`, Accept: 'text/event-stream' },
          signal: controller.signal,
        });
        if (!res.ok || !res.body) {
          scheduleReconnect();
          return;
        }

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        attempt = 0;

        while (!cancelled) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const parsed = parseSSEBuffer(buffer);
          buffer = parsed.rest;
          for (const data of parsed.events) {
            try {
              const event: unknown = JSON.parse(data);
              if (isCheckResultEvent(event)) {
                onEventRef.current(event);
              }
            } catch {
              // ignore malformed events
            }
          }
        }
      } catch {
        // network error or abort; reconnect below unless cancelled
      }
      scheduleReconnect();
    }

    connect();

    return () => {
      cancelled = true;
      controller?.abort();
      if (retryTimer) clearTimeout(retryTimer);
    };
  }, [enabled]);
}
