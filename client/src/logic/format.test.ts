/// <reference types="node" />
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import type { VersionCheckConfig } from '../api/endpoints';
import {
  componentTitle,
  formatDateTime,
  formatObservedValue,
  formatSeenRange,
  formatVersion,
  healthStatusLabel,
  shouldShowComponents,
  shouldShowVersion,
  sortVersionHistory,
  versionSourceLabel,
  versionSourceOf,
  versionStatusText,
} from './format';

const config = (isEnabled: boolean): VersionCheckConfig => ({
  isEnabled,
  url: 'https://api.example.com/version',
  everyNChecks: 5,
  versionFieldPath: 'version',
  assertions: [],
  authType: 'none',
  authUsername: null,
  authHeaderName: null,
});

describe('versionSourceOf', () => {
  it('is null without a version check or the standard', () => {
    assert.equal(versionSourceOf({ healthStandard: false, versionCheck: null }), null);
    assert.equal(versionSourceOf({}), null);
  });

  it('uses an explicit version check', () => {
    assert.equal(versionSourceOf({ healthStandard: false, versionCheck: config(true) }), 'versionCheck');
    assert.equal(versionSourceOf({ healthStandard: false, versionCheck: config(false) }), 'versionCheck');
  });

  it('auto-tracks from the health response unless an enabled explicit check takes over', () => {
    assert.equal(versionSourceOf({ healthStandard: true, versionCheck: null }), 'healthStandard');
    assert.equal(versionSourceOf({ healthStandard: true, versionCheck: config(false) }), 'healthStandard');
    assert.equal(versionSourceOf({ healthStandard: true, versionCheck: config(true) }), 'versionCheck');
  });

  it('labels the source', () => {
    assert.equal(versionSourceLabel('healthStandard'), 'From health response');
    assert.equal(versionSourceLabel('versionCheck'), 'Version check');
  });
});

describe('formatVersion', () => {
  it('prefixes numeric versions with v', () => {
    assert.equal(formatVersion('1.4.2'), 'v1.4.2');
    assert.equal(formatVersion(' 1.4.2 (9f2c1ab) '), 'v1.4.2 (9f2c1ab)');
  });

  it('leaves other values alone and dashes empty ones', () => {
    assert.equal(formatVersion('v2.0.0'), 'v2.0.0');
    assert.equal(formatVersion('9f2c1ab'), '9f2c1ab', 'a bare commit SHA is not a version number');
    assert.equal(formatVersion('2'), 'v2');
    assert.equal(formatVersion('main@abc'), 'main@abc');
    assert.equal(formatVersion(null), '—');
    assert.equal(formatVersion(undefined), '—');
    assert.equal(formatVersion('  '), '—');
  });
});

describe('formatDateTime', () => {
  it('dashes missing or invalid dates', () => {
    assert.equal(formatDateTime(null), '—');
    assert.equal(formatDateTime(''), '—');
    assert.equal(formatDateTime('not a date'), '—');
  });

  it('formats valid ISO strings', () => {
    const iso = '2026-10-01T10:00:00.000Z';
    assert.equal(formatDateTime(iso), new Date(iso).toLocaleString());
  });
});

describe('versionStatusText', () => {
  const ok = { version: '1.0.0', isFailing: false, failureReason: null, lastCheckedAt: '2026-10-01T10:00:00.000Z' };

  it('is OK for a passing result', () => {
    assert.deepEqual(versionStatusText(ok, { source: 'versionCheck', isEnabled: true }), {
      label: 'OK',
      tone: 'ok',
      detail: null,
    });
  });

  it('shows the failure reason when failing', () => {
    assert.deepEqual(
      versionStatusText({ ...ok, isFailing: true, failureReason: 'HTTP 500' }, { source: 'versionCheck', isEnabled: true }),
      { label: 'Failing', tone: 'failing', detail: 'HTTP 500' },
    );
    assert.equal(
      versionStatusText({ ...ok, isFailing: true, failureReason: null }, { source: 'versionCheck', isEnabled: true }).detail,
      'Version check failed',
    );
  });

  it('is not checked yet without a result', () => {
    assert.equal(versionStatusText(null, { source: 'healthStandard', isEnabled: true }).label, 'Not checked yet');
  });

  it('says paused for a disabled explicit check, even if the last result failed', () => {
    assert.equal(
      versionStatusText({ ...ok, isFailing: true }, { source: 'versionCheck', isEnabled: false }).label,
      'Paused',
    );
  });
});

