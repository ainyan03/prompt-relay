"""prompt_parser のテスト"""

import json
import pytest
from prompt_parser import (
    codex_decision,
    codex_choice_key,
    detect_codex_prompt,
    detect_prompt,
    parse_codex_request,
    parse_codex_choices,
    parse_pane,
    parse_response,
)


# ============================================================
# detect_prompt テスト
# ============================================================

class TestDetectPrompt:
    """プロンプト検出ロジックのテスト"""

    def test_standard_permission_prompt(self):
        """標準的な権限プロンプトを検出できる"""
        pane = "\n".join([
            "──────────────────────────",
            "☐ Claude wants to use Bash",
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            "  ls -la",
            "❯ 1. Allow",
            "  2. Allow always",
            "  3. Deny",
            "  4. Type something.",
            "Esc to cancel   Enter to select",
        ])
        assert detect_prompt(pane) is True

    def test_prompt_with_gt_cursor(self):
        """> カーソルインジケータでも検出できる"""
        pane = "\n".join([
            "──────────────────────────",
            "☐ Claude wants to use Edit",
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            "  file.txt",
            "> 1. Allow",
            "  2. Deny",
            "Enter to select",
        ])
        assert detect_prompt(pane) is True

    def test_prompt_cursor_not_on_first(self):
        """カーソルが1番以外の選択肢にあっても検出できる"""
        pane = "\n".join([
            "──────────────────────────",
            "☐ Claude wants to use Bash",
            "  1. Allow",
            "❯ 2. Deny",
            "  3. Type something",
            "Esc to cancel",
        ])
        assert detect_prompt(pane) is True

    def test_no_prompt_empty(self):
        """空のペイン内容ではプロンプト未検出"""
        assert detect_prompt("") is False

    def test_no_prompt_normal_output(self):
        """通常の出力はプロンプトとして検出しない"""
        pane = "\n".join([
            "$ ls -la",
            "total 32",
            "-rw-r--r--  1 user  staff   100 Jan  1 00:00 file.txt",
            "-rw-r--r--  1 user  staff   200 Jan  1 00:00 README.md",
        ])
        assert detect_prompt(pane) is False

    def test_no_prompt_numbered_list_without_cursor(self):
        """カーソルのない番号付きリスト（Esc to あり）は検出しない"""
        pane = "\n".join([
            "手順:",
            "  1. ファイルを開く",
            "  2. 編集する",
            "  3. 保存する",
            "Esc to cancel",
        ])
        assert detect_prompt(pane) is False

    def test_no_prompt_numbered_list_without_esc(self):
        """Esc to / Enter to のない番号付きリスト（カーソルあり）は検出しない"""
        pane = "\n".join([
            "❯ 1. Allow",
            "  2. Allow always",
            "  3. Deny",
        ])
        assert detect_prompt(pane) is False

    def test_false_positive_conversation_example(self):
        """会話中のプロンプト例示テキストを誤検出しない（AND条件による防止）"""
        pane = "\n".join([
            "Claude の権限プロンプトは以下の構造です:",
            "",
            "❯ 1. Allow",
            "  2. Allow always",
            "  3. Deny",
            "",
            "このようにカーソルと連番で表示されます。",
        ])
        assert detect_prompt(pane) is False

    def test_non_consecutive_numbers(self):
        """連番でない番号（1, 3, 5）は検出しない"""
        pane = "\n".join([
            "❯ 1. First option",
            "  3. Third option",
            "  5. Fifth option",
            "Esc to cancel",
        ])
        assert detect_prompt(pane) is False

    def test_single_choice(self):
        """選択肢が1つだけの場合は検出しない"""
        pane = "\n".join([
            "❯ 1. Continue",
            "Esc to cancel",
        ])
        assert detect_prompt(pane) is False

    def test_prompt_with_wrapped_choice_text(self):
        """選択肢テキストが折り返して複数行になる場合も検出できる"""
        pane = "\n".join([
            "──────────────────────────",
            "☐ Claude wants to use Bash",
            "❯ 1. Allow this very long command that wraps",
            "     to the next line",
            "  2. Deny",
            "Esc to cancel",
        ])
        assert detect_prompt(pane) is True

    def test_prompt_with_preceding_output(self):
        """プロンプト前に大量の出力があっても検出できる"""
        output_lines = [f"line {i}" for i in range(50)]
        prompt_lines = [
            "──────────────────────────",
            "☐ Claude wants to use Write",
            "❯ 1. Allow",
            "  2. Deny",
            "Enter to select",
        ]
        pane = "\n".join(output_lines + prompt_lines)
        assert detect_prompt(pane) is True

    def test_prompt_narrow_terminal(self):
        """狭い端末でピリオド直後にスペースがない場合も検出できる"""
        pane = "\n".join([
            "──────────────────────────",
            "❯ 1.Allow",
            "  2.Deny",
            "Esc to cancel",
        ])
        assert detect_prompt(pane) is True


