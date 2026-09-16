import { readFileSync } from 'fs';
import http2 from 'http2';
import jwt from 'jsonwebtoken';

export class ApnsError extends Error {
  statusCode: number;
  reason: string;

  constructor(statusCode: number, reason: string) {
    super(`APNs error ${statusCode}: ${reason}`);
    this.name = 'ApnsError';
    this.statusCode = statusCode;
    this.reason = reason;
  }
}

export function isApnsBadDevice(err: unknown): boolean {
  if (!(err instanceof ApnsError)) return false;
  return err.statusCode === 410 || (err.statusCode === 400 && err.reason === 'BadDeviceToken');
}

let cachedToken: { token: string; issuedAt: number } | null = null;
let cachedClient: { client: http2.ClientHttp2Session; host: string } | null = null;

// 接続レベルの障害（stale 接続の使用時に発生）。HTTP 応答が返った場合 (ApnsError) は対象外
const RETRYABLE_TRANSPORT_CODES = new Set([
  'ECONNRESET',
  'EPIPE',
  'ETIMEDOUT',
  'ECONNREFUSED',
  'ERR_HTTP2_INVALID_SESSION',
  'ERR_HTTP2_GOAWAY_SESSION',
  'ERR_HTTP2_STREAM_CANCEL',
]);

function isRetryableTransportError(err: unknown): boolean {
  if (err instanceof ApnsError) return false;
  const code = (err as NodeJS.ErrnoException | undefined)?.code;
  return typeof code === 'string' && RETRYABLE_TRANSPORT_CODES.has(code);
}

function destroyCachedClient(): void {
  if (cachedClient) {
    cachedClient.client.destroy();
    cachedClient = null;
  }
}

function getClient(): http2.ClientHttp2Session {
  const isProduction = process.env.APNS_PRODUCTION === 'true';
  const host = isProduction ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';

  if (cachedClient && !cachedClient.client.destroyed && cachedClient.host === host) {
    return cachedClient.client;
  }

  const client = http2.connect(`https://${host}`);
  // アイドル接続は自発的に閉じる: NAT や APNs 側の無通告切断による stale 接続を防ぐ
  client.setTimeout(120_000, () => client.close());
  client.on('error', (err) => {
    console.error('[apns] HTTP/2 connection error:', err.message);
    if (cachedClient?.client === client) cachedClient = null;
  });
  client.on('close', () => {
    if (cachedClient?.client === client) cachedClient = null;
  });
  cachedClient = { client, host };
  return client;
}

function getJwt(): string {
  const keyId = process.env.APNS_KEY_ID!;
  const teamId = process.env.APNS_TEAM_ID!;
  const keyPath = process.env.APNS_KEY_PATH!;

  // 50分でキャッシュ更新: APNs の JWT 有効期限 60分に対する安全マージン
  if (cachedToken && Date.now() - cachedToken.issuedAt < 50 * 60 * 1000) {
    return cachedToken.token;
  }

  const key = readFileSync(keyPath, 'utf8');
  const now = Math.floor(Date.now() / 1000);
  const token = jwt.sign({ iss: teamId, iat: now }, key, {
    algorithm: 'ES256',
    header: {
      alg: 'ES256',
      kid: keyId,
    },
  });

  cachedToken = { token, issuedAt: Date.now() };
  return token;
}

interface NotificationPayload {
  title: string;
  subtitle?: string;
  body: string;
  category?: string;
  collapseId?: string;
  /// UNIX 秒。これを過ぎた通知は APNs が保存・再送しない (端末オフライン中に期限切れになった
  /// 承認リクエストが、復帰後に「遅れて届く」のを防ぐ)。省略時は APNs の既定保存ポリシー。
  expiration?: number;
  data?: Record<string, unknown>;
}

export type ApnsPlatform = 'ios' | 'watchos';

/// APNs topic。Watch アプリへ直接届ける場合は Watch アプリの bundle ID
/// (= iOS アプリの bundle ID + ".watchkitapp") を指定する必要がある。
export function apnsTopic(platform: ApnsPlatform = 'ios'): string {
  const bundleId = process.env.APNS_BUNDLE_ID!;
  return platform === 'watchos' ? `${bundleId}.watchkitapp` : bundleId;
}

