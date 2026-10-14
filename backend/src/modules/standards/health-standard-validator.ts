import type { HealthStatus } from '../../db/schema.js';
import {
  HEALTH_MEDIA_TYPE,
  HEALTH_STANDARD_FIELDS,
  HEALTH_STANDARD_ID,
  HTTP_STATUS_FOR,
  RESPONSE_TIME_LIMIT_MS,
  isHealthStatus,
  isPlainObject,
} from './health-standard.js';

/**
 * Strict, pure validator for `zext-health/v1` responses — no I/O, so the validate route (URL and
 * pasted-response modes) and tests share it. MUST violations become `errors` (and make the response
 * invalid); SHOULD violations and leak heuristics become `warnings`.
 *
 * `path` is a JSON Pointer into the body (`""` = the whole body, e.g. `/version`) or, for HTTP
 * metadata, one of `http.status`, `http.headers.content-type`, `http.headers.cache-control`,
 * `http.responseTime`.
 */

export interface ValidationIssue {
  path: string;
  rule: string;
  message: string;
}

export interface HealthResponseInput {
  httpStatus: number;
  /** `undefined` = unknown (not checked); `null` = header absent. */
  contentType?: string | null;
  /** `undefined` = unknown (not checked); `null` = header absent. */
  cacheControl?: string | null;
  /** Raw body text, or an already-parsed JSON value (pasted responses). */
  body: unknown;
  /** Only known when the backend fetched the URL itself. */
  responseTimeMs?: number | null;
}

export interface ValidationReport {
  standard: typeof HEALTH_STANDARD_ID;
  valid: boolean;
  errors: ValidationIssue[];
  warnings: ValidationIssue[];
  observed: {
    httpStatus: number;
    contentType: string | null;
    responseTimeMs?: number;
    status?: HealthStatus;
    version?: string;
    releaseId?: string;
  };
}

/** RFC 6901 escaping for one pointer segment. */
function pointer(...segments: Array<string | number>): string {
  return segments.map((segment) => `/${String(segment).replace(/~/g, '~0').replace(/\//g, '~1')}`).join('');
}

const STRING_FIELDS = ['version', 'releaseId', 'serviceId', 'description', 'output'] as const;

// ── Leak heuristics (warnings only — they can have false positives) ──

