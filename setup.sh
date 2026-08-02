#!/bin/bash
# prompt-relay セットアップスクリプト
# Claude Code / Codex の hook 登録と環境変数の設定を自動で行います

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
PERMISSION_HOOK="$SCRIPT_DIR/hook/permission-request.sh"
CODEX_PERMISSION_HOOK="$SCRIPT_DIR/hook/codex-permission-request.sh"
NOTIFICATION_HOOK="$SCRIPT_DIR/hook/notification.sh"

echo "=== prompt-relay セットアップ ==="
echo ""

# --- 前提確認 ---

if ! command -v jq &>/dev/null; then
  echo "エラー: jq がインストールされていません"
  echo "  macOS: brew install jq"
  echo "  Ubuntu/Debian: sudo apt install jq"
  exit 1
fi

if ! command -v tmux &>/dev/null; then
  echo "警告: tmux がインストールされていません"
  echo "  Claude Code の自動応答には tmux が必要です（Codex は tmux 不要）"
  echo ""
fi

# hook スクリプトに実行権限を付与
chmod +x "$PERMISSION_HOOK" "$CODEX_PERMISSION_HOOK" "$NOTIFICATION_HOOK"

# --- 環境変数の対話式設定 ---

# シェル設定ファイルの判定
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
  SHELL_RC="$HOME/.zshrc"
else
  SHELL_RC="$HOME/.bashrc"
fi

echo "[1/4] 環境変数の設定"
echo ""

# SERVER_URL
CURRENT_SERVER_URL=""
if grep -q "^export PROMPT_RELAY_SERVER_URL" "$SHELL_RC" 2>/dev/null; then
  CURRENT_SERVER_URL=$(grep "^export PROMPT_RELAY_SERVER_URL" "$SHELL_RC" | sed 's/^export PROMPT_RELAY_SERVER_URL=//')
  echo "  PROMPT_RELAY_SERVER_URL は既に設定されています: $CURRENT_SERVER_URL"
  read -p "  上書きしますか？ [y/N]: " OVERWRITE_URL
  if [ "$OVERWRITE_URL" != "y" ] && [ "$OVERWRITE_URL" != "Y" ]; then
    echo "  スキップしました"
    echo ""
  else
    read -p "  サーバURL [http://localhost:3939]: " INPUT_URL
    INPUT_URL="${INPUT_URL:-http://localhost:3939}"
    sed -i.bak "/PROMPT_RELAY_SERVER_URL/d" "$SHELL_RC"
    rm -f "${SHELL_RC}.bak"
    echo "export PROMPT_RELAY_SERVER_URL=\"${INPUT_URL}\"" >> "$SHELL_RC"
    echo "  設定しました: $INPUT_URL"
    echo ""
  fi
else
  read -p "  サーバURL [http://localhost:3939]: " INPUT_URL
  INPUT_URL="${INPUT_URL:-http://localhost:3939}"
  echo "" >> "$SHELL_RC"
  echo "# prompt-relay" >> "$SHELL_RC"
  echo "export PROMPT_RELAY_SERVER_URL=\"${INPUT_URL}\"" >> "$SHELL_RC"
  echo "  設定しました: $INPUT_URL"
  echo ""
fi

# API_KEY (ルームキー)
echo "  ルームキー: 任意の文字列を決めて入力してください（8〜128文字）"
echo "  同じキーを設定したデバイス同士がデータを共有します"
if grep -q "^export PROMPT_RELAY_API_KEY" "$SHELL_RC" 2>/dev/null; then
  echo "  PROMPT_RELAY_API_KEY は既に設定されています"
  read -p "  上書きしますか？ [y/N]: " OVERWRITE_KEY
  if [ "$OVERWRITE_KEY" != "y" ] && [ "$OVERWRITE_KEY" != "Y" ]; then
    echo "  スキップしました"
    echo ""
  else
    read -p "  ルームキー (空欄でスキップ): " INPUT_KEY
    if [ -n "$INPUT_KEY" ]; then
      sed -i.bak "/PROMPT_RELAY_API_KEY/d" "$SHELL_RC"
      rm -f "${SHELL_RC}.bak"
      echo "export PROMPT_RELAY_API_KEY=\"${INPUT_KEY}\"" >> "$SHELL_RC"
      echo "  設定しました"
    else
      echo "  スキップしました"
    fi
    echo ""
  fi
