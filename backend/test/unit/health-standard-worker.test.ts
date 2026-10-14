import { describe, it, expect, beforeEach, afterEach, afterAll, vi } from 'vitest';
import { desc, eq, sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import {
  users,
  endpoints,
  healthCheckResults,
  dailyStats,
  incidents,
  endpointHealthState,
  pushSubscriptions,
  notificationPreferences,
  versionHistory,
} from '../../src/db/schema.js';
import type { VersionCheckConfig } from '../../src/db/schema.js';
import { runCheckForEndpoint, stopWorker } from '../../src/modules/checks/checks.worker.js';
import { getVersionHistory } from '../../src/modules/checks/version-check.js';
import { getHealthDetails } from '../../src/modules/checks/health-standard-check.js';
import { getDashboard } from '../../src/modules/dashboard/dashboard.service.js';

const HEALTH_URL = 'http://service.test/health';

let healthBody: unknown = { status: 'pass' };
let healthStatus = 200;
let versionBody: unknown = { version: '9.9.9' };
let pushes: Array<{ title: string; body: string }> = [];

function jsonResponse(body: unknown, status = 200, contentType = 'application/health+json'): Response {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': contentType },
  });
}

async function createUser() {
  const [user] = await db
    .insert(users)
    .values({ email: 'standard-owner@test.com', passwordHash: 'hash', name: 'Owner', role: 'admin' })
    .returning();
  await db.insert(pushSubscriptions).values({ userId: user.id, platform: 'fcm', token: 'ExponentPushToken[test]' });
  return user;
}

async function createEndpoint(userId: string, overrides: Partial<typeof endpoints.$inferInsert> = {}) {
  const [endpoint] = await db
    .insert(endpoints)
    .values({ userId, name: 'Billing', url: HEALTH_URL, healthStandard: true, ...overrides })
    .returning();
  return endpoint;
}

async function latestResult(endpointId: string) {
  return db.query.healthCheckResults.findFirst({
    where: eq(healthCheckResults.endpointId, endpointId),
    orderBy: [desc(healthCheckResults.timestamp)],
  });
}

async function check(endpointId: string, body: unknown, status = 200) {
  healthBody = body;
  healthStatus = status;
  await runCheckForEndpoint(endpointId);
  return latestResult(endpointId);
}

