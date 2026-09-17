import { describe, it, expect, beforeEach, afterAll, beforeAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader, inviteAndLogin } from '../helpers.js';

describe('endpoints routes', () => {
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

  describe('GET /endpoints', () => {
    it("should return user's endpoints (200)", async () => {
      await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });

      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(Array.isArray(body)).toBe(true);
      expect(body).toHaveLength(1);
      expect(body[0].name).toBe('API');
    });

    it('should return empty array for new user', async () => {
      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual([]);
    });

    it('should return 401 without auth', async () => {
      const res = await app.inject({ method: 'GET', url: '/api/endpoints' });
      expect(res.statusCode).toBe(401);
    });

    it('should filter by group query param', async () => {
      await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com', groupName: 'prod' },
      });
      await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'Web', url: 'https://web.example.com', groupName: 'staging' },
      });

      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints?group=prod',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body).toHaveLength(1);
      expect(body[0].name).toBe('API');
    });

    it("should not return other users' endpoints", async () => {
      const other = await inviteAndLogin(app, accessToken, 'other@test.com');

      await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(other.accessToken),
        payload: { name: 'Other endpoint', url: 'https://other.example.com' },
      });

      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual([]);
    });
  });

  describe('POST /endpoints', () => {
    it('should create endpoint (201)', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body.name).toBe('API');
      expect(body.url).toBe('https://api.example.com');
      expect(body.checkType).toBe('http');
      expect(body.checkInterval).toBe(300);
      expect(body.isPaused).toBe(false);
    });

    it('should create endpoint with all optional fields', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: {
          name: 'Secure API',
          url: 'https://secure.example.com',
          checkType: 'http',
          expectedStatusCode: 201,
          checkInterval: 60,
          groupName: 'prod',
          jsonAssertions: [{ path: '$.status', expectedValue: 'ok', matchMode: 'exact' }],
          authType: 'bearer_token',
          authUsername: null,
          authHeaderName: null,
          authSecret: 'super-secret-token',
        },
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body.groupName).toBe('prod');
      expect(body.expectedStatusCode).toBe(201);
      expect(body.checkInterval).toBe(60);
      expect(body.authType).toBe('bearer_token');
      expect(body.jsonAssertions).toEqual([
        { path: '$.status', expectedValue: 'ok', matchMode: 'exact' },
      ]);
      expect(body.authSecret).toBeUndefined();
    });

    it('should return 400 for missing required fields (name, url)', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: {},
      });

      expect(res.statusCode).toBe(400);
    });

    it('should return 401 without auth', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        payload: { name: 'API', url: 'https://api.example.com' },
      });

      expect(res.statusCode).toBe(401);
    });
  });

  describe('GET /endpoints/:id', () => {
    it('should return endpoint (200)', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });
      const { id } = createRes.json();

      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      expect(res.json().id).toBe(id);
    });

    it('should return 404 for non-existent id', async () => {
      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints/00000000-0000-0000-0000-000000000000',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(404);
    });

    it('should return 404 for another user\'s endpoint (not 403, to avoid leaking existence)', async () => {
      const other = await inviteAndLogin(app, accessToken, 'other@test.com');
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(other.accessToken),
        payload: { name: 'Other', url: 'https://other.example.com' },
      });
      const { id } = createRes.json();

      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(404);
    });
  });

  describe('PUT /endpoints/:id', () => {
    it('should update endpoint (200)', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });
      const { id } = createRes.json();

      const res = await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
        payload: { name: 'Renamed API', checkInterval: 120 },
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.name).toBe('Renamed API');
      expect(body.checkInterval).toBe(120);
    });

    it('should only update provided fields (partial update)', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: {
          name: 'API',
          url: 'https://api.example.com',
          groupName: 'prod',
          expectedStatusCode: 200,
        },
      });
      const created = createRes.json();

      const res = await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${created.id}`,
        headers: authHeader(accessToken),
        payload: { groupName: 'staging' },
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.groupName).toBe('staging');
      expect(body.name).toBe('API');
      expect(body.url).toBe('https://api.example.com');
      expect(body.expectedStatusCode).toBe(200);
    });

    it('should return 404 for non-existent id', async () => {
      const res = await app.inject({
        method: 'PUT',
        url: '/api/endpoints/00000000-0000-0000-0000-000000000000',
        headers: authHeader(accessToken),
        payload: { name: 'Nope' },
      });

      expect(res.statusCode).toBe(404);
    });
  });

  describe('DELETE /endpoints/:id', () => {
    it('should delete endpoint (204)', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });
      const { id } = createRes.json();

      const res = await app.inject({
        method: 'DELETE',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(204);

      const getRes = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
      });
      expect(getRes.statusCode).toBe(404);
    });

    it('should return 404 for non-existent id', async () => {
      const res = await app.inject({
        method: 'DELETE',
        url: '/api/endpoints/00000000-0000-0000-0000-000000000000',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(404);
    });
  });

  describe('POST /endpoints/:id/pause', () => {
    it('should set isPaused to true', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });
      const { id } = createRes.json();

      const res = await app.inject({
        method: 'POST',
        url: `/api/endpoints/${id}/pause`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      expect(res.json().isPaused).toBe(true);
    });
  });

  describe('POST /endpoints/:id/resume', () => {
    it('should set isPaused to false', async () => {
      const createRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });
      const { id } = createRes.json();

      await app.inject({
        method: 'POST',
        url: `/api/endpoints/${id}/pause`,
        headers: authHeader(accessToken),
      });

      const res = await app.inject({
        method: 'POST',
        url: `/api/endpoints/${id}/resume`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      expect(res.json().isPaused).toBe(false);
    });
  });

  describe('POST /endpoints/import', () => {
    it('should import endpoints from macOS JSON format', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/endpoints/import',
        headers: authHeader(accessToken),
        payload: [
          { name: 'Imported API', url: 'https://imported.example.com' },
          { name: 'Imported Web', url: 'https://imported-web.example.com' },
        ],
      });

      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({ created: 2, updated: 0 });

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
      });
      expect(listRes.json()).toHaveLength(2);
    });

    it('should return { created, updated } counts', async () => {
      const importRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints/import',
        headers: authHeader(accessToken),
        payload: [{ name: 'Imported API', url: 'https://imported.example.com' }],
      });
      expect(importRes.json()).toEqual({ created: 1, updated: 0 });

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
      });
      const [existing] = listRes.json();

      const updateRes = await app.inject({
        method: 'POST',
        url: '/api/endpoints/import',
        headers: authHeader(accessToken),
        payload: [{ id: existing.id, name: 'Imported API Renamed', url: 'https://imported.example.com' }],
      });

      expect(updateRes.json()).toEqual({ created: 0, updated: 1 });
    });

    it('should handle macOS field name mapping (group, checkIntervalOverride, bearerToken)', async () => {
      await app.inject({
        method: 'POST',
        url: '/api/endpoints/import',
        headers: authHeader(accessToken),
        payload: [
          {
            name: 'Mapped Endpoint',
            url: 'https://mapped.example.com',
            group: 'prod',
            checkIntervalOverride: 45,
            authType: 'bearerToken',
          },
        ],
      });

      const listRes = await app.inject({
        method: 'GET',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
      });
      const [endpoint] = listRes.json();

      expect(endpoint.groupName).toBe('prod');
      expect(endpoint.checkInterval).toBe(45);
      expect(endpoint.authType).toBe('bearer_token');
    });
  });

  describe('GET /endpoints/export', () => {
    it('should return all user endpoints as JSON array', async () => {
      await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'API', url: 'https://api.example.com' },
      });
      await app.inject({
        method: 'POST',
        url: '/api/endpoints',
        headers: authHeader(accessToken),
        payload: { name: 'Web', url: 'https://web.example.com' },
      });

      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints/export',
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(Array.isArray(body)).toBe(true);
      expect(body).toHaveLength(2);
    });
  });
});
