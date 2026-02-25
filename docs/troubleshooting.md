# トラブルシューティング

## 通知が来ない

### サーバが起動していない / URL が間違っている

**症状**: アプリ・PWA に承認リクエストが一切表示されない

**原因**: サーバが停止している、または `PROMPT_RELAY_SERVER_URL` のアドレスが間違っている

**対処法**:
```bash
# サーバの稼働確認
curl http://localhost:3939/health
# 期待する応答: {"status":"ok"}

# リモートサーバの場合
curl http://<サーバアドレス>:3939/health
```

応答がない場合はサーバを起動する。URL が間違っている場合は環境変数を修正:
```bash
export PROMPT_RELAY_SERVER_URL=http://<正しいアドレス>:3939
```

### ルームキーが不一致

**症状**: サーバは稼働しているが通知が来ない。サーバログに `401 unauthorized` が出力される

**原因**: フックスクリプトの `PROMPT_RELAY_API_KEY` と、アプリ側で入力したルームキーが一致していない。同じルームキーを使うクライアント同士のみがデータを共有できる

**対処法**:
```bash
# フック側のルームキーを確認
echo $PROMPT_RELAY_API_KEY

# 認証テスト（フックと同じキーを指定）
curl -H "Authorization: Bearer <ルームキー>" http://localhost:3939/permission-requests
# 200 OK が返ればフック→サーバ間は正常
```

アプリ側の設定画面でも同じルームキーが入力されているか確認する。サーバ側に固定キーの設定は不要（クライアントが送信する Bearer トークンがそのままルームキーになる）。

### VAPID キーが未設定（Web Push）

**症状**: PWA のポーリングでは承認リクエストが表示されるが、ブラウザ閉じた状態でプッシュ通知が届かない

**原因**: `server/.env` に VAPID 関連の環境変数が設定されていない

**対処法**:
```bash
# VAPID キーペアを生成
cd server && npx web-push generate-vapid-keys

# server/.env に追加
VAPID_PUBLIC_KEY=<生成された公開鍵>
VAPID_PRIVATE_KEY=<生成された秘密鍵>
VAPID_SUBJECT=mailto:you@example.com
```

サーバ起動時のログで `Web Push configured: true` と表示されることを確認する。`false` の場合は設定が不足している。

### APNs 設定不備（iOS ネイティブアプリ）

**症状**: iOS アプリに通知が届かない

**原因**: APNs の `.p8` キーファイルの配置漏れ、または `server/.env` の APNs 設定が不正

**対処法**:
1. `server/certs/` に `.p8` ファイルが配置されているか確認
2. `server/.env` の以下の値を確認:
   ```env
   APNS_KEY_ID=XXXXXXXXXX
   APNS_TEAM_ID=XXXXXXXXXX
   APNS_KEY_PATH=./certs/AuthKey_XXXXXXXXXX.p8
   APNS_BUNDLE_ID=com.yourname.prompt-relay
   APNS_PRODUCTION=false  # TestFlight/開発: false、App Store: true
   ```
3. サーバ起動時のログで `APNs configured: true` と表示されることを確認

### iOS Safari: PWA としてインストールしていない

**症状**: iOS Safari でページは表示できるが、Web Push 通知が届かない

**原因**: iOS Safari では通常のブラウザタブから Web Push を利用できない。「ホーム画面に追加」で PWA としてインストールする必要がある

**対処法**:
1. Safari で `https://<サーバアドレス>:3940/` にアクセス
2. 共有ボタン → 「ホーム画面に追加」
3. ホーム画面から PWA を起動
4. 設定画面でプッシュ通知を有効化

---

## hook が発火しない

### tmux 外で Claude Code を実行している

**症状**: Claude Code がツール実行の承認を求めるが、フックが一切反応しない

**原因**: `permission-request.sh` は `tmux display-message` でペイン情報を取得する。tmux セッション外では取得に失敗し、即座に `exit 0` する

**対処法**:
```bash
# tmux 内にいるか確認
tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'
# 出力例: main:0.0

# tmux 外の場合、tmux セッション内で Claude Code を起動し直す
tmux new-session -s claude
# このセッション内で claude を起動
```

### settings.json のフック設定が正しくない

**症状**: tmux 内で Claude Code を実行しているが、フックが発火しない

**原因**: `~/.claude/settings.json` のフック設定が誤っている、またはスクリプトに実行権限がない

