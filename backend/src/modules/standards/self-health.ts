import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { HealthStatus } from '../../db/schema.js';
import { HTTP_STATUS_FOR, worstStatus } from './health-standard.js';

/**
 * The backend's own `GET /health`, in the Zext Health Standard format. Dependency probes are cached
 * for `CACHE_TTL_MS` and individually time-limited, as the standard asks, so a burst of monitor
 * requests never turns into a burst of database round trips.
 */

const PROBE_TIMEOUT_MS = 800;
/** A dependency that answers but slower than this is reported as `warn`. */
const PROBE_WARN_MS = 250;
const CACHE_TTL_MS = 10_000;

export type Probe = () => Promise<unknown>;

export interface SelfHealthDeps {
  probes: Record<string, Probe>;
  version: string | null;
  releaseId: string | null;
  now?: () => number;
}

export interface SelfHealthResponse {
  httpStatus: number;
  body: Record<string, unknown>;
}

interface CheckEntry {
  componentType: 'datastore';
  status: HealthStatus;
  observedValue?: number;
  observedUnit?: 'ms';
  time: string;
  output?: string;
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const handle = setTimeout(() => reject(new Error('timed out')), ms);
    promise.then(
      (value) => {
        clearTimeout(handle);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(handle);
        reject(error);
      },
    );
  });
}

async function runProbe(name: string, probe: Probe, now: () => number): Promise<CheckEntry> {
  const start = performance.now();
  const time = new Date(now()).toISOString();
  try {
    await withTimeout(probe(), PROBE_TIMEOUT_MS);
    const elapsed = Math.round(performance.now() - start);
    return {
      componentType: 'datastore',
      status: elapsed > PROBE_WARN_MS ? 'warn' : 'pass',
      observedValue: elapsed,
      observedUnit: 'ms',
      time,
      ...(elapsed > PROBE_WARN_MS ? { output: `${name} is slow` } : {}),
    };
  } catch (error) {
    // Never echo the driver's error message: it can carry hostnames or connection details.
    const timedOut = error instanceof Error && error.message === 'timed out';
    return { componentType: 'datastore', status: 'fail', time, output: timedOut ? `${name} timed out` : `${name} unreachable` };
  }
}

export async function buildSelfHealth(deps: SelfHealthDeps): Promise<SelfHealthResponse> {
  const now = deps.now ?? Date.now;
  const names = Object.keys(deps.probes);
  const entries = await Promise.all(names.map((name) => runProbe(name, deps.probes[name], now)));

  const checks: Record<string, CheckEntry[]> = {};
  names.forEach((name, index) => {
    checks[`${name}:responseTime`] = [entries[index]];
  });

  const status = worstStatus(entries.map((entry) => entry.status));
  const firstProblem = entries.find((entry) => entry.status === status && status !== 'pass');

  const body: Record<string, unknown> = { status };
  if (deps.version) body.version = deps.version;
  if (deps.releaseId) body.releaseId = deps.releaseId;
  body.serviceId = 'health-monitor-api';
  if (firstProblem?.output) body.output = firstProblem.output;
  body.checks = checks;

  return { httpStatus: HTTP_STATUS_FOR[status], body };
}

/** Wraps `buildSelfHealth` with a short cache so probes run at most once per TTL. */
export function createSelfHealthHandler(deps: SelfHealthDeps, ttlMs: number = CACHE_TTL_MS) {
  const now = deps.now ?? Date.now;
  let cached: { at: number; value: Promise<SelfHealthResponse> } | null = null;
  return (): Promise<SelfHealthResponse> => {
    if (!cached || now() - cached.at >= ttlMs) {
      const value = buildSelfHealth(deps);
      cached = { at: now(), value };
      // A rejected build would otherwise be cached; buildSelfHealth itself never rejects, but be safe.
      value.catch(() => {
        cached = null;
      });
    }
    return cached.value;
  };
}

/** `version` from the backend's package.json (same relative path from src/ and dist/). */
export function readPackageVersion(): string | null {
  try {
    const path = fileURLToPath(new URL('../../../package.json', import.meta.url));
    const version = (JSON.parse(readFileSync(path, 'utf8')) as { version?: unknown }).version;
    return typeof version === 'string' ? version : null;
  } catch {
    return null;
  }
}

/** `RELEASE_ID` env var, else the current git SHA when running from a checkout, else `null`. */
export function resolveReleaseId(env: NodeJS.ProcessEnv = process.env): string | null {
  const fromEnv = env.RELEASE_ID?.trim();
  if (fromEnv) {
    return fromEnv;
  }
  try {
    const sha = execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: fileURLToPath(new URL('.', import.meta.url)),
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 2000,
    })
      .toString()
      .trim();
    return /^[0-9a-f]{7,40}$/i.test(sha) ? sha : null;
  } catch {
    return null; // no git binary / not a checkout (e.g. the Docker image)
  }
}
