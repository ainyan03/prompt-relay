# Claude Code フック設定

## settings.json の設定

`~/.claude/settings.json` にフックを追加:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/prompt-relay/hook/permission-request.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/prompt-relay/hook/notification.sh"
          }
        ]
      }
    ]
  }
}
```

フックスクリプトに実行権限を付与:

```bash
chmod +x hook/permission-request.sh hook/notification.sh
```

## フックの動作原理

### permission-request.sh（PreToolUse）

権限プロンプトの検出と応答転送を行います。

**動作フロー:**

1. `PreToolUse` は各ツール実行前に発火する（権限不要のツールでも発火）
2. フック本体は stdin を読み取り、バックグラウンドサブシェルを起動して即 `exit 0`
3. バックグラウンドで tmux ペインをポーリングし、権限プロンプトの出現を検出
4. 検出後、ペイン内容をパースしてサーバへ送信
5. サーバからの応答をポーリングし、`tmux send-keys` で入力
6. 応答送信後、再びステップ 3 に戻り次の連続プロンプトを検出（プランモード等で複数の承認プロンプトが順次表示される場合に対応）

**プロンプト検出・パースロジック:**

検出・パースのロジックは `hook/prompt_parser.py` に集約されており、`permission-request.sh` から CLI 経由で呼び出されます。

- `detect_prompt`: 可視領域の末尾から番号降順パターンを探索し、`❯` カーソル**および** `Esc to` / `Enter to` 行の**両方**の存在を要求（誤検出防止）
- `parse_pane`: ペイン内容からヘッダー・説明・選択肢を構造化
- `parse_response`: サーバ応答 JSON を解析

テストは `hook/test_prompt_parser.py` で管理:

```bash
cd hook && pipx run pytest test_prompt_parser.py -v
```

**重要な実装詳細:**

バックグラウンドサブシェルの stdin/stdout/stderr は `/dev/null` にリダイレクトする必要があります。これを怠ると、Claude Code がパイプの EOF を待ち続けてプロンプト表示がブロックされるデッドロックが発生します。

```bash
( ... ) </dev/null >/dev/null 2>&1 &
exit 0
```

**手動回答の検知:**

tmux 側で手動回答するとプロンプトが消えるため、バックグラウンドプロセスがこれを検知してサーバにキャンセルを送信します（SEEN_PROMPT パターン）。

### notification.sh（Notification）

処理完了などの通知を送信します。`Notification` タイプの `idle_prompt` マッチャーで発火します。

### matcher について

- `PreToolUse` の `matcher` は空文字列（`""`）で全ツールにマッチさせます
- `Notification` の `matcher` は `"idle_prompt"` でアイドル通知のみにマッチさせます

### 環境変数

フックスクリプトは `hook/common.sh` で以下の環境変数を参照します:

| 変数 | 説明 | デフォルト |
|---|---|---|
| `PROMPT_RELAY_SERVER_URL` | プライマリサーバURL | `http://localhost:3939` |
| `PROMPT_RELAY_SERVER_URL_2` | セカンダリサーバURL（オプション） | なし |
| `PROMPT_RELAY_API_KEY` | ルームキー（必須） | なし |
| `PROMPT_RELAY_API_KEY_2` | セカンダリ用 API キー（オプション） | プライマリと同じ |
| `PROMPT_RELAY_DETECT_INTERVAL` | プロンプト検出のポーリング間隔（秒） | `0.1` |
| `PROMPT_RELAY_DETECT_ATTEMPTS` | プロンプト検出の最大試行回数 | `10` |
