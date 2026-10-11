import { describe, it, expect, beforeEach, afterAll, beforeAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { recordHealthDetails } from '../../src/modules/checks/health-standard-check.js';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader, inviteAndLogin } from '../helpers.js';

describe('endpoints routes: healthStandard', () => {
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
    accessToken = (await registerAndLogin(app)).accessToken;
  });

  async function create(payload: Record<string, unknown> = {}) {
    return app.inject({
      method: 'POST',
      url: '/api/endpoints',
      headers: authHeader(accessToken),
      payload: { name: 'API', url: 'https://api.example.com/health', ...payload },
    });
  }

  it('defaults to false and accepts true on create', async () => {
    expect((await create()).json().healthStandard).toBe(false);
    const res = await create({ healthStandard: true });
    expect(res.statusCode).toBe(201);
    expect(res.json().healthStandard).toBe(true);
  });

  it('rejects a non-boolean value', async () => {
    expect((await create({ healthStandard: 'yes' })).statusCode).toBe(400);
  });

  it('can be toggled on update without touching other fields', async () => {
    const created = (await create({ expectedStatusCode: 204 })).json();
    const on = await app.inject({
      method: 'PUT',
      url: `/api/endpoints/${created.id}`,
      headers: authHeader(accessToken),
      payload: { healthStandard: true },
    });
    expect(on.json()).toMatchObject({ healthStandard: true, expectedStatusCode: 204 });

    const rename = await app.inject({
      method: 'PUT',
      url: `/api/endpoints/${created.id}`,
      headers: authHeader(accessToken),
      payload: { name: 'Renamed' },
    });
    expect(rename.json().healthStandard).toBe(true); // omitted on update = unchanged
  });

  it('imports the macOS shape and exports the flag', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/api/endpoints/import',
      headers: authHeader(accessToken),
      payload: [
        { name: 'Standard', url: 'https://a.example.com/health', healthStandard: true },
        { name: 'Legacy', url: 'https://b.example.com/health' },
      ],
    });
    expect(res.json()).toEqual({ created: 2, updated: 0 });

    const exported = await app.inject({ method: 'GET', url: '/api/endpoints/export', headers: authHeader(accessToken) });
    const byName = Object.fromEntries(exported.json().map((e: { name: string; healthStandard: boolean }) => [e.name, e.healthStandard]));
    expect(byName).toEqual({ Standard: true, Legacy: false });
  });

  describe('GET /endpoints/:id/health-details', () => {
    it('returns null details until a standard response has been parsed', async () => {
      const created = (await create({ healthStandard: true })).json();
      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${created.id}/health-details`,
        headers: authHeader(accessToken),
      });
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({ healthStandard: true, latest: null });
    });

    it('returns the latest components', async () => {
      const created = (await create({ healthStandard: true })).json();
      await recordHealthDetails(
        created.id,
        {
          status: 'warn',
          version: '1.0',
          releaseId: 'abc',
          output: 'Disk',
          components: [{ key: 'disk:utilization', status: 'warn', observedValue: 91, observedUnit: 'percent' }],
        },
        new Date('2026-10-11T09:30:00Z'),
      );

      const res = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${created.id}/health-details`,
        headers: authHeader(accessToken),
      });
      expect(res.json()).toEqual({
        healthStandard: true,
        latest: {
          status: 'warn',
          version: '1.0',
          releaseId: 'abc',
          output: 'Disk',
          checkedAt: '2026-10-11T09:30:00.000Z',
          components: [{ key: 'disk:utilization', status: 'warn', observedValue: 91, observedUnit: 'percent' }],
        },
      });
    });

    it('requires auth and ownership', async () => {
      const created = (await create({ healthStandard: true })).json();
      const anonymous = await app.inject({ method: 'GET', url: `/api/endpoints/${created.id}/health-details` });
      expect(anonymous.statusCode).toBe(401);

      const other = await inviteAndLogin(app, accessToken, 'other@test.com');
      const foreign = await app.inject({
        method: 'GET',
        url: `/api/endpoints/${created.id}/health-details`,
        headers: authHeader(other.accessToken),
      });
      expect(foreign.statusCode).toBe(404);
    });

    it('400 for a non-uuid id', async () => {
      const res = await app.inject({
        method: 'GET',
        url: '/api/endpoints/not-a-uuid/health-details',
        headers: authHeader(accessToken),
      });
      expect(res.statusCode).toBe(400);
    });
  });
});
