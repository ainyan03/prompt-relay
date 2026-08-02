"""
プロンプト検出・パースモジュール

permission-request.sh から呼び出される Python ロジックを集約。
単体テスト可能な関数として提供する。

CLI インターフェース:
  python3 prompt_parser.py detect <pane_content>
  python3 prompt_parser.py parse <stdin_json> <pane_content> [tmux_target] [hostname] [timeout]
  python3 prompt_parser.py response <response_json>
  python3 prompt_parser.py codex-parse <stdin_json> [hostname] [timeout] [tmux_target] [pane_content]
  python3 prompt_parser.py codex-decision <allow|deny>
  python3 prompt_parser.py detect-codex <pane_content>
  python3 prompt_parser.py codex-choice-key <pane_content> <choice_number>
"""

import hashlib
import json
import re
import sys


def detect_prompt(pane_text: str) -> bool:
    """tmux ペインの可視領域からプロンプトの有無を判定する。

    検出ロジック:
      1. 末尾から逆順に走査し、番号が降順（例: 3→2→1）に並ぶパターンを探す
      2. 連番パターンに加え、❯カーソルおよび "Esc to"/"Enter to" 行の両方の存在を要求
         → テキスト中の箇条書きとの誤検出を防止
    """
    lines = pane_text.split('\n') if pane_text else []

    # 末尾から走査して番号付き選択肢行を収集
    # 選択肢テキストが折り返して複数行（空行含む）になる場合があるため、
    # 番号のない継続行はスキップし、15行以上連続で番号なしなら停止する
    nums = []
    has_cursor = False
    gap = 0
    scan_start = len(lines)  # 連番領域の開始行

    for i in range(len(lines) - 1, -1, -1):
        # ❯ と > は Claude Code TUI のカーソルインジケータ
        # TUI の幅が狭いとピリオド直後のスペースが消える場合がある (例: "2.Yes")
        m = re.match(r'\s*([❯>])?\s*(\d+)\.\s*\S', lines[i])
        if m:
            nums.append(int(m.group(2)))
            if m.group(1):
                has_cursor = True
            scan_start = i
            gap = 0
        elif nums:
            gap += 1
            if gap >= 15:
                break

    # 連番領域の後方に Esc to / Enter to があるか確認
    has_esc_enter = False
    for i in range(scan_start, len(lines)):
        s = lines[i].strip()
        if s.startswith('Esc to') or s.startswith('Enter to'):
            has_esc_enter = True
            break

    # nums は末尾から収集したので [3, 2, 1] のような降順になるはず
    if len(nums) >= 2 and has_cursor and has_esc_enter:
        # 昇順に直して 1,2,3... の連番か確認
        nums.reverse()
        if nums == list(range(nums[0], nums[0] + len(nums))):
            return True

    return False


def detect_codex_prompt(pane_text: str) -> bool:
    """Codex TUI の承認ダイアログが可視領域にあるか判定する。"""
    if not pane_text:
        return False
    lower = pane_text.lower()
    prompt_markers = (
        'needs your approval',
        'would you like to run',
        'do you want to approve',
        'allow codex to run',
    )
    has_prompt = any(marker in lower for marker in prompt_markers)
    has_action = ('yes' in lower or 'allow' in lower) and (
        'no' in lower or 'deny' in lower or 'esc' in lower
    )
    return has_prompt and has_action


