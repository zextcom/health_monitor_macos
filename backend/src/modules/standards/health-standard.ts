import type { HealthComponent, HealthStatus } from '../../db/schema.js';

/**
 * Zext Health Standard v1 (`zext-health/v1`) — the single source of truth for the rules, examples
 * and JSON Schema served by `GET /api/standards/health`, plus the pure parsing helpers shared by
 * the validator (`health-standard-validator.ts`) and the check worker. `docs/health-standard.md`
 * is the human handout; `test/unit/health-standard-doc.test.ts` keeps its examples in sync.
 *
 * Based on the IETF draft "Health Check Response Format for HTTP APIs"
 * (draft-inadarei-api-health-check, `application/health+json`).
 */

export const HEALTH_STANDARD_ID = 'zext-health/v1';
export const HEALTH_MEDIA_TYPE = 'application/health+json';
export const HEALTH_STATUSES: readonly HealthStatus[] = ['pass', 'warn', 'fail'];

/** HTTP status a response with the given body `status` MUST use. */
export const HTTP_STATUS_FOR: Record<HealthStatus, number> = { pass: 200, warn: 200, fail: 503 };

/** Responses slower than this are flagged (SHOULD respond within 1s). */
export const RESPONSE_TIME_LIMIT_MS = 1000;

export type RuleLevel = 'must' | 'should';

export interface HealthStandardRule {
  id: string;
  level: RuleLevel;
  text: string;
}

export const HEALTH_STANDARD_RULES: HealthStandardRule[] = [
  { id: 'json-body', level: 'must', text: 'The response body MUST be a single JSON object.' },
  { id: 'status-field', level: 'must', text: 'The body MUST contain "status" with one of "pass", "warn" or "fail".' },
  {
    id: 'http-status',
    level: 'must',
    text: 'The HTTP status MUST be 200 when status is "pass" or "warn", and 503 when status is "fail".',
  },
  {
    id: 'check-entries',
    level: 'must',
    text: 'If present, "checks" MUST be an object whose keys are "component:measurement" names and whose values are arrays of objects, each with a valid "status".',
  },
  {
    id: 'field-types',
    level: 'must',
    text: 'Optional fields, when present, MUST have the documented types (strings; "notes" an array of strings; "observedValue" a number, string or boolean; "time" an ISO 8601 timestamp).',
  },
  {
    id: 'worst-of-checks',
    level: 'must',
    text: 'The overall "status" MUST be the worst status of all check entries (fail > warn > pass).',
  },
  {
    id: 'no-sensitive-data',
    level: 'must',
    text: 'The body MUST NOT contain secrets or tokens, file system paths, internal hostnames or IP addresses, connection strings, stack traces or user data.',
  },
  { id: 'no-auth', level: 'must', text: 'The endpoint MUST NOT require authentication.' },
  { id: 'path', level: 'should', text: 'The endpoint SHOULD be served at GET /health.' },
  { id: 'version', level: 'should', text: 'The body SHOULD contain "version", the human-readable version (e.g. "1.4.2").' },
  {
    id: 'release-id',
    level: 'should',
    text: 'The body SHOULD contain "releaseId", the deploy identifier (e.g. a git SHA or build number).',
  },
  {
    id: 'content-type',
    level: 'should',
    text: 'The response SHOULD use Content-Type: application/health+json (application/json is tolerated).',
  },
  { id: 'cache-control', level: 'should', text: 'The response SHOULD send Cache-Control: no-store.' },
  {
    id: 'response-time',
    level: 'should',
    text: 'The endpoint SHOULD respond within 1 second; dependency checks SHOULD be cached for at most 30 seconds and individually time-limited.',
  },
  {
    id: 'output-on-problem',
    level: 'should',
    text: 'When status is "warn" or "fail", "output" SHOULD give a short, human-readable reason.',
  },
];

