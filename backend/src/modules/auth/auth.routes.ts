import type { FastifyInstance, FastifyReply } from 'fastify';
import {
  acceptInviteSchema,
  inviteSchema,
  loginSchema,
  refreshSchema,
  registerSchema,
} from './auth.schemas.js';
import {
  acceptInvitation,
  createInvitation,
  login,
  logout,
  refresh,
  register,
} from './auth.service.js';

function statusCodeForError(message: string): number {
  if (message === 'Invalid email or password' || message === 'Invalid or expired refresh token') {
    return 401;
  }
  if (message.includes('already registered') || message.includes('already exists')) {
    return 409;
  }
  if (message.includes('not found')) {
    return 404;
  }
  return 400;
}

function handleServiceError(reply: FastifyReply, error: unknown) {
  const message = error instanceof Error ? error.message : 'Unexpected error';
  reply.code(statusCodeForError(message)).send({ error: message });
}

export async function authRoutes(fastify: FastifyInstance) {
  fastify.post('/register', async (request, reply) => {
    const parsed = registerSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const user = await register(parsed.data);
      return reply.code(201).send({ user });
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/login', async (request, reply) => {
    const parsed = loginSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const { user, refreshToken } = await login(parsed.data);
      const accessToken = await request.server.jwt.sign({ sub: user.id, role: user.role });
      return reply.send({ accessToken, refreshToken, user });
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/refresh', async (request, reply) => {
    const parsed = refreshSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const { userId, role, newRefreshToken } = await refresh(parsed.data.refreshToken);
      const accessToken = await request.server.jwt.sign({ sub: userId, role });
      return reply.send({ accessToken, refreshToken: newRefreshToken });
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/logout', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = refreshSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      await logout(parsed.data.refreshToken);
      return reply.code(204).send();
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/invite', { preHandler: [fastify.requireAdmin] }, async (request, reply) => {
    const parsed = inviteSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const { token } = await createInvitation(request.user.id, parsed.data.email);
      return reply.code(201).send({ token, message: 'Invitation created' });
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });

  fastify.post('/accept-invite', async (request, reply) => {
    const parsed = acceptInviteSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    try {
      const user = await acceptInvitation(parsed.data);
      return reply.code(201).send({ user });
    } catch (error) {
      return handleServiceError(reply, error);
    }
  });
}
