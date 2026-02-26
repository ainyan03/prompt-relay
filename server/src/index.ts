import express from 'express';
import https from 'https';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import type { Request, Response, NextFunction } from 'express';
import { randomBytes } from 'crypto';
import { config } from 'dotenv';
import { createRequest, getRequest, respondToRequest, cancelRequest, resolveSendKey, registerDevice, getDeviceTokens, removeDevice, touchDevice, registerWebPush, getWebPushSubscriptions, removeWebPush, touchWebPush, getAllRequests, cleanup, hasPendingRequest, serializeRequest, PENDING_TIMEOUT_MS } from './store.js';
import { sendNotification, sendSilentNotification, isConfigured, isApnsBadDevice } from './apns.js';
import { initWebPush, sendWebPushNotification, isConfigured as isWebPushConfigured, getVapidPublicKey } from './web-push.js';
import { ensureCerts, getLanIPs, isSanCovered, regenerateCert, dynamicSanCount } from './certs.js';
import { setupWebSocket, broadcast } from './ws.js';

config();
initWebPush();

declare global {
  namespace Express {
    interface Request {
      roomKey?: string;
    }
  }
}

const app = express();

const PORT = parseInt(process.env.PORT || '3939');

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const publicDir = path.resolve(__dirname, '..', 'public');

// 静的ファイル配信（認証の前に配置）
app.use(express.static(publicDir));

// Host ヘッダー検出 — 未知のホスト名でアクセスされたら HTTPS 証明書を再生成
let httpsServer: https.Server | null = null;

// 証明書再生成の保護パラメータ
let lastCertRegenTime = 0;
const CERT_REGEN_DEBOUNCE_MS = 10_000;
const MAX_DYNAMIC_SANS = 50;
const VALID_HOSTNAME_RE = /^[a-zA-Z0-9._-]+$/;

app.use((req: Request, _res: Response, next: NextFunction) => {
  const host = req.hostname;
  if (host && !isSanCovered(host)) {
    // ホスト名検証: RFC 準拠パターンのみ許可
    if (!VALID_HOSTNAME_RE.test(host)) {
      next();
      return;
    }
    // SAN 上限チェック: 動的 SAN が上限を超えたら追加しない
    if (dynamicSanCount() >= MAX_DYNAMIC_SANS) {
      console.log(`[certs] Dynamic SAN limit (${MAX_DYNAMIC_SANS}) reached, skipping: ${host}`);
      next();
      return;
    }
    // debounce: 最後の再生成から一定時間以内はスキップ
    const now = Date.now();
    if (now - lastCertRegenTime < CERT_REGEN_DEBOUNCE_MS) {
      next();
      return;
    }
    console.log(`[certs] New hostname detected from request: ${host}`);
    const result = regenerateCert([host]);
    lastCertRegenTime = Date.now();
    if (result && httpsServer) {
      httpsServer.setSecureContext({
        cert: fs.readFileSync(result.cert),
        key: fs.readFileSync(result.key),
      });
      console.log(`[certs] HTTPS certificate hot-swapped, now includes: ${host}`);
    }
  }
  next();
});

// ヘルスチェック（認証不要、Docker ヘルスチェック用）
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', request_timeout_ms: PENDING_TIMEOUT_MS });
});

app.use(express.json());

// CA 証明書ダウンロード（認証不要 — Android への CA インストール用）
app.get('/PromptRelay-CA.pem', (_req, res) => {
  const caPath = path.resolve('certs', 'PromptRelay-CA.pem');
  if (!fs.existsSync(caPath)) {
    res.status(404).json({ error: 'CA certificate not found' });
    return;
  }
  res.setHeader('Content-Type', 'application/x-pem-file');
  res.setHeader('Content-Disposition', 'attachment; filename="PromptRelay-CA.pem"');
  res.sendFile(caPath);
});

// VAPID 公開鍵取得（認証の前に配置 — SW の subscribe に必要）
app.get('/vapid-public-key', (_req, res) => {
  const key = getVapidPublicKey();
  if (!key) {
    res.status(404).json({ error: 'VAPID not configured' });
    return;
  }
  res.json({ key });
});

