import { EventEmitter } from 'node:events';
import { Redis as IORedis } from 'ioredis';
import { env } from '../../config/env.js';

export const REDIS_CHANNEL = 'health-check-results';

export interface CheckResultEvent {
  endpointId: string;
  userId: string;
  isHealthy: boolean;
  responseTimeMs: number | null;
  statusCode: number | null;
  failureReason: string | null;
  timestamp: string;
}

const bus = new EventEmitter();
bus.setMaxListeners(1000);

let subscriber: IORedis | null = null;

export function getSSEBus(): EventEmitter {
  return bus;
}

export async function startSSESubscriber(): Promise<void> {
  subscriber = new IORedis(env.REDIS_URL);
  await subscriber.subscribe(REDIS_CHANNEL);
  subscriber.on('message', (_channel, message) => {
    try {
      const event: CheckResultEvent = JSON.parse(message);
      bus.emit(`check:${event.userId}`, event);
    } catch {
      /* ignore malformed messages */
    }
  });
}

export async function stopSSESubscriber(): Promise<void> {
  await subscriber?.unsubscribe(REDIS_CHANNEL);
  subscriber?.disconnect();
  subscriber = null;
}