class TestDetectCodexPrompt:
    def test_exec_approval(self):
        pane = """Command needs your approval.
Would you like to run the following command?
› 1. Yes, proceed
  2. No, cancel
Press enter to confirm or esc to cancel"""
        assert detect_codex_prompt(pane) is True

    def test_network_approval(self):
        pane = """Do you want to approve network access to example.com?
Allow / Deny"""
        assert detect_codex_prompt(pane) is True

    def test_normal_output(self):
        assert detect_codex_prompt('Finished successfully. No errors.') is False


class TestParseCodexChoices:
    PANE = """• Running sw_vers -buildVersion

  Would you like to run the following command?

  Environment: local
  Reason: Codex needs approval
  $ sw_vers -buildVersion

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `sw_vers -buildVersion` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel"""

    def test_extracts_all_three_choices(self):
        assert parse_codex_choices(self.PANE) == [
            {'number': 1, 'text': 'Yes, proceed (y)'},
            {'number': 2, 'text': "Yes, and don't ask again for commands that start with `sw_vers -buildVersion` (p)"},
            {'number': 3, 'text': 'No, and tell Codex what to do differently (esc)'},
        ]

    def test_extracts_shortcut_keys(self):
        assert codex_choice_key(self.PANE, 1) == 'y'
        assert codex_choice_key(self.PANE, 2) == 'p'
        assert codex_choice_key(self.PANE, 3) == 'esc'

    def test_wrapped_choice(self):
        pane = """Would you like to run the following command?
› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start
     with `a very long command` (p)
  3. No, and tell Codex what to do differently (esc)
Press enter to confirm or esc to cancel"""
        choices = parse_codex_choices(pane)
        assert choices[1]['text'] == (
            "Yes, and don't ask again for commands that start "
            "with `a very long command` (p)")


# ============================================================
# parse_pane テスト
# ============================================================

class TestParsePaneToolName:
    """ツール名抽出のテスト"""

    def test_tool_name_from_stdin(self):
        """stdin の tool_name フィールドから取得"""
        result = parse_pane('{"tool_name": "Bash"}', '')
        assert result['tool_name'] == 'Bash'

    def test_tool_name_from_message(self):
        """message フィールドからツール名をパース"""
        result = parse_pane('{"message": "permission to use Edit"}', '')
        assert result['tool_name'] == 'Edit'

    def test_tool_name_question(self):
        """needs your attention メッセージ → Question"""
        result = parse_pane('{"message": "needs your attention"}', '')
        assert result['tool_name'] == 'Question'

    def test_tool_name_fallback(self):
        """不明なメッセージ → Permission"""
        result = parse_pane('{"message": "unknown"}', '')
        assert result['tool_name'] == 'Permission'

    def test_empty_stdin(self):
        """空の stdin → Permission"""
        result = parse_pane('', '')
        assert result['tool_name'] == 'Permission'


