# サーバセットアップ

## 前提条件

- Node.js 18+ (Docker 利用時は不要)

## インストール

```bash
cd server
npm install
```

## .env 設定

`.env` ファイルを `server/` ディレクトリに作成します。PWA のみ使う場合と iOS アプリも使う場合で必要な設定が異なります。

### 最小構成（PWA のみ）

```env
PORT=3939

# Web Push (VAPID) — PWA プッシュ通知に必要
VAPID_PUBLIC_KEY=BLxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxQ=
VAPID_PRIVATE_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxQ
VAPID_SUBJECT=mailto:you@example.com
```

VAPID キーペアの生成:

```bash
npx web-push generate-vapid-keys
```

### iOS アプリも使う場合は追加

```env
# Apple Developer で発行した APNs キー情報
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_KEY_PATH=./certs/AuthKey_XXXXXXXXXX.p8
APNS_BUNDLE_ID=com.yourname.prompt-relay

# 開発中は false、本番は true
APNS_PRODUCTION=false
```

APNs の `.p8` キーファイルを `server/certs/` に配置してください。

### マルチデバイス設定（オプション）

APNs / Web Push それぞれに登録できるデバイス数の上限を設定できます。

```env
# マルチデバイス上限（APNs / Web Push 各上限、デフォルト 4）
MAX_DEVICES=4
```

上限を超えた場合、最後に通知送信が成功した時刻（`lastPushAt`）が最も古いデバイスが自動的に削除されます。未送信のデバイスは登録時刻（`registeredAt`）で判定されます。

無効なデバイストークン（APNs の BadDeviceToken / Unregistered、Web Push の 410 / 404）は送信失敗時に自動削除されます。

## ルームキー（API キー）

クライアントが送信する Bearer トークン（`PROMPT_RELAY_API_KEY`）がそのままルームキーとして使われます。同じキーを持つクライアント同士が同じルーム（データ空間）を共有し、異なるキーを使えば 1 つのサーバで複数ユーザのデータを分離できます。

**キーの要件**: 8〜128 文字（この範囲外のキーはサーバに拒否されます）。

サーバ側に固定キーの設定は不要です。フックスクリプトを使うマシンで環境変数を設定するだけで動作します:

```bash
export PROMPT_RELAY_API_KEY=your-secret-key-here
```

iOS / Android アプリ、PWA の設定画面でも同じキーを入力してください。

> **⚠ セキュリティ注意**: サーバはキーの正当性を検証しません。任意のキーでルームを作成できるため、**インターネットに直接公開しないでください**。Tailscale や VPN 等の信頼できるネットワーク内での利用を推奨します。

## サーバ起動

```bash
cd server
npm run dev
```

デフォルトで `http://localhost:3939` で起動します。

## マルチホスト構成

サーバを別マシン（NAS 等）で動作させ、複数のマシンから利用する場合:

1. 各マシンで環境変数 `PROMPT_RELAY_SERVER_URL` にサーバのアドレスを設定:

```bash
export PROMPT_RELAY_SERVER_URL=http://your-server:3939
```

2. サーバは APNs への HTTPS アウトバウンド接続が必要
3. 各マシンのホスト名は自動的にリクエストに付与され、アプリ上でバッジ表示される

## デュアルサーバ構成

Node.js サーバと ESP32 サーバを同時に運用し、両方で承認操作を受け付けることができます。先に応答した方の結果が採用されます。

```bash
# セカンダリサーバ（ESP32 等）のアドレスを設定
export PROMPT_RELAY_SERVER_URL_2=http://192.168.x.x:3939

# セカンダリ用に別の API キーを使う場合（省略時はプライマリと同じキーを使用）
export PROMPT_RELAY_API_KEY_2=your-secondary-key
```

フックスクリプトは `PROMPT_RELAY_SERVER_URL_2` が設定されていれば自動的に両サーバへリクエストを送信します。

## Docker デプロイ

```bash
cd prompt-relay

# ビルド & 起動
docker compose up -d --build

# ログ確認
docker compose logs -f

# ヘルスチェック
curl http://localhost:3939/health
```

`server/.env` に最低限 VAPID の設定を記述してください。iOS アプリも使う場合は APNs の設定と `server/certs/` への `.p8` キー配置も必要です。

`docker-compose.yml` では HTTP と HTTPS の両ポートを公開し、`server/certs/` をボリュームマウントします（自動生成証明書の永続化のため）:

```yaml
services:
  server:
    image: prompt-relay:latest
    env_file: ./server/.env
    volumes:
      - ./server/certs:/app/certs
    ports:
      - "3939:3939"
      - "3940:3940"
    restart: unless-stopped
```

### NAS 等でビルドできない場合

QNAP Container Station など:

```bash
# ローカルでビルドしてイメージをエクスポート
docker build --platform linux/amd64 -t prompt-relay:latest ./server/
docker save prompt-relay:latest | gzip | ssh your-nas 'docker load'

# NAS 上で起動
ssh your-nas 'cd /path/to/prompt-relay && docker compose up -d'
```

### Docker + LAN/Tailscale での HTTPS

Docker コンテナはホストのネットワークインターフェースを直接参照できないため、起動時の証明書 SAN にはコンテナ内部 IP のみが含まれます。外部からのアクセスには以下のいずれかで対応します:

- **自動検出（推奨）**: `http://<外部アドレス>:3939/PromptRelay-CA.pem` で CA 証明書をダウンロードすると、Host ヘッダーから外部ホスト名が自動検出され HTTPS 証明書に追加されます
- **環境変数で明示指定**: `.env` に `HTTPS_EXTRA_SANS=myserver.example.com,192.168.1.100` を追加

**注意**: `.env` の内容を変更した場合、`docker compose restart` では反映されません。`docker compose down && docker compose up -d` で再作成してください。