else
  read -p "  ルームキー (空欄でスキップ): " INPUT_KEY
  if [ -n "$INPUT_KEY" ]; then
    # prompt-relay ヘッダがまだなければ追加しない（SERVER_URLで追加済み）
    echo "export PROMPT_RELAY_API_KEY=\"${INPUT_KEY}\"" >> "$SHELL_RC"
    echo "  設定しました"
  else
    echo "  スキップしました（注意: ルームキーは必須です。後で PROMPT_RELAY_API_KEY を設定してください）"
  fi
  echo ""
fi

# --- Claude Code settings.json への hook マージ ---

echo "[2/4] Claude Code hook の登録"
echo ""

mkdir -p "$HOME/.claude"

# 新しい hooks 設定を生成
# - PreToolUse: 権限プロンプトの即時検出・転送（全ツール実行前に発火）
# - Notification: アイドル状態の通知
HOOKS_JSON=$(cat <<HOOKS_EOF
{
  "PreToolUse": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "$PERMISSION_HOOK",
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
          "command": "$NOTIFICATION_HOOK",
          "timeout": 10
        }
      ]
    }
  ]
}
HOOKS_EOF
)

if [ ! -f "$CLAUDE_SETTINGS" ]; then
  # settings.json が存在しない場合は新規作成
  echo "{\"hooks\": $HOOKS_JSON}" | jq . > "$CLAUDE_SETTINGS"
  echo "  $CLAUDE_SETTINGS を新規作成しました"
else
  # 既存 hook を保持し、prompt-relay の不足分だけを追加する。
  MERGED=$(jq --argjson new_hooks "$HOOKS_JSON" \
    --arg permission "$PERMISSION_HOOK" --arg notification "$NOTIFICATION_HOOK" '
    .hooks = (.hooks // {}) |
    .hooks.PreToolUse = (.hooks.PreToolUse // []) |
    .hooks.Notification = (.hooks.Notification // []) |
    (if any(.hooks.PreToolUse[]?.hooks[]?; .command == $permission) then .
     else .hooks.PreToolUse += $new_hooks.PreToolUse end) |
    (if any(.hooks.Notification[]?.hooks[]?; .command == $notification) then .
     else .hooks.Notification += $new_hooks.Notification end)
  ' "$CLAUDE_SETTINGS")
  echo "$MERGED" | jq . > "$CLAUDE_SETTINGS"
  echo "  hook を登録・確認しました"
fi

# --- Codex hooks.json への hook マージ ---

echo ""
echo "[3/4] Codex hook の登録"
echo ""

mkdir -p "$HOME/.codex"

CODEX_HOOKS_JSON=$(cat <<HOOKS_EOF
{
  "PermissionRequest": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "$CODEX_PERMISSION_HOOK",
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
          "command": "$NOTIFICATION_HOOK",
          "timeout": 10
        }
      ]
    }
  ]
}
HOOKS_EOF
)

if [ ! -f "$CODEX_HOOKS" ]; then
  echo "{\"hooks\": $CODEX_HOOKS_JSON}" | jq . > "$CODEX_HOOKS"
  echo "  $CODEX_HOOKS を新規作成しました"
else
  MERGED=$(jq --argjson new_hooks "$CODEX_HOOKS_JSON" \
    --arg permission "$CODEX_PERMISSION_HOOK" --arg notification "$NOTIFICATION_HOOK" '
    .hooks = (.hooks // {}) |
    .hooks.PermissionRequest = (.hooks.PermissionRequest // []) |
    .hooks.Stop = (.hooks.Stop // []) |
    (if any(.hooks.PermissionRequest[]?.hooks[]?; .command == $permission) then .
     else .hooks.PermissionRequest += $new_hooks.PermissionRequest end) |
    (if any(.hooks.Stop[]?.hooks[]?; .command == $notification) then .
     else .hooks.Stop += $new_hooks.Stop end)
  ' "$CODEX_HOOKS")
  echo "$MERGED" | jq . > "$CODEX_HOOKS"
  echo "  hook を登録・確認しました"
fi

# --- 完了 ---

echo ""
echo "[4/4] セットアップ完了"
echo ""
echo "  Hook スクリプト:"
echo "    Claude PreToolUse:      $PERMISSION_HOOK"
echo "    Codex PermissionRequest: $CODEX_PERMISSION_HOOK"
echo "    完了通知:                $NOTIFICATION_HOOK"
echo ""
echo "  設定ファイル:"
echo "    $CLAUDE_SETTINGS"
echo "    $CODEX_HOOKS"
echo "    $SHELL_RC"
echo ""
echo "  次のステップ:"
echo "    1. source $SHELL_RC"
echo "    2. Claude Code / Codex を再起動"
echo "    3. Codex では /hooks を開いて新しい hook を確認・信頼"
echo "    4. アプリでサーバ URL とルームキーを設定"
echo ""
