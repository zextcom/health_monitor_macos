import { and, desc, eq, gte, inArray } from 'drizzle-orm';
import { db } from '../../db/index.js';
import { dailyStats, endpoints, healthCheckResults, incidents } from '../../db/schema.js';

export interface DashboardEndpoint {
  id: string;
  name: string;
  url: string;
  checkType: string;
  groupName: string | null;
  isPaused: boolean;
  latestCheck: {
    isHealthy: boolean;
    responseTimeMs: number | null;
    statusCode: number | null;
    failureReason: string | null;
    timestamp: string;
    certificateExpiresAt: string | null;
  } | null;
  uptimePercent24h: number | null;
  activeIncident: {
    startedAt: string;
    failureReason: string | null;
  } | null;
}

export interface DashboardResponse {
  summary: {
    totalEndpoints: number;
    healthyEndpoints: number;
    unhealthyEndpoints: number;
    pausedEndpoints: number;
    overallUptimePercent: number;
  };
  endpoints: DashboardEndpoint[];
}

function emptyDashboard(): DashboardResponse {
  return {
    summary: {
      totalEndpoints: 0,
      healthyEndpoints: 0,
      unhealthyEndpoints: 0,
      pausedEndpoints: 0,
      overallUptimePercent: 100,
    },
    endpoints: [],
  };
}

export async function getDashboard(userId: string): Promise<DashboardResponse> {
  const userEndpoints = await db.select().from(endpoints).where(eq(endpoints.userId, userId));

  if (userEndpoints.length === 0) {
    return emptyDashboard();
  }

  const endpointIds = userEndpoints.map((endpoint) => endpoint.id);

  const since = new Date();
  since.setDate(since.getDate() - 1);
  const sinceStr = since.toISOString().slice(0, 10);

  const [latestChecks, activeIncidents, statsRows] = await Promise.all([
    db
      .selectDistinctOn([healthCheckResults.endpointId])
      .from(healthCheckResults)
      .where(inArray(healthCheckResults.endpointId, endpointIds))
      .orderBy(healthCheckResults.endpointId, desc(healthCheckResults.timestamp)),
    db
      .select()
      .from(incidents)
      .where(and(inArray(incidents.endpointId, endpointIds), eq(incidents.isOngoing, true))),
    db
      .select()
      .from(dailyStats)
      .where(and(inArray(dailyStats.endpointId, endpointIds), gte(dailyStats.date, sinceStr))),
  ]);

  const latestCheckByEndpoint = new Map<string, (typeof latestChecks)[number]>();
  for (const check of latestChecks) {
    latestCheckByEndpoint.set(check.endpointId, check);
  }

  const incidentByEndpoint = new Map<string, (typeof activeIncidents)[number]>();
  for (const incident of activeIncidents) {
    const existing = incidentByEndpoint.get(incident.endpointId);
    if (!existing || incident.startedAt > existing.startedAt) {
      incidentByEndpoint.set(incident.endpointId, incident);
    }
  }

  const statsByEndpoint = new Map<string, { totalChecks: number; downChecks: number }>();
  for (const stat of statsRows) {
    const existing = statsByEndpoint.get(stat.endpointId) ?? { totalChecks: 0, downChecks: 0 };
    existing.totalChecks += stat.totalChecks;
    existing.downChecks += stat.downChecks;
    statsByEndpoint.set(stat.endpointId, existing);
  }

  let healthyEndpoints = 0;
  let unhealthyEndpoints = 0;
  let pausedEndpoints = 0;
  let totalChecksAll = 0;
  let downChecksAll = 0;

  const dashboardEndpoints: DashboardEndpoint[] = userEndpoints.map((endpoint) => {
    const latestCheck = latestCheckByEndpoint.get(endpoint.id) ?? null;
    const activeIncident = incidentByEndpoint.get(endpoint.id) ?? null;
    const stats = statsByEndpoint.get(endpoint.id);

    if (endpoint.isPaused) {
      pausedEndpoints += 1;
    } else if (latestCheck) {
      if (latestCheck.isHealthy) {
        healthyEndpoints += 1;
      } else {
        unhealthyEndpoints += 1;
      }
    }

    if (stats) {
      totalChecksAll += stats.totalChecks;
      downChecksAll += stats.downChecks;
    }

    return {
      id: endpoint.id,
      name: endpoint.name,
      url: endpoint.url,
      checkType: endpoint.checkType,
      groupName: endpoint.groupName,
      isPaused: endpoint.isPaused,
      latestCheck: latestCheck
        ? {
            isHealthy: latestCheck.isHealthy,
            responseTimeMs: latestCheck.responseTimeMs,
            statusCode: latestCheck.statusCode,
            failureReason: latestCheck.failureReason,
            timestamp: latestCheck.timestamp.toISOString(),
            certificateExpiresAt: latestCheck.certificateExpiresAt
              ? latestCheck.certificateExpiresAt.toISOString()
              : null,
          }
        : null,
      uptimePercent24h: stats
        ? stats.totalChecks === 0
          ? 100
          : (1 - stats.downChecks / stats.totalChecks) * 100
        : null,
      activeIncident: activeIncident
        ? {
            startedAt: activeIncident.startedAt.toISOString(),
            failureReason: activeIncident.failureReason,
          }
        : null,
    };
  });

  const overallUptimePercent =
    totalChecksAll === 0 ? 100 : (1 - downChecksAll / totalChecksAll) * 100;

  return {
    summary: {
      totalEndpoints: userEndpoints.length,
      healthyEndpoints,
      unhealthyEndpoints,
      pausedEndpoints,
      overallUptimePercent,
    },
    endpoints: dashboardEndpoints,
  };
}
