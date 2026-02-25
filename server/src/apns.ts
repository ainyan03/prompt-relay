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

function getClient(): http2.ClientHttp2Session {
  const isProduction = process.env.APNS_PRODUCTION === 'true';
  const host = isProduction ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';

  if (cachedClient && !cachedClient.client.destroyed && cachedClient.host === host) {
    return cachedClient.client;
  }

  const client = http2.connect(`https://${host}`);
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
  data?: Record<string, unknown>;
}

function sendApnsRequest(
  deviceToken: string,
  apnsPayload: Record<string, unknown>,
  pushType: 'alert' | 'background',
  priority: '10' | '5',
  collapseId?: string
): Promise<void> {
  const bundleId = process.env.APNS_BUNDLE_ID!;
  const body = JSON.stringify(apnsPayload);
  const token = getJwt();

  return new Promise((resolve, reject) => {
    const client = getClient();

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

    const req = client.request(headers);

    // 15秒でタイムアウト（APNs が無応答の場合のハング防止）
    req.setTimeout(15_000, () => {
      req.close();
      reject(new Error('APNs request timed out after 15s'));
    });

    let responseData = '';
    let statusCode = 0;

    req.on('response', (headers) => {
      statusCode = headers[':status'] as number;
    });

    req.on('data', (chunk) => {
      responseData += chunk;
    });

    req.on('end', () => {
      if (statusCode === 200) {
        resolve();
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

export async function sendNotification(deviceToken: string, payload: NotificationPayload): Promise<void> {
  const apnsPayload = {
    aps: {
      alert: {
        title: payload.title,
        ...(payload.subtitle && { subtitle: payload.subtitle }),
        body: payload.body,
      },
      sound: 'default',
      'mutable-content': 1,
      'interruption-level': 'time-sensitive',
      ...(payload.category && { category: payload.category }),
    },
    ...payload.data,
  };

  return sendApnsRequest(deviceToken, apnsPayload, 'alert', '10', payload.collapseId);
}

export async function sendSilentNotification(
  deviceToken: string,
  data: Record<string, unknown>
): Promise<void> {
  const apnsPayload = {
    aps: { 'content-available': 1 },
    ...data,
  };

  return sendApnsRequest(deviceToken, apnsPayload, 'background', '5');
}

export function isConfigured(): boolean {
  return !!(process.env.APNS_KEY_PATH && process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID && process.env.APNS_BUNDLE_ID);
}
