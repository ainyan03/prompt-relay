# Codex フック設定

Codex は `PermissionRequest` lifecycle hook から構造化された承認要求を受け取れます。prompt-relayは実行環境に応じて、標準TUIとスマホを併用するtmuxハイブリッド、または構造化hook応答を使う直接応答を自動選択します。

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

## 推奨: TUIとスマホを併用する

Codexをtmux内で起動します。

```bash
tmux new-session -s codex
codex
```

既定の `auto` モードはtmuxを検出すると、次のように動作します。

1. `PermissionRequest` hookはポーラーをバックグラウンド化し、決定を返さず即終了
2. Automatic approvalで承認された場合は、TUIもスマホ通知も表示しない
3. Codex標準TUIに承認選択肢が実際に表示された場合だけ、サーバへ要求を登録してスマホへ通知
4. TUIで回答した場合はスマホ側リクエストをキャンセル
5. スマホで回答した場合は、選択した番号をTUIに表示されたショートカット（例: `y` / `p` / `esc`）へ変換してtmuxへ入力

Codex TUIが `Yes, proceed`、`Yes, and don't ask again ...`、`No ...` の3択を表示した場合、スマホにも同じ3択を表示します。2番目を選ぶとTUIへ `p` を送り、そのコマンド接頭辞を以後確認しない選択として処理されます。

## tmux外の直接応答

1. Codex が承認を必要とする直前に `PermissionRequest` hook を起動
2. hook の stdin から `tool_name`、`tool_input`、セッション情報を取得
3. サーバへ承認要求を作成し、スマートフォンへ通知
4. スマートフォンの Allow / Deny をポーリング
5. 回答があれば Codex 仕様の decision JSON を stdout へ返す
6. 接続失敗または `PROMPT_RELAY_TIMEOUT` 経過時は空出力で終了し、Codex標準の承認画面を表示

`Stop` hook はターン完了時の通知に使います。

## モード設定

`PROMPT_RELAY_CODEX_MODE` で動作を固定できます。

| 値 | 動作 |
|---|---|
| `auto` | 既定。tmux内はハイブリッド、tmux外は直接応答 |
| `tmux` | ハイブリッドのみ。tmux外では中継しない |
| `direct` | 常に構造化hook応答。tmux内でも待機中はTUIを表示しない |

例:

```bash
export PROMPT_RELAY_CODEX_MODE=auto
```

## 注意事項

- tmux外の直接応答モードでは、リモート回答を待っている間はCodex標準の承認画面がまだ表示されません。
- tmuxハイブリッドではTUIが即時表示され、`PROMPT_RELAY_TIMEOUT` はスマホ側リクエストの有効時間になります。
- `PROMPT_RELAY_CODEX_DETECT_TIMEOUT` はTUI表示を待つ秒数です（既定30秒）。TUIが出なければAutomatic approval済みとして通知しません。
- tmux外の直接応答モードではTUIを観測できないため、Automatic approval対象かどうかを事前判定できません。自動承認の通知抑止にはtmuxハイブリッドを使用してください。
- Codex の hook はユーザー設定の `~/.codex/hooks.json` に登録します。プロジェクトローカル hook と違い、各リポジトリへ設定を複製する必要はありません。
- hooks を明示的に無効化している場合は、`~/.codex/config.toml` の `[features]` で `hooks = true` にしてください。

Codex hook の仕様は [OpenAI の Hooks ドキュメント](https://learn.chatgpt.com/docs/hooks) を参照してください。
