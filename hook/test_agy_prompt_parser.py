"""Only observed command approval layouts are supported."""
import json
from pathlib import Path

import pytest

from prompt_parser import (detect_agy_prompt, parse_agy_request,
                           prompt_matches, prompt_snapshot)


@pytest.fixture(params=['tmux', 'cmux'])
def prompt(request):
    return (Path(__file__).parent / 'fixtures' / f'agy_permission_{request.param}.txt').read_text()


def test_observed_dialog(prompt):
    assert detect_agy_prompt(prompt)
    snapshot = json.dumps(prompt_snapshot('agy', prompt))
    assert prompt_matches('agy', prompt, snapshot, prompt)
    assert prompt_matches('agy', prompt.replace('> 1.', '  1.').replace('  2.', '> 2.'), snapshot)
    assert prompt_matches('agy', prompt.replace('relay-example', 'relay-\nexample'), snapshot)
    assert prompt_matches('agy', prompt.replace('medium', 'high'), snapshot)
    assert prompt_matches('agy', 'unrelated history\n' + prompt, snapshot)
    assert not prompt_matches('agy', prompt.replace('relay-example', 'another-command'), snapshot)
    assert not prompt_matches('agy', prompt.replace('Yes, run command', 'Yes, do something else'), snapshot)
    assert not prompt_matches('agy', prompt, snapshot, prompt + '\n> What next?')


@pytest.mark.parametrize('change', ['url', 'tool', 'reason', 'no_heading', 'no_cursor',
                                    'no_footer', 'bad_numbers', 'output', 'input',
                                    'reason_after_heading', 'reason_in_tail'])
def test_unsupported_or_retired_dialog(prompt, change):
    replacements = {
        'url': ('Run this command?', 'Allow access to this URL?'),
        'tool': ('Run this command?', 'Allow calling this tool?'),
        'reason': ('Run this command?', 'Reason: needs access\nRun this command?'),
        'no_heading': ('Run this command?', ''),
        'no_cursor': ('> 1.', '  1.'),
        'no_footer': ('↑/↓ Navigate', 'Navigation'),
        'bad_numbers': ('  3.', '  2.'),
        'reason_after_heading': ('Run this command?', 'Run this command?\nReason: access'),
        'reason_in_tail': ('esc to cancel', 'Reason: access\nesc to cancel'),
    }
    changed = prompt.replace(*replacements[change]) if change in replacements else prompt + (
        '\nCommand completed' if change == 'output' else '\n> Next task')
    assert not detect_agy_prompt(changed)
    assert not prompt_snapshot('agy', changed)['fingerprint']
    assert not prompt_matches('agy', changed, json.dumps(prompt_snapshot('agy', prompt)))


@pytest.mark.parametrize('args,expected', [
    ({'CommandLine': 'touch /tmp/relay-example.txt', 'toolSummary': 'Summary'}, 'touch /tmp/relay-example.txt'),
    ({'CommandLine': 'touch \n/tmp/relay-example.txt'}, 'touch \n/tmp/relay-example.txt'),
])
def test_agy_payload(prompt, args, expected):
    result = parse_agy_request(json.dumps({'toolCall': {'name': 'run_command', 'args': args}}),
                               prompt, 'host:surface', 'host:workspace', 120)
    assert result['tool_name'] == 'run_command'
    assert result['tool_input'] == args
    assert result['description'] == expected
    assert len(result['choices']) == 4
    assert result['choices'][-1] == {'number': 4, 'text': 'No, cancel'}
    assert result['tmux_target'] == 'host:surface'
    assert result['hostname'] == 'host:workspace'
    assert result['timeout'] == 120


@pytest.mark.parametrize('args', [
    {'toolSummary': 'View hosts'}, {}, {'CommandLine': ''}, {'CommandLine': 1},
    {'CommandLine': 'git status'}, {'CommandLine': 'touch /tmp/different-command.txt'},
    {'CommandLine': 'touch /tmp/relay-example.txt && echo omitted'},
])
def test_hook_command_must_match_full_screen_body(prompt, args):
    with pytest.raises(ValueError):
        parse_agy_request(json.dumps({'toolCall': {'name': 'run_command', 'args': args}}), prompt)


