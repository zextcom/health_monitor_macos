/// <reference types="node" />
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { buildRequestHeaders } from './request';

describe('buildRequestHeaders', () => {
  it('declares JSON when the request has a body', () => {
    assert.deepEqual(buildRequestHeaders(true), { 'Content-Type': 'application/json' });
  });

  it('sends no Content-Type for a body-less request (DELETE, pause, resume)', () => {
    assert.deepEqual(buildRequestHeaders(false), {});
  });

  it('keeps caller-supplied headers in both cases', () => {
    assert.deepEqual(buildRequestHeaders(false, { 'X-Test': '1' }), { 'X-Test': '1' });
    assert.deepEqual(buildRequestHeaders(true, { 'X-Test': '1' }), {
      'Content-Type': 'application/json',
      'X-Test': '1',
    });
  });

  it('lets a caller override Content-Type', () => {
    assert.deepEqual(buildRequestHeaders(true, { 'Content-Type': 'text/plain' }), {
      'Content-Type': 'text/plain',
    });
  });
});
