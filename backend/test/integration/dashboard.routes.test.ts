import { describe, it, expect, beforeEach, afterAll, beforeAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader } from '../helpers.js';

describe('dashboard routes', () => {
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

  describe('GET /dashboard', () => {
    it('should return empty dashboard for new user (200)', async () => {
      const res = await app.inject({
        method: 'GET',
        url: '/dashboard',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.summary).toEqual({
        totalEndpoints: 0,
        healthyEndpoints: 0,
        unhealthyEndpoints: 0,
        pausedEndpoints: 0,
        overallUptimePercent: 100,
      });
      expect(body.endpoints).toEqual([]);
    });

    it('should return endpoint summary with correct counts', async () => {
      await app.inject({
        method: 'POST',
        url: '/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API 1', url: 'https://api1.example.com' },
      });
      await app.inject({
        method: 'POST',
        url: '/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API 2', url: 'https://api2.example.com' },
      });
      const pausedCreateRes = await app.inject({
        method: 'POST',
        url: '/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API 3', url: 'https://api3.example.com' },
      });
      await app.inject({
        method: 'POST',
        url: `/endpoints/${pausedCreateRes.json().id}/pause`,
        headers: authHeader(accessToken),
      });

      const res = await app.inject({
        method: 'GET',
        url: '/dashboard',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.summary.totalEndpoints).toBe(3);
      expect(body.summary.pausedEndpoints).toBe(1);
      expect(body.endpoints).toHaveLength(3);
    });

    it('should return 401 without auth', async () => {
      const res = await app.inject({ method: 'GET', url: '/dashboard' });
      expect(res.statusCode).toBe(401);
    });
  });
});
