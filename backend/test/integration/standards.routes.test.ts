import { describe, it, expect, beforeEach, afterEach, afterAll, beforeAll, vi } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader } from '../helpers.js';
import { HEALTH_STANDARD_EXAMPLES, HEALTH_STANDARD_SCHEMA } from '../../src/modules/standards/health-standard.js';
import { fetchForValidation } from '../../src/modules/standards/standards.routes.js';
import { stopSSESubscriber } from '../../src/modules/sse/sse-bus.js';

function healthResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/health+json', 'Cache-Control': 'no-store', ...headers },
  });
}

describe('standards routes', () => {
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

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('GET /api/standards/health (public)', () => {
    it('returns the standard without auth', async () => {
      const res = await app.inject({ method: 'GET', url: '/api/standards/health' });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body).toMatchObject({ id: 'zext-health/v1', title: 'Zext Health Standard v1', mediaType: 'application/health+json' });
      expect(typeof body.summary).toBe('string');
      expect(body.rules.length).toBeGreaterThan(5);
      expect(body.rules[0]).toEqual({ id: expect.any(String), level: expect.stringMatching(/^(must|should)$/), text: expect.any(String) });
      expect(body.examples).toEqual(JSON.parse(JSON.stringify(HEALTH_STANDARD_EXAMPLES)));
      expect(body.schema).toEqual(JSON.parse(JSON.stringify(HEALTH_STANDARD_SCHEMA)));
    });

    it('serves the schema alone as application/schema+json', async () => {
      const res = await app.inject({ method: 'GET', url: '/api/standards/health/schema.json' });
      expect(res.statusCode).toBe(200);
      expect(res.headers['content-type']).toContain('application/schema+json');
      expect(res.json()).toEqual(JSON.parse(JSON.stringify(HEALTH_STANDARD_SCHEMA)));
    });
  });

  describe('POST /api/standards/health/validate', () => {
    async function validate(payload: unknown, token: string | null = accessToken) {
      return app.inject({
        method: 'POST',
        url: '/api/standards/health/validate',
        headers: token ? authHeader(token) : {},
        payload: payload as Record<string, unknown>,
      });
    }

    it('requires auth', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      const res = await validate({ url: 'https://service.test/health' }, null);
      expect(res.statusCode).toBe(401);
      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it.each([
      ['empty body', {}],
      ['non-http url', { url: 'ftp://service.test/health' }],
      ['not a url', { url: 'service.test/health' }],
      ['both modes', { url: 'https://service.test/health', response: { httpStatus: 200, body: '{}' } }],
      ['missing body', { response: { httpStatus: 200 } }],
      ['bad http status', { response: { httpStatus: 42, body: '{}' } }],
      ['unknown key', { response: { httpStatus: 200, body: '{}', extra: 1 } }],
    ])('400 for %s', async (_label, payload) => {
      const res = await validate(payload);
      expect(res.statusCode).toBe(400);
    });

    it('validates a pasted response without fetching', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      const res = await validate({
        response: { httpStatus: 200, contentType: 'application/json', body: '{"status":"ok","path":"/var/www/app"}' },
      });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.standard).toBe('zext-health/v1');
      expect(body.valid).toBe(false);
      expect(body.errors).toEqual([expect.objectContaining({ path: '/status', rule: 'status-field' })]);
      expect(body.warnings.map((w: { rule: string }) => w.rule)).toEqual(
        expect.arrayContaining(['content-type', 'version', 'release-id', 'no-sensitive-data']),
      );
      expect(body.observed).toEqual({ httpStatus: 200, contentType: 'application/json' });
      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it('accepts a pasted body that is already a JSON object', async () => {
      const res = await validate({ response: { httpStatus: 503, body: HEALTH_STANDARD_EXAMPLES.fail.body } });
      expect(res.json()).toMatchObject({ valid: true, errors: [], warnings: [], observed: { status: 'fail' } });
    });

    it('fetches a URL and validates headers, timing and body', async () => {
      const fetchSpy = vi
        .spyOn(globalThis, 'fetch')
        .mockResolvedValue(healthResponse(HEALTH_STANDARD_EXAMPLES.warn.body));
      const res = await validate({ url: 'https://service.test/health' });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body).toMatchObject({
        valid: true,
        errors: [],
        warnings: [],
        observed: {
          httpStatus: 200,
          contentType: 'application/health+json',
          status: 'warn',
          version: '1.4.2',
          releaseId: '9f2c1ab7e4d3',
        },
      });
      expect(typeof body.observed.responseTimeMs).toBe('number');
      expect(String(fetchSpy.mock.calls[0][0])).toBe('https://service.test/health');
      expect((fetchSpy.mock.calls[0][1] as RequestInit).redirect).toBe('manual');
    });

    it('reports missing headers and an HTTP mismatch from a fetched URL', async () => {
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response(JSON.stringify({ status: 'fail', version: '1', releaseId: 'a', output: 'x' }), { status: 200 }),
      );
      const body = (await validate({ url: 'http://service.test/health' })).json();
      expect(body.valid).toBe(false);
      expect(body.errors.map((e: { rule: string }) => e.rule)).toEqual(['http-status']);
      expect(body.warnings.map((w: { rule: string }) => w.rule)).toEqual(['content-type', 'cache-control']);
    });

    it('returns a fetch error instead of throwing when the URL is unreachable', async () => {
      vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('getaddrinfo ENOTFOUND service.test'));
      const res = await validate({ url: 'https://service.test/health' });
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({
        standard: 'zext-health/v1',
        valid: false,
        errors: [{ path: 'http', rule: 'fetch', message: 'Could not fetch the URL: getaddrinfo ENOTFOUND service.test' }],
        warnings: [],
        observed: { httpStatus: 0, contentType: null },
      });
    });

    it('rejects bodies over 256 KB', async () => {
      const huge = JSON.stringify({ status: 'pass', notes: ['x'.repeat(300 * 1024)] });
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(healthResponse(huge));
      const body = (await validate({ url: 'https://service.test/health' })).json();
      expect(body.valid).toBe(false);
      expect(body.errors).toEqual([expect.objectContaining({ rule: 'json-body', message: expect.stringContaining('256 KB') })]);
    });
  });

  describe('fetchForValidation()', () => {
    it('follows http(s) redirects manually', async () => {
      const fetchImpl = vi
        .fn<typeof fetch>()
        .mockResolvedValueOnce(new Response(null, { status: 301, headers: { Location: '/v2/health' } }))
        .mockResolvedValueOnce(healthResponse({ status: 'pass' }));
      const result = await fetchForValidation('https://service.test/health', fetchImpl);
      expect(result.httpStatus).toBe(200);
      expect(String(fetchImpl.mock.calls[1][0])).toBe('https://service.test/v2/health');
    });

    it('refuses redirects to non-http schemes', async () => {
      const fetchImpl = vi
        .fn<typeof fetch>()
        .mockResolvedValue(new Response(null, { status: 302, headers: { Location: 'file:///etc/passwd' } }));
      await expect(fetchForValidation('https://service.test/health', fetchImpl)).rejects.toThrow(/non-http/);
      expect(fetchImpl).toHaveBeenCalledTimes(1);
    });

    it('stops after too many redirects', async () => {
      const fetchImpl = vi
        .fn<typeof fetch>()
        .mockImplementation(async () => new Response(null, { status: 302, headers: { Location: '/again' } }));
      await expect(fetchForValidation('https://service.test/health', fetchImpl)).rejects.toThrow('Too many redirects');
    });
  });

  describe('GET /health (own health, standard format)', () => {
    it('passes with real postgres and redis', async () => {
      const res = await app.inject({ method: 'GET', url: '/health' });
      expect(res.statusCode).toBe(200);
      expect(res.headers['content-type']).toContain('application/health+json');
      expect(res.headers['cache-control']).toBe('no-store');
      const body = res.json();
      expect(body.status).toBe('pass');
      expect(body.version).toMatch(/^\d+\.\d+\.\d+/);
      // Public endpoint: no per-dependency details, only the overall status.
      expect(body).not.toHaveProperty('checks');
      expect(Object.keys(body).filter((key) => !['status', 'version', 'releaseId', 'serviceId'].includes(key))).toEqual([]);
    });

    it('returns 503 fail when a dependency is down', async () => {
      // buildApp() keeps a single module-level SSE subscriber; release the first app's one so the
      // second app's subscriber is the one closeApp() stops in afterAll.
      await stopSSESubscriber();
      const failing = await createApp({
        healthProbes: { postgres: () => Promise.resolve(), redis: () => Promise.reject(new Error('ECONNREFUSED')) },
      });
      try {
        const res = await failing.inject({ method: 'GET', url: '/health' });
        expect(res.statusCode).toBe(503);
        const body = res.json();
        expect(body).toMatchObject({ status: 'fail', output: 'redis unreachable' });
        expect(body).not.toHaveProperty('checks');
      } finally {
        await failing.close();
      }
    });
  });
});
