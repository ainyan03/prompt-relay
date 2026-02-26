# ESP32 (M5Stack) セットアップ

ESP32 版は Node.js サーバの REST API と互換性があり、単体でもデュアルサーバ構成のセカンダリとしても利用できます。

設計の詳細は [design-esp32.md](design-esp32.md) を参照してください。

## 必要なもの

- M5Stack（Core、Core2 等の M5Unified 対応デバイス）
- ESP-IDF v5.5.1

## ビルド & 書き込み

```bash
cd server-esp32

# WiFi 設定
idf.py menuconfig
# → "Prompt Relay Configuration" で SSID とパスワードを設定

# ビルド & フラッシュ
idf.py build flash monitor
```

## 認証

ESP32 版は任意のルームキー（8〜128 文字）を受け付けます。
Node.js サーバと同じ `PROMPT_RELAY_API_KEY` をフックスクリプトに設定するだけで動作します。

> **注意**: ESP32 版はルーム分離を行いません。
> 異なるキーでもすべてのリクエストが同じ画面・ボタンで操作されます。

## 機能

- ディスプレイにリクエスト内容を日本語で表示（経過時間カウンタ付き）
- ボタン A: 最初の選択肢（承認）、ボタン B: 最後の選択肢（拒否）、ボタン C: 次のリクエストへ
- 新しいリクエスト到着時にビープ音で通知
- mDNS で `prompt-relay.local` として自動検出可能
