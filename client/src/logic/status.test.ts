/// <reference types="node" />
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import type { DashboardEndpoint, DashboardResponse, DashboardSummary } from '../api/dashboard';
import {
  applyCheckEvent,
  checkState,
  deriveStatus,
  isCheckResultEvent,
  recomputeSummary,
  stateOfHealthStatus,
  statusOfDashboardEndpoint,
  summaryCounts,
  type CheckResultEvent,
} from './status';

function endpoint(overrides: Partial<DashboardEndpoint> = {}): DashboardEndpoint {
  return {
    id: 'e1',
    name: 'API',
    url: 'https://api.example.com/health',
    checkType: 'http',
    groupName: null,
    isPaused: false,
    latestCheck: null,
    uptimePercent24h: null,
    activeIncident: null,
    ...overrides,
  };
}

function latest(
  isHealthy: boolean,
  extra: Partial<NonNullable<DashboardEndpoint['latestCheck']>> = {},
): NonNullable<DashboardEndpoint['latestCheck']> {
  return {
    isHealthy,
    responseTimeMs: 10,
    statusCode: 200,
    failureReason: null,
    timestamp: '2026-10-01T10:00:00.000Z',
    certificateExpiresAt: null,
    ...extra,
  };
}

const baseSummary: DashboardSummary = {
  totalEndpoints: 0,
  healthyEndpoints: 0,
  unhealthyEndpoints: 0,
  degradedEndpoints: 0,
  pausedEndpoints: 0,
  overallUptimePercent: 99.5,
};

describe('deriveStatus', () => {
  it('is unknown without a check', () => {
    assert.equal(deriveStatus({ isPaused: false, isHealthy: null }), 'unknown');
    assert.equal(deriveStatus({ isPaused: false, isHealthy: undefined }), 'unknown');
  });

  it('is healthy for a healthy check without warn', () => {
    assert.equal(deriveStatus({ isPaused: false, isHealthy: true }), 'healthy');
    assert.equal(deriveStatus({ isPaused: false, isHealthy: true, healthStatus: 'pass' }), 'healthy');
    assert.equal(deriveStatus({ isPaused: false, isHealthy: true, healthStatus: null, isDegraded: false }), 'healthy');
  });

  it('is degraded from isDegraded or a warn health status', () => {
    assert.equal(deriveStatus({ isPaused: false, isHealthy: true, isDegraded: true }), 'degraded');
    assert.equal(deriveStatus({ isPaused: false, isHealthy: true, healthStatus: 'warn' }), 'degraded');
  });

  it('is unhealthy when down', () => {
    assert.equal(deriveStatus({ isPaused: false, isHealthy: false }), 'unhealthy');
    assert.equal(deriveStatus({ isPaused: false, isHealthy: false, healthStatus: 'fail' }), 'unhealthy');
  });

  describe('precedence: paused > down > degraded > healthy > unknown', () => {
    it('paused beats everything', () => {
      assert.equal(deriveStatus({ isPaused: true, isHealthy: false }), 'paused');
      assert.equal(deriveStatus({ isPaused: true, isHealthy: true, isDegraded: true }), 'paused');
      assert.equal(deriveStatus({ isPaused: true, isHealthy: true }), 'paused');
      assert.equal(deriveStatus({ isPaused: true, isHealthy: null }), 'paused');
    });

    it('down beats degraded (a stale degraded flag on a down check)', () => {
      assert.equal(deriveStatus({ isPaused: false, isHealthy: false, isDegraded: true }), 'unhealthy');
      assert.equal(deriveStatus({ isPaused: false, isHealthy: false, healthStatus: 'warn' }), 'unhealthy');
    });

    it('degraded beats healthy', () => {
      assert.equal(deriveStatus({ isPaused: false, isHealthy: true, isDegraded: true, healthStatus: 'pass' }), 'degraded');
    });

    it('a degraded flag without any check stays unknown', () => {
      assert.equal(deriveStatus({ isPaused: false, isHealthy: null, isDegraded: true }), 'unknown');
      assert.equal(deriveStatus({ isPaused: false, isHealthy: null, healthStatus: 'warn' }), 'unknown');
    });
  });
});