// ルームキー抽出ミドルウェア: Bearer トークンをルームキーとして使用
const MIN_KEY_LENGTH = 8;
const MAX_KEY_LENGTH = 128;

app.use((req: Request, res: Response, next: NextFunction) => {
  const auth = req.headers.authorization || '';
  const match = auth.match(/^Bearer\s+(.+)$/i);
  const key = match?.[1] || '';
  if (!key) {
    res.status(401).json({ error: 'unauthorized' });
  } else if (key.length < MIN_KEY_LENGTH || key.length > MAX_KEY_LENGTH) {
    res.status(401).json({ error: `Room key must be ${MIN_KEY_LENGTH}-${MAX_KEY_LENGTH} characters` });
  } else {
    req.roomKey = key;
    next();
  }
});

// デバイストークン登録（APNs）
app.post('/register', (req, res) => {
  const { token } = req.body;
  if (!token || typeof token !== 'string') {
    res.status(400).json({ error: 'token is required' });
    return;
  }
  registerDevice(req.roomKey!, token);
  console.log(`[register] Device token registered: ${token.substring(0, 16)}... (total: ${getDeviceTokens(req.roomKey!).length})`);
  res.json({ ok: true });
});

// Web Push subscription 登録
app.post('/register-web', (req, res) => {
  const { subscription } = req.body;
  if (!subscription || !subscription.endpoint || !subscription.keys?.p256dh || !subscription.keys?.auth) {
    res.status(400).json({ error: 'valid subscription is required' });
    return;
  }
  registerWebPush(req.roomKey!, {
    endpoint: subscription.endpoint,
    keys: {
      p256dh: subscription.keys.p256dh,
      auth: subscription.keys.auth,
    },
  });
  console.log(`[register-web] Web Push subscription registered: ${subscription.endpoint.substring(0, 48)}... (total: ${getWebPushSubscriptions(req.roomKey!).length})`);
  res.json({ ok: true });
});

// マルチデバイス送信ヘルパー

interface ApnsNotificationPayload {
  title: string;
  subtitle?: string;
  body: string;
  category?: string;
  collapseId?: string;
  data?: Record<string, unknown>;
}

async function trySendApnsNotification(roomKey: string, payload: ApnsNotificationPayload): Promise<void> {
  const devices = getDeviceTokens(roomKey);
  if (devices.length === 0 || !isConfigured()) return;
  const targets = devices.map(d => d.token);

  const results = await Promise.allSettled(
    targets.map(token => sendNotification(token, payload))
  );
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    const token = targets[i];
    if (r.status === 'fulfilled') {
      touchDevice(roomKey, token);
      console.log(`[apns] Notification sent to ${token.substring(0, 16)}...`);
    } else {
      if (isApnsBadDevice(r.reason)) {
        console.log(`[apns] Bad device token, removing: ${token.substring(0, 16)}...`);
        removeDevice(roomKey, token);
      } else {
        console.error(`[apns] Failed to send notification:`, r.reason);
      }
    }
  }
}

async function trySendApnsSilent(roomKey: string, data: Record<string, unknown>): Promise<void> {
  const devices = getDeviceTokens(roomKey);
  if (devices.length === 0 || !isConfigured()) return;
  const targets = devices.map(d => d.token);

  const results = await Promise.allSettled(
    targets.map(token => sendSilentNotification(token, data))
  );
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    const token = targets[i];
    if (r.status === 'fulfilled') {
      touchDevice(roomKey, token);
    } else {
      if (isApnsBadDevice(r.reason)) {
        console.log(`[apns] Bad device token, removing: ${token.substring(0, 16)}...`);
        removeDevice(roomKey, token);
      } else {
        console.error(`[apns] Silent push failed:`, r.reason);
      }
    }
  }
}

