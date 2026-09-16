import type { FastifyInstance, FastifyReply } from 'fastify';
import {
  createEndpointSchema,
  updateEndpointSchema,
  importSchema,
  listEndpointsQuerySchema,
  endpointParamsSchema,
} from './endpoints.schemas.js';
import {
  listEndpoints,
  getEndpoint,
  createEndpoint,
  updateEndpoint,
  deleteEndpoint,
  pauseEndpoint,
  resumeEndpoint,
  importEndpoints,
  exportEndpoints,
} from './endpoints.service.js';

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

export async function endpointRoutes(fastify: FastifyInstance) {
  fastify.addHook('preHandler', fastify.authenticate);

  fastify.get('/', async (request, reply) => {
    const parsed = listEndpointsQuerySchema.safeParse(request.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      return await listEndpoints(request.user.id, parsed.data);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.get('/export', async (request, reply) => {
    try {
      return await exportEndpoints(request.user.id);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.get('/:id', async (request, reply) => {
    const parsed = endpointParamsSchema.safeParse(request.params);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      return await getEndpoint(request.user.id, parsed.data.id);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/', async (request, reply) => {
    const parsed = createEndpointSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const endpoint = await createEndpoint(request.user.id, parsed.data);
      return reply.code(201).send(endpoint);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.put('/:id', async (request, reply) => {
    const params = endpointParamsSchema.safeParse(request.params);
    if (!params.success) {
      return reply.code(400).send({ error: params.error.flatten() });
    }

    const body = updateEndpointSchema.safeParse(request.body);
    if (!body.success) {
      return reply.code(400).send({ error: body.error.flatten() });
    }

    try {
      return await updateEndpoint(request.user.id, params.data.id, body.data);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.delete('/:id', async (request, reply) => {
    const parsed = endpointParamsSchema.safeParse(request.params);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      await deleteEndpoint(request.user.id, parsed.data.id);
      return reply.code(204).send();
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/:id/pause', async (request, reply) => {
    const parsed = endpointParamsSchema.safeParse(request.params);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      return await pauseEndpoint(request.user.id, parsed.data.id);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/:id/resume', async (request, reply) => {
    const parsed = endpointParamsSchema.safeParse(request.params);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      return await resumeEndpoint(request.user.id, parsed.data.id);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/import', async (request, reply) => {
    const parsed = importSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      return await importEndpoints(request.user.id, parsed.data);
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });
}
