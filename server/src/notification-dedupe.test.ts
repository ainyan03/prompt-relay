import assert from 'node:assert/strict';
import test from 'node:test';
import { NotificationDedupe } from './notification-dedupe.js';

test('同じroomとevent_idは一度だけ受理する', () => {
  const dedupe = new NotificationDedupe();
  assert.equal(dedupe.accept('room-a', 'goal:1'), true);
  assert.equal(dedupe.accept('room-a', 'goal:1'), false);
});

test('roomまたはevent_idが異なれば受理する', () => {
  const dedupe = new NotificationDedupe();
  assert.equal(dedupe.accept('room-a', 'goal:1'), true);
  assert.equal(dedupe.accept('room-b', 'goal:1'), true);
  assert.equal(dedupe.accept('room-a', 'goal:2'), true);
});

test('event_idが無い旧クライアントは常に受理する', () => {
  const dedupe = new NotificationDedupe();
  assert.equal(dedupe.accept('room-a', undefined), true);
  assert.equal(dedupe.accept('room-a', undefined), true);
});

test('保持上限を超えた古いevent_idは解放する', () => {
  const dedupe = new NotificationDedupe();
  assert.equal(dedupe.accept('room-a', 'event-0'), true);
  for (let i = 1; i <= 4096; i++) {
    assert.equal(dedupe.accept('room-a', `event-${i}`), true);
  }
  assert.equal(dedupe.accept('room-a', 'event-0'), true);
});