async function trySendWebPushAll(roomKey: string, payload: { title: string; subtitle?: string; body: string; tag?: string; data?: Record<string, unknown> }): Promise<void> {
  const entries = getWebPushSubscriptions(roomKey);
  if (entries.length === 0 || !isWebPushConfigured()) return;
  const targets = entries.map(e => e.subscription);

  const results = await Promise.allSettled(
    targets.map(subscription => sendWebPushNotification(subscription, payload))
  );
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    const endpoint = targets[i].endpoint;
    if (r.status === 'fulfilled') {
      touchWebPush(roomKey, endpoint);
      console.log(`[web-push] Notification sent to ${endpoint.substring(0, 48)}...`);
    } else {
      const err = r.reason as any;
      if (err?.statusCode === 410 || err?.statusCode === 404) {
        console.log(`[web-push] Subscription expired (${err.statusCode}), removing`);
        removeWebPush(roomKey, endpoint);
      } else {
        console.error(`[web-push] Failed to send notification:`, err);
      }
    }
  }
}

// デバイストークン解除（APNs）
app.post('/unregister', (req, res) => {
  const { token } = req.body;
  if (!token || typeof token !== 'string') {
    res.status(400).json({ error: 'token is required' });
    return;
  }
  removeDevice(req.roomKey!, token);
  console.log(`[unregister] Device token removed: ${token.substring(0, 16)}... (remaining: ${getDeviceTokens(req.roomKey!).length})`);
  res.json({ ok: true });
});

// Web Push subscription 解除
app.post('/unregister-web', (req, res) => {
  const { endpoint } = req.body;
  if (!endpoint || typeof endpoint !== 'string') {
    res.status(400).json({ error: 'endpoint is required' });
    return;
  }
  removeWebPush(req.roomKey!, endpoint);
  console.log(`[unregister-web] Web Push subscription removed: ${endpoint.substring(0, 48)}...`);
  res.json({ ok: true });
});

// 権限リクエスト受信（フックスクリプトから）
app.post('/permission-request', async (req, res) => {
  const roomKey = req.roomKey!;
  const { tool_name, tool_input, message, header, description, prompt_question, choices, has_tmux, tmux_target, hostname, timeout } = req.body;
  const id = randomBytes(4).toString('hex');

  const toolDisplay = tool_name || 'Unknown';
  // header があればそちらを subtitle に使用（例: "Bash command", "Edit file"）
  const subtitleText = header || toolDisplay;

  // アプリ用の詳細テキストを構築
  let detailText: string;
  if (description) {
    detailText = description;
  } else if (tool_input?.command) {
    detailText = `$ ${tool_input.command}`;
  } else if (tool_input?.file_path) {
    detailText = tool_input.file_path as string;
  } else {
    detailText = message || `${toolDisplay} の実行を許可しますか？`;
  }

  // prompt_question があれば detailText に追加（アプリ用）
  if (prompt_question) {
    detailText += `\n${prompt_question}`;
  }

  // 非tmux の場合、注記を追加
  if (has_tmux === false) {
    detailText += '\n⚠ tmux未経由のためWatch応答不可';
  }

  // 通知用テキスト: prompt_question があればそれを優先、なければ detailText の1行目
  const notifyLine = prompt_question || detailText.split('\n')[0];
  // 57文字で切断: APNs の subtitle 表示幅制限（60文字）に収めるため末尾に「…」を付加
  const notifyBody = notifyLine.length > 60 ? notifyLine.substring(0, 57) + '…' : notifyLine;

  // フックから送信された timeout（秒）を ms に変換
  const timeoutMs = typeof timeout === 'number' && timeout > 0 ? timeout * 1000 : undefined;

  const { request, cancelledIds, collapseSlot } = createRequest(roomKey, id, toolDisplay, tool_input || {}, detailText, choices || [], tmux_target, hostname, timeoutMs);
  console.log(`[permission] New request: ${id} - ${subtitleText}: ${detailText.replace(/\n/g, ' | ')} [tmux_target=${tmux_target || '(none)'}]`);
  if (choices?.length) {
    console.log(`[permission]   choices: ${choices.map((c: { number: number; text: string }) => `${c.number}.${c.text}`).join(' | ')}`);
  }

  // レスポンスを即返す（フックのブロックを防ぐ）
  res.json({ id, tool_name: toolDisplay, message: detailText, expires_at: request.expires_at });

  // 同一 tmux_target の旧リクエストがキャンセルされた場合、通知を消去
  for (const cid of cancelledIds) {
    trySendApnsSilent(roomKey, { type: 'dismiss', request_id: cid });
  }

  // collapse-id: 2スロット交互（最大2件、直前の通知は置換しない）
  const collapseId = tmux_target ? `relay:${tmux_target}:${collapseSlot}` : undefined;
  if (collapseId) {
    console.log(`[permission]   collapse-id: ${collapseId}`);
  }

  // WebSocket クライアントにブロードキャスト
  broadcast(roomKey);

  const notifTitle = hostname ? `承認待ち [${hostname}]` : '承認待ち';

  // 通知カテゴリ: tmux 経由でない場合はアクションボタンなしの通知
  const category = has_tmux !== false ? 'PERMISSION_REQUEST' : undefined;

  // APNs でプッシュ通知送信（非同期、fire-and-forget）
  trySendApnsNotification(roomKey, {
    title: notifTitle,
    subtitle: subtitleText,
    body: notifyBody,
    ...(category ? { category } : {}),
    collapseId,
    data: {
      request_id: id,
      type: 'permission_request',
      ...(tmux_target ? { tmux_target } : {}),
      ...(choices?.length ? { choices } : {}),
    },
  });

  // Web Push 送信（fire-and-forget）
  trySendWebPushAll(roomKey, {
    title: notifTitle,
    subtitle: subtitleText,
    body: notifyBody,
    tag: collapseId,
    data: {
      request_id: id,
      type: 'permission_request',
      ...(choices?.length ? { choices } : {}),
    },
  });
});

