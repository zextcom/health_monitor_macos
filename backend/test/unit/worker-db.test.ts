import { describe, it, expect, beforeEach, afterAll } from 'vitest';
import { and, eq, sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import { users, endpoints, dailyStats, incidents } from '../../src/db/schema.js';
import { updateDailyStats, manageIncidents, stopWorker } from '../../src/modules/checks/checks.worker.js';

async function createTestUser(email = 'worker-owner@test.com') {
  const [user] = await db
    .insert(users)
    .values({ email, passwordHash: 'hash', name: 'Owner', role: 'admin' })
    .returning();
  return user;
}

async function createTestEndpoint(userId: string, overrides: Partial<typeof endpoints.$inferInsert> = {}) {
  const [endpoint] = await db
    .insert(endpoints)
    .values({
      userId,
      name: 'Test Endpoint',
      url: 'https://example.com',
      checkType: 'http',
      expectedStatusCode: 200,
      checkInterval: 60,
      ...overrides,
    })
    .returning();
  return endpoint;
}

beforeEach(async () => {
  await db.execute(
    sql`TRUNCATE TABLE ${incidents}, ${dailyStats}, ${endpoints}, ${users} RESTART IDENTITY CASCADE`,
  );
});

afterAll(async () => {
  await stopWorker();
});

describe('checks.worker DB-backed helpers', () => {
  describe('updateDailyStats()', () => {
    it('should insert a new daily stats row', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await updateDailyStats(endpoint.id, true, 60);

      const rows = await db.select().from(dailyStats).where(eq(dailyStats.endpointId, endpoint.id));
      expect(rows).toHaveLength(1);
      expect(rows[0].totalChecks).toBe(1);
      expect(rows[0].downChecks).toBe(0);
      expect(rows[0].downtimeSeconds).toBe('0');
    });

    it('should increment totalChecks on existing row (upsert)', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await updateDailyStats(endpoint.id, true, 60);
      await updateDailyStats(endpoint.id, true, 60);

      const rows = await db.select().from(dailyStats).where(eq(dailyStats.endpointId, endpoint.id));
      expect(rows).toHaveLength(1);
      expect(rows[0].totalChecks).toBe(2);
    });

    it('should increment downChecks and downtimeSeconds when unhealthy', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await updateDailyStats(endpoint.id, false, 60);
      await updateDailyStats(endpoint.id, false, 60);

      const rows = await db.select().from(dailyStats).where(eq(dailyStats.endpointId, endpoint.id));
      expect(rows).toHaveLength(1);
      expect(rows[0].totalChecks).toBe(2);
      expect(rows[0].downChecks).toBe(2);
      expect(rows[0].downtimeSeconds).toBe('120');
    });

    it('should not increment downChecks when healthy', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await updateDailyStats(endpoint.id, false, 60);
      await updateDailyStats(endpoint.id, true, 60);

      const rows = await db.select().from(dailyStats).where(eq(dailyStats.endpointId, endpoint.id));
      expect(rows).toHaveLength(1);
      expect(rows[0].totalChecks).toBe(2);
      expect(rows[0].downChecks).toBe(1);
      expect(rows[0].downtimeSeconds).toBe('60');
    });
  });

  describe('manageIncidents()', () => {
    it('should create an incident when endpoint goes unhealthy with no ongoing incident', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      const action = await manageIncidents(endpoint.id, false, 'Connection refused');

      expect(action).toBe('opened');
      const rows = await db.select().from(incidents).where(eq(incidents.endpointId, endpoint.id));
      expect(rows).toHaveLength(1);
      expect(rows[0].isOngoing).toBe(true);
      expect(rows[0].failureReason).toBe('Connection refused');
      expect(rows[0].endedAt).toBeNull();
    });

    it('should not create a duplicate incident when one is already ongoing', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await manageIncidents(endpoint.id, false, 'Connection refused');
      const action = await manageIncidents(endpoint.id, false, 'Connection refused again');

      expect(action).toBe('none');
      const rows = await db.select().from(incidents).where(eq(incidents.endpointId, endpoint.id));
      expect(rows).toHaveLength(1);
    });

    it('should close the ongoing incident when the endpoint recovers', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await manageIncidents(endpoint.id, false, 'Connection refused');
      const action = await manageIncidents(endpoint.id, true, null);

      expect(action).toBe('closed');
      const rows = await db
        .select()
        .from(incidents)
        .where(and(eq(incidents.endpointId, endpoint.id), eq(incidents.isOngoing, true)));
      expect(rows).toHaveLength(0);

      const allRows = await db.select().from(incidents).where(eq(incidents.endpointId, endpoint.id));
      expect(allRows).toHaveLength(1);
      expect(allRows[0].isOngoing).toBe(false);
      expect(allRows[0].endedAt).not.toBeNull();
    });

    it("should return 'none' when healthy and no ongoing incident", async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      const action = await manageIncidents(endpoint.id, true, null);

      expect(action).toBe('none');
      const rows = await db.select().from(incidents).where(eq(incidents.endpointId, endpoint.id));
      expect(rows).toHaveLength(0);
    });
  });
});
