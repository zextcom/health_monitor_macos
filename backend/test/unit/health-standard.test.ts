import { describe, it, expect } from 'vitest';
import {
  HEALTH_STANDARD_DOCUMENT,
  HEALTH_STANDARD_EXAMPLES,
  HEALTH_STANDARD_FIELDS,
  HEALTH_STANDARD_RULES,
  HEALTH_STANDARD_SCHEMA,
  HEALTH_STATUSES,
  evaluateStandardResponse,
  healthReason,
  parseHealthBody,
  trackedVersionValue,
  worstStatus,
} from '../../src/modules/standards/health-standard.js';
import { validateHealthResponse } from '../../src/modules/standards/health-standard-validator.js';
import {
  degradedTransition,
  evaluateStandardHttpCheck,
  healthStateOf,
  usesAutoVersion,
} from '../../src/modules/checks/health-standard-check.js';
import { preferenceForNotificationType } from '../../src/modules/notifications/notification.service.js';

const json = (value: unknown) => JSON.stringify(value);

describe('worstStatus()', () => {
  it('orders fail > warn > pass', () => {
    expect(worstStatus([])).toBe('pass');
    expect(worstStatus(['pass', 'pass'])).toBe('pass');
    expect(worstStatus(['pass', 'warn'])).toBe('warn');
    expect(worstStatus(['warn', 'fail', 'pass'])).toBe('fail');
  });
});

describe('trackedVersionValue()', () => {
  it('combines version and the first 7 chars of releaseId', () => {
    expect(trackedVersionValue('1.4.2', '9f2c1ab7e4d3')).toBe('1.4.2 (9f2c1ab)');
  });

  it('uses whichever exists', () => {
    expect(trackedVersionValue('1.4.2', null)).toBe('1.4.2');
    expect(trackedVersionValue(null, '9f2c1ab7e4d3')).toBe('9f2c1ab7e4d3');
    expect(trackedVersionValue('  ', ' 42 ')).toBe('42');
  });

  it('keeps short release ids whole and skips when neither exists', () => {
    expect(trackedVersionValue('2.0', 'b12')).toBe('2.0 (b12)');
    expect(trackedVersionValue(null, null)).toBeNull();
    expect(trackedVersionValue('', '')).toBeNull();
  });
});

describe('parseHealthBody()', () => {
  it('requires an object with a valid status', () => {
    expect(parseHealthBody([])).toEqual({ ok: false, error: 'body is not a JSON object' });
    expect(parseHealthBody(null)).toEqual({ ok: false, error: 'body is not a JSON object' });
    expect(parseHealthBody({})).toEqual({ ok: false, error: 'missing "status"' });
    expect(parseHealthBody({ status: 'ok' })).toEqual({ ok: false, error: 'invalid status "ok"' });
    expect(parseHealthBody({ status: 'PASS' })).toMatchObject({ ok: false });
  });

  it('reads the standard fields leniently', () => {
    const result = parseHealthBody({ status: 'warn', version: '1.0', releaseId: 123456789, output: ' Cache unavailable ' });
    expect(result).toEqual({
      ok: true,
      value: { status: 'warn', version: '1.0', releaseId: '123456789', output: 'Cache unavailable' },
    });
  });

  it('ignores a legacy "checks" block and any other extra field', () => {
    const result = parseHealthBody({
      status: 'pass',
      checks: { 'db:responseTime': [{ status: 'fail' }], broken: 'not-an-array' },
      php: '8.3.23',
    });
    expect(result).toEqual({ ok: true, value: { status: 'pass', version: null, releaseId: null, output: null } });
  });

  it('clips long output', () => {
    const result = parseHealthBody({ status: 'fail', output: 'x'.repeat(1000) });
    expect(result.ok && result.value.output?.length).toBe(300);
  });
});

describe('healthReason()', () => {
  it('is null for pass', () => {
    expect(healthReason({ status: 'pass', output: 'ignored' })).toBeNull();
  });

  it('uses the top-level output', () => {
    expect(healthReason({ status: 'fail', output: 'DB down' })).toBe('DB down');
  });

  it('falls back to a generic reason', () => {
    expect(healthReason({ status: 'warn', output: null })).toBe('Health status "warn"');
  });
});

