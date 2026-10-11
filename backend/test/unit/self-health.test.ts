import { describe, it, expect, vi } from 'vitest';
import {
  buildSelfHealth,
  createSelfHealthHandler,
  readPackageVersion,
  resolveReleaseId,
} from '../../src/modules/standards/self-health.js';
import { validateHealthResponse } from '../../src/modules/standards/health-standard-validator.js';

const ok = () => Promise.resolve();
const fixedNow = () => Date.parse('2026-10-11T09:30:00Z');

describe('buildSelfHealth()', () => {
  it('passes with every dependency up and conforms to the standard', async () => {
    const { httpStatus, body } = await buildSelfHealth({
      probes: { postgres: ok, redis: ok },
      version: '0.1.0',
      releaseId: 'abcdef1234',
      now: fixedNow,
    });
    expect(httpStatus).toBe(200);
    expect(body).toMatchObject({
      status: 'pass',
      version: '0.1.0',
      releaseId: 'abcdef1234',
      serviceId: 'health-monitor-api',
      checks: {
        'postgres:responseTime': [
          { componentType: 'datastore', status: 'pass', observedUnit: 'ms', time: '2026-10-11T09:30:00.000Z' },
        ],
        'redis:responseTime': [{ componentType: 'datastore', status: 'pass', observedUnit: 'ms' }],
      },
    });
    expect(body.output).toBeUndefined();

    const report = validateHealthResponse({ httpStatus, body });
    expect(report.errors).toEqual([]);
    expect(report.warnings).toEqual([]);
  });

  it('fails with 503 when a dependency throws, without leaking the error message', async () => {
    const { httpStatus, body } = await buildSelfHealth({
      probes: {
        postgres: () => Promise.reject(new Error('connect ECONNREFUSED 10.0.0.5:5432')),
        redis: ok,
      },
      version: '0.1.0',
      releaseId: null,
    });
    expect(httpStatus).toBe(503);
    expect(body.status).toBe('fail');
    expect(body.output).toBe('postgres unreachable');
    expect(body).not.toHaveProperty('releaseId');
    expect(JSON.stringify(body)).not.toContain('10.0.0.5');
    expect(validateHealthResponse({ httpStatus, body }).errors).toEqual([]);
  });

  it('fails a dependency that exceeds the probe timeout', async () => {
    vi.useFakeTimers();
    try {
      const pending = buildSelfHealth({ probes: { redis: () => new Promise(() => {}) }, version: null, releaseId: null });
      await vi.advanceTimersByTimeAsync(1000);
      const { httpStatus, body } = await pending;
      expect(httpStatus).toBe(503);
      expect(body.output).toBe('redis timed out');
    } finally {
      vi.useRealTimers();
    }
  });

  it('warns (still 200) when a dependency is slow', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'performance', 'Date'] });
    try {
      const slow = () => new Promise<void>((resolve) => setTimeout(resolve, 400));
      const pending = buildSelfHealth({ probes: { postgres: slow }, version: '1', releaseId: 'a' });
      await vi.advanceTimersByTimeAsync(400);
      const { httpStatus, body } = await pending;
      expect(httpStatus).toBe(200);
      expect(body.status).toBe('warn');
      expect(body.output).toBe('postgres is slow');
    } finally {
      vi.useRealTimers();
    }
  });
});

describe('createSelfHealthHandler()', () => {
  it('caches probe results for the TTL', async () => {
    let now = 0;
    const probe = vi.fn(ok);
    const handler = createSelfHealthHandler({ probes: { postgres: probe }, version: null, releaseId: null, now: () => now }, 10_000);

    await handler();
    await handler();
    expect(probe).toHaveBeenCalledTimes(1);

    now = 10_000;
    await handler();
    expect(probe).toHaveBeenCalledTimes(2);
  });
});

describe('version / releaseId sources', () => {
  it('reads the version from package.json', () => {
    expect(readPackageVersion()).toMatch(/^\d+\.\d+\.\d+/);
  });

  it('prefers RELEASE_ID, otherwise a git SHA or nothing', () => {
    expect(resolveReleaseId({ RELEASE_ID: ' build-42 ' })).toBe('build-42');
    const fallback = resolveReleaseId({});
    expect(fallback === null || /^[0-9a-f]{40}$/.test(fallback)).toBe(true);
  });
});
