import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import {
  users,
  endpoints,
  endpointVersionSecrets,
  endpointVersionState,
  versionHistory,
  notificationPreferences,
  pushSubscriptions,
} from '../../src/db/schema.js';
import type { VersionCheckConfig } from '../../src/db/schema.js';
import { encrypt } from '../../src/utils/crypto.js';
import {
  incrementVersionCheckCounter,
  resetVersionCheckCounter,
  recordVersionResult,
  getVersionHistory,
  runVersionCheckIfDue,
  type VersionCheckOutcome,
} from '../../src/modules/checks/version-check.js';

const versionConfig: VersionCheckConfig = {
  isEnabled: true,
  url: 'https://version.example.com/v',
  everyNChecks: 5,
  versionFieldPath: 'version',
  assertions: [],
  authType: 'none',
  authUsername: null,
  authHeaderName: null,
};

async function createUser(email = 'version-owner@test.com') {
  const [user] = await db.insert(users).values({ email, passwordHash: 'hash', name: 'Owner', role: 'admin' }).returning();
  return user;
}

async function createEndpoint(userId: string, versionCheck: VersionCheckConfig | null = versionConfig) {
  const [endpoint] = await db
    .insert(endpoints)
    .values({ userId, name: 'Versioned', url: 'https://example.com/health', versionCheck })
    .returning();
  return endpoint;
}

function success(version: string): VersionCheckOutcome {
  return { isSuccess: true, version, failureReason: null, statusCode: 200, responseTimeMs: 10 };
}

function failure(reason: string, version: string | null = null): VersionCheckOutcome {
  return { isSuccess: false, version, failureReason: reason, statusCode: null, responseTimeMs: null };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

beforeEach(async () => {
  await db.execute(sql`TRUNCATE TABLE ${endpoints}, ${users} RESTART IDENTITY CASCADE`);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('version check counter', () => {
  it('starts at 1 and increments per call', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);
    expect(await incrementVersionCheckCounter(endpoint.id)).toBe(1);
    expect(await incrementVersionCheckCounter(endpoint.id)).toBe(2);
  });

  it('reset makes the next check count as the first', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);
    await incrementVersionCheckCounter(endpoint.id);
    await incrementVersionCheckCounter(endpoint.id);
    await resetVersionCheckCounter(endpoint.id);
    expect(await incrementVersionCheckCounter(endpoint.id)).toBe(1);
  });
});

describe('recordVersionResult()', () => {
  it('collapses repeated versions and appends changes', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    expect(await recordVersionResult(endpoint.id, success('1.0'), new Date('2026-10-01T10:00:00Z'))).toEqual([]);
    expect(await recordVersionResult(endpoint.id, success('1.0'), new Date('2026-10-01T11:00:00Z'))).toEqual([]);
    expect(await recordVersionResult(endpoint.id, success('1.1'), new Date('2026-10-01T12:00:00Z'))).toEqual([
      { type: 'changed', from: '1.0', to: '1.1' },
    ]);

    const history = await getVersionHistory(endpoint.id);
    expect(history.history).toEqual([
      { value: '1.1', firstSeenAt: '2026-10-01T12:00:00.000Z', lastSeenAt: '2026-10-01T12:00:00.000Z' },
      { value: '1.0', firstSeenAt: '2026-10-01T10:00:00.000Z', lastSeenAt: '2026-10-01T11:00:00.000Z' },
    ]);
    expect(history.current).toEqual({
      version: '1.1',
      isFailing: false,
      failureReason: null,
      lastCheckedAt: '2026-10-01T12:00:00.000Z',
    });
  });

  it('notifies failure once and keeps the last known version', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    await recordVersionResult(endpoint.id, success('1.0'), new Date('2026-10-01T10:00:00Z'));
    expect(await recordVersionResult(endpoint.id, failure('Timed out'), new Date('2026-10-01T11:00:00Z'))).toEqual([
      { type: 'failed', reason: 'Timed out' },
    ]);
    expect(await recordVersionResult(endpoint.id, failure('Timed out'), new Date('2026-10-01T12:00:00Z'))).toEqual([]);

    const history = await getVersionHistory(endpoint.id);
    expect(history.current).toMatchObject({ version: '1.0', isFailing: true, failureReason: 'Timed out' });

    expect(await recordVersionResult(endpoint.id, success('2.0'), new Date('2026-10-01T13:00:00Z'))).toEqual([
      { type: 'recovered' },
      { type: 'changed', from: '1.0', to: '2.0' },
    ]);
  });

  it('caps history per endpoint, keeping the newest entries', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    for (let i = 0; i < 6; i += 1) {
      await recordVersionResult(endpoint.id, success(`v${i}`), new Date(Date.UTC(2026, 9, 1, i)), 4);
    }

    const rows = await db.select().from(versionHistory).where(eq(versionHistory.endpointId, endpoint.id));
    expect(rows.map((row) => row.value).sort()).toEqual(['v2', 'v3', 'v4', 'v5']);
  });

  it('is removed together with its endpoint', async () => {
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);
    await recordVersionResult(endpoint.id, success('1.0'));
    await db.delete(endpoints).where(eq(endpoints.id, endpoint.id));

    expect(await db.select().from(versionHistory)).toHaveLength(0);
    expect(await db.select().from(endpointVersionState)).toHaveLength(0);
  });
});