export interface HealthStandardExample {
  httpStatus: number;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

const exampleHeaders = { 'Content-Type': HEALTH_MEDIA_TYPE, 'Cache-Control': 'no-store' };

export const HEALTH_STANDARD_EXAMPLES: Record<HealthStatus, HealthStandardExample> = {
  pass: {
    httpStatus: 200,
    headers: exampleHeaders,
    body: {
      status: 'pass',
      version: '1.4.2',
      releaseId: '9f2c1ab7e4d3',
      serviceId: 'billing-api',
      description: 'Billing API',
      checks: {
        'postgres:responseTime': [
          {
            componentType: 'datastore',
            status: 'pass',
            observedValue: 12,
            observedUnit: 'ms',
            time: '2026-10-11T09:30:00Z',
          },
        ],
        'redis:responseTime': [
          {
            componentType: 'datastore',
            status: 'pass',
            observedValue: 2,
            observedUnit: 'ms',
            time: '2026-10-11T09:30:00Z',
          },
        ],
        'disk:utilization': [
          {
            componentType: 'system',
            status: 'pass',
            observedValue: 41.5,
            observedUnit: 'percent',
            time: '2026-10-11T09:30:00Z',
          },
        ],
      },
    },
  },
  warn: {
    httpStatus: 200,
    headers: exampleHeaders,
    body: {
      status: 'warn',
      version: '1.4.2',
      releaseId: '9f2c1ab7e4d3',
      serviceId: 'billing-api',
      output: 'Disk usage above 85%',
      checks: {
        'postgres:responseTime': [
          {
            componentType: 'datastore',
            status: 'pass',
            observedValue: 14,
            observedUnit: 'ms',
            time: '2026-10-11T09:30:00Z',
          },
        ],
        'disk:utilization': [
          {
            componentType: 'system',
            status: 'warn',
            observedValue: 87.2,
            observedUnit: 'percent',
            time: '2026-10-11T09:30:00Z',
            output: 'Disk usage above 85%',
          },
        ],
      },
    },
  },
  fail: {
    httpStatus: 503,
    headers: exampleHeaders,
    body: {
      status: 'fail',
      version: '1.4.2',
      releaseId: '9f2c1ab7e4d3',
      serviceId: 'billing-api',
      output: 'Database unreachable',
      checks: {
        'postgres:responseTime': [
          {
            componentType: 'datastore',
            status: 'fail',
            time: '2026-10-11T09:30:00Z',
            output: 'Database unreachable',
          },
        ],
        'redis:responseTime': [
          {
            componentType: 'datastore',
            status: 'pass',
            observedValue: 3,
            observedUnit: 'ms',
            time: '2026-10-11T09:30:00Z',
          },
        ],
      },
    },
  },
};

/** JSON Schema (draft 2020-12) of the response body. Unknown extra fields are allowed. */
export const HEALTH_STANDARD_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'https://health.zext.dev/api/standards/health/schema.json',
  title: 'Zext Health Standard v1 response body',
  description: `Body of a ${HEALTH_STANDARD_ID} health endpoint (${HEALTH_MEDIA_TYPE}).`,
  type: 'object',
  required: ['status'],
  properties: {
    status: { $ref: '#/$defs/status' },
    version: { type: 'string', description: 'Human-readable version, e.g. "1.4.2".' },
    releaseId: { type: 'string', description: 'Deploy identifier, e.g. a git SHA or build number.' },
    serviceId: { type: 'string', description: 'Stable service identifier.' },
    description: { type: 'string' },
    notes: { type: 'array', items: { type: 'string' } },
    output: { type: 'string', description: 'Short reason when status is warn or fail. Never a stack trace.' },
    checks: {
      type: 'object',
      description: 'Keys are "component:measurement" names, e.g. "postgres:responseTime".',
      additionalProperties: { type: 'array', items: { $ref: '#/$defs/check' } },
    },
  },
  additionalProperties: true,
  $defs: {
    status: { type: 'string', enum: [...HEALTH_STATUSES] },
    check: {
      type: 'object',
      required: ['status'],
      properties: {
        status: { $ref: '#/$defs/status' },
        componentId: { type: 'string' },
        componentType: { type: 'string', description: 'e.g. "datastore", "system", "component".' },
        observedValue: { type: ['number', 'string', 'boolean'] },
        observedUnit: { type: 'string', description: 'e.g. "ms", "percent".' },
        time: { type: 'string', format: 'date-time' },
        output: { type: 'string' },
      },
      additionalProperties: true,
    },
  },
} as const;

