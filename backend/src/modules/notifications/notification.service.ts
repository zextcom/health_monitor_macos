import { eq } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { pushSubscriptions, notificationPreferences, endpoints } from '../../db/schema.js';

export interface NotificationPayload {
  title: string;
  body: string;
  data?: Record<string, string>;
}

export async function shouldNotify(userId: string, isDown: boolean): Promise<boolean> {
  const preferences = await db.query.notificationPreferences.findFirst({
    where: eq(notificationPreferences.userId, userId),
  });

  const notifyOnDown = preferences?.notifyOnDown ?? true;
  const notifyOnRecovery = preferences?.notifyOnRecovery ?? true;

  return isDown ? notifyOnDown : notifyOnRecovery;
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

async function sendAPNS(token: string, payload: NotificationPayload): Promise<void> {
  // TODO: Implement with @parse/node-apn or similar when APNs credentials are configured
  console.log(`[APNs] Would send to ${token.slice(0, 8)}...: ${payload.title}`);
}

async function sendFCM(token: string, payload: NotificationPayload): Promise<void> {
  // TODO: Implement with firebase-admin when FCM credentials are configured
  console.log(`[FCM] Would send to ${token.slice(0, 8)}...: ${payload.title}`);
}

async function sendWebPush(token: string, payload: NotificationPayload): Promise<void> {
  // TODO: Implement with web-push package when VAPID keys are configured
  console.log(`[WebPush] Would send to ${token.slice(0, 8)}...: ${payload.title}`);
}

export async function sendNotification(
  userId: string,
  payload: NotificationPayload,
): Promise<void> {
  const isDown = payload.data?.type === 'down';

  const notify = await shouldNotify(userId, isDown);
  if (!notify) {
    return;
  }

  const tokens = await getUserPushTokens(userId);

  for (const { platform, token } of tokens) {
    try {
      if (platform === 'apns') {
        await sendAPNS(token, payload);
      } else if (platform === 'fcm') {
        await sendFCM(token, payload);
      } else if (platform === 'web') {
        await sendWebPush(token, payload);
      }
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

export async function notifyEndpointRecovered(endpointId: string): Promise<void> {
  const endpoint = await db.query.endpoints.findFirst({
    where: eq(endpoints.id, endpointId),
  });

  if (!endpoint) {
    return;
  }

  await sendNotification(endpoint.userId, {
    title: '🟢 Endpoint Recovered',
    body: `${endpoint.name} is back online.`,
    data: { endpointId, type: 'recovery' },
  });
}