describe('checkState', () => {
  it('maps a single result', () => {
    assert.equal(checkState({ isHealthy: true }), 'healthy');
    assert.equal(checkState({ isHealthy: true, healthStatus: null }), 'healthy');
    assert.equal(checkState({ isHealthy: true, healthStatus: 'pass' }), 'healthy');
    assert.equal(checkState({ isHealthy: true, healthStatus: 'warn' }), 'degraded');
    assert.equal(checkState({ isHealthy: false, healthStatus: 'warn' }), 'unhealthy');
    assert.equal(checkState({ isHealthy: false, healthStatus: 'fail' }), 'unhealthy');
    assert.equal(checkState({ isHealthy: false }), 'unhealthy');
  });
});

describe('stateOfHealthStatus', () => {
  it('maps pass / warn / fail', () => {
    assert.equal(stateOfHealthStatus('pass'), 'healthy');
    assert.equal(stateOfHealthStatus('warn'), 'degraded');
    assert.equal(stateOfHealthStatus('fail'), 'unhealthy');
  });
});

describe('statusOfDashboardEndpoint', () => {
  it('reads the latest check', () => {
    assert.equal(statusOfDashboardEndpoint(endpoint()), 'unknown');
    assert.equal(statusOfDashboardEndpoint(endpoint({ latestCheck: latest(true) })), 'healthy');
    assert.equal(
      statusOfDashboardEndpoint(endpoint({ latestCheck: latest(true, { isDegraded: true, healthStatus: 'warn' }) })),
      'degraded',
    );
    assert.equal(statusOfDashboardEndpoint(endpoint({ latestCheck: latest(true, { healthStatus: 'warn' }) })), 'degraded');
    assert.equal(statusOfDashboardEndpoint(endpoint({ latestCheck: latest(false) })), 'unhealthy');
    assert.equal(statusOfDashboardEndpoint(endpoint({ isPaused: true, latestCheck: latest(false) })), 'paused');
  });
});

describe('summaryCounts', () => {
  it('splits degraded out of healthy', () => {
    assert.deepEqual(
      summaryCounts({
        ...baseSummary,
        totalEndpoints: 6,
        healthyEndpoints: 3,
        degradedEndpoints: 1,
        unhealthyEndpoints: 1,
        pausedEndpoints: 1,
      }),
      { total: 6, healthy: 2, degraded: 1, unhealthy: 1, paused: 1 },
    );
  });

  it('treats a missing degraded count (older backend) as 0', () => {
    const { degradedEndpoints: _omit, ...legacy } = { ...baseSummary, totalEndpoints: 2, healthyEndpoints: 2 };
    assert.deepEqual(summaryCounts(legacy), { total: 2, healthy: 2, degraded: 0, unhealthy: 0, paused: 0 });
  });

  it('never reports more degraded than healthy, or negative counts', () => {
    assert.deepEqual(
      summaryCounts({ ...baseSummary, totalEndpoints: 1, healthyEndpoints: 1, degradedEndpoints: 5 }),
      { total: 1, healthy: 0, degraded: 1, unhealthy: 0, paused: 0 },
    );
    assert.equal(summaryCounts({ ...baseSummary, degradedEndpoints: -2 }).degraded, 0);
  });

  it('all zeros for an empty dashboard', () => {
    assert.deepEqual(summaryCounts(baseSummary), { total: 0, healthy: 0, degraded: 0, unhealthy: 0, paused: 0 });
  });
});