def parse_codex_choices(pane_text: str) -> list[dict]:
    """Codex TUI の承認領域から番号付き選択肢を抽出する。"""
    if not pane_text:
        return []
    lines = pane_text.splitlines()
    prompt_start = 0
    for i in range(len(lines) - 1, -1, -1):
        lower = lines[i].lower()
        if ('would you like to run' in lower or
                'do you want to approve' in lower or
                'allow codex to run' in lower):
            prompt_start = i
            break

    choices: list[dict] = []
    current: dict | None = None
    for line in lines[prompt_start:]:
        match = re.match(r'\s*[›❯>]?\s*(\d+)\.\s+(.+?)\s*$', line)
        if match:
            current = {'number': int(match.group(1)), 'text': match.group(2).strip()}
            choices.append(current)
            continue
        stripped = line.strip()
        if current and stripped:
            lower = stripped.lower()
            if lower.startswith('press enter') or lower.startswith('esc to'):
                current = None
            elif not re.match(r'^(environment|reason):', lower) and not stripped.startswith('$'):
                # 狭い端末で折り返された選択肢の続きを結合する。
                current['text'] += ' ' + stripped

    # 通常出力中の番号付きリストを拾わないよう、承認/拒否らしい選択肢を要求する。
    joined = ' '.join(choice['text'].lower() for choice in choices)
    if len(choices) < 2 or not ('yes' in joined or 'allow' in joined):
        return []
    if not ('no' in joined or 'deny' in joined or '(esc)' in joined):
        return []
    return choices


def codex_choice_key(pane_text: str, choice_number: int) -> str:
    """選択肢末尾のTUIショートカットを返す。見つからなければ安全な既定値。"""
    choices = parse_codex_choices(pane_text)
    selected = next((c for c in choices if c['number'] == choice_number), None)
    if selected:
        match = re.search(r'\((y|p|esc)\)\s*$', selected['text'], re.IGNORECASE)
        if match:
            return match.group(1).lower()
    if choices and choice_number == choices[-1]['number']:
        return 'esc'
    if choices and choice_number == choices[0]['number']:
        return 'enter'
    return ''


def parse_pane(stdin_data: str, pane_data: str,
               tmux_target: str | None = None,
               hostname: str | None = None,
               timeout: int | None = None) -> dict:
    """PreToolUse の stdin データとペイン内容からサーバ送信用の構造化データを生成する。"""
    d = json.loads(stdin_data) if stdin_data else {}

    # ツール名: PreToolUse は tool_name を直接提供
    tool_name = d.get('tool_name', '')
    if not tool_name:
        msg = d.get('message', '')
        m = re.search(r'permission to use (\w+)', msg)
        if m:
            tool_name = m.group(1)
        elif 'needs your attention' in msg:
            tool_name = 'Question'
        else:
            tool_name = 'Permission'

    # ペイン内容からプロンプト詳細をパース
    header = ''
    description = ''
    choices = []
    prompt_question = ''

    if pane_data:
        lines = pane_data.split('\n')

        SYSTEM_CHOICES = {'type something', 'type something.', 'chat about this'}

        def is_solid_sep(l):
            s = l.strip()
            return bool(s) and len(s) >= 10 and all(c == '─' for c in s)

        def is_dashed_sep(l):
            s = l.strip()
            return bool(s) and len(s) >= 10 and all(c == '╌' for c in s)

        # ❯ カーソルをアンカーとしてプロンプト領域を特定（末尾から逆順サーチ）
        cursor_idx = -1
        for i in range(len(lines) - 1, -1, -1):
            if re.match(r'\s*❯\s*\d+\.', lines[i]):
                cursor_idx = i
                break

        # ❯ より前の最後の ─ 実線セパレータを探す（プロンプト開始点）
        prompt_start = 0
        if cursor_idx >= 0:
            for i in range(cursor_idx - 1, -1, -1):
                if is_solid_sep(lines[i]):
                    prompt_start = i + 1
                    break

        # プロンプト領域内のみから選択肢を抽出
        all_choice_lines = []
        scan_from = prompt_start if cursor_idx >= 0 else 0
        if cursor_idx >= 0:
            for i in range(cursor_idx, scan_from - 1, -1):
                if re.match(r'\s*[❯>]?\s*1\.\s*', lines[i]):
                    scan_from = i
                    break
        for i in range(scan_from, len(lines)):
            cm = re.match(r'\s*[❯>]?\s*(\d+)\.\s*(.+)', lines[i])
            if cm:
                text = cm.group(2).strip()
                # 折り返しにより別選択肢のテキストが同一行に混ざる場合があるため
                # 3個以上の連続空白で分割して先頭部分のみ採用する
                text = re.split(r'\s{3,}', text)[0].strip()
                if text.lower().rstrip('.') not in SYSTEM_CHOICES and text.lower() not in SYSTEM_CHOICES:
                    all_choice_lines.append((i, int(cm.group(1)), text))

        # ヘッダー領域: prompt_start から最初の ╌ 点線セパレータまで
        first_choice_idx = all_choice_lines[0][0] if all_choice_lines else len(lines)
        header_end = first_choice_idx
        for i in range(prompt_start, first_choice_idx):
            if is_dashed_sep(lines[i]):
                header_end = i
                break

        # ヘッダーと説明を抽出
        desc_lines = []
        for i in range(prompt_start, header_end):
            s = lines[i].strip()
            if not s:
                continue
            if re.match(r'^[☐□]\s', s):
                header = re.sub(r'^[☐□]\s*', '', s).strip()
                continue
            if 'Do you want' in s or 'Enter to select' in s or 'Esc to' in s:
                break
            if re.match(r'[❯>]?\s*\d+\.', s):
                break
            if not header:
                header = s
            else:
                desc_lines.append(s)

        choices = [{'number': n, 'text': t} for _, n, t in all_choice_lines]

        # 選択肢直前の質問行を抽出
        prompt_question = ''
        for i in range(first_choice_idx - 1, prompt_start - 1, -1):
            s = lines[i].strip()
            if not s:
                continue
            if is_dashed_sep(lines[i]) or is_solid_sep(lines[i]):
                break
            if 'Enter to select' in s or 'Esc to' in s:
                continue
            prompt_question = s
            break

        # Watch/通知表示用に省略（モバイル通知の表示幅に合わせた上限）
        MAX_LINES = 3       # 通知に収まる行数上限
        MAX_LINE_LEN = 80   # 通知に収まる1行の文字数上限
        truncated = []
        for line in desc_lines[:MAX_LINES]:
            if len(line) > MAX_LINE_LEN:
                truncated.append(line[:MAX_LINE_LEN] + '…')
            else:
                truncated.append(line)
        if len(desc_lines) > MAX_LINES:
            truncated.append(f'(+{len(desc_lines) - MAX_LINES} lines)')
        description = '\n'.join(truncated).strip()

    result = {
        'tool_name': tool_name,
        'tool_input': d.get('tool_input', {}),
        'message': d.get('message', ''),
        'header': header,
        'description': description,
        'prompt_question': prompt_question,
        'choices': choices,
        'has_tmux': bool(pane_data),
        'tmux_target': tmux_target,
        'hostname': hostname,
    }
    if timeout is not None and timeout > 0:
        result['timeout'] = timeout
    return result


