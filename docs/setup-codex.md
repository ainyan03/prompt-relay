# Codex フック設定

Codex は `PermissionRequest` lifecycle hook から構造化された承認要求を受け取れます。prompt-relayは実行環境に応じて、標準TUIとスマホを併用するtmux / cmuxハイブリッド、または構造化hook応答を使う直接応答を自動選択します。

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

Codexをtmux内で起動するか、cmuxでtmuxを使わず直接起動します。
cmuxの中でtmuxを使うとcmux側の操作はできず、tmuxとして動きます。

```bash
tmux new-session -s codex
codex --no-daemon
```

素の `codex` は共有の常駐サービス経由で動作する場合があり、その場合は hook に
呼び出し元の端末情報が届きません。常駐サービスが起動元の `TMUX_PANE` を引き継いでも、
そのペインのプロセスが hook の祖先でなければキーを送りません。tmux / cmux とも、祖先に
制御端末のない `codex` 実行ファイルのプロセスがある場合や、制御端末を持つ祖先が1つもない場合は画面操作を無効化します。`auto` モードでは、スマホの回答を
hook が直接返す形になります。プロセス情報や tmux の問い合わせに失敗した場合も画面操作しません。
tmux では回答を送る直前にペインのプロセス番号と端末を取り直し、確認時と違えば送りません。
既知の制約: 回答を待つ間にペインが作り直され、プロセス番号と端末の番号が両方とも同じ値で再利用され、
同じ承認画面が出ている場合は区別できません。cmux には surface とプロセスを結ぶ手段が無いため、
祖先の確認は常駐サービスの判定だけです。

tmux / cmux で承認画面への中継を使う場合は `--no-daemon` を付けて起動してください。
引き換えに、画面を閉じた後もスレッドを続行する機能など、共有の常駐サービスに依存する機能が使えなくなります。
必要なら、シェルの設定へ次の関数を手動で追加できます。引数なし・オプションだけ・最初の指示付き・
`resume` / `fork` の対話起動にだけ付加します（サブコマンドの一覧は `codex --help` に合わせてください）。値を取る未列挙のオプションは `--名前=値` 形式で指定してください。

```bash
codex() {
  local arg takes_value=no interactive=yes
  for arg in "$@"; do
    if [ "$takes_value" = yes ]; then takes_value=no; continue; fi
    case "$arg" in
      -c|--config|-m|--model|-p|--profile|-s|--sandbox|-a|--ask-for-approval|-C|--cd|--add-dir|--enable|--disable|-i|--image)
        takes_value=yes ;;
      --) interactive=no; break ;;
      -*) ;;
      resume|fork) break ;;
      agents|exec|e|review|login|logout|mcp|plugin|app-server|remote-control|app|completion|update|doctor|\
      sandbox|debug|apply|a|queue|archive|delete|migrate-*|unarchive|cloud|exec-server|features|help)
        interactive=no; break ;;
      *) break ;;  # 最初の指示を付けた対話起動
    esac
  done
  if [ "$interactive" = yes ] && [ -n "${TMUX:-}${CMUX_SURFACE_ID:-}" ]; then
    command codex --no-daemon "$@"
  else
    command codex "$@"
  fi
}
```

`--no-daemon` はサブコマンドより前に置きます。`codex exec --no-daemon` は受け付けられないため、
この関数は `exec` などのサブコマンドへオプションを追加しません。`setup.sh` はこの関数を自動登録しません。

既定の `auto` モードはtmux / cmuxを検出すると、次のように動作します。

1. `PermissionRequest` hookはポーラーをバックグラウンド化し、決定を返さず即終了
2. Automatic approvalで承認された場合は、TUIもスマホ通知も表示しない
3. Codex標準TUIに承認選択肢が実際に表示された場合だけ、サーバへ要求を登録してスマホへ通知
4. TUIで回答した場合はスマホ側リクエストをキャンセル
5. スマホで回答した場合は、選択した番号をTUIに表示されたショートカット（例: `y` / `p` / `esc`）へ変換して端末へ入力

Codex TUIが `Yes, proceed`、`Yes, and don't ask again ...`、`No ...` の3択を表示した場合、スマホにも同じ3択を表示します。2番目を選ぶとTUIへ `p` を送り、そのコマンド接頭辞を以後確認しない選択として処理されます。

