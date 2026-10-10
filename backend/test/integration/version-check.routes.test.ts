import { describe, it, expect, beforeEach, afterAll, beforeAll } from 'vitest';
import { eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { db } from '../../src/db/index.js';
import { endpointVersionSecrets, endpointVersionState } from '../../src/db/schema.js';
import { incrementVersionCheckCounter, recordVersionResult } from '../../src/modules/checks/version-check.js';
import { decrypt } from '../../src/utils/crypto.js';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader, inviteAndLogin } from '../helpers.js';

const versionCheck = {
  url: 'https://api.example.com/version',
  versionFieldPath: 'data.version',
};

describe('version check routes', () => {
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

  async function createEndpoint(payload: Record<string, unknown> = {}) {
    return app.inject({
      method: 'POST',
      url: '/api/endpoints',
      headers: authHeader(accessToken),
      payload: { name: 'API', url: 'https://api.example.com/health', ...payload },
    });
  }

  async function versionSecretFor(endpointId: string) {
    return db.query.endpointVersionSecrets.findFirst({ where: eq(endpointVersionSecrets.endpointId, endpointId) });
  }

  describe('POST /endpoints with versionCheck', () => {
    it('applies defaults and never returns the version secret', async () => {
      const res = await createEndpoint({
        versionCheck: { ...versionCheck, authType: 'bearer_token' },
        versionAuthSecret: 'version-token',
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body.versionCheck).toEqual({
        isEnabled: true,
        url: 'https://api.example.com/version',
        everyNChecks: 5,
        versionFieldPath: 'data.version',
        assertions: [],
        authType: 'bearer_token',
        authUsername: null,
        authHeaderName: null,
      });
      expect(JSON.stringify(body)).not.toContain('version-token');

      const secret = await versionSecretFor(body.id);
      expect(secret).toBeDefined();
      expect(decrypt(secret!.encryptedValue, secret!.iv)).toBe('version-token');
    });

    it('defaults to no version check', async () => {
      const res = await createEndpoint();
      expect(res.json().versionCheck).toBeNull();
    });

    it.each([
      ['non-http url', { ...versionCheck, url: 'ftp://api.example.com/v' }],
      ['missing field path', { ...versionCheck, versionFieldPath: '  ' }],
      ['everyNChecks below 1', { ...versionCheck, everyNChecks: 0 }],
      ['everyNChecks above 1000', { ...versionCheck, everyNChecks: 1001 }],
    ])('rejects %s (400)', async (_label, invalid) => {
      const res = await createEndpoint({ versionCheck: invalid });
      expect(res.statusCode).toBe(400);
    });
  });

  describe('PUT /endpoints/:id with versionCheck', () => {
    it('removing the version check deletes its secret', async () => {
      const created = await createEndpoint({
        versionCheck: { ...versionCheck, authType: 'bearer_token' },
        versionAuthSecret: 'version-token',
      });
      const { id } = created.json();

      const res = await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
        payload: { versionCheck: null },
      });

      expect(res.statusCode).toBe(200);
      expect(res.json().versionCheck).toBeNull();
      expect(await versionSecretFor(id)).toBeUndefined();
    });

    it('switching version auth to none deletes its secret', async () => {
      const created = await createEndpoint({
        versionCheck: { ...versionCheck, authType: 'bearer_token' },
        versionAuthSecret: 'version-token',
      });
      const { id } = created.json();

      await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
        payload: { versionCheck: { ...versionCheck, authType: 'none' } },
      });

      expect(await versionSecretFor(id)).toBeUndefined();
    });

    it('updating unrelated fields keeps the version secret', async () => {
      const created = await createEndpoint({
        versionCheck: { ...versionCheck, authType: 'bearer_token' },
        versionAuthSecret: 'version-token',
      });
      const { id } = created.json();

      await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
        payload: { name: 'Renamed' },
      });

      expect(await versionSecretFor(id)).toBeDefined();
    });

    it('changing the config resets the cadence counter; unrelated updates do not', async () => {
      const created = await createEndpoint({ versionCheck });
      const { id } = created.json();
      await incrementVersionCheckCounter(id);
      await incrementVersionCheckCounter(id);

      await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
        payload: { name: 'Renamed' },
      });
      let state = await db.query.endpointVersionState.findFirst({ where: eq(endpointVersionState.endpointId, id) });
      expect(state?.checkCounter).toBe(2);

      await app.inject({
        method: 'PUT',
        url: `/api/endpoints/${id}`,
        headers: authHeader(accessToken),
        payload: { versionCheck: { ...versionCheck, everyNChecks: 10 } },
      });
      state = await db.query.endpointVersionState.findFirst({ where: eq(endpointVersionState.endpointId, id) });
      expect(state?.checkCounter).toBe(0);
    });
  });

  describe('GET /endpoints/:id/versions', () => {
    it('returns current state and newest-first history', async () => {
      const { id } = (await createEndpoint({ versionCheck })).json();
      const ok = { isSuccess: true, failureReason: null, statusCode: 200, responseTimeMs: 5 };
      await recordVersionResult(id, { ...ok, version: '1.0' }, new Date('2026-10-01T10:00:00Z'));
      await recordVersionResult(id, { ...ok, version: '1.1' }, new Date('2026-10-02T10:00:00Z'));

      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${id}/versions`,
        headers: authHeader(accessToken),
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.current).toMatchObject({ version: '1.1', isFailing: false });
      expect(body.history.map((entry: { value: string }) => entry.value)).toEqual(['1.1', '1.0']);
    });

    it('returns an empty result before any version check ran', async () => {
      const { id } = (await createEndpoint({ versionCheck })).json();
      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${id}/versions`,
        headers: authHeader(accessToken),
      });
      expect(res.json()).toEqual({ current: null, history: [] });
    });

    it("returns 404 for another user's endpoint", async () => {
      const { id } = (await createEndpoint({ versionCheck })).json();
      const other = await inviteAndLogin(app, accessToken, 'other@test.com');

      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${id}/versions`,
        headers: authHeader(other.accessToken),
      });
      expect(res.statusCode).toBe(404);
    });
  });

  describe('POST /endpoints/import with versionCheck', () => {
    it('maps the macOS export shape', async () => {
      await app.inject({
        method: 'POST',
        url: '/api/endpoints/import',
        headers: authHeader(accessToken),
        payload: [
          {
            name: 'From Mac',
            url: 'https://mac.example.com/health',
            versionCheck: {
              isEnabled: false,
              url: 'https://mac.example.com/version',
              everyNChecks: 3,
              versionFieldPath: 'build.version',
              assertions: [{ path: 'env', expectedValue: 'prod' }],
              authType: 'customHeader',
              authHeaderName: 'X-Key',
            },
          },
        ],
      });

      const [endpoint] = (
        await app.inject({ method: 'GET', url: '/api/endpoints', headers: authHeader(accessToken) })
      ).json();
      expect(endpoint.versionCheck).toEqual({
        isEnabled: false,
        url: 'https://mac.example.com/version',
        everyNChecks: 3,
        versionFieldPath: 'build.version',
        assertions: [{ path: 'env', expectedValue: 'prod', matchMode: 'exact' }],
        authType: 'custom_header',
        authUsername: null,
        authHeaderName: 'X-Key',
      });
    });
  });

  describe('GET /dashboard version summary', () => {
    it('includes the latest version and failure state', async () => {
      const { id } = (await createEndpoint({ versionCheck })).json();
      await createEndpoint({ name: 'Plain' });
      await recordVersionResult(id, {
        isSuccess: false,
        version: '2.0.0',
        failureReason: 'Assertion failed',
        statusCode: 200,
        responseTimeMs: 5,
      });

      const res = await app.inject({ method: 'GET', url: '/api/dashboard', headers: authHeader(accessToken) });
      const byName = Object.fromEntries(
        res.json().endpoints.map((endpoint: { name: string; version: unknown }) => [endpoint.name, endpoint.version]),
      );
      expect(byName.API).toMatchObject({
        isEnabled: true,
        current: '2.0.0',
        isFailing: true,
        failureReason: 'Assertion failed',
      });
      expect(byName.Plain).toBeNull();
    });
  });

  describe('notification preferences', () => {
    it('defaults notifyOnVersionChange to true and persists updates', async () => {
      const defaults = await app.inject({
        method: 'GET',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
      });
      expect(defaults.json().notifyOnVersionChange).toBe(true);

      await app.inject({
        method: 'PUT',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
        payload: { notifyOnVersionChange: false },
      });
      const saved = await app.inject({
        method: 'GET',
        url: '/api/notifications/preferences',
        headers: authHeader(accessToken),
      });
      expect(saved.json().notifyOnVersionChange).toBe(false);
      expect(saved.json().notifyOnDown).toBe(true);
    });
  });
});