class TestParsePaneContent:
    """ペイン内容パースのテスト"""

    STANDARD_PANE = "\n".join([
        "──────────────────────────",
        "☐ Claude wants to use Bash",
        "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
        "  ls -la /tmp",
        "❯ 1. Allow",
        "  2. Allow always",
        "  3. Deny",
        "Esc to cancel   Enter to select",
    ])

    def test_header_extraction(self):
        """ヘッダー（☐ 行）を正しく抽出"""
        result = parse_pane('{}', self.STANDARD_PANE)
        assert result['header'] == 'Claude wants to use Bash'

    def test_choices_extraction(self):
        """選択肢を正しく抽出"""
        result = parse_pane('{}', self.STANDARD_PANE)
        assert len(result['choices']) == 3
        assert result['choices'][0] == {'number': 1, 'text': 'Allow'}
        assert result['choices'][1] == {'number': 2, 'text': 'Allow always'}
        assert result['choices'][2] == {'number': 3, 'text': 'Deny'}

    def test_system_choices_excluded(self):
        """'type something' などのシステム選択肢は除外される"""
        pane = "\n".join([
            "──────────────────────────",
            "☐ Permission request",
            "❯ 1. Allow",
            "  2. Deny",
            "  3. Type something.",
            "  4. Chat about this",
            "Esc to cancel",
        ])
        result = parse_pane('{}', pane)
        assert len(result['choices']) == 2
        assert result['choices'][0]['text'] == 'Allow'
        assert result['choices'][1]['text'] == 'Deny'

    def test_description_extraction(self):
        """説明テキスト（☐ヘッダーと╌セパレータの間）を正しく抽出"""
        pane = "\n".join([
            "──────────────────────────",
            "☐ Claude wants to use Bash",
            "  command: echo hello",
            "  path: /tmp",
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            "  echo hello",
            "❯ 1. Allow",
            "  2. Deny",
            "Esc to cancel",
        ])
        result = parse_pane('{}', pane)
        assert 'command: echo hello' in result['description']
        assert 'path: /tmp' in result['description']

    def test_description_truncation(self):
        """長い説明は3行+省略表記に切り詰められる"""
        desc_lines = [f"  description line {i}" for i in range(10)]
        pane = "\n".join([
            "──────────────────────────",
            "☐ Header",
            *desc_lines,
            "╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌",
            "❯ 1. Allow",
            "  2. Deny",
            "Esc to cancel",
        ])
        result = parse_pane('{}', pane)
        lines = result['description'].split('\n')
        assert len(lines) == 4  # 3行 + "(+N lines)"
        assert lines[-1].startswith('(+')

    def test_tmux_target_and_hostname(self):
        """tmux_target と hostname が出力に含まれる"""
        result = parse_pane('{}', '', 'host:main:0.0', 'myhost')
        assert result['tmux_target'] == 'host:main:0.0'
        assert result['hostname'] == 'myhost'

    def test_no_pane_data(self):
        """ペインデータなしの場合"""
        result = parse_pane('{"tool_name": "Bash"}', '')
        assert result['choices'] == []
        assert result['header'] == ''
        assert result['has_tmux'] is False

    def test_has_tmux_true(self):
        """ペインデータありの場合 has_tmux が true"""
        result = parse_pane('{}', self.STANDARD_PANE)
        assert result['has_tmux'] is True


# ============================================================
# parse_response テスト
# ============================================================

class TestParseResponse:
    """サーバ応答解析のテスト"""

    def test_allow_with_send_key(self):
        resp = parse_response('{"response": "allow", "send_key": "1"}')
        assert resp == 'ok|1|allow'

    def test_second_allow_choice_keeps_send_key(self):
        """Codexの「以後確認しない」を通常allowへ潰さず、2番として保持する。"""
        resp = parse_response('{"response": "allow", "send_key": "2"}')
        assert resp == 'ok|2|allow'

    def test_allow_default_send_key(self):
        """allow で send_key 未指定の場合はデフォルト '1'"""
        resp = parse_response('{"response": "allow"}')
        assert resp == 'ok|1|allow'

    def test_deny_with_send_key(self):
        resp = parse_response('{"response": "deny", "send_key": "3"}')
        assert resp == 'ok|3|deny'

    def test_deny_without_send_key(self):
        """deny で send_key 未指定の場合は空"""
        resp = parse_response('{"response": "deny"}')
        assert resp == 'ok||deny'

    def test_cancelled(self):
        resp = parse_response('{"response": "cancelled"}')
        assert resp == 'stale||'

    def test_expired(self):
        resp = parse_response('{"response": "expired"}')
        assert resp == 'stale||'

    def test_no_response_field(self):
        resp = parse_response('{"id": "123"}')
        assert resp == 'none||'

    def test_empty_response(self):
        resp = parse_response('{"response": ""}')
        assert resp == 'none||'

    def test_invalid_json(self):
        resp = parse_response('not json')
        assert resp == 'none||'

    def test_empty_string(self):
        resp = parse_response('')
        assert resp == 'none||'

    def test_none_input(self):
        resp = parse_response(None)
        assert resp == 'none||'