`auto` では cmux の CLI やソケットが使えず最初の画面取得に失敗した場合も、直接応答に切り替わります。
`tmux` モードでは中継せず終了します。

## 画面操作できない端末の直接応答

1. Codex が承認を必要とする直前に `PermissionRequest` hook を起動
2. hook の stdin から `tool_name`、`tool_input`、セッション情報を取得
3. サーバへ承認要求を作成し、スマートフォンへ通知
4. スマートフォンの Allow / Deny をポーリング
5. 回答があれば Codex 仕様の decision JSON を stdout へ返す
6. 接続失敗または `PROMPT_RELAY_TIMEOUT` 経過時は空出力で終了し、Codex標準の承認画面を表示

`Stop` hook はターン完了時の通知に使います。Codexの永続goalがある場合は、
`codex app-server` の公開 `thread/goal/get` APIで状態を確認します。

- `active`: 自動継続中なので通知しない
- `complete`: 「タスクが完了しました」と通知
- `blocked` / `paused` / `usageLimited` / `budgetLimited`: 停止理由を通知
- goalなし、またはAPIを利用できない場合: 「ターンが完了しました」と通知

同じgoal状態から複数回`Stop`が発火しても、`event_id`によってサーバ側で重複配信を抑止します。

1 つの tmux セッションまたは cmux workspace で複数のエージェントを動かし、全員の完了時にだけ通知したい場合は、
`UserPromptSubmit` hook も登録して session モードを使います
（[複数エージェントの完了通知をまとめる](session-idle.md)）。

## モード設定

`PROMPT_RELAY_CODEX_MODE` で動作を固定できます。

| 値 | 動作 |
|---|---|
| `auto` | 既定。tmux / cmux内はハイブリッド、それ以外は直接応答 |
| `tmux` | 画面操作できる端末（tmux / cmux）でハイブリッド。それ以外では中継しない |
| `direct` | 常に構造化hook応答。tmux / cmux内でも待機中はTUIを表示しない |

例:

```bash
export PROMPT_RELAY_CODEX_MODE=auto
```

完了通知のgoal判定は既定で有効です。問題の切り分けなどで無効にする場合は
`PROMPT_RELAY_CODEX_GOAL_AWARE=false`を設定します。無効時もタスク完了とは断定せず、
「ターンが完了しました」と通知します。

`codex`が通常の`PATH`にない環境では`PROMPT_RELAY_CODEX_BIN`に実行ファイルの絶対パスを、
goal照会のタイムアウトを変更する場合は`PROMPT_RELAY_CODEX_GOAL_QUERY_TIMEOUT`に秒数
（0.5〜8、既定4）を指定できます。

## 注意事項

- 直接応答の allow / deny と端末へのキー送信の結果は[承認経路の記録](setup-hooks.md#環境変数)で確認できます。
- 画面操作できない端末の直接応答モードでは、リモート回答を待っている間はCodex標準の承認画面がまだ表示されません。
- tmux / cmuxハイブリッドではTUIが即時表示され、`PROMPT_RELAY_TIMEOUT` はスマホ側リクエストの有効時間になります。
- `PROMPT_RELAY_CODEX_DETECT_TIMEOUT` はTUI表示を待つ秒数です（既定30秒）。TUIが出なければAutomatic approval済みとして通知しません。
- 画面操作できない端末の直接応答モードではTUIを観測できないため、Automatic approval対象かどうかを事前判定できません。自動承認の通知抑止にはtmux / cmuxハイブリッドを使用してください。
- Codex の hook はユーザー設定の `~/.codex/hooks.json` に登録します。プロジェクトローカル hook と違い、各リポジトリへ設定を複製する必要はありません。
- hooks を明示的に無効化している場合は、`~/.codex/config.toml` の `[features]` で `hooks = true` にしてください。
- goal照会は読み取り専用APIを使用し、Codex内部のSQLiteファイルやスキーマには依存しません。

Codex hook の仕様は [OpenAI の Hooks ドキュメント](https://learn.chatgpt.com/docs/hooks) を参照してください。
