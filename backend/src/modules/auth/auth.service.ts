import bcrypt from 'bcrypt';
import { and, count, eq, gt, isNull } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { invitations, refreshTokens, users, type User } from '../../db/schema.js';
import { env } from '../../config/env.js';
import { generateToken, hashToken } from '../../utils/crypto.js';
import type { AcceptInviteInput, LoginInput, RegisterInput } from './auth.schemas.js';

const SALT_ROUNDS = 12;
const INVITATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const DURATION_UNITS: Record<string, number> = {
  ms: 1,
  s: 1000,
  m: 60 * 1000,
  h: 60 * 60 * 1000,
  d: 24 * 60 * 60 * 1000,
};

function parseDurationMs(duration: string): number {
  const match = /^(\d+)\s*(ms|s|m|h|d)?$/.exec(duration.trim());
  if (!match) {
    throw new Error(`Invalid duration string: ${duration}`);
  }
  const [, amount, unit = 'ms'] = match;
  return Number(amount) * DURATION_UNITS[unit];
}

function stripPasswordHash(user: User): Omit<User, 'passwordHash'> {
  const { passwordHash: _passwordHash, ...rest } = user;
  return rest;
}

async function findUserByEmail(email: string) {
  const [user] = await db.select().from(users).where(eq(users.email, email));
  return user;
}

export async function register(data: RegisterInput): Promise<Omit<User, 'passwordHash'>> {
  const [{ value: userCount }] = await db.select({ value: count() }).from(users);

  if (userCount > 0) {
    throw new Error('Registration is invite-only; ask an administrator for an invitation');
  }

  const passwordHash = await bcrypt.hash(data.password, SALT_ROUNDS);
  const [user] = await db
    .insert(users)
    .values({ email: data.email, passwordHash, name: data.name, role: 'admin' })
    .returning();

  return stripPasswordHash(user);
}

export async function login(
  data: LoginInput,
): Promise<{ user: Omit<User, 'passwordHash'>; refreshToken: string }> {
  const user = await findUserByEmail(data.email);
  if (!user) {
    throw new Error('Invalid email or password');
  }

  const passwordValid = await bcrypt.compare(data.password, user.passwordHash);
  if (!passwordValid) {
    throw new Error('Invalid email or password');
  }

  const refreshToken = generateToken();
  await db.insert(refreshTokens).values({
    userId: user.id,
    tokenHash: hashToken(refreshToken),
    expiresAt: new Date(Date.now() + parseDurationMs(env.REFRESH_TOKEN_EXPIRES_IN)),
  });

  return { user: stripPasswordHash(user), refreshToken };
}

export async function refresh(
  tokenStr: string,
): Promise<{ userId: string; role: string; newRefreshToken: string }> {
  const tokenHash = hashToken(tokenStr);
  const now = new Date();

  const [existing] = await db
    .select()
    .from(refreshTokens)
    .where(
      and(
        eq(refreshTokens.tokenHash, tokenHash),
        isNull(refreshTokens.revokedAt),
        gt(refreshTokens.expiresAt, now),
      ),
    );

  if (!existing) {
    throw new Error('Invalid or expired refresh token');
  }

  const [user] = await db.select().from(users).where(eq(users.id, existing.userId));
  if (!user) {
    throw new Error('Invalid or expired refresh token');
  }

  await db
    .update(refreshTokens)
    .set({ revokedAt: now })
    .where(eq(refreshTokens.id, existing.id));

  const newRefreshToken = generateToken();
  await db.insert(refreshTokens).values({
    userId: user.id,
    tokenHash: hashToken(newRefreshToken),
    expiresAt: new Date(Date.now() + parseDurationMs(env.REFRESH_TOKEN_EXPIRES_IN)),
  });

  return { userId: user.id, role: user.role, newRefreshToken };
}

export async function logout(tokenStr: string): Promise<void> {
  const tokenHash = hashToken(tokenStr);
  await db
    .update(refreshTokens)
    .set({ revokedAt: new Date() })
    .where(and(eq(refreshTokens.tokenHash, tokenHash), isNull(refreshTokens.revokedAt)));
}

export async function createInvitation(
  invitedById: string,
  email: string,
): Promise<{ token: string }> {
  const existingUser = await findUserByEmail(email);
  if (existingUser) {
    throw new Error('A user with this email is already registered');
  }

  const token = generateToken();
  await db.insert(invitations).values({
    email,
    invitedById,
    tokenHash: hashToken(token),
    expiresAt: new Date(Date.now() + INVITATION_TTL_MS),
  });

  return { token };
}

export async function acceptInvitation(
  data: AcceptInviteInput,
): Promise<Omit<User, 'passwordHash'>> {
  const tokenHash = hashToken(data.token);

  const [invitation] = await db
    .select()
    .from(invitations)
    .where(
      and(
        eq(invitations.tokenHash, tokenHash),
        isNull(invitations.acceptedAt),
        gt(invitations.expiresAt, new Date()),
      ),
    );

  if (!invitation) {
    throw new Error('Invalid or expired invitation');
  }

  const existingUser = await findUserByEmail(invitation.email);
  if (existingUser) {
    throw new Error('A user with this email is already registered');
  }

  const passwordHash = await bcrypt.hash(data.password, SALT_ROUNDS);
  const [user] = await db
    .insert(users)
    .values({ email: invitation.email, passwordHash, name: data.name, role: 'member' })
    .returning();

  await db
    .update(invitations)
    .set({ acceptedAt: new Date() })
    .where(eq(invitations.id, invitation.id));

  return stripPasswordHash(user);
}
