# Prompt Relay ESP32 Edition — 設計ドキュメント

## 1. プロジェクト概要

### 目的

Claude Code の承認要求（permission prompt）を手元のデバイスで受け取り、物理ボタンで応答できるシステムを、**ESP32（M5Stack シリーズ）で実現**する。

### ゴール

- M5Stack 単体で承認操作が可能（PC の画面を見なくてよい）
- 既存の Node.js サーバと API 互換（フックスクリプトの送信先を変えるだけで動作）
- デュアルサーバ構成で Node.js 版と並行運用可能

### 現行版との関係

| 項目 | Node.js 版 | ESP32 版 |
|---|---|---|
| サーバ実行環境 | Docker / NAS / VPS | M5Stack 単体 |
| 通知方法 | APNs / Web Push | ディスプレイ表示 + ビープ音 |
| クライアント | iOS アプリ / PWA | デバイス本体の画面・ボタン |
| プロトコル | HTTP/2 (APNs), WebSocket | HTTP/1.1 のみ |
| 運用形態 | メインサーバ | 単独 or デュアルサーバのセカンダリ |

---

## 2. ハードウェア

### 動作確認済みデバイス

| デバイス | ディスプレイ | ボタン | 状態 |
|---|---|---|---|
| M5Stack Basic / Gray | 320x240 TFT | 3個（A/B/C） | 動作確認済み |

### 将来対応候補

| デバイス | ディスプレイ | ボタン | 備考 |
|---|---|---|---|
| M5Stack Core2 / CoreS3 | 320x240 タッチ | タッチ操作 | M5Unified で対応可能 |
| M5StickC Plus | 135x240 TFT | 2個 | UI 調整が必要 |

### 最小要件

- ESP32（WiFi 対応）
- フラッシュ 4MB 以上
- PSRAM 推奨

---

## 3. システムアーキテクチャ

```
┌──────────────────────────────────────────────────┐
│ Claude Code (PC / tmux セッション) ×複数同時対応  │
│                                                  │
│  hook/permission-request.sh                      │
│    POST /permission-request → ESP32              │
│    GET  /permission-request/:id/response ← ESP32 │
│    POST /permission-request/:id/cancel  → ESP32  │
└──────────────────┬───────────────────────────────┘
                   │ HTTP/1.1 (LAN)
                   ▼
┌──────────────────────────────────────────────────┐
│ ESP32 (M5Stack)                                  │
├──────────────────────────────────────────────────┤
│                                                  │
│  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ HTTP Server  │  │ Request Store            │  │
│  │ (REST API)   │──│ (8 slots, in-memory)     │  │
│  │ esp_http_    │  └──────────────────────────┘  │
│  │ server       │                                │
│  └──────────────┘  ┌──────────────────────────┐  │
│                    │ Display Manager          │  │
│  ┌──────────────┐  │ (M5GFX, 日本語フォント)   │  │
│  │ Button       │  │ 部分更新でちらつき防止     │  │
│  │ Handler      │  └──────────────────────────┘  │
│  │ (M5Unified) │                                │
│  └──────────────┘  ┌──────────────────────────┐  │
│                    │ mDNS                     │  │
│  ┌──────────────┐  │ (prompt-relay.local)      │  │
│  │ Speaker      │  └──────────────────────────┘  │
│  │ (ビープ音)   │                                │
│  └──────────────┘                                │
└──────────────────────────────────────────────────┘
```

### 動作フロー

1. Claude Code のフックが ESP32 に `POST /permission-request` を送信
2. ESP32 はリクエストをストアに保存し、画面に表示 + ビープ音で通知
3. ユーザーが物理ボタンで応答（A: 承認、B: 拒否、C: 次のリクエスト）
4. フックが `GET /permission-request/:id/response` で応答を取得
5. tmux に自動入力

### 複数セッション対応

- 各リクエストは `hostname` と `tmux_target` で送信元を識別
- 画面ヘッダーにホスト名を表示し、どのセッションの要求か視覚的に区別
- 同時保持リクエスト: 最大 8 件

---

## 4. API 仕様（Node.js 版互換）

### 実装済みエンドポイント

| メソッド | パス | 説明 |
|---|---|---|
| `GET` | `/health` | ヘルスチェック |
| `POST` | `/permission-request` | 承認要求の作成 |
| `GET` | `/permission-request/:id/response` | 応答のポーリング |
| `POST` | `/permission-request/:id/respond` | 応答の送信 |
| `POST` | `/permission-request/:id/cancel` | キャンセル |
| `GET` | `/permission-requests` | 一覧取得 |
| `POST` | `/notify` | 汎用通知 |

### 省略したエンドポイント（ESP32 版では不要）

