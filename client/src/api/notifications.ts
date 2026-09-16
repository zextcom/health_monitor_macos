import { apiFetch } from './client';

export interface NotificationPreferences {
  userId: string;
  notifyOnDown: boolean;
  notifyOnRecovery: boolean;
}

export function getNotificationPreferences(): Promise<NotificationPreferences> {
  return apiFetch<NotificationPreferences>('/notifications/preferences');
}

export function updateNotificationPreferences(
  input: Partial<Pick<NotificationPreferences, 'notifyOnDown' | 'notifyOnRecovery'>>,
): Promise<NotificationPreferences> {
  return apiFetch<NotificationPreferences>('/notifications/preferences', {
    method: 'PUT',
    body: input,
  });
}