# ============================================================
# Codex PermissionRequest テスト
# ============================================================

class TestCodexPermissionRequest:
    def test_bash_request(self):
        input_data = json.dumps({
            'hook_event_name': 'PermissionRequest',
            'session_id': 'session-123',
            'turn_id': 'turn-456',
            'tool_name': 'Bash',
            'tool_input': {
                'command': 'curl https://example.com',
                'description': '外部サイトへ接続します',
            },
        })
        result = parse_codex_request(input_data, 'devbox', 120)

        assert result['tool_name'] == 'Bash'
        assert result['header'] == 'Codex: Bash'
        assert result['description'] == '外部サイトへ接続します'
        assert result['choices'] == [
            {'number': 1, 'text': 'Allow'},
            {'number': 2, 'text': 'Deny'},
        ]
        assert result['has_tmux'] is False
        assert result['can_respond'] is True
        assert result['hostname'] == 'devbox:Codex'
        assert result['tmux_target'].startswith('devbox:codex:session-123:turn-456:')
        assert result['timeout'] == 120

    def test_tmux_hybrid_target(self):
        result = parse_codex_request(
            '{"session_id":"s","turn_id":"t","tool_name":"Bash"}',
            'devbox:main', 120, 'devbox:main:0.0', TestParseCodexChoices.PANE)
        assert result['has_tmux'] is True
        assert result['tmux_target'] == 'devbox:main:0.0'
        assert result['hostname'] == 'devbox:main'
        assert len(result['choices']) == 3

    def test_command_is_description_fallback(self):
        result = parse_codex_request('{"tool_name":"Bash","tool_input":{"command":"ls"}}')
        assert result['description'] == 'ls'

    def test_invalid_json_is_safe(self):
        result = parse_codex_request('not-json')
        assert result['tool_name'] == 'Permission'
        assert result['tool_input'] == {}

    def test_target_is_stable_for_same_request(self):
        data = '{"session_id":"s","turn_id":"t","tool_input":{"b":2,"a":1}}'
        first = parse_codex_request(data, 'host')['tmux_target']
        second = parse_codex_request(data, 'host')['tmux_target']
        assert first == second

    def test_allow_decision(self):
        assert codex_decision('allow') == {
            'hookSpecificOutput': {
                'hookEventName': 'PermissionRequest',
                'decision': {'behavior': 'allow'},
            }
        }

    def test_deny_decision(self):
        result = codex_decision('deny')
        assert result['hookSpecificOutput']['decision']['behavior'] == 'deny'
        assert result['hookSpecificOutput']['decision']['message']

    def test_unknown_decision(self):
        assert codex_decision('cancelled') is None


@pytest.mark.parametrize('agent', ['claude', 'codex'])
def test_approval_fingerprint_keeps_full_body_and_ignores_decoration(agent):
    from prompt_parser import prompt_snapshot, prompt_matches
    import json
    command = 'echo ' + 'x' * 300 + ' harmless'
    if agent == 'claude':
        pane = '────────────────────\n☐ Bash command\n' + command + '\n❯ 1. Yes\n  2. No\nEsc to cancel'
    else:
        pane = 'Would you like to run the following command?\n$ ' + command + '\n› 1. Yes (y)\n  2. No (esc)'
    snapshot = json.dumps(prompt_snapshot(agent, pane))
    assert prompt_matches(agent, pane, snapshot)
    assert prompt_matches(agent, pane.replace('❯ 1.', '  1.').replace('› 1.', '  1.').replace('  2.', '❯ 2.'), snapshot)
    assert not prompt_matches(agent, pane.replace('harmless', 'rm -rf important-directory'), snapshot)
    assert not prompt_matches(agent, pane.replace('1. Yes', '9. Yes'), snapshot)
    if agent == 'claude':
        assert prompt_matches(agent, '1. earlier output\n2. earlier output\n' + pane, snapshot)
        assert prompt_matches(agent, pane.replace('─' * 20, '─' * 40), snapshot)


