import { Queue } from 'bullmq';
import { Redis as IORedis } from 'ioredis';
import { env } from '../../config/env.js';
import { QUEUE_NAME } from './checks.worker.js';

export const SCHEDULE_SYNC_CHANNEL = 'endpoint-schedule-sync';

export type ScheduleSyncAction =
  | { action: 'upsert'; endpointId: string; checkInterval: number }
  | { action: 'remove'; endpointId: string };

let syncPublisher: IORedis | null = null;

function getSyncPublisher(): IORedis {
  if (!syncPublisher) {
    syncPublisher = new IORedis(env.REDIS_URL);
  }
  return syncPublisher;
}

export async function publishScheduleSync(event: ScheduleSyncAction): Promise<void> {
  await getSyncPublisher().publish(SCHEDULE_SYNC_CHANNEL, JSON.stringify(event));
}

let syncSubscriber: IORedis | null = null;

export async function startScheduleSyncSubscriber(): Promise<void> {
  const redisForQueue = new IORedis(env.REDIS_URL, { maxRetriesPerRequest: null });
  const queue = new Queue(QUEUE_NAME, { connection: redisForQueue });

  syncSubscriber = new IORedis(env.REDIS_URL);
  await syncSubscriber.subscribe(SCHEDULE_SYNC_CHANNEL);

  syncSubscriber.on('message', async (_channel, message) => {
    try {
      const event: ScheduleSyncAction = JSON.parse(message);

      if (event.action === 'upsert') {
        await queue.upsertJobScheduler(
          `check:${event.endpointId}`,
          { every: event.checkInterval * 1000 },
          { data: { endpointId: event.endpointId } },
        );
      } else if (event.action === 'remove') {
        await queue.removeJobScheduler(`check:${event.endpointId}`);
      }
    } catch (error) {
      console.error('Schedule sync error:', error);
    }
  });
}

export async function stopScheduleSyncSubscriber(): Promise<void> {
  await syncSubscriber?.unsubscribe(SCHEDULE_SYNC_CHANNEL);
  syncSubscriber?.disconnect();
  syncSubscriber = null;
}
