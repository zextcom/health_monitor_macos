import { env } from './config/env.js';
import { setupCheckSchedules, startWorker, stopWorker } from './modules/checks/checks.worker.js';
import {
  startScheduleSyncSubscriber,
  stopScheduleSyncSubscriber,
} from './modules/checks/schedule-sync.js';

console.log(`Worker starting in ${env.NODE_ENV} mode...`);

await setupCheckSchedules();
await startWorker();
await startScheduleSyncSubscriber();

console.log('Worker is running and processing health checks.');

const shutdown = async () => {
  console.log('Worker shutting down...');
  await stopScheduleSyncSubscriber();
  await stopWorker();
  process.exit(0);
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
