import { describe, it, expect } from 'vitest';
import {
  shouldRunVersionCheck,
  evaluateVersionResponse,
  versionEvents,
} from '../../src/modules/checks/version-check.js';
import { preferenceForNotificationType } from '../../src/modules/notifications/notification.service.js';
import { versionSummary } from '../../src/modules/dashboard/dashboard.service.js';
import type { EndpointVersionState, VersionCheckConfig } from '../../src/db/schema.js';

const baseConfig: VersionCheckConfig = {
  isEnabled: true,
  url: 'https://example.com/version',
  everyNChecks: 5,
  versionFieldPath: 'data.version',
  assertions: [],
  authType: 'none',
  authUsername: null,
  authHeaderName: null,
};

describe('shouldRunVersionCheck()', () => {
  it('runs on the first check and every Nth after', () => {
    const runs = Array.from({ length: 12 }, (_, i) => i + 1).filter((n) => shouldRunVersionCheck(n, 5));
    expect(runs).toEqual([1, 6, 11]);
  });

  it('runs every time when N is 1', () => {
    expect([1, 2, 3].every((n) => shouldRunVersionCheck(n, 1))).toBe(true);
  });

  it('treats N below 1 as 1', () => {
    expect(shouldRunVersionCheck(4, 0)).toBe(true);
    expect(shouldRunVersionCheck(4, -3)).toBe(true);
  });

  it('never runs for a zero count', () => {
    expect(shouldRunVersionCheck(0, 5)).toBe(false);
  });
});

describe('evaluateVersionResponse()', () => {
  it('reads the version on a 2xx JSON response', () => {
    const outcome = evaluateVersionResponse(200, '{"data":{"version":"1.4.2"}}', baseConfig, 15);
    expect(outcome).toEqual({
      isSuccess: true,
      version: '1.4.2',
      failureReason: null,
      statusCode: 200,
      responseTimeMs: 15,
    });
  });

  it('accepts any 2xx status', () => {
    expect(evaluateVersionResponse(204, '{"data":{"version":"1"}}', baseConfig).isSuccess).toBe(true);
  });

  it('stringifies numeric and boolean versions', () => {
    const config = { ...baseConfig, versionFieldPath: 'build' };
    expect(evaluateVersionResponse(200, '{"build":42}', config).version).toBe('42');
    expect(evaluateVersionResponse(200, '{"build":true}', config).version).toBe('true');
  });

  it('fails on a non-2xx status', () => {
    const outcome = evaluateVersionResponse(503, '{"data":{"version":"1"}}', baseConfig);
    expect(outcome.isSuccess).toBe(false);
    expect(outcome.failureReason).toBe('Expected 2xx, got 503');
    expect(outcome.version).toBeNull();
  });

  it('fails on invalid JSON', () => {
    const outcome = evaluateVersionResponse(200, '<html>', baseConfig);
    expect(outcome.isSuccess).toBe(false);
    expect(outcome.failureReason).toBe('Response body is not valid JSON');
  });

  it('fails when the version field is missing or not a scalar', () => {
    expect(evaluateVersionResponse(200, '{"data":{}}', baseConfig).failureReason).toBe(
      'Version field "data.version" not found',
    );
    expect(evaluateVersionResponse(200, '{"data":{"version":{"major":1}}}', baseConfig).isSuccess).toBe(false);
  });

  it('reports the version even when an assertion fails', () => {
    const config = {
      ...baseConfig,
      assertions: [{ path: 'env', expectedValue: 'production', matchMode: 'exact' as const }],
    };
    const outcome = evaluateVersionResponse(200, '{"data":{"version":"2.0.0"},"env":"staging"}', config);
    expect(outcome.isSuccess).toBe(false);
    expect(outcome.version).toBe('2.0.0');
    expect(outcome.failureReason).toBe('Assertion failed: "env" did not match "production"');
  });

  it('treats an invalid regex assertion as a failure instead of throwing', () => {
    const config = {
      ...baseConfig,
      assertions: [{ path: 'env', expectedValue: '([', matchMode: 'regex' as const }],
    };
    const outcome = evaluateVersionResponse(200, '{"data":{"version":"1"},"env":"x"}', config);
    expect(outcome.isSuccess).toBe(false);
    expect(outcome.version).toBe('1');
  });

  it('passes when all assertions match', () => {
    const config = {
      ...baseConfig,
      assertions: [
        { path: 'env', expectedValue: 'prod', matchMode: 'contains' as const },
        { path: 'data.version', expectedValue: '^2\\.', matchMode: 'regex' as const },
      ],
    };
    expect(evaluateVersionResponse(200, '{"data":{"version":"2.1"},"env":"production"}', config).isSuccess).toBe(
      true,
    );
  });
});