export const HEALTH_STANDARD_DOCUMENT = {
  id: HEALTH_STANDARD_ID,
  title: 'Zext Health Standard v1',
  summary:
    'GET /health returns application/health+json with a "status" of pass, warn or fail (HTTP 200, 200, 503), ' +
    'the running version and releaseId, and optional per-dependency "checks". No auth, no secrets, under 1s.',
  mediaType: HEALTH_MEDIA_TYPE,
  rules: HEALTH_STANDARD_RULES,
  examples: HEALTH_STANDARD_EXAMPLES,
  schema: HEALTH_STANDARD_SCHEMA,
};

// ── Shared parsing helpers (pure) ──

const SEVERITY: Record<HealthStatus, number> = { pass: 0, warn: 1, fail: 2 };

export function isHealthStatus(value: unknown): value is HealthStatus {
  return typeof value === 'string' && (HEALTH_STATUSES as readonly string[]).includes(value);
}

/** fail > warn > pass; `pass` for an empty list. */
export function worstStatus(statuses: Iterable<HealthStatus>): HealthStatus {
  let worst: HealthStatus = 'pass';
  for (const status of statuses) {
    if (SEVERITY[status] > SEVERITY[worst]) {
      worst = status;
    }
  }
  return worst;
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Trimmed non-empty string, or `null`. Numbers are accepted leniently (e.g. a numeric build id). */
function optionalText(value: unknown): string | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value);
  }
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}

const MAX_COMPONENTS = 50;
const MAX_TEXT_LENGTH = 300;

function clip(value: string): string {
  return value.length > MAX_TEXT_LENGTH ? `${value.slice(0, MAX_TEXT_LENGTH - 1)}…` : value;
}

export interface ParsedHealthResponse {
  status: HealthStatus;
  version: string | null;
  releaseId: string | null;
  output: string | null;
  /** Flattened, lenient view of `checks` (malformed entries skipped, capped, long text clipped). */
  components: HealthComponent[];
}

/**
 * Lenient parse used by the monitor: only `status` is required. Everything else is best-effort, so a
 * service with a slightly malformed `checks` entry is still monitored by its declared overall status
 * (the validator is where strictness lives).
 */
export function parseHealthBody(
  body: unknown,
): { ok: true; value: ParsedHealthResponse } | { ok: false; error: string } {
  if (!isPlainObject(body)) {
    return { ok: false, error: 'body is not a JSON object' };
  }
  if (!('status' in body)) {
    return { ok: false, error: 'missing "status"' };
  }
  if (!isHealthStatus(body.status)) {
    return { ok: false, error: `invalid status ${JSON.stringify(body.status)}` };
  }

  const components: HealthComponent[] = [];
  if (isPlainObject(body.checks)) {
    for (const [key, entries] of Object.entries(body.checks)) {
      if (!Array.isArray(entries)) {
        continue;
      }
      for (const entry of entries) {
        if (components.length >= MAX_COMPONENTS || !isPlainObject(entry) || !isHealthStatus(entry.status)) {
          continue;
        }
        const component: HealthComponent = { key: clip(key), status: entry.status };
        const componentId = optionalText(entry.componentId);
        const componentType = optionalText(entry.componentType);
        const observedUnit = optionalText(entry.observedUnit);
        const time = optionalText(entry.time);
        const output = optionalText(entry.output);
        if (componentId) component.componentId = clip(componentId);
        if (componentType) component.componentType = clip(componentType);
        if (
          typeof entry.observedValue === 'number' ||
          typeof entry.observedValue === 'boolean' ||
          typeof entry.observedValue === 'string'
        ) {
          component.observedValue =
            typeof entry.observedValue === 'string' ? clip(entry.observedValue) : entry.observedValue;
        }
        if (observedUnit) component.observedUnit = clip(observedUnit);
        if (time) component.time = time;
        if (output) component.output = clip(output);
        components.push(component);
      }
    }
  }

  const output = optionalText(body.output);
  return {
    ok: true,
    value: {
      status: body.status,
      version: optionalText(body.version),
      releaseId: optionalText(body.releaseId),
      output: output ? clip(output) : null,
      components,
    },
  };
}

