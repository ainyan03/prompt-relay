#!/bin/bash
# Codex PermissionRequest hook
#
# auto（既定）:
#   tmux / cmux 内では即終了し、実際に標準 TUI が表示された要求だけをスマホへ転送する。
#   画面操作できる端末の外ではスマホ応答を待ち、Codex の allow / deny JSON を直接返す。
# direct: 常に構造化 hook 応答を返す（画面操作不要、待機中は TUI 非表示）。
# tmux:   画面操作できる端末を必須とし、その外では何もしない。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_LOG_AGENT=codex
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${PROMPT_RELAY_TIMEOUT:-120}"
POLL_INTERVAL="${PROMPT_RELAY_POLL_INTERVAL:-1}"
PROMPT_DETECT_TIMEOUT="${PROMPT_RELAY_CODEX_DETECT_TIMEOUT:-30}"
CODEX_MODE="${PROMPT_RELAY_CODEX_MODE:-auto}"
PARSER="${SCRIPT_DIR}/prompt_parser.py"
INPUT=$(cat)

HYBRID=false
case "$CODEX_MODE" in
  auto) [ -n "$TERM_TARGET_ID" ] && HYBRID=true ;;
  tmux)
    # Keep the mode name for compatibility; cmux also supports screen transport.
    [ -z "$TERM_TARGET_ID" ] && exit 0
    HYBRID=true
    ;;
  direct) ;;
  *)
    echo "[prompt-relay] WARNING: PROMPT_RELAY_CODEX_MODE は auto/direct/tmux のいずれかを指定してください" >&2
    [ -n "$TERM_TARGET_ID" ] && HYBRID=true
    ;;
esac
# Probe only on a permission event, before detaching. Auto mode retains the
# direct-response path when the cmux socket or CLI is unavailable.
if [ "$HYBRID" = true ] && [ "$TERM_BACKEND" = cmux ]; then
  if ! term_capture >/dev/null; then
    [ "$CODEX_MODE" = tmux ] && exit 0
    HYBRID=false
  fi
fi
PAYLOAD_TARGET=""
[ "$HYBRID" = true ] && PAYLOAD_TARGET="$TERM_TARGET_ID"

[ "$HYBRID" = true ] || term_display_host
PAYLOAD=$(/usr/bin/env python3 "$PARSER" codex-parse \
  "$INPUT" "$DISPLAY_HOST" "$TIMEOUT" "$PAYLOAD_TARGET" 2>/dev/null)
[ -z "$PAYLOAD" ] && exit 0

REQUEST_ID=""
REQUEST_ID_2=""

cancel_requests() {
  if [ -n "$REQUEST_ID" ]; then
    curl -s --connect-timeout 3 -X POST "${CURL_AUTH[@]}" \
      "${SERVER_URL}/permission-request/${REQUEST_ID}/cancel" >/dev/null 2>&1 || true
  fi
  if [ -n "$SERVER_URL_2" ] && [ -n "$REQUEST_ID_2" ]; then
    curl -s --connect-timeout 3 -X POST "${CURL_AUTH_2[@]}" \
      "${SERVER_URL_2}/permission-request/${REQUEST_ID_2}/cancel" >/dev/null 2>&1 || true
  fi
}

post_request() {
  local url="$1"
  shift
  curl -s --connect-timeout 3 --max-time 5 -X POST "${url}/permission-request" \
    -H "Content-Type: application/json" "$@" -d "$PAYLOAD" 2>/dev/null
}

parse_response() {
  /usr/bin/env python3 "$PARSER" response "$1" 2>/dev/null
}

poll_response() {
  local parsed="none||"
  local status="none"
  local result=""
  if [ -n "$REQUEST_ID" ]; then
    result=$(curl -s --connect-timeout 3 --max-time 5 "${CURL_AUTH[@]}" \
      "${SERVER_URL}/permission-request/${REQUEST_ID}/response" 2>/dev/null)
    parsed=$(parse_response "$result")
    status="${parsed%%|*}"
  fi
  if [ "$status" = "none" ] && [ -n "$SERVER_URL_2" ] && [ -n "$REQUEST_ID_2" ]; then
    result=$(curl -s --connect-timeout 3 --max-time 5 "${CURL_AUTH_2[@]}" \
      "${SERVER_URL_2}/permission-request/${REQUEST_ID_2}/response" 2>/dev/null)
    parsed=$(parse_response "$result")
  fi
  printf '%s' "$parsed"
}

