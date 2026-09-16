import type { FastifyInstance, FastifyReply } from 'fastify';
import { getDashboard } from './dashboard.service.js';

function handleServiceError(reply: FastifyReply, error: unknown) {
  const message = error instanceof Error ? error.message : 'Unexpected error';
  reply.code(400).send({ error: message });
}

export async function dashboardRoutes(fastify: FastifyInstance) {
  fastify.addHook('preHandler', fastify.authenticate);

  fastify.get('/', async (request, reply) => {
    try {
      return await getDashboard(request.user.id);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });
}
