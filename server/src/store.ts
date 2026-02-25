export interface Choice {
  number: number;
  text: string;
}

export interface PermissionRequest {
  id: string;
  tool_name: string;
  tool_input: Record<string, unknown>;
  message: string;
  choices: Choice[];
  tmux_target?: string;
  hostname?: string;
  created_at: number;
  response?: 'allow' | 'deny' | 'cancelled' | 'expired';
  responded_at?: number;
  send_key?: string;
}

const PENDING_TIMEOUT_MS = 120 * 1000; // 2分でリクエスト期限切れ（フックの TIMEOUT と一致させる）

// --- マルチデバイス管理 ---

export interface DeviceEntry {
  token: string;
  registeredAt: number;
  lastPushAt: number | null;
}

export interface WebPushSubscription {
  endpoint: string;
  keys: {
    p256dh: string;
    auth: string;
  };
}

export interface WebPushEntry {
  subscription: WebPushSubscription;
  registeredAt: number;
  lastPushAt: number | null;
}

// --- ルームベースストレージ ---

interface RoomState {
  requests: Map<string, PermissionRequest>;
  apnsDevices: DeviceEntry[];
  webPushDevices: WebPushEntry[];
  lastActivityAt: number;
  // collapse-id 単調増加カウンタ（tmux_target → 連番、毎回ユニークな collapse-id を生成）
  collapseCounter: Map<string, number>;
}

const MAX_ROOMS = Math.max(1, parseInt(process.env.MAX_ROOMS || '10', 10));
const MAX_DEVICES = Math.max(1, parseInt(process.env.MAX_DEVICES || '4', 10));
const rooms = new Map<string, RoomState>();

function createRoomState(): RoomState {
  return {
    requests: new Map(),
    apnsDevices: [],
    webPushDevices: [],
    lastActivityAt: Date.now(),
    collapseCounter: new Map(),
  };
}

function getOrCreateRoom(roomKey: string): RoomState {
  let room = rooms.get(roomKey);
  if (room) {
    room.lastActivityAt = Date.now();
    return room;
  }
  // MAX_ROOMS 超過時は LRU 淘汰
  if (rooms.size >= MAX_ROOMS) {
    evictOldestRoom();
  }
  room = createRoomState();
  rooms.set(roomKey, room);
  return room;
}

function getRoom(roomKey: string): RoomState | undefined {
  const room = rooms.get(roomKey);
  if (room) room.lastActivityAt = Date.now();
  return room;
}

function evictOldestRoom(): void {
  let oldestKey: string | null = null;
  let oldestTime = Infinity;
  for (const [key, room] of rooms) {
    if (room.lastActivityAt < oldestTime) {
      oldestTime = room.lastActivityAt;
      oldestKey = key;
    }
  }
  if (oldestKey) {
    rooms.delete(oldestKey);
    console.log(`[store] Room evicted (LRU): ${oldestKey.substring(0, 8)}...`);
  }
}

/** 配列内で getTime が最小の要素を1つ削除 */
function evictOldest<T>(arr: T[], getTime: (item: T) => number): void {
  if (arr.length === 0) return;
  let minIdx = 0;
  let minTime = getTime(arr[0]);
  for (let i = 1; i < arr.length; i++) {
    const t = getTime(arr[i]);
    if (t < minTime) {
      minTime = t;
      minIdx = i;
    }
  }
  arr.splice(minIdx, 1);
}

// --- APNs デバイス管理 ---

export function registerDevice(roomKey: string, token: string): void {
  // 他ルームから同一トークンを削除（API Key 変更時の重複防止）
  for (const [key, room] of rooms) {
    if (key === roomKey) continue;
    const idx = room.apnsDevices.findIndex(d => d.token === token);
    if (idx !== -1) {
      room.apnsDevices.splice(idx, 1);
      console.log(`[store] APNs token moved from room ${key.substring(0, 8)}... to ${roomKey.substring(0, 8)}...`);
    }
  }

  const room = getOrCreateRoom(roomKey);
  const existing = room.apnsDevices.find(d => d.token === token);
  if (existing) {
    existing.registeredAt = Date.now();
    return;
  }
  if (room.apnsDevices.length >= MAX_DEVICES) {
    evictOldest(room.apnsDevices, d => d.lastPushAt ?? d.registeredAt);
  }
  room.apnsDevices.push({ token, registeredAt: Date.now(), lastPushAt: null });
}