beforeEach(async () => {
  await db.execute(sql`TRUNCATE TABLE ${endpoints}, ${users} RESTART IDENTITY CASCADE`);
  pushes = [];
  healthBody = { status: 'pass' };
  healthStatus = 200;
  versionBody = { version: '9.9.9' };
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = String(input);
    if (url.startsWith('https://exp.host')) {
      const payload = JSON.parse(String(init?.body));
      pushes.push({ title: payload.title, body: payload.body });
      return jsonResponse({ data: { status: 'ok' } }, 200, 'application/json');
    }
    if (url === 'http://version.test/v') {
      return jsonResponse(versionBody, 200, 'application/json');
    }
    return jsonResponse(healthBody, healthStatus);
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

afterAll(async () => {
  await stopWorker();
});

describe('worker: health-standard endpoints', () => {
  it('migration adds health_standard (default false) and a nullable health_status', async () => {
    const user = await createUser();
    const [plain] = await db.insert(endpoints).values({ userId: user.id, name: 'Plain', url: HEALTH_URL }).returning();
    expect(plain.healthStandard).toBe(false);
    const [row] = await db.insert(healthCheckResults).values({ endpointId: plain.id, isHealthy: true }).returning();
    expect(row.healthStatus).toBeNull();
  });

  it('pass: healthy, stores the report and auto-tracks the version; a legacy "checks" block is ignored', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id, { expectedStatusCode: 204 }); // ignored for the standard

    const result = await check(endpoint.id, {
      status: 'pass',
      version: '1.4.2',
      releaseId: '9f2c1ab7e4d3',
      checks: { 'postgres:responseTime': [{ status: 'fail', observedValue: 12, observedUnit: 'ms' }] },
    });

    expect(result).toMatchObject({ isHealthy: true, healthStatus: 'pass', statusCode: 200, failureReason: null });
    expect(await getHealthDetails(endpoint.id)).toEqual({
      status: 'pass',
      version: '1.4.2',
      releaseId: '9f2c1ab7e4d3',
      output: null,
      checkedAt: expect.any(String),
      components: [],
    });
    const [stored] = await db.select().from(endpointHealthState).where(eq(endpointHealthState.endpointId, endpoint.id));
    expect(stored.components).toEqual([]); // nothing from the response is persisted per component
    const versions = await getVersionHistory(endpoint.id);
    expect(versions.current).toMatchObject({ version: '1.4.2 (9f2c1ab)', isFailing: false });
    expect(pushes).toEqual([]);
  });

  it('warn: up but degraded — no incident, no downtime, reason from output', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    const result = await check(endpoint.id, { status: 'warn', output: 'Disk usage above 85%' });

    expect(result).toMatchObject({ isHealthy: true, healthStatus: 'warn', failureReason: 'Disk usage above 85%' });
    const [stats] = await db.select().from(dailyStats).where(eq(dailyStats.endpointId, endpoint.id));
    expect(stats).toMatchObject({ totalChecks: 1, downChecks: 0 });
    expect(await db.select().from(incidents).where(eq(incidents.endpointId, endpoint.id))).toHaveLength(0);
    expect(pushes).toEqual([]); // the very first result never sends a degraded notification
  });

  it('fail (503): down with an incident and the reason from output', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    const result = await check(endpoint.id, { status: 'fail', output: 'Database unreachable' }, 503);

    expect(result).toMatchObject({
      isHealthy: false,
      healthStatus: 'fail',
      statusCode: 503,
      failureReason: 'Database unreachable',
    });
    expect(await db.select().from(incidents).where(eq(incidents.endpointId, endpoint.id))).toHaveLength(1);
    expect(pushes.map((push) => push.title)).toEqual(['🔴 Endpoint Down']);
  });

  it('invalid bodies and unexpected HTTP statuses are down and store no details', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    expect(await check(endpoint.id, { status: 'ok' })).toMatchObject({
      isHealthy: false,
      healthStatus: null,
      failureReason: 'Invalid health response: invalid status "ok"',
    });
    expect(await check(endpoint.id, 'not json')).toMatchObject({
      failureReason: 'Invalid health response: body is not valid JSON',
    });
    expect(await check(endpoint.id, { status: 'pass' }, 500)).toMatchObject({
      isHealthy: false,
      failureReason: 'Unexpected HTTP 500',
    });
    expect(await getHealthDetails(endpoint.id)).toBeNull();
  });

  it('JSON assertions still apply on top of a passing body', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id, {
      jsonAssertions: [{ path: 'serviceId', expectedValue: 'billing', matchMode: 'exact' }],
    });

    expect(await check(endpoint.id, { status: 'pass', serviceId: 'billing' })).toMatchObject({ isHealthy: true });
    expect(await check(endpoint.id, { status: 'pass', serviceId: 'search' })).toMatchObject({
      isHealthy: false,
      healthStatus: 'pass',
      failureReason: 'Assertion failed: "serviceId" did not match "billing"',
    });
  });

  it('notifies on healthy ↔ degraded and degraded ↔ down transitions', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    await check(endpoint.id, { status: 'pass' });
    await check(endpoint.id, { status: 'warn', output: 'Queue backlog' });
    await check(endpoint.id, { status: 'warn', output: 'Queue backlog' }); // no repeat
    await check(endpoint.id, { status: 'pass' });
    await check(endpoint.id, { status: 'warn', output: 'Queue backlog' });
    await check(endpoint.id, { status: 'fail', output: 'Queue dead' }, 503);
    await check(endpoint.id, { status: 'warn', output: 'Queue backlog' });

    expect(pushes).toEqual([
      { title: '🟠 Endpoint Degraded', body: 'Billing reports warn. Queue backlog' },
      { title: '🟢 Endpoint Healthy', body: 'Billing is no longer degraded.' },
      { title: '🟠 Endpoint Degraded', body: 'Billing reports warn. Queue backlog' },
      { title: '🔴 Endpoint Down', body: 'Billing is unreachable. Queue dead' },
      { title: '🟢 Endpoint Recovered', body: 'Billing is back online but degraded. Queue backlog' },
    ]);
  });

  it('gates degraded notifications by notifyOnDown and its recovery by notifyOnRecovery', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);
    await db.insert(notificationPreferences).values({ userId: user.id, notifyOnDown: false, notifyOnRecovery: true });

    await check(endpoint.id, { status: 'pass' });
    await check(endpoint.id, { status: 'warn' });
    await check(endpoint.id, { status: 'pass' });

    expect(pushes.map((push) => push.title)).toEqual(['🟢 Endpoint Healthy']);
  });

  it('keeps only the latest report per endpoint', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    await check(endpoint.id, { status: 'pass', version: '1.0.0' });
    await check(endpoint.id, { status: 'warn', version: '1.0.1', output: 'Cache unavailable' });

    const rows = await db.select().from(endpointHealthState).where(eq(endpointHealthState.endpointId, endpoint.id));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ status: 'warn', version: '1.0.1', output: 'Cache unavailable', components: [] });
  });

  it('auto version: records changes and notifies, skips responses without a version', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    await check(endpoint.id, { status: 'pass', version: '1.0.0' });
    await check(endpoint.id, { status: 'pass' });
    await check(endpoint.id, { status: 'pass', version: '1.1.0', releaseId: 'abcdef0123' });

    const history = await getVersionHistory(endpoint.id);
    expect(history.history.map((entry) => entry.value)).toEqual(['1.1.0 (abcdef0)', '1.0.0']);
    expect(pushes).toEqual([{ title: '🔄 Version Changed', body: 'Billing: 1.0.0 → 1.1.0 (abcdef0)' }]);
  });

  it('an enabled explicit version check wins over auto tracking', async () => {
    const user = await createUser();
    const versionCheck: VersionCheckConfig = {
      isEnabled: true,
      url: 'http://version.test/v',
      everyNChecks: 1,
      versionFieldPath: 'version',
      assertions: [],
      authType: 'none',
      authUsername: null,
      authHeaderName: null,
    };
    const endpoint = await createEndpoint(user.id, { versionCheck });

    await check(endpoint.id, { status: 'pass', version: '1.0.0' });

    const rows = await db.select().from(versionHistory).where(eq(versionHistory.endpointId, endpoint.id));
    expect(rows.map((row) => row.value)).toEqual(['9.9.9']);
  });

  it('non-standard endpoints are untouched', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id, { healthStandard: false });

    const result = await check(endpoint.id, { status: 'fail', version: '1.0.0' }, 200);

    expect(result).toMatchObject({ isHealthy: true, healthStatus: null });
    expect(await getHealthDetails(endpoint.id)).toBeNull();
    expect((await getVersionHistory(endpoint.id)).history).toEqual([]);
  });

  it('dashboard exposes healthStatus, degraded counts, details and the auto version', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);
    await createEndpoint(user.id, { name: 'Plain', healthStandard: false });

    await check(endpoint.id, { status: 'warn', version: '2.0.0', output: 'Slow' });

    const dashboard = await getDashboard(user.id);
    expect(dashboard.summary).toMatchObject({ healthyEndpoints: 1, degradedEndpoints: 1, unhealthyEndpoints: 0 });
    const standard = dashboard.endpoints.find((entry) => entry.id === endpoint.id)!;
    expect(standard.healthStandard).toBe(true);
    expect(standard.latestCheck).toMatchObject({ isHealthy: true, healthStatus: 'warn', isDegraded: true, failureReason: 'Slow' });
    expect(standard.healthDetails).toMatchObject({
      status: 'warn',
      version: '2.0.0',
      output: 'Slow',
      components: [],
    });
    expect(standard.version).toMatchObject({ isEnabled: true, current: '2.0.0', source: 'healthStandard' });

    const plain = dashboard.endpoints.find((entry) => entry.name === 'Plain')!;
    expect(plain.healthStandard).toBe(false);
    expect(plain.healthDetails).toBeNull();
    expect(plain.version).toBeNull();
  });
});
