import { apiFetch } from './client';

export interface NotificationPreferences {
  userId: string;
  notifyOnDown: boolean;
  notifyOnRecovery: boolean;
  /** Absent on backends older than the version check feature; treat as on (the backend default). */
  notifyOnVersionChange?: boolean;
}

export type NotificationPreferenceKey = 'notifyOnDown' | 'notifyOnRecovery' | 'notifyOnVersionChange';

export function getNotificationPreferences(): Promise<NotificationPreferences> {
  return apiFetch<NotificationPreferences>('/api/notifications/preferences');
}

export function updateNotificationPreferences(
  input: Partial<Record<NotificationPreferenceKey, boolean>>,
): Promise<NotificationPreferences> {
  return apiFetch<NotificationPreferences>('/api/notifications/preferences', {
    method: 'PUT',
    body: input,
  });
}
