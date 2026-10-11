import { useCallback, useEffect, useRef } from 'react';
import { AppState, type AppStateStatus } from 'react-native';
import { useFocusEffect } from 'expo-router';

/**
 * Runs `callback` whenever the screen gains focus (first mount, tab switch,
 * back navigation, closing a modal on top of it) and when the app comes back
 * to the foreground. This is the screens' only fetch trigger, so the first
 * focus must run too: none of them has a separate initial fetch.
 */
export function useRefreshOnFocus(callback: () => void): void {
  const callbackRef = useRef(callback);
  callbackRef.current = callback;

  useFocusEffect(
    useCallback(() => {
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
