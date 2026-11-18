#!/bin/bash
# 共通設定・ヘルパー

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

PROMPT_RELAY_RUNTIME_DIR="${PROMPT_RELAY_RUNTIME_DIR:-/tmp}"
PROMPT_RELAY_LOG="${PROMPT_RELAY_LOG-${XDG_STATE_HOME:-$HOME/.local/state}/prompt-relay/hook.log}"

hook_log_write() {
  /usr/bin/env python3 "$(dirname "${BASH_SOURCE[0]}")/hook_log.py" "$PROMPT_RELAY_LOG" \
    "${HOOK_LOG_AGENT:-claude}" "$1" "$TERM_BACKEND" "$TERM_TARGET" "${2:-}" >/dev/null 2>&1 || :
}

hook_log() {
  [ -n "$PROMPT_RELAY_LOG" ] && [ "$PROMPT_RELAY_LOG" != off ] || return 0
  # Emit detection only when this invocation actually handles an approval.
  if [ "$HOOK_LOG_TERMINAL_WRITTEN" != yes ]; then
    HOOK_LOG_TERMINAL_WRITTEN=yes
    hook_log_write terminal "$TERM_REASON"
  fi
  [ "$1" = terminal ] || hook_log_write "$@"
}

runtime_prepare() {
  mkdir -p "$PROMPT_RELAY_RUNTIME_DIR" 2>/dev/null
}

SERVER_URL="${PROMPT_RELAY_SERVER_URL:-http://localhost:3939}" # プライマリサーバのURL
API_KEY="${PROMPT_RELAY_API_KEY:-}"                          # Bearer トークン認証用（ルームキー、8〜128文字）

# ルームキーバリデーション
if [ -z "$API_KEY" ]; then
  echo "[prompt-relay] ERROR: PROMPT_RELAY_API_KEY が未設定です" >&2
  exit 0