describe('sortVersionHistory / formatSeenRange', () => {
  it('sorts newest first without mutating', () => {
    const history = [
      { value: '1.0.0', firstSeenAt: '2026-01-01T00:00:00.000Z', lastSeenAt: '2026-02-01T00:00:00.000Z' },
      { value: '1.2.0', firstSeenAt: '2026-03-01T00:00:00.000Z', lastSeenAt: '2026-03-01T00:00:00.000Z' },
      { value: '1.1.0', firstSeenAt: '2026-02-01T00:00:00.000Z', lastSeenAt: '2026-02-15T00:00:00.000Z' },
    ];
    assert.deepEqual(
      sortVersionHistory(history).map((entry) => entry.value),
      ['1.2.0', '1.1.0', '1.0.0'],
    );
    assert.equal(history[0].value, '1.0.0');
  });

  it('collapses equal first/last seen', () => {
    const t = '2026-03-01T00:00:00.000Z';
    assert.equal(formatSeenRange({ firstSeenAt: t, lastSeenAt: t }), formatDateTime(t));
    const t2 = '2026-03-02T00:00:00.000Z';
    assert.equal(formatSeenRange({ firstSeenAt: t, lastSeenAt: t2 }), `${formatDateTime(t)} – ${formatDateTime(t2)}`);
  });
});

describe('formatObservedValue', () => {
  it('formats numbers with units', () => {
    assert.equal(formatObservedValue({ observedValue: 42, observedUnit: 'ms' }), '42 ms');
    assert.equal(formatObservedValue({ observedValue: 12.5, observedUnit: '%' }), '12.5 %');
    assert.equal(formatObservedValue({ observedValue: 0.12345, observedUnit: 's' }), '0.123 s');
    assert.equal(formatObservedValue({ observedValue: 0 }), '0');
  });

  it('formats strings and booleans', () => {
    assert.equal(formatObservedValue({ observedValue: 'connected' }), 'connected');
    assert.equal(formatObservedValue({ observedValue: false }), 'false');
    assert.equal(formatObservedValue({ observedValue: true, observedUnit: '  ' }), 'true');
  });

  it('is null when nothing was observed', () => {
    assert.equal(formatObservedValue({}), null);
    assert.equal(formatObservedValue({ observedValue: '', observedUnit: 'ms' }), null);
    assert.equal(formatObservedValue({ observedUnit: 'ms' }), null);
  });
});

describe('componentTitle / healthStatusLabel', () => {
  it('adds the component id when it differs from the key', () => {
    assert.equal(componentTitle({ key: 'postgres:responseTime' }), 'postgres:responseTime');
    assert.equal(componentTitle({ key: 'postgres:responseTime', componentId: 'db-1' }), 'postgres:responseTime (db-1)');
    assert.equal(componentTitle({ key: 'redis', componentId: 'redis' }), 'redis');
    assert.equal(componentTitle({ key: 'redis', componentId: ' ' }), 'redis');
  });

  it('labels statuses', () => {
    assert.equal(healthStatusLabel('pass'), 'Pass');
    assert.equal(healthStatusLabel('warn'), 'Warn');
    assert.equal(healthStatusLabel('fail'), 'Fail');
  });
});

describe('shouldShowComponents', () => {
  const component = { key: 'db', status: 'pass' as const };
  const latest = {
    status: 'pass' as const,
    version: null,
    releaseId: null,
    output: null,
    checkedAt: '2026-10-01T10:00:00.000Z',
    components: [component],
  };

  it('shows for health-standard endpoints, even before data arrives', () => {
    assert.equal(shouldShowComponents(null, { healthStandard: true }), true);
    assert.equal(shouldShowComponents({ healthStandard: true, latest: null }, { healthStandard: false }), true);
  });

  it('shows when there is component data', () => {
    assert.equal(shouldShowComponents({ healthStandard: false, latest }, { healthStandard: false }), true);
  });

  it('hides otherwise', () => {
    assert.equal(shouldShowComponents(null, { healthStandard: false }), false);
    assert.equal(shouldShowComponents({ healthStandard: false, latest: null }, {}), false);
    assert.equal(
      shouldShowComponents({ healthStandard: false, latest: { ...latest, components: [] } }, {}),
      false,
    );
  });
});

describe('shouldShowVersion', () => {
  it('shows when a source applies or data exists', () => {
    assert.equal(shouldShowVersion(null, 'versionCheck'), true);
    assert.equal(shouldShowVersion(null, null), false);
    assert.equal(shouldShowVersion({ current: null, history: [] }, null), false);
    assert.equal(
      shouldShowVersion({ current: null, history: [{ value: '1', firstSeenAt: 'x', lastSeenAt: 'x' }] }, null),
      true,
    );
    assert.equal(
      shouldShowVersion({ current: { version: '1', isFailing: false, failureReason: null, lastCheckedAt: null }, history: [] }, null),
      true,
    );
  });
});