async function sendApnsRequest(
  deviceToken: string,
  apnsPayload: Record<string, unknown>,
  pushType: 'alert' | 'background',
  priority: '10' | '5',
  collapseId?: string,
  platform: ApnsPlatform = 'ios',
  expiration?: number
): Promise<string> {
  const bundleId = apnsTopic(platform);
  const body = JSON.stringify(apnsPayload);
  const token = getJwt();

  const headers: Record<string, string | number> = {
    ':method': 'POST',
    ':path': `/3/device/${deviceToken}`,
    'authorization': `bearer ${token}`,
    'apns-topic': bundleId,
    'apns-push-type': pushType,
    'apns-priority': priority,
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(body),
  };
  if (collapseId) {
    headers['apns-collapse-id'] = collapseId;
  }
  if (expiration !== undefined) {
    headers['apns-expiration'] = Math.max(0, Math.floor(expiration));
  }

  try {
    return await attemptApnsRequest(headers, body);
  } catch (err) {
    if (!isRetryableTransportError(err)) throw err;
    const code = (err as NodeJS.ErrnoException).code;
    console.warn(`[apns] Transport error (${code}), retrying with fresh connection`);
    destroyCachedClient();
    return attemptApnsRequest(headers, body);
  }
}

/// 成功時は APNs が付けた apns-id を返す (Push Notifications Console の Delivery Log と突合するため)
function attemptApnsRequest(headers: Record<string, string | number>, body: string): Promise<string> {
  return new Promise((resolve, reject) => {
    let req: ReturnType<http2.ClientHttp2Session['request']>;
    try {
      req = getClient().request(headers);
    } catch (err) {
      // セッション破棄直後の client.request は同期例外を投げる (ERR_HTTP2_INVALID_SESSION 等)
      reject(err);
      return;
    }

    // 15秒でタイムアウト（APNs が無応答の場合のハング防止）
    req.setTimeout(15_000, () => {
      req.close();
      reject(new Error('APNs request timed out after 15s'));
    });

    let responseData = '';
    let statusCode = 0;
    let apnsId = '';

    req.on('response', (headers) => {
      statusCode = headers[':status'] as number;
      apnsId = typeof headers['apns-id'] === 'string' ? headers['apns-id'] : '';
    });

    req.on('data', (chunk) => {
      responseData += chunk;
    });

    req.on('end', () => {
      if (statusCode === 200) {
        resolve(apnsId);
      } else {
        let reason = responseData;
        try {
          const parsed = JSON.parse(responseData);
          if (parsed.reason) reason = parsed.reason;
        } catch { /* ignore */ }
        reject(new ApnsError(statusCode, reason));
      }
    });

    req.on('error', (err) => {
      reject(err);
    });

    req.write(body);
    req.end();
  });
}

export interface SendOptions {
  platform?: ApnsPlatform;
  /// 音ファイル名 (端末の bundle に同梱されているもの)。省略時は default。
  /// iPhone は NotificationService が設定値で上書きするため実質 Watch 向け。
  sound?: string;
}

export async function sendNotification(deviceToken: string, payload: NotificationPayload, options: SendOptions = {}): Promise<string> {
  const apnsPayload = {
    aps: {
      alert: {
        title: payload.title,
        ...(payload.subtitle && { subtitle: payload.subtitle }),
        body: payload.body,
      },
      sound: options.sound || 'default',
      'mutable-content': 1,
      'interruption-level': 'time-sensitive',
      ...(payload.category && { category: payload.category }),
    },
    ...payload.data,
  };

  return sendApnsRequest(deviceToken, apnsPayload, 'alert', '10', payload.collapseId, options.platform, payload.expiration);
}

export async function sendSilentNotification(
  deviceToken: string,
  data: Record<string, unknown>,
  platform: ApnsPlatform = 'ios'
): Promise<string> {
  const apnsPayload = {
    aps: { 'content-available': 1 },
    ...data,
  };

  return sendApnsRequest(deviceToken, apnsPayload, 'background', '5', undefined, platform);
}

export function isConfigured(): boolean {
  return !!(process.env.APNS_KEY_PATH && process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID && process.env.APNS_BUNDLE_ID);
}