describe('evaluateStandardResponse() matrix', () => {
  const body = (status: string, extra: Record<string, unknown> = {}) => json({ status, ...extra });

  it.each([
    [200, 'pass', true, 'pass', null],
    [200, 'warn', true, 'warn', 'Health status "warn"'],
    [200, 'fail', false, 'fail', 'Health status "fail"'],
    [503, 'fail', false, 'fail', 'Health status "fail"'],
    [503, 'pass', false, null, 'Invalid health response: HTTP 503 with status "pass"'],
    [503, 'warn', false, null, 'Invalid health response: HTTP 503 with status "warn"'],
  ])('HTTP %i + %s → healthy=%s', (httpStatus, status, isHealthy, healthStatus, reason) => {
    const result = evaluateStandardResponse(httpStatus, body(status));
    expect(result.isHealthy).toBe(isHealthy);
    expect(result.healthStatus).toBe(healthStatus);
    expect(result.reason).toBe(reason);
  });

  it.each([201, 204, 301, 404, 500, 502])('any other HTTP status (%i) is down', (httpStatus) => {
    const result = evaluateStandardResponse(httpStatus, body('pass'));
    expect(result).toMatchObject({ isHealthy: false, healthStatus: null, reason: `Unexpected HTTP ${httpStatus}` });
  });

  it.each([
    ['<html>oops</html>', 'Invalid health response: body is not valid JSON'],
    ['', 'Invalid health response: body is not valid JSON'],
    ['[1,2]', 'Invalid health response: body is not a JSON object'],
    ['{}', 'Invalid health response: missing "status"'],
    ['{"status":"ok"}', 'Invalid health response: invalid status "ok"'],
    ['{"status":null}', 'Invalid health response: invalid status null'],
  ])('invalid body %j is down', (text, reason) => {
    const result = evaluateStandardResponse(200, text);
    expect(result).toMatchObject({ isHealthy: false, healthStatus: null, reason, parsed: null });
  });

  it('uses output as the reason', () => {
    expect(evaluateStandardResponse(503, body('fail', { output: 'DB unreachable' })).reason).toBe('DB unreachable');
    expect(evaluateStandardResponse(200, body('warn', { output: 'Cache unavailable' })).reason).toBe('Cache unavailable');
  });

  it('trusts the declared overall status and ignores a legacy "checks" block', () => {
    const result = evaluateStandardResponse(200, body('pass', { checks: { 'db:x': [{ status: 'fail' }] } }));
    expect(result.isHealthy).toBe(true);
    expect(result.healthStatus).toBe('pass');
    expect(result.parsed).toEqual({ status: 'pass', version: null, releaseId: null, output: null });
  });
});

describe('evaluateStandardHttpCheck() with JSON assertions', () => {
  const assertion = { path: 'serviceId', expectedValue: 'billing', matchMode: 'exact' as const };

  it('passes when the body is pass/warn and assertions match', () => {
    const result = evaluateStandardHttpCheck({ jsonAssertions: [assertion] }, 200, json({ status: 'warn', serviceId: 'billing' }));
    expect(result).toMatchObject({ isHealthy: true, healthStatus: 'warn' });
  });

  it('is down when an assertion fails on a passing body', () => {
    const result = evaluateStandardHttpCheck({ jsonAssertions: [assertion] }, 200, json({ status: 'pass', serviceId: 'other' }));
    expect(result).toMatchObject({
      isHealthy: false,
      healthStatus: 'pass',
      failureReason: 'Assertion failed: "serviceId" did not match "billing"',
    });
  });

  it('keeps the standard reason when the body already fails', () => {
    const result = evaluateStandardHttpCheck(
      { jsonAssertions: [assertion] },
      503,
      json({ status: 'fail', output: 'down', serviceId: 'other' }),
    );
    expect(result).toMatchObject({ isHealthy: false, healthStatus: 'fail', failureReason: 'down' });
  });

  it('never throws on an invalid regex assertion', () => {
    const result = evaluateStandardHttpCheck(
      { jsonAssertions: [{ path: 'status', expectedValue: '(', matchMode: 'regex' }] },
      200,
      json({ status: 'pass' }),
    );
    expect(result.isHealthy).toBe(false);
  });
});

