import type { FastifyInstance } from 'fastify';
import { getSSEBus, type CheckResultEvent } from './sse-bus.js';

export async function sseRoutes(fastify: FastifyInstance) {
  fastify.addHook('preHandler', fastify.authenticate);

  fastify.get('/sse/checks', async (request, reply) => {
    const userId = request.user.id;

    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });

    reply.raw.write(`data: ${JSON.stringify({ type: 'connected' })}\n\n`);

    const bus = getSSEBus();
    const handler = (event: CheckResultEvent) => {
      reply.raw.write(`data: ${JSON.stringify(event)}\n\n`);
    };

    bus.on(`check:${userId}`, handler);

    const heartbeat = setInterval(() => {
      reply.raw.write(': heartbeat\n\n');
    }, 30_000);

    request.raw.on('close', () => {
      bus.off(`check:${userId}`, handler);
      clearInterval(heartbeat);
    });

    await reply.hijack();
  });
}
