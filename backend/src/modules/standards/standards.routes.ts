import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { HEALTH_STANDARD_DOCUMENT, HEALTH_STANDARD_ID, HEALTH_STANDARD_SCHEMA } from './health-standard.js';
import { validateHealthResponse, type ValidationReport } from './health-standard-validator.js';

/**
 * `GET /api/standards/health` and `GET /api/standards/health/schema.json` are public so other
 * services' developers (and their CI) can read the standard without an account.
 * `POST /api/standards/health/validate` fetches arbitrary URLs, so it requires auth like the
 * endpoints routes do.
 */

export const VALIDATE_FETCH_TIMEOUT_MS = 10_000;
export const VALIDATE_MAX_BODY_BYTES = 256 * 1024;
const MAX_REDIRECTS = 5;

const httpUrl = z
  .string()
  .url()
  .refine((value) => /^https?:\/\//i.test(value), 'Must be an http(s) URL');

export const validateRequestSchema = z.union([
  z.object({ url: httpUrl }).strict(),
  z
    .object({
      response: z
        .object({
          httpStatus: z.number().int().min(100).max(599),
          contentType: z.string().nullable().optional(),
          cacheControl: z.string().nullable().optional(),
          body: z.unknown(),
        })
        .strict()
        .refine((response) => response.body !== undefined, { message: 'body is required', path: ['body'] }),
    })
    .strict(),
]);

export interface FetchedResponse {
  httpStatus: number;
  contentType: string | null;
  cacheControl: string | null;
  body: string;
  responseTimeMs: number;
  tooLarge: boolean;
}

/** Reads at most `limit` bytes; `tooLarge` when the body was longer (the rest is discarded). */
async function readCapped(response: Response, limit: number): Promise<{ text: string; tooLarge: boolean }> {
  if (!response.body) {
    return { text: '', tooLarge: false };
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    total += value.byteLength;
    if (total > limit) {
      await reader.cancel();
      return { text: '', tooLarge: true };
    }
    chunks.push(value);
  }
  return { text: Buffer.concat(chunks).toString('utf8'), tooLarge: false };
}

/**
 * GETs `url` for validation: 10s overall timeout, 256 KB body cap, and redirects followed manually
 * so a `Location` pointing at a non-http(s) scheme is rejected rather than followed.
 */
export async function fetchForValidation(url: string, fetchImpl: typeof fetch = fetch): Promise<FetchedResponse> {
  const controller = new AbortController();
  const timeoutHandle = setTimeout(() => controller.abort(), VALIDATE_FETCH_TIMEOUT_MS);
  const start = performance.now();

  try {
    let current = new URL(url);
    for (let redirects = 0; ; redirects += 1) {
      if (current.protocol !== 'http:' && current.protocol !== 'https:') {
        throw new Error(`Refusing to follow a redirect to a non-http(s) URL (${current.protocol})`);
      }
      const response = await fetchImpl(current, {
        signal: controller.signal,
        redirect: 'manual',
        headers: { Accept: 'application/health+json, application/json;q=0.9, */*;q=0.1' },
      });
      const location = response.headers.get('location');
      if (response.status >= 300 && response.status < 400 && location) {
        if (redirects >= MAX_REDIRECTS) {
          throw new Error('Too many redirects');
        }
        await response.body?.cancel();
        current = new URL(location, current);
        continue;
      }
      const { text, tooLarge } = await readCapped(response, VALIDATE_MAX_BODY_BYTES);
      return {
        httpStatus: response.status,
        contentType: response.headers.get('content-type'),
        cacheControl: response.headers.get('cache-control'),
        body: text,
        responseTimeMs: Math.round(performance.now() - start),
        tooLarge,
      };
    }
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`Timed out after ${VALIDATE_FETCH_TIMEOUT_MS / 1000}s`);
    }
    throw error;
  } finally {
    clearTimeout(timeoutHandle);
  }
}

function fetchFailureReport(message: string): ValidationReport {
  return {
    standard: HEALTH_STANDARD_ID,
    valid: false,
    errors: [{ path: 'http', rule: 'fetch', message }],
    warnings: [],
    observed: { httpStatus: 0, contentType: null, checkCount: 0 },
  };
}

export async function standardsRoutes(fastify: FastifyInstance, options: { fetchImpl?: typeof fetch } = {}) {
  fastify.get('/health', async () => HEALTH_STANDARD_DOCUMENT);

  fastify.get('/health/schema.json', async (_request, reply) => {
    reply.type('application/schema+json');
    return JSON.stringify(HEALTH_STANDARD_SCHEMA);
  });

  fastify.post('/health/validate', { preHandler: fastify.authenticate }, async (request, reply) => {
    const parsed = validateRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    if ('response' in parsed.data) {
      const { httpStatus, contentType, cacheControl, body } = parsed.data.response;
      return validateHealthResponse({ httpStatus, contentType, cacheControl, body });
    }

    let fetched: FetchedResponse;
    try {
      fetched = await fetchForValidation(parsed.data.url, options.fetchImpl ?? fetch);
    } catch (error) {
      return fetchFailureReport(`Could not fetch the URL: ${error instanceof Error ? error.message : 'unknown error'}`);
    }

    if (fetched.tooLarge) {
      const report = validateHealthResponse({ ...fetched, body: '' });
      report.errors = [
        { path: '', rule: 'json-body', message: `Body exceeds ${VALIDATE_MAX_BODY_BYTES / 1024} KB; keep health responses small.` },
      ];
      report.valid = false;
      return report;
    }

    return validateHealthResponse(fetched);
  });
}
