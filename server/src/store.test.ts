import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveSendKey } from './store.js';
import type { PermissionRequest } from './store.js';

test('allow_all resolves common session-wide choices', () => {
  const base: PermissionRequest = {
    id: 'request-1',
    tool_name: 'Edit',
    tool_input: {},
    message: 'Allow edit?',
    choices: [],
    created_at: 0,
    expires_at: 1,
  };

  for (const text of ['Yes, allow all edits', 'Yes, allow edits during this session']) {
    const request = { ...base, choices: [{ number: 1, text: 'Yes' }, { number: 2, text }, { number: 3, text: 'No' }] };
    assert.equal(resolveSendKey(request, 'allow_all'), '2');
  }
});
