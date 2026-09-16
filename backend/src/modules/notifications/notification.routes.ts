import type { FastifyInstance, FastifyReply } from 'fastify';
import { and, eq } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { notificationPreferences, pushSubscriptions } from '../../db/schema.js';
import {
  updatePreferencesSchema,
  createSubscriptionSchema,
  subscriptionParamsSchema,
} from './notification.schemas.js';

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

export async function notificationRoutes(fastify: FastifyInstance) {
  fastify.addHook('preHandler', fastify.authenticate);

  fastify.get('/preferences', async (request) => {
    const preferences = await db.query.notificationPreferences.findFirst({
      where: eq(notificationPreferences.userId, request.user.id),
    });

    return (
      preferences ?? {
        userId: request.user.id,
        notifyOnDown: true,
        notifyOnRecovery: true,
      }
    );
  });

  fastify.put('/preferences', async (request, reply) => {
    const parsed = updatePreferencesSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const existing = await db.query.notificationPreferences.findFirst({
      where: eq(notificationPreferences.userId, request.user.id),
    });

    if (existing) {
      const [updated] = await db
        .update(notificationPreferences)
        .set({ ...parsed.data, updatedAt: new Date() })
        .where(eq(notificationPreferences.userId, request.user.id))
        .returning();
      return updated;
    }

    const [created] = await db
      .insert(notificationPreferences)
      .values({
        userId: request.user.id,
        notifyOnDown: parsed.data.notifyOnDown ?? true,
        notifyOnRecovery: parsed.data.notifyOnRecovery ?? true,
      })
      .returning();
    return created;
  });

  fastify.get('/subscriptions', async (request) => {
    return db.query.pushSubscriptions.findMany({
      where: eq(pushSubscriptions.userId, request.user.id),
    });
  });

  fastify.post('/subscriptions', async (request, reply) => {
    const parsed = createSubscriptionSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const [subscription] = await db
      .insert(pushSubscriptions)
      .values({
        userId: request.user.id,
        platform: parsed.data.platform,
        token: parsed.data.token,
        deviceName: parsed.data.deviceName,
      })
      .returning();

    return reply.code(201).send(subscription);
  });

  fastify.delete('/subscriptions/:id', async (request, reply) => {
    const parsed = subscriptionParamsSchema.safeParse(request.params);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const subscription = await db.query.pushSubscriptions.findFirst({
        where: and(
          eq(pushSubscriptions.id, parsed.data.id),
          eq(pushSubscriptions.userId, request.user.id),
        ),
      });

      if (!subscription) {
        throw new Error('Push subscription not found');
      }

      await db.delete(pushSubscriptions).where(eq(pushSubscriptions.id, parsed.data.id));
      return reply.code(204).send();
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });
}
