"""Exercise herdr transports using fake CLIs, never the running terminals."""
import getpass
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

import pytest

import idle_state
from prompt_parser import (detect_agy_prompt, detect_codex_prompt, detect_prompt,
                           prompt_matches, prompt_snapshot)
from test_terminal_backend import (HOOK_DIR, calls, shell, terminal_env,
                                   wait_for_file)


@pytest.fixture(params=['herdr', 'hc'])
def herdr_env(terminal_env, request):
    backend = request.param
    if backend == 'herdr':
        terminal_env.update(HERDR_ENV='1', HERDR_PANE_ID='w1:p1', HERDR_WORKSPACE_ID='w1')
    else:
        terminal_env['HC_TERMINAL_ID'] = 't1'
    return terminal_env, backend, 'w1:p1' if backend == 'herdr' else 't1'


def records(env):
    return [line.split('\t') for line in Path(env['PROMPT_RELAY_LOG']).read_text().splitlines()]


def sends(env):
    return [call for call in calls(env) if 'send-keys' in call or 'keys' in call]


def test_verified_herdr_capture_keys_and_log(herdr_env):
    env, backend, target = herdr_env
    result = shell(env, 'printf "%s|%s|%s|%s|%s\\n" "$TERM_BACKEND" "$TERM_TARGET" '
                   '"$TERM_TARGET_ID" "$TERM_PANE_PID" "$TERM_PANE_TTY"; '
                   'term_capture; term_capture history; term_capture joined; '
                   'term_send 1; term_send Escape; term_send Enter')
    assert result.returncode == 0
    assert result.stderr == ''
    first = result.stdout.splitlines()[0].split('|')
    assert first[:2] == [backend, f'{backend}:{target}']
    assert first[2].endswith(f':{backend}:{target}')
    assert first[3:] == ['424242', 'ttys001']
    captures = [call for call in calls(env) if 'read' in call]
    prefix = [backend, 'pane', 'read', target] if backend == 'herdr' else [backend, 'read', target]
    assert captures == [prefix + (['--source', 'visible'] if backend == 'herdr' else []),
                        prefix + (['--source', 'recent'] if backend == 'herdr' else []) + ['--lines', '200'],
                        prefix + (['--source', 'visible'] if backend == 'herdr' else [])]
    send_prefix = [backend, 'pane', 'send-keys', target] if backend == 'herdr' else [backend, 'keys', target]
    assert sends(env) == [send_prefix + [key] for key in ('1', 'esc', 'enter')]
    assert records(env)[0][2:] == ['terminal', backend, f'{backend}:{target}', 'verified']
    assert len([row for row in records(env) if row[2] == 'key_send']) == 3


@pytest.mark.parametrize(('failure', 'reason'), [
    ({'PANE_PID': '777777'}, 'pane_not_ancestor'),
    ({'HOOK_TTY': 'ttys002'}, 'tty_mismatch'),
    ({'ANCESTOR_COMM': '/bin/codex', 'ANCESTOR_TTY': '??', 'HOOK_TTY': '??'}, 'daemon'),
    ({'PS_FAIL': '1'}, 'ps_failed'),
    ({'CLI_FAIL': '1'}, 'query_failed'),
    ({'BAD_JSON': '1'}, 'query_failed'),
    ({'PANE_PID': 'invalid'}, 'query_failed'),
    ({'PANE_PID': '0'}, 'query_failed'),
    ({'PANE_TTY': '??'}, 'query_failed'),
    ({'TTY_QUERY_FAIL': '1'}, 'query_failed'),
])
def test_herdr_rejects_unverified_target(herdr_env, failure, reason):
    env, backend, _ = herdr_env
    env.update(failure)
    result = shell(env, 'printf "%s|%s|%s|%s" "$TERM_BACKEND" "$TERM_TARGET" '
                   '"$TERM_TARGET_ID" "$TERM_REASON"; term_capture; term_send y')
    assert result.returncode != 0
    assert result.stdout == 'none|||' + (backend + '_' + reason if reason == 'query_failed' else reason)
    assert result.stderr == ''
    assert not sends(env)
    assert not any('read' in call for call in calls(env))


