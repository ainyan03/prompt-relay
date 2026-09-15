# iOS アプリセットアップ

## 前提条件

- **Apple Developer アカウント** (APNs キーの発行に必要)
- **実機 iPhone** (プッシュ通知はシミュレータでは受信不可)
- Xcode 15+

## Apple Developer Portal の設定

1. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) を開く
2. **App IDs** を作成:
   - メインアプリ: `com.yourname.prompt-relay`
   - NotificationService Extension: `com.yourname.prompt-relay.NotificationService`（Xcode が自動作成する場合あり）
3. 両方の App ID で **Push Notifications** capability を有効にする
4. メインアプリの App ID で **Time Sensitive Notifications** capability を有効にする（集中モード中でも通知を配信）
5. 両方の App ID で **App Groups** capability を有効にし、`group.<メインアプリの Bundle ID>` を割り当てる（通知音の設定をアプリと Extension で共有するため。Xcode の自動署名で作成される場合あり）
6. **Keys** から APNs 用キー (.p8) を発行（Team 全体で共通、1つあれば OK）

## アプリのビルド

1. 設定ファイルをテンプレートからコピー:

```bash
# Xcode プロジェクト設定（Team ID, Bundle ID）
cp app-ios/PromptRelay/Config.xcconfig.example app-ios/PromptRelay/Config.xcconfig
# 中身を自分の Apple Developer 情報に書き換え

# アプリ設定（デフォルトサーバURL）
cp app-ios/PromptRelay/PromptRelay/Config.swift.example app-ios/PromptRelay/PromptRelay/Config.swift
# 中身を自分のサーバアドレスに書き換え
```

2. `app-ios/PromptRelay/PromptRelay.xcodeproj` を Xcode で開く
3. Signing & Capabilities で自分のチームが選択されていることを確認
4. Bundle Identifier が `server/.env` の `APNS_BUNDLE_ID` と一致していることを確認（例: `com.yourname.prompt-relay`）
5. **Push Notifications** capability が有効であることを確認
6. **Time Sensitive Notifications** capability が有効であることを確認
7. 両ターゲットで **App Groups** capability が有効で、`group.<Bundle ID>` が選択されていることを確認
8. 実機にビルド・インストール

## 通知音

アプリの設定タブで、承認リクエストと完了通知それぞれの通知音を選べます（選ぶと試聴できます）。
音は `app-ios/PromptRelay/PromptRelay/Sounds/*.caf` として同梱しており、`app-ios/tools/gen-sounds.py` で再生成できます。
Apple Watch は NotificationService Extension を実行しないため標準音のままです。

## 通信と省電力動作

- リクエスト画面は、アプリがフォアグラウンドの間だけ `/ws` へ接続します。バックグラウンド移行時は接続を閉じます。
- WebSocket切断中は指数バックオフで再接続し、一覧取得は30秒間隔へフォールバックします。画面を下へ引くと手動更新できます。
- APNsデバイストークンの再登録は、設定変更時を除き15分以内の重複送信を省略します。
- ルームキーはKeychainへ保存します。旧バージョンの `UserDefaults` にあるキーは初回起動時に自動移行します。
- LAN内HTTPとの互換性のためATSのローカルネットワーク例外を使用します。外部ネットワーク経由ではHTTPSを推奨します。
