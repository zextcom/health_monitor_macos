/**
 * Minimal Server-Sent Events frame parser for a streamed `fetch` body. Pure, so it's unit tested.
 *
 * Only `data:` lines matter for `/api/sse/checks`; comments (`: heartbeat`), `event:`, `id:` and
 * `retry:` lines are ignored. Multiple `data:` lines in one event are joined with "\n", per spec.
 */
export interface SSEParseResult {
  /** The `data` payload of every complete event in the buffer, in order. */
  events: string[];
  /** Trailing incomplete text to prepend to the next chunk. */
  rest: string;
}

export function parseSSEBuffer(buffer: string): SSEParseResult {
  const normalized = buffer.replace(/\r\n?/g, '\n');
  const blocks = normalized.split('\n\n');
  const rest = blocks.pop() ?? '';
  const events: string[] = [];

  for (const block of blocks) {
    const dataLines: string[] = [];
    for (const line of block.split('\n')) {
      if (line.startsWith('data:')) {
        const value = line.slice(5);
        dataLines.push(value.startsWith(' ') ? value.slice(1) : value);
      }
    }
    if (dataLines.length > 0) {
      events.push(dataLines.join('\n'));
    }
  }

  return { events, rest };
}

/** Reconnect delay after the n-th consecutive failure (0-based): 2s, 4s, 8s … capped at 60s. */
export function reconnectDelayMs(attempt: number): number {
  return Math.min(60_000, 2_000 * 2 ** Math.max(0, attempt));
}
