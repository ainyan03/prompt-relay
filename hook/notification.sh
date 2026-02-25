#!/bin/bash
# Claude Code Notification フック（idle_prompt 等）
# 単純な通知をローカルサーバ経由で送信

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# tmux ペイン識別子（collapse-id 用）
TMUX_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
TMUX_TARGET_ID=""
if [ -n "$TMUX_PANE" ]; then
  TMUX_TARGET_ID="${HOSTNAME_SHORT}:${TMUX_PANE}"
fi

INPUT=$(cat) # stdin から Notification フックの JSON データを読み取り

# tool_name フィールドでイベント種別を判定（idle_prompt / permission_prompt 等）
HOOK_EVENT=$(/usr/bin/env python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null <<< "$INPUT")

if [ -z "$HOOK_EVENT" ] || [ "$HOOK_EVENT" = "permission_prompt" ]; then
  # permission_prompt は permission-request.sh で処理されるため、ここでは無視
  # /notify は category なしでボタンなし通知になり、承認操作ができない
  # HOOK_EVENT が空の場合も JSON パース失敗のため送信しない
  exit 0
elif [ "$HOOK_EVENT" = "idle_prompt" ]; then
  TITLE="Done"
  MESSAGE="処理が完了しました"
else
  TITLE="Claude Code"
  MESSAGE="${HOOK_EVENT}"
fi

# JSON エスケープを Python で安全に構築
NOTIFY_BODY=$(/usr/bin/env python3 -c "
import json,sys
print(json.dumps({
    'title': sys.argv[1],
    'message': sys.argv[2],
    'hostname': sys.argv[3],
    **({'tmux_target': sys.argv[4]} if len(sys.argv) > 4 and sys.argv[4] else {})
}))
" "$TITLE" "$MESSAGE" "$DISPLAY_HOST" "$TMUX_TARGET_ID")

curl -s --connect-timeout 3 -X POST "${SERVER_URL}/notify" \
  -H "Content-Type: application/json" \
  "${CURL_AUTH[@]}" \
  -d "$NOTIFY_BODY" > /dev/null 2>&1

# セカンダリサーバにも送信（設定されている場合）
if [ -n "$SERVER_URL_2" ]; then
  curl -s --connect-timeout 3 -X POST "${SERVER_URL_2}/notify" \
    -H "Content-Type: application/json" \
    "${CURL_AUTH_2[@]}" \
    -d "$NOTIFY_BODY" > /dev/null 2>&1 &
fi

exit 0
