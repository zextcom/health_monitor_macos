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

    it('accepts every field the standard defines without warnings', () => {
      const body = {
        ...good,
        serviceId: 'billing-api',
        description: 'Billing API',
        notes: ['note'],
      };
      expect(validate({ body }).warnings).toEqual([]);
      expect(validate({ httpStatus: 503, body: { ...body, status: 'fail', output: 'Database unreachable' } }).warnings).toEqual([]);
    });

    it('reports response time when known', () => {
      expect(validate({ responseTimeMs: 42 }).observed.responseTimeMs).toBe(42);
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

    it('never errors on a legacy "checks" block, whatever it contains', () => {
      for (const checks of [[], 'x', { 'db:responseTime': [{ status: 'nope' }] }, { 'a:b': { status: 'pass' } }]) {
        expect(validate({ body: { ...good, checks } }).errors).toEqual([]);
      }
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

    it('"checks" is public per-component detail: warned, not an error', () => {
      const report = validate({ body: { ...good, checks: { 'postgres:responseTime': [{ status: 'pass' }] } } });
      expect(report.valid).toBe(true);
      expect(report.warnings).toEqual([expect.objectContaining({ path: '/checks', rule: 'no-checks' })]);
    });

    it('fields outside the standard are warned about, not rejected', () => {
      const report = validate({ body: { ...good, php: '8.3.23', links: { about: 'https://x.test' } } });
      expect(report.valid).toBe(true);
      expect(report.warnings).toEqual([
        expect.objectContaining({ path: '/php', rule: 'known-fields' }),
        expect.objectContaining({ path: '/links', rule: 'known-fields' }),
      ]);
    });

    it('the "Saltqr" case: runtime versions in a component check are flagged as extra, public detail', () => {
      const report = validate({
        body: {
          status: 'pass',
          version: 'unknown',
          serviceId: 'saltqr-app',
          checks: { 'php:version': [{ componentType: 'runtime', status: 'pass', observedValue: '8.3.23' }] },
        },
      });
      expect(report.valid).toBe(true);
      expect(rules(report.warnings)).toEqual(expect.arrayContaining(['no-checks', 'release-id']));
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
      const report = validate({ body: { ...good, description: ip } });
      expect(report.warnings).toEqual([
        expect.objectContaining({ path: '/description', message: expect.stringContaining('private IPv4') }),
      ]);
    });

    it.each([['8.8.8.8'], ['172.32.0.1'], ['1.4.2']])('not a private IPv4: %s', (value) => {
      expect(validate({ body: { ...good, description: value } }).warnings).toEqual([]);
    });

    it.each([['password'], ['dbPassword'], ['secret'], ['clientSecret'], ['token'], ['accessToken'], ['apiKey']])(
      'sensitive key %s',
      (key) => {
        const report = validate({ body: { ...good, [key]: 'x' } });
        expect(report.warnings).toContainEqual(expect.objectContaining({ path: `/${key}`, rule: 'no-sensitive-data' }));
      },
    );

    it('does not treat component names in a legacy checks block as sensitive keys', () => {
      const report = validate({ body: { ...good, checks: { 'token-service:responseTime': [{ status: 'pass' }] } } });
      expect(rules(report.warnings)).toEqual(['no-checks']);
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
