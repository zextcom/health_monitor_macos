import { describe, it, expect, afterAll } from 'vitest';
import {
  buildAuthHeaders,
  getByPath,
  matchesAssertion,
  stopWorker,
} from '../../src/modules/checks/checks.worker.js';
import type { Endpoint } from '../../src/db/schema.js';

function baseEndpoint(overrides: Partial<Endpoint> = {}): Endpoint {
  return {
    id: '00000000-0000-0000-0000-000000000001',
    userId: '00000000-0000-0000-0000-000000000002',
    name: 'Test Endpoint',
    url: 'https://example.com',
    checkType: 'http',
    expectedStatusCode: 200,
    checkInterval: 300,
    groupName: null,
    jsonAssertions: [],
    authType: 'none',
    authUsername: null,
    authHeaderName: null,
    isPaused: false,
    createdAt: new Date(),
    updatedAt: new Date(),
    ...overrides,
  };
}

afterAll(async () => {
  await stopWorker();
});

describe('checks.worker helpers', () => {
  describe('getByPath()', () => {
    it('should get a top-level property', () => {
      expect(getByPath({ status: 'ok' }, 'status')).toBe('ok');
    });

    it('should get a nested property via dot notation', () => {
      expect(getByPath({ data: { status: 'ok' } }, 'data.status')).toBe('ok');
    });

    it('should return undefined for a missing path', () => {
      expect(getByPath({ data: { status: 'ok' } }, 'data.missing')).toBeUndefined();
      expect(getByPath({ data: { status: 'ok' } }, 'nope.status')).toBeUndefined();
    });

    it('should handle null/undefined input', () => {
      expect(getByPath(null, 'status')).toBeUndefined();
      expect(getByPath(undefined, 'status')).toBeUndefined();
    });

    it('should handle arrays in path', () => {
      expect(getByPath({ items: { 0: { status: 'ok' } } }, 'items.0.status')).toBe('ok');
    });
  });

  describe('matchesAssertion()', () => {
    it('exact mode: should match exact string', () => {
      expect(matchesAssertion('ok', 'ok', 'exact')).toBe(true);
    });

    it('exact mode: should not match different string', () => {
      expect(matchesAssertion('ok', 'not-ok', 'exact')).toBe(false);
    });

    it('contains mode: should match substring', () => {
      expect(matchesAssertion('all systems ok', 'ok', 'contains')).toBe(true);
    });

    it('contains mode: should not match when not present', () => {
      expect(matchesAssertion('all systems down', 'ok', 'contains')).toBe(false);
    });

    it('regex mode: should match regex pattern', () => {
      expect(matchesAssertion('v1.2.3', '^v\\d+\\.\\d+\\.\\d+$', 'regex')).toBe(true);
    });

    it('regex mode: should not match non-matching regex', () => {
      expect(matchesAssertion('not-a-version', '^v\\d+\\.\\d+\\.\\d+$', 'regex')).toBe(false);
    });

    it('should convert non-string values to string', () => {
      expect(matchesAssertion(200, '200', 'exact')).toBe(true);
      expect(matchesAssertion(true, 'true', 'exact')).toBe(true);
    });

    it('should treat undefined/null as empty string', () => {
      expect(matchesAssertion(undefined, '', 'exact')).toBe(true);
      expect(matchesAssertion(null, '', 'exact')).toBe(true);
      expect(matchesAssertion(undefined, 'ok', 'exact')).toBe(false);
    });
  });

  describe('buildAuthHeaders()', () => {
    it('should return empty for no secret', () => {
      const endpoint = baseEndpoint({ authType: 'bearer_token' });
      expect(buildAuthHeaders(endpoint, null)).toEqual({});
    });

    it('should return Bearer header for bearer_token auth type', () => {
      const endpoint = baseEndpoint({ authType: 'bearer_token' });
      expect(buildAuthHeaders(endpoint, 'my-token')).toEqual({
        Authorization: 'Bearer my-token',
      });
    });

    it('should return Basic header for basic_auth type', () => {
      const endpoint = baseEndpoint({ authType: 'basic_auth', authUsername: 'alice' });
      const expected = Buffer.from('alice:secret').toString('base64');
      expect(buildAuthHeaders(endpoint, 'secret')).toEqual({
        Authorization: `Basic ${expected}`,
      });
    });

    it('should return custom header for custom_header type', () => {
      const endpoint = baseEndpoint({ authType: 'custom_header', authHeaderName: 'X-Api-Key' });
      expect(buildAuthHeaders(endpoint, 'my-key')).toEqual({ 'X-Api-Key': 'my-key' });
    });

    it("should return empty for 'none' auth type", () => {
      const endpoint = baseEndpoint({ authType: 'none' });
      expect(buildAuthHeaders(endpoint, 'irrelevant')).toEqual({});
    });
  });
});
