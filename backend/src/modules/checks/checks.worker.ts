import net from 'node:net';
import tls from 'node:tls';
import { Worker, Queue } from 'bullmq';
import type { Job } from 'bullmq';
import { Redis as IORedis } from 'ioredis';
import { eq, and, desc, sql } from 'drizzle-orm';
import { env } from '../../config/env.js';
import { db } from '../../db/index.js';
import {
  endpoints,
  endpointSecrets,
  healthCheckResults,
  dailyStats,
  incidents,
} from '../../db/schema.js';
import type { Endpoint, HealthStatus, JsonAssertion } from '../../db/schema.js';
import { buildAuthHeaders, evaluateAssertions, getByPath, matchesAssertion } from './check-helpers.js';
import { runVersionCheckIfDue } from './version-check.js';
import {
  degradedTransition,
  evaluateStandardHttpCheck,
  healthStateOf,
  notifyDegradedTransition,
  recordAutoVersion,
  recordHealthDetails,
} from './health-standard-check.js';
import type { ParsedHealthResponse } from '../standards/health-standard.js';
import { decrypt } from '../../utils/crypto.js';
import { REDIS_CHANNEL, type CheckResultEvent } from '../sse/sse-bus.js';
import { notifyEndpointDown, notifyEndpointRecovered } from '../notifications/notification.service.js';

// Re-exported so existing imports (and tests) of these helpers from the worker keep working.
export { buildAuthHeaders, getByPath, matchesAssertion };

export const QUEUE_NAME = 'health-checks';

interface CheckJobData {
  endpointId: string;
}

interface CheckOutcome {
  isHealthy: boolean;
  responseTimeMs: number | null;
  statusCode: number | null;
  failureReason: string | null;
  certificateExpiresAt: Date | null;
  /** Health-standard endpoints only: the body's `status` when it could be read. */
  healthStatus?: HealthStatus | null;
  /** Health-standard endpoints only: the parsed body (components, version) when readable. */
  standard?: ParsedHealthResponse | null;
}

const HTTP_TIMEOUT_MS = 30_000;
const TCP_TIMEOUT_MS = 30_000;
const TLS_TIMEOUT_MS = 10_000;

const connection = new IORedis(env.REDIS_URL, { maxRetriesPerRequest: null });
const publisher = new IORedis(env.REDIS_URL);

const checkQueue = new Queue<CheckJobData>(QUEUE_NAME, { connection });

let worker: Worker<CheckJobData> | undefined;

async function checkJsonAssertions(
  response: Response,
  assertions: JsonAssertion[],
): Promise<{ passed: boolean; reason: string | null }> {
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return { passed: false, reason: 'Response body is not valid JSON' };
  }

  return evaluateAssertions(body, assertions);
}

function getCertificateExpiry(urlString: string): Promise<Date | null> {
  return new Promise((resolve) => {
    let url: URL;
    try {
      url = new URL(urlString);
    } catch {
      resolve(null);
      return;
    }

    const port = url.port ? Number(url.port) : 443;
    const socket = tls.connect(
      {
        host: url.hostname,
        port,
        servername: url.hostname,
        timeout: TLS_TIMEOUT_MS,
        rejectUnauthorized: false,
      },
      () => {
        const cert = socket.getPeerCertificate();
        socket.end();
        resolve(cert?.valid_to ? new Date(cert.valid_to) : null);
      },
    );

    socket.once('error', () => resolve(null));
    socket.once('timeout', () => {
      socket.destroy();
      resolve(null);
    });
  });
}

async function performHttpCheck(endpoint: Endpoint, secret: string | null): Promise<CheckOutcome> {
  const controller = new AbortController();
  const timeoutHandle = setTimeout(() => controller.abort(), HTTP_TIMEOUT_MS);
  const start = performance.now();

  try {
    const headers = buildAuthHeaders(endpoint, secret);
    const response = await fetch(endpoint.url, { signal: controller.signal, headers });
    const statusCode = response.status;

    if (endpoint.healthStandard) {
      // expectedStatusCode is ignored: the standard defines 200 (pass/warn) and 503 (fail).
      const bodyText = await response.text();
      const responseTimeMs = Math.round(performance.now() - start);
      const evaluation = evaluateStandardHttpCheck(endpoint, statusCode, bodyText);
      const certificateExpiresAt = endpoint.url.startsWith('https://')
        ? await getCertificateExpiry(endpoint.url)
        : null;
      return {
        isHealthy: evaluation.isHealthy,
        responseTimeMs,
        statusCode,
        failureReason: evaluation.failureReason,
        certificateExpiresAt,
        healthStatus: evaluation.healthStatus,
        standard: evaluation.parsed,
      };
    }

    const responseTimeMs = Math.round(performance.now() - start);

    let isHealthy = statusCode === endpoint.expectedStatusCode;
    let failureReason: string | null = isHealthy
      ? null
      : `Expected status ${endpoint.expectedStatusCode}, got ${statusCode}`;

    if (isHealthy && endpoint.jsonAssertions.length > 0) {
      const assertionResult = await checkJsonAssertions(response, endpoint.jsonAssertions);
      if (!assertionResult.passed) {
        isHealthy = false;
        failureReason = assertionResult.reason;
      }
    }

    const certificateExpiresAt = endpoint.url.startsWith('https://')
      ? await getCertificateExpiry(endpoint.url)
      : null;

    return { isHealthy, responseTimeMs, statusCode, failureReason, certificateExpiresAt };
  } catch (error) {
    const responseTimeMs = Math.round(performance.now() - start);
    return {
      isHealthy: false,
      responseTimeMs,
      statusCode: null,
      failureReason: error instanceof Error ? error.message : 'Unknown error during HTTP check',
      certificateExpiresAt: null,
    };
  } finally {
    clearTimeout(timeoutHandle);
  }
}

