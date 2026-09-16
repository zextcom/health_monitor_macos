import { and, desc, eq, gte } from 'drizzle-orm';
import { db } from '../../db/index.js';
import {
  endpoints,
  healthCheckResults,
  dailyStats,
  incidents,
  type HealthCheckResult,
  type DailyStat,
  type Incident,
} from '../../db/schema.js';

async function assertEndpointOwnership(userId: string, endpointId: string): Promise<void> {
  const endpoint = await db.query.endpoints.findFirst({
    where: and(eq(endpoints.id, endpointId), eq(endpoints.userId, userId)),
  });

  if (!endpoint) {
    throw new Error('Endpoint not found');
  }
}

export async function getCheckHistory(
  userId: string,
  endpointId: string,
  options: { limit?: number; offset?: number } = {},
): Promise<HealthCheckResult[]> {
  await assertEndpointOwnership(userId, endpointId);

  const limit = options.limit ?? 100;
  const offset = options.offset ?? 0;

  return db.query.healthCheckResults.findMany({
    where: eq(healthCheckResults.endpointId, endpointId),
    orderBy: [desc(healthCheckResults.timestamp)],
    limit,
    offset,
  });
}

export async function getLatestCheck(
  userId: string,
  endpointId: string,
): Promise<HealthCheckResult | null> {
  await assertEndpointOwnership(userId, endpointId);

  const result = await db.query.healthCheckResults.findFirst({
    where: eq(healthCheckResults.endpointId, endpointId),
    orderBy: [desc(healthCheckResults.timestamp)],
  });

  return result ?? null;
}

export async function getDailyStats(
  userId: string,
  endpointId: string,
  days: number = 30,
): Promise<DailyStat[]> {
  await assertEndpointOwnership(userId, endpointId);

  const since = new Date();
  since.setDate(since.getDate() - days);
  const sinceStr = since.toISOString().slice(0, 10);

  return db.query.dailyStats.findMany({
    where: and(eq(dailyStats.endpointId, endpointId), gte(dailyStats.date, sinceStr)),
    orderBy: (stat, { asc }) => [asc(stat.date)],
  });
}

export async function getUptime(
  userId: string,
  endpointId: string,
  days: number = 7,
): Promise<{ uptimePercent: number; totalChecks: number; downChecks: number }> {
  const stats = await getDailyStats(userId, endpointId, days);

  const totalChecks = stats.reduce((sum, stat) => sum + stat.totalChecks, 0);
  const downChecks = stats.reduce((sum, stat) => sum + stat.downChecks, 0);
  const uptimePercent = totalChecks === 0 ? 100 : (1 - downChecks / totalChecks) * 100;

  return { uptimePercent, totalChecks, downChecks };
}

export async function getIncidents(
  userId: string,
  endpointId: string,
  limit: number = 20,
): Promise<Incident[]> {
  await assertEndpointOwnership(userId, endpointId);

  return db.query.incidents.findMany({
    where: eq(incidents.endpointId, endpointId),
    orderBy: [desc(incidents.startedAt)],
    limit,
  });
}
