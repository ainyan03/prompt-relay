"""Verify routing metadata, failure isolation, and disposable runtime files."""
import json
import os
from pathlib import Path
import subprocess
import time

import pytest

from hook_log import MAX_BYTES, write_log
from test_terminal_backend import (CLAUDE_PROMPT, CODEX_PROMPT, HOOK_DIR, calls,
                                   shell, terminal_env, wait_for_file)


def records(env):
    return [line.split('\t') for line in Path(env['PROMPT_RELAY_LOG']).read_text().splitlines()]


@pytest.mark.parametrize(('variables', 'backend', 'reason'), [
    ({}, 'none', 'no_environment'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, 'tmux', 'verified'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'PANE_PID': '777777'}, 'none', 'pane_not_ancestor'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'PANE_TTY': '/dev/other'}, 'none', 'tty_mismatch'),
    ({'CMUX_SURFACE_ID': 'surface-1', 'ANCESTOR_COMM': '/bin/codex', 'ANCESTOR_TTY': '??'}, 'none', 'daemon'),
    ({'CMUX_SURFACE_ID': 'surface-1', 'PS_FAIL': '1'}, 'none', 'ps_failed'),
])
def test_terminal_log_has_one_reason_row(terminal_env, variables, backend, reason):
    terminal_env.update(variables, HOOK_LOG_AGENT='claude')
    result = shell(terminal_env, 'hook_log terminal "$TERM_REASON"')
    assert result.returncode == 0
    assert result.stdout == result.stderr == ''
    rows = records(terminal_env)
    assert len(rows) == 1
    assert len(rows[0]) == 6
    assert rows[0][0].endswith('Z')
    assert rows[0][1:4] == ['claude', 'terminal', backend]
    assert rows[0][5] == reason


@pytest.mark.parametrize('send_fail', [False, True])
def test_key_log_preserves_transport_status(terminal_env, send_fail):
    terminal_env.update(TMUX='socket', TMUX_PANE='%1', HOOK_LOG_AGENT='agy')
    if send_fail:
        terminal_env['SEND_FAIL'] = '1'
    result = shell(terminal_env, 'term_send 1')
    assert result.returncode == int(send_fail)
    assert result.stdout == result.stderr == ''
    rows = [row for row in records(terminal_env) if row[2] == 'key_send']
    assert len(rows) == 1
    assert rows[0][1] == 'agy'
    assert rows[0][5] == f'key=1 rc={int(send_fail)}'


def test_cancelled_send_is_logged_without_sending(terminal_env):
    terminal_env.update(TMUX='socket', TMUX_PANE='%1', HOOK_LOG_AGENT='codex')
    result = shell(terminal_env, 'export PANE_PID=777777; term_send y')
    assert result.returncode == 1
    assert result.stdout == result.stderr == ''
    assert records(terminal_env)[-1][2:] == ['send_cancelled', 'tmux',
                                          terminal_env['TEST_SESSION'] + ':0.0', 'pane_pid_changed']
    assert not any(call[1] == 'send-keys' for call in calls(terminal_env))


@pytest.mark.parametrize('decision', ['allow', 'deny'])
def test_direct_response_log_excludes_request_content(terminal_env, decision):
    terminal_env['DECISION'] = decision
    secret = 'DO_NOT_LOG_COMMAND_OR_BODY_9deca'
    Path(terminal_env['SCREEN']).write_text(secret)
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env,
                            input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': secret}}),
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert json.loads(result.stdout)['hookSpecificOutput']['decision']['behavior'] == decision
    rows = [row for row in records(terminal_env) if row[2] == 'direct_response']
    assert len(rows) == 1
    assert rows[0][1:] == ['codex', 'direct_response', 'none', '', decision]
    log = Path(terminal_env['PROMPT_RELAY_LOG']).read_text()
    assert secret not in log
    assert terminal_env['PROMPT_RELAY_API_KEY'] not in log
    assert 'Bash' not in log