def parse_response(response_json: str) -> str:
    """サーバ応答 JSON を解析し、'status|send_key|response' 形式の文字列を返す。"""
    try:
        r = json.loads(response_json)
    except (json.JSONDecodeError, TypeError):
        return 'none||'

    resp = r.get('response', '')
    if not resp:
        return 'none||'
    elif resp in ('cancelled', 'expired'):
        return 'stale||'
    else:
        sk = r.get('send_key', '')
        if not sk and resp == 'allow':
            sk = '1'
        return f'ok|{sk}|{resp}'


def parse_codex_request(stdin_data: str, hostname: str | None = None,
                        timeout: int | None = None,
                        tmux_target: str | None = None,
                        pane_data: str | None = None) -> dict:
    """Codex PermissionRequest の入力をサーバ共通形式へ変換する。"""
    try:
        d = json.loads(stdin_data) if stdin_data else {}
    except json.JSONDecodeError:
        d = {}

    tool_name = d.get('tool_name') or 'Permission'
    tool_input = d.get('tool_input')
    if not isinstance(tool_input, dict):
        tool_input = {'value': tool_input} if tool_input is not None else {}

    description = tool_input.get('description')
    if not isinstance(description, str) or not description.strip():
        command = tool_input.get('command')
        if isinstance(command, str) and command.strip():
            description = command
        elif tool_input:
            description = json.dumps(tool_input, ensure_ascii=False, separators=(',', ':'))
        else:
            description = ''

    # 並行した承認要求を区別しつつ、同じ要求の再送は置換できる安定 ID にする。
    canonical_input = json.dumps(tool_input, ensure_ascii=False, sort_keys=True,
                                 separators=(',', ':'))
    digest = hashlib.sha256(canonical_input.encode()).hexdigest()[:12]
    session_id = str(d.get('session_id') or 'unknown')[:24]
    turn_id = str(d.get('turn_id') or 'unknown')[:24]
    host = hostname or 'unknown'

    choices = parse_codex_choices(pane_data or '') or [
        {'number': 1, 'text': 'Allow'},
        {'number': 2, 'text': 'Deny'},
    ]

    result = {
        'tool_name': tool_name,
        'tool_input': tool_input,
        'message': description,
        'header': f'Codex: {tool_name}',
        'description': description,
        'prompt_question': 'Codex の実行を許可しますか？',
        'choices': choices,
        'has_tmux': bool(tmux_target),
        'can_respond': True,
        'tmux_target': tmux_target or f'{host}:codex:{session_id}:{turn_id}:{digest}',
        'hostname': f'{host}:Codex',
        'client': 'codex',
    }
    if timeout is not None and timeout > 0:
        result['timeout'] = timeout
    return result