describe('degraded state & transitions', () => {
  it('derives state from isHealthy + healthStatus', () => {
    expect(healthStateOf({ isHealthy: true, healthStatus: null })).toBe('healthy');
    expect(healthStateOf({ isHealthy: true, healthStatus: 'pass' })).toBe('healthy');
    expect(healthStateOf({ isHealthy: true, healthStatus: 'warn' })).toBe('degraded');
    expect(healthStateOf({ isHealthy: false, healthStatus: 'warn' })).toBe('down');
    expect(healthStateOf({ isHealthy: false, healthStatus: 'fail' })).toBe('down');
  });

  it('only reports healthy ↔ degraded transitions', () => {
    expect(degradedTransition('healthy', 'degraded')).toBe('degraded');
    expect(degradedTransition('degraded', 'healthy')).toBe('degraded_recovered');
    expect(degradedTransition(null, 'degraded')).toBeNull();
    expect(degradedTransition('degraded', 'degraded')).toBeNull();
    expect(degradedTransition('down', 'degraded')).toBeNull(); // incident close sends "recovered"
    expect(degradedTransition('degraded', 'down')).toBeNull(); // incident open sends "down"
    expect(degradedTransition('healthy', 'healthy')).toBeNull();
  });

  it('gates degraded notifications like down/recovery', () => {
    expect(preferenceForNotificationType.degraded).toBe('notifyOnDown');
    expect(preferenceForNotificationType.degraded_recovered).toBe('notifyOnRecovery');
  });

  it('auto-tracks versions only without an enabled explicit version check', () => {
    const config = {
      isEnabled: true,
      url: 'https://x.test/v',
      everyNChecks: 5,
      versionFieldPath: 'v',
      assertions: [],
      authType: 'none' as const,
      authUsername: null,
      authHeaderName: null,
    };
    expect(usesAutoVersion({ healthStandard: true, versionCheck: null })).toBe(true);
    expect(usesAutoVersion({ healthStandard: true, versionCheck: { ...config, isEnabled: false } })).toBe(true);
    expect(usesAutoVersion({ healthStandard: true, versionCheck: config })).toBe(false);
    expect(usesAutoVersion({ healthStandard: false, versionCheck: null })).toBe(false);
  });
});

describe('published standard content', () => {
  it('has unique rule ids with a level', () => {
    const ids = HEALTH_STANDARD_RULES.map((rule) => rule.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(HEALTH_STANDARD_RULES.every((rule) => rule.level === 'must' || rule.level === 'should')).toBe(true);
  });

  it('references only published rule ids from the validator', () => {
    const ids = new Set(HEALTH_STANDARD_RULES.map((rule) => rule.id));
    const bad = validateHealthResponse({
      httpStatus: 500,
      contentType: 'text/html',
      cacheControl: null,
      responseTimeMs: 5000,
      body: json({
        status: 'warn',
        version: 1,
        notes: 'x',
        checks: { db: [{ status: 'fail', time: 'yesterday', observedValue: {} }], other: 'x' },
        password: '/var/www/app 10.0.0.1',
      }),
    });
    for (const issue of [...bad.errors, ...bad.warnings]) {
      expect(ids.has(issue.rule)).toBe(true);
    }
  });

  it('every example is valid, warning-free and uses the right HTTP status', () => {
    for (const status of HEALTH_STATUSES) {
      const example = HEALTH_STANDARD_EXAMPLES[status];
      expect(example.body.status).toBe(status);
      const report = validateHealthResponse({
        httpStatus: example.httpStatus,
        contentType: example.headers['Content-Type'],
        cacheControl: example.headers['Cache-Control'],
        body: example.body,
      });
      expect(report.errors).toEqual([]);
      expect(report.warnings).toEqual([]);
      expect(report.valid).toBe(true);
    }
  });

  it('schema mirrors the status enum and required fields', () => {
    expect(HEALTH_STANDARD_SCHEMA.$schema).toBe('https://json-schema.org/draft/2020-12/schema');
    expect(HEALTH_STANDARD_SCHEMA.required).toEqual(['status']);
    expect(HEALTH_STANDARD_SCHEMA.$defs.status.enum).toEqual(['pass', 'warn', 'fail']);
    expect(HEALTH_STANDARD_SCHEMA.additionalProperties).toBe(true);
  });

  it('no longer defines "checks" anywhere in the published content', () => {
    expect(Object.keys(HEALTH_STANDARD_SCHEMA.properties)).not.toContain('checks');
    expect(HEALTH_STANDARD_SCHEMA.$defs).not.toHaveProperty('check');
    for (const example of Object.values(HEALTH_STANDARD_EXAMPLES)) {
      expect(example.body).not.toHaveProperty('checks');
    }
    expect(HEALTH_STANDARD_RULES.map((rule) => rule.id)).not.toEqual(
      expect.arrayContaining(['check-entries', 'worst-of-checks']),
    );
    expect(HEALTH_STANDARD_RULES.find((rule) => rule.id === 'no-checks')).toMatchObject({ level: 'should' });
  });

  it('every example field is one the validator treats as known', () => {
    for (const example of Object.values(HEALTH_STANDARD_EXAMPLES)) {
      expect(Object.keys(example.body).every((key) => HEALTH_STANDARD_FIELDS.includes(key))).toBe(true);
    }
  });

  it('document bundles everything under the standard id', () => {
    expect(HEALTH_STANDARD_DOCUMENT).toMatchObject({
      id: 'zext-health/v1',
      mediaType: 'application/health+json',
    });
    expect(Object.keys(HEALTH_STANDARD_DOCUMENT.examples)).toEqual(['pass', 'warn', 'fail']);
  });
});