const FILE_PATH = /(^|[\s"'=:(])(\/var\/|\/home\/|\/Users\/|\/root\/|\/etc\/|\/opt\/|\/srv\/|[A-Za-z]:\\)/;
const PRIVATE_IPV4 = /\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b/;
const CREDENTIAL_URL = /[a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:[^\s/@]+@/i;
const STACK_TRACE = /(\n\s+at\s+\S+|Traceback \(most recent call last\)|\.(js|ts|py|java|go|rb|php):\d+)/;
const SENSITIVE_KEY = /(password|passwd|secret|token|api[-_]?key|credential|private[-_]?key)/i;

function leakFindings(value: unknown, path: string, out: ValidationIssue[]): void {
  if (out.length >= 20) {
    return; // enough to make the point; keeps responses small for a huge leaky body
  }
  if (typeof value === 'string') {
    if (FILE_PATH.test(value)) {
      out.push({ path, rule: 'no-sensitive-data', message: 'Looks like a file system path; do not expose server paths.' });
    }
    if (PRIVATE_IPV4.test(value)) {
      out.push({ path, rule: 'no-sensitive-data', message: 'Looks like a private IPv4 address; do not expose internal addresses.' });
    }
    if (CREDENTIAL_URL.test(value)) {
      out.push({ path, rule: 'no-sensitive-data', message: 'Looks like a connection string with credentials.' });
    }
    if (STACK_TRACE.test(value)) {
      out.push({ path, rule: 'no-sensitive-data', message: 'Looks like a stack trace; use a short "output" reason instead.' });
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => leakFindings(item, `${path}${pointer(index)}`, out));
    return;
  }
  if (isPlainObject(value)) {
    for (const [key, child] of Object.entries(value)) {
      const childPath = `${path}${pointer(key)}`;
      // Keys of a legacy checks map are component names, not field names — "token-service:responseTime" is fine.
      const isCheckName = path === '/checks';
      if (!isCheckName && SENSITIVE_KEY.test(key)) {
        out.push({ path: childPath, rule: 'no-sensitive-data', message: `Key "${key}" suggests a secret; never include credentials.` });
      }
      leakFindings(child, childPath, out);
    }
  }
}

function parseBody(body: unknown): { ok: true; value: unknown } | { ok: false } {
  if (typeof body !== 'string') {
    return { ok: true, value: body };
  }
  try {
    return { ok: true, value: JSON.parse(body) };
  } catch {
    return { ok: false };
  }
}

function mediaTypeOf(contentType: string): string {
  return contentType.split(';')[0].trim().toLowerCase();
}

export function validateHealthResponse(input: HealthResponseInput): ValidationReport {
  const errors: ValidationIssue[] = [];
  const warnings: ValidationIssue[] = [];
  const observed: ValidationReport['observed'] = {
    httpStatus: input.httpStatus,
    contentType: input.contentType ?? null,
  };
  if (typeof input.responseTimeMs === 'number') {
    observed.responseTimeMs = input.responseTimeMs;
  }

  const report = (): ValidationReport => ({
    standard: HEALTH_STANDARD_ID,
    valid: errors.length === 0,
    errors,
    warnings,
    observed,
  });

  // ── HTTP metadata (SHOULDs) ──
  if (input.contentType !== undefined) {
    const mediaType = input.contentType ? mediaTypeOf(input.contentType) : null;
    if (mediaType === null) {
      warnings.push({
        path: 'http.headers.content-type',
        rule: 'content-type',
        message: `Missing Content-Type; send ${HEALTH_MEDIA_TYPE}.`,
      });
    } else if (mediaType === 'application/json') {
      warnings.push({
        path: 'http.headers.content-type',
        rule: 'content-type',
        message: `application/json is tolerated; prefer ${HEALTH_MEDIA_TYPE}.`,
      });
    } else if (mediaType !== HEALTH_MEDIA_TYPE) {
      warnings.push({
        path: 'http.headers.content-type',
        rule: 'content-type',
        message: `Unexpected Content-Type "${mediaType}"; send ${HEALTH_MEDIA_TYPE}.`,
      });
    }
  }
  if (input.cacheControl !== undefined) {
    const directives = (input.cacheControl ?? '').toLowerCase().split(',').map((part) => part.trim());
    if (!directives.includes('no-store')) {
      warnings.push({
        path: 'http.headers.cache-control',
        rule: 'cache-control',
        message: 'Send Cache-Control: no-store so proxies never serve a stale health status.',
      });
    }
  }
  if (typeof input.responseTimeMs === 'number' && input.responseTimeMs > RESPONSE_TIME_LIMIT_MS) {
    warnings.push({
      path: 'http.responseTime',
      rule: 'response-time',
      message: `Responded in ${input.responseTimeMs} ms; respond within ${RESPONSE_TIME_LIMIT_MS} ms (cache dependency checks).`,
    });
  }

  // ── Body ──
  const parsed = parseBody(input.body);
  if (!parsed.ok) {
    errors.push({ path: '', rule: 'json-body', message: 'Body is not valid JSON.' });
    return report();
  }
  const body = parsed.value;
  if (!isPlainObject(body)) {
    errors.push({ path: '', rule: 'json-body', message: 'Body must be a JSON object.' });
    return report();
  }

  // status
  let status: HealthStatus | null = null;
  if (!('status' in body)) {
    errors.push({ path: '/status', rule: 'status-field', message: 'Missing "status" (pass, warn or fail).' });
  } else if (!isHealthStatus(body.status)) {
    errors.push({
      path: '/status',
      rule: 'status-field',
      message: `Invalid status ${JSON.stringify(body.status)}; expected "pass", "warn" or "fail".`,
    });
  } else {
    status = body.status;
    observed.status = status;
    const expectedHttp = HTTP_STATUS_FOR[status];
    if (input.httpStatus !== expectedHttp) {
      errors.push({
        path: 'http.status',
        rule: 'http-status',
        message: `Status "${status}" must be served with HTTP ${expectedHttp}, got ${input.httpStatus}.`,
      });
    }
  }

  // top-level optional fields
  for (const field of STRING_FIELDS) {
    if (field in body && typeof body[field] !== 'string') {
      errors.push({ path: pointer(field), rule: 'field-types', message: `"${field}" must be a string.` });
    }
  }
  if ('notes' in body) {
    if (!Array.isArray(body.notes)) {
      errors.push({ path: '/notes', rule: 'field-types', message: '"notes" must be an array of strings.' });
    } else {
      body.notes.forEach((note, index) => {
        if (typeof note !== 'string') {
          errors.push({ path: pointer('notes', index), rule: 'field-types', message: 'Each note must be a string.' });
        }
      });
    }
  }
  if (typeof body.version === 'string' && body.version.trim() !== '') {
    observed.version = body.version;
  } else if (!('version' in body)) {
    warnings.push({ path: '/version', rule: 'version', message: 'Add "version" (e.g. "1.4.2").' });
  }
  if (typeof body.releaseId === 'string' && body.releaseId.trim() !== '') {
    observed.releaseId = body.releaseId;
  } else if (!('releaseId' in body)) {
    warnings.push({ path: '/releaseId', rule: 'release-id', message: 'Add "releaseId" (e.g. the git SHA of the deploy).' });
  }

  // Public-minimum: the endpoint is unauthenticated, so everything beyond the standard's fields is exposed.
  for (const key of Object.keys(body)) {
    if (key === 'checks') {
      warnings.push({
        path: pointer(key),
        rule: 'no-checks',
        message: 'Remove "checks": per-component details are public here and the monitor ignores them. Decide the overall "status" inside the service.',
      });
    } else if (!HEALTH_STANDARD_FIELDS.includes(key)) {
      warnings.push({
        path: pointer(key),
        rule: 'known-fields',
        message: `"${key}" is not part of the standard and is public; remove it unless the monitor needs it.`,
      });
    }
  }

  if (status && status !== 'pass' && !(typeof body.output === 'string' && body.output.trim() !== '')) {
    warnings.push({ path: '/output', rule: 'output-on-problem', message: `Add a short "output" reason for "${status}".` });
  }

  leakFindings(body, '', warnings);

  return report();
}
