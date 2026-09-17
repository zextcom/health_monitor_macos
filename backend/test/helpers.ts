import { buildApp } from '../src/app.js';
import { db } from '../src/db/index.js';
import { sql } from 'drizzle-orm';
import { stopSSESubscriber } from '../src/modules/sse/sse-bus.js';
import type { FastifyInstance } from 'fastify';

export async function createApp(): Promise<FastifyInstance> {
  const app = await buildApp();
  await app.ready();

  // @fastify/rate-limit keys buckets by remote IP, and light-my-request's
  // inject() defaults every call to the same fake address. Left as-is, a
  // single test file's rapid-fire register/login calls would trip the
  // strict /auth/register and /auth/login limits (max 10/min) long before
  // all its tests finished. Give every injected request its own IP so tests
  // don't share a rate-limit bucket with one another.
  const originalInject = app.inject.bind(app);
  app.inject = ((opts: unknown) => {
    const normalized =
      typeof opts === 'string' ? { url: opts } : { ...(opts as Record<string, unknown>) };
    if (!normalized.remoteAddress) {
      normalized.remoteAddress = `10.${Math.floor(Math.random() * 255)}.${Math.floor(
        Math.random() * 255,
      )}.${Math.floor(Math.random() * 255)}`;
    }
    return originalInject(normalized as Parameters<typeof originalInject>[0]);
  }) as typeof app.inject;

  return app;
}

export async function closeApp(app: FastifyInstance): Promise<void> {
  await app.close();
  // buildApp() starts a Redis subscriber that isn't tied to the Fastify
  // lifecycle, so it must be stopped explicitly to avoid hanging the
  // test process once all tests in a file are done.
  await stopSSESubscriber();
}

export async function cleanDb(): Promise<void> {
  await db.execute(
    sql`TRUNCATE users, endpoints, health_check_results, daily_stats, incidents, refresh_tokens, invitations, endpoint_secrets, push_subscriptions, notification_preferences CASCADE`,
  );
}

export async function registerAndLogin(
  app: FastifyInstance,
  email = 'admin@test.com',
  password = 'testpass123',
  name = 'Admin',
): Promise<{ accessToken: string; refreshToken: string; userId: string }> {
  await app.inject({
    method: 'POST',
    url: '/api/auth/register',
    payload: { email, password, name },
  });

  const loginRes = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { email, password },
  });

  const body = loginRes.json();
  return {
    accessToken: body.accessToken,
    refreshToken: body.refreshToken,
    userId: body.user.id,
  };
}

export function authHeader(token: string): { Authorization: string } {
  return { Authorization: `Bearer ${token}` };
}

/**
 * Invites a new user via an admin's token, accepts the invitation, and logs
 * the new user in. Handy for tests that need a second, distinct user.
 */
export async function inviteAndLogin(
  app: FastifyInstance,
  adminToken: string,
  email: string,
  password = 'testpass123',
  name = 'Member',
): Promise<{ accessToken: string; refreshToken: string; userId: string }> {
  const inviteRes = await app.inject({
    method: 'POST',
    url: '/api/auth/invite',
    headers: authHeader(adminToken),
    payload: { email },
  });
  const { token } = inviteRes.json();

  await app.inject({
    method: 'POST',
    url: '/api/auth/accept-invite',
    payload: { token, password, name },
  });

  const loginRes = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { email, password },
  });

  const body = loginRes.json();
  return {
    accessToken: body.accessToken,
    refreshToken: body.refreshToken,
    userId: body.user.id,
  };
}