function performTcpCheck(endpoint: Endpoint): Promise<CheckOutcome> {
  return new Promise((resolve) => {
    let host: string;
    let port: number;

    try {
      const url = new URL(endpoint.url);
      host = url.hostname;
      port = Number(url.port);
      if (!host || !port) {
        throw new Error('Invalid TCP URL, expected tcp://host:port');
      }
    } catch (error) {
      resolve({
        isHealthy: false,
        responseTimeMs: null,
        statusCode: null,
        failureReason: error instanceof Error ? error.message : 'Invalid TCP URL',
        certificateExpiresAt: null,
      });
      return;
    }

    const start = performance.now();
    const socket = net.createConnection({ host, port, timeout: TCP_TIMEOUT_MS });
    let settled = false;

    const finish = (outcome: CheckOutcome) => {
      if (settled) {
        return;
      }
      settled = true;
      socket.destroy();
      resolve(outcome);
    };

    socket.once('connect', () => {
      finish({
        isHealthy: true,
        responseTimeMs: Math.round(performance.now() - start),
        statusCode: null,
        failureReason: null,
        certificateExpiresAt: null,
      });
    });

    socket.once('timeout', () => {
      finish({
        isHealthy: false,
        responseTimeMs: Math.round(performance.now() - start),
        statusCode: null,
        failureReason: 'Connection timed out',
        certificateExpiresAt: null,
      });
    });

    socket.once('error', (error) => {
      finish({
        isHealthy: false,
        responseTimeMs: Math.round(performance.now() - start),
        statusCode: null,
        failureReason: error.message,
        certificateExpiresAt: null,
      });
    });
  });
}

async function runCheck(endpoint: Endpoint, secret: string | null): Promise<CheckOutcome> {
  if (endpoint.checkType === 'tcp') {
    return performTcpCheck(endpoint);
  }
  return performHttpCheck(endpoint, secret);
}

export async function updateDailyStats(
  endpointId: string,
  isHealthy: boolean,
  checkInterval: number,
): Promise<void> {
  const todayStr = new Date().toISOString().slice(0, 10);

  await db
    .insert(dailyStats)
    .values({
      endpointId,
      date: todayStr,
      totalChecks: 1,
      downChecks: isHealthy ? 0 : 1,
      downtimeSeconds: isHealthy ? '0' : String(checkInterval),
    })
    .onConflictDoUpdate({
      target: [dailyStats.endpointId, dailyStats.date],
      set: {
        totalChecks: sql`${dailyStats.totalChecks} + 1`,
        downChecks: isHealthy ? sql`${dailyStats.downChecks}` : sql`${dailyStats.downChecks} + 1`,
        downtimeSeconds: isHealthy
          ? sql`${dailyStats.downtimeSeconds}`
          : sql`${dailyStats.downtimeSeconds} + ${checkInterval}`,
      },
    });
}

type IncidentAction = 'opened' | 'closed' | 'none';

export async function manageIncidents(
  endpointId: string,
  isHealthy: boolean,
  failureReason: string | null,
): Promise<IncidentAction> {
  const ongoing = await db.query.incidents.findFirst({
    where: and(eq(incidents.endpointId, endpointId), eq(incidents.isOngoing, true)),
  });

  if (!isHealthy) {
    if (!ongoing) {
      await db.insert(incidents).values({
        endpointId,
        startedAt: new Date(),
        isOngoing: true,
        failureReason,
      });
      return 'opened';
    }
    return 'none';
  }

  if (ongoing) {
    await db
      .update(incidents)
      .set({ endedAt: new Date(), isOngoing: false })
      .where(eq(incidents.id, ongoing.id));
    return 'closed';
  }

  return 'none';
}

async function processCheckJob(job: Job<CheckJobData>): Promise<void> {
  await runCheckForEndpoint(job.data.endpointId);
}

