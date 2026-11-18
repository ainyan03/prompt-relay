# Claude Code / Antigravity CLI フック設定

Codex の設定は [Codex フック設定](setup-codex.md) を参照してください。
tmux / cmux で Codex の承認画面へ回答を中継するには、[起動時の `--no-daemon` の設定](setup-codex.md#推奨-tuiとスマホを併用する)も必要です。

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
        "matcher": "idle_prompt|permission_prompt",
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

## 対応する端末

| 起動環境 | Claude Code の承認 | 完了通知の session モード |
|---|---|---|
| tmux | 画面を検出し、スマホの回答をキー入力で転送 | tmux セッション単位 |
| cmux（tmux を使わず直接起動） | 画面を検出し、スマホの回答をキー入力で転送 | cmux workspace 単位 |
| その他（Terminal.app 等） | 「承認待ち」の通知のみ。回答は端末で操作 | エージェントごと |

端末は環境変数で自動判別します。`TMUX` と `TMUX_PANE` が揃えば tmux を優先し、
`TMUX` が無く `CMUX_SURFACE_ID` があれば cmux、それ以外は画面操作を行いません。
`TMUX` だけが残ってペインを特定できない場合も、cmux 側へ入力しません。
cmux の中で tmux を使うと cmux 側の操作はできず、tmux として動きます。
cmux CLI は `CMUX_BUNDLED_CLI_PATH`、`PATH`、macOS の標準インストール先の順に探します。

その他の端末の「承認待ち」は、Claude Code が数秒待って発行する `permission_prompt` を使います。
既存の登録が `idle_prompt` のみの場合は `setup.sh` を再実行するか、上記の matcher に変更してください。

## Antigravity CLI の承認中継

`setup.sh` は `~/.gemini` が存在するとき、`~/.gemini/config/hooks.json` の
`prompt-relay` に次の登録を追加します。既存の他の名前付き hook は保持します。
手動で設定する場合は、既存の `prompt-relay` オブジェクトへ追加してください。

```json
{
  "prompt-relay": {
    "PreToolUse": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "/path/to/prompt-relay/hook/permission-request.sh --agent agy", "timeout": 10}
      ]}
    ]
  }
}
```

PreToolUse は `matcher` と `hooks` で包む形式が必要です。`matcher: ""` で全ツールを対象にします。
handler を直接並べる旧形式は `setup.sh` の再実行で置き換わります。完了通知の
`PreInvocation` / `Stop` は [session モードの設定](session-idle.md) を参照してください。

| 起動環境 | Antigravity CLI の承認 |
|---|---|
| tmux | コマンド承認画面の4選択肢を転送し、選択番号1文字で回答 |
| cmux（tmux を使わず直接起動） | 同じ4選択肢を転送し、呼び出し元の surface に回答 |
| その他 | 中継・通知なし。端末で回答 |

`Command` と罫線の枠、`Requesting permission for:`、`Run this command?`、カーソル付きの4選択肢、
`↑/↓ Navigate · tab Amend · ctrl+g edit/expand command` のフッター全文が揃うコマンド承認画面に対応します。
1番は `Yes, run command`、4番は `No, cancel` の完全一致を要求し、異なるフッター・選択肢は中継しません。
`Allow access to this URL?`、`Allow calling this tool?`、`Reason:` 付きの画面は中継しません。
選択肢の下に通常の出力や入力行がある場合も中継しません。
画面本文と hook の `toolCall.args.CommandLine` を空白全除去で照合し、一致したコマンドだけを説明として登録します。
`CommandLine` がない場合、目印が複数ある場合、長いコマンドが省略表示されて全文と一致しない場合は中継しません。

hook は `{"decision":"allow"}` を1つ返して既定の承認判定に進み、
バックグラウンドで既定5秒まで画面を待ちます。この返却値でツール実行を承認するわけではなく、
スマホまたは端末からの回答は agy の承認画面で処理されます。
回答の送信直前に本文と選択肢を照合し、画面の消失・変更や読み取り失敗時にはキーを送りません。
空白は Claude Code と同じく指紋から除去するため、折り返しや字下げだけの変化は区別しません。
画面取得とキー送信は別操作のため、その間の画面変更を原子的に防ぐ保証はありません。

**既知の制約:**

- 画面全体を字下げした写しでも、本文がhookのコマンドと一致し、他の条件も揃うと本物の承認画面と区別できません。
- agyの強制終了後に承認画面が残り、同じ端末が無表示の入力待ちに切り替わると、残った画面への回答がその入力へ届く場合があります。

## フックの動作原理

### permission-request.sh（PreToolUse）

権限プロンプトの検出と応答転送を行います。

**動作フロー:**

1. `PreToolUse` は各ツール実行前に発火する（権限不要のツールでも発火）
2. フック本体は stdin を読み取り、バックグラウンドサブシェルを起動して即 `exit 0`
3. **フェーズ1（検出）**: バックグラウンドで tmux ペインまたは cmux surface をポーリングし、権限プロンプトの出現を検出
4. **フェーズ2（送信）**: 検出後、ペイン内容をパースしてサーバへ送信
5. **フェーズ3（応答待ち）**: サーバからの応答をポーリングし、端末へキーを送信
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

端末側で手動回答するとプロンプトが消えるため、バックグラウンドプロセスがこれを検知してサーバにキャンセルを送信します（SEEN_PROMPT パターン）。

### notification.sh（Notification / UserPromptSubmit / Stop）

処理完了などの通知を送信します。既定では Claude Code の `idle_prompt` と
Codex の `Stop` で通知します。session モードでは `UserPromptSubmit` で作業開始を記録し、
`Stop` で待機への移行を記録し、tmux セッションまたは cmux workspace 内の全エージェントが待機したときに 1 回だけ通知します
（[複数エージェントの完了通知をまとめる](session-idle.md)）。

### matcher について

- `PreToolUse` の `matcher` は空文字列（`""`）で全ツールにマッチさせます
- `Notification` の `matcher` は `"idle_prompt|permission_prompt"` で完了通知と承認待ち通知にマッチさせます

### 環境変数

承認の経路は既定で `${XDG_STATE_HOME:-$HOME/.local/state}/prompt-relay/hook.log` に記録します。
タブ区切りの時刻・hook 名・事象・backend・宛先・短い結果で、端末の拒否理由、キー送信の結果、
Codex の直接応答、通知だけになった場合を確認できます。承認本文・コマンド文字列・画面内容・API キーは記録しません。
承認を中継・回答・通知せずに終了した起動は記録しません。
`PROMPT_RELAY_LOG` で記録先を変更でき、`off` または空文字にすると停止します。
256 KB を超える前に `.1` へ1世代だけ回転します。記録先に書けなくても承認処理は続行します。
watcher / poller / skip の保存先は `PROMPT_RELAY_RUNTIME_DIR`（既定 `/tmp`）で変更できます。
保存先は自動作成し、作成できない場合は端末へキーを送りません。

フックスクリプトは以下の環境変数を参照します。

環境変数のほか、設定ファイル `~/.config/prompt-relay/config`（`PROMPT_RELAY_CONFIG` で変更可）にも
`KEY=VALUE` の形で 1 行に 1 項目ずつ書けます。先頭の `export` と、値を囲む引用符は省けます。
`PROMPT_RELAY_` で始まる項目だけを読み、同じ項目が環境変数にもある場合は環境変数を優先します。
環境変数はエージェントの起動時に受け継がれるので、起動経路によっては届きません。
設定ファイルはフックが実行のたびに読むため、起動経路に左右されません。

| 変数 | 説明 | デフォルト |
|---|---|---|
| `PROMPT_RELAY_SERVER_URL` | プライマリサーバURL | `http://localhost:3939` |
| `PROMPT_RELAY_SERVER_URL_2` | セカンダリサーバURL（オプション） | なし |
| `PROMPT_RELAY_API_KEY` | ルームキー（必須） | なし |
| `PROMPT_RELAY_API_KEY_2` | セカンダリ用ルームキー（オプション） | プライマリと同じ |
| `PROMPT_RELAY_TIMEOUT` | リクエストタイムアウト（秒）。サーバに送信され、リクエスト固有の期限として使用される | `120` |
| `PROMPT_RELAY_RUNTIME_DIR` | watcher / poller / skip の保存先 | `/tmp` |
| `PROMPT_RELAY_LOG` | 承認経路の記録先。`off` または空文字で停止 | `${XDG_STATE_HOME:-$HOME/.local/state}/prompt-relay/hook.log` |
| `PROMPT_RELAY_DETECT_INTERVAL` | プロンプト検出のポーリング間隔（秒） | `0.1` |
| `PROMPT_RELAY_DETECT_ATTEMPTS` | プロンプト検出の最大試行回数 | `10` |
| `PROMPT_RELAY_IDLE_SCOPE` | 待機通知の単位。`pane` または `session` | `pane` |
| `PROMPT_RELAY_IDLE_GRACE` | session モードで全体の待機を再判定するまでの秒数 | `5` |
| `PROMPT_RELAY_STATE_DIR` | 待機状態ファイルの保存先 | `/tmp/prompt-relay-state-<uid>` |

session モードの設定項目・hook の登録方法・判定の仕組みは
[複数エージェントの完了通知をまとめる](session-idle.md) を参照してください。
