import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { createApp, closeApp, cleanDb, registerAndLogin } from '../helpers.js';

// A real listening server (not inject): the SSE route writes to the raw socket, and the headers
// it actually sends — CORS in particular — are only observable over HTTP.
describe('GET /api/sse/checks', () => {
  let app: FastifyInstance;
  let baseUrl: string;
  let accessToken: string;

  beforeAll(async () => {
    app = await createApp();
    await app.listen({ port: 0, host: '127.0.0.1' });
    const address = app.server.address();
    if (!address || typeof address === 'string') throw new Error('no address');
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  afterAll(async () => {
    await closeApp(app);
  });

  beforeEach(async () => {
    await cleanDb();
    ({ accessToken } = await registerAndLogin(app));
  });

  async function openStream(origin: string) {
    const controller = new AbortController();
    const response = await fetch(`${baseUrl}/api/sse/checks`, {
      headers: { Authorization: `Bearer ${accessToken}`, Origin: origin },
      signal: controller.signal,
    });
    const reader = response.body!.getReader();
    const { value } = await reader.read();
    controller.abort();
    return { response, firstChunk: new TextDecoder().decode(value) };
  }

  it('sends CORS headers to an allowed cross-origin client (Expo web dev)', async () => {
    const { response, firstChunk } = await openStream('http://localhost:19006');
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toBe('text/event-stream');
    expect(response.headers.get('access-control-allow-origin')).toBe('http://localhost:19006');
    expect(firstChunk).toContain('"type":"connected"');
  });

  it('does not allow an unknown origin', async () => {
    const { response } = await openStream('https://evil.example');
    expect(response.headers.get('access-control-allow-origin')).toBeNull();
  });
});
