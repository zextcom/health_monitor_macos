import { and, eq } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { endpoints, endpointSecrets, type Endpoint, type NewEndpoint } from '../../db/schema.js';
import { encrypt } from '../../utils/crypto.js';
import { publishScheduleSync } from '../checks/schedule-sync.js';
import type {
  CreateEndpointInput,
  UpdateEndpointInput,
  ImportEndpointInput,
} from './endpoints.schemas.js';

interface ListFilters {
  group?: string;
  paused?: string;
}

const importAuthTypeMap: Record<string, 'none' | 'bearer_token' | 'basic_auth' | 'custom_header'> = {
  none: 'none',
  bearerToken: 'bearer_token',
  basicAuth: 'basic_auth',
  customHeader: 'custom_header',
};

export async function listEndpoints(userId: string, filters: ListFilters = {}): Promise<Endpoint[]> {
  const conditions = [eq(endpoints.userId, userId)];

  if (filters.group !== undefined) {
    conditions.push(eq(endpoints.groupName, filters.group));
  }
  if (filters.paused !== undefined) {
    conditions.push(eq(endpoints.isPaused, filters.paused === 'true'));
  }

  return db.query.endpoints.findMany({
    where: and(...conditions),
    orderBy: (endpoint, { asc }) => [asc(endpoint.name)],
  });
}

export async function getEndpoint(userId: string, endpointId: string): Promise<Endpoint> {
  const endpoint = await db.query.endpoints.findFirst({
    where: and(eq(endpoints.id, endpointId), eq(endpoints.userId, userId)),
  });

  if (!endpoint) {
    throw new Error('Endpoint not found');
  }

  return endpoint;
}

export async function createEndpoint(userId: string, data: CreateEndpointInput): Promise<Endpoint> {
  const { authSecret, ...rest } = data;

  const [endpoint] = await db
    .insert(endpoints)
    .values({
      ...rest,
      userId,
    } satisfies NewEndpoint)
    .returning();

  if (authSecret) {
    const { encrypted, iv } = encrypt(authSecret);
    await db.insert(endpointSecrets).values({
      endpointId: endpoint.id,
      encryptedValue: encrypted,
      iv,
    });
  }

  await publishScheduleSync({
    action: 'upsert',
    endpointId: endpoint.id,
    checkInterval: endpoint.checkInterval,
  });

  return endpoint;
}

export async function updateEndpoint(
  userId: string,
  endpointId: string,
  data: UpdateEndpointInput,
): Promise<Endpoint> {
  await getEndpoint(userId, endpointId);

  const { authSecret, ...rest } = data;

  if (authSecret) {
    const { encrypted, iv } = encrypt(authSecret);
    await db
      .insert(endpointSecrets)
      .values({ endpointId, encryptedValue: encrypted, iv })
      .onConflictDoUpdate({
        target: endpointSecrets.endpointId,
        set: { encryptedValue: encrypted, iv, updatedAt: new Date() },
      });
  }

  const [updated] = await db
    .update(endpoints)
    .set({ ...rest, updatedAt: new Date() })
    .where(and(eq(endpoints.id, endpointId), eq(endpoints.userId, userId)))
    .returning();

  await publishScheduleSync({
    action: 'upsert',
    endpointId: updated.id,
    checkInterval: updated.checkInterval,
  });

  return updated;
}

export async function deleteEndpoint(userId: string, endpointId: string): Promise<void> {
  await getEndpoint(userId, endpointId);
  await db.delete(endpoints).where(and(eq(endpoints.id, endpointId), eq(endpoints.userId, userId)));
  await publishScheduleSync({ action: 'remove', endpointId });
}

export async function pauseEndpoint(userId: string, endpointId: string): Promise<Endpoint> {
  await getEndpoint(userId, endpointId);

  const [updated] = await db
    .update(endpoints)
    .set({ isPaused: true, updatedAt: new Date() })
    .where(and(eq(endpoints.id, endpointId), eq(endpoints.userId, userId)))
    .returning();

  await publishScheduleSync({ action: 'remove', endpointId });

  return updated;
}

export async function resumeEndpoint(userId: string, endpointId: string): Promise<Endpoint> {
  await getEndpoint(userId, endpointId);

  const [updated] = await db
    .update(endpoints)
    .set({ isPaused: false, updatedAt: new Date() })
    .where(and(eq(endpoints.id, endpointId), eq(endpoints.userId, userId)))
    .returning();

  await publishScheduleSync({
    action: 'upsert',
    endpointId: updated.id,
    checkInterval: updated.checkInterval,
  });

  return updated;
}

export async function importEndpoints(
  userId: string,
  data: ImportEndpointInput[],
): Promise<{ created: number; updated: number }> {
  let created = 0;
  let updated = 0;

  for (const item of data) {
    const { id, group, checkIntervalOverride, authType, ...rest } = item;

    const values: NewEndpoint = {
      ...rest,
      userId,
      groupName: group ?? null,
      checkInterval: checkIntervalOverride ?? 300,
      authType: importAuthTypeMap[authType] ?? 'none',
    };

    let existing: Endpoint | undefined;
    if (id) {
      existing = await db.query.endpoints.findFirst({
        where: and(eq(endpoints.id, id), eq(endpoints.userId, userId)),
      });
    }

    if (existing) {
      const [row] = await db
        .update(endpoints)
        .set({ ...values, updatedAt: new Date() })
        .where(and(eq(endpoints.id, id!), eq(endpoints.userId, userId)))
        .returning();
      updated += 1;
      await publishScheduleSync(
        row.isPaused
          ? { action: 'remove', endpointId: row.id }
          : { action: 'upsert', endpointId: row.id, checkInterval: row.checkInterval },
      );
    } else {
      const [row] = await db.insert(endpoints).values(id ? { ...values, id } : values).returning();
      created += 1;
      await publishScheduleSync(
        row.isPaused
          ? { action: 'remove', endpointId: row.id }
          : { action: 'upsert', endpointId: row.id, checkInterval: row.checkInterval },
      );
    }
  }

  return { created, updated };
}

export async function exportEndpoints(userId: string): Promise<Endpoint[]> {
  return listEndpoints(userId);
}
