/// <reference types="node" />
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { deleteConfirmation, isAlreadyDeleted } from './deleteEndpoint';

describe('deleteConfirmation', () => {
  it('names the endpoint in the title', () => {
    assert.equal(deleteConfirmation('Trelivelli').title, 'Delete "Trelivelli"?');
  });

  it('trims the name', () => {
    assert.equal(deleteConfirmation('  API  ').title, 'Delete "API"?');
  });

  it('falls back to a generic label for a blank name', () => {
    assert.equal(deleteConfirmation('   ').title, 'Delete "this endpoint"?');
  });

  it('warns that history is removed and the delete is permanent', () => {
    const { message } = deleteConfirmation('API');
    assert.match(message, /history/);
    assert.match(message, /can't be undone/);
  });
});

describe('isAlreadyDeleted', () => {
  it('treats 404 as already deleted', () => {
    assert.equal(isAlreadyDeleted(404), true);
  });

  it('does not swallow other failures', () => {
    for (const status of [400, 401, 403, 500, 503]) {
      assert.equal(isAlreadyDeleted(status), false);
    }
  });
});