@pytest.mark.parametrize('agent', ['claude', 'codex'])
def test_hybrid_approval_logs_detection_relay_and_key_once(terminal_env, agent):
    secret = 'DO_NOT_LOG_HYBRID_COMMAND_f83cd'
    terminal_env.update(TMUX='socket', TMUX_PANE='%1')
    prompt = CODEX_PROMPT.replace('command?\n', 'command?\n  $ ' + secret + '\n') if agent == 'codex' else (
        CLAUDE_PROMPT.replace('  ls', '  ' + secret))
    Path(terminal_env['SCREEN']).write_text(prompt)
    hook = 'codex-permission-request.sh' if agent == 'codex' else 'permission-request.sh'
    result = subprocess.run([str(HOOK_DIR / hook)], env=terminal_env,
                            input=json.dumps({'tool_name': 'Bash', 'tool_input': {'command': secret}}),
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ''
    wait_for_file(terminal_env['CANCELLED'])
    assert [row[2] for row in records(terminal_env)] == ['terminal', 'relay', 'key_send']
    assert {row[1] for row in records(terminal_env)} == {agent}
    assert secret not in Path(terminal_env['PROMPT_RELAY_LOG']).read_text()
    assert Path(terminal_env['PROMPT_RELAY_RUNTIME_DIR']).is_dir()


def test_permission_notification_logs_notify_only(terminal_env):
    result = subprocess.run([str(HOOK_DIR / 'notification.sh')], env=terminal_env,
                            input='{"notification_type":"permission_prompt"}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ''
    assert [row[2] for row in records(terminal_env)] == ['terminal', 'notify_only']


@pytest.mark.parametrize('disabled', ['off', ''])
def test_disabled_log_creates_no_files(terminal_env, disabled):
    directory = Path(terminal_env['PROMPT_RELAY_LOG']).parent
    terminal_env.update(HOOK_LOG_AGENT='claude', PROMPT_RELAY_LOG=disabled)
    assert shell(terminal_env, 'hook_log terminal "$TERM_REASON"').returncode == 0
    assert not directory.exists()


def test_default_log_uses_xdg_state_home(terminal_env, tmp_path):
    terminal_env.pop('PROMPT_RELAY_LOG')
    terminal_env.update(HOOK_LOG_AGENT='claude', XDG_STATE_HOME=str(tmp_path / 'state'))
    assert shell(terminal_env, 'hook_log terminal "$TERM_REASON"').returncode == 0
    assert (tmp_path / 'state' / 'prompt-relay' / 'hook.log').exists()


@pytest.mark.parametrize('operation', ['direct', 'send'])
def test_unwritable_log_does_not_change_stdout_or_status(terminal_env, tmp_path, operation):
    blocker = tmp_path / 'blocker'
    blocker.touch()
    if operation == 'send':
        terminal_env.update(TMUX='socket', TMUX_PANE='%1', HOOK_LOG_AGENT='claude', SEND_FAIL='1')
    outcomes = []
    for destination in ('off', str(blocker / 'hook.log')):
        terminal_env['PROMPT_RELAY_LOG'] = destination
        result = shell(terminal_env, 'term_send y') if operation == 'send' else subprocess.run(
            [str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env, input='{}',
            text=True, capture_output=True, timeout=5)
        outcomes.append((result.returncode, result.stdout, result.stderr))
    assert outcomes[0] == outcomes[1]


def test_log_rotation_keeps_one_bounded_generation(tmp_path):
    path = tmp_path / 'hook.log'
    for old in ('first', 'second'):
        path.write_text(old + '\n' + 'x' * MAX_BYTES)
        write_log(str(path), 'codex', 'terminal', 'none', '', 'no_environment')
        assert Path(str(path) + '.1').read_text().startswith(old + '\n')
        assert path.stat().st_size < MAX_BYTES
    assert not Path(str(path) + '.2').exists()
    assert len(path.read_text().splitlines()) == 1


def test_log_fields_cannot_inject_extra_records(tmp_path):
    path = tmp_path / 'hook.log'
    write_log(str(path), 'claude', 'terminal', 'tmux', 'session\tname\nline', 'verified')
    assert len(path.read_text().splitlines()) == 1
    assert len(path.read_text().splitlines()[0].split('\t')) == 6


@pytest.mark.parametrize('agent', ['claude', 'codex', 'agy'])
def test_runtime_directory_failure_never_sends(terminal_env, tmp_path, agent):
    blocker = tmp_path / 'blocked-runtime'
    blocker.touch()
    terminal_env.update(TMUX='socket', TMUX_PANE='%1', PROMPT_RELAY_RUNTIME_DIR=str(blocker / 'runtime'))
    command = [str(HOOK_DIR / ('codex-permission-request.sh' if agent == 'codex' else 'permission-request.sh'))]
    if agent == 'agy':
        command += ['--agent', 'agy']
    result = subprocess.run(command, env=terminal_env, input='{}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ('{"decision":"allow"}\n' if agent == 'agy' else '')
    assert result.stderr == ''
    assert not Path(terminal_env['PROMPT_RELAY_LOG']).exists()
    assert not any(call[1] in ('capture-pane', 'send-keys') for call in calls(terminal_env))


@pytest.mark.parametrize('agent', ['claude', 'codex', 'agy'])
def test_invocation_without_approval_writes_no_log(terminal_env, agent):
    terminal_env.update(TMUX='socket', TMUX_PANE='%1', PROMPT_RELAY_CODEX_DETECT_TIMEOUT='1')
    Path(terminal_env['SCREEN']).write_text('working; no approval required')
    command = [str(HOOK_DIR / ('codex-permission-request.sh' if agent == 'codex' else 'permission-request.sh'))]
    if agent == 'agy':
        command += ['--agent', 'agy']
    result = subprocess.run(command, env=terminal_env, input='{}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ('{"decision":"allow"}\n' if agent == 'agy' else '')
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        captures = [call for call in calls(terminal_env) if call[1] == 'capture-pane']
        active = list(Path(terminal_env['PROMPT_RELAY_RUNTIME_DIR']).glob('prompt-relay-*'))
        if captures and not active:
            break
        time.sleep(0.02)
    else:
        pytest.fail('Approval-free worker did not finish')
    assert not Path(terminal_env['PROMPT_RELAY_LOG']).exists()
    assert not Path(terminal_env['REGISTERED']).exists()
