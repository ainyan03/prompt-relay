import assert from 'node:assert/strict';
import test from 'node:test';
import { makeCollapseId } from './collapse-id.js';

test('keeps short collapse ids readable', () => {
  assert.equal(makeCollapseId('host:main:0.0', 1), 'relay:host:main:0.0:1');
});

test('hashes long collapse ids below the APNs 64-byte limit', () => {
  const target = `host:codex:${'s'.repeat(24)}:${'t'.repeat(24)}:${'d'.repeat(12)}`;
  const id = makeCollapseId(target, 1)!;
  assert.ok(Buffer.byteLength(id, 'utf8') <= 64);
  assert.match(id, /^relay:h:[0-9a-f]{40}:1$/);
  assert.equal(makeCollapseId(target, 1), id);
  assert.notEqual(makeCollapseId(target, 0), id);
});
