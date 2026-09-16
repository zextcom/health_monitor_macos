import { describe, it, expect, beforeEach } from 'vitest';
import { sql } from 'drizzle-orm';
import { db } from '../../src/db/index.js';
import { users, endpoints, endpointSecrets } from '../../src/db/schema.js';
import {
  listEndpoints,
  createEndpoint,
  getEndpoint,
  updateEndpoint,
  deleteEndpoint,
  pauseEndpoint,
  resumeEndpoint,
  importEndpoints,
  exportEndpoints,
} from '../../src/modules/endpoints/endpoints.service.js';
import { decrypt } from '../../src/utils/crypto.js';
import type { CreateEndpointInput, ImportEndpointInput } from '../../src/modules/endpoints/endpoints.schemas.js';

async function createTestUser(email = 'owner@test.com') {
  const [user] = await db
    .insert(users)
    .values({ email, passwordHash: 'hash', name: 'Owner', role: 'admin' })
    .returning();
  return user;
}

function baseEndpointInput(overrides: Partial<CreateEndpointInput> = {}): CreateEndpointInput {
  return {
    name: 'My Endpoint',
    url: 'https://example.com',
    checkType: 'http',
    expectedStatusCode: 200,
    checkInterval: 300,
    groupName: null,
    jsonAssertions: [],
    authType: 'none',
    authUsername: null,
    authHeaderName: null,
    ...overrides,
  };
}

beforeEach(async () => {
  await db.execute(
    sql`TRUNCATE TABLE ${endpointSecrets}, ${endpoints}, ${users} RESTART IDENTITY CASCADE`,
  );
});

