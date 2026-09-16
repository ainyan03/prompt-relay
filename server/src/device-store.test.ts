import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// DEVICE_STORE_PATH はモジュール読み込み時に評価されるため、import より前に環境変数を置く
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prompt-relay-store-'));
const storePath = path.join(dir, 'devices.json');
process.env.DEVICE_STORE_PATH = storePath;

const store = await import('./store.js');

test('device registrations are written to DEVICE_STORE_PATH and restored by loadDevices', async () => {
  store.registerDevice('room-key-12345678', 'tok-ios', { platform: 'ios' });
  store.registerDevice('room-key-12345678', 'tok-watch', { platform: 'watchos', sounds: { permission_request: 'chime.caf' } });
  store.registerWebPush('room-key-12345678', { endpoint: 'https://push.example/abc', keys: { p256dh: 'p', auth: 'a' } });

  // 書き込みは 100ms まとめ
  await new Promise(r => setTimeout(r, 250));
  assert.ok(fs.existsSync(storePath), 'store file should exist');
  const saved = JSON.parse(fs.readFileSync(storePath, 'utf8'));
  assert.equal(saved.version, 1);
  assert.equal(saved.rooms['room-key-12345678'].apnsDevices.length, 2);
  assert.equal(saved.rooms['room-key-12345678'].webPushDevices.length, 1);
  assert.equal((fs.statSync(storePath).mode & 0o777), 0o600);

  // メモリ側を空にしてから読み戻す
  store.removeDevice('room-key-12345678', 'tok-ios');
  store.removeDevice('room-key-12345678', 'tok-watch');
  store.removeWebPush('room-key-12345678', 'https://push.example/abc');
  await new Promise(r => setTimeout(r, 250));
  assert.equal(store.getDeviceTokens('room-key-12345678').length, 0);

  // 先ほどの内容を書き戻して復元
  fs.writeFileSync(storePath, JSON.stringify(saved));
  const restored = store.loadDevices();
  assert.equal(restored, 3);
  const devices = store.getDeviceTokens('room-key-12345678');
  assert.deepEqual(devices.map(d => d.token).sort(), ['tok-ios', 'tok-watch']);
  assert.equal(devices.find(d => d.token === 'tok-watch')?.sounds?.permission_request, 'chime.caf');
  assert.equal(store.getWebPushSubscriptions('room-key-12345678').length, 1);
});

test('loadDevices ignores a missing or corrupt file', () => {
  fs.writeFileSync(storePath, '{not json');
  assert.equal(store.loadDevices(), 0);
  fs.rmSync(storePath);
  assert.equal(store.loadDevices(), 0);
});
