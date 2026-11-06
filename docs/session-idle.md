# 複数エージェントの完了通知をまとめる（session モード）

1 つの tmux セッションの中で、複数のエージェント（Claude Code / Codex / Antigravity CLI）を
別々のウィンドウやペインで同時に動かす使い方向けの機能です。

- **既定（pane モード）**: エージェントごとに、待機に入ったら個別に完了通知を送ります。
  あるエージェントが待機しても、別のエージェントがまだ作業中のことがあります
- **session モード**: tmux セッション内の全エージェントが待機したときだけ、完了通知を 1 回送ります

承認・質問プロンプトの通知は、どちらのモードでも従来どおり即時に届きます。session モードが変えるのは完了通知だけです。

## 用語

| 用語 | 意味 |
|---|---|
| tmux セッション | `tmux new-session -s <名前>` で作る作業単位。中に複数のウィンドウ（タブ）を持つ |
| ペイン | ウィンドウ内の区画。エージェント 1 体が 1 つのペインで動く |

session モードは tmux セッション単位で集計します。別々のプロジェクトを同時に進める場合は、tmux セッションを分けてください。

## 有効にする

1. 設定ファイル `~/.config/prompt-relay/config` に追加します

   ```bash
   mkdir -p ~/.config/prompt-relay
   echo 'PROMPT_RELAY_IDLE_SCOPE=session' >> ~/.config/prompt-relay/config
   ```

2. `setup.sh` を再実行して、session モード用の hook を登録します（既存の hook は保持されます）
3. Codex では `/hooks` を開き、追加された hook を信頼します

設定ファイルは hook が実行のたびに読むので、起動済みのエージェントにもすぐ効きます。

シェル設定（`~/.zshrc` など）に `export PROMPT_RELAY_IDLE_SCOPE=session` と書いても有効になります。
ただし環境変数はエージェントの起動時に受け継がれるため、設定前に開いたシェルから起動したエージェントや、
シェル設定を読まずに起動したエージェント（`tmux new-window` でコマンドを直接起動する等）には届きません。
エージェントの起動を他のツールに任せる場合は、設定ファイルを使ってください。

### 手動で登録する場合

Claude Code（`~/.claude/settings.json` の `hooks` に追加）:

```json
"UserPromptSubmit": [
  {"hooks": [{"type": "command", "command": "/path/to/prompt-relay/hook/notification.sh --agent claude", "timeout": 10}]}
],
"Stop": [
  {"hooks": [{"type": "command", "command": "/path/to/prompt-relay/hook/notification.sh --agent claude", "timeout": 10}]}
]
```

Codex（`~/.codex/hooks.json` の `hooks` に追加。`Stop` は既存の登録をそのまま使えます）:

```json
"UserPromptSubmit": [
  {"hooks": [{"type": "command", "command": "/path/to/prompt-relay/hook/notification.sh --agent codex", "timeout": 10}]}
]
```

Antigravity CLI（`~/.gemini/config/hooks.json` に名前付き hook として追加。
`PreInvocation` / `Stop` は matcher を使わないフラットな配列です）:

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

Antigravity CLI は session モードの集計にだけ参加します。pane モードでは通知せず、権限確認プロンプトの中継にも対応していません。

## 設定項目

いずれも設定ファイルにも書けます。同じ項目が環境変数にもある場合は、環境変数を優先します。

| 変数 | 説明 | 既定 |
|---|---|---|
| `PROMPT_RELAY_IDLE_SCOPE` | `pane` または `session` | `pane` |
| `PROMPT_RELAY_IDLE_GRACE` | 全員が待機してから通知するまでの猶予（秒） | `5` |
| `PROMPT_RELAY_STATE_DIR` | 待機状態ファイルの保存先 | `/tmp/prompt-relay-state-<uid>` |

## 判定の仕組み

各エージェントは、自分のペインの状態を「作業中」「待機」として記録します。

| | 作業開始（作業中にする） | 作業停止（待機にする） |
|---|---|---|
| Claude Code | `UserPromptSubmit` | `Stop` |
| Codex | `UserPromptSubmit` | `Stop`（goal が `active` の間は作業中のまま） |
| Antigravity CLI | `PreInvocation` | `Stop` |

- エージェントが待機に入ると、猶予秒数のあとにセッション全体を判定します
- 判定時点で、状態を記録したことのあるペインのうち実在するもの全てが待機なら、1 回だけ通知します。閉じたペインの状態は無視します
- 猶予の間に別のエージェントが作業を始めれば、通知しません。あるエージェントが別のエージェントへ作業を依頼して待機に入るときに、受け手が作業を始めるまでの数秒の空白を吸収するための猶予です
- 待機の判定はターンの終了で行い、バックグラウンドで動いている処理は見ません
- tmux の外で動いているエージェントは、従来どおりペイン単位で通知します

### 通知の内容

- 通常: 「Done / 全エージェントの処理が完了しました」
- Codex の goal がブロック・一時停止・利用上限・トークン予算で止まった場合は、その理由を示す文面のまま通知します
- 通知はセッション単位で上書きされます（送信元の表示は `<ホスト名>:<tmux セッション名>`）

## 既知の制約

- **Esc で中断したエージェント**: 中断では `Stop` が発火しないため、次のターンが終わるまで作業中のまま残り、その間はセッションの完了通知が出ません
- **バックグラウンドで処理を続けるエージェント**: ターンを終えた時点で待機として数えるため、早めに通知されることがあります。処理の完了で次のターンが始まれば作業中に戻ります
- **猶予より長い受け渡し**: 依頼を受けたエージェントが猶予秒数以内に作業を始めない場合（受信の仕組みが止まっていて起こされるのを待っている等）、早めに 1 回通知されます。頻繁に起きる場合は `PROMPT_RELAY_IDLE_GRACE` を 8〜10 秒程度に上げてください
