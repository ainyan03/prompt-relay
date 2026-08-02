#!/bin/bash
# Codex PermissionRequest hook
#
# Codex から構造化された承認要求を受け取り、Prompt Relay の応答を
# PermissionRequest hook の allow / deny JSON として同期的に返す。
# サーバ障害・タイムアウト・不正応答時は何も決定せず、Codex 標準の
# 承認プロンプトへフォールバックする。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${PROMPT_RELAY_TIMEOUT:-120}"
POLL_INTERVAL="${PROMPT_RELAY_POLL_INTERVAL:-1}"
PARSER="${SCRIPT_DIR}/prompt_parser.py"
INPUT=$(cat)

PAYLOAD=$(/usr/bin/env python3 "$PARSER" codex-parse "$INPUT" "$HOSTNAME_SHORT" "$TIMEOUT" 2>/dev/null)
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
trap cancel_requests EXIT

post_request() {
  local url="$1"
  shift
  curl -s --connect-timeout 3 --max-time 5 -X POST "${url}/permission-request" \
    -H "Content-Type: application/json" "$@" -d "$PAYLOAD" 2>/dev/null
}

RESPONSE=$(post_request "$SERVER_URL" "${CURL_AUTH[@]}")
REQUEST_ID=$(/usr/bin/env python3 -c \
  'import json,sys; print(json.loads(sys.argv[1]).get("id", ""))' "$RESPONSE" 2>/dev/null)

if [ -n "$SERVER_URL_2" ]; then
  RESPONSE_2=$(post_request "$SERVER_URL_2" "${CURL_AUTH_2[@]}")
  REQUEST_ID_2=$(/usr/bin/env python3 -c \
    'import json,sys; print(json.loads(sys.argv[1]).get("id", ""))' "$RESPONSE_2" 2>/dev/null)
fi

# どちらのサーバにも登録できなければ、直ちに Codex 標準 UI へ戻す。
[ -z "$REQUEST_ID" ] && [ -z "$REQUEST_ID_2" ] && exit 0

DEADLINE_EPOCH=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE_EPOCH" ]; do
  DECISION=""

  if [ -n "$REQUEST_ID" ]; then
    RESULT=$(curl -s --connect-timeout 3 --max-time 5 "${CURL_AUTH[@]}" \
      "${SERVER_URL}/permission-request/${REQUEST_ID}/response" 2>/dev/null)
    DECISION=$(/usr/bin/env python3 -c '
import json,sys
try:
    value = json.loads(sys.argv[1]).get("response")
    print(value if value in ("allow", "deny") else "")
except Exception:
    pass
' "$RESULT" 2>/dev/null)
  fi

  if [ -z "$DECISION" ] && [ -n "$SERVER_URL_2" ] && [ -n "$REQUEST_ID_2" ]; then
    RESULT_2=$(curl -s --connect-timeout 3 --max-time 5 "${CURL_AUTH_2[@]}" \
      "${SERVER_URL_2}/permission-request/${REQUEST_ID_2}/response" 2>/dev/null)
    DECISION=$(/usr/bin/env python3 -c '
import json,sys
try:
    value = json.loads(sys.argv[1]).get("response")
    print(value if value in ("allow", "deny") else "")
except Exception:
    pass
' "$RESULT_2" 2>/dev/null)
  fi

  if [ -n "$DECISION" ]; then
    /usr/bin/env python3 "$PARSER" codex-decision "$DECISION"
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done

# 応答がなければ空出力で終了し、Codex 自身に承認を委ねる。
exit 0