export function getDeviceTokens(roomKey: string): DeviceEntry[] {
  return getRoom(roomKey)?.apnsDevices ?? [];
}

export function removeDevice(roomKey: string, token: string): void {
  const room = getRoom(roomKey);
  if (!room) return;
  const idx = room.apnsDevices.findIndex(d => d.token === token);
  if (idx !== -1) room.apnsDevices.splice(idx, 1);
}

export function touchDevice(roomKey: string, token: string): void {
  const room = getRoom(roomKey);
  if (!room) return;
  const entry = room.apnsDevices.find(d => d.token === token);
  if (entry) entry.lastPushAt = Date.now();
}

// --- Web Push デバイス管理 ---

export function registerWebPush(roomKey: string, sub: WebPushSubscription): void {
  // 他ルームから同一エンドポイントを削除（API Key 変更時の重複防止）
  for (const [key, room] of rooms) {
    if (key === roomKey) continue;
    const idx = room.webPushDevices.findIndex(d => d.subscription.endpoint === sub.endpoint);
    if (idx !== -1) {
      room.webPushDevices.splice(idx, 1);
      console.log(`[store] Web Push endpoint moved from room ${key.substring(0, 8)}... to ${roomKey.substring(0, 8)}...`);
    }
  }

  const room = getOrCreateRoom(roomKey);
  const existing = room.webPushDevices.find(d => d.subscription.endpoint === sub.endpoint);
  if (existing) {
    existing.subscription = sub;
    existing.registeredAt = Date.now();
    return;
  }
  if (room.webPushDevices.length >= MAX_DEVICES) {
    evictOldest(room.webPushDevices, d => d.lastPushAt ?? d.registeredAt);
  }
  room.webPushDevices.push({ subscription: sub, registeredAt: Date.now(), lastPushAt: null });
}

export function getWebPushSubscriptions(roomKey: string): WebPushEntry[] {
  return getRoom(roomKey)?.webPushDevices ?? [];
}

export function removeWebPush(roomKey: string, endpoint: string): void {
  const room = getRoom(roomKey);
  if (!room) return;
  const idx = room.webPushDevices.findIndex(d => d.subscription.endpoint === endpoint);
  if (idx !== -1) room.webPushDevices.splice(idx, 1);
}

export function touchWebPush(roomKey: string, endpoint: string): void {
  const room = getRoom(roomKey);
  if (!room) return;
  const entry = room.webPushDevices.find(d => d.subscription.endpoint === endpoint);
  if (entry) entry.lastPushAt = Date.now();
}

// --- リクエスト管理 ---

// 同じ tmux ペインの未応答リクエストをキャンセル（キャンセルした ID を返す）
function cancelPendingByTarget(requestsMap: Map<string, PermissionRequest>, tmux_target: string): string[] {
  const cancelledIds: string[] = [];
  for (const req of requestsMap.values()) {
    if (req.tmux_target === tmux_target && !req.response) {
      req.response = 'cancelled';
      req.responded_at = Date.now();
      cancelledIds.push(req.id);
    }
  }
  return cancelledIds;
}

export function createRequest(roomKey: string, id: string, tool_name: string, tool_input: Record<string, unknown>, message: string, choices: Choice[] = [], tmux_target?: string, hostname?: string): { request: PermissionRequest; cancelledIds: string[]; collapseSuffix: number } {
  const room = getOrCreateRoom(roomKey);

  // 同じ tmux ペインからの未応答リクエストをキャンセル
  let cancelledIds: string[] = [];
  if (tmux_target) {
    cancelledIds = cancelPendingByTarget(room.requests, tmux_target);
  }

  // collapse-id 単調増加: 毎回ユニークな値を使い、APNs の「更新」扱いによる配信遅延を回避
  let collapseSuffix = 0;
  if (tmux_target) {
    const prev = room.collapseCounter.get(tmux_target) ?? 0;
    collapseSuffix = prev + 1;
    room.collapseCounter.set(tmux_target, collapseSuffix);
  }

  const req: PermissionRequest = {
    id,
    tool_name,
    tool_input,
    message,
    choices,
    tmux_target,
    hostname,
    created_at: Date.now(),
  };
  room.requests.set(id, req);
  return { request: req, cancelledIds, collapseSuffix };
}