@pytest.mark.parametrize('state', ['stopped', 'exited', 'starting'])
def test_hc_requires_live_terminal(terminal_env, state):
    terminal_env.update(HC_TERMINAL_ID='t1', HC_STATE=state)
    assert shell(terminal_env, 'printf "%s|%s" "$TERM_BACKEND" "$TERM_REASON"').stdout == 'none|hc_query_failed'


@pytest.mark.parametrize(('change', 'reason'), [
    ({'PANE_PID_AFTER_RESPONSE': '777777'}, 'pane_pid_changed'),
    ({'PANE_TTY_AFTER_RESPONSE': '/dev/ttys002'}, 'pane_tty_changed'),
    ({'PANE_QUERY_FAIL_AFTER_RESPONSE': '1'}, 'query_failed'),
    ({'BAD_JSON': '1'}, 'query_failed'),
    ({'TTY_QUERY_FAIL': '1'}, 'query_failed'),
])
def test_herdr_send_rechecks_owner(herdr_env, change, reason):
    env, backend, target = herdr_env
    script = 'touch "$RESPONSE_SEEN"; export ' + ' '.join(key + '=' + value for key, value in change.items()) + '; term_send y'
    result = shell(env, script)
    assert result.returncode != 0
    assert result.stdout == result.stderr == ''
    assert not sends(env)
    assert records(env)[-1][2:] == ['send_cancelled', backend, f'{backend}:{target}',
                                   backend + '_' + reason if reason == 'query_failed' else reason]


@pytest.mark.parametrize('operation', ['query', 'capture', 'send'])
def test_herdr_cli_timeout_is_bounded(herdr_env, operation):
    env, backend, _ = herdr_env
    if operation == 'query':
        env['CLI_SLEEP'] = '1'
        script = 'printf "%s|%s" "$TERM_BACKEND" "$TERM_REASON"'
    else:
        script = 'export CLI_SLEEP=1; ' + ('term_capture' if operation == 'capture' else 'term_send y')
    start = time.monotonic()
    result = shell(env, script)
    assert 1.8 < time.monotonic() - start < 4
    assert result.stderr == ''
    if operation == 'query':
        assert result.stdout == f'none|{backend}_query_failed'
    else:
        assert result.returncode != 0
    assert not sends(env)


@pytest.mark.parametrize(('variables', 'failure', 'backend'), [
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1'}, {}, 'tmux'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'HC_TERMINAL_ID': 't1'}, {'PANE_PID': '777777'}, 'none'),
    ({'TMUX': 'socket', 'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1', 'CMUX_SURFACE_ID': 'surface-1'}, {}, 'none'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1', 'HC_TERMINAL_ID': 't1'}, {}, 'herdr'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1', 'HC_TERMINAL_ID': 't1'}, {'FAIL_BACKEND': 'herdr'}, 'hc'),
    ({'HC_TERMINAL_ID': 't1', 'CMUX_SURFACE_ID': 'surface-1'}, {'PANE_PID': '777777'}, 'none'),
    ({'HC_TERMINAL_ID': 't1', 'CMUX_SURFACE_ID': 'surface-1'}, {'PANE_TTY': '/dev/other'}, 'none'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1', 'CMUX_SURFACE_ID': 'surface-1'}, {'FAIL_BACKEND': 'herdr'}, 'none'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1', 'CMUX_SURFACE_ID': 'surface-1'}, {'PANE_PID': '777777'}, 'none'),
    ({'HC_TERMINAL_ID': 't1', 'CMUX_SURFACE_ID': 'surface-1'}, {'FAIL_BACKEND': 'hc'}, 'none'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1'}, {'FAIL_BACKEND': 'tmux'}, 'herdr'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'HC_TERMINAL_ID': 't1'}, {'FAIL_BACKEND': 'tmux'}, 'hc'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'CMUX_SURFACE_ID': 'surface-1'}, {'FAIL_BACKEND': 'tmux'}, 'none'),
    ({'HERDR_PANE_ID': 'w1:p1'}, {}, 'none'),
    ({'HERDR_ENV': '0', 'HERDR_PANE_ID': 'w1:p1'}, {}, 'none'),
])
def test_nested_terminal_selection(terminal_env, variables, failure, backend):
    terminal_env.update(variables, **failure)
    result = shell(terminal_env, 'printf "%s" "$TERM_BACKEND"')
    assert result.returncode == 0
    assert result.stdout == backend
    if variables.get('TMUX') and (backend == 'tmux' or not variables.get('TMUX_PANE')):
        assert not any(call[0] in ('herdr', 'hc', 'cmux') for call in calls(terminal_env))
    if variables.get('TMUX') or variables.get('HERDR_ENV') == '1' or variables.get('HC_TERMINAL_ID'):
        assert not any(call[0] == 'cmux' for call in calls(terminal_env))
    snapshot = Path(terminal_env['CALLS'] + '.ps')
    if snapshot.exists():
        assert snapshot.read_text().splitlines().count('snapshot') == 1


