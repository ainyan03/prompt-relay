#!/bin/bash
# 共通設定・ヘルパー

SERVER_URL="${PROMPT_RELAY_SERVER_URL:-http://localhost:3939}" # プライマリサーバのURL
API_KEY="${PROMPT_RELAY_API_KEY:-}"                          # Bearer トークン認証用（ルームキー、8〜128文字）

# API Key バリデーション
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

# ホスト名構築（複数マシンからの利用時に衝突を防ぐ）
HOSTNAME_SHORT=$(hostname -s)
TMUX_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
DISPLAY_HOST="${HOSTNAME_SHORT}${TMUX_SESSION:+:${TMUX_SESSION}}" # 形式: hostname:tmux_session（マルチマシン識別用）

DETECT_INTERVAL="${PROMPT_RELAY_DETECT_INTERVAL:-0.1}"
DETECT_ATTEMPTS="${PROMPT_RELAY_DETECT_ATTEMPTS:-10}"