// choices から応答に対応するキーを決定
export function resolveSendKey(req: PermissionRequest, response: 'allow' | 'deny' | 'allow_all'): string {
  const choices = req.choices;
  if (!choices.length) {
    // choices がない場合のフォールバック
    return response === 'deny' ? '3' : '1';
  }

  if (response === 'allow') {
    // 最初の選択肢 (Yes)
    return String(choices[0].number);
  }

  if (response === 'allow_all') {
    // "don't ask again" / "省略" を含む選択肢を探す
    const alwaysChoice = choices.find(c =>
      /don.t ask again|always|省略/i.test(c.text)
    );
    if (alwaysChoice) {
      return String(alwaysChoice.number);
    }
    // 見つからなければ最初の選択肢
    return String(choices[0].number);
  }

  // deny: 最後の選択肢 (No)
  return String(choices[choices.length - 1].number);
}

// 未応答のまま PENDING_TIMEOUT_MS を超えたリクエストを expired にする
function expireIfStale(req: PermissionRequest): void {
  if (!req.response && Date.now() - req.created_at > PENDING_TIMEOUT_MS) {
    req.response = 'expired';
    req.responded_at = Date.now();
  }
}

export function getRequest(roomKey: string, id: string): PermissionRequest | undefined {
  const room = getRoom(roomKey);
  if (!room) return undefined;
  const req = room.requests.get(id);
  if (req) expireIfStale(req);
  return req;
}

export function respondToRequest(roomKey: string, id: string, response: 'allow' | 'deny'): boolean {
  const room = getRoom(roomKey);
  if (!room) return false;
  const req = room.requests.get(id);
  if (!req || req.response) return false;
  req.response = response;
  req.responded_at = Date.now();
  return true;
}

export function cancelRequest(roomKey: string, id: string): boolean {
  const room = getRoom(roomKey);
  if (!room) return false;
  const req = room.requests.get(id);
  if (!req || req.response) return false;
  req.response = 'cancelled';
  req.responded_at = Date.now();
  return true;
}

// 指定 tmux_target に未応答の permission request があるか
export function hasPendingRequest(roomKey: string, tmuxTarget: string): boolean {
  const room = getRoom(roomKey);
  if (!room) return false;
  for (const req of room.requests.values()) {
    if (req.tmux_target === tmuxTarget && !req.response) {
      return true;
    }
  }
  return false;
}

// 全リクエスト一覧（新しい順）
export function getAllRequests(roomKey: string): PermissionRequest[] {
  const room = getRoom(roomKey);
  if (!room) return [];
  const all = Array.from(room.requests.values());
  all.forEach(expireIfStale);
  return all.sort((a, b) => b.created_at - a.created_at);
}

// 古いリクエストを定期的にクリーンアップ（5分以上前のもの）
// 空ルーム（リクエスト 0・デバイス 0）かつ lastActivityAt が 1 時間以上前のルームを自動削除
export function cleanup(): void {
  const requestCutoff = Date.now() - 5 * 60 * 1000;
  const roomCutoff = Date.now() - 60 * 60 * 1000;

  for (const [roomKey, room] of rooms) {
    // リクエストのクリーンアップ
    for (const [id, req] of room.requests) {
      if (req.created_at < requestCutoff) {
        room.requests.delete(id);
      }
    }

    // 空ルームの自動削除
    if (
      room.requests.size === 0 &&
      room.apnsDevices.length === 0 &&
      room.webPushDevices.length === 0 &&
      room.lastActivityAt < roomCutoff
    ) {
      rooms.delete(roomKey);
      console.log(`[store] Empty room removed: ${roomKey.substring(0, 8)}...`);
    }
  }
}