// フックスクリプトからのポーリング
app.get('/permission-request/:id/response', (req, res) => {
  const request = getRequest(req.roomKey!, req.params.id);
  if (!request) {
    res.status(404).json({ error: 'not found' });
    return;
  }
  res.json({
    id: request.id,
    response: request.response || null,
    responded_at: request.responded_at || null,
    send_key: request.send_key || null,
  });
});

// iOS アプリ / PWA からの応答
app.post('/permission-request/:id/respond', (req, res) => {
  const roomKey = req.roomKey!;
  const { response, choice, source } = req.body;

  const request = getRequest(roomKey, req.params.id);
  if (!request) {
    res.status(404).json({ error: 'not found' });
    return;
  }

  let sendKey: string;
  let actualResponse: 'allow' | 'deny';

  if (typeof choice === 'number') {
    // 選択肢番号ベース（動的ボタンから）
    sendKey = String(choice);
    // Question（AskUserQuestion）は全選択肢が等価な回答なので常に allow
    // 権限プロンプトは最後の選択肢 = deny（No）、それ以外 = allow
    if (request.tool_name === 'Question') {
      actualResponse = 'allow';
    } else {
      const isLast = request.choices.length > 0 && choice === request.choices[request.choices.length - 1].number;
      actualResponse = isLast ? 'deny' : 'allow';
    }
  } else if (response === 'allow' || response === 'deny' || response === 'allow_all') {
    // レガシー応答（RequestsView 等から）
    sendKey = resolveSendKey(request, response);
    actualResponse = response === 'allow_all' ? 'allow' : response;
  } else {
    res.status(400).json({ error: 'response or choice is required' });
    return;
  }

  const ok = respondToRequest(roomKey, req.params.id, actualResponse);
  if (!ok) {
    res.status(404).json({ error: 'already responded' });
    return;
  }

  // send_key をリクエストに保存（ポーリング時に返す）
  request.send_key = sendKey;

  const src = source || 'unknown';
  console.log(`[respond] ${req.params.id}: choice=${choice ?? response} → send_key: ${sendKey} (${actualResponse}) [source=${src}]`);
  res.json({ ok: true });

  // WebSocket クライアントにブロードキャスト
  broadcast(roomKey);

  // サイレントプッシュで通知をクリア
  trySendApnsSilent(roomKey, { type: 'dismiss', request_id: req.params.id });
});

