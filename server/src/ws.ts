import { WebSocketServer, WebSocket } from 'ws';
import type { Server as HttpServer } from 'http';
import type { Server as HttpsServer } from 'https';
import type { IncomingMessage } from 'http';
import { getAllRequests } from './store.js';

interface WsClient {
  ws: WebSocket;
  roomKey: string;
}

const clients = new Set<WsClient>();

const MIN_KEY_LENGTH = 8;
const MAX_KEY_LENGTH = 128;

// ルームキー抽出: Authorization ヘッダー優先、クエリパラメータをフォールバック
// ブラウザ WebSocket API はカスタムヘッダーを設定できないためクエリも受け付ける
function extractRoomKey(req: IncomingMessage): string | null {
  // 1. Authorization: Bearer <key>
  const auth = req.headers.authorization || '';
  const match = auth.match(/^Bearer\s+(.+)$/i);
  let key = match?.[1] || '';

  // 2. フォールバック: ?key=<key>
  if (!key) {
    const url = new URL(req.url || '/', `http://${req.headers.host}`);
    key = url.searchParams.get('key') || '';
  }

  if (!key || key.length < MIN_KEY_LENGTH || key.length > MAX_KEY_LENGTH) return null;
  return key;
}

function attachWSS(server: HttpServer | HttpsServer): void {
  const wss = new WebSocketServer({ server, path: '/ws' });

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const roomKey = extractRoomKey(req);
    if (roomKey === null) {
      ws.close(4001, 'unauthorized');
      return;
    }

    const client: WsClient = { ws, roomKey };
    clients.add(client);
    console.log(`[ws] Client connected (room: ${roomKey.substring(0, 8)}${roomKey.length > 8 ? '...' : ''}, total: ${clients.size})`);

    // 接続直後に現在のリクエスト一覧を送信
    ws.send(JSON.stringify(buildPayload(roomKey)));

    ws.on('pong', () => {
      (ws as any).__alive = true;
    });

    ws.on('close', () => {
      clients.delete(client);
      console.log(`[ws] Client disconnected (total: ${clients.size})`);
    });

    (ws as any).__alive = true;
  });

  // 30秒ごとの ping/pong ヘルスチェック
  setInterval(() => {
    for (const client of clients) {
      if ((client.ws as any).__alive === false) {
        client.ws.terminate();
        clients.delete(client);
        continue;
      }
      (client.ws as any).__alive = false;
      client.ws.ping();
    }
  }, 30_000);
}

export function setupWebSocket(httpServer: HttpServer, httpsServer?: HttpsServer | null): void {
  attachWSS(httpServer);
  if (httpsServer) {
    attachWSS(httpsServer);
  }
  console.log(`[ws] WebSocket server attached`);
}

function buildPayload(roomKey: string) {
  const all = getAllRequests(roomKey);
  return {
    type: 'update',
    requests: all.map(r => ({
      id: r.id,
      tool_name: r.tool_name,
      message: r.message,
      choices: r.choices.length > 0 ? r.choices : null,
      created_at: r.created_at,
      response: r.response || null,
      responded_at: r.responded_at || null,
      send_key: r.send_key || null,
      hostname: r.hostname || null,
    })),
  };
}

export function broadcast(roomKey: string): void {
  if (clients.size === 0) return;
  const data = JSON.stringify(buildPayload(roomKey));
  for (const client of clients) {
    if (client.roomKey === roomKey && client.ws.readyState === WebSocket.OPEN) {
      client.ws.send(data);
    }
  }
}
