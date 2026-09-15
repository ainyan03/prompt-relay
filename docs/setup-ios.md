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
Apple Watch アプリ（下記）を入れていれば、同じ選択が Watch の通知にも適用されます。

## Apple Watch アプリ

iPhone の通知をミラー表示するだけでは Watch の通知音を変えられないため、Watch 用のコンパニオンアプリ
（`PromptRelayWatch` ターゲット）を用意しています。

- 通知はサーバから Watch アプリへ直接届き、iPhone で選んだ通知音で鳴ります
- 承認は **通知をタップして Watch アプリを開き、画面のボタンで応答**します。Watch の通知には
  ボタンを付けていません（watchOS の制約で、通知のボタンからでは応答が即時に届かないため）
- Watch アプリを開いた画面では、**ダブルタップ**（人差し指と親指を 2 回合わせる）で最初の選択肢
  （Yes）を送れます（watchOS 11 以降、Series 9 / Ultra 2 以降）
- Watch アプリを開いている間は数秒おきに承認待ちを取り直すので、通知の配送が遅れてもボタンが出ます。
  別の端末で先に応答した枠は自動で消えます
- 通知を見逃しても、Watch アプリを開けば届いている承認リクエストが表示されます。スマートスタックに
  **Prompt Relay ウィジェット**を追加しておくと、そこからアプリを開けます（文字盤を長押し →
  スマートスタックの編集、または文字盤でクラウンを回してスマートスタックを開き「+」から追加）
  watchOS 27 以降なら、スマートスタックをダブルタップで送り、シングルタップ（指を 1 回合わせる）で
  ウィジェットを選んでアプリを開けるため、画面に触れずに承認まで進めます。シングルタップは
  スマートスタック専用で、アプリ内では効きません
- Watch はサーバと直接通信しません。トークンの登録や応答はすべて iPhone アプリが中継するので、
  サーバが Tailscale などの VPN 越しでも、自己署名証明書でも動きます。応答の中継には iPhone が
  近くにある必要があります

### セットアップ

1. Apple Developer Portal の **Devices** に Watch を登録する。UDID は Xcode の Devices and Simulators
   に Watch が表示されていればそこから、表示されない場合は
   `xcrun devicectl list devices` で識別子を調べ `xcrun devicectl device info details --device <識別子>` で確認できる
2. Portal の **App IDs** に `<Bundle ID>.watchkitapp` が作られ、**Push Notifications** が有効になっていることを確認する
   （Xcode の自動署名で作られる。作られない場合は手動で追加）
3. Xcode で `PromptRelay` スキームを iPhone に Run する（Watch アプリも同梱される）
4. iPhone の **Watch** アプリ → PromptRelay をインストールする。Watch 側で
   設定 → プライバシーとセキュリティ → デベロッパモード をオンにするよう求められたらオンにする
5. Watch で PromptRelay を開き、「詳細」の「登録」が `登録済 (200)` になっていれば完了

Xcode から Run し直しても Watch 側のアプリが更新されないことがあります。Watch アプリの「詳細」に
ある build 時刻が古いままなら、iPhone の Watch アプリから一度削除して入れ直してください。
Watch のトークンは再インストールで変わりますが、iPhone アプリが検知して登録し直します。

## 通信と省電力動作

- リクエスト画面は、アプリがフォアグラウンドの間だけ `/ws` へ接続します。バックグラウンド移行時は接続を閉じます。
- WebSocket切断中は指数バックオフで再接続し、一覧取得は30秒間隔へフォールバックします。画面を下へ引くと手動更新できます。
- APNsデバイストークンの再登録は、設定変更時を除き15分以内の重複送信を省略します。
- ルームキーはKeychainへ保存します。旧バージョンの `UserDefaults` にあるキーは初回起動時に自動移行します。
- LAN内HTTPとの互換性のためATSのローカルネットワーク例外を使用します。外部ネットワーク経由ではHTTPSを推奨します。
