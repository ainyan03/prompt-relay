# Codex フック設定

Codex は `PermissionRequest` lifecycle hook から構造化された承認要求を受け取れます。prompt-relay はスマートフォンの回答を待ち、`allow` または `deny` を Codex へ直接返します。tmux と画面解析は使いません。

## 自動セットアップ

リポジトリ直下で実行します。

```bash
./setup.sh
```

`~/.codex/hooks.json` に Codex 用 hook が追加されます。既存 hook は保持されます。Codex を再起動した後、`/hooks` を開いて追加された command hook の内容を確認し、信頼してください。hook の定義が変更された場合は再確認が必要です。

## 手動セットアップ

`~/.codex/hooks.json` に以下を追加します。パスは実際の clone 先へ置き換えてください。

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/prompt-relay/hook/codex-permission-request.sh",
            "statusMessage": "Waiting for Prompt Relay"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/prompt-relay/hook/notification.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

実行権限も付与します。

```bash
chmod +x hook/codex-permission-request.sh hook/notification.sh
```

## 動作フロー

1. Codex が承認を必要とする直前に `PermissionRequest` hook を起動
2. hook の stdin から `tool_name`、`tool_input`、セッション情報を取得
3. サーバへ承認要求を作成し、スマートフォンへ通知
4. スマートフォンの Allow / Deny をポーリング
5. 回答があれば Codex 仕様の decision JSON を stdout へ返す
6. 接続失敗または `PROMPT_RELAY_TIMEOUT` 経過時は空出力で終了し、Codex 標準の承認画面を表示

`Stop` hook はターン完了時の通知に使います。

## 注意事項

- リモート回答を待っている間、Codex 標準の承認画面はまだ表示されません。既定では 120 秒後に標準画面へフォールバックします。
- `PROMPT_RELAY_TIMEOUT` を短くすると、標準画面へ戻るまでの時間も短くなります。
- Codex の hook はユーザー設定の `~/.codex/hooks.json` に登録します。プロジェクトローカル hook と違い、各リポジトリへ設定を複製する必要はありません。
- hooks を明示的に無効化している場合は、`~/.codex/config.toml` の `[features]` で `hooks = true` にしてください。

Codex hook の仕様は [OpenAI の Hooks ドキュメント](https://learn.chatgpt.com/docs/hooks) を参照してください。
