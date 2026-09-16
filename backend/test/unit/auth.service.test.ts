import { describe, it, expect, beforeEach } from 'vitest';
import { sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import { users, invitations, refreshTokens } from '../../src/db/schema.js';
import {
  register,
  login,
  refresh,
  logout,
  createInvitation,
  acceptInvitation,
} from '../../src/modules/auth/auth.service.js';
import { hashToken } from '../../src/utils/crypto.js';

async function createTestUser(email = 'admin@test.com', password = 'testpass123', name = 'Admin') {
  return register({ email, password, name });
}

async function loginTestUser(email = 'admin@test.com', password = 'testpass123') {
  return login({ email, password });
}

beforeEach(async () => {
  await db.execute(
    sql`TRUNCATE TABLE ${refreshTokens}, ${invitations}, ${users} RESTART IDENTITY CASCADE`,
  );
});

describe('auth.service', () => {
  describe('register()', () => {
    it('should create the first user with admin role', async () => {
      const user = await createTestUser();
      expect(user.role).toBe('admin');
      expect(user.email).toBe('admin@test.com');
      expect(user.name).toBe('Admin');
    });

    it('should reject registration when users already exist (invite-only)', async () => {
      await createTestUser();
      await expect(
        register({ email: 'second@test.com', password: 'testpass123', name: 'Second' }),
      ).rejects.toThrow(/invite-only/i);
    });

    it('should hash the password (not store plaintext)', async () => {
      await createTestUser();
      const [row] = await db.select().from(users).where(sql`${users.email} = 'admin@test.com'`);
      expect(row.passwordHash).not.toBe('testpass123');
      expect(row.passwordHash.length).toBeGreaterThan(20);
    });

    it('should return user without passwordHash', async () => {
      const user = await createTestUser();
      expect(user).not.toHaveProperty('passwordHash');
    });

    it('should reject duplicate email', async () => {
      await createTestUser();
      // second registration is already blocked by invite-only rule once a user exists,
      // but verify the DB-level unique constraint independently by inserting directly.
      await expect(
        db.insert(users).values({
          email: 'admin@test.com',
          passwordHash: 'x',
          name: 'Dup',
          role: 'member',
        }),
      ).rejects.toThrow();
    });
  });

  describe('login()', () => {
    it('should return user and refreshToken for valid credentials', async () => {
      await createTestUser();
      const result = await loginTestUser();
      expect(result.user.email).toBe('admin@test.com');
      expect(typeof result.refreshToken).toBe('string');
      expect(result.refreshToken.length).toBeGreaterThan(10);
    });

    it('should throw for wrong password', async () => {
      await createTestUser();
      await expect(login({ email: 'admin@test.com', password: 'wrongpass' })).rejects.toThrow(
        /invalid email or password/i,
      );
    });

    it('should throw for non-existent email', async () => {
      await expect(
        login({ email: 'nobody@test.com', password: 'testpass123' }),
      ).rejects.toThrow(/invalid email or password/i);
    });
  });

  describe('refresh()', () => {
    it('should return new refresh token and revoke old one', async () => {
      await createTestUser();
      const { refreshToken } = await loginTestUser();

      const result = await refresh(refreshToken);
      expect(result.newRefreshToken).toBeDefined();
      expect(result.newRefreshToken).not.toBe(refreshToken);

      const oldHash = hashToken(refreshToken);
      const [oldRow] = await db
        .select()
        .from(refreshTokens)
        .where(sql`${refreshTokens.tokenHash} = ${oldHash}`);
      expect(oldRow.revokedAt).not.toBeNull();
    });

    it('should throw for invalid token', async () => {
      await expect(refresh('not-a-real-token')).rejects.toThrow(/invalid or expired/i);
    });

    it('should throw for expired token', async () => {
      const user = await createTestUser();
      const token = 'expired-token-value';
      await db.insert(refreshTokens).values({
        userId: user.id,
        tokenHash: hashToken(token),
        expiresAt: new Date(Date.now() - 1000),
      });
      await expect(refresh(token)).rejects.toThrow(/invalid or expired/i);
    });

    it('should throw for already-revoked token', async () => {
      await createTestUser();
      const { refreshToken } = await loginTestUser();
      await refresh(refreshToken); // revokes it and issues a new one
      await expect(refresh(refreshToken)).rejects.toThrow(/invalid or expired/i);
    });
  });

  describe('logout()', () => {
    it('should revoke the refresh token', async () => {
      await createTestUser();
      const { refreshToken } = await loginTestUser();
      await logout(refreshToken);

      const hash = hashToken(refreshToken);
      const [row] = await db
        .select()
        .from(refreshTokens)
        .where(sql`${refreshTokens.tokenHash} = ${hash}`);
      expect(row.revokedAt).not.toBeNull();
    });

    it('should not throw for non-existent token', async () => {
      await expect(logout('does-not-exist')).resolves.toBeUndefined();
    });
  });

  describe('createInvitation()', () => {
    it('should create an invitation and return a token', async () => {
      const admin = await createTestUser();
      const { token } = await createInvitation(admin.id, 'invitee@test.com');
      expect(typeof token).toBe('string');
      expect(token.length).toBeGreaterThan(10);

      const hash = hashToken(token);
      const [row] = await db
        .select()
        .from(invitations)
        .where(sql`${invitations.tokenHash} = ${hash}`);
      expect(row.email).toBe('invitee@test.com');
      expect(row.invitedById).toBe(admin.id);
    });

    it('should throw if email is already registered', async () => {
      const admin = await createTestUser();
      await expect(createInvitation(admin.id, admin.email)).rejects.toThrow(
        /already registered/i,
      );
    });
  });

  describe('acceptInvitation()', () => {
    it('should create a member user from valid invitation', async () => {
      const admin = await createTestUser();
      const { token } = await createInvitation(admin.id, 'invitee@test.com');

      const member = await acceptInvitation({
        token,
        password: 'memberpass123',
        name: 'New Member',
      });

      expect(member.email).toBe('invitee@test.com');
      expect(member.role).toBe('member');
      expect(member).not.toHaveProperty('passwordHash');
    });

    it('should mark invitation as accepted', async () => {
      const admin = await createTestUser();
      const { token } = await createInvitation(admin.id, 'invitee@test.com');
      await acceptInvitation({ token, password: 'memberpass123', name: 'New Member' });

      const hash = hashToken(token);
      const [row] = await db
        .select()
        .from(invitations)
        .where(sql`${invitations.tokenHash} = ${hash}`);
      expect(row.acceptedAt).not.toBeNull();
    });

    it('should throw for invalid token', async () => {
      await expect(
        acceptInvitation({ token: 'bogus-token', password: 'memberpass123', name: 'X' }),
      ).rejects.toThrow(/invalid or expired/i);
    });

    it('should throw for expired invitation', async () => {
      const admin = await createTestUser();
      const token = 'expired-invite-token';
      await db.insert(invitations).values({
        email: 'expired@test.com',
        invitedById: admin.id,
        tokenHash: hashToken(token),
        expiresAt: new Date(Date.now() - 1000),
      });

      await expect(
        acceptInvitation({ token, password: 'memberpass123', name: 'X' }),
      ).rejects.toThrow(/invalid or expired/i);
    });

    it('should throw for already-accepted invitation', async () => {
      const admin = await createTestUser();
      const { token } = await createInvitation(admin.id, 'invitee@test.com');
      await acceptInvitation({ token, password: 'memberpass123', name: 'New Member' });

      await expect(
        acceptInvitation({ token, password: 'memberpass123', name: 'New Member' }),
      ).rejects.toThrow(/invalid or expired/i);
    });
  });
});
