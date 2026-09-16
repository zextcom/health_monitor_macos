import { useCallback, useEffect, useRef } from 'react';
import { AppState, type AppStateStatus } from 'react-native';
import { useFocusEffect } from 'expo-router';

/**
 * Re-runs `callback` whenever the screen regains focus (tab switch, back
 * navigation) or the app comes back to the foreground. Skips the very first
 * focus so it doesn't double-fire alongside the screen's initial fetch.
 */
export function useRefreshOnFocus(callback: () => void): void {
  const callbackRef = useRef(callback);
  callbackRef.current = callback;

  const isFirstFocus = useRef(true);

  useFocusEffect(
    useCallback(() => {
      if (isFirstFocus.current) {
        isFirstFocus.current = false;
        return;
      }
      callbackRef.current();
    }, []),
  );

  useEffect(() => {
    const subscription = AppState.addEventListener('change', (state: AppStateStatus) => {
      if (state === 'active') {
        callbackRef.current();
      }
    });
    return () => subscription.remove();
  }, []);
}
