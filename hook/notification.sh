#!/bin/bash
# Claude Code Notification / Codex Stop フック
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

# デバッグ: /tmp/prompt-relay-debug が存在する場合、hook 入力をそこに追記する
[ -f /tmp/prompt-relay-debug ] && printf '%s\n' "$INPUT" >> /tmp/prompt-relay-debug 2>/dev/null

# イベント種別を判定（idle_prompt / permission_prompt 等）
# 種別フィールドは Claude Code のバージョンにより異なるため複数候補を参照する。
# いずれも無い場合は、本フックが matcher "idle_prompt" で登録されている前提で
# idle_prompt とみなす（JSON パース失敗時のみ空を返して送信を抑止）。
HOOK_EVENT=$(/usr/bin/env python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
print(d.get('hook_event_name') or d.get('notification_type') or d.get('tool_name') or 'idle_prompt')
" 2>/dev/null <<< "$INPUT")

# Codex は tmux 外でも動くため、セッション ID を通知のまとめ先に使う。
CODEX_SESSION=""
CODEX_TURN=""
if [ "$HOOK_EVENT" = "Stop" ]; then
  CODEX_IDS=$(/usr/bin/env python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('session_id') or '') + '|' + (d.get('turn_id') or ''))
except Exception:
    pass
" 2>/dev/null <<< "$INPUT")
  IFS='|' read -r CODEX_SESSION CODEX_TURN <<< "$CODEX_IDS"
  [ -n "$CODEX_SESSION" ] && TMUX_TARGET_ID="${HOSTNAME_SHORT}:codex:${CODEX_SESSION}"
fi

EVENT_ID=""
if [ -z "$HOOK_EVENT" ] || [ "$HOOK_EVENT" = "permission_prompt" ]; then
  # permission_prompt は permission-request.sh で処理されるため、ここでは無視
  # /notify は category なしでボタンなし通知になり、承認操作ができない
  # HOOK_EVENT が空の場合は JSON パース失敗のため送信しない
  exit 0
elif [ "$HOOK_EVENT" = "idle_prompt" ]; then
  TITLE="Done"
  MESSAGE="処理が完了しました"
elif [ "$HOOK_EVENT" = "Stop" ]; then
  # Stop は「タスク全体」ではなく1ターンの終了時に発火する。Codexの
  # 公開 thread/goal/get API で永続goalを確認し、中間ターンは通知しない。
  GOAL_STATUS="unknown"
  GOAL_UPDATED_AT=""
  if [ "${PROMPT_RELAY_CODEX_GOAL_AWARE:-true}" != "false" ] && [ -n "$CODEX_SESSION" ]; then
    GOAL_INFO=$(/usr/bin/env python3 "${SCRIPT_DIR}/codex_goal_status.py" "$CODEX_SESSION" 2>/dev/null)
    IFS='|' read -r GOAL_STATUS GOAL_UPDATED_AT <<< "$GOAL_INFO"
  fi

  case "$GOAL_STATUS" in
    active)
      # Codexが次のgoalターンを自動開始するため、完了通知を送らない。
      exit 0
      ;;
    complete)
      TITLE="Done"
      MESSAGE="タスクが完了しました"
      ;;
    blocked)
      TITLE="Codex"
      MESSAGE="タスクがブロックされました"
      ;;
    paused)
      TITLE="Codex"
      MESSAGE="タスクが一時停止しました"
      ;;
    usage_limited)
      TITLE="Codex"
      MESSAGE="利用上限によりタスクが停止しました"
      ;;
    budget_limited)
      TITLE="Codex"
      MESSAGE="トークン予算に達してタスクが停止しました"
      ;;
    *)
      TITLE="Codex"
      MESSAGE="ターンが完了しました"
      ;;
  esac

  if [ "$GOAL_STATUS" = "complete" ] || [ "$GOAL_STATUS" = "blocked" ] || \
     [ "$GOAL_STATUS" = "paused" ] || [ "$GOAL_STATUS" = "usage_limited" ] || \
     [ "$GOAL_STATUS" = "budget_limited" ]; then
    EVENT_ID="codex-goal:${CODEX_SESSION}:${GOAL_STATUS}:${GOAL_UPDATED_AT:-unknown}"
  elif [ -n "$CODEX_TURN" ]; then
    EVENT_ID="codex-turn:${CODEX_SESSION}:${CODEX_TURN}"
  fi
else
  if [[ "$HOOK_EVENT" == *Codex* ]]; then
    TITLE="Codex"
  else
    TITLE="Claude Code"
  fi
  MESSAGE="${HOOK_EVENT}"
fi

# JSON エスケープを Python で安全に構築
NOTIFY_BODY=$(/usr/bin/env python3 -c "
import json,sys
print(json.dumps({
    'title': sys.argv[1],
    'message': sys.argv[2],
    'hostname': sys.argv[3],
    **({'tmux_target': sys.argv[4]} if len(sys.argv) > 4 and sys.argv[4] else {}),
    **({'event_id': sys.argv[5]} if len(sys.argv) > 5 and sys.argv[5] else {})
}))
" "$TITLE" "$MESSAGE" "$DISPLAY_HOST" "$TMUX_TARGET_ID" "$EVENT_ID")

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
