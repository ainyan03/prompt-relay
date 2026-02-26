#!/bin/bash
# prompt-relay セットアップスクリプト
# Claude Code の hook 登録と環境変数の設定を自動で行います

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
PERMISSION_HOOK="$SCRIPT_DIR/hook/permission-request.sh"
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
  echo "  tmux がないと自動応答機能が使えません（通知の受信は可能）"
  echo ""
fi

# hook スクリプトに実行権限を付与
chmod +x "$PERMISSION_HOOK" "$NOTIFICATION_HOOK"

# --- 環境変数の対話式設定 ---

# シェル設定ファイルの判定
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
  SHELL_RC="$HOME/.zshrc"
else
  SHELL_RC="$HOME/.bashrc"
fi

echo "[1/3] 環境変数の設定"
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

echo "[2/3] Claude Code hook の登録"
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
  # 既に hook が登録されているかチェック
  EXISTING_PRE=$(jq -r '.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | .command' "$CLAUDE_SETTINGS" 2>/dev/null)

  if echo "$EXISTING_PRE" | grep -q "permission-request.sh"; then
    echo "  PreToolUse hook は既に登録されています — スキップ"
  else
    # hooks セクションをマージ
    MERGED=$(jq --argjson new_hooks "$HOOKS_JSON" '
      .hooks = (
        (.hooks // {}) * {PreToolUse: $new_hooks.PreToolUse, Notification: $new_hooks.Notification}
      )
    ' "$CLAUDE_SETTINGS")
    echo "$MERGED" | jq . > "$CLAUDE_SETTINGS"
    echo "  hook を登録しました"
  fi
fi

# --- 完了 ---

echo ""
echo "[3/3] セットアップ完了"
echo ""
echo "  Hook スクリプト:"
echo "    PreToolUse:   $PERMISSION_HOOK"
echo "    Notification: $NOTIFICATION_HOOK"
echo ""
echo "  設定ファイル:"
echo "    $CLAUDE_SETTINGS"
echo "    $SHELL_RC"
echo ""
echo "  次のステップ:"
echo "    1. source $SHELL_RC"
echo "    2. Claude Code を再起動"
echo "    3. アプリでサーバ URL とルームキーを設定"
echo ""