**対処法**:
```bash
# settings.json の確認
cat ~/.claude/settings.json | python3 -m json.tool

# 以下が正しく設定されていること:
# - hooks.PreToolUse[].matcher が "" (空文字列で全ツールにマッチ)
# - hooks.PreToolUse[].hooks[].command がスクリプトの絶対パス
# - hooks.PreToolUse[].hooks[].timeout が 10

# スクリプトの実行権限を確認
ls -la /path/to/prompt-relay/hook/permission-request.sh
# -rwxr-xr-x であること

# 権限がない場合
chmod +x /path/to/prompt-relay/hook/*.sh
```

`setup.sh` を再実行すれば設定とパーミッションがまとめて修正される。

### 環境変数 PROMPT_RELAY_SERVER_URL が未設定

**症状**: フックは発火しているが、サーバに到達しない（サーバログに何も出ない）

**原因**: リモートサーバを使っている場合に `PROMPT_RELAY_SERVER_URL` が未設定で、デフォルトの `http://localhost:3939` に送信されている

**対処法**:
```bash
# 環境変数を確認
echo $PROMPT_RELAY_SERVER_URL

# 未設定の場合、シェルの設定ファイルに追加
echo 'export PROMPT_RELAY_SERVER_URL=http://<サーバアドレス>:3939' >> ~/.zshrc
source ~/.zshrc
```

---

## 承認操作がターミナルに反映されない

### リクエストがタイムアウト済み（2 分）

**症状**: アプリで承認ボタンを押したが、ターミナルにキーが入力されない。アプリに「already responded」エラーが表示される

**原因**: 権限リクエストは作成から 120 秒でタイムアウトする。フックスクリプトのポーリングも 120 秒で終了するため、それ以降はサーバから応答を受け取っても `tmux send-keys` を実行するプロセスが存在しない

**対処法**: ターミナルで手動操作する。タイムアウト後のリクエストはアプリ側では操作不可。Claude Code のターミナル上で直接選択肢を選ぶ。

### tmux ペインの不一致

**症状**: 承認操作がアプリ上では成功するが、ターミナルには反映されない

**原因**: フックスクリプトが取得した tmux ペイン (`session:window.pane`) と、実際に Claude Code が動作しているペインが異なっている。ウィンドウの分割・統合を行った場合に発生しうる

**対処法**:
```bash
# 現在のペインを確認
tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'
```

Claude Code を再起動すれば、フックが正しいペインを取得し直す。

### 手動で先に応答済み

**症状**: アプリで承認しようとしたら「already responded」になった

**原因**: ターミナル側で手動操作（選択肢の番号を入力）が先に行われた。フックスクリプトはプロンプトの消失を検知してサーバにキャンセルを送信する

**対処法**: 正常な動作。ターミナルとアプリのどちらで先に操作しても、先に行われた方が採用される。

### Apple Watch からの応答が反映されない

**症状**: Apple Watch の通知アクションから承認・拒否を選択したが、ターミナルに反映されない

**原因**: Watch の通知応答は iPhone 経由でサーバに送信される。以下のケースで失敗する可能性がある:

1. **サーバ再起動直後**: インメモリストレージのため、サーバ再起動で未応答リクエストが消失する。サーバログに `404` が出力される
2. **iPhone アプリがアンロード状態**: iPhone のメモリ不足でアプリが完全終了した状態で Watch から応答すると、cold launch のタイミングで問題が起きうる
3. **ネットワーク不安定**: Watch → iPhone → サーバ間の通信が不安定な場合、リトライ（3回、指数バックオフ）で回復しなければ失敗する

**対処法**:
- Xcode のコンソールで `[PromptRelay]` プレフィックスのログを確認する（`sendChoiceResponse`, `didReceive action=` 等のログが出力される）
- 失敗が頻発する場合はターミナルで手動操作する

### Apple Watch の古い通知から回答しても反映されない

**症状**: Apple Watch の通知から承認・拒否を選択したが、ターミナルに反映されない。新しい通知からは正常に操作できる

**原因**: 通知の取り違え防止機構が正常に動作している。サーバは APNs collapse-id に毎回ユニークな値を使用するため、各通知が独立した request_id を保持する。古い通知のボタンを押すと、キャンセル済みのリクエストに対して応答が送信され、サーバが `404` で拒否する