/**
 * Reason shown for a warn/fail response: top-level `output`, else the first non-pass component as
 * `"<key>: <status>[ — output]"`, else a generic `Health status "<status>"`. `null` for pass.
 */
export function healthReason(parsed: Pick<ParsedHealthResponse, 'status' | 'output' | 'components'>): string | null {
  if (parsed.status === 'pass') {
    return null;
  }
  if (parsed.output) {
    return parsed.output;
  }
  const firstProblem = parsed.components.find((component) => component.status !== 'pass');
  if (firstProblem) {
    return firstProblem.output
      ? `${firstProblem.key}: ${firstProblem.status} — ${firstProblem.output}`
      : `${firstProblem.key}: ${firstProblem.status}`;
  }
  return `Health status "${parsed.status}"`;
}

/**
 * Value fed into version tracking for health-standard endpoints without an explicit version check:
 * `"<version> (<releaseId first 7>)"` when both exist, else whichever exists, else `null`.
 */
export function trackedVersionValue(version: string | null, releaseId: string | null): string | null {
  const v = version?.trim() || null;
  const r = releaseId?.trim() || null;
  if (v && r) {
    return `${v} (${r.slice(0, 7)})`;
  }
  return v ?? r;
}

export interface StandardEvaluation {
  isHealthy: boolean;
  /** Body `status` when the body could be read, else `null`. */
  healthStatus: HealthStatus | null;
  /** Down reason, or the warn reason for a degraded (healthy + warn) result. */
  reason: string | null;
  parsed: ParsedHealthResponse | null;
  /** The parsed JSON body (for JSON assertions layered on top), `undefined` if it didn't parse. */
  body: unknown;
}

/**
 * Monitor-side evaluation of a health-standard response (same rules as the macOS
 * `HealthStandard.evaluate`):
 * - `expectedStatusCode` is ignored; only HTTP 200 and 503 are readable, anything else is down
 *   ("Unexpected HTTP <code>");
 * - the body must parse and carry a valid `status`, otherwise down ("Invalid health response: …");
 * - 503 with a pass/warn body is contradictory and treated as invalid (down);
 * - pass → healthy, warn → healthy but degraded, fail → down.
 */
export function evaluateStandardResponse(httpStatus: number, bodyText: string): StandardEvaluation {
  const down = (reason: string, parsed: ParsedHealthResponse | null = null, body: unknown = undefined) => ({
    isHealthy: false,
    healthStatus: parsed?.status ?? null,
    reason,
    parsed,
    body,
  });

  if (httpStatus !== 200 && httpStatus !== 503) {
    return down(`Unexpected HTTP ${httpStatus}`);
  }

  let body: unknown;
  try {
    body = JSON.parse(bodyText);
  } catch {
    return down('Invalid health response: body is not valid JSON');
  }

  const parsed = parseHealthBody(body);
  if (!parsed.ok) {
    return down(`Invalid health response: ${parsed.error}`, null, body);
  }
  const value = parsed.value;

  if (httpStatus === 503 && value.status !== 'fail') {
    return down(`Invalid health response: HTTP 503 with status "${value.status}"`, null, body);
  }

  if (value.status === 'fail') {
    return down(healthReason(value) ?? 'Health status "fail"', value, body);
  }

  return { isHealthy: true, healthStatus: value.status, reason: healthReason(value), parsed: value, body };
}
