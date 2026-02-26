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
#   4. 検出後、サーバへ送信し、応答をポーリングして tmux へ転送
#   5. 応答送信後、再びフェーズ1に戻り次の連続プロンプトを検出する
#
# 排他戦略（PID 後勝ち方式、ロックなし）:
#   2つの独立した PID ファイルで排他制御を行い、いずれも後発が先行を置き換える。
#
#   WATCHER_FILE — フェーズ1（検出）+ フェーズ2（パース＋サーバ送信）を排他
#     各フックは起動時に自身の PID を書き込む。検出ループの各イテレーションで
#     PID を確認し、新しいフックに上書きされていたら即座に終了する。
#     万一フェーズ2で重複送信が発生しても、サーバの cancelPendingByTarget が
#     旧リクエストをキャンセルするため実害はない。
#
#   POLLER_FILE — フェーズ3（応答ポーリング）を排他
#     サーバ送信成功後に自身の PID を書き込む。ポーリング各イテレーションで
#     PID を確認し、新しいリクエストに上書きされていたら退く。
#     サーバ側でも cancelPendingByTarget が旧リクエストをキャンセルするため
#     二重の安全策となる。
#
#   この方式により、フェーズ2（数百ms）の間だけ排他が効き、
#   フェーズ3（最大120秒）は新しいフックの処理をブロックしない。
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

TIMEOUT="${PROMPT_RELAY_TIMEOUT:-120}"
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
  # --- PID ファイル & 重複防止 ---
  _SAFE_TARGET="${TMUX_TARGET//[:.]/_}"
  WATCHER_FILE="/tmp/prompt-relay-${_SAFE_TARGET}.watcher"
  POLLER_FILE="/tmp/prompt-relay-${_SAFE_TARGET}.poller"
  SKIP_FILE="/tmp/prompt-relay-${_SAFE_TARGET}.skip"

  _MY_PID=$(sh -c 'echo $PPID')

  cleanup() {
    # 自分の PID の場合のみ削除（他プロセスのファイルを消さない）
    [ "$(cat "$WATCHER_FILE" 2>/dev/null)" = "$_MY_PID" ] && rm -f "$WATCHER_FILE"
    [ "$(cat "$POLLER_FILE" 2>/dev/null)" = "$_MY_PID" ] && rm -f "$POLLER_FILE"
  }
  trap cleanup EXIT

  # --- ウォッチャー登録（PID 後勝ち方式）---
  # 自身の PID を書き込み、検出ループの各イテレーションで確認する。
  # 新しいフックが PID を上書きしたら、古いフックは次のチェックで退く。
  echo "$_MY_PID" > "$WATCHER_FILE"

  PARSER="${SCRIPT_DIR}/prompt_parser.py"

  # --- プロンプト検出関数 ---
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
  DEADLINE_EPOCH=$(( $(date +%s) + TIMEOUT ))
  PREV_DETECTED_RAW=""  # 前回処理済みペイン内容（同一内容の再処理防止用）

  while [ $(date +%s) -lt $DEADLINE_EPOCH ]; do

    # === フェーズ1: プロンプト出現を待機（ウォッチャー排他） ===
    # 可視領域のみ対象とし、スクロールバック内の古いプロンプトとの誤検出を防ぐ。
    PANE_CONTENT=""
    for _i in $(seq 1 $DETECT_ATTEMPTS); do
      # ウォッチャーチェック: 新しいフックに置き換えられていたら即終了
      [ "$(cat "$WATCHER_FILE" 2>/dev/null)" != "$_MY_PID" ] && exit 0

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

    # プロンプト未検出 → 終了
    [ -z "$PANE_CONTENT" ] && break

    # === フェーズ2: パース＋サーバ送信（ロック不要、ウォッチャー排他で十分） ===

    # プロンプトが処理された可能性があるので再確認
    _RAW_RECHECK=$(tmux capture-pane -t "$TMUX_TARGET" -p 2>/dev/null)
    if [ "$(detect_prompt "$_RAW_RECHECK")" != "yes" ]; then
      break
    fi
    # 再取得（フェーズ1からの間にペイン内容が変わっている可能性）
    PANE_CONTENT=$(tmux capture-pane -t "$TMUX_TARGET" -p -S -50 2>/dev/null)

    # ペイン内容をパースしてサーバ送信用 JSON を構築
    # ロジックの詳細は prompt_parser.py の parse_pane() を参照
    PAYLOAD=$(/usr/bin/env python3 "$PARSER" parse "$INPUT" "$PANE_CONTENT" "$TMUX_TARGET_ID" "${DISPLAY_HOST}" "$TIMEOUT" 2>/dev/null)

    if [ -z "$PAYLOAD" ]; then
      notify_fallback "パース失敗: 手動で確認してください"
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
      break
    fi

    if [ "$HTTP_STATUS" = "503" ] || [ "$HTTP_STATUS" = "401" ]; then
      break
    fi

    REQUEST_ID=$(/usr/bin/env python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$RESPONSE" 2>/dev/null)
    # サーバが返した expires_at（エポックミリ秒）をポーリング期限に使用
    # ESP32 版はブート相対時刻を返すため、妥当なエポック値（2020年以降）のみ採用
    EXPIRES_AT=$(/usr/bin/env python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('expires_at',''))" "$RESPONSE" 2>/dev/null)
    if [ -n "$EXPIRES_AT" ] && [ "$EXPIRES_AT" != "" ] && [ "$EXPIRES_AT" -gt 1577836800000 ] 2>/dev/null; then
      DEADLINE_EPOCH=$((EXPIRES_AT / 1000))
    fi

    if [ -z "$REQUEST_ID" ] || [ "$REQUEST_ID" = "null" ]; then
      notify_fallback "サーバ応答異常"
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

    # 送信成功 → 重複検出防止用に記録
    PREV_DETECTED_RAW="$_RAW"
    echo "$_RAW" > "$SKIP_FILE"

    # === フェーズ3: 応答ポーリング（ポーラー排他） ===
    # ポーラー登録: 新しいリクエストが来たら古いポーラーは退く
    echo "$_MY_PID" > "$POLLER_FILE"

    ANSWERED=false
    SEEN_PROMPT=true  # フェーズ1で確認済み
    while [ $(date +%s) -lt $DEADLINE_EPOCH ]; do
      # ポーラーチェック: 新しいリクエストに置き換えられていたら退く
      # （サーバ側でも cancelPendingByTarget が旧リクエストをキャンセルしている）
      [ "$(cat "$POLLER_FILE" 2>/dev/null)" != "$_MY_PID" ] && {
        ANSWERED=true  # 新しいフックが引き継ぐので、外側ループは継続扱い
        break
      }

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
        break
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
    done

    # 応答なし（タイムアウト等）→ 連続プロンプトの試行を中断
    [ "$ANSWERED" = "false" ] && break

  done

  # タイムアウト時: 未応答リクエストをキャンセルして通知を消去
  if [ -n "$REQUEST_ID" ] && [ "$REQUEST_ID" != "null" ] && [ "$ANSWERED" != "true" ]; then
    cancel_all >/dev/null 2>&1
  fi
) </dev/null >/dev/null 2>&1 &

exit 0