/** One full check of `endpointId`: run, persist, publish, stats, incidents, notifications, follow-ups. */
export async function runCheckForEndpoint(endpointId: string): Promise<void> {
  let endpoint: Endpoint | undefined;
  let outcome: CheckOutcome;
  let previousResult: { isHealthy: boolean; healthStatus: HealthStatus | null } | undefined;

  try {
    endpoint = await db.query.endpoints.findFirst({
      where: eq(endpoints.id, endpointId),
    });

    if (!endpoint || endpoint.isPaused) {
      return;
    }

    let secret: string | null = null;
    if (endpoint.authType !== 'none') {
      const secretRow = await db.query.endpointSecrets.findFirst({
        where: eq(endpointSecrets.endpointId, endpointId),
      });
      if (secretRow) {
        secret = decrypt(secretRow.encryptedValue, secretRow.iv);
      }
    }

    outcome = await runCheck(endpoint, secret);

    previousResult = await db.query.healthCheckResults.findFirst({
      where: eq(healthCheckResults.endpointId, endpointId),
      orderBy: [desc(healthCheckResults.timestamp)],
      columns: { isHealthy: true, healthStatus: true },
    });

    await db.insert(healthCheckResults).values({
      endpointId,
      isHealthy: outcome.isHealthy,
      responseTimeMs: outcome.responseTimeMs,
      statusCode: outcome.statusCode,
      failureReason: outcome.failureReason,
      certificateExpiresAt: outcome.certificateExpiresAt,
      healthStatus: outcome.healthStatus ?? null,
    });

    const sseEvent: CheckResultEvent = {
      endpointId,
      userId: endpoint.userId,
      isHealthy: outcome.isHealthy,
      responseTimeMs: outcome.responseTimeMs,
      statusCode: outcome.statusCode,
      failureReason: outcome.failureReason,
      healthStatus: outcome.healthStatus ?? null,
      timestamp: new Date().toISOString(),
    };
    await publisher.publish(REDIS_CHANNEL, JSON.stringify(sseEvent));

    // Degraded (healthy + warn) counts as up for daily stats and incidents.
    await updateDailyStats(endpointId, outcome.isHealthy, endpoint.checkInterval);

    const currentState = healthStateOf({ isHealthy: outcome.isHealthy, healthStatus: outcome.healthStatus ?? null });
    const incidentAction = await manageIncidents(endpointId, outcome.isHealthy, outcome.failureReason);
    if (incidentAction === 'opened') {
      await notifyEndpointDown(endpointId, outcome.failureReason);
    } else if (incidentAction === 'closed') {
      // down → degraded: a single "recovered" notification, worded as degraded.
      await notifyEndpointRecovered(endpointId, currentState === 'degraded' ? outcome.failureReason : undefined);
    }

    const previousState = previousResult ? healthStateOf(previousResult) : null;
    await notifyDegradedTransition(endpointId, degradedTransition(previousState, currentState), outcome.failureReason);
  } catch (error) {
    console.error(`Health check processing failed for endpoint ${endpointId}:`, error);
    return;
  }

  // Separate try, like the version check below: storing components or the auto-tracked version
  // must never alter the health result that was already recorded.
  if (endpoint.healthStandard && outcome.standard) {
    try {
      await recordHealthDetails(endpointId, outcome.standard);
      await recordAutoVersion(endpoint, outcome.standard, outcome.statusCode, outcome.responseTimeMs);
    } catch (error) {
      console.error(`Health standard processing failed for endpoint ${endpointId}:`, error);
    }
  }

  // Separate try so a version check problem can never be mistaken for (or mask) a health failure.
  try {
    await runVersionCheckIfDue(endpoint);
  } catch (error) {
    console.error(`Version check processing failed for endpoint ${endpointId}:`, error);
  }
}

export async function startWorker(): Promise<void> {
  worker = new Worker<CheckJobData>(QUEUE_NAME, processCheckJob, { connection });

  worker.on('failed', (job, error) => {
    console.error(`Health check job ${job?.id ?? 'unknown'} failed:`, error);
  });
}

export async function stopWorker(): Promise<void> {
  await worker?.close();
  await checkQueue.close();
  connection.disconnect();
  publisher.disconnect();
}

export async function setupCheckSchedules(): Promise<void> {
  const activeEndpoints = await db.query.endpoints.findMany({
    where: eq(endpoints.isPaused, false),
  });

  for (const endpoint of activeEndpoints) {
    await checkQueue.upsertJobScheduler(
      `check:${endpoint.id}`,
      { every: endpoint.checkInterval * 1000 },
      { data: { endpointId: endpoint.id } },
    );
  }

  const pausedEndpoints = await db.query.endpoints.findMany({
    where: eq(endpoints.isPaused, true),
  });

  for (const endpoint of pausedEndpoints) {
    await checkQueue.removeJobScheduler(`check:${endpoint.id}`);
  }
}
