import { describe, it, expect, beforeEach, afterAll, beforeAll } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { db } from '../../src/db/index.js';
import { invitations } from '../../src/db/schema.js';
import { generateToken, hashToken } from '../../src/utils/crypto.js';
import { createApp, closeApp, cleanDb, registerAndLogin, authHeader, inviteAndLogin } from '../helpers.js';

describe('auth routes', () => {
  let app: FastifyInstance;

  beforeAll(async () => {
    app = await createApp();
  });

  afterAll(async () => {
    await closeApp(app);
  });

  beforeEach(async () => {
    await cleanDb();
  });

  describe('POST /auth/register', () => {
    it('should register first user as admin', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/register',
        payload: { email: 'admin@test.com', password: 'testpass123', name: 'Admin' },
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body.user.role).toBe('admin');
      expect(body.user.email).toBe('admin@test.com');
      expect(body.user.passwordHash).toBeUndefined();
    });

    it('should reject registration without invitation when users exist', async () => {
      await app.inject({
        method: 'POST',
        url: '/api/auth/register',
        payload: { email: 'admin@test.com', password: 'testpass123', name: 'Admin' },
      });

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/register',
        payload: { email: 'second@test.com', password: 'testpass123', name: 'Second' },
      });

      expect(res.statusCode).toBe(400);
    });

    it('should return 400 for invalid email', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/register',
        payload: { email: 'not-an-email', password: 'testpass123', name: 'Admin' },
      });

      expect(res.statusCode).toBe(400);
    });

    it('should return 400 for short password (< 8 chars)', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/register',
        payload: { email: 'admin@test.com', password: 'short', name: 'Admin' },
      });

      expect(res.statusCode).toBe(400);
    });
  });

  describe('POST /auth/login', () => {
    beforeEach(async () => {
      await app.inject({
        method: 'POST',
        url: '/api/auth/register',
        payload: { email: 'admin@test.com', password: 'testpass123', name: 'Admin' },
      });
    });

    it('should return accessToken, refreshToken, and user (200)', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/login',
        payload: { email: 'admin@test.com', password: 'testpass123' },
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(typeof body.accessToken).toBe('string');
      expect(typeof body.refreshToken).toBe('string');
      expect(body.user.email).toBe('admin@test.com');
    });

    it('should return 401 for wrong password', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/login',
        payload: { email: 'admin@test.com', password: 'wrongpassword' },
      });

      expect(res.statusCode).toBe(401);
    });

    it('should return 401 for non-existent email', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/login',
        payload: { email: 'nobody@test.com', password: 'testpass123' },
      });

      expect(res.statusCode).toBe(401);
    });

    it('should NOT return passwordHash in user object', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/login',
        payload: { email: 'admin@test.com', password: 'testpass123' },
      });

      const body = res.json();
      expect(body.user.passwordHash).toBeUndefined();
    });
  });

  describe('POST /auth/refresh', () => {
    it('should return new accessToken and refreshToken (200)', async () => {
      const { refreshToken } = await registerAndLogin(app);

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/refresh',
        payload: { refreshToken },
      });

      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(typeof body.accessToken).toBe('string');
      expect(typeof body.refreshToken).toBe('string');
      expect(body.refreshToken).not.toBe(refreshToken);
    });

    it('should invalidate old refresh token after use', async () => {
      const { refreshToken } = await registerAndLogin(app);

      await app.inject({
        method: 'POST',
        url: '/api/auth/refresh',
        payload: { refreshToken },
      });

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/refresh',
        payload: { refreshToken },
      });

      expect(res.statusCode).toBe(401);
    });

    it('should return 401 for invalid token', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/refresh',
        payload: { refreshToken: 'not-a-real-token' },
      });

      expect(res.statusCode).toBe(401);
    });
  });

  describe('POST /auth/logout', () => {
    it('should revoke refresh token (204)', async () => {
      const { accessToken, refreshToken } = await registerAndLogin(app);

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/logout',
        headers: authHeader(accessToken),
        payload: { refreshToken },
      });

      expect(res.statusCode).toBe(204);

      const refreshRes = await app.inject({
        method: 'POST',
        url: '/api/auth/refresh',
        payload: { refreshToken },
      });
      expect(refreshRes.statusCode).toBe(401);
    });

    it('should require authentication', async () => {
      const { refreshToken } = await registerAndLogin(app);

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/logout',
        payload: { refreshToken },
      });

      expect(res.statusCode).toBe(401);
    });
  });

  describe('POST /auth/invite', () => {
    it('should create invitation (201, admin only)', async () => {
      const { accessToken } = await registerAndLogin(app);

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/invite',
        headers: authHeader(accessToken),
        payload: { email: 'member@test.com' },
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(typeof body.token).toBe('string');
    });

    it('should return 403 for non-admin user', async () => {
      const { accessToken: adminToken } = await registerAndLogin(app);
      const { accessToken: memberToken } = await inviteAndLogin(
        app,
        adminToken,
        'member@test.com',
      );

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/invite',
        headers: authHeader(memberToken),
        payload: { email: 'another@test.com' },
      });

      expect(res.statusCode).toBe(403);
    });

    it('should return 401 without token', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/invite',
        payload: { email: 'member@test.com' },
      });

      expect(res.statusCode).toBe(401);
    });

    it('should return 409 for already-registered email', async () => {
      const { accessToken } = await registerAndLogin(app, 'admin@test.com');

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/invite',
        headers: authHeader(accessToken),
        payload: { email: 'admin@test.com' },
      });

      expect(res.statusCode).toBe(409);
    });
  });

  describe('POST /auth/accept-invite', () => {
    it('should create member user from valid invitation (201)', async () => {
      const { accessToken } = await registerAndLogin(app);

      const inviteRes = await app.inject({
        method: 'POST',
        url: '/api/auth/invite',
        headers: authHeader(accessToken),
        payload: { email: 'member@test.com' },
      });
      const { token } = inviteRes.json();

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/accept-invite',
        payload: { token, password: 'memberpass123', name: 'Member' },
      });

      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body.user.email).toBe('member@test.com');
      expect(body.user.role).toBe('member');

      const loginRes = await app.inject({
        method: 'POST',
        url: '/api/auth/login',
        payload: { email: 'member@test.com', password: 'memberpass123' },
      });
      expect(loginRes.statusCode).toBe(200);
      expect(loginRes.json().user.role).toBe('member');
    });

    it('should return 400 for invalid token', async () => {
      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/accept-invite',
        payload: { token: 'not-a-real-token', password: 'memberpass123', name: 'Member' },
      });

      expect(res.statusCode).toBe(400);
    });

    it('should return 400 for expired invitation', async () => {
      const { userId } = await registerAndLogin(app);

      const rawToken = generateToken();
      await db.insert(invitations).values({
        email: 'expired@test.com',
        invitedById: userId,
        tokenHash: hashToken(rawToken),
        expiresAt: new Date(Date.now() - 1000),
      });

      const res = await app.inject({
        method: 'POST',
        url: '/api/auth/accept-invite',
        payload: { token: rawToken, password: 'memberpass123', name: 'Member' },
      });

      expect(res.statusCode).toBe(400);
    });
  });
});
