# API リファレンス

## エンドポイント一覧

| メソッド | パス | 説明 |
|---------|------|------|
| `GET` | `/health` | ヘルスチェック（認証不要）。`{ "status": "ok", "request_timeout_ms": 120000 }` を返す |
| `GET` | `/PromptRelay-CA.pem` | CA 証明書のダウンロード（認証不要） |
| `POST` | `/register` | iOS デバイストークンの登録（複数デバイス対応、上限 `MAX_DEVICES`） |
| `POST` | `/register-web` | Web Push subscription の登録（複数デバイス対応、上限 `MAX_DEVICES`） |
| `POST` | `/unregister` | iOS デバイストークンの解除 |
| `POST` | `/unregister-web` | Web Push subscription の解除 |
| `GET` | `/vapid-public-key` | VAPID 公開鍵の取得（認証不要） |
| `POST` | `/permission-request` | 権限リクエストの作成 (hook → server) |
| `GET` | `/permission-request/:id/response` | 応答のポーリング (hook → server) |
| `POST` | `/permission-request/:id/respond` | 応答の送信 (iOS/Android → server) |
| `POST` | `/permission-request/:id/cancel` | リクエストのキャンセル (hook → server) |
| `GET` | `/permission-requests` | リクエスト一覧の取得 (iOS/Android → server) |
| `POST` | `/notify` | 汎用通知の送信（`tmux_target` 指定で同一ターミナルの通知を自動上書き） |
| `WS` | `/ws` | WebSocket リアルタイム更新（リクエスト一覧の変更通知） |

## 認証とルーム分離

全ての認証対象エンドポイントに `Authorization: Bearer <key>` ヘッダーが必要です。Bearer トークンはルームキーとして使用され、同じキーを持つクライアント同士が同じデータ空間（ルーム）を共有します。キーは 8〜128 文字で指定してください。

以下のエンドポイントは認証不要:
- `GET /health`
- `GET /PromptRelay-CA.pem`
- `GET /vapid-public-key`

## データモデル

### Permission Request

**POST `/permission-request` リクエストボディ（hook → server）:**

```json
{
  "tool_name": "Bash",
  "tool_input": {},
  "message": "",
  "header": "Bash command",
  "description": "curl -s https://example.com",
  "prompt_question": "Do you want to proceed?",
  "choices": [
    { "number": 1, "text": "Yes" },
    { "number": 2, "text": "Yes, and don't ask again for: curl:*" },
    { "number": 3, "text": "No" }
  ],
  "has_tmux": true,
  "can_respond": true,
  "tmux_target": "hostname:session:window.pane",
  "hostname": "my-mac",
  "timeout": 120
}
```

- `timeout`: リクエストのタイムアウト秒数（オプション）。省略時はサーバの `REQUEST_TIMEOUT` がデフォルトとして使われる
- `can_respond`: tmux 以外の構造化 hook から応答できる場合は `true`。Codex の `PermissionRequest` hook が使用する

**POST `/permission-request` レスポンス:**

```json
{
  "id": "a1b2c3d4",
  "tool_name": "Bash",
  "message": "curl -s https://example.com",
  "expires_at": 1735689720000
}
```

- `id`: リクエスト識別子（8文字の16進数文字列）
- `expires_at`: リクエストの有効期限（エポックミリ秒）。フックはこの値をポーリングのデッドラインとして使用する

**GET `/permission-requests` レスポンス要素:**

```json
{
  "id": "a1b2c3d4",
  "tool_name": "Bash",
  "message": "...",
  "choices": [...],
  "created_at": 1735689600000,
  "expires_at": 1735689720000,
  "response": null,
  "responded_at": null,
  "send_key": null,
  "hostname": "my-mac"
}
```

- `created_at`, `expires_at`, `responded_at`: エポックミリ秒

### Response

`POST /permission-request/:id/respond` のリクエストボディ:

```json
{
  "choice": 1,
  "source": "ios-app",
  "device_token": "APNs device token"
}
```

- `choice`: 動的選択肢の番号。レガシークライアントは `response` に `allow` / `deny` / `allow_all` を指定可能
- `device_token`: 任意。回答元iPhoneが通知をローカル削除した場合、同じ端末へのdismissサイレントプッシュを省略するために使用

`GET /permission-request/:id/response` の応答フィールド:

- `response`: `"allow"` または `"deny"`
- `send_key`: tmux に送信するキー（選択肢の番号）

### Notification

`POST /notify` のリクエストボディ:

```json
{
  "title": "Done",
  "message": "タスクが完了しました",
  "hostname": "my-mac",
  "tmux_target": "my-mac:codex:session-id",
  "event_id": "codex-goal:session-id:complete:1785648418"
}
```

- `tmux_target`: 任意。同じ実行元の通知をAPNs/Web Pushでまとめるために使用
- `event_id`: 任意。1〜256文字の場合、同じルームで既に受理したIDは再配信しない。省略した旧hookは従来どおり毎回配信する

## WebSocket `/ws`

リクエスト一覧の変更をリアルタイムで受信できる WebSocket エンドポイントです。

### 接続

```
ws://<host>:<port>/ws?key=<ルームキー>
wss://<host>:<https_port>/ws?key=<ルームキー>
```

- 認証: `Authorization: Bearer <key>` ヘッダー優先、クエリパラメータ `key` でのフォールバックも可（ブラウザ WebSocket API はカスタムヘッダーを設定できないため）
- HTTP / HTTPS 両方のサーバにアタッチされている

### メッセージ形式

サーバからクライアントへ JSON メッセージを送信:

```json
{
  "type": "update",
  "requests": [
    {
      "id": "a1b2c3d4",
      "tool_name": "Bash",
      "message": "...",
      "choices": [...],
      "created_at": "...",
      "response": null,
      "hostname": "my-mac"
    }
  ]
}
```

- リクエストの作成・応答・キャンセル時に自動送信される
- クライアントからサーバへのメッセージ送信は不要

### ping/pong

サーバは 30 秒間隔で WebSocket ping を送信し、接続の生存確認を行います。

## エラーレスポンス

| ステータスコード | 意味 | 発生条件 |
|-----------------|------|----------|
| `401 Unauthorized` | 認証エラー | ルームキーが未指定または不正 |
| `404 Not Found` | リソースが存在しない | 指定された ID のリクエストが見つからない、または期限切れ |
