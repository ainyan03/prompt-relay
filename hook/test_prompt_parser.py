"""prompt_parser のテスト"""

import json
import pytest
from prompt_parser import detect_prompt, parse_pane, parse_response


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