def test_approval_fingerprint_preserves_command_redirection():
    from prompt_parser import prompt_snapshot
    base = '☐ Bash command\n  COMMAND\n❯ 1. Yes\n  2. No\nEsc to cancel'
    assert prompt_snapshot('claude', base.replace('COMMAND', '1.txt')) != prompt_snapshot(
        'claude', base.replace('COMMAND', '> 1.txt'))


def test_unnumbered_codex_fingerprint_preserves_command_redirection():
    from prompt_parser import prompt_snapshot
    base = 'Would you like to run the following command?\nCOMMAND\nAllow / Deny'
    assert prompt_snapshot('codex', base.replace('COMMAND', '1.txt')) != prompt_snapshot(
        'codex', base.replace('COMMAND', '> 1.txt'))


@pytest.mark.parametrize('agent', ['claude', 'codex'])
def test_approval_fingerprint_ignores_whitespace_presence_and_position_by_design(agent):
    from prompt_parser import prompt_snapshot, prompt_matches, approval_region
    command = "python3 - <<'PY'\nif False:\n    pass\n\n    print('remove important data')\nPY"
    if agent == 'claude':
        pane = '☐ Bash command\n' + command + '\n❯ 1. Yes\n  2. No\nEsc to cancel'
    else:
        pane = 'Would you like to run the following command?\n$ ' + command + '\n› 1. Yes (y)\n  2. No (esc)'
    snapshot = json.dumps(prompt_snapshot(agent, pane))
    assert '\n\n    print' in approval_region(agent, pane)
    assert prompt_matches(agent, pane.replace('    print', 'print'), snapshot)
    assert prompt_matches(agent, pane.replace('if False:', 'ifFalse:'), snapshot)
    assert prompt_matches(agent, pane.replace('\n\n    print', '\n    print'), snapshot)
    assert prompt_matches(agent, '\n'.join(line + '  ' for line in pane.splitlines()), snapshot)


def test_codex_body_heading_phrase_is_not_a_boundary():
    from prompt_parser import prompt_snapshot, prompt_matches, approval_region
    pane = ("Would you like to run the following command?\n  $ echo harmless\n"
            "echo 'would you like to run'\n› 1. Yes (y)\n  2. No (esc)\nPress enter to confirm")
    snapshot = json.dumps(prompt_snapshot('codex', pane))
    assert 'echo harmless' in approval_region('codex', pane)
    assert not prompt_matches('codex', pane.replace('echo harmless', 'rm -rf important-directory'), snapshot)
    ambiguous = pane.replace('  $', 'Do you want to approve another command?\n  $')
    assert not prompt_matches('codex', ambiguous, snapshot)


@pytest.mark.parametrize('agent', ['claude', 'codex'])
@pytest.mark.parametrize('tail', ['\n\n❯ Type your next instruction', '\n› next', '\n> next',
                                 '\nCommand finished.', '\n\n', '\n99% context left · ? for shortcuts',
                                 '\n? for shortcuts'])
def test_approval_footer_rejects_new_input_but_allows_known_status(agent, tail):
    from prompt_parser import prompt_snapshot, prompt_matches
    pane = ('☐ Bash command\necho harmless\n❯ 1. Yes\n  2. No\nEsc to cancel' if agent == 'claude' else
            'Would you like to run the following command?\n$ echo harmless\n› 1. Yes (y)\n  2. No (esc)\nPress enter to confirm')
    snapshot = json.dumps(prompt_snapshot(agent, pane))
    allowed = tail in ('\n\n', '\n99% context left · ? for shortcuts', '\n? for shortcuts') or (agent == 'codex' and tail == '\nCommand finished.')
    detect = detect_prompt if agent == 'claude' else detect_codex_prompt
    assert bool(detect(pane + tail)) == allowed
    assert bool(prompt_matches(agent, pane + tail, snapshot)) == allowed


def test_approval_region_retains_framed_blank_lines_before_fingerprinting():
    from prompt_parser import approval_region
    pane = '☐ Bash command\n │ if False:\n │     pass\n │ \n │     print(1)\n❯ 1. Yes\n  2. No\nEsc to cancel'
    assert approval_region('claude', pane).splitlines()[3] == ' '