describe('endpoints.service', () => {
  describe('listEndpoints()', () => {
    it("should return only the user's endpoints", async () => {
      const user = await createTestUser('a@test.com');
      const other = await createTestUser('b@test.com');
      await createEndpoint(user.id, baseEndpointInput({ name: 'Mine' }));
      await createEndpoint(other.id, baseEndpointInput({ name: 'Theirs' }));

      const result = await listEndpoints(user.id);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('Mine');
    });

    it('should filter by group', async () => {
      const user = await createTestUser();
      await createEndpoint(user.id, baseEndpointInput({ name: 'A', groupName: 'prod' }));
      await createEndpoint(user.id, baseEndpointInput({ name: 'B', groupName: 'staging' }));

      const result = await listEndpoints(user.id, { group: 'prod' });
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('A');
    });

    it('should filter by paused status', async () => {
      const user = await createTestUser();
      const active = await createEndpoint(user.id, baseEndpointInput({ name: 'Active' }));
      const paused = await createEndpoint(user.id, baseEndpointInput({ name: 'Paused' }));
      await pauseEndpoint(user.id, paused.id);

      const pausedResult = await listEndpoints(user.id, { paused: 'true' });
      expect(pausedResult).toHaveLength(1);
      expect(pausedResult[0].name).toBe('Paused');

      const activeResult = await listEndpoints(user.id, { paused: 'false' });
      expect(activeResult).toHaveLength(1);
      expect(activeResult[0].name).toBe('Active');
      expect(active.id).toBe(activeResult[0].id);
    });

    it('should return empty array for user with no endpoints', async () => {
      const user = await createTestUser();
      const result = await listEndpoints(user.id);
      expect(result).toEqual([]);
    });
  });

  describe('createEndpoint()', () => {
    it('should create an endpoint with defaults', async () => {
      const user = await createTestUser();
      const endpoint = await createEndpoint(user.id, baseEndpointInput());
      expect(endpoint.name).toBe('My Endpoint');
      expect(endpoint.isPaused).toBe(false);
      expect(endpoint.checkInterval).toBe(300);
      expect(endpoint.userId).toBe(user.id);
    });

    it('should create an endpoint with all fields', async () => {
      const user = await createTestUser();
      const endpoint = await createEndpoint(
        user.id,
        baseEndpointInput({
          name: 'Full Endpoint',
          url: 'https://full.example.com',
          checkType: 'tcp',
          expectedStatusCode: 201,
          checkInterval: 60,
          groupName: 'prod',
          jsonAssertions: [{ path: '$.status', expectedValue: 'ok', matchMode: 'exact' }],
          authType: 'basic_auth',
          authUsername: 'user1',
          authHeaderName: null,
        }),
      );

      expect(endpoint.name).toBe('Full Endpoint');
      expect(endpoint.checkType).toBe('tcp');
      expect(endpoint.expectedStatusCode).toBe(201);
      expect(endpoint.checkInterval).toBe(60);
      expect(endpoint.groupName).toBe('prod');
      expect(endpoint.jsonAssertions).toEqual([
        { path: '$.status', expectedValue: 'ok', matchMode: 'exact' },
      ]);
      expect(endpoint.authType).toBe('basic_auth');
      expect(endpoint.authUsername).toBe('user1');
    });

    it('should encrypt and store auth secret', async () => {
      const user = await createTestUser();
      const endpoint = await createEndpoint(
        user.id,
        baseEndpointInput({ authType: 'bearer_token', authSecret: 'super-secret-token' }),
      );

      const [secretRow] = await db
        .select()
        .from(endpointSecrets)
        .where(sql`${endpointSecrets.endpointId} = ${endpoint.id}`);

      expect(secretRow).toBeDefined();
      expect(secretRow.encryptedValue).not.toContain('super-secret-token');
      expect(decrypt(secretRow.encryptedValue, secretRow.iv)).toBe('super-secret-token');
    });
  });

  describe('getEndpoint()', () => {
    it('should return the endpoint for the owner', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(user.id, baseEndpointInput());
      const fetched = await getEndpoint(user.id, created.id);
      expect(fetched.id).toBe(created.id);
    });

    it('should throw for non-existent endpoint', async () => {
      const user = await createTestUser();
      await expect(
        getEndpoint(user.id, '00000000-0000-0000-0000-000000000000'),
      ).rejects.toThrow(/not found/i);
    });

    it('should throw for endpoint owned by another user', async () => {
      const user = await createTestUser('a@test.com');
      const other = await createTestUser('b@test.com');
      const created = await createEndpoint(other.id, baseEndpointInput());
      await expect(getEndpoint(user.id, created.id)).rejects.toThrow(/not found/i);
    });
  });

  describe('updateEndpoint()', () => {
    it('should update specified fields', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(user.id, baseEndpointInput());
      const updated = await updateEndpoint(user.id, created.id, { name: 'Renamed', checkInterval: 120 });
      expect(updated.name).toBe('Renamed');
      expect(updated.checkInterval).toBe(120);
    });

    it('should update auth secret (upsert)', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(
        user.id,
        baseEndpointInput({ authType: 'bearer_token', authSecret: 'first-secret' }),
      );

      await updateEndpoint(user.id, created.id, { authSecret: 'second-secret' });

      const rows = await db
        .select()
        .from(endpointSecrets)
        .where(sql`${endpointSecrets.endpointId} = ${created.id}`);
      expect(rows).toHaveLength(1);
      expect(decrypt(rows[0].encryptedValue, rows[0].iv)).toBe('second-secret');
    });

    it('should throw for non-existent endpoint', async () => {
      const user = await createTestUser();
      await expect(
        updateEndpoint(user.id, '00000000-0000-0000-0000-000000000000', { name: 'X' }),
      ).rejects.toThrow(/not found/i);
    });
  });

  describe('deleteEndpoint()', () => {
    it('should delete the endpoint', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(user.id, baseEndpointInput());
      await deleteEndpoint(user.id, created.id);

      const rows = await db.select().from(endpoints).where(sql`${endpoints.id} = ${created.id}`);
      expect(rows).toHaveLength(0);
    });

    it('should throw for non-existent endpoint', async () => {
      const user = await createTestUser();
      await expect(
        deleteEndpoint(user.id, '00000000-0000-0000-0000-000000000000'),
      ).rejects.toThrow(/not found/i);
    });

    it('should cascade delete related records (secrets)', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(
        user.id,
        baseEndpointInput({ authType: 'bearer_token', authSecret: 'to-be-deleted' }),
      );
      await deleteEndpoint(user.id, created.id);

      const secretRows = await db
        .select()
        .from(endpointSecrets)
        .where(sql`${endpointSecrets.endpointId} = ${created.id}`);
      expect(secretRows).toHaveLength(0);
    });
  });

  describe('pauseEndpoint() / resumeEndpoint()', () => {
    it('should set isPaused to true', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(user.id, baseEndpointInput());
      const paused = await pauseEndpoint(user.id, created.id);
      expect(paused.isPaused).toBe(true);
    });

    it('should set isPaused to false', async () => {
      const user = await createTestUser();
      const created = await createEndpoint(user.id, baseEndpointInput());
      await pauseEndpoint(user.id, created.id);
      const resumed = await resumeEndpoint(user.id, created.id);
      expect(resumed.isPaused).toBe(false);
    });
  });

  describe('importEndpoints()', () => {
    it('should import new endpoints (created count)', async () => {
      const user = await createTestUser();
      const items: ImportEndpointInput[] = [
        { name: 'Imported 1', url: 'https://one.example.com', checkType: 'http', expectedStatusCode: 200, jsonAssertions: [], authType: 'none' },
        { name: 'Imported 2', url: 'https://two.example.com', checkType: 'http', expectedStatusCode: 200, jsonAssertions: [], authType: 'none' },
      ];
      const result = await importEndpoints(user.id, items);
      expect(result.created).toBe(2);
      expect(result.updated).toBe(0);

      const all = await listEndpoints(user.id);
      expect(all).toHaveLength(2);
    });

    it('should update existing endpoints by id (updated count)', async () => {
      const user = await createTestUser();
      const existing = await createEndpoint(user.id, baseEndpointInput({ name: 'Original' }));

      const result = await importEndpoints(user.id, [
        {
          id: existing.id,
          name: 'Updated Name',
          url: existing.url,
          checkType: 'http',
          expectedStatusCode: 200,
          jsonAssertions: [],
          authType: 'none',
        },
      ]);

      expect(result.created).toBe(0);
      expect(result.updated).toBe(1);

      const fetched = await getEndpoint(user.id, existing.id);
      expect(fetched.name).toBe('Updated Name');
    });

    it('should map macOS field names (group -> groupName, checkIntervalOverride -> checkInterval, bearerToken -> bearer_token)', async () => {
      const user = await createTestUser();
      const result = await importEndpoints(user.id, [
        {
          name: 'Mapped',
          url: 'https://mapped.example.com',
          checkType: 'http',
          expectedStatusCode: 200,
          group: 'prod-group',
          checkIntervalOverride: 45,
          jsonAssertions: [],
          authType: 'bearerToken',
        },
      ]);

      expect(result.created).toBe(1);
      const all = await listEndpoints(user.id);
      expect(all[0].groupName).toBe('prod-group');
      expect(all[0].checkInterval).toBe(45);
      expect(all[0].authType).toBe('bearer_token');
    });
  });

  describe('exportEndpoints()', () => {
    it('should return all user endpoints', async () => {
      const user = await createTestUser();
      await createEndpoint(user.id, baseEndpointInput({ name: 'One' }));
      await createEndpoint(user.id, baseEndpointInput({ name: 'Two' }));

      const result = await exportEndpoints(user.id);
      expect(result).toHaveLength(2);
      expect(result.map((e) => e.name).sort()).toEqual(['One', 'Two']);
    });
  });
});
