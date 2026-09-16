import net from 'node:net';
import tls from 'node:tls';
import { Worker, Queue } from 'bullmq';
import type { Job } from 'bullmq';
import { Redis as IORedis } from 'ioredis';
import { eq, and, sql } from 'drizzle-orm';
import { env } from '../../config/env.js';
import { db } from '../../db/index.js';
import {
  endpoints,
  endpointSecrets,
  healthCheckResults,
  dailyStats,
  incidents,
} from '../../db/schema.js';
import type { Endpoint, JsonAssertion } from '../../db/schema.js';
import { decrypt } from '../../utils/crypto.js';
import { REDIS_CHANNEL, type CheckResultEvent } from '../sse/sse-bus.js';

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
}

const HTTP_TIMEOUT_MS = 30_000;
const TCP_TIMEOUT_MS = 30_000;
const TLS_TIMEOUT_MS = 10_000;

const connection = new IORedis(env.REDIS_URL, { maxRetriesPerRequest: null });
const publisher = new IORedis(env.REDIS_URL);

const checkQueue = new Queue<CheckJobData>(QUEUE_NAME, { connection });

let worker: Worker<CheckJobData> | undefined;

function buildAuthHeaders(endpoint: Endpoint, secret: string | null): Record<string, string> {
  if (!secret) {
    return {};
  }

  switch (endpoint.authType) {
    case 'bearer_token':
      return { Authorization: `Bearer ${secret}` };
    case 'basic_auth': {
      const credentials = Buffer.from(`${endpoint.authUsername ?? ''}:${secret}`).toString('base64');
      return { Authorization: `Basic ${credentials}` };
    }
    case 'custom_header':
      return endpoint.authHeaderName ? { [endpoint.authHeaderName]: secret } : {};
    default:
      return {};
  }
}

function getByPath(obj: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((acc, key) => {
    if (acc && typeof acc === 'object' && key in (acc as Record<string, unknown>)) {
      return (acc as Record<string, unknown>)[key];
    }
    return undefined;
  }, obj);
}

function matchesAssertion(
  value: unknown,
  expectedValue: string,
  matchMode: JsonAssertion['matchMode'],
): boolean {
  const stringValue = value === undefined || value === null ? '' : String(value);

  switch (matchMode) {
    case 'exact':
      return stringValue === expectedValue;
    case 'contains':
      return stringValue.includes(expectedValue);
    case 'regex':
      return new RegExp(expectedValue).test(stringValue);
    default:
      return false;
  }
}

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

  for (const assertion of assertions) {
    const value = getByPath(body, assertion.path);
    if (!matchesAssertion(value, assertion.expectedValue, assertion.matchMode)) {
      return {
        passed: false,
        reason: `Assertion failed: "${assertion.path}" did not match "${assertion.expectedValue}"`,
      };
    }
  }

  return { passed: true, reason: null };
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
    const responseTimeMs = Math.round(performance.now() - start);
    const statusCode = response.status;

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

async function updateDailyStats(
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

async function manageIncidents(
  endpointId: string,
  isHealthy: boolean,
  failureReason: string | null,
): Promise<void> {
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
    }
    return;
  }

  if (ongoing) {
    await db
      .update(incidents)
      .set({ endedAt: new Date(), isOngoing: false })
      .where(eq(incidents.id, ongoing.id));
  }
}

async function processCheckJob(job: Job<CheckJobData>): Promise<void> {
  const { endpointId } = job.data;

  try {
    const endpoint = await db.query.endpoints.findFirst({
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

    const outcome = await runCheck(endpoint, secret);

    await db.insert(healthCheckResults).values({
      endpointId,
      isHealthy: outcome.isHealthy,
      responseTimeMs: outcome.responseTimeMs,
      statusCode: outcome.statusCode,
      failureReason: outcome.failureReason,
      certificateExpiresAt: outcome.certificateExpiresAt,
    });

    const sseEvent: CheckResultEvent = {
      endpointId,
      userId: endpoint.userId,
      isHealthy: outcome.isHealthy,
      responseTimeMs: outcome.responseTimeMs,
      statusCode: outcome.statusCode,
      failureReason: outcome.failureReason,
      timestamp: new Date().toISOString(),
    };
    await publisher.publish(REDIS_CHANNEL, JSON.stringify(sseEvent));

    await updateDailyStats(endpointId, outcome.isHealthy, endpoint.checkInterval);
    await manageIncidents(endpointId, outcome.isHealthy, outcome.failureReason);
  } catch (error) {
    console.error(`Health check processing failed for endpoint ${endpointId}:`, error);
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