def test_codex_heading_after_command_without_title_is_ambiguous():
    from prompt_parser import prompt_snapshot
    pane = '$ echo harmless\nWould you like to run the following command?\n› 1. Yes (y)\n  2. No (esc)\nPress enter to confirm'
    assert not prompt_snapshot('codex', pane)['fingerprint']
    assert prompt_snapshot('codex', 'Command needs your approval.\n' + pane)['fingerprint']


def test_second_dialog_after_footer_does_not_match_old_approval():
    from prompt_parser import prompt_snapshot, prompt_matches
    pane = 'Would you like to run the following command?\n$ echo harmless\n› 1. Yes (y)\n  2. No (esc)\nPress enter to confirm'
    assert not prompt_matches('codex', pane + '\n' + pane.replace('harmless', 'different'),
                              json.dumps(prompt_snapshot('codex', pane)))


def test_claude_footer_check_uses_viewport_not_previous_history():
    from prompt_parser import prompt_snapshot, prompt_matches
    pane = '☐ Bash command\necho harmless\n❯ 1. Yes\n  2. No\nEsc to cancel'
    history = pane.replace('harmless', 'earlier') + '\nEarlier output\n' + pane
    assert prompt_matches('claude', history, json.dumps(prompt_snapshot('claude', pane)), pane)


def test_codex_footer_allows_wrapped_status_but_not_input():
    from prompt_parser import prompt_snapshot, prompt_matches
    pane = 'Would you like to run the following command?\n$ echo harmless\n› 1. Yes (y)\n  2. No (esc)\nPress enter to confirm'
    status = '\nExample model · Context 95% left · weekly 84% left · /workspace/\n  project · branch\n  ← for agents · ? for shortcuts'
    snapshot = json.dumps(prompt_snapshot('codex', pane))
    assert detect_codex_prompt(pane + status)
    assert prompt_matches('codex', pane + status, snapshot)
    for cursor in ('›', '❯', '>'):
        assert not detect_codex_prompt(pane + '\n' + cursor + ' Ask anything' + status)
        assert not prompt_matches('codex', pane + '\n' + cursor + ' Ask anything' + status, snapshot)


def test_real_claude_dialog_with_labeled_tmux_separator():
    from pathlib import Path
    from prompt_parser import prompt_snapshot, prompt_matches
    pane = (Path(__file__).parent / 'fixtures' / 'claude_permission_tmux.txt').read_text()
    assert detect_prompt(pane)
    assert prompt_matches('claude', pane, json.dumps(prompt_snapshot('claude', pane)))


def test_recorded_claude_rewrap_matches_but_different_command_does_not():
    from pathlib import Path
    from prompt_parser import prompt_snapshot, prompt_matches
    fixtures = Path(__file__).parent / 'fixtures'
    registered = (fixtures / 'claude_permission_wide.txt').read_text()
    answer = (fixtures / 'claude_permission_narrow.txt').read_text()
    snapshot = json.dumps(prompt_snapshot('claude', registered))
    assert detect_prompt(registered) and detect_prompt(answer)
    assert prompt_matches('claude', answer, snapshot)
    assert not prompt_matches('claude', answer.replace('touch ', 'rm '), snapshot)


@pytest.mark.parametrize('agent', ['claude', 'codex'])
def test_approval_fingerprint_accepts_midword_reflow_by_design(agent):
    from prompt_parser import prompt_snapshot, prompt_matches
    command = 'printf marker-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789'
    pane = ('☐ Bash command\n' + command + '\n❯ 1. Yes\n  2. No\nEsc to cancel' if agent == 'claude' else
            'Would you like to run the following command?\n$ ' + command + '\n› 1. Yes (y)\n  2. No (esc)\nPress enter to confirm')
    snapshot = json.dumps(prompt_snapshot(agent, pane))
    wrapped = pane.replace('wxyz', 'wx\nyz')
    # Word boundaries are deliberately ignored so UI-inserted breaks still match.
    assert prompt_matches(agent, wrapped, snapshot)
    assert not prompt_matches(agent, wrapped.replace('yz', 'yZ'), snapshot)