def codex_decision(response: str) -> dict | None:
    """サーバ応答を Codex PermissionRequest フックの出力へ変換する。"""
    if response not in ('allow', 'deny'):
        return None
    decision = {'behavior': response}
    if response == 'deny':
        decision['message'] = 'Denied from Prompt Relay.'
    return {
        'hookSpecificOutput': {
            'hookEventName': 'PermissionRequest',
            'decision': decision,
        }
    }


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <detect|parse|response> [args...]', file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == 'detect':
        pane = sys.argv[2] if len(sys.argv) > 2 else ''
        print('yes' if detect_prompt(pane) else 'no')

    elif cmd == 'detect-codex':
        pane = sys.argv[2] if len(sys.argv) > 2 else ''
        print('yes' if detect_codex_prompt(pane) else 'no')

    elif cmd == 'parse':
        stdin_data = sys.argv[2] if len(sys.argv) > 2 else '{}'
        pane_data = sys.argv[3] if len(sys.argv) > 3 else ''
        tmux_target = sys.argv[4] if len(sys.argv) > 4 else None
        hostname = sys.argv[5] if len(sys.argv) > 5 else None
        timeout_str = sys.argv[6] if len(sys.argv) > 6 else None
        try:
            timeout_val = int(timeout_str) if timeout_str else None
        except ValueError:
            timeout_val = None
        result = parse_pane(stdin_data, pane_data, tmux_target, hostname, timeout_val)
        print(json.dumps(result))

    elif cmd == 'response':
        resp_json = sys.argv[2] if len(sys.argv) > 2 else ''
        print(parse_response(resp_json))

    elif cmd == 'codex-parse':
        stdin_data = sys.argv[2] if len(sys.argv) > 2 else '{}'
        hostname = sys.argv[3] if len(sys.argv) > 3 else None
        timeout_str = sys.argv[4] if len(sys.argv) > 4 else None
        tmux_target = sys.argv[5] if len(sys.argv) > 5 else None
        pane_data = sys.argv[6] if len(sys.argv) > 6 else None
        try:
            timeout_val = int(timeout_str) if timeout_str else None
        except ValueError:
            timeout_val = None
        print(json.dumps(parse_codex_request(
            stdin_data, hostname, timeout_val, tmux_target, pane_data),
                         ensure_ascii=False))

    elif cmd == 'codex-choice-key':
        pane = sys.argv[2] if len(sys.argv) > 2 else ''
        try:
            choice_number = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        except ValueError:
            choice_number = 0
        print(codex_choice_key(pane, choice_number))

    elif cmd == 'codex-decision':
        response = sys.argv[2] if len(sys.argv) > 2 else ''
        result = codex_decision(response)
        if result is not None:
            print(json.dumps(result))

    else:
        print(f'Unknown command: {cmd}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
