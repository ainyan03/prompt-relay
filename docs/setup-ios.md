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
5. **Keys** から APNs 用キー (.p8) を発行（Team 全体で共通、1つあれば OK）

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
7. 実機にビルド・インストール
