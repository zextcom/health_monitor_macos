import { describe, it, expect } from 'vitest';
import {
  validateHealthResponse,
  type HealthResponseInput,
  type ValidationIssue,
} from '../../src/modules/standards/health-standard-validator.js';

const good = {
  status: 'pass',
  version: '1.0.0',
  releaseId: 'abc1234',
};

function validate(overrides: Partial<HealthResponseInput> = {}) {
  return validateHealthResponse({
    httpStatus: 200,
    contentType: 'application/health+json',
    cacheControl: 'no-store',
    body: good,
    ...overrides,
  });
}

const rules = (issues: ValidationIssue[]) => issues.map((issue) => issue.rule);

describe('validateHealthResponse()', () => {
  describe('a fully conforming response', () => {
    it('is valid with no warnings', () => {
      const report = validate();
      expect(report).toEqual({
        standard: 'zext-health/v1',
        valid: true,
        errors: [],
        warnings: [],
        observed: {
          httpStatus: 200,
          contentType: 'application/health+json',
          status: 'pass',
          version: '1.0.0',
          releaseId: 'abc1234',
          checkCount: 0,
        },
      });
    });

    it('accepts the body as raw text or already-parsed JSON', () => {
      expect(validate({ body: JSON.stringify(good) }).valid).toBe(true);
      expect(validate({ body: good }).valid).toBe(true);
    });

    it('accepts a content type with parameters, case-insensitively', () => {
      expect(validate({ contentType: 'Application/Health+JSON; charset=utf-8' }).warnings).toEqual([]);
    });

    it('allows unknown extra fields (forward compatible)', () => {
      expect(validate({ body: { ...good, links: { about: 'https://x.test' }, custom: 1 } }).warnings).toEqual([]);
    });

    it('reports response time and check count when known', () => {
      const report = validate({
        responseTimeMs: 42,
        body: { ...good, checks: { 'db:responseTime': [{ status: 'pass' }, { status: 'pass' }], 'disk:utilization': [] } },
      });
      expect(report.observed.responseTimeMs).toBe(42);
      expect(report.observed.checkCount).toBe(2);
    });
  });

  describe('MUST violations (errors)', () => {
    it.each([
      ['not JSON', '<html>', ''],
      ['empty body', '', ''],
      ['an array', '[]', ''],
      ['a string', '"pass"', ''],
      ['null', 'null', ''],
    ])('body that is %s', (_label, body, path) => {
      const report = validate({ body });
      expect(report.valid).toBe(false);
      expect(report.errors).toHaveLength(1);
      expect(report.errors[0]).toMatchObject({ rule: 'json-body', path });
    });

    it('missing status', () => {
      const report = validate({ body: { version: '1' , releaseId: 'x'} });
      expect(report.valid).toBe(false);
      expect(report.errors).toEqual([{ path: '/status', rule: 'status-field', message: 'Missing "status" (pass, warn or fail).' }]);
      expect(report.observed.status).toBeUndefined();
    });

    it.each([['ok'], ['PASS'], [true], [1], [null]])('invalid status %j', (status) => {
      const report = validate({ body: { ...good, status } });
      expect(rules(report.errors)).toEqual(['status-field']);
    });

    it.each([
      ['pass', 503],
      ['warn', 503],
      ['fail', 200],
      ['pass', 500],
      ['fail', 500],
      ['pass', 204],
    ])('status %s served with HTTP %i', (status, httpStatus) => {
      const body = { ...good, status, ...(status === 'pass' ? {} : { output: 'reason' }) };
      const report = validate({ httpStatus, body });
      expect(report.valid).toBe(false);
      expect(report.errors).toEqual([expect.objectContaining({ path: 'http.status', rule: 'http-status' })]);
    });

    it.each([
      ['pass', 200],
      ['warn', 200],
      ['fail', 503],
    ])('status %s with HTTP %i is fine', (status, httpStatus) => {
      const body = { ...good, status, ...(status === 'pass' ? {} : { output: 'reason' }) };
      expect(validate({ httpStatus, body }).errors).toEqual([]);
    });

    it('overall status must be the worst of all checks', () => {
      const body = {
        ...good,
        status: 'warn',
        output: 'x',
        checks: { 'db:responseTime': [{ status: 'pass' }], 'disk:utilization': [{ status: 'fail' }] },
      };
      const report = validate({ body });
      expect(report.errors).toEqual([
        {
          path: '/status',
          rule: 'worst-of-checks',
          message: 'Overall status is "warn" but the worst check status is "fail".',
        },
      ]);
    });

    it('overall status better than needed is also an error (pass with a warn check)', () => {
      const report = validate({ body: { ...good, checks: { 'disk:utilization': [{ status: 'warn' }] } } });
      expect(rules(report.errors)).toEqual(['worst-of-checks']);
    });

    it('overall status worse than checks is an error too', () => {
      const report = validate({
        httpStatus: 503,
        body: { ...good, status: 'fail', output: 'x', checks: { 'db:responseTime': [{ status: 'pass' }] } },
      });
      expect(rules(report.errors)).toEqual(['worst-of-checks']);
    });

    it('checks must be an object of arrays of objects with a valid status', () => {
      expect(rules(validate({ body: { ...good, checks: [] } }).errors)).toEqual(['check-entries']);
      expect(rules(validate({ body: { ...good, checks: 'x' } }).errors)).toEqual(['check-entries']);

      const report = validate({
        body: {
          ...good,
          checks: {
            'a:b': { status: 'pass' },
            'c:d': ['pass', { status: 'nope' }, {}],
          },
        },
      });
      expect(report.errors).toEqual([
        expect.objectContaining({ path: '/checks/a:b', rule: 'check-entries' }),
        expect.objectContaining({ path: '/checks/c:d/0', rule: 'check-entries' }),
        expect.objectContaining({ path: '/checks/c:d/1/status', rule: 'check-entries' }),
        expect.objectContaining({ path: '/checks/c:d/2/status', rule: 'check-entries' }),
      ]);
      expect(report.observed.checkCount).toBe(3);
    });

    it('escapes JSON Pointer segments', () => {
      const report = validate({ body: { ...good, checks: { 'a/b~c:x': [{ status: 'bad' }] } } });
      expect(report.errors[0].path).toBe('/checks/a~1b~0c:x/0/status');
    });

    it('optional top-level fields must have the right types', () => {
      const report = validate({
        body: { ...good, version: 1, releaseId: 2, serviceId: {}, description: [], output: false, notes: 'x' },
      });
      expect(report.errors.map((issue) => issue.path)).toEqual([
        '/version',
        '/releaseId',
        '/serviceId',
        '/description',
        '/output',
        '/notes',
      ]);
      expect(new Set(rules(report.errors))).toEqual(new Set(['field-types']));
      expect(report.observed.version).toBeUndefined();
    });

    it('notes must be strings', () => {
      const report = validate({ body: { ...good, notes: ['ok', 2] } });
      expect(report.errors).toEqual([expect.objectContaining({ path: '/notes/1', rule: 'field-types' })]);
    });

    it('check entry fields must have the right types', () => {
      const report = validate({
        body: {
          ...good,
          checks: {
            'db:responseTime': [
              {
                status: 'pass',
                componentId: 1,
                componentType: true,
                observedUnit: 5,
                output: {},
                observedValue: { nested: true },
                time: 'yesterday',
              },
            ],
          },
        },
      });
      expect(report.errors.map((issue) => issue.path)).toEqual([
        '/checks/db:responseTime/0/componentId',
        '/checks/db:responseTime/0/componentType',
        '/checks/db:responseTime/0/observedUnit',
        '/checks/db:responseTime/0/output',
        '/checks/db:responseTime/0/observedValue',
        '/checks/db:responseTime/0/time',
      ]);
    });

    it.each([['2026-10-11T09:30:00Z'], ['2026-10-11T09:30:00.123+02:00'], ['2026-10-11T09:30Z']])(
      'accepts ISO 8601 time %s',
      (time) => {
        const report = validate({ body: { ...good, checks: { 'db:x': [{ status: 'pass', time }] } } });
        expect(report.errors).toEqual([]);
      },
    );

    it.each([[123], ['2026-10-11'], ['2026-10-11T09:30:00'], ['11/10/2026']])('rejects time %j', (time) => {
      const report = validate({ body: { ...good, checks: { 'db:x': [{ status: 'pass', time }] } } });
      expect(rules(report.errors)).toEqual(['field-types']);
    });

    it.each([[1.5], ['up'], [false]])('accepts observedValue %j', (observedValue) => {
      expect(validate({ body: { ...good, checks: { 'db:x': [{ status: 'pass', observedValue }] } } }).errors).toEqual([]);
    });
  });

  describe('SHOULD violations (warnings)', () => {
    it('missing version and releaseId', () => {
      const report = validate({ body: { status: 'pass' } });
      expect(report.valid).toBe(true);
      expect(report.warnings).toEqual([
        expect.objectContaining({ path: '/version', rule: 'version' }),
        expect.objectContaining({ path: '/releaseId', rule: 'release-id' }),
      ]);
    });

    it('content type: application/json tolerated with a warning, others warned, missing warned', () => {
      expect(validate({ contentType: 'application/json; charset=utf-8' }).warnings).toEqual([
        expect.objectContaining({ path: 'http.headers.content-type', rule: 'content-type', message: expect.stringContaining('tolerated') }),
      ]);
      expect(validate({ contentType: 'text/html' }).warnings[0].message).toContain('"text/html"');
      expect(validate({ contentType: null }).warnings[0].message).toContain('Missing Content-Type');
    });

    it('content type and cache control are not checked when unknown (pasted response)', () => {
      expect(validate({ contentType: undefined, cacheControl: undefined }).warnings).toEqual([]);
    });

    it('cache control must include no-store', () => {
      expect(rules(validate({ cacheControl: null }).warnings)).toEqual(['cache-control']);
      expect(rules(validate({ cacheControl: 'max-age=30' }).warnings)).toEqual(['cache-control']);
      expect(validate({ cacheControl: 'no-cache, No-Store' }).warnings).toEqual([]);
    });

    it('slow responses (>1s) when fetched', () => {
      expect(validate({ responseTimeMs: 1000 }).warnings).toEqual([]);
      expect(validate({ responseTimeMs: 1500 }).warnings).toEqual([
        expect.objectContaining({ path: 'http.responseTime', rule: 'response-time' }),
      ]);
    });

    it('warn/fail without output', () => {
      expect(validate({ body: { ...good, status: 'warn' } }).warnings).toEqual([
        expect.objectContaining({ path: '/output', rule: 'output-on-problem' }),
      ]);
      expect(rules(validate({ httpStatus: 503, body: { ...good, status: 'fail' } }).warnings)).toEqual(['output-on-problem']);
    });

    it('check names should be component:measurement', () => {
      expect(validate({ body: { ...good, checks: { postgres: [{ status: 'pass' }] } } }).warnings).toEqual([
        expect.objectContaining({ path: '/checks/postgres', rule: 'check-entries' }),
      ]);
    });
  });

  describe('leak heuristics (warnings)', () => {
    it.each([
      ['/var/www/app/current'],
      ['/home/deploy/app'],
      ['/Users/dev/project'],
      ['C:\\inetpub\\wwwroot'],
      ['Loaded from /etc/app/config.yml'],
    ])('file path %s', (value) => {
      const report = validate({ body: { ...good, description: value } });
      expect(report.valid).toBe(true);
      expect(report.warnings).toEqual([
        expect.objectContaining({ path: '/description', rule: 'no-sensitive-data', message: expect.stringContaining('file system path') }),
      ]);
    });

    it('does not flag URL paths that merely contain /var/', () => {
      expect(validate({ body: { ...good, description: 'https://cdn.test/var/x' } }).warnings).toEqual([]);
    });

    it.each([['10.0.0.12'], ['172.16.4.1'], ['172.31.255.255'], ['192.168.1.20:5432']])('private IPv4 %s', (ip) => {
      const report = validate({ body: { ...good, checks: { 'db:x': [{ status: 'pass', componentId: ip }] } } });
      expect(report.warnings).toEqual([
        expect.objectContaining({ path: '/checks/db:x/0/componentId', message: expect.stringContaining('private IPv4') }),
      ]);
    });

    it.each([['8.8.8.8'], ['172.32.0.1'], ['1.4.2']])('not a private IPv4: %s', (value) => {
      expect(validate({ body: { ...good, description: value } }).warnings).toEqual([]);
    });

    it.each([['password'], ['dbPassword'], ['secret'], ['clientSecret'], ['token'], ['accessToken'], ['apiKey']])(
      'sensitive key %s',
      (key) => {
        const report = validate({ body: { ...good, [key]: 'x' } });
        expect(report.warnings).toEqual([expect.objectContaining({ path: `/${key}`, rule: 'no-sensitive-data' })]);
      },
    );

    it('does not treat component names in checks as sensitive keys', () => {
      expect(validate({ body: { ...good, checks: { 'token-service:responseTime': [{ status: 'pass' }] } } }).warnings).toEqual([]);
    });

    it('connection strings with credentials and stack traces', () => {
      const report = validate({
        body: {
          ...good,
          notes: ['postgres://app:hunter2@db.internal:5432/app', 'Error: boom\n    at Object.<anonymous> (index.js:10:5)'],
        },
      });
      expect(report.warnings.map((issue) => issue.path)).toEqual(['/notes/0', '/notes/1']);
      expect(report.warnings[0].message).toContain('connection string');
      expect(report.warnings.some((issue) => issue.message.includes('stack trace'))).toBe(true);
    });

    it('the motivating case: a server path leaked in a health body', () => {
      const report = validate({
        contentType: 'application/json',
        cacheControl: null,
        body: { status: 'ok', path: '/var/www/vhosts/example/httpdocs/storage' },
      });
      expect(report.valid).toBe(false);
      expect(rules(report.errors)).toEqual(['status-field']);
      expect(rules(report.warnings)).toEqual(
        expect.arrayContaining(['content-type', 'cache-control', 'version', 'release-id', 'no-sensitive-data']),
      );
    });

    it('caps the number of findings', () => {
      const body = { ...good, notes: Array.from({ length: 100 }, () => '/var/log/x') };
      expect(validate({ body }).warnings.length).toBeLessThanOrEqual(21);
    });
  });
});