def test_screen_reflow_matches_hook_command(prompt):
    command = 'touch /tmp/relay-example.txt'
    screen = prompt.replace(command, 'touch /tmp/relay-\nexample.txt')
    result = parse_agy_request(json.dumps({'toolCall': {'args': {'CommandLine': command}}}), screen)
    assert result['description'] == result['message'] == command


@pytest.mark.parametrize('command', [
    "cat > /tmp/audit-first.txt <<'EOF'\nRequesting permission for:\nfixed-content\nEOF",
    "cat > /tmp/audit-second.txt <<'EOF'\nRequesting permission for:\nfixed-content\nEOF",
    "echo '\nRequesting permission for:\nfixed-content'",
    "rm -rf ~/work; echo '\nRequesting permission for:\nfixed-content'",
])
def test_embedded_permission_marker_is_rejected(prompt, command):
    screen = prompt.replace('touch /tmp/relay-example.txt', command).replace("'touch'", "'cat'")
    assert not detect_agy_prompt(screen)
    assert not prompt_snapshot('agy', screen)['fingerprint']
    assert not prompt_matches('agy', screen, json.dumps(prompt_snapshot('agy', prompt)))
    with pytest.raises(ValueError):
        parse_agy_request(json.dumps({'toolCall': {'args': {'CommandLine': command}}}), screen)


@pytest.mark.parametrize('change', ['no_frame', 'no_title', 'no_rule', 'wrong_title'])
def test_quoted_dialog_without_command_frame_is_rejected(prompt, change):
    lines = prompt.splitlines()
    marker = next(i for i, line in enumerate(lines) if line.strip() == 'Requesting permission for:')
    if change == 'no_frame':
        screen = '\n'.join(lines[marker:])
    elif change == 'no_title':
        screen = prompt.replace('\nCommand\n', '\n')
    elif change == 'wrong_title':
        screen = prompt.replace('\nCommand\n', '\nQuoted command\n')
    else:
        screen = '\n'.join(line for line in lines if not line.strip() or set(line.strip()) != {'─'})
    assert not detect_agy_prompt(screen)
    assert not prompt_snapshot('agy', screen)['fingerprint']



def test_editing_mode_navigation_is_rejected(prompt):
    navigation = '↑/↓ Navigate · tab Amend · ctrl+g edit/expand command'
    changed = prompt.replace(navigation, '↑/↓ Navigate · enter Submit amendment · esc Back')
    assert not detect_agy_prompt(changed)
    assert not prompt_snapshot('agy', changed)['fingerprint']
    assert not prompt_matches('agy', changed, json.dumps(prompt_snapshot('agy', prompt)))
    with pytest.raises(ValueError):
        parse_agy_request(json.dumps({'toolCall': {'args': {'CommandLine': 'touch /tmp/relay-example.txt'}}}), changed)
    # The observed footer still matches with different leading/trailing padding.
    assert detect_agy_prompt(prompt.replace(navigation, '  ' + navigation + '  '))


@pytest.mark.parametrize('old,new', [
    ('1. Yes, run command', '1. No, cancel'),
    ('4. No, cancel', '4. Yes, run in background'),
])
def test_unobserved_allow_deny_choices_are_rejected(prompt, old, new):
    changed = prompt.replace(old, new)
    assert not detect_agy_prompt(changed)
    assert not prompt_snapshot('agy', changed)['fingerprint']
    assert not prompt_matches('agy', changed, json.dumps(prompt_snapshot('agy', prompt)))
    with pytest.raises(ValueError):
        parse_agy_request(json.dumps({'toolCall': {'args': {'CommandLine': 'touch /tmp/relay-example.txt'}}}), changed)
