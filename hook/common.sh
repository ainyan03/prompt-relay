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

TERM_BACKEND=none
TERM_REASON=no_environment

# Bound reads, ownership queries, and key sends to two seconds per CLI call.
terminal_cli() {
  /usr/bin/env python3 "$(dirname "${BASH_SOURCE[0]}")/idle_state.py" "terminal-$1" "${@:2}" 2>/dev/null
}

term_query_owner() {
  local pane_pid pane_tty
  pane_pid=$(terminal_cli owner "$TERM_BACKEND" "$TERM_ENDPOINT") || return 1
  pane_tty=$(ps -o tty= -p "$pane_pid" 2>/dev/null) || return 1
  read -r pane_tty <<< "$pane_tty"
  case "$pane_tty" in ''|'??'|'?'|-) return 1 ;; esac
  printf '%s %s\n' "$pane_pid" "${pane_tty#/dev/}"
}

# A daemon inherits its launcher's environment: TMUX_PANE may name a different
# caller's pane. Shared servers lack a controlling terminal; interactive agents
# have one. Check executable names and TTYs without depending on launch arguments.
# Pane PID/TTY matching guards tmux and herdr; codex name checking is supplementary.
TERM_PANE_PID=""
TERM_PANE_TTY=""
TERM_PS_READY=""
TERM_PS_FAILED=""
TERM_PS_SNAPSHOT=""
term_verify_ancestry() {
  local pid ppid tty executable current=$$ pane_pid="" pane_tty="" pane_info first_tty="" matched="" seen=" "
  local -a parents ttys executables
  TERM_REASON=invalid_endpoint
  case "$TERM_BACKEND" in
    herdr) [[ "$TERM_ENDPOINT" =~ ^w[0-9A-Za-z]+:p[0-9A-Za-z]+$ ]] || return 1 ;;
    hc) [[ "$TERM_ENDPOINT" =~ ^t[0-9a-z]+$ ]] || return 1 ;;
  esac
  TERM_REASON=ps_failed
  if [ "$TERM_PS_READY" != yes ]; then
    TERM_PS_READY=yes
    TERM_PS_SNAPSHOT=$(ps -axo pid=,ppid=,tty=,comm= 2>/dev/null) || TERM_PS_FAILED=yes
  fi
  [ "$TERM_PS_FAILED" != yes ] || return 1
  while read -r pid ppid tty executable; do
    [[ "$pid" =~ ^[0-9]+$ && "$ppid" =~ ^[0-9]+$ ]] || continue
    parents[$pid]=$ppid
    ttys[$pid]=$tty
    executables[$pid]=$executable
  done <<< "$TERM_PS_SNAPSHOT"
  if [ "$TERM_BACKEND" = tmux ]; then
    TERM_REASON=pane_query_failed
    pane_info=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid} #{pane_tty}' 2>/dev/null) || return 1
    read -r pane_pid pane_tty <<< "$pane_info"
    TERM_REASON=invalid_pane
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    TERM_REASON=missing_pane_tty
    [ -n "$pane_tty" ] || return 1
    pane_tty=${pane_tty#/dev/}
  elif [ "$TERM_BACKEND" = herdr ] || [ "$TERM_BACKEND" = hc ]; then
    TERM_REASON="${TERM_BACKEND}_query_failed"
    pane_info=$(term_query_owner) || return 1
    read -r pane_pid pane_tty <<< "$pane_info"
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
    if [ "$TERM_BACKEND" != cmux ]; then
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
TERM_ENDPOINT=""
# Prefer the inner terminal, then transports that bind a pane to an ancestor PID.
# Failed tmux validation may try herdr/hc: PID and TTY bind them to this caller.
if [ -n "$TMUX" ] && [ -n "$TMUX_PANE" ]; then
  TERM_BACKEND=tmux
  term_verify_ancestry || TERM_BACKEND=none
fi
if [ "$TERM_BACKEND" = none ] && { [ -z "$TMUX" ] || [ -n "$TMUX_PANE" ]; }; then
  for candidate in herdr hc cmux; do
    case "$candidate" in
      herdr)
        [ "$HERDR_ENV" = 1 ] || continue
        TERM_ENDPOINT=$HERDR_PANE_ID ;;
      hc)
        [ -n "$HC_TERMINAL_ID" ] || continue
        TERM_ENDPOINT=$HC_TERMINAL_ID ;;
      cmux)
        # cmux cannot bind a surface to a PID; never fall back outside herdr/hc.
        [ -z "$TMUX" ] && [ "$HERDR_ENV" != 1 ] && [ -z "$HC_TERMINAL_ID" ] &&
          [ -n "$CMUX_SURFACE_ID" ] || continue ;;
    esac
    TERM_BACKEND=$candidate
    term_verify_ancestry && break
    TERM_BACKEND=none
  done
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
  herdr|hc)
    TERM_TARGET="${TERM_BACKEND}:${TERM_ENDPOINT}"
    TERM_TARGET_ID="${HOSTNAME_SHORT}:${TERM_TARGET}"
    ;;
esac
DISPLAY_HOST="${HOSTNAME_SHORT}${TERM_NAME:+:${TERM_NAME}}"

# visible and joined read only the viewport; non-tmux history reads 200 lines.
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
    herdr)
      if [ "${1:-visible}" = history ]; then
        terminal_cli run herdr pane read "$TERM_ENDPOINT" --source recent --lines 200
      else
        terminal_cli run herdr pane read "$TERM_ENDPOINT" --source visible
      fi
      ;;
    hc)
      if [ "${1:-visible}" = history ]; then
        local content
        content=$(terminal_cli run hc read "$TERM_ENDPOINT" --lines 200) || return 1
        # While the program is busy or blocked, hc returns only the screen and
        # appends a notice line; drop it so the prompt footer stays the last line.
        case "${content##*$'\n'}" in
          '[hc] incomplete:'*) content=${content%$'\n'*} ;;
        esac
        printf '%s\n' "$content"
      else
        terminal_cli run hc read "$TERM_ENDPOINT"
      fi
      ;;
    *) return 1 ;;
  esac
}

term_send() {
  local pane_info pane_pid pane_tty rc key key_kind=other
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
    herdr|hc)
      pane_info=$(term_query_owner) || {
        hook_log send_cancelled "${TERM_BACKEND}_query_failed"; return 1;
      }
      read -r pane_pid pane_tty <<< "$pane_info"
      [ -n "$TERM_PANE_PID" ] && [ "$pane_pid" = "$TERM_PANE_PID" ] || {
        hook_log send_cancelled pane_pid_changed; return 1;
      }
      [ -n "$TERM_PANE_TTY" ] && [ "$pane_tty" = "$TERM_PANE_TTY" ] || {
        hook_log send_cancelled pane_tty_changed; return 1;
      }
      case "$1" in Escape) key=esc ;; Enter) key=enter ;; *) key=$1 ;; esac
      if [ "$TERM_BACKEND" = herdr ]; then
        terminal_cli run herdr pane send-keys "$TERM_ENDPOINT" "$key"
      else
        terminal_cli run hc keys "$TERM_ENDPOINT" "$key"
      fi
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
  elif [ "$TERM_BACKEND" = herdr ] || [ "$TERM_BACKEND" = hc ]; then
    TERM_NAME=$(terminal_cli name "$TERM_BACKEND" "$TERM_ENDPOINT")
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