elif [ ${#API_KEY} -lt 8 ] || [ ${#API_KEY} -gt 128 ]; then
  echo "[prompt-relay] ERROR: PROMPT_RELAY_API_KEY は 8〜128 文字で指定してください (現在: ${#API_KEY}文字)" >&2
  exit 0
fi

CURL_AUTH=(-H "Authorization: Bearer ${API_KEY}")

# セカンダリサーバ (ESP32 等、空なら無効)
SERVER_URL_2="${PROMPT_RELAY_SERVER_URL_2:-}"
API_KEY_2="${PROMPT_RELAY_API_KEY_2:-${API_KEY}}" # 未設定時はプライマリの API_KEY を継承
CURL_AUTH_2=()
if [ -n "$SERVER_URL_2" ]; then
  if [ ${#API_KEY_2} -lt 8 ] || [ ${#API_KEY_2} -gt 128 ]; then
    echo "[prompt-relay] WARNING: PROMPT_RELAY_API_KEY_2 は 8〜128 文字で指定してください (現在: ${#API_KEY_2}文字)、セカンダリサーバを無効化" >&2
    SERVER_URL_2=""
  else
    CURL_AUTH_2=(-H "Authorization: Bearer ${API_KEY_2}")
  fi
fi

# Prefer tmux: cmux variables can survive inside a nested tmux session.
# Detection uses only environment variables, never a running server's focus.
TERM_BACKEND=none
TERM_REASON=no_environment
if [ -n "$TMUX" ] && [ -n "$TMUX_PANE" ]; then
  TERM_BACKEND=tmux
elif [ -z "$TMUX" ] && [ -n "$CMUX_SURFACE_ID" ]; then
  TERM_BACKEND=cmux
fi

# A daemon inherits its launcher's environment: TMUX_PANE may name a different
# caller's pane. Shared servers lack a controlling terminal; interactive agents
# have one. Check executable names and TTYs without depending on launch arguments.
# Pane PID/TTY matching is the primary tmux guard; codex name checking is supplementary.
TERM_PANE_PID=""
TERM_PANE_TTY=""
term_verify_ancestry() {
  local snapshot pid ppid tty executable current=$$ pane_pid="" pane_tty="" pane_info first_tty="" matched="" seen=" "
  local -a parents ttys executables
  TERM_REASON=ps_failed
  snapshot=$(ps -axo pid=,ppid=,tty=,comm= 2>/dev/null) || return 1
  while read -r pid ppid tty executable; do
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || continue
    parents[$pid]=$ppid
    ttys[$pid]=$tty
    executables[$pid]=$executable
  done <<< "$snapshot"
  if [ "$TERM_BACKEND" = tmux ]; then
    TERM_REASON=pane_query_failed
    pane_info=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid} #{pane_tty}' 2>/dev/null) || return 1
    read -r pane_pid pane_tty <<< "$pane_info"
    TERM_REASON=invalid_pane
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    TERM_REASON=missing_pane_tty
    [ -n "$pane_tty" ] || return 1
    pane_tty=${pane_tty#/dev/}
  fi
  while [ "$current" != 1 ]; do
    TERM_REASON=ancestor_missing
    case "$seen" in *" $current "*) TERM_REASON=ancestor_cycle; return 1 ;; esac
    seen="$seen$current "
    case "${ttys[$current]}" in
      '??'|'?'|-) [ "${executables[$current]##*/}" = codex ] && { TERM_REASON=daemon; return 1; } ;;
      '') return 1 ;;
      *) [ -n "$first_tty" ] || first_tty=${ttys[$current]#/dev/} ;;
    esac
    if [ "$TERM_BACKEND" = tmux ]; then
      [ "$current" = "$pane_pid" ] && matched=yes
    fi
    ppid=${parents[$current]}
    [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
    current=$ppid
  done
  TERM_REASON=no_tty
  [ -n "$first_tty" ] || return 1
  TERM_REASON=pane_not_ancestor
  [ "$TERM_BACKEND" = cmux ] || [ "$matched" = yes ] || return 1
  TERM_REASON=tty_mismatch
  [ "$TERM_BACKEND" = cmux ] || [ "$first_tty" = "$pane_tty" ] || return 1
  TERM_PANE_PID=$pane_pid
  TERM_PANE_TTY=$pane_tty
  TERM_REASON=verified
}
if [ "$TERM_BACKEND" != none ] && ! term_verify_ancestry; then
  TERM_BACKEND=none
fi

HOSTNAME_SHORT=$(hostname -s)
TERM_TARGET=""
TERM_TARGET_ID=""
TERM_NAME=""
case "$TERM_BACKEND" in
  tmux)
    if TERM_TARGET=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) &&
       TERM_NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) && [ -n "$TERM_TARGET" ]; then
      TERM_TARGET_ID="${HOSTNAME_SHORT}:${TERM_TARGET}"
    else
      TERM_BACKEND=none
      TERM_REASON=target_query_failed
      TERM_TARGET=""
      TERM_NAME=""
    fi
    ;;
  cmux)
    TERM_TARGET="cmux:${CMUX_SURFACE_ID}"
    TERM_TARGET_ID="${HOSTNAME_SHORT}:${TERM_TARGET}"
    ;;
esac
DISPLAY_HOST="${HOSTNAME_SHORT}${TERM_NAME:+:${TERM_NAME}}"

# visible and joined read only the viewport; cmux history reads the last 200 lines.
term_capture() {
  case "$TERM_BACKEND" in
    tmux)
      case "${1:-visible}" in
        history) tmux capture-pane -t "$TMUX_PANE" -p -S -50 2>/dev/null ;;
        joined) tmux capture-pane -J -t "$TMUX_PANE" -p 2>/dev/null ;;
        *) tmux capture-pane -t "$TMUX_PANE" -p 2>/dev/null ;;
      esac
      ;;
    cmux)
      if [ "${1:-visible}" = history ]; then
        cmux_cli read-screen --surface "$CMUX_SURFACE_ID" --lines 200
      else
        cmux_cli read-screen --surface "$CMUX_SURFACE_ID" 2>/dev/null
      fi
      ;;
    *) return 1 ;;
  esac
}