@pytest.mark.parametrize('name_fail', [False, True])
def test_herdr_lazy_display_name(herdr_env, name_fail):
    env, backend, _ = herdr_env
    env['WORKSPACE_TITLE'] = 'example / 1'
    if name_fail:
        env['NAME_FAIL' if backend == 'herdr' else 'CLI_FAIL'] = '1'
    # Name failures must not invalidate an already verified transport.
    script = 'term_display_host; printf "%s|%s" "$TERM_NAME" "$DISPLAY_HOST"'
    if name_fail and backend == 'hc':
        env.pop('CLI_FAIL')
        script = 'export CLI_FAIL=1; ' + script
    result = shell(env, script)
    name, display = result.stdout.split('|')
    expected = ('w1' if backend == 'herdr' else '') if name_fail else 'example / 1'
    assert name == expected
    if name:
        assert display.endswith(':' + name)
    else:
        assert ':' not in display


@pytest.mark.parametrize(('agent', 'fixture'), [
    ('claude', 'claude_permission_hc.txt'),
    ('claude', 'claude_permission_herdr.txt'),
    ('codex', 'codex_permission_hc.txt'),
    ('agy', 'agy_permission_hc.txt'),
])
def test_observed_herdr_prompts(agent, fixture):
    prompt = (HOOK_DIR / 'fixtures' / fixture).read_text()
    detector = {'claude': detect_prompt, 'codex': detect_codex_prompt, 'agy': detect_agy_prompt}[agent]
    assert detector(prompt)
    snapshot = json.dumps(prompt_snapshot(agent, prompt))
    assert prompt_matches(agent, prompt, snapshot, prompt)
    assert not prompt_matches(agent, prompt, snapshot, prompt + '\n> Next instruction')
    # Captures must not carry home paths, e-mail addresses, or this machine's user name.
    assert '/Users/' not in prompt and '/home/' not in prompt
    assert not re.search(r'[\w.+-]+@[\w-]+\.[\w.]+', prompt)
    assert getpass.getuser() not in prompt


@pytest.mark.parametrize(('agent', 'mode'), [('claude', 'auto'), ('agy', 'auto'),
                                           ('codex', 'auto'), ('codex', 'tmux')])