describe('runVersionCheckIfDue()', () => {
  it('does nothing without an enabled version check', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const user = await createUser();
    const noConfig = await createEndpoint(user.id, null);
    const disabled = await createEndpoint(user.id, { ...versionConfig, isEnabled: false });

    expect(await runVersionCheckIfDue(noConfig)).toEqual([]);
    expect(await runVersionCheckIfDue(disabled)).toEqual([]);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('fetches on the 1st and every Nth health check only', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => jsonResponse({ version: '1.0' }));
    const user = await createUser();
    const endpoint = await createEndpoint(user.id, { ...versionConfig, everyNChecks: 3 });

    for (let i = 0; i < 7; i += 1) {
      await runVersionCheckIfDue(endpoint);
    }

    // checks 1, 4, 7
    expect(fetchSpy).toHaveBeenCalledTimes(3);
    expect(fetchSpy.mock.calls[0][0]).toBe('https://version.example.com/v');
  });

  it('sends the decrypted version secret with the configured auth', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => jsonResponse({ version: '1.0' }));
    const user = await createUser();
    const endpoint = await createEndpoint(user.id, {
      ...versionConfig,
      authType: 'custom_header',
      authHeaderName: 'X-Version-Key',
    });
    const { encrypted, iv } = encrypt('version-secret');
    await db.insert(endpointVersionSecrets).values({ endpointId: endpoint.id, encryptedValue: encrypted, iv });

    await runVersionCheckIfDue(endpoint);

    const init = fetchSpy.mock.calls[0][1] as RequestInit;
    expect(init.headers).toEqual({ 'X-Version-Key': 'version-secret' });
  });

  it('records an unreachable version URL as a failure without throwing', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('getaddrinfo ENOTFOUND'));
    const user = await createUser();
    const endpoint = await createEndpoint(user.id);

    await expect(runVersionCheckIfDue(endpoint)).resolves.toEqual([]);
    const history = await getVersionHistory(endpoint.id);
    expect(history.current).toMatchObject({ isFailing: true, failureReason: 'getaddrinfo ENOTFOUND', version: null });
  });

  it('pushes a version change notification, honouring the user preference', async () => {
    let version = '1.0';
    const pushes: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      if (String(input).startsWith('https://exp.host')) {
        pushes.push(JSON.parse(String(init?.body)).body);
        return jsonResponse({ data: { status: 'ok' } });
      }
      return jsonResponse({ version });
    });
    const user = await createUser();
    const endpoint = await createEndpoint(user.id, { ...versionConfig, everyNChecks: 1 });
    await db.insert(pushSubscriptions).values({ userId: user.id, platform: 'fcm', token: 'ExponentPushToken[test]' });

    await runVersionCheckIfDue(endpoint);
    version = '1.1';
    expect(await runVersionCheckIfDue(endpoint)).toEqual([{ type: 'changed', from: '1.0', to: '1.1' }]);
    expect(pushes).toEqual(['Versioned: 1.0 → 1.1']);

    await db.insert(notificationPreferences).values({ userId: user.id, notifyOnVersionChange: false });
    version = '1.2';
    await runVersionCheckIfDue(endpoint);
    expect(pushes).toHaveLength(1);
  });
});