term_send() {
  local pane_info pane_pid pane_tty rc key_kind=other
  case "$TERM_BACKEND" in
    tmux)
      # A reused pane must not receive keys for its previous owner's request.
      # PID and TTY numbers can both be reused; a pane respawned with the same
      # pair while a response is pending is not distinguished.
      pane_info=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid} #{pane_tty}' 2>/dev/null) || {
        hook_log send_cancelled pane_query_failed; return 1;
      }
      read -r pane_pid pane_tty <<< "$pane_info"
      [ -n "$TERM_PANE_PID" ] && [ "$pane_pid" = "$TERM_PANE_PID" ] || {
        hook_log send_cancelled pane_pid_changed; return 1;
      }
      [ -n "$TERM_PANE_TTY" ] && [ "${pane_tty#/dev/}" = "$TERM_PANE_TTY" ] || {
        hook_log send_cancelled pane_tty_changed; return 1;
      }
      tmux send-keys -t "$TMUX_PANE" "$1" 2>/dev/null
      ;;
    cmux)
      case "$1" in
        Escape) cmux_cli send-key --force --surface "$CMUX_SURFACE_ID" escape 2>/dev/null ;;
        Enter) cmux_cli send-key --force --surface "$CMUX_SURFACE_ID" enter 2>/dev/null ;;
        *) cmux_cli send --force --surface "$CMUX_SURFACE_ID" "$1" 2>/dev/null ;;
      esac
      ;;
    *) hook_log send_cancelled no_transport; return 1 ;;
  esac
  rc=$?
  case "$1" in
    Escape|Enter|y|p|[1-4]) key_kind=$1 ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] && key_kind=choice ;;
  esac
  hook_log key_send "key=$key_kind rc=$rc"
  return "$rc"
}

# Bound every cmux call, including raw screen reads and key sends, to two seconds.
cmux_cli() {
  /usr/bin/env python3 "$(dirname "${BASH_SOURCE[0]}")/idle_state.py" cmux-run "$@" 2>/dev/null
}

term_display_host() {
  if [ "$TERM_BACKEND" = cmux ] && [ -n "$CMUX_WORKSPACE_ID" ]; then
    TERM_NAME=$(/usr/bin/env python3 "$(dirname "${BASH_SOURCE[0]}")/idle_state.py" cmux-name "$CMUX_WORKSPACE_ID" 2>/dev/null)
  fi
  DISPLAY_HOST="${HOSTNAME_SHORT}${TERM_NAME:+:${TERM_NAME}}"
}

# Retry failed captures without treating the failed read as a vanished prompt.
term_capture_wait() {
  local attempt content
  for attempt in 1 2 3 4 5; do
    if content=$(term_capture "$@"); then
      printf '%s' "$content"
      return 0
    fi
    [ "$attempt" = 5 ] || sleep "$DETECT_INTERVAL"
  done
  return 1
}

notify_fallback() {
  local body
  hook_log notify_only fallback
  term_display_host
  body=$(/usr/bin/env python3 -c 'import json,sys; print(json.dumps({"title":"承認待ち", "message":sys.argv[1], "hostname":sys.argv[2]}))' "$1" "$DISPLAY_HOST")
  curl -s --connect-timeout 3 -X POST "${SERVER_URL}/notify" \
    -H "Content-Type: application/json" "${CURL_AUTH[@]}" -d "$body" >/dev/null 2>&1
  if [ -n "$SERVER_URL_2" ]; then
    curl -s --connect-timeout 3 -X POST "${SERVER_URL_2}/notify" \
      -H "Content-Type: application/json" "${CURL_AUTH_2[@]}" -d "$body" >/dev/null 2>&1 &
  fi
}

DETECT_INTERVAL="${PROMPT_RELAY_DETECT_INTERVAL:-0.1}"
DETECT_ATTEMPTS="${PROMPT_RELAY_DETECT_ATTEMPTS:-10}"