// フックスクリプトからのキャンセル（tmux 側で手動回答された場合）
app.post('/permission-request/:id/cancel', (req, res) => {
  const roomKey = req.roomKey!;
  const ok = cancelRequest(roomKey, req.params.id);
  if (!ok) {
    res.status(404).json({ error: 'not found or already responded' });
    return;
  }
  console.log(`[cancel] ${req.params.id}: manually answered in tmux`);
  res.json({ ok: true });

  // WebSocket クライアントにブロードキャスト
  broadcast(roomKey);

  // サイレントプッシュで通知をクリア
  trySendApnsSilent(roomKey, { type: 'dismiss', request_id: req.params.id });
});


// リクエスト一覧（iOS アプリ / PWA 用）
app.get('/permission-requests', (req, res) => {
  const all = getAllRequests(req.roomKey!);
  res.json(all.map(serializeRequest));
});

// 単純な通知送信（idle_prompt 等）
app.post('/notify', async (req, res) => {
  const roomKey = req.roomKey!;
  const { title, message, hostname, tmux_target } = req.body;
  console.log(`[notify] ${title || 'Claude Code'}${hostname ? ` [${hostname}]` : ''}: ${message || '(no message)'}`);

  // 同一 tmux_target に未応答の permission request がある場合はプッシュ通知をスキップ
  // （collapse-id が共通のため、ボタンなし通知でボタンあり通知が上書きされるのを防ぐ）
  if (tmux_target && hasPendingRequest(roomKey, tmux_target)) {
    console.log(`[notify] Skipped push: pending permission request for ${tmux_target}`);
    res.json({ ok: true });
    return;
  }

  const notifTitle = (title || 'Claude Code') + (hostname ? ` [${hostname}]` : '');
  const notifBody = message || '処理が完了しました';

  // collapse-id: 同一ターミナルの通知を自動上書き（承認リクエストと共有）
  const collapseId = tmux_target ? `relay:${tmux_target}` : undefined;

  // レスポンスを先に返す
  res.json({ ok: true });

  // APNs + Web Push 送信（fire-and-forget）
  trySendApnsNotification(roomKey, { title: notifTitle, body: notifBody, collapseId });
  trySendWebPushAll(roomKey, { title: notifTitle, body: notifBody, tag: collapseId });
});

// 定期クリーンアップ
setInterval(cleanup, 60 * 1000);

// HTTP サーバ起動
const httpServer = app.listen(PORT, '0.0.0.0', () => {
  console.log(`[server] HTTP  : http://0.0.0.0:${PORT} (built: ${new Date().toISOString()})`);
  console.log(`[server] APNs configured: ${isConfigured()}`);
  console.log(`[server] Web Push configured: ${isWebPushConfigured()}`);
});

// HTTPS サーバ起動（証明書があれば）
const HTTPS_PORT = parseInt(process.env.HTTPS_PORT || String(PORT + 1));
const certPaths = ensureCerts();

if (certPaths) {
  try {
    const httpsOptions = {
      cert: fs.readFileSync(certPaths.cert),
      key: fs.readFileSync(certPaths.key),
    };
    httpsServer = https.createServer(httpsOptions, app);
    httpsServer.listen(HTTPS_PORT, '0.0.0.0', () => {
      console.log(`[server] HTTPS : https://0.0.0.0:${HTTPS_PORT}`);
      const lanIPs = getLanIPs();
      if (lanIPs.length > 0) {
        console.log('[server]');
        console.log('[server] --- Android / LAN からの利用 ---');
        for (const ip of lanIPs) {
          console.log(`[server]   PWA  : https://${ip}:${HTTPS_PORT}/`);
        }
        console.log(`[server]   CA証明書DL : http://<LAN IP>:${PORT}/PromptRelay-CA.pem`);
        console.log('[server]   → Android: 設定 → セキュリティ → 証明書のインストール → CA証明書');
      }
    });
  } catch (err) {
    console.error('[server] HTTPS startup failed:', err);
  }
}

// WebSocket サーバ初期化（HTTP/HTTPS 両方にアタッチ）
setupWebSocket(httpServer, httpsServer);

// Graceful shutdown
function shutdown(signal: string) {
  console.log(`[server] ${signal} received, shutting down...`);
  httpServer.close();
  httpsServer?.close();
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
