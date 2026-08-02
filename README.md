# prompt-relay

> **⚠ 本ツールは LAN / VPN / Tailscale 等の信頼できるネットワーク内での利用を前提としています。インターネットに直接公開するサーバでの運用は想定していません。** 詳しくは [SECURITY.md](SECURITY.md) を参照してください。

Claude Code / Codex の承認待ちをスマホで操作するためのツールです。

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) と [Codex](https://developers.openai.com/codex/) は、ファイル変更やコマンド実行前にユーザーへ承認を求めることがあります。prompt-relay を使うと、この承認操作をスマートフォンからリモートで行えます。

## できること

- Claude Code / Codex が承認待ちになるとスマホにプッシュ通知
- 通知から承認・拒否を選択すると Claude Code / Codex に自動反映
- プランモード等で連続する承認プロンプトにも対応（自動で次のプロンプトを検出）
- 処理完了時にも通知でお知らせ
- 同一ターミナルの通知は最新1件に自動上書き（通知の溜まりを防止）
- ブラウザだけで利用可能（PWA）、アプリのインストール不要
- iPhone ネイティブアプリにも対応（Apple Developer Program が必要）
- Android ネイティブアプリにも対応（Jetpack Compose）
- ESP32 (M5Stack) 版サーバにも対応（物理ボタンで承認操作）
- **即時通知（iOS）**: Time Sensitive Notifications 対応。集中モード中でも承認リクエストを即座に配信
- **誤タップ防止**: 新しい承認要求の表示時にアニメーション付きで挿入し、ボタンを一時無効化してリスト移動による押し間違いを防止
- **設定エラー自動検出**: URLやAPIキーが誤っている場合に自動でリトライを停止し、エラー内容をステータスに表示

## 必要なもの

- Claude Code を使う場合: tmux 上で実行する環境
- Codex を使う場合: lifecycle hooks 対応版。TUIとスマホを併用する場合はtmux
- Python 3（フックスクリプトのプロンプト検出・パースに使用）
- Node.js サーバ（ローカルまたは LAN 内、Docker 対応）
- Android アプリを使う場合: Android 8.0 以上
- ESP32 版を使う場合: M5Stack + ESP-IDF v5.5.1

## アーキテクチャ

```
Claude Code / Codex (権限プロンプト / ターン・goal完了)
    │
    ▼
hook/permission-request.sh  ── PreToolUse で発火、tmux 画面をパースしてサーバへ転送
hook/codex-permission-request.sh ── PermissionRequest の構造化データと応答を中継
hook/notification.sh        ── ターン完了・Codex goal状態の通知を送信
    │
    ├──▶ Node.js Server (Express)  ── リクエスト管理 + APNs / Web Push 送信
    │       ├──▶ Apple Push Notification Service ──▶ iOS App / Apple Watch
    │       └──▶ Web Push (VAPID) ──▶ PWA (任意のブラウザ)
    │
    └──▶ ESP32 Server (M5Stack)  ── ディスプレイ表示 + 物理ボタン操作（オプション）
    │
    ▼
Server へ応答を返送（先に応答した方を採用）
    │
    ▼
Claude: tmux send-keys / Codex: tmux内はTUIへ入力、tmux外はhookのdecisionを返却
```

## クイックセットアップ

リポジトリをクローンしてセットアップスクリプトを実行すると、Claude Code と Codex の hook 登録および環境変数の設定が完了します。

```bash
git clone <repo-url> ~/prompt-relay
cd ~/prompt-relay
./setup.sh
```

各コンポーネントの詳細なセットアップ手順は以下を参照してください。

## セットアップガイド

すべての構成で **サーバ** と **フック** のセットアップが必要です。クライアントは用途に応じて選択してください。

```
1. サーバを起動          → docs/setup-server.md
2. フックを設定          → docs/setup-hooks.md
3. クライアントを選ぶ:
   ├─ ブラウザで使いたい  → docs/setup-pwa.md     （PWA、インストール不要）
   ├─ iPhone で使いたい   → docs/setup-ios.md     （要 Apple Developer Program）
   ├─ Android で使いたい  → docs/setup-android.md （ソースビルド）
   └─ 物理ボタンで使いたい → docs/setup-esp32.md  （M5Stack）
```

| ドキュメント | 内容 |
|---|---|
| [サーバセットアップ](docs/setup-server.md) | Node.js サーバ、.env 設定、API 認証、Docker デプロイ、マルチホスト・デュアルサーバ構成 |
| [Claude Code フック設定](docs/setup-hooks.md) | settings.json の設定、フックの動作原理 |
| [Codex フック設定](docs/setup-codex.md) | hooks.json の設定、PermissionRequest の動作原理 |
| [PWA（ブラウザ）](docs/setup-pwa.md) | HTTPS 証明書、PWA インストール（Android / iOS / Tailscale） |
| [iOS アプリ](docs/setup-ios.md) | Apple Developer Portal 設定、Xcode ビルド |
| [Android アプリ](docs/setup-android.md) | Android Studio ビルド、通知設定 |
| [ESP32 (M5Stack)](docs/setup-esp32.md) | ビルド & 書き込み、ボタン操作 |
| [API リファレンス](docs/api.md) | REST API エンドポイント一覧 |
| [トラブルシューティング](docs/troubleshooting.md) | よくある問題と解決方法 |

## 設計思想

prompt-relay は Claude Code / Codex の標準承認操作を**補完する**ツールです。**標準操作の置き換えが目的ではありません**。

### フェイルセーフ設計

Claude Code では `PreToolUse` フックとtmuxの画面検出を使用します。Codexはtmux内で起動すると、`PermissionRequest` hookが要求だけを登録して即終了するため、標準TUIとスマホの両方から回答できます。Codex TUIに3択以上が表示された場合も、各選択肢の文言をスマホへ転送し、選択結果を対応するTUIショートカットへ変換します。tmux外では構造化された `allow` / `deny` をhookから直接返します。

- フックがエラーで終了しても、標準の承認操作を利用できる
- サーバが停止・障害状態でも、Claude Code / Codex の処理を継続できる
- スマートフォンアプリが機能しなくても、ターミナルでの手動承認は常に可能

中継が利用できない場合に AI コーディングツールまで利用不能にならない設計です。

### 接続のオン・オフ

アプリで接続をオフにすると、クライアントがサーバからデバイストークン（APNs）や Web Push subscription を解除します。解除後はサーバがそのデバイスにプッシュ通知を送信しなくなるため、以下が停止します:

- スマートフォンへのプッシュ通知送信

**ただし承認プロンプト自体はターミナルに引き続き表示されるので、手動での応答は常に可能です**。ターミナルで手動承認すれば Claude Code は通常どおり動作します。接続をオンに戻すと、デバイスが再登録されて通知が再開します。

## プロジェクト構成

```
prompt-relay/
├── server/                 # Node.js/Express バックエンド
│   ├── src/
│   │   ├── index.ts        # メインサーバ（API エンドポイント）
│   │   ├── apns.ts         # APNs プッシュ通知送信
│   │   ├── web-push.ts     # Web Push (VAPID) 送信
│   │   ├── certs.ts        # HTTPS 自動証明書生成
│   │   └── store.ts        # インメモリデータストア
│   ├── public/             # PWA フロントエンド
│   ├── certs/              # APNs 秘密鍵 (.p8) + 自動生成 HTTPS 証明書
│   └── Dockerfile          # Docker イメージビルド
├── hook/                   # Claude Code / Codex フックスクリプト
│   ├── common.sh               # 共通設定（サーバURL、認証、デュアルサーバ）
│   ├── permission-request.sh   # 権限リクエストハンドラ（PreToolUse）
│   ├── codex-permission-request.sh # Codex 権限リクエスト（PermissionRequest）
│   ├── codex_goal_status.py    # Codex App Serverからgoal状態を読み取り
│   ├── prompt_parser.py        # プロンプト検出・パースロジック
│   ├── test_prompt_parser.py   # パーサーの単体テスト
│   └── notification.sh         # 汎用通知送信（Notification）
├── server-esp32/           # ESP32 (M5Stack) 版サーバ
├── app-android/            # Android アプリ (Jetpack Compose)
├── app-ios/                # iOS アプリ (SwiftUI)
├── docs/                   # ドキュメント
├── docker-compose.yml
├── setup.sh
└── README.md
```

## 使い方

1. **サーバを起動する**
   - Docker: `docker compose up -d`
   - ローカル: `cd server && npm ci && npm run dev`
2. TUIとスマホを併用する場合は、Claude Code / Codexを **tmuxセッション内で** 起動
3. iOS アプリまたは PWA (`http://localhost:3939/`) を開き、接続設定を行う
4. Claude Code / Codex がツール実行の許可を求めると、フックスクリプトが発火
5. サーバ経由で iOS / PWA にプッシュ通知が届く
6. 通知から直接応答、または アプリを開いて応答
7. フックスクリプトが応答を受け取り、tmux TUIまたはCodex hook応答へ反映
8. tmux 側で手動回答した場合は、アプリ側が自動的に「Cancelled」に更新
9. 処理が完了すると完了通知が届く

## 注意事項

- **Codexはモードを自動選択**: tmux内ではTUI＋スマホのハイブリッド、tmux外ではスマホ優先の直接応答になります
- **Automatic approvalを通知しない**: tmuxハイブリッドでは、標準TUIが実際に表示された承認要求だけをスマホへ転送します
- **APNs collapse ID**: 64バイトを超える識別子はサーバで固定長ハッシュへ変換します
- **インメモリストレージ**: サーバ再起動で履歴クリア。未応答リクエストは `REQUEST_TIMEOUT` 秒（デフォルト 120）でタイムアウト、`REQUEST_CLEANUP` 秒（デフォルト 300）で自動削除。`MAX_HISTORY` で履歴保持件数を制限可能
- **マルチデバイス**: APNs / Web Push それぞれ最大 4 台（`MAX_DEVICES` で変更可）。上限超過時は最後に通知送信が成功した時刻が最も古いデバイスを自動淘汰
- **通知の即時配信**: 同一ターミナルからの通知は APNs collapse-id / Web Push tag で管理。毎回ユニークな collapse-id を使用し、APNs の「更新」扱いによる配信遅延を回避
- **通知の取り違え防止**: 古い通知のボタンを押してもサーバ側でキャンセル済みリクエストとして拒否されるため、誤って新しいプロンプトに回答することを防止

## ライセンス

[ISC](LICENSE)
