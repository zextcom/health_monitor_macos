import { describe, it, expect, beforeEach, afterAll, beforeAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader } from '../helpers.js';

describe('notifications routes', () => {
  let app: FastifyInstance;
  let accessToken: string;

  beforeAll(async () => {
    app = await createApp();
  });

  afterAll(async () => {
    await closeApp(app);
  });

  beforeEach(async () => {
    await cleanDb();
    const auth = await registerAndLogin(app);
    accessToken = auth.accessToken;
  });

  describe('GET /notifications/preferences', () => {
    it('should return default preferences for new user', async () => {
      const res = await app.inject({
        method: 'GET',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.notifyOnDown).toBe(true);
      expect(body.notifyOnRecovery).toBe(true);
    });

    it('should return saved preferences', async () => {
      await app.inject({
        method: 'PUT',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
        payload: { notifyOnDown: false, notifyOnRecovery: true },
      });

      const res = await app.inject({
        method: 'GET',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.notifyOnDown).toBe(false);
      expect(body.notifyOnRecovery).toBe(true);
    });
  });

  describe('PUT /notifications/preferences', () => {
    it('should update preferences', async () => {
      await app.inject({
        method: 'PUT',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
        payload: { notifyOnDown: false, notifyOnRecovery: false },
      });

      const res = await app.inject({
        method: 'PUT',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
        payload: { notifyOnDown: true },
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.notifyOnDown).toBe(true);
      expect(body.notifyOnRecovery).toBe(false);
    });

    it('should create preferences if none exist', async () => {
      const res = await app.inject({
        method: 'PUT',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
        payload: { notifyOnDown: false },
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.notifyOnDown).toBe(false);
      expect(body.notifyOnRecovery).toBe(true);

      const getRes = await app.inject({
        method: 'GET',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
      });
      expect(getRes.json().notifyOnDown).toBe(false);
    });
  });

  describe('POST /notifications/subscriptions', () => {
    it('should add push subscription (201)', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/notifications/subscriptions',
        headers: authHeader(accessToken),
        payload: { platform: 'web', token: 'push-token-abc', deviceName: 'MacBook' },
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body.platform).toBe('web');
      expect(body.token).toBe('push-token-abc');
      expect(body.deviceName).toBe('MacBook');
    });
  });

  describe('GET /notifications/subscriptions', () => {
    it("should list user's subscriptions", async () => {
      await app.inject({
        method: 'POST',
        url: '/api/notifications/subscriptions',
        headers: authHeader(accessToken),
        payload: { platform: 'apns', token: 'apns-token' },
      });
      await app.inject({
        method: 'POST',
        url: '/api/notifications/subscriptions',
        headers: authHeader(accessToken),
        payload: { platform: 'fcm', token: 'fcm-token' },
      });

      const res = await app.inject({
        method: 'GET',
        url: '/api/notifications/subscriptions',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      expect(res.json()).toHaveLength(2);
    });
  });

  describe('DELETE /notifications/subscriptions/:id', () => {
    it('should remove subscription (204)', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/notifications/subscriptions',
        headers: authHeader(accessToken),
        payload: { platform: 'web', token: 'push-token-abc' },
      });
      const { id } = createRes.json();

      const res = await app.inject({
        method: 'DELETE',
        url: `/api/notifications/subscriptions/${id}`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(204);

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/notifications/subscriptions',
        headers: authHeader(accessToken),
      });
      expect(listRes.json()).toEqual([]);
    });

    it("should return 404 for non-existent/other user's subscription", async () => {
      const res = await app.inject({
        method: 'DELETE',
        url: '/api/notifications/subscriptions/00000000-0000-0000-0000-000000000000',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(404);
    });
  });
});