def test_herdr_permission_roundtrip(herdr_env, agent, mode):
    env, backend, target = herdr_env
    env.update(PROMPT_RELAY_CODEX_MODE=mode, PROMPT_RELAY_POLL_INTERVAL='0.01')
    fixture = {'claude': 'claude_permission_herdr.txt' if backend == 'herdr' else 'claude_permission_hc.txt',
               'codex': 'codex_permission_hc.txt', 'agy': 'agy_permission_hc.txt'}[agent]
    Path(env['SCREEN']).write_text((HOOK_DIR / 'fixtures' / fixture).read_text())
    hook = 'codex-permission-request.sh' if agent == 'codex' else 'permission-request.sh'
    command = [str(HOOK_DIR / hook)] + (['--agent', 'agy'] if agent == 'agy' else [])
    tool = 'ping -c 1 example.org' if agent == 'codex' else 'touch /tmp/herdr-probe-agy.txt' if agent == 'agy' else 'touch /tmp/herdr-probe-marker.txt'
    payload = {'toolCall': {'name': 'run_command', 'args': {'CommandLine': tool}}} if agent == 'agy' else {
        'tool_name': 'Bash', 'tool_input': {'command': tool}}
    result = subprocess.run(command, env=env, input=json.dumps(payload),
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ('{"decision":"allow"}\n' if agent == 'agy' else '')
    assert result.stderr == ''
    wait_for_file(env['CANCELLED'])
    payload = json.loads(Path(env['PAYLOADS']).read_text().splitlines()[0])
    assert payload['tmux_target'].endswith(f':{backend}:{target}')
    assert sends(env)[-1][-1] == ('y' if agent == 'codex' else '1')
    assert records(env)[0][2:4] == ['terminal', backend]
    assert any(row[2] == 'key_send' and row[3] == backend for row in records(env))


@pytest.mark.parametrize('event', ['permission_prompt', 'idle_prompt'])
def test_herdr_notification_and_session_fallback(herdr_env, event):
    env, backend, target = herdr_env
    env['PROMPT_RELAY_IDLE_SCOPE'] = 'session'
    assert idle_state.context(backend) is None
    result = subprocess.run([str(HOOK_DIR / 'notification.sh')], env=env,
                            input=json.dumps({'hook_event_name': 'Notification', 'notification_type': event}),
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ''
    if event == 'permission_prompt':
        assert not Path(env['PAYLOADS']).exists()
    else:
        payload = json.loads(Path(env['PAYLOADS']).read_text())
        assert payload['tmux_target'].endswith(f':{backend}:{target}')
        assert payload['message'] != '全エージェントの処理が完了しました'


@pytest.mark.parametrize('mode', ['auto', 'tmux', 'direct'])
def test_herdr_codex_unreadable_screen_falls_back_by_mode(herdr_env, mode):
    env, _, _ = herdr_env
    env.update(READ_FAIL='1', PROMPT_RELAY_CODEX_MODE=mode)
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=env,
                            input='{"tool_name":"Bash","tool_input":{"command":"ls"}}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stderr == ''
    if mode == 'tmux':
        assert result.stdout == ''
        assert not Path(env['PAYLOADS']).exists()
    else:
        assert json.loads(result.stdout)['hookSpecificOutput']['decision']['behavior'] == 'allow'
    assert not sends(env)


def test_herdr_send_failure_is_logged(herdr_env):
    env, backend, target = herdr_env
    env['SEND_FAIL'] = '1'
    result = shell(env, 'term_send Enter')
    assert result.returncode == 1
    assert result.stdout == result.stderr == ''
    assert records(env)[-1][2:] == ['key_send', backend, f'{backend}:{target}', 'key=Enter rc=1']


def test_herdr_missing_cli_disables_transport(herdr_env, tmp_path):
    env, backend, _ = herdr_env
    # Only these commands are reachable; an installed real CLI must never run.
    isolated = tmp_path / 'isolated-bin'
    isolated.mkdir()
    for executable in ('bash', 'dirname', 'hostname'):
        (isolated / executable).symlink_to('/bin/bash' if executable == 'bash' else shutil.which(executable))
    (isolated / 'python3').symlink_to(shutil.which('python3'))
    (isolated / 'ps').symlink_to(tmp_path / 'ps')
    env['PATH'] = str(isolated)
    result = shell(env, 'printf "%s|%s" "$TERM_BACKEND" "$TERM_REASON"')
    assert result.returncode == 0
    assert result.stdout == f'none|{backend}_query_failed'
    assert result.stderr == ''


@pytest.mark.parametrize('agent', ['codex', 'agy'])
def test_herdr_completion_without_group_context(herdr_env, agent):
    env, backend, target = herdr_env
    env.update(PROMPT_RELAY_IDLE_SCOPE='session', PROMPT_RELAY_CODEX_GOAL_AWARE='false')
    command = [str(HOOK_DIR / 'notification.sh')]
    if agent == 'agy':
        command += ['--agent', 'agy', '--event', 'Stop']
    result = subprocess.run(command, env=env,
                            input='{"hook_event_name":"Stop","session_id":"example-thread","turn_id":"turn-1"}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ('{}\n' if agent == 'agy' else '')
    assert result.stderr == ''
    if agent == 'agy':
        assert not Path(env['PAYLOADS']).exists()
    else:
        payload = json.loads(Path(env['PAYLOADS']).read_text())
        assert payload['tmux_target'].endswith(':codex:example-thread')
        assert payload['message'] == 'ターンが完了しました'


@pytest.mark.parametrize(('variables', 'backend'), [
    ({'HC_TERMINAL_ID': 'other-machine/t7'}, 'hc'),
    ({'HC_TERMINAL_ID': 'my-terminal'}, 'hc'),
    ({'HC_TERMINAL_ID': '--help'}, 'hc'),
    ({'HC_TERMINAL_ID': 't7/child'}, 'hc'),
    ({'HC_TERMINAL_ID': 'tA'}, 'hc'),
    ({'HC_TERMINAL_ID': 't'}, 'hc'),
    ({'HC_TERMINAL_ID': 't1\n'}, 'hc'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'other:w1:p1'}, 'herdr'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': '--help'}, 'herdr'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1/child'}, 'herdr'),
    ({'HERDR_ENV': '1', 'HERDR_PANE_ID': 'w1:p1\n'}, 'herdr'),
    ({'HERDR_ENV': '1'}, 'herdr'),
])
def test_invalid_local_endpoint_is_rejected_before_query(terminal_env, variables, backend):
    terminal_env.update(variables, CMUX_SURFACE_ID='outer-surface')
    result = shell(terminal_env, 'printf "%s|%s|%s" "$TERM_BACKEND" "$TERM_REASON" "$TERM_TARGET_ID"; term_send y')
    assert result.returncode == 1
    assert result.stdout == 'none|invalid_endpoint|'
    assert result.stderr == ''
    assert calls(terminal_env) == []
    assert not Path(terminal_env['SENT']).exists()


@pytest.mark.parametrize('endpoint', ['t18', 't1c', 't1b'])
def test_hc_local_id_grammar(terminal_env, endpoint):
    terminal_env['HC_TERMINAL_ID'] = endpoint
    result = shell(terminal_env, 'printf "%s" "$TERM_TARGET"')
    assert result.stdout == 'hc:' + endpoint


def test_herdr_local_id_uses_driver_bare_grammar(terminal_env):
    terminal_env.update(HERDR_ENV='1', HERDR_PANE_ID='wA3:p1b')
    assert shell(terminal_env, 'printf "%s" "$TERM_TARGET"').stdout == 'herdr:wA3:p1b'


@pytest.mark.parametrize('hook', ['permission-request.sh', 'codex-permission-request.sh'])
def test_remote_endpoint_never_sends_even_with_runtime_parent(terminal_env, hook):
    env = terminal_env
    env.update(HC_TERMINAL_ID='other-machine/t7', PROMPT_RELAY_POLL_INTERVAL='0.01')
    host = subprocess.check_output(['hostname', '-s'], text=True).strip()
    runtime = Path(env['PROMPT_RELAY_RUNTIME_DIR'])
    (runtime / f'prompt-relay-{host}_hc_other-machine').mkdir(parents=True)
    (runtime / 'prompt-relay-hc_other-machine').mkdir()
    Path(env['SCREEN']).write_text((HOOK_DIR / 'fixtures' / 'codex_permission_hc.txt').read_text())
    result = subprocess.run([str(HOOK_DIR / hook)], env=env,
                            input='{"tool_name":"Bash","tool_input":{"command":"ping -c 1 example.org"}}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stderr == ''
    if hook.startswith('codex'):
        assert json.loads(result.stdout)['hookSpecificOutput']['decision']['behavior'] == 'allow'
    else:
        assert result.stdout == ''
    assert calls(env) == []
    assert not Path(env['SENT']).exists()


@pytest.mark.parametrize('bundled_state', ['executable', 'missing', 'not_executable'])
def test_herdr_binary_path_selection(terminal_env, tmp_path, bundled_state):
    env = terminal_env
    env.update(HERDR_ENV='1', HERDR_PANE_ID='w1:p1')
    directory = tmp_path / 'bundled'
    directory.mkdir()
    bundled = directory / 'herdr'
    if bundled_state != 'missing':
        shutil.copyfile(tmp_path / 'herdr', bundled)
        bundled.chmod(0o755 if bundled_state == 'executable' else 0o644)
    if bundled_state == 'executable':
        # PATH's CLI fails, so successful calls must use the bundled executable.
        (tmp_path / 'herdr').write_text('#!/bin/sh\nexit 1\n')
    env['HERDR_BIN_PATH'] = str(bundled)
    result = shell(env, 'printf "%s\\n" "$TERM_BACKEND"; term_capture; term_send Enter')
    assert result.returncode == 0
    assert result.stdout.startswith('herdr\nviewport\n')
    assert result.stderr == ''
    assert sends(env)[-1] == ['herdr', 'pane', 'send-keys', 'w1:p1', 'enter']


HC_INCOMPLETE = '\n[hc] incomplete: older output may be missing'


def test_hc_history_drops_incomplete_notice(terminal_env):
    terminal_env.update(HC_TERMINAL_ID='t1', HISTORY_SUFFIX=HC_INCOMPLETE)
    Path(terminal_env['SCREEN']).write_text('line one\nesc to cancel')
    result = shell(terminal_env, 'term_capture history; echo "rc=$?"')
    assert result.stdout == 'line one\nesc to cancel\nrc=0\n'


def test_hc_history_keeps_other_last_lines(terminal_env):
    terminal_env.update(HC_TERMINAL_ID='t1', HISTORY_SUFFIX='\nordinary output')
    Path(terminal_env['SCREEN']).write_text('line one')
    result = shell(terminal_env, 'term_capture history')
    assert result.stdout == 'line one\nordinary output\n'


def test_hc_history_read_failure_still_fails(terminal_env):
    terminal_env.update(HC_TERMINAL_ID='t1', READ_FAIL='1')
    result = shell(terminal_env, 'term_capture history; echo "rc=$?"')
    assert result.stdout.strip().endswith('rc=1')


@pytest.mark.parametrize('agent', ['agy', 'claude'])
def test_hc_relay_with_incomplete_history_notice(terminal_env, agent):
    env = terminal_env
    env.update(HC_TERMINAL_ID='t1', HISTORY_SUFFIX=HC_INCOMPLETE, PROMPT_RELAY_POLL_INTERVAL='0.01')
    fixture = 'agy_permission_hc.txt' if agent == 'agy' else 'claude_permission_hc.txt'
    Path(env['SCREEN']).write_text((HOOK_DIR / 'fixtures' / fixture).read_text())
    tool = 'touch /tmp/herdr-probe-agy.txt' if agent == 'agy' else 'touch /tmp/herdr-probe-marker.txt'
    payload = {'toolCall': {'name': 'run_command', 'args': {'CommandLine': tool}}} if agent == 'agy' else {
        'tool_name': 'Bash', 'tool_input': {'command': tool}}
    command = [str(HOOK_DIR / 'permission-request.sh')] + (['--agent', 'agy'] if agent == 'agy' else [])
    result = subprocess.run(command, env=env, input=json.dumps(payload),
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    wait_for_file(env['CANCELLED'])
    assert sends(env)[-1] == ['hc', 'keys', 't1', '1']
    assert not any(row[2] == 'notify_only' for row in records(env))
