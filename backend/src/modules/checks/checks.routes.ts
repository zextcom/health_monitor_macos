import type { FastifyInstance, FastifyReply } from 'fastify';
import {
  checkParamsSchema,
  checkHistoryQuerySchema,
  dailyStatsQuerySchema,
  uptimeQuerySchema,
  incidentsQuerySchema,
} from './checks.schemas.js';
import { getCheckHistory, getLatestCheck, getDailyStats, getUptime, getIncidents } from './checks.service.js';

function statusCodeForError(message: string): number {
  if (message.includes('not found')) {
    return 404;
  }
  if (message.includes('not allowed') || message.includes('forbidden')) {
    return 403;
  }
  return 400;
}

function handleServiceError(reply: FastifyReply, error: unknown) {
  const message = error instanceof Error ? error.message : 'Unexpected error';
  reply.code(statusCodeForError(message)).send({ error: message });
}

export async function checkRoutes(fastify: FastifyInstance) {
  fastify.addHook('preHandler', fastify.authenticate);

  fastify.get('/endpoints/:id/checks', async (request, reply) => {
    const params = checkParamsSchema.safeParse(request.params);
    if (!params.success) {
      return reply.code(400).send({ error: params.error.flatten() });
    }

    const query = checkHistoryQuerySchema.safeParse(request.query);
    if (!query.success) {
      return reply.code(400).send({ error: query.error.flatten() });
    }

    try {
      return await getCheckHistory(request.user.id, params.data.id, query.data);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.get('/endpoints/:id/checks/latest', async (request, reply) => {
    const params = checkParamsSchema.safeParse(request.params);
    if (!params.success) {
      return reply.code(400).send({ error: params.error.flatten() });
    }

    try {
      return await getLatestCheck(request.user.id, params.data.id);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.get('/endpoints/:id/stats', async (request, reply) => {
    const params = checkParamsSchema.safeParse(request.params);
    if (!params.success) {
      return reply.code(400).send({ error: params.error.flatten() });
    }

    const query = dailyStatsQuerySchema.safeParse(request.query);
    if (!query.success) {
      return reply.code(400).send({ error: query.error.flatten() });
    }

    try {
      return await getDailyStats(request.user.id, params.data.id, query.data.days);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.get('/endpoints/:id/uptime', async (request, reply) => {
    const params = checkParamsSchema.safeParse(request.params);
    if (!params.success) {
      return reply.code(400).send({ error: params.error.flatten() });
    }

    const query = uptimeQuerySchema.safeParse(request.query);
    if (!query.success) {
      return reply.code(400).send({ error: query.error.flatten() });
    }

    try {
      return await getUptime(request.user.id, params.data.id, query.data.days);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.get('/endpoints/:id/incidents', async (request, reply) => {
    const params = checkParamsSchema.safeParse(request.params);
    if (!params.success) {
      return reply.code(400).send({ error: params.error.flatten() });
    }

    const query = incidentsQuerySchema.safeParse(request.query);
    if (!query.success) {
      return reply.code(400).send({ error: query.error.flatten() });
    }

    try {
      return await getIncidents(request.user.id, params.data.id, query.data.limit);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });
}
