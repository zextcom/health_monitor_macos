import type { FastifyInstance } from 'fastify';
import { runRetention } from './retention.service.js';

export async function retentionRoutes(fastify: FastifyInstance) {
  fastify.post('/retention/run', { preHandler: [fastify.requireAdmin] }, async () => {
    return await runRetention();
  });
}