**対処法**:
- 新しい通知から回答する（正常な動作であり、異なるプロンプトへの誤回答を防いでいる）
- ターミナルで直接操作する

---

## Android アプリ固有の問題

### 接続トグルがオフなのにステータスが「接続済み」

**症状**: 設定画面のステータスは「接続済み」だが、接続トグルがオフになっている

**原因**: 旧バージョンでは、ネットワーク切り替え時の一時的な接続失敗でもトグルを自動 OFF にしていた。NetworkMonitor がネットワーク復帰を検知して再接続に成功しても、DataStore のトグル状態が OFF のまま残るケースがあった

**対処法**: アプリを最新版にアップデートする。修正後は接続トグルはユーザーの操作のみで変化し、一時的なネットワーク障害では自動 OFF しない。

---

## HTTPS / 証明書のエラー

### 自己署名 CA 証明書のインストールが必要

**症状**: ブラウザで `https://<サーバ>:3940/` にアクセスすると証明書エラーが表示される

**原因**: サーバが自動生成した CA 証明書がデバイスに信頼されていない

**対処法**:

**Android**:
1. `http://<サーバアドレス>:3939/PromptRelay-CA.pem` にアクセスして CA 証明書をダウンロード
2. 設定 → セキュリティ → 証明書のインストール → CA 証明書

**iOS**:
1. Safari で `http://<サーバアドレス>:3939/PromptRelay-CA.pem` にアクセス
2. 設定 → 一般 → VPN とデバイス管理 → ダウンロード済みプロファイルをインストール
3. 設定 → 一般 → 情報 → 証明書信頼設定 → 該当 CA の「完全な信頼を有効にする」をオン

### SAN（Subject Alternative Name）の不一致

**症状**: CA 証明書をインストール済みなのに、特定のホスト名やIPアドレスでアクセスすると証明書エラーになる

**原因**: HTTPS 証明書の SAN に、アクセスに使用しているホスト名/IP が含まれていない。Docker 環境ではコンテナ内部の IP のみが SAN に含まれる場合がある

**対処法**:

サーバはアクセス時のホスト名を自動検出して SAN に追加する仕組みがある。まず HTTP 経由で CA 証明書をダウンロードする:
```bash
# HTTP (3939) 経由でアクセスすると Host ヘッダーからホスト名が自動検出される
curl http://<外部アドレス>:3939/PromptRelay-CA.pem -o PromptRelay-CA.pem
```

これにより HTTPS 証明書が再生成され、そのホスト名が SAN に追加される。

### HTTPS_EXTRA_SANS の設定方法

**症状**: Docker 環境や Tailscale 経由で、ホスト名の自動検出がうまく動かない

**原因**: 特殊なネットワーク構成で Host ヘッダーが正しく伝わらない

**対処法**: `server/.env` に明示的に SAN を指定する:
```env
# カンマ区切りでドメイン名・IP を指定
HTTPS_EXTRA_SANS=myserver.tail01234.ts.net,192.168.1.100
```

`.env` 変更後、Docker の場合は `docker compose restart` ではなく再作成が必要:
```bash
docker compose down && docker compose up -d --pull never
```

---

## 確認コマンド集

```bash
# サーバ稼働確認
curl http://localhost:3939/health
# → {"status":"ok"}

# tmux ペイン確認
tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'
# → main:0.0

# API Key 認証テスト
curl -H "Authorization: Bearer <ルームキー>" http://localhost:3939/permission-requests
# → 200: JSON 配列が返る / 401: ルームキー不一致

# Web Push 設定確認
curl http://localhost:3939/vapid-public-key
# → {"key":"BL..."} なら設定済み / 404 なら未設定

# フックスクリプトの実行権限確認
ls -la /path/to/prompt-relay/hook/*.sh

# 環境変数一覧
echo "SERVER_URL: ${PROMPT_RELAY_SERVER_URL:-http://localhost:3939}"
echo "API_KEY: ${PROMPT_RELAY_API_KEY:-(未設定)}"
echo "SERVER_URL_2: ${PROMPT_RELAY_SERVER_URL_2:-(未設定)}"

# サーバログの確認（Docker の場合）
docker compose logs -f --tail=50

# CA 証明書の SAN を確認
openssl x509 -in server/certs/server.crt -noout -text | grep -A1 "Subject Alternative Name"
```
