#!/bin/bash
# PreToolUse hook - 権限プロンプト即時検出 & サーバ転送
#
# Claude Code の PreToolUse フックとして動作し、権限プロンプトが表示された際に
# サーバへ転送してモバイル端末からの応答を可能にする。
#
# 動作原理:
#   1. PreToolUse は各ツール実行前に発火する（権限不要のツールでも発火）
#   2. フック本体は stdin を読み取り、バックグラウンドサブシェルを起動して即 exit 0
#   3. バックグラウンドで tmux ペインをポーリングし、権限プロンプトの
#      出現を検出する（末尾から逆順に番号降順パターンを探索）
#   4. 検出後、排他ロックを取得してからサーバへ送信、応答をポーリングして tmux へ転送
#   5. 応答送信後、ロックを解放し、再びフェーズ1に戻り次の連続プロンプトを検出する
#
# ロック戦略:
#   プロンプト検出（フェーズ1）はロック不要 — 読み取り専用のため並行実行可能。
#   プロンプトが見つかった場合にのみロックを取得し、処理を排他的に実行する。
#   これにより、プロンプトが表示されない大多数のケース（自動承認ツール等）では
#   ロック競合が発生せず、連続する PreToolUse フックの同時実行を妨げない。
#
# 重要: バックグラウンドサブシェルの stdin/stdout/stderr は /dev/null にリダイレクト
#        する必要がある。これを怠ると、Claude Code がパイプの EOF を待ち続けて
#        プロンプト表示がブロックされるデッドロックが発生する。
#
# settings.json 設定例:
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": "",
#       "hooks": [{ "type": "command", "command": "/path/to/permission-request.sh", "timeout": 5 }]
#     }]
#   }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT=120
POLL_INTERVAL=1

# 現在の tmux ペインを取得
TMUX_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
TMUX_TARGET="$TMUX_PANE"

# tmux が使えない場合は何もしない
[ -z "$TMUX_TARGET" ] && exit 0

TMUX_TARGET_ID="${HOSTNAME_SHORT}:${TMUX_PANE}"

# stdin から PreToolUse データを読み取る
INPUT=$(cat)