| メソッド | パス | 理由 |
|---|---|---|
| `POST` | `/register` | APNs デバイストークン不要 |
| `POST` | `/register-web` | Web Push 不要 |
| `GET` | `/vapid-public-key` | Web Push 不要 |
| `GET` | `/PromptRelay-CA.pem` | HTTPS 不要 |
| `GET` | `/ws` | WebSocket 不要（画面直接更新） |

### 実装上の注意点

- ESP-IDF の `httpd_uri_match_wildcard` は URI 末尾の `*` のみ対応。`/permission-request/*/response` のような中間ワイルドカードは不可
- 解決策: `/permission-request/*` をキャッチオールで登録し、ハンドラ内で URI サフィックス（`/response`, `/respond`, `/cancel`）を判別して分岐

### メモリ管理

- 同時保持リクエスト数: 最大 **8 件**（固定配列）
- 120 秒で自動 expire
- 5 分後に自動削除（クリーンアップ）
- 同一 `tmux_target` の未応答リクエストは新規作成時に自動キャンセル

---

## 5. 画面 UI

M5GFX で直接描画。`startWrite()` / `endWrite()` による SPI トランザクションバッチで描画のちらつきを防止。日本語フォントは `efontJA_14` を使用。

### 待機画面

```
┌─────────────────────────┐
│ Prompt Relay     ● WiFi │
│                         │
│   192.168.x.x:3939      │
│   承認待ちなし            │
│                         │
│ [A:---] [B:---] [C:---] │
└─────────────────────────┘
```

### 承認要求表示

```
┌─────────────────────────┐
│ macbook:0  [1/3]   45s  │
│─────────────────────────│
│ Bash command            │
│                         │
│ npm install             │
│                         │
│─────────────────────────│
│ [A:Yes] [B:No ] [C:次▶] │
└─────────────────────────┘
```

### 描画の最適化

- **全体再描画**: 状態遷移時（待機→要求表示、要求切り替え）のみ
- **部分更新**: タイマー表示はヘッダー右端のみ再描画（本文を巻き込まない）
- **フルスクリーンスプライトは使用禁止**: 320x240 のスプライトはメモリ不足で動作しない

---

## 6. 技術スタック

| 項目 | 選択 | 備考 |
|---|---|---|
| フレームワーク | **ESP-IDF v5.5.1** | |
| デバイス抽象化 | **M5Unified** (^0.2) | ボタン・電源・スピーカー等を統一 API で扱う |
| ディスプレイ | **M5GFX** | M5Unified に含まれる描画ライブラリ |
| HTTP サーバ | **esp_http_server** | ESP-IDF 標準コンポーネント |
| JSON パーサ | **cJSON** | ESP-IDF 標準コンポーネント |
| ストレージ | **NVS (nvs_flash)** | 設定の永続化 |
| mDNS | **mdns** (^1.4) | ESP-IDF コンポーネント |
| UUID 生成 | **esp_fill_random()** | ハードウェア乱数で UUID v4 生成 |

---

## 7. プロジェクト構成

```
prompt-relay/
├── server/                 # Node.js 版サーバ
├── server-esp32/           # ESP32 (M5Stack) 版サーバ
│   ├── CMakeLists.txt
│   ├── sdkconfig.defaults
│   ├── partitions.csv
│   └── main/
│       ├── CMakeLists.txt
│       ├── idf_component.yml   # M5Unified, mdns の依存定義
│       ├── main.cpp
│       ├── http_server.cpp/h
│       ├── request_store.cpp/h
│       ├── display_manager.cpp/h
│       ├── button_handler.cpp/h
│       ├── wifi_setup.cpp/h
│       └── mdns_service.cpp/h
├── app-ios/                # iOS アプリ
├── hook/                   # Claude Code フックスクリプト
├── docs/                   # 設計ドキュメント
└── docker-compose.yml
```

---

## 8. 実装状況

### Phase 1: MVP — 完了

- [x] ESP-IDF プロジェクトスケルトン + M5Unified 初期化
- [x] `esp_http_server` で REST API 互換エンドポイント実装
- [x] `request_store`: インメモリリクエスト管理（複数セッション対応）
- [x] `display_manager`: リクエスト表示画面（日本語、部分更新）
- [x] `button_handler`: 物理ボタンで承認/拒否/切替
- [x] mDNS サービス登録（`prompt-relay.local`）
- [x] ビープ音による新着通知
- [x] デュアルサーバ構成でのフックスクリプト対応
- [x] フックスクリプトとの疎通確認

### Phase 2: 通知プラグイン — 未着手

- [ ] Pushover / Telegram / Discord 等への通知転送
- [ ] プラグインインターフェースの設計
- [ ] Web 設定画面

### Phase 3: 拡張・改善 — 未着手

- [ ] OTA ファームウェア更新
- [ ] AP モード WiFi プロビジョニング
- [ ] M5StickC / Core2 / CoreS3 向け UI 最適化
- [ ] スリープ/省電力制御
