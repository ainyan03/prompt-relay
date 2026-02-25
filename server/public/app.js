// Prompt Relay PWA Client

(function () {
  'use strict';

  // --- State ---
  let serverUrl = '';
  let apiKey = '';
  let pollTimer = null;
  let requests = [];
  let swRegistration = null;
  let ws = null;
  let wsReconnectTimer = null;
  let wsReconnectDelay = 1000;
  let wsConnected = false;
  let knownPendingIds = new Set();
  let lockTimer = null;

  // --- DOM refs ---
  const requestList = document.getElementById('request-list');
  const emptyState = document.getElementById('empty-state');
  const inputServer = document.getElementById('input-server');
  const inputApiKey = document.getElementById('input-apikey');
  const toggleConnect = document.getElementById('toggle-connect');
  const connectErrorEl = document.getElementById('connect-error');
  const apikeyErrorEl = document.getElementById('apikey-error');
  const togglePush = document.getElementById('toggle-push');
  const pushStatusEl = document.getElementById('push-status');
  const pollingStatusEl = document.getElementById('polling-status');

  // --- Tabs ---
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
      document.querySelectorAll('.panel').forEach((p) => p.classList.remove('active'));
      tab.classList.add('active');
      document.getElementById('panel-' + tab.dataset.tab).classList.add('active');
    });
  });

  // --- Settings ---
  function loadSettings() {
    serverUrl = localStorage.getItem('serverUrl') || '';
    apiKey = localStorage.getItem('apiKey') || '';
    inputServer.value = serverUrl;
    inputApiKey.value = apiKey;
    toggleConnect.checked = localStorage.getItem('connectEnabled') !== 'false';
  }

  // --- API Key validation ---
  const MIN_KEY_LENGTH = 8;
  const MAX_KEY_LENGTH = 128;

  function validateApiKey(key) {
    if (!key) return 'API Key を入力してください';
    if (key.length < MIN_KEY_LENGTH) return `API Key は ${MIN_KEY_LENGTH} 文字以上で入力してください (現在: ${key.length}文字)`;
    if (key.length > MAX_KEY_LENGTH) return `API Key は ${MAX_KEY_LENGTH} 文字以下で入力してください`;
    return '';
  }

  function showApiKeyError(msg) {
    if (msg) {
      apikeyErrorEl.textContent = msg;
      apikeyErrorEl.style.display = '';
    } else {
      apikeyErrorEl.style.display = 'none';
    }
  }

  // --- Auto-save with debounce ---
  let saveTimer = null;
  function scheduleSettingsSave() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      serverUrl = inputServer.value.replace(/\/+$/, '');
      apiKey = inputApiKey.value;
      localStorage.setItem('serverUrl', serverUrl);
      localStorage.setItem('apiKey', apiKey);

      const keyError = validateApiKey(apiKey);
      showApiKeyError(keyError);

      passApiKeyToSW();
      if (toggleConnect.checked && !keyError) {
        closeWebSocket();
        connectWebSocket();
      }
    }, 500);
  }
  inputServer.addEventListener('input', scheduleSettingsSave);
  inputApiKey.addEventListener('input', scheduleSettingsSave);

  // --- 接続トグル ---
  toggleConnect.addEventListener('change', async () => {
    connectErrorEl.style.display = 'none';
    if (toggleConnect.checked) {
      const keyError = validateApiKey(apiKey);
      if (keyError) {
        showApiKeyError(keyError);
        toggleConnect.checked = false;
        localStorage.setItem('connectEnabled', 'false');
        return;
      }
      connectWebSocket();
      startPolling();
    } else {
      closeWebSocket();
      stopPolling();
      // サーバから Web Push subscription を解除
      unregisterWebPush();
    }
    localStorage.setItem('connectEnabled', toggleConnect.checked);
  });

  // --- API helper ---
  function apiFetch(path, options = {}) {
    const base = serverUrl || '';
    const headers = options.headers || {};
    headers['Content-Type'] = 'application/json';
    if (apiKey) {
      headers['Authorization'] = 'Bearer ' + apiKey;
    }
    return fetch(base + path, { ...options, headers });
  }

  // --- Polling ---
  function startPolling() {
    if (pollTimer) return;
    poll();
    pollTimer = setInterval(poll, 2000); // 2秒間隔でポーリング（WS 未接続時のフォールバック）
    pollingStatusEl.innerHTML = statusHtml(true, '動作中');
  }

  function stopPolling() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    pollingStatusEl.innerHTML = statusHtml(false, '停止中');
  }

  async function poll() {
    try {
      const res = await apiFetch('/permission-requests');
      if (!res.ok) {
        if (res.status === 401) {
          stopPolling();
          pollingStatusEl.innerHTML = statusHtml(false, '認証エラー');
          toggleConnect.checked = false;
          connectErrorEl.textContent = '認証エラー: API Key を確認してください';
          connectErrorEl.style.display = '';
          localStorage.setItem('connectEnabled', 'false');
        }
        return;
      }
      requests = await res.json();
      renderRequests();
    } catch {
      // ネットワークエラー — 静かに無視して次回リトライ
    }
  }

  // --- WebSocket ---
  function connectWebSocket() {
    if (ws) return;

    try {
      let protocol, host;
      if (serverUrl) {
        protocol = serverUrl.startsWith('https') ? 'wss:' : 'ws:';
        host = serverUrl.replace(/^https?:\/\//, '');
      } else {
        protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
        host = location.host;
      }
      const keyParam = apiKey ? '?key=' + encodeURIComponent(apiKey) : '';
      const url = protocol + '//' + host + '/ws' + keyParam;

      ws = new WebSocket(url);

      ws.onopen = function () {
        console.log('[ws] Connected');
        wsConnected = true;
        wsReconnectDelay = 1000;
        stopPolling();
        pollingStatusEl.innerHTML = statusHtml(true, 'リアルタイム');
      };

      ws.onmessage = function (event) {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'update' && Array.isArray(data.requests)) {
            requests = data.requests;
            renderRequests();
          }
        } catch (err) {
          console.error('[ws] Parse error:', err);
        }
      };

      ws.onclose = function () {
        console.log('[ws] Disconnected');
        ws = null;
        wsConnected = false;
        // ポーリングにフォールバック
        if (toggleConnect.checked) {
          startPolling();
          // 指数バックオフで再接続
          scheduleReconnect();
        }
      };

      ws.onerror = function () {
        // onclose が呼ばれるのでここでは何もしない
      };
    } catch (err) {
      console.error('[ws] Connection error:', err);
      ws = null;
    }
  }

  function closeWebSocket() {
    if (wsReconnectTimer) {
      clearTimeout(wsReconnectTimer);
      wsReconnectTimer = null;
    }
    if (ws) {
      ws.onclose = null; // 再接続スケジュールを防止
      ws.close();
      ws = null;
    }
    wsConnected = false;
  }

  function scheduleReconnect() {
    if (wsReconnectTimer) return;
    wsReconnectTimer = setTimeout(function () {
      wsReconnectTimer = null;
      if (toggleConnect.checked) {
        connectWebSocket();
      }
    }, wsReconnectDelay);
    wsReconnectDelay = Math.min(wsReconnectDelay * 2, 30000); // 最大30秒で再接続（指数バックオフ上限）
  }

  // --- Render ---
  // 各カードの状態フィンガープリントを保持（変化検知用）
  const cardFingerprints = new Map();

  function requestFingerprint(req) {
    return req.id + '|' + (req.response || 'pending') + '|' + (req.responded_at || 0);
  }

  function renderRequests() {
    const pending = requests.filter((r) => !r.response);
    const responded = requests.filter((r) => r.response);

    if (pending.length === 0 && responded.length === 0) {
      requestList.innerHTML = '';
      emptyState.style.display = '';
      cardFingerprints.clear();
      return;
    }

    emptyState.style.display = 'none';

    const allVisible = [...pending, ...responded];
    const newIds = new Set(allVisible.map((r) => r.id));

    // 不要なカード・ヘッダーを削除
    for (const child of Array.from(requestList.children)) {
      if (child.classList.contains('section-header')) {
        child.remove();
      } else if (!newIds.has(child.dataset.id)) {
        child.remove();
        cardFingerprints.delete(child.dataset.id);
      }
    }

    // DOM を再構築
    requestList.innerHTML = '';

    if (pending.length > 0) {
      const header = document.createElement('div');
      header.className = 'section-header';
      header.textContent = '承認待ち (' + pending.length + ')';
      requestList.appendChild(header);

      for (const req of pending) {
        const fp = requestFingerprint(req);
        let card = document.createElement('div');
        card.className = 'card';
        card.dataset.id = req.id;
        rebuildCard(card, req);
        cardFingerprints.set(req.id, fp);
        requestList.appendChild(card);
      }
    }

    if (responded.length > 0) {
      const header = document.createElement('div');
      header.className = 'section-header';
      header.textContent = '履歴';
      requestList.appendChild(header);

      for (const req of responded) {
        const fp = requestFingerprint(req);
        let card = document.createElement('div');
        card.className = 'card';
        card.dataset.id = req.id;
        rebuildCard(card, req);
        cardFingerprints.set(req.id, fp);
        requestList.appendChild(card);
      }
    }

    // 新規 pending カードの検出とボタンロック
    const currentPendingIds = new Set(pending.map((r) => r.id));
    let hasNewPending = false;
    for (const id of currentPendingIds) {
      if (!knownPendingIds.has(id)) {
        hasNewPending = true;
        // 新規カードにアニメーションクラスを付与
        const card = requestList.querySelector(`[data-id="${id}"]`);
        if (card) card.classList.add('card-new');
      }
    }
    if (hasNewPending && knownPendingIds.size > 0) {
      requestList.classList.add('cards-locked');
      clearTimeout(lockTimer);
      lockTimer = setTimeout(() => {
        requestList.classList.remove('cards-locked');
        lockTimer = null;
      }, 300);
    }
    knownPendingIds = currentPendingIds;
  }

  function rebuildCard(card, req) {
    const isPending = !req.response;
    const elapsed = Date.now() - req.created_at;
    const remaining = Math.max(0, 120000 - elapsed); // 2分タイムアウト（サーバの PENDING_TIMEOUT_MS と一致）
    const remainSec = Math.ceil(remaining / 1000);

    let html = '<div class="card-header">';
    html += `<span class="card-tool">${escapeHtml(req.tool_name)}</span>`;
    if (req.hostname) {
      html += `<span class="card-host">${escapeHtml(req.hostname)}</span>`;
    }
    if (isPending && remaining > 0) {
      const timerClass = remainSec <= 30 ? 'timer-danger' : remainSec <= 60 ? 'timer-warning' : 'timer-gray';
      html += `<span class="card-timer ${timerClass}">${remainSec}s</span>`;
    }
    html += '</div>';

    html += `<div class="card-message">${escapeHtml(req.message)}</div>`;

    if (isPending && remaining > 0) {
      html += '<div class="card-actions">';
      if (req.choices && req.choices.length > 0) {
        for (const c of req.choices) {
          const cls = isDenyChoice(c.text) ? 'btn-deny' : 'btn-allow';
          html += `<button class="${cls}" data-id="${req.id}" data-choice="${c.number}">${escapeHtml(c.text)}</button>`;
        }
      } else {
        html += `<button class="btn-allow" data-id="${req.id}" data-response="allow">Allow</button>`;
        html += `<button class="btn-deny" data-id="${req.id}" data-response="deny">Deny</button>`;
      }
      html += '</div>';
    } else if (req.response) {
      // 選択肢テキストベースで色を決定
      let statusLabel;
      let statusClass;
      if (req.response === 'cancelled') {
        statusLabel = 'Cancelled';
        statusClass = 'cancelled';
      } else {
        const chosen = (req.send_key && req.choices)
          ? req.choices.find((c) => String(c.number) === String(req.send_key))
          : null;
        statusLabel = chosen ? chosen.text : '';
        statusClass = (chosen && isDenyChoice(chosen.text)) ? 'deny' : 'allow';
      }
      html += `<div class="card-status ${statusClass}">${escapeHtml(statusLabel)}</div>`;
    } else {
      html += '<div class="card-status expired">Expired</div>';
    }

    card.innerHTML = html;

    // イベントリスナー
    card.querySelectorAll('button[data-id]').forEach((btn) => {
      btn.addEventListener('click', handleAction);
    });
  }

  async function handleAction(e) {
    const btn = e.currentTarget;
    const id = btn.dataset.id;
    const choice = btn.dataset.choice;
    const response = btn.dataset.response;

    // ボタン無効化
    btn.closest('.card-actions').querySelectorAll('button').forEach((b) => {
      b.disabled = true;
      b.style.opacity = '0.5';
    });

    try {
      const body = choice ? { choice: parseInt(choice, 10), source: 'pwa' } : { response, source: 'pwa' };
      await apiFetch(`/permission-request/${id}/respond`, {
        method: 'POST',
        body: JSON.stringify(body),
      });
      // WS 未接続時は即座にポーリング
      if (!wsConnected) poll();
    } catch (err) {
      console.error('respond failed:', err);
      const actions = btn.closest('.card-actions');
      if (actions) {
        actions.querySelectorAll('button').forEach((b) => {
          b.disabled = false;
          b.style.opacity = '';
        });
      }
    }
  }

  function isDenyChoice(text) {
    const lower = (text || '').toLowerCase();
    return lower.startsWith('no') || lower.startsWith('reject') || lower.startsWith('deny');
  }

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function statusHtml(on, label) {
    return `<span class="status-indicator ${on ? 'on' : 'off'}"></span>${escapeHtml(label)}`;
  }

  // --- カウントダウンタイマー更新 ---
  setInterval(() => {
    document.querySelectorAll('.card').forEach((card) => {
      const id = card.dataset.id;
      const req = requests.find((r) => r.id === id);
      if (!req || req.response) return;

      const remaining = Math.max(0, 120000 - (Date.now() - req.created_at)); // 2分タイムアウト
      const timer = card.querySelector('.card-timer');
      if (timer) {
        const sec = Math.ceil(remaining / 1000);
        timer.textContent = sec + 's';
        timer.className = 'card-timer ' + (sec <= 30 ? 'timer-danger' : sec <= 60 ? 'timer-warning' : 'timer-gray');
      }

      if (remaining <= 0) {
        // タイムアウト — 再描画
        rebuildCard(card, { ...req, response: 'expired' });
      }
    });
  }, 1000);

  // --- Service Worker & Push ---
  async function registerSW() {
    if (!('serviceWorker' in navigator)) return;

    try {
      swRegistration = await navigator.serviceWorker.register('sw.js');
      console.log('[app] SW registered');
      passApiKeyToSW();
      updatePushUI();
    } catch (err) {
      console.error('[app] SW registration failed:', err);
    }
  }

  function passApiKeyToSW() {
    if (swRegistration && swRegistration.active) {
      swRegistration.active.postMessage({ type: 'SET_API_KEY', apiKey });
    } else if (navigator.serviceWorker && navigator.serviceWorker.controller) {
      navigator.serviceWorker.controller.postMessage({ type: 'SET_API_KEY', apiKey });
    }
  }

  // SW がアクティブになったとき
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      passApiKeyToSW();
    });
  }

  togglePush.addEventListener('change', async () => {
    if (togglePush.checked) {
      await subscribePush();
    } else {
      await unsubscribePush();
    }
  });

  async function subscribePush() {
    if (!swRegistration) {
      pushStatusEl.textContent = 'Service Worker が未登録です';
      togglePush.checked = false;
      return;
    }

    try {
      // VAPID 公開鍵を取得
      const res = await apiFetch('/vapid-public-key');
      if (!res.ok) {
        pushStatusEl.textContent = 'VAPID 未設定（サーバ側）';
        togglePush.checked = false;
        return;
      }
      const { key } = await res.json();
      if (!key) {
        pushStatusEl.textContent = 'VAPID 未設定（サーバ側）';
        togglePush.checked = false;
        return;
      }

      // pushManager.subscribe() が内部で権限リクエストを行う
      const subscription = await swRegistration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(key),
      });

      // サーバに登録
      const regRes = await apiFetch('/register-web', {
        method: 'POST',
        body: JSON.stringify({ subscription: subscription.toJSON() }),
      });

      if (!regRes.ok) {
        pushStatusEl.textContent = '登録に失敗しました';
        togglePush.checked = false;
        return;
      }

      localStorage.setItem('pushEnabled', 'true');
      updatePushUI();
    } catch (err) {
      console.error('[app] push subscribe failed:', err);
      pushStatusEl.textContent = 'エラー: ' + err.message;
      togglePush.checked = false;
    }
  }

  async function unsubscribePush() {
    if (!swRegistration) return;

    try {
      const subscription = await swRegistration.pushManager.getSubscription();
      if (subscription) {
        // サーバから subscription を解除してからブラウザ側を解除
        await unregisterWebPush();
        await subscription.unsubscribe();
      }
      localStorage.removeItem('pushEnabled');
      updatePushUI();
    } catch (err) {
      console.error('[app] push unsubscribe failed:', err);
    }
  }

  async function unregisterWebPush() {
    if (!swRegistration) return;
    try {
      const subscription = await swRegistration.pushManager.getSubscription();
      if (subscription) {
        await apiFetch('/unregister-web', {
          method: 'POST',
          body: JSON.stringify({ endpoint: subscription.endpoint }),
        });
      }
    } catch (err) {
      console.error('[app] unregister-web failed:', err);
    }
  }

  async function updatePushUI() {
    if (!swRegistration) {
      pushStatusEl.textContent = '';
      togglePush.checked = false;
      return;
    }

    try {
      const subscription = await swRegistration.pushManager.getSubscription();
      if (subscription) {
        togglePush.checked = true;
        pushStatusEl.textContent = '通知を受信します';
      } else {
        togglePush.checked = false;
        pushStatusEl.textContent = '';
      }
    } catch {
      togglePush.checked = false;
    }
  }

  function urlBase64ToUint8Array(base64String) {
    const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    const rawData = atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for (let i = 0; i < rawData.length; i++) {
      outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
  }

  // --- LAN Setup Guide ---
  function showLanSetup() {
    const isLocalhost = location.hostname === 'localhost' || location.hostname === '127.0.0.1';
    const isHTTPS = location.protocol === 'https:';

    if (isLocalhost || isHTTPS) return;

    // HTTP + 非 localhost → LAN セットアップガイドを表示
    const lanSetup = document.getElementById('lan-setup');
    const linkCA = document.getElementById('link-ca');
    const linkHTTPS = document.getElementById('link-https');

    const httpPort = location.port || '3939';
    const httpsPort = String(parseInt(httpPort, 10) + 1);

    linkCA.href = location.protocol + '//' + location.hostname + ':' + httpPort + '/PromptRelay-CA.pem';
    linkHTTPS.href = 'https://' + location.hostname + ':' + httpsPort + '/';

    lanSetup.style.display = '';
  }

  // --- SW からの通知タップ → 該当カードへスクロール ---
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', (event) => {
      const msg = event.data;
      if (msg && msg.type === 'FOCUS_REQUEST' && msg.requestId) {
        focusRequest(msg.requestId);
      }
    });
  }

  // ハッシュによる該当カードフォーカス（SW が新規ウィンドウで開いた場合）
  function checkHashFocus() {
    const hash = location.hash.replace('#', '');
    if (hash) {
      history.replaceState(null, '', '/');
      // ポーリングで最新データ取得後にフォーカス
      poll().then(() => focusRequest(hash));
    }
  }

  function focusRequest(requestId) {
    // リクエストタブに切り替え
    const reqTab = document.querySelector('[data-tab="requests"]');
    if (reqTab && !reqTab.classList.contains('active')) {
      reqTab.click();
    }
    // 該当カードにスクロール＆ハイライト
    const card = requestList.querySelector(`[data-id="${requestId}"]`);
    if (card) {
      card.scrollIntoView({ behavior: 'smooth', block: 'center' });
      card.classList.add('highlight');
      setTimeout(() => card.classList.remove('highlight'), 2000);
    }
  }

  // --- Init ---
  loadSettings();
  registerSW();
  const initKeyError = validateApiKey(apiKey);
  showApiKeyError(initKeyError);
  if (toggleConnect.checked && !initKeyError) {
    connectWebSocket();
    startPolling();
  } else if (initKeyError) {
    toggleConnect.checked = false;
    localStorage.setItem('connectEnabled', 'false');
  }
  showLanSetup();
  checkHashFocus();
})();