# バックグラウンドで全処理を実行（PreToolUse を即座に返すため）
(
  # --- ロック管理 & プロセス間重複防止 ---
  LOCK_DIR="/tmp/prompt-relay-${TMUX_TARGET//[:.]/_}.lock"
  SKIP_FILE="/tmp/prompt-relay-${TMUX_TARGET//[:.]/_}.skip"
  LOCK_HELD=false

  cleanup() {
    [ "$LOCK_HELD" = "true" ] && rmdir "$LOCK_DIR" 2>/dev/null
  }
  trap cleanup EXIT

  acquire_lock() {
    # 古いロックの除去（フック最大寿命 120s を大きく超えている場合は確実に stale）
    if [ -d "$LOCK_DIR" ]; then
      local _age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0) ))
      [ $_age -gt 300 ] && rmdir "$LOCK_DIR" 2>/dev/null
    fi
    # リトライ（最大 2 秒待機: 先行フックの処理完了を待つ）
    local _try
    for _try in 1 2 3 4 5 6 7 8 9 10; do
      if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_HELD=true
        return 0
      fi
      sleep 0.2
    done
    return 1
  }

  release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
    LOCK_HELD=false
  }

  PARSER="${SCRIPT_DIR}/prompt_parser.py"

  # --- プロンプト検出関数（ロック不要、読み取り専用）---
  # ロジックの詳細は prompt_parser.py の detect_prompt() を参照
  detect_prompt() {
    /usr/bin/env python3 "$PARSER" detect "$1" 2>/dev/null
  }

  # --- ヘルパー関数 ---

  # フォールバック通知
  notify_fallback() {
    curl -s --connect-timeout 3 -X POST "${SERVER_URL}/notify" \
      -H "Content-Type: application/json" \
      "${CURL_AUTH[@]}" \
      -d "{\"title\":\"承認待ち\",\"message\":\"$1\",\"hostname\":\"${DISPLAY_HOST}\"}" > /dev/null 2>&1
    if [ -n "$SERVER_URL_2" ]; then
      curl -s --connect-timeout 3 -X POST "${SERVER_URL_2}/notify" \
        -H "Content-Type: application/json" \
        "${CURL_AUTH_2[@]}" \
        -d "{\"title\":\"承認待ち\",\"message\":\"$1\",\"hostname\":\"${DISPLAY_HOST}\"}" > /dev/null 2>&1 &
    fi
  }

  # 両サーバにキャンセル送信
  cancel_all() {
    curl -s --connect-timeout 3 -X POST "${CURL_AUTH[@]}" "${SERVER_URL}/permission-request/${REQUEST_ID}/cancel" 2>/dev/null
    if [ -n "$SERVER_URL_2" ] && [ -n "$REQUEST_ID_2" ] && [ "$REQUEST_ID_2" != "null" ]; then
      curl -s --connect-timeout 3 -X POST "${CURL_AUTH_2[@]}" "${SERVER_URL_2}/permission-request/${REQUEST_ID_2}/cancel" 2>/dev/null &
    fi
  }

  # サーバ応答を解析
  # ロジックの詳細は prompt_parser.py の parse_response() を参照
  parse_response() {
    /usr/bin/env python3 "$PARSER" response "$1" 2>/dev/null
  }

  # --- メインループ ---
  ELAPSED=0
  PREV_DETECTED_RAW=""  # 前回処理済みペイン内容（同一内容の再処理防止用）

  while [ $ELAPSED -lt $TIMEOUT ]; do

    # --- フェーズ1: プロンプト出現を待機（ロック不要）---
    # 可視領域のみ対象とし、スクロールバック内の古いプロンプトとの誤検出を防ぐ。
    PANE_CONTENT=""
    for _i in $(seq 1 $DETECT_ATTEMPTS); do
      sleep $DETECT_INTERVAL
      _RAW=$(tmux capture-pane -t "$TMUX_TARGET" -p 2>/dev/null)

      if [ "$(detect_prompt "$_RAW")" = "yes" ]; then
        # 同一ペイン内容の再処理をスキップ（偽プロンプトの無限ループ防止）
        # - PREV_DETECTED_RAW: 同一プロセス内の連続検出を防止
        # - SKIP_FILE: 別プロセス（並行 PreToolUse）による重複処理を防止
        # 真の連続プロンプトは画面内容が変わるので影響しない
        if [ -n "$PREV_DETECTED_RAW" ] && [ "$_RAW" = "$PREV_DETECTED_RAW" ]; then
          continue
        fi
        if [ -f "$SKIP_FILE" ] && [ "$(cat "$SKIP_FILE" 2>/dev/null)" = "$_RAW" ]; then
          continue
        fi
        # 検出成功 → パース用にスクロールバック込みで再取得
        # -S -50: 可視領域+50行のスクロールバックを取得（プロンプトヘッダーが画面外にある場合に対応）
        PANE_CONTENT=$(tmux capture-pane -t "$TMUX_TARGET" -p -S -50 2>/dev/null)
        break
      fi
    done

    # プロンプト未検出 → これ以上の連続プロンプトはない、終了
    [ -z "$PANE_CONTENT" ] && break

    # --- プロンプト検出 → 排他ロック取得 ---
    # 別のフックが既に処理中の場合はリトライ後に諦めて終了
    if ! acquire_lock; then
      break
    fi

    # ロック取得中に別プロセスが処理済みなら再処理しない
    if [ -f "$SKIP_FILE" ] && [ "$(cat "$SKIP_FILE" 2>/dev/null)" = "$_RAW" ]; then
      release_lock
      break
    fi

    # ロック取得中にプロンプトが処理された可能性があるので再確認
    _RAW_RECHECK=$(tmux capture-pane -t "$TMUX_TARGET" -p 2>/dev/null)
    if [ "$(detect_prompt "$_RAW_RECHECK")" != "yes" ]; then
      release_lock
      break
    fi
    # 再取得（ロック取得中にペイン内容が変わっている可能性）
    PANE_CONTENT=$(tmux capture-pane -t "$TMUX_TARGET" -p -S -50 2>/dev/null)

    # --- フェーズ2: ペイン内容をパースしてサーバ送信用 JSON を構築 ---
    # ロジックの詳細は prompt_parser.py の parse_pane() を参照
    PAYLOAD=$(/usr/bin/env python3 "$PARSER" parse "$INPUT" "$PANE_CONTENT" "$TMUX_TARGET_ID" "${DISPLAY_HOST}" 2>/dev/null)

    if [ -z "$PAYLOAD" ]; then
      notify_fallback "パース失敗: 手動で確認してください"
      release_lock
      break
    fi

    # サーバにリクエスト送信（通知送信はサーバ側で非同期処理）
    REQUEST_ID=""
    REQUEST_ID_2=""
    RESPONSE_WITH_STATUS=$(curl -s -w "\n%{http_code}" --connect-timeout 3 -X POST "${SERVER_URL}/permission-request" \
      -H "Content-Type: application/json" \
      "${CURL_AUTH[@]}" \
      -d "$PAYLOAD" 2>/dev/null)
    CURL_EXIT=$?
    HTTP_STATUS=$(echo "$RESPONSE_WITH_STATUS" | tail -1)
    RESPONSE=$(echo "$RESPONSE_WITH_STATUS" | sed '$d')

    if [ $CURL_EXIT -ne 0 ] || [ -z "$RESPONSE_WITH_STATUS" ]; then
      notify_fallback "サーバ接続失敗"
      release_lock
      break
    fi

    if [ "$HTTP_STATUS" = "503" ] || [ "$HTTP_STATUS" = "401" ]; then
      release_lock
      break
    fi

    REQUEST_ID=$(/usr/bin/env python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$RESPONSE" 2>/dev/null)

    if [ -z "$REQUEST_ID" ] || [ "$REQUEST_ID" = "null" ]; then
      notify_fallback "サーバ応答異常"
      release_lock
      break
    fi

    # セカンダリサーバにもリクエスト送信（設定されている場合）
    if [ -n "$SERVER_URL_2" ]; then
      RESPONSE_2=$(curl -s --connect-timeout 3 -X POST "${SERVER_URL_2}/permission-request" \
        -H "Content-Type: application/json" \
        "${CURL_AUTH_2[@]}" \
        -d "$PAYLOAD" 2>/dev/null)
      REQUEST_ID_2=$(/usr/bin/env python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$RESPONSE_2" 2>/dev/null)
    fi

    # --- フェーズ3: サーバの応答をポーリングし、tmux にキー送信 ---
    ANSWERED=false
    SEEN_PROMPT=true  # フェーズ1で確認済み
    while [ $ELAPSED -lt $TIMEOUT ]; do
      # まずプライマリサーバの応答を確認
      RESULT=$(curl -s --connect-timeout 3 "${CURL_AUTH[@]}" "${SERVER_URL}/permission-request/${REQUEST_ID}/response" 2>/dev/null)
      PARSED=$(parse_response "$RESULT")
      STATUS="${PARSED%%|*}"
      REST="${PARSED#*|}"
      SEND_KEY="${REST%%|*}"

      # セカンダリも確認（プライマリに応答がない場合）
      if [ "$STATUS" = "none" ] && [ -n "$SERVER_URL_2" ] && [ -n "$REQUEST_ID_2" ] && [ "$REQUEST_ID_2" != "null" ]; then
        RESULT_2=$(curl -s --connect-timeout 3 "${CURL_AUTH_2[@]}" "${SERVER_URL_2}/permission-request/${REQUEST_ID_2}/response" 2>/dev/null)
        PARSED_2=$(parse_response "$RESULT_2")
        STATUS_2="${PARSED_2%%|*}"
        REST_2="${PARSED_2#*|}"
        SEND_KEY_2="${REST_2%%|*}"

        if [ "$STATUS_2" != "none" ]; then
          STATUS="$STATUS_2"
          SEND_KEY="$SEND_KEY_2"
        fi
      fi

      # キャンセル/期限切れなら終了
      if [ "$STATUS" = "stale" ]; then
        release_lock
        break 2
      fi

      # 応答あり + send_key あり → tmux にキー送信
      if [ "$STATUS" = "ok" ] && [ -n "$SEND_KEY" ]; then
        # send_key が数字のみであることを検証（インジェクション防止）
        if echo "$SEND_KEY" | grep -qE '^[0-9]+$'; then
          tmux send-keys -t "$TMUX_TARGET" "$SEND_KEY" 2>/dev/null
        fi
        cancel_all
        ANSWERED=true
        break
      fi

      # 応答あり + send_key 空（deny でキー不明）→ ペインから探す
      if [ "$STATUS" = "ok" ] && [ -z "$SEND_KEY" ]; then
        PANE_NOW=$(tmux capture-pane -t "$TMUX_TARGET" -p 2>/dev/null)
        LAST_NUM=$(echo "$PANE_NOW" | grep -oE '^\s*[0-9]+\.' | tail -1 | tr -dc '0-9')
        # LAST_NUM が数字のみであることを検証（インジェクション防止）
        if [ -n "$LAST_NUM" ] && echo "$LAST_NUM" | grep -qE '^[0-9]+$'; then
          tmux send-keys -t "$TMUX_TARGET" "$LAST_NUM" 2>/dev/null
        fi
        cancel_all
        ANSWERED=true
        break
      fi

      # tmux ペインの手動回答を検知
      PANE_CHECK=$(tmux capture-pane -t "$TMUX_TARGET" -p 2>/dev/null)
      if echo "$PANE_CHECK" | grep -qE '[❯>]\s*[0-9]+\.'; then
        SEEN_PROMPT=true
      elif [ "$SEEN_PROMPT" = "true" ]; then
        # プロンプトが消えた → tmux 側で手動回答された
        cancel_all
        ANSWERED=true
        break
      fi

      sleep $POLL_INTERVAL
      ELAPSED=$((ELAPSED + POLL_INTERVAL))
    done

    # 処理済みペイン内容を記録（同一内容の再処理防止）
    PREV_DETECTED_RAW="$_RAW"        # 同一プロセス内用
    echo "$_RAW" > "$SKIP_FILE"      # 別プロセス間共有用

    # ロック解放（連続プロンプトの次回検出を別フックにも許可）
    release_lock

    # 応答なし（タイムアウト等）→ 連続プロンプトの試行を中断
    [ "$ANSWERED" = "false" ] && break

  done
) </dev/null >/dev/null 2>&1 &

exit 0
