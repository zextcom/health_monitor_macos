import Fastify from 'fastify';
import { sql } from 'drizzle-orm';
import { Redis as IORedis } from 'ioredis';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import sensible from '@fastify/sensible';
import dbPlugin from './plugins/db.js';
import authPlugin from './plugins/auth.js';
import { authRoutes } from './modules/auth/auth.routes.js';
import { endpointRoutes } from './modules/endpoints/endpoints.routes.js';
import { checkRoutes } from './modules/checks/checks.routes.js';
import { sseRoutes } from './modules/sse/sse.routes.js';
import { dashboardRoutes } from './modules/dashboard/dashboard.routes.js';
import { notificationRoutes } from './modules/notifications/notification.routes.js';
import { retentionRoutes } from './modules/retention/retention.routes.js';
import { standardsRoutes } from './modules/standards/standards.routes.js';
import {
  createSelfHealthHandler,
  readPackageVersion,
  resolveReleaseId,
  type Probe,
} from './modules/standards/self-health.js';
import { HEALTH_MEDIA_TYPE } from './modules/standards/health-standard.js';
import { startSSESubscriber } from './modules/sse/sse-bus.js';
import { db } from './db/index.js';
import { env } from './config/env.js';

export interface BuildAppOptions {
  /** Overrides the `/health` dependency probes (tests use this to simulate a failing dependency). */
  healthProbes?: Record<string, Probe>;
}

export async function buildApp(options: BuildAppOptions = {}) {
  const app = Fastify({ logger: true });

  await app.register(cors, {
    origin: [
      'https://health.zext.dev',
      'http://localhost:8081', // Expo dev
      'http://localhost:19006', // Expo web dev
    ],
  });
  await app.register(helmet);
  await app.register(rateLimit, {
    max: 100,
    timeWindow: '1 minute',
  });
  await app.register(sensible);
  await app.register(dbPlugin);
  await app.register(authPlugin);

  await app.register(async function apiRoutes(api) {
    await api.register(authRoutes, { prefix: '/auth' });
    await api.register(endpointRoutes, { prefix: '/endpoints' });
    await api.register(checkRoutes);
    await api.register(sseRoutes);
    await api.register(dashboardRoutes, { prefix: '/dashboard' });
    await api.register(retentionRoutes, { prefix: '/admin' });
    await api.register(notificationRoutes, { prefix: '/notifications' });
    await api.register(standardsRoutes, { prefix: '/standards' });
  }, { prefix: '/api' });

  // Health check stays at root - no /api prefix. Zext Health Standard format (see
  // docs/health-standard.md): 200 for pass/warn, 503 when a dependency fails.
  let healthRedis: IORedis | null = null;
  const healthProbes: Record<string, Probe> = options.healthProbes ?? {
    postgres: () => db.execute(sql`select 1`),
    redis: () => {
      healthRedis ??= new IORedis(env.REDIS_URL, { lazyConnect: true, maxRetriesPerRequest: 1 });
      return healthRedis.ping();
    },
  };
  const selfHealth = createSelfHealthHandler({
    probes: healthProbes,
    version: readPackageVersion(),
    releaseId: resolveReleaseId(),
  });
  app.addHook('onClose', async () => {
    healthRedis?.disconnect();
  });
  app.get('/health', async (_request, reply) => {
    const { httpStatus, body } = await selfHealth();
    reply.code(httpStatus).type(HEALTH_MEDIA_TYPE).header('Cache-Control', 'no-store');
    return JSON.stringify(body);
  });

  await startSSESubscriber();

  return app;
}
