import { Worker as BullWorker, Queue as BullQueue } from 'bullmq';
import { Redis as IORedis } from 'ioredis';
import { env } from './config/env.js';
import { setupCheckSchedules, startWorker, stopWorker } from './modules/checks/checks.worker.js';
import {
  startScheduleSyncSubscriber,
  stopScheduleSyncSubscriber,
} from './modules/checks/schedule-sync.js';
import { runRetention } from './modules/retention/retention.service.js';

const RETENTION_QUEUE_NAME = 'retention';
const RETENTION_INTERVAL_MS = 24 * 60 * 60 * 1000;

console.log(`Worker starting in ${env.NODE_ENV} mode...`);

await setupCheckSchedules();
await startWorker();
await startScheduleSyncSubscriber();

const retentionConnection = new IORedis(env.REDIS_URL, { maxRetriesPerRequest: null });
const retentionQueue = new BullQueue(RETENTION_QUEUE_NAME, { connection: retentionConnection });
const retentionWorker = new BullWorker(
  RETENTION_QUEUE_NAME,
  async () => {
    await runRetention();
  },
  { connection: retentionConnection },
);

retentionWorker.on('failed', (job, error) => {
  console.error(`Retention job ${job?.id ?? 'unknown'} failed:`, error);
});

await retentionQueue.upsertJobScheduler(
  'daily-retention',
  { every: RETENTION_INTERVAL_MS },
  { data: {} },
);

console.log('Worker is running and processing health checks.');

const shutdown = async () => {
  console.log('Worker shutting down...');
  await stopScheduleSyncSubscriber();
  await stopWorker();
  await retentionWorker.close();
  await retentionQueue.close();
  retentionConnection.disconnect();
  process.exit(0);
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
