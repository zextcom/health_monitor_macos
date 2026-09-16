import { describe, it, expect, beforeEach } from 'vitest';
import { sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import { users, endpoints, healthCheckResults, dailyStats, refreshTokens } from '../../src/db/schema.js';
import { runRetention } from '../../src/modules/retention/retention.service.js';

async function createTestUser(email = 'retention@test.com') {
  const [user] = await db
    .insert(users)
    .values({ email, passwordHash: 'hash', name: 'Retention User', role: 'admin' })
    .returning();
  return user;
}

async function createTestEndpoint(userId: string) {
  const [endpoint] = await db
    .insert(endpoints)
    .values({ userId, name: 'Endpoint', url: 'https://example.com' })
    .returning();
  return endpoint;
}

function daysAgo(days: number): Date {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d;
}

function dateStrDaysAgo(days: number): string {
  return daysAgo(days).toISOString().slice(0, 10);
}

beforeEach(async () => {
  await db.execute(
    sql`TRUNCATE TABLE ${healthCheckResults}, ${dailyStats}, ${refreshTokens}, ${endpoints}, ${users} RESTART IDENTITY CASCADE`,
  );
});

describe('retention.service', () => {
  describe('runRetention()', () => {
    it('should delete check results older than 90 days', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(healthCheckResults).values({
        endpointId: endpoint.id,
        isHealthy: true,
        timestamp: daysAgo(91),
      });

      await runRetention();

      const rows = await db
        .select()
        .from(healthCheckResults)
        .where(sql`${healthCheckResults.endpointId} = ${endpoint.id}`);
      expect(rows).toHaveLength(0);
    });

    it('should keep check results newer than 90 days', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(healthCheckResults).values({
        endpointId: endpoint.id,
        isHealthy: true,
        timestamp: daysAgo(10),
      });

      await runRetention();

      const rows = await db
        .select()
        .from(healthCheckResults)
        .where(sql`${healthCheckResults.endpointId} = ${endpoint.id}`);
      expect(rows).toHaveLength(1);
    });

    it('should delete daily stats older than 365 days', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(dailyStats).values({
        endpointId: endpoint.id,
        date: dateStrDaysAgo(366),
        totalChecks: 10,
        downChecks: 0,
      });

      await runRetention();

      const rows = await db
        .select()
        .from(dailyStats)
        .where(sql`${dailyStats.endpointId} = ${endpoint.id}`);
      expect(rows).toHaveLength(0);
    });

    it('should keep daily stats newer than 365 days', async () => {
      const user = await createTestUser();
      const endpoint = await createTestEndpoint(user.id);

      await db.insert(dailyStats).values({
        endpointId: endpoint.id,
        date: dateStrDaysAgo(30),
        totalChecks: 10,
        downChecks: 0,
      });

      await runRetention();

      const rows = await db
        .select()
        .from(dailyStats)
        .where(sql`${dailyStats.endpointId} = ${endpoint.id}`);
      expect(rows).toHaveLength(1);
    });

    it('should delete revoked tokens older than 30 days', async () => {
      const user = await createTestUser();
      await db.insert(refreshTokens).values({
        userId: user.id,
        tokenHash: 'old-revoked-hash',
        expiresAt: daysAgo(-1),
        revokedAt: daysAgo(31),
      });

      await runRetention();

      const rows = await db
        .select()
        .from(refreshTokens)
        .where(sql`${refreshTokens.tokenHash} = 'old-revoked-hash'`);
      expect(rows).toHaveLength(0);
    });

    it('should keep non-revoked tokens regardless of age', async () => {
      const user = await createTestUser();
      await db.insert(refreshTokens).values({
        userId: user.id,
        tokenHash: 'old-active-hash',
        expiresAt: daysAgo(-100),
        createdAt: daysAgo(100),
        revokedAt: null,
      });

      await runRetention();

      const rows = await db
        .select()
        .from(refreshTokens)
        .where(sql`${refreshTokens.tokenHash} = 'old-active-hash'`);
      expect(rows).toHaveLength(1);
    });

    it('should keep revoked tokens newer than 30 days', async () => {
      const user = await createTestUser();
      await db.insert(refreshTokens).values({
        userId: user.id,
        tokenHash: 'recent-revoked-hash',
        expiresAt: daysAgo(-1),
        revokedAt: daysAgo(5),
      });

      await runRetention();

      const rows = await db
        .select()
        .from(refreshTokens)
        .where(sql`${refreshTokens.tokenHash} = 'recent-revoked-hash'`);
      expect(rows).toHaveLength(1);
    });
  });
});