register_requests() {
  local response=""
  response=$(post_request "$SERVER_URL" "${CURL_AUTH[@]}")
  REQUEST_ID=$(/usr/bin/env python3 -c \
    'import json,sys; print(json.loads(sys.argv[1]).get("id", ""))' "$response" 2>/dev/null)

  if [ -n "$SERVER_URL_2" ]; then
    response=$(post_request "$SERVER_URL_2" "${CURL_AUTH_2[@]}")
    REQUEST_ID_2=$(/usr/bin/env python3 -c \
      'import json,sys; print(json.loads(sys.argv[1]).get("id", ""))' "$response" 2>/dev/null)
  fi
}

if [ "$HYBRID" = "true" ]; then
  runtime_prepare || exit 0
  # hook 本体の stdout/stderr を保持すると Codex が EOF を待つため、完全に切り離す。
  (
    _SAFE_TARGET="${PAYLOAD_TARGET//[:.]/_}"
    POLLER_FILE="${PROMPT_RELAY_RUNTIME_DIR}/prompt-relay-${_SAFE_TARGET}.codex-poller"
    _MY_PID=$(sh -c 'echo $PPID')
    echo "$_MY_PID" > "$POLLER_FILE" || exit 0
    trap 'if [ "$(cat "$POLLER_FILE" 2>/dev/null)" = "$_MY_PID" ]; then rm -f "$POLLER_FILE"; fi' EXIT

    # PermissionRequest hook の後にAutomatic approvalが実行される。実際にTUIが
    # 表示されるまでサーバ登録を遅らせ、自動承認された要求の通知を抑止する。
    DETECT_DEADLINE=$(( $(date +%s) + PROMPT_DETECT_TIMEOUT ))
    PROMPT_VISIBLE="no"
    while [ "$(date +%s)" -lt "$DETECT_DEADLINE" ]; do
      [ "$(cat "$POLLER_FILE" 2>/dev/null)" != "$_MY_PID" ] && exit 0
      # -Jで端末幅による物理折り返しを元の論理行へ戻す。
      PANE_CONTENT=$(term_capture_wait joined) || {
        notify_fallback "端末で確認してください"
        cancel_requests
        exit 0
      }
      PROMPT_VISIBLE=$(/usr/bin/env python3 "$PARSER" detect-codex "$PANE_CONTENT" 2>/dev/null)
      [ "$PROMPT_VISIBLE" = "yes" ] && break
      sleep "$DETECT_INTERVAL"
    done

    # TUIが出なければAutomatic approval済みなので、通知を作成しない。
    [ "$PROMPT_VISIBLE" != "yes" ] && exit 0

    # 実際に表示されたTUIから選択肢を抽出する。これにより、固定のAllow/Deny
    # ではなく、Codexが表示した3択などをそのままスマホへ転送できる。
    REGISTERED_PROMPT=$(/usr/bin/env python3 "$PARSER" fingerprint codex "$PANE_CONTENT")
    term_display_host
    PAYLOAD=$(/usr/bin/env python3 "$PARSER" codex-parse \
      "$INPUT" "$DISPLAY_HOST" "$TIMEOUT" "$PAYLOAD_TARGET" "$PANE_CONTENT" 2>/dev/null)
    [ -z "$PAYLOAD" ] && exit 0

    hook_log relay request
    register_requests
    [ -z "$REQUEST_ID" ] && [ -z "$REQUEST_ID_2" ] && exit 0
    DEADLINE_EPOCH=$(( $(date +%s) + TIMEOUT ))

    while [ "$(date +%s)" -lt "$DEADLINE_EPOCH" ]; do
      [ "$(cat "$POLLER_FILE" 2>/dev/null)" != "$_MY_PID" ] && exit 0

      PANE_CONTENT=$(term_capture_wait joined) || {
        notify_fallback "端末で確認してください"
        cancel_requests
        exit 0
      }
      PROMPT_VISIBLE=$(/usr/bin/env python3 "$PARSER" detect-codex "$PANE_CONTENT" 2>/dev/null)
      if [ "$PROMPT_VISIBLE" != "yes" ]; then
        # TUI 側で先に回答された。
        cancel_requests
        exit 0
      fi

      PARSED=$(poll_response)
      STATUS="${PARSED%%|*}"
      REST="${PARSED#*|}"
      SEND_KEY="${REST%%|*}"
      DECISION="${REST#*|}"
      if [ "$STATUS" = "stale" ]; then
        exit 0
      fi
      if [ "$STATUS" = "ok" ] && [ "$PROMPT_VISIBLE" = "yes" ]; then
        # Capture and send still race; this check is not an atomic guarantee.
        [ "$(cat "$POLLER_FILE" 2>/dev/null)" != "$_MY_PID" ] && exit 0
        if ! PANE_CONTENT=$(term_capture_wait joined); then
          notify_fallback "端末で操作してください"
          cancel_requests
          exit 0
        fi
        /usr/bin/env python3 "$PARSER" matches codex "$PANE_CONTENT" "$REGISTERED_PROMPT"
        MATCH_STATUS=$?
        if [ "$MATCH_STATUS" != 0 ]; then
          [ "$MATCH_STATUS" = 2 ] && notify_fallback "端末で操作してください"
          cancel_requests
          exit 0
        fi
        # サーバのsend_keyはスマホで選んだ選択肢番号。実際のTUIに表示された
        # (y)/(p)/(esc)へ変換して送る。
        TUI_KEY=""
        if echo "$SEND_KEY" | grep -qE '^[0-9]+$'; then
          TUI_KEY=$(/usr/bin/env python3 "$PARSER" codex-choice-key \
            "$PANE_CONTENT" "$SEND_KEY" 2>/dev/null)
        fi
        case "$TUI_KEY" in
          y|p) ;;
          esc) TUI_KEY=Escape ;;
          enter) TUI_KEY=Enter ;;
          *)
            # Compatibility with older responses and unknown shortcut formats.
            if [ "$DECISION" = allow ]; then TUI_KEY=Enter; else TUI_KEY=Escape; fi
            ;;
        esac
        [ "$(cat "$POLLER_FILE" 2>/dev/null)" != "$_MY_PID" ] && exit 0
        term_send "$TUI_KEY" || notify_fallback "端末で操作してください"
        cancel_requests
        exit 0
      fi

      sleep "$POLL_INTERVAL"
    done
    cancel_requests
  ) </dev/null >/dev/null 2>&1 &

  # decision を返さないため、Codex は直ちに標準 TUI を表示する。
  exit 0
fi

# 画面操作できる端末の外の直接応答モード。Codex はこの hook の終了まで標準 UI を表示しない。
hook_log direct_request waiting
register_requests
[ -z "$REQUEST_ID" ] && [ -z "$REQUEST_ID_2" ] && exit 0
DEADLINE_EPOCH=$(( $(date +%s) + TIMEOUT ))
trap cancel_requests EXIT
while [ "$(date +%s)" -lt "$DEADLINE_EPOCH" ]; do
  PARSED=$(poll_response)
  STATUS="${PARSED%%|*}"
  REST="${PARSED#*|}"
  DECISION="${REST#*|}"
  if [ "$STATUS" = "stale" ]; then
    exit 0
  fi
  if [ "$STATUS" = "ok" ]; then
    /usr/bin/env python3 "$PARSER" codex-decision "$DECISION"
    if [ "$?" = 0 ]; then
      case "$DECISION" in allow|deny) hook_log direct_response "$DECISION" ;; esac
    fi
    exit 0
  fi
  sleep "$POLL_INTERVAL"
done

exit 0
