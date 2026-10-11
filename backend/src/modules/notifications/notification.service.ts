import { eq } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { pushSubscriptions, notificationPreferences, endpoints } from '../../db/schema.js';

export interface NotificationPayload {
  title: string;
  body: string;
  data?: Record<string, string>;
}

export type NotificationType =
  | 'down'
  | 'recovery'
  | 'version_change'
  | 'version_failed'
  | 'version_recovered'
  | 'degraded'
  | 'degraded_recovered';

type PreferenceKey = 'notifyOnDown' | 'notifyOnRecovery' | 'notifyOnVersionChange';

/**
 * Which user preference gates each notification type. Version check failure/resolved and the
 * health-standard degraded/no-longer-degraded pair follow down/recovery (same as the macOS app);
 * version changes have their own toggle.
 */
export const preferenceForNotificationType: Record<NotificationType, PreferenceKey> = {
  down: 'notifyOnDown',
  recovery: 'notifyOnRecovery',
  version_change: 'notifyOnVersionChange',
  version_failed: 'notifyOnDown',
  version_recovered: 'notifyOnRecovery',
  degraded: 'notifyOnDown',
  degraded_recovered: 'notifyOnRecovery',
};

export async function shouldNotify(userId: string, type: NotificationType): Promise<boolean> {
  const preferences = await db.query.notificationPreferences.findFirst({
    where: eq(notificationPreferences.userId, userId),
  });

  return preferences?.[preferenceForNotificationType[type]] ?? true;
}

export async function getUserPushTokens(
  userId: string,
): Promise<Array<{ platform: string; token: string }>> {
  const subscriptions = await db.query.pushSubscriptions.findMany({
    where: eq(pushSubscriptions.userId, userId),
  });

  return subscriptions.map((subscription) => ({
    platform: subscription.platform,
    token: subscription.token,
  }));
}

async function sendExpoPush(token: string, payload: NotificationPayload): Promise<void> {
  const response = await fetch('https://exp.host/--/api/v2/push/send', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      to: token,
      title: payload.title,
      body: payload.body,
      data: payload.data,
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    console.error(`[ExpoPush] HTTP ${response.status} for ${token.slice(0, 20)}...: ${text}`);
    return;
  }

  const result = await response.json();
  if (result.data?.status === 'error') {
    console.error(
      `[ExpoPush] Error for ${token.slice(0, 20)}...: ${result.data.message ?? 'unknown'}`,
    );
  }
}

export async function sendNotification(
  userId: string,
  payload: NotificationPayload,
): Promise<void> {
  // Unknown/missing types fall back to the recovery preference, as non-'down' payloads always did.
  const rawType = payload.data?.type;
  const type: NotificationType =
    rawType && rawType in preferenceForNotificationType ? (rawType as NotificationType) : 'recovery';

  const notify = await shouldNotify(userId, type);
  if (!notify) {
    return;
  }

  const tokens = await getUserPushTokens(userId);

  for (const { platform, token } of tokens) {
    try {
      await sendExpoPush(token, payload);
    } catch (error) {
      console.error(`Failed to send ${platform} notification to user ${userId}:`, error);
    }
  }
}

export async function notifyEndpointDown(
  endpointId: string,
  failureReason: string | null,
): Promise<void> {
  const endpoint = await db.query.endpoints.findFirst({
    where: eq(endpoints.id, endpointId),
  });

  if (!endpoint) {
    return;
  }

  await sendNotification(endpoint.userId, {
    title: '🔴 Endpoint Down',
    body: `${endpoint.name} is unreachable. ${failureReason || ''}`,
    data: { endpointId, type: 'down' },
  });
}

/**
 * `degradedReason` is set when the endpoint came back as a health-standard `warn` — down → degraded
 * sends only this one "recovered" notification, worded as degraded, rather than a second one.
 */
export async function notifyEndpointRecovered(endpointId: string, degradedReason?: string | null): Promise<void> {
  const endpoint = await db.query.endpoints.findFirst({
    where: eq(endpoints.id, endpointId),
  });

  if (!endpoint) {
    return;
  }

  await sendNotification(endpoint.userId, {
    title: '🟢 Endpoint Recovered',
    body:
      degradedReason === undefined
        ? `${endpoint.name} is back online.`
        : `${endpoint.name} is back online but degraded. ${degradedReason ?? ''}`.trim(),
    data: { endpointId, type: 'recovery' },
  });
}

async function notifyForEndpoint(
  endpointId: string,
  build: (endpointName: string) => NotificationPayload,
): Promise<void> {
  const endpoint = await db.query.endpoints.findFirst({
    where: eq(endpoints.id, endpointId),
  });

  if (!endpoint) {
    return;
  }

  await sendNotification(endpoint.userId, build(endpoint.name));
}

export async function notifyVersionChanged(endpointId: string, from: string, to: string): Promise<void> {
  await notifyForEndpoint(endpointId, (name) => ({
    title: '🔄 Version Changed',
    body: `${name}: ${from} → ${to}`,
    data: { endpointId, type: 'version_change' },
  }));
}

export async function notifyVersionCheckFailed(endpointId: string, reason: string): Promise<void> {
  await notifyForEndpoint(endpointId, (name) => ({
    title: '⚠️ Version Check Failed',
    body: `${name}: ${reason}`,
    data: { endpointId, type: 'version_failed' },
  }));
}

export async function notifyVersionCheckRecovered(endpointId: string): Promise<void> {
  await notifyForEndpoint(endpointId, (name) => ({
    title: '✅ Version Check Resolved',
    body: `${name} version check succeeded again.`,
    data: { endpointId, type: 'version_recovered' },
  }));
}

export async function notifyEndpointDegraded(endpointId: string, reason: string | null): Promise<void> {
  await notifyForEndpoint(endpointId, (name) => ({
    title: '🟠 Endpoint Degraded',
    body: `${name} reports warn. ${reason ?? ''}`.trim(),
    data: { endpointId, type: 'degraded' },
  }));
}

export async function notifyEndpointNoLongerDegraded(endpointId: string): Promise<void> {
  await notifyForEndpoint(endpointId, (name) => ({
    title: '🟢 Endpoint Healthy',
    body: `${name} is no longer degraded.`,
    data: { endpointId, type: 'degraded_recovered' },
  }));
}
