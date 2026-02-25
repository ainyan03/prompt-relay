// Service Worker - プッシュ通知受信 & PWA 起動 v6

// --- ライフサイクル: 即時有効化 ---
self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('message', (_event) => {
  // 将来の拡張用
});

self.addEventListener('push', (event) => {
  if (!event.data) return;

  let payload;
  try {
    payload = event.data.json();
  } catch (e) {
    console.error('[SW] Failed to parse push data:', e);
    return;
  }

  const { title, body, subtitle, tag, data } = payload;

  const options = {
    body: subtitle ? `${subtitle}\n${body}` : body,
    icon: 'icon-192.png',
    badge: 'badge-96.png',
    tag: tag || data?.request_id || 'notify',
    data: data || {},
    requireInteraction: true,
  };

  event.waitUntil(self.registration.showNotification(title || 'Prompt Relay', options));
});

self.addEventListener('notificationclick', (event) => {
  const notification = event.notification;
  const data = notification.data || {};
  const requestId = data.request_id;

  notification.close();

  // permission_request の場合はリクエスト詳細へスクロールできるようハッシュ付きで開く
  const url = (requestId && data.type === 'permission_request')
    ? `/#${requestId}`
    : '/';

  event.waitUntil(openOrFocusPWA(url, requestId));
});

async function openOrFocusPWA(url, requestId) {
  try {
    const windowClients = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windowClients) {
      if ('focus' in client) {
        await client.focus();
        // 既に開いている PWA に対象リクエストを通知
        if (requestId) {
          client.postMessage({ type: 'FOCUS_REQUEST', requestId });
        }
        return;
      }
    }
  } catch (_) {}
  return clients.openWindow(url);
}
