/// <reference types="node" />
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseSSEBuffer, reconnectDelayMs } from './sse';

describe('parseSSEBuffer', () => {
  it('returns complete events and keeps the incomplete tail', () => {
    const result = parseSSEBuffer('data: {"type":"connected"}\n\ndata: {"endpointId":"a"');
    assert.deepEqual(result.events, ['{"type":"connected"}']);
    assert.equal(result.rest, 'data: {"endpointId":"a"');
  });

  it('reassembles an event split across chunks', () => {
    const first = parseSSEBuffer('data: {"a":');
    assert.deepEqual(first.events, []);
    const second = parseSSEBuffer(`${first.rest}1}\n\n`);
    assert.deepEqual(second.events, ['{"a":1}']);
    assert.equal(second.rest, '');
  });

  it('ignores heartbeat comments and non-data fields', () => {
    const result = parseSSEBuffer(': heartbeat\n\nevent: check\nid: 7\nretry: 1000\ndata: x\n\n');
    assert.deepEqual(result.events, ['x']);
  });

  it('joins multi-line data and accepts data without a space', () => {
    assert.deepEqual(parseSSEBuffer('data: a\ndata:b\n\n').events, ['a\nb']);
  });

  it('handles CRLF line endings', () => {
    assert.deepEqual(parseSSEBuffer('data: one\r\n\r\ndata: two\r\n\r\n').events, ['one', 'two']);
  });

  it('returns nothing for an empty buffer', () => {
    assert.deepEqual(parseSSEBuffer(''), { events: [], rest: '' });
  });
});

describe('reconnectDelayMs', () => {
  it('backs off exponentially and caps at a minute', () => {
    assert.equal(reconnectDelayMs(0), 2_000);
    assert.equal(reconnectDelayMs(1), 4_000);
    assert.equal(reconnectDelayMs(3), 16_000);
    assert.equal(reconnectDelayMs(10), 60_000);
    assert.equal(reconnectDelayMs(-1), 2_000);
  });
});
