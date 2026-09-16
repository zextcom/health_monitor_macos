import { describe, it, expect, beforeEach } from 'vitest';
import { sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import {
  users,
  endpoints,
  healthCheckResults,
  incidents,
  dailyStats,
} from '../../src/db/schema.js';
import { getDashboard } from '../../src/modules/dashboard/dashboard.service.js';

async function createTestUser(email = 'dash@test.com') {
  const [user] = await db
    .insert(users)
    .values({ email, passwordHash: 'hash', name: 'Dash User', role: 'admin' })
    .returning();
  return user;
}

async function createTestEndpoint(userId: string, overrides: Partial<typeof endpoints.$inferInsert> = {}) {
  const [endpoint] = await db
    .insert(endpoints)
    .values({
      userId,
      name: 'Endpoint',
      url: 'https://example.com',
      ...overrides,
    })
    .returning();
  return endpoint;
}

function todayStr(): string {
  return new Date().toISOString().slice(0, 10);
}

beforeEach(async () => {
  await db.execute(
    sql`TRUNCATE TABLE ${healthCheckResults}, ${incidents}, ${dailyStats}, ${endpoints}, ${users} RESTART IDENTITY CASCADE`,
  );
});

describe('dashboard.service', () => {
  describe('getDashboard()', () => {
    it('should return empty dashboard for user with no endpoints', async () => {
      const user = await createTestUser();
      const dashboard = await getDashboard(user.id);

      expect(dashboard.summary.totalEndpoints).toBe(0);
      expect(dashboard.summary.healthyEndpoints).toBe(0);
      expect(dashboard.summary.unhealthyEndpoints).toBe(0);
      expect(dashboard.summary.pausedEndpoints).toBe(0);
      expect(dashboard.summary.overallUptimePercent).toBe(100);
      expect(dashboard.endpoints).toEqual([]);
    });

    it('should count healthy/unhealthy/paused endpoints correctly', async () => {
      const user = await createTestUser();
      const healthy = await createTestEndpoint(user.id, { name: 'Healthy' });
      const unhealthy = await createTestEndpoint(user.id, { name: 'Unhealthy' });
      const paused = await createTestEndpoint(user.id, { name: 'Paused', isPaused: true });

      await db.insert(healthCheckResults).values([
        { endpointId: healthy.id, isHealthy: true, statusCode: 200 },
        { endpointId: unhealthy.id, isHealthy: false, statusCode: 500, failureReason: 'boom' },
      ]);

      const dashboard = await getDashboard(user.id);
      expect(dashboard.summary.totalEndpoints).toBe(3);
      expect(dashboard.summary.healthyEndpoints).toBe(1);
      expect(dashboard.summary.unhealthyEndpoints).toBe(1);
      expect(dashboard.summary.pausedEndpoints).toBe(1);
      void paused;
    });

    it('should include latest check result per endpoint', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(healthCheckResults).values({
        endpointId: endpoint.id,
        isHealthy: false,
        statusCode: 500,
        failureReason: 'old failure',
        timestamp: new Date(Date.now() - 60_000),
      });
      await db.insert(healthCheckResults).values({
        endpointId: endpoint.id,
        isHealthy: true,
        statusCode: 200,
        responseTimeMs: 123,
        timestamp: new Date(),
      });

      const dashboard = await getDashboard(user.id);
      const dashEndpoint = dashboard.endpoints.find((e) => e.id === endpoint.id);
      expect(dashEndpoint?.latestCheck).not.toBeNull();
      expect(dashEndpoint?.latestCheck?.isHealthy).toBe(true);
      expect(dashEndpoint?.latestCheck?.responseTimeMs).toBe(123);
    });

    it('should include active incidents', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(incidents).values({
        endpointId: endpoint.id,
        startedAt: new Date(),
        failureReason: 'connection refused',
        isOngoing: true,
      });

      const dashboard = await getDashboard(user.id);
      const dashEndpoint = dashboard.endpoints.find((e) => e.id === endpoint.id);
      expect(dashEndpoint?.activeIncident).not.toBeNull();
      expect(dashEndpoint?.activeIncident?.failureReason).toBe('connection refused');
    });

    it('should calculate 24h uptime percentage', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(dailyStats).values({
        endpointId: endpoint.id,
        date: todayStr(),
        totalChecks: 100,
        downChecks: 25,
      });

      const dashboard = await getDashboard(user.id);
      const dashEndpoint = dashboard.endpoints.find((e) => e.id === endpoint.id);
      expect(dashEndpoint?.uptimePercent24h).toBe(75);
      expect(dashboard.summary.overallUptimePercent).toBe(75);
    });

    it("should not include other users' endpoints", async () => {
      const user = await createTestUser('u1@test.com');
      const other = await createTestUser('u2@test.com');
      await createTestEndpoint(user.id, { name: 'Mine' });
      await createTestEndpoint(other.id, { name: 'Theirs' });

      const dashboard = await getDashboard(user.id);
      expect(dashboard.summary.totalEndpoints).toBe(1);
      expect(dashboard.endpoints).toHaveLength(1);
      expect(dashboard.endpoints[0].name).toBe('Mine');
    });
  });
});
