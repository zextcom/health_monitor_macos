import Fastify from 'fastify';
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
import { startSSESubscriber } from './modules/sse/sse-bus.js';

export async function buildApp() {
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
  }, { prefix: '/api' });

  // Health check stays at root - no /api prefix
  app.get('/health', async () => ({ status: 'ok' }));

  await startSSESubscriber();

  return app;
}
