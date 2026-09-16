import { lt, and, isNotNull } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { healthCheckResults, dailyStats, refreshTokens } from '../../db/schema.js';

const CHECK_RESULTS_RETENTION_DAYS = 90;
const DAILY_STATS_RETENTION_DAYS = 365;
const REVOKED_TOKENS_RETENTION_DAYS = 30;

function daysAgo(days: number): Date {
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - days);
  return cutoff;
}

export async function pruneCheckResults(): Promise<number> {
  const cutoff = daysAgo(CHECK_RESULTS_RETENTION_DAYS);
  const result = await db
    .delete(healthCheckResults)
    .where(lt(healthCheckResults.timestamp, cutoff))
    .returning({ id: healthCheckResults.id });
  return result.length;
}

export async function pruneDailyStats(): Promise<void> {
  const cutoff = daysAgo(DAILY_STATS_RETENTION_DAYS);
  const cutoffStr = cutoff.toISOString().slice(0, 10);
  await db.delete(dailyStats).where(lt(dailyStats.date, cutoffStr));
}

export async function pruneRevokedTokens(): Promise<void> {
  const cutoff = daysAgo(REVOKED_TOKENS_RETENTION_DAYS);
  await db
    .delete(refreshTokens)
    .where(and(isNotNull(refreshTokens.revokedAt), lt(refreshTokens.revokedAt, cutoff)));
}

export interface RetentionResult {
  checkResultsPruned: boolean;
  dailyStatsPruned: boolean;
  revokedTokensPruned: boolean;
  timestamp: string;
}

export async function runRetention(): Promise<RetentionResult> {
  console.log('Running retention policy...');

  let checkResultsPruned = false;
  let dailyStatsPruned = false;
  let revokedTokensPruned = false;

  try {
    const count = await pruneCheckResults();
    console.log(`Pruned ${count} health check result(s).`);
    checkResultsPruned = true;
  } catch (error) {
    console.error('Failed to prune check results:', error);
  }

  try {
    await pruneDailyStats();
    dailyStatsPruned = true;
  } catch (error) {
    console.error('Failed to prune daily stats:', error);
  }

  try {
    await pruneRevokedTokens();
    revokedTokensPruned = true;
  } catch (error) {
    console.error('Failed to prune tokens:', error);
  }

  console.log('Retention policy completed.');
  return {
    checkResultsPruned,
    dailyStatsPruned,
    revokedTokensPruned,
    timestamp: new Date().toISOString(),
  };
}
