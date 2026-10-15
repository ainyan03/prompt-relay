# Claude Code フック設定

Codex の設定は [Codex フック設定](setup-codex.md) を参照してください。

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
3. **フェーズ1（検出）**: バックグラウンドで tmux ペインをポーリングし、権限プロンプトの出現を検出
4. **フェーズ2（送信）**: 検出後、ペイン内容をパースしてサーバへ送信
5. **フェーズ3（応答待ち）**: サーバからの応答をポーリングし、`tmux send-keys` で入力
6. 応答送信後、再びフェーズ1に戻り次の連続プロンプトを検出（プランモード等で複数の承認プロンプトが順次表示される場合に対応）

**排他制御（PID 後勝ち方式）:**

ロックファイルは使用せず、2つの PID ファイルによる「後勝ち」方式で排他制御を行います:

- **WATCHER_FILE**: フェーズ1〜2（検出＋送信）を排他。新しいフックが起動すると古いフックは検出を中断する
- **POLLER_FILE**: フェーズ3（応答ポーリング）を排他。新しいリクエストが送信されると古いポーラーは退く

この設計により、フェーズ3（最大120秒）が新しいプロンプトの処理をブロックしません。万一フェーズ2で重複送信が発生しても、サーバ側の `cancelPendingByTarget` が旧リクエストを自動キャンセルするため実害はありません。

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

### notification.sh（Notification / UserPromptSubmit / Stop）

処理完了などの通知を送信します。既定では Claude Code の `idle_prompt` と
Codex の `Stop` で通知します。session モードでは `UserPromptSubmit` で作業開始を記録し、
`Stop` で待機への移行を記録します。

### matcher について

- `PreToolUse` の `matcher` は空文字列（`""`）で全ツールにマッチさせます
- `Notification` の `matcher` は `"idle_prompt"` でアイドル通知のみにマッチさせます

### 環境変数

フックスクリプトは以下の環境変数を参照します:

| 変数 | 説明 | デフォルト |
|---|---|---|
| `PROMPT_RELAY_SERVER_URL` | プライマリサーバURL | `http://localhost:3939` |
| `PROMPT_RELAY_SERVER_URL_2` | セカンダリサーバURL（オプション） | なし |
| `PROMPT_RELAY_API_KEY` | ルームキー（必須） | なし |
| `PROMPT_RELAY_API_KEY_2` | セカンダリ用ルームキー（オプション） | プライマリと同じ |
| `PROMPT_RELAY_TIMEOUT` | リクエストタイムアウト（秒）。サーバに送信され、リクエスト固有の期限として使用される | `120` |
| `PROMPT_RELAY_DETECT_INTERVAL` | プロンプト検出のポーリング間隔（秒） | `0.1` |
| `PROMPT_RELAY_DETECT_ATTEMPTS` | プロンプト検出の最大試行回数 | `10` |
| `PROMPT_RELAY_IDLE_SCOPE` | 待機通知の単位。`pane` または `session` | `pane` |
| `PROMPT_RELAY_IDLE_GRACE` | session モードで全体の待機を再判定するまでの秒数 | `5` |
| `PROMPT_RELAY_STATE_DIR` | 待機状態ファイルの保存先 | `/tmp/prompt-relay-state-<uid>` |

`PROMPT_RELAY_IDLE_SCOPE=session` にすると、tmux セッション内で状態を記録した
全エージェントが待機してから猶予時間が経過したとき、1 回だけ通知します。
`setup.sh` を再実行して、Claude Code の `UserPromptSubmit` / `Stop` と
Codex の `UserPromptSubmit` / `Stop` に必要な hook を登録してください。
これらは `notification.sh --agent claude` / `notification.sh --agent codex` を呼びます。
既存の引数なし Codex `Stop` 登録もそのまま使えます。
tmux 外では従来のペイン単位の動作になります。承認・質問の通知経路は変わりません。

待機はターン終了で判定し、バックグラウンド作業は見ません。
ユーザーが Esc で中断したペインは、次のターンまで busy のまま残ります。
Codex の goal が active の間は待機扱いになりません。

session モードの通常完了通知は、Claude / Codex とも「全エージェントの処理が完了しました」に統一します。
Codex goal のブロック・一時停止・利用上限・予算上限は、それぞれの理由を示す文面を維持します。

### Antigravity CLI (agy)

Antigravity CLI は session モードの待機集計にだけ参加します。
pane モードでは通知しません。権限確認プロンプトの中継は対象外です。
`~/.gemini` が存在する環境で `setup.sh` を実行すると、
`~/.gemini/config/hooks.json` に次の名前付き hook を登録します（既存の hook は保持します）。
手動で登録する場合も、`PreInvocation` / `Stop` は matcher を使わないフラットな配列にします。

```json
{
  "prompt-relay": {
    "PreInvocation": [
      {"type": "command", "command": "/path/to/prompt-relay/hook/notification.sh --agent agy --event PreInvocation", "timeout": 10}
    ],
    "Stop": [
      {"type": "command", "command": "/path/to/prompt-relay/hook/notification.sh --agent agy --event Stop", "timeout": 10}
    ]
  }
}
```

`PROMPT_RELAY_IDLE_SCOPE=session` を設定して agy を再起動してください。
`PreInvocation` で busy、`Stop` で idle を記録し、`fullyIdle` は判定に使いません。
Esc 中断では `Stop` が出ないため、次のターンまで busy が残ります。
