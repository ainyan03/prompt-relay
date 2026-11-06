#!/bin/bash
# 設定ファイルから PROMPT_RELAY_* を読み込む
#
# hook はエージェントのプロセスから環境変数を受け継ぐ。シェル設定を読まない経路
# (tmux new-window で直接起動するエージェント等) や、設定の追記前に開いたシェルから
# 起動したエージェントには export が届かないため、起動経路に依存しない設定先として
# ファイルも読む。環境変数が設定済みなら、そちらを優先する。
#
# 形式: 1 行 1 項目の KEY=VALUE (先頭の export、値を囲む引用符は可)。
# PROMPT_RELAY_ で始まる名前だけを取り込み、ファイルの内容は実行しない。
# 毎回のモデル呼び出しで走る hook からも読まれるため、外部コマンドを使わない。

PROMPT_RELAY_CONFIG="${PROMPT_RELAY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/prompt-relay/config}"

if [ -r "$PROMPT_RELAY_CONFIG" ]; then
  while IFS= read -r _pr_line || [ -n "$_pr_line" ]; do
    _pr_line="${_pr_line#"${_pr_line%%[![:space:]]*}"}"
    case "$_pr_line" in
      ''|'#'*) continue ;;
      export[[:space:]]*) _pr_line="${_pr_line#export}"; _pr_line="${_pr_line#"${_pr_line%%[![:space:]]*}"}" ;;
    esac
    _pr_key="${_pr_line%%=*}"
    [ "$_pr_key" = "$_pr_line" ] && continue
    [[ "$_pr_key" =~ ^PROMPT_RELAY_[A-Z0-9_]+$ ]] || continue
    [ -n "${!_pr_key+x}" ] && continue
    _pr_value="${_pr_line#*=}"
    _pr_value="${_pr_value%"${_pr_value##*[![:space:]]}"}"
    case "$_pr_value" in
      \"*\") _pr_value="${_pr_value#\"}"; _pr_value="${_pr_value%\"}" ;;
      \'*\') _pr_value="${_pr_value#\'}"; _pr_value="${_pr_value%\'}" ;;
    esac
    export "$_pr_key=$_pr_value"
  done < "$PROMPT_RELAY_CONFIG"
  unset _pr_line _pr_key _pr_value
fi
