import type { Endpoint, JsonAssertion } from '../../db/schema.js';

/**
 * Pure helpers shared by the health check worker and the version check. Kept out of
 * `checks.worker.ts` because importing that module opens Redis connections.
 */

/** The auth-related subset of an endpoint — also satisfied by a `VersionCheckConfig`. */
export type AuthConfig = Pick<Endpoint, 'authType' | 'authUsername' | 'authHeaderName'>;

export function buildAuthHeaders(endpoint: AuthConfig, secret: string | null): Record<string, string> {
  if (!secret) {
    return {};
  }

  switch (endpoint.authType) {
    case 'bearer_token':
      return { Authorization: `Bearer ${secret}` };
    case 'basic_auth': {
      const credentials = Buffer.from(`${endpoint.authUsername ?? ''}:${secret}`).toString('base64');
      return { Authorization: `Basic ${credentials}` };
    }
    case 'custom_header':
      return endpoint.authHeaderName ? { [endpoint.authHeaderName]: secret } : {};
    default:
      return {};
  }
}

export function getByPath(obj: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((acc, key) => {
    if (acc && typeof acc === 'object' && key in (acc as Record<string, unknown>)) {
      return (acc as Record<string, unknown>)[key];
    }
    return undefined;
  }, obj);
}

export function matchesAssertion(
  value: unknown,
  expectedValue: string,
  matchMode: JsonAssertion['matchMode'],
): boolean {
  const stringValue = value === undefined || value === null ? '' : String(value);

  switch (matchMode) {
    case 'exact':
      return stringValue === expectedValue;
    case 'contains':
      return stringValue.includes(expectedValue);
    case 'regex':
      return new RegExp(expectedValue).test(stringValue);
    default:
      return false;
  }
}

/** ANDs `assertions` against an already-parsed JSON body; the first failing one gives the reason. */
export function evaluateAssertions(
  body: unknown,
  assertions: JsonAssertion[],
): { passed: boolean; reason: string | null } {
  for (const assertion of assertions) {
    const value = getByPath(body, assertion.path);
    let matched: boolean;
    try {
      matched = matchesAssertion(value, assertion.expectedValue, assertion.matchMode);
    } catch {
      matched = false; // invalid regex never matches
    }
    if (!matched) {
      return {
        passed: false,
        reason: `Assertion failed: "${assertion.path}" did not match "${assertion.expectedValue}"`,
      };
    }
  }
  return { passed: true, reason: null };
}
