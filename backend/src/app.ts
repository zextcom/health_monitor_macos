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
import { startSSESubscriber } from './modules/sse/sse-bus.js';

export async function buildApp() {
  const app = Fastify({ logger: true });

  await app.register(cors, { origin: true });
  await app.register(helmet);
  await app.register(rateLimit, {
    max: 100,
    timeWindow: '1 minute',
  });
  await app.register(sensible);
  await app.register(dbPlugin);
  await app.register(authPlugin);

  await app.register(authRoutes, { prefix: '/auth' });
  await app.register(endpointRoutes, { prefix: '/endpoints' });
  await app.register(checkRoutes);
  await app.register(sseRoutes);
  await app.register(dashboardRoutes, { prefix: '/dashboard' });

  app.get('/health', async () => ({ status: 'ok' }));

  await startSSESubscriber();

  return app;
}