describe('recomputeSummary', () => {
  it('counts like the backend: paused first, no check counts nowhere, degraded within healthy', () => {
    const endpoints = [
      endpoint({ id: 'a', latestCheck: latest(true) }),
      endpoint({ id: 'b', latestCheck: latest(true, { isDegraded: true, healthStatus: 'warn' }) }),
      endpoint({ id: 'c', latestCheck: latest(false) }),
      endpoint({ id: 'd', isPaused: true, latestCheck: latest(false) }),
      endpoint({ id: 'e', latestCheck: null }),
      endpoint({ id: 'f', latestCheck: latest(true, { healthStatus: 'warn' }) }),
    ];
    const summary = recomputeSummary({ ...baseSummary, totalEndpoints: 6 }, endpoints);
    assert.deepEqual(summary, {
      totalEndpoints: 6,
      healthyEndpoints: 3,
      degradedEndpoints: 2,
      unhealthyEndpoints: 1,
      pausedEndpoints: 1,
      overallUptimePercent: 99.5,
    });
  });
});

describe('isCheckResultEvent', () => {
  it('accepts check results and rejects other frames', () => {
    assert.equal(
      isCheckResultEvent({ endpointId: 'e1', isHealthy: true, timestamp: 't', healthStatus: null }),
      true,
    );
    assert.equal(isCheckResultEvent({ type: 'connected' }), false);
    assert.equal(isCheckResultEvent(null), false);
    assert.equal(isCheckResultEvent('x'), false);
    assert.equal(isCheckResultEvent({ endpointId: 'e1', isHealthy: 'yes', timestamp: 't' }), false);
  });
});

describe('applyCheckEvent', () => {
  const data: DashboardResponse = {
    summary: { ...baseSummary, totalEndpoints: 2, healthyEndpoints: 2 },
    endpoints: [
      endpoint({ id: 'a', latestCheck: latest(true, { certificateExpiresAt: '2027-01-01T00:00:00.000Z' }) }),
      endpoint({ id: 'b', latestCheck: latest(true) }),
    ],
  };

  function event(overrides: Partial<CheckResultEvent> = {}): CheckResultEvent {
    return {
      endpointId: 'a',
      isHealthy: true,
      responseTimeMs: 55,
      statusCode: 200,
      failureReason: 'Database slow',
      healthStatus: 'warn',
      timestamp: '2026-10-01T10:05:00.000Z',
      ...overrides,
    };
  }

  it('marks a warn result degraded and updates the summary', () => {
    const next = applyCheckEvent(data, event());
    const a = next.endpoints[0];
    assert.equal(a.latestCheck?.isDegraded, true);
    assert.equal(a.latestCheck?.healthStatus, 'warn');
    assert.equal(a.latestCheck?.responseTimeMs, 55);
    assert.equal(a.latestCheck?.failureReason, 'Database slow');
    assert.equal(a.latestCheck?.certificateExpiresAt, '2027-01-01T00:00:00.000Z', 'keeps certificate expiry');
    assert.equal(statusOfDashboardEndpoint(a), 'degraded');
    assert.equal(next.summary.healthyEndpoints, 2);
    assert.equal(next.summary.degradedEndpoints, 1);
    assert.equal(next.endpoints[1], data.endpoints[1], 'other endpoints untouched');
    assert.equal(data.endpoints[0].latestCheck?.healthStatus, undefined, 'input not mutated');
  });

  it('a down result is never degraded', () => {
    const next = applyCheckEvent(data, event({ isHealthy: false, healthStatus: 'warn' }));
    assert.equal(next.endpoints[0].latestCheck?.isDegraded, false);
    assert.equal(next.summary.unhealthyEndpoints, 1);
    assert.equal(next.summary.healthyEndpoints, 1);
    assert.equal(next.summary.degradedEndpoints, 0);
  });

  it('treats a missing healthStatus (older backend) as non-standard', () => {
    const { healthStatus: _omit, ...legacy } = event();
    const next = applyCheckEvent(data, legacy);
    assert.equal(next.endpoints[0].latestCheck?.healthStatus, null);
    assert.equal(next.endpoints[0].latestCheck?.isDegraded, false);
  });

  it('ignores events for unknown endpoints', () => {
    assert.equal(applyCheckEvent(data, event({ endpointId: 'zzz' })), data);
  });
});