describe('versionEvents()', () => {
  const ok = (version: string) => ({ isSuccess: true, version, failureReason: null });
  const fail = (reason: string, version: string | null = null) => ({ isSuccess: false, version, failureReason: reason });

  it('emits nothing for the very first result', () => {
    expect(versionEvents(null, null, ok('1.0'))).toEqual([]);
    expect(versionEvents(null, null, fail('down'))).toEqual([]);
  });

  it('emits nothing when the version is unchanged', () => {
    expect(versionEvents(true, '1.0', ok('1.0'))).toEqual([]);
    expect(versionEvents(true, '1.0', ok(' 1.0 '))).toEqual([]);
  });

  it('emits changed when the version differs from the last known one', () => {
    expect(versionEvents(true, '1.0', ok('1.1'))).toEqual([{ type: 'changed', from: '1.0', to: '1.1' }]);
  });

  it('emits failed once on a success → failure transition', () => {
    expect(versionEvents(true, '1.0', fail('Timed out'))).toEqual([{ type: 'failed', reason: 'Timed out' }]);
    expect(versionEvents(false, '1.0', fail('Timed out'))).toEqual([]);
  });

  it('emits recovered and changed for a deploy that came back on a new version', () => {
    expect(versionEvents(false, '1.0', ok('2.0'))).toEqual([
      { type: 'recovered' },
      { type: 'changed', from: '1.0', to: '2.0' },
    ]);
  });

  it('still tracks a change when an assertion failed', () => {
    expect(versionEvents(true, '1.0', fail('env mismatch', '1.1'))).toEqual([
      { type: 'failed', reason: 'env mismatch' },
      { type: 'changed', from: '1.0', to: '1.1' },
    ]);
  });
});

describe('preferenceForNotificationType', () => {
  it('maps version failure/resolved to down/recovery and changes to their own toggle', () => {
    expect(preferenceForNotificationType.version_change).toBe('notifyOnVersionChange');
    expect(preferenceForNotificationType.version_failed).toBe('notifyOnDown');
    expect(preferenceForNotificationType.version_recovered).toBe('notifyOnRecovery');
    expect(preferenceForNotificationType.down).toBe('notifyOnDown');
    expect(preferenceForNotificationType.recovery).toBe('notifyOnRecovery');
  });
});

describe('versionSummary()', () => {
  const state: EndpointVersionState = {
    endpointId: '00000000-0000-0000-0000-000000000001',
    checkCounter: 3,
    lastCheckedAt: new Date('2026-10-01T10:00:00Z'),
    lastIsSuccess: false,
    lastVersion: '1.2.3',
    lastFailureReason: 'Timed out',
    lastStatusCode: null,
    lastResponseTimeMs: 30000,
  };

  it('is null without a version check', () => {
    expect(versionSummary({ versionCheck: null }, state)).toBeNull();
  });

  it('reports configured-but-never-run as no version, not failing', () => {
    expect(versionSummary({ versionCheck: baseConfig }, undefined)).toEqual({
      isEnabled: true,
      current: null,
      isFailing: false,
      failureReason: null,
      lastCheckedAt: null,
      source: 'versionCheck',
    });
  });

  it('reports the last known version and failure', () => {
    expect(versionSummary({ versionCheck: { ...baseConfig, isEnabled: false } }, state)).toEqual({
      isEnabled: false,
      current: '1.2.3',
      isFailing: true,
      failureReason: 'Timed out',
      lastCheckedAt: '2026-10-01T10:00:00.000Z',
      source: 'versionCheck',
    });
  });

  it('auto-tracks via the health standard when no explicit version check is enabled', () => {
    const auto = {
      isEnabled: true,
      current: '1.2.3',
      isFailing: false,
      failureReason: null,
      lastCheckedAt: '2026-10-01T10:00:00.000Z',
      source: 'healthStandard',
    };
    expect(versionSummary({ versionCheck: null, healthStandard: true }, state)).toEqual(auto);
    expect(versionSummary({ versionCheck: { ...baseConfig, isEnabled: false }, healthStandard: true }, state)).toEqual(auto);
    expect(versionSummary({ versionCheck: baseConfig, healthStandard: true }, state)?.source).toBe('versionCheck');
    expect(versionSummary({ versionCheck: null, healthStandard: false }, state)).toBeNull();
  });
});
