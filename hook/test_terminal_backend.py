"""Exercise terminal routing without touching the caller's real terminal."""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

import pytest

import idle_state


HOOK_DIR = Path(__file__).resolve().parent


@pytest.fixture
def terminal_env(tmp_path):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('PROMPT_RELAY_', 'CMUX_', 'TMUX', 'HERDR_', 'HC_'))
           or key in ('PROMPT_RELAY_RUNTIME_DIR', 'PROMPT_RELAY_LOG')}
    env.update({
        'PATH': f'{tmp_path}:{env["PATH"]}',
        'PROMPT_RELAY_CONFIG': str(tmp_path / 'missing'),
        'PROMPT_RELAY_API_KEY': 'test-key',
        'PROMPT_RELAY_SERVER_URL': 'http://relay.test',
        'PROMPT_RELAY_TIMEOUT': '3',
        'PROMPT_RELAY_CODEX_DETECT_TIMEOUT': '2',
        'PROMPT_RELAY_DETECT_INTERVAL': '0.01',
        'PROMPT_RELAY_DETECT_ATTEMPTS': '1',
        'CALLS': str(tmp_path / 'calls'),
        'SCREEN': str(tmp_path / 'screen'),
        'SENT': str(tmp_path / 'sent'),
        'PAYLOADS': str(tmp_path / 'payloads'),
        'REGISTERED': str(tmp_path / 'registered'),
        'RESPONSE_SEEN': str(tmp_path / 'response-seen'),
        'CANCELLED': str(tmp_path / 'cancelled'),
        'TEST_SESSION': 'test-' + uuid.uuid4().hex,
        'CMUX_BUNDLED_CLI_PATH': str(tmp_path / 'cmux'),
        'BASH_ENV': str(tmp_path / 'bash-env'),
    })
    (tmp_path / 'bash-env').write_text('export TEST_HOOK_PID=$$\n')
    (tmp_path / 'screen').write_text('viewport\nsecond line\n')
    fake = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as stream:
    stream.write(json.dumps([Path(sys.argv[0]).name, *args]) + '\\n')
if os.environ.get('CLI_SLEEP'):
    import time
    time.sleep(5)
if os.environ.get('CLI_FAIL'): sys.exit(1)
backend = Path(sys.argv[0]).name
if os.environ.get('FAIL_BACKEND') == backend: sys.exit(1)
if backend in ('herdr', 'hc') and ('process-info' in args or args[0] == 'get'):
    if os.environ.get('BAD_JSON'): print('not json'); sys.exit(0)
    after = Path(os.environ['RESPONSE_SEEN']).exists()
    if after and os.environ.get('PANE_QUERY_FAIL_AFTER_RESPONSE'): sys.exit(1)
    pid = os.environ.get('PANE_PID_AFTER_RESPONSE' if after else 'PANE_PID', os.environ.get('PANE_PID', '424242'))
    pid = int(pid) if pid.isdigit() else pid
    data = {'result': {'process_info': {'shell_pid': pid}}} if backend == 'herdr' else {
        'pid': pid, 'state': os.environ.get('HC_STATE', 'live'),
        'labels': {'where': os.environ.get('WORKSPACE_TITLE', 'team / 1')}}
    print(json.dumps(data))
elif args[:2] == ['workspace', 'get']:
    if os.environ.get('NAME_FAIL'): sys.exit(1)
    print(json.dumps({'result': {'workspace': {'label': os.environ.get('WORKSPACE_TITLE', 'team')}}}))
elif 'read-screen' in args or 'capture-pane' in args or 'read' in args:
    if os.environ.get('READ_FAIL'): sys.exit(1)
    if os.environ.get('READ_FAIL_AFTER_RESPONSE') and Path(os.environ['RESPONSE_SEEN']).exists(): sys.exit(1)
    final = Path(os.environ['CALLS'] + '.final-failures')
    remaining = int(final.read_text()) if final.exists() else int(os.environ.get('FINAL_READ_FAILURES', '0'))
    if Path(os.environ['RESPONSE_SEEN']).exists() and remaining:
        final.write_text(str(remaining - 1))
        sys.exit(1)
    counter = Path(os.environ['CALLS'] + '.failures')
    remaining = int(counter.read_text()) if counter.exists() else int(os.environ.get('POST_REGISTER_FAILURES', '0'))
    if Path(os.environ['REGISTERED']).exists() and remaining:
        counter.write_text(str(remaining - 1))
        sys.exit(1)
    initial = Path(os.environ['CALLS'] + '.initial')
    remaining = int(initial.read_text()) if initial.exists() else int(os.environ.get('INITIAL_EMPTY_READS', '0'))
    if remaining:
        initial.write_text(str(remaining - 1))
        print('working')
        sys.exit(0)
    history = os.environ.get('HISTORY_PREFIX', '') if '-S' in args or '--lines' in args else ''
    suffix = os.environ.get('HISTORY_SUFFIX', '') if '--lines' in args else ''
    print('answered' if Path(os.environ['SENT']).exists() else history + Path(os.environ['SCREEN']).read_text() + suffix)
elif 'send' in args or 'send-key' in args or 'send-keys' in args or 'keys' in args:
    if os.environ.get('SEND_FAIL'): sys.exit(1)
    Path(os.environ['SENT']).touch()
elif 'display-message' in args:
    if os.environ.get('TARGET_FAIL') and '#{window_index}' in args[-1]: sys.exit(1)
    if os.environ.get('NAME_FAIL') and args[-1] == '#{session_name}': sys.exit(1)
    if '#{pane_pid}' in args[-1]:
        if Path(os.environ['RESPONSE_SEEN']).exists():
            if os.environ.get('PANE_QUERY_FAIL_AFTER_RESPONSE'): sys.exit(1)
            pid = os.environ.get('PANE_PID_AFTER_RESPONSE', os.environ.get('PANE_PID', '424242'))
            tty = os.environ.get('PANE_TTY_AFTER_RESPONSE', os.environ.get('PANE_TTY', '/dev/ttys001'))
        else:
            pid = os.environ.get('PANE_PID', '424242')
            tty = os.environ.get('PANE_TTY', '/dev/ttys001')
        print(pid + (' ' + tty if '#{pane_tty}' in args[-1] else ''))
    elif '#{session_id}' in args[-1]: print('$1\\tteam')
    elif '#{window_index}' in args[-1]: print(os.environ['TEST_SESSION'] + ':0.0')
    else: print('team')
elif 'list-workspaces' in args:
    print(json.dumps({'workspaces': [{'id': 'workspace-id', 'title': os.environ.get('WORKSPACE_TITLE', 'team')}]}))
elif 'list-panes' in args:
    print(json.dumps({'panes': [{'id': 'pane-1', 'rows': 24, 'surface_ids': [os.environ.get('CMUX_SURFACE_ID', 'surface-1')]}, {'id': 'pane-2', 'rows': 40, 'surface_ids': ['surface-2']}]}))
elif 'list-pane-surfaces' in args:
    pane = args[args.index('--pane') + 1]
    if os.environ.get('SECOND_PANE_FAIL') and pane == 'pane-2': sys.exit(1)
    print(json.dumps({'surfaces': [{'id': ('SURFACE-' if os.environ.get('UPPER_IDS') else 'surface-') + pane[-1]}]}))
'''
    for name in ('tmux', 'cmux', 'herdr', 'hc'):
        path = tmp_path / name
        path.write_text(fake)
        path.chmod(0o755)
    curl = tmp_path / 'curl'
    curl.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if '-d' in args:
    with open(os.environ['PAYLOADS'], 'a') as stream:
        stream.write(args[args.index('-d') + 1] + '\\n')
if any(arg.endswith('/response') for arg in args):
    from pathlib import Path
    count = Path(os.environ['CALLS'] + '.polls')
    remaining = int(count.read_text()) if count.exists() else int(os.environ.get('PENDING_POLLS', '0'))
    count.write_text(str(max(0, remaining - 1)))
    if remaining:
        print('{}')
    else:
        Path(os.environ['RESPONSE_SEEN']).touch()
        if os.environ.get('REPLACE_WATCHER'):
            target = os.environ['TEST_SESSION'] + ':0.0' if os.environ.get('TMUX') else 'cmux:' + os.environ['CMUX_SURFACE_ID']
            safe = target.replace(':', '_').replace('.', '_')
            (Path(os.environ['PROMPT_RELAY_RUNTIME_DIR']) / ('prompt-relay-' + safe + '.watcher')).write_text('new-watcher')
        if 'AFTER_RESPONSE_SCREEN' in os.environ:
            Path(os.environ['SCREEN']).write_text(os.environ['AFTER_RESPONSE_SCREEN'])
        print(json.dumps({'response': os.environ.get('DECISION', 'allow'), 'send_key': os.environ.get('CHOICE', '1')}))
elif any(arg.endswith('/permission-request') for arg in args):
    from pathlib import Path
    Path(os.environ['REGISTERED']).touch()
    print('{"id":"test-request"}')
    if '-w' in args: print('200')
elif any(arg.endswith('/cancel') for arg in args):
    from pathlib import Path
    Path(os.environ['CANCELLED']).touch()
''')
    curl.chmod(0o755)
    ps = tmp_path / 'ps'
    ps.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
with open(os.environ['CALLS'] + '.ps', 'a') as stream:
    stream.write('tty\\n' if sys.argv[1:3] == ['-o', 'tty='] else 'snapshot\\n')
if os.environ.get('PS_FAIL'): sys.exit(1)
if sys.argv[1:3] == ['-o', 'tty=']:
    if os.environ.get('TTY_QUERY_FAIL'): sys.exit(1)
    after = Path(os.environ['RESPONSE_SEEN']).exists()
    print(os.environ.get('PANE_TTY_AFTER_RESPONSE' if after else 'PANE_TTY', os.environ.get('PANE_TTY', '/dev/ttys001')))
    sys.exit(0)
assert sys.argv[1:] == ['-axo', 'pid=,ppid=,tty=,comm=']
print(os.environ['TEST_HOOK_PID'], 424242, os.environ.get('HOOK_TTY', 'ttys001'), '/bin/bash')
print(os.environ.get('PS_ANCESTORS', '424242 1 ' + os.environ.get('ANCESTOR_TTY', 'ttys001') + ' ' + os.environ.get('ANCESTOR_COMM', '/bin/bash')))
''')
    ps.chmod(0o755)
    return env


def calls(env):
    path = Path(env['CALLS'])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def shell(env, script):
    return subprocess.run(['bash', '-c', 'source "$1/common.sh"\n' + script, 'bash', str(HOOK_DIR)],
                          env=env, text=True, capture_output=True, timeout=5)


@pytest.mark.parametrize(('variables', 'backend'), [
    ({}, 'none'),
    ({'TMUX_PANE': '%1'}, 'none'),
    ({'TMUX': 'socket'}, 'none'),
    ({'TMUX': 'socket', 'CMUX_SURFACE_ID': 'stale'}, 'none'),
    ({'CMUX_SURFACE_ID': 'surface-1'}, 'cmux'),
    ({'TMUX_PANE': '%1', 'CMUX_SURFACE_ID': 'surface-1'}, 'cmux'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, 'tmux'),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1', 'CMUX_SURFACE_ID': 'stale'}, 'tmux'),
])
def test_backend_detection_ignores_unrelated_tmux_server(terminal_env, variables, backend):
    terminal_env.update(variables)
    result = shell(terminal_env, 'printf "%s" "$TERM_BACKEND"')
    assert result.returncode == 0
    assert result.stdout == backend
    terminal_calls = calls(terminal_env)
    if backend != 'tmux':
        assert not any(call[0] == 'tmux' for call in terminal_calls)
    else:
        assert terminal_calls
        assert all(call[call.index('-t') + 1] == '%1' for call in terminal_calls)
    if backend != 'none':
        assert Path(terminal_env['CALLS'] + '.ps').read_text() == 'snapshot\n'


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
def test_capture_and_keys_always_target_calling_terminal(terminal_env, backend):
    if backend == 'tmux':
        terminal_env.update(TMUX='socket', TMUX_PANE='%1')
    else:
        terminal_env.update(CMUX_SURFACE_ID='surface-1')
    result = shell(terminal_env, 'term_capture; term_capture history; term_capture joined; '
                   'term_send 1; term_send y; term_send Escape; term_send Enter')
    assert result.returncode == 0
    actual = calls(terminal_env)
    if backend == 'tmux':
        assert all(call[call.index('-t') + 1] == '%1' for call in actual)
        assert any('-J' in call for call in actual)
        assert any('-S' in call for call in actual)
    else:
        assert all(call[call.index('--surface') + 1] == 'surface-1' for call in actual if '--surface' in call)
        assert any(call[-2:] == ['--lines', '200'] for call in actual)
        sends = [call for call in actual if call[1] in ('send', 'send-key')]
        assert len(sends) == 4
        assert all('--force' in call for call in sends)
        assert sends[-2][-1] == 'escape'
        assert sends[-1][-1] == 'enter'


@pytest.mark.parametrize(('variables', 'failure'), [
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, {'PANE_PID': '777777'}),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, {'PS_FAIL': '1'}),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, {'CLI_FAIL': '1'}),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, {'TARGET_FAIL': '1'}),
    ({'TMUX': 'socket', 'TMUX_PANE': '%1'}, {'NAME_FAIL': '1'}),
    ({'CMUX_SURFACE_ID': 'surface-1'}, {'ANCESTOR_COMM': '/bin/codex', 'ANCESTOR_TTY': '??'}),
    ({'CMUX_SURFACE_ID': 'surface-1'}, {'PS_FAIL': '1'}),
])
def test_unverified_terminal_disables_capture_and_keys(terminal_env, variables, failure):
    terminal_env.update(variables, **failure)
    result = shell(terminal_env, 'printf "%s|%s|%s|%s" "$TERM_BACKEND" "$TERM_TARGET" '
                   '"$TERM_TARGET_ID" "$TERM_NAME"; term_capture; term_send y')
    assert result.stdout == 'none|||'
    assert not Path(terminal_env['SENT']).exists()
    assert not any(call[1] in ('capture-pane', 'read-screen', 'send', 'send-key', 'send-keys')
                   for call in calls(terminal_env))
    assert Path(terminal_env['CALLS'] + '.ps').read_text() == 'snapshot\n'


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
@pytest.mark.parametrize(('ancestors', 'hook_tty', 'pane_pid', 'expected'), [
    ('424242 1 ?? /opt/bin/codex', '??', '424242', 'none'),
    ('424242 1 - /Applications/Codex App/bin/codex', '-', '424242', 'none'),
    ('424242 424243 ?? /opt/bin/codex\n424243 424244 ttys001 /opt/bin/codex\n'
     '424244 1 ttys001 /bin/bash', '??', '424244', 'none'),
    ('424242 424243 ?? /bin/bash\n424243 424244 ttys001 /opt/bin/codex\n'
     '424244 1 ttys001 /bin/bash', '??', '424244', 'valid'),
    ('424242 1 ?? /bin/bash', '??', '424242', 'none'),
    ('424242 1 - /bin/bash', '-', '424242', 'none'),
    ('424242 424243 ? /opt/bin/codex\n424243 1 pts/3 /bin/bash', '?', '424243', 'none'),
    ('424242 424243 ? /bin/bash\n424243 1 pts/3 /opt/bin/codex', '?', '424243', 'valid'),
    ('424242 1 ? /bin/bash', '?', '424242', 'none'),
])
def test_ancestor_tty_and_executable_control_transport(
        terminal_env, backend, ancestors, hook_tty, pane_pid, expected):
    terminal_env.update(PS_ANCESTORS=ancestors, HOOK_TTY=hook_tty, PANE_PID=pane_pid)
    if 'pts/3' in ancestors:
        terminal_env['PANE_TTY'] = '/dev/pts/3'
    terminal_env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else terminal_env.update(
        CMUX_SURFACE_ID='surface-1')
    # ps projects comm, so global options before app-server cannot hide codex.
    terminal_env['ANCESTOR_COMMAND'] = 'codex -c features.code_mode_host=true app-server --listen unix://'
    result = shell(terminal_env, 'printf "%s" "$TERM_BACKEND"')
    assert result.returncode == 0
    assert result.stdout == (backend if expected == 'valid' else 'none')
    assert result.stderr == ''


@pytest.mark.parametrize('executable', ['/opt/bin/claude', '/Applications/Codex App/bin/codex'])
def test_prompt_words_do_not_disable_interactive_cmux(terminal_env, executable):
    terminal_env.update(CMUX_SURFACE_ID='surface-1', ANCESTOR_COMM=executable,
                        ANCESTOR_COMMAND="codex --no-daemon 'Explain codex app-server lifecycle'")
    result = shell(terminal_env, 'printf "%s" "$TERM_BACKEND"')
    assert result.returncode == 0
    assert result.stdout == 'cmux'
    assert result.stderr == ''


@pytest.mark.parametrize('change', ['PANE_PID=777777', 'CLI_FAIL=1'])
def test_tmux_send_rejects_changed_or_unreadable_owner(terminal_env, change):
    terminal_env.update(TMUX='socket', TMUX_PANE='%1')
    result = shell(terminal_env, 'export ' + change + '; term_send y')
    assert result.returncode != 0
    assert result.stdout == result.stderr == ''
    assert not Path(terminal_env['SENT']).exists()
    assert not any(call[1] == 'send-keys' for call in calls(terminal_env))
    assert len([call for call in calls(terminal_env) if '#{pane_pid}' in call[-1]]) == 2


@pytest.mark.parametrize(('pane_pid', 'pane_tty', 'hook_tty', 'expected'), [
    ('71004', '/dev/ttys100', '??', 'none'),
    ('71002', '/dev/ttys201', '??', 'tmux'),
    ('71002', '', '??', 'none'),
    ('71002', '/dev/ttys201', 'ttys202', 'none'),
])
def test_tmux_pane_must_match_nearest_controlling_terminal(
        terminal_env, pane_pid, pane_tty, hook_tty, expected):
    terminal_env.update(
        TMUX='socket', TMUX_PANE='%1', PANE_PID=pane_pid, PANE_TTY=pane_tty,
        HOOK_TTY=hook_tty,
        PS_ANCESTORS=('424242 71001 ?? /bin/bash\n'
                      '71001 71002 ttys201 /opt/bin/codex\n'
                      '71002 71003 ttys201 /bin/bash\n'
                      '71003 71004 ttys100 /opt/bin/tmux\n'
                      '71004 1 ttys100 /bin/bash'))
    result = shell(terminal_env, 'printf "%s" "$TERM_BACKEND"; term_send y')
    assert result.stdout == expected
    assert result.stderr == ''
    assert (result.returncode == 0) == (expected == 'tmux')
    assert Path(terminal_env['SENT']).exists() == (expected == 'tmux')
    owner_queries = [call for call in calls(terminal_env) if '#{pane_pid}' in call[-1]]
    assert owner_queries[0][-1] == '#{pane_pid} #{pane_tty}'
    assert len(owner_queries) == (2 if expected == 'tmux' else 1)


@pytest.mark.parametrize('backend', ['none', 'tmux', 'cmux'])
def test_permission_notification_only_without_screen_transport(terminal_env, backend):
    if backend == 'tmux':
        terminal_env.update(TMUX='socket', TMUX_PANE='%1')
    elif backend == 'cmux':
        terminal_env['CMUX_SURFACE_ID'] = 'surface-1'
    result = subprocess.run([str(HOOK_DIR / 'notification.sh')], env=terminal_env,
                            input='{"hook_event_name":"Notification","notification_type":"permission_prompt"}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ''
    payload = Path(terminal_env['PAYLOADS'])
    assert payload.exists() == (backend == 'none')
    if backend == 'none':
        body = json.loads(payload.read_text())
        assert body['title'] == '承認待ち'
        assert 'choices' not in body
        assert 'category' not in body


def test_cmux_context_and_all_panes(terminal_env, monkeypatch):
    for key, value in terminal_env.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setenv('CMUX_SURFACE_ID', 'surface-1')
    monkeypatch.setenv('CMUX_WORKSPACE_ID', 'workspace-id')
    ctx = idle_state.context('cmux', check_membership=True)
    assert ctx == {'pane': 'surface-1', 'session': 'workspace-id', 'name': '', 'backend': 'cmux'}
    assert idle_state.live_panes(ctx) == {'surface-1', 'surface-2'}
    actual = calls(terminal_env)
    assert all('--id-format' in call and 'uuids' in call for call in actual)
    assert [call[-1] for call in actual if 'list-pane-surfaces' in call] == ['pane-1', 'pane-2'] * 2


@pytest.mark.parametrize('failure', ['CLI_FAIL', 'SECOND_PANE_FAIL'])
def test_cmux_query_failure_does_not_prune_or_notify(terminal_env, monkeypatch, tmp_path, failure):
    for key, value in terminal_env.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setenv('PROMPT_RELAY_STATE_DIR', str(tmp_path / 'states'))
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '0')
    ctx = {'pane': 'surface-1', 'session': 'workspace-id', 'name': 'team', 'backend': 'cmux'}
    a = idle_state.IdleState(ctx, 'host')
    b = idle_state.IdleState(dict(ctx, pane='surface-2'), 'host')
    b.update('busy')
    token = a.update('idle')
    monkeypatch.setenv(failure, '1')
    with pytest.raises(subprocess.CalledProcessError):
        a.claim_notification(token)
    assert b.pane_path('surface-2').exists()
    assert not (a.directory / 'meta').exists()


def test_cmux_name_failure_omits_display_name(terminal_env):
    terminal_env.update(CMUX_SURFACE_ID='surface-1', CMUX_WORKSPACE_ID='workspace-id', CLI_FAIL='1')
    result = shell(terminal_env, 'term_display_host; printf "%s" "$DISPLAY_HOST|$HOSTNAME_SHORT"')
    display, host = result.stdout.split('|')
    assert display == host


@pytest.mark.parametrize(('hook', 'mode'), [
    ('permission-request.sh', 'auto'),
    ('codex-permission-request.sh', 'auto'),
    ('codex-permission-request.sh', 'tmux'),
])
def test_cmux_permission_roundtrip(terminal_env, hook, mode):
    surface = str(uuid.uuid4())
    terminal_env.update(CMUX_SURFACE_ID=surface, CMUX_WORKSPACE_ID='workspace-id',
                        PROMPT_RELAY_CODEX_MODE=mode)
    prompt = ('Would you like to run the following command?\n› 1. Yes, proceed (y)\n'
              '  2. No, and tell Codex what to do differently (esc)\n') if hook.startswith('codex') else (
                  '☐ Claude wants to use Bash\n  ls\n❯ 1. Allow\n  2. Deny\nEsc to cancel\n')
    Path(terminal_env['SCREEN']).write_text(prompt)
    result = subprocess.run([str(HOOK_DIR / hook)], env=terminal_env,
                            input='{"tool_name":"Bash","tool_input":{"command":"ls"}}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ''
    deadline = time.monotonic() + 5
    while not Path(terminal_env['SENT']).exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert Path(terminal_env['SENT']).exists()
    payload = json.loads(Path(terminal_env['PAYLOADS']).read_text().splitlines()[0])
    assert payload['tmux_target'].endswith(':cmux:' + surface)
    sends = [call for call in calls(terminal_env) if call[1] == 'send']
    assert sends[-1][-1] == ('y' if hook.startswith('codex') else '1')
    assert '--force' in sends[-1]
    assert sends[-1][sends[-1].index('--surface') + 1] == surface


def test_cmux_busy_peer_blocks_then_group_notifies_once(terminal_env, monkeypatch, tmp_path):
    for key, value in terminal_env.items():
        monkeypatch.setenv(key, value)
    monkeypatch.setenv('PROMPT_RELAY_STATE_DIR', str(tmp_path / 'states'))
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '0')
    ctx = {'pane': 'surface-1', 'session': 'workspace-id', 'name': 'team', 'backend': 'cmux'}
    a = idle_state.IdleState(ctx, 'host')
    b = idle_state.IdleState(dict(ctx, pane='surface-2'), 'host')
    other = idle_state.IdleState(dict(ctx, session='other-workspace'), 'host')
    other.update('busy')
    b.update('busy')
    assert not a.claim_notification(a.update('idle'))
    assert b.claim_notification(b.update('idle'))
    assert not a.claim_notification(a.update('idle'))


def test_cmux_session_notification_uses_workspace_id(terminal_env, tmp_path):
    terminal_env.update(CMUX_SURFACE_ID='surface-1', CMUX_WORKSPACE_ID='workspace-id',
                        PROMPT_RELAY_IDLE_SCOPE='session', PROMPT_RELAY_IDLE_GRACE='0',
                        PROMPT_RELAY_STATE_DIR=str(tmp_path / 'states'))
    result = subprocess.run([str(HOOK_DIR / 'notification.sh'), '--agent', 'claude'],
                            env=terminal_env, input='{"hook_event_name":"Stop"}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ''
    deadline = time.monotonic() + 5
    payloads = Path(terminal_env['PAYLOADS'])
    while not payloads.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    body = json.loads(payloads.read_text())
    assert body['tmux_target'].endswith(':cmux:workspace-id')
    assert body['hostname'].endswith(':team')
    assert body['message'] == '全エージェントの処理が完了しました'


@pytest.mark.parametrize(('mode', 'cmux_surface', 'direct_response'), [
    ('auto', False, True),
    ('direct', True, True),
    ('tmux', False, False),
])
def test_codex_modes_without_screen_or_with_explicit_direct(terminal_env, mode, cmux_surface, direct_response):
    terminal_env['PROMPT_RELAY_CODEX_MODE'] = mode
    if cmux_surface:
        terminal_env['CMUX_SURFACE_ID'] = 'surface-1'
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env,
                            input='{"tool_name":"Bash","tool_input":{"command":"ls"}}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    if direct_response:
        assert json.loads(result.stdout)['hookSpecificOutput']['decision']['behavior'] == 'allow'
    else:
        assert result.stdout == ''
        assert not Path(terminal_env['PAYLOADS']).exists()
    assert not any(call[1] in ('read-screen', 'send', 'send-key', 'capture-pane', 'send-keys')
                   for call in calls(terminal_env))


CLAUDE_PROMPT = '☐ Claude wants to use Bash\n  ls\n❯ 1. Allow\n  2. Deny\nEsc to cancel\n'
CODEX_PROMPT = 'Would you like to run the following command?\n› 1. Yes, proceed (y)\n  2. No (esc)\n'


def wait_for_file(path):
    deadline = time.monotonic() + 8
    while not Path(path).exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert Path(path).exists()


@pytest.mark.parametrize('change', ['PANE_PID_AFTER_RESPONSE', 'PANE_TTY_AFTER_RESPONSE',
                                    'PANE_QUERY_FAIL_AFTER_RESPONSE'])
def test_codex_pending_approval_cannot_send_to_replaced_tmux_pane(terminal_env, change):
    terminal_env.update(TMUX='socket', TMUX_PANE='%1')
    terminal_env[change] = {'PANE_PID_AFTER_RESPONSE': '777777',
                            'PANE_TTY_AFTER_RESPONSE': '/dev/ttys002'}.get(change, '1')
    Path(terminal_env['SCREEN']).write_text(CODEX_PROMPT)
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env,
                            input='{}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == result.stderr == ''
    wait_for_file(terminal_env['CANCELLED'])
    assert Path(terminal_env['RESPONSE_SEEN']).exists()
    assert not Path(terminal_env['SENT']).exists()
    assert not any(call[1] == 'send-keys' for call in calls(terminal_env))
    assert len([call for call in calls(terminal_env) if '#{pane_pid}' in call[-1]]) == 2


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
@pytest.mark.parametrize('agent', ['claude', 'codex'])
@pytest.mark.parametrize('scenario', ['vanished', 'changed', 'read_error', 'send_error',
                                      'transient_read', 'persistent_read', 'deny_without_key',
                                      'body_changed', 'long_body_changed', 'old_history', 'unnumbered',
                                      'unnumbered_changed', 'final_transient_read',
                                      'indent_changed', 'heading_phrase', 'footer_input', 'old_footer_history'])
def test_permission_rechecks_and_failures(terminal_env, backend, agent, scenario):
    env = terminal_env
    env['PROMPT_RELAY_TIMEOUT'] = '8'
    env['PROMPT_RELAY_POLL_INTERVAL'] = '0.01'
    env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else env.update(
        CMUX_SURFACE_ID=str(uuid.uuid4()), CMUX_WORKSPACE_ID='workspace-id')
    prompt = CODEX_PROMPT if agent == 'codex' else CLAUDE_PROMPT
    if scenario in ('body_changed', 'long_body_changed'):
        command = 'echo harmless' if scenario == 'body_changed' else 'echo ' + 'x' * 300 + ' harmless'
        prompt = prompt.replace('  ls', '  ' + command) if agent == 'claude' else prompt.replace('command?\n', 'command?\n  $ ' + command + '\n')
        env['AFTER_RESPONSE_SCREEN'] = prompt.replace('harmless', 'rm -rf important-directory')
    if scenario == 'old_history': env['HISTORY_PREFIX'] = '1. earlier output\n2. earlier output\n'
    if scenario == 'old_footer_history': env['HISTORY_PREFIX'] = '☐ Earlier command\n❯ 1. Yes\n  2. No\nEsc to cancel\nEarlier output\n'
    if scenario in ('unnumbered', 'unnumbered_changed'):
        if agent != 'codex': pytest.skip('Codex compatibility path')
        prompt = 'Would you like to run the following command?\n  $ echo harmless\nAllow / Deny'
        if scenario == 'unnumbered_changed': env['AFTER_RESPONSE_SCREEN'] = prompt.replace('harmless', 'different')
    # Whitespace presence and position are ignored: generation checks guard stale replies.
    if scenario in ('indent_changed', 'heading_phrase'):
        command = ("python3 - <<'PY'\nif False:\n    pass\n    print('remove important data')\nPY"
                   if scenario == 'indent_changed' else "echo harmless\necho 'would you like to run'")
        prompt = prompt.replace('  ls', command) if agent == 'claude' else prompt.replace('command?\n', 'command?\n  $ ' + command + '\n')
        env['AFTER_RESPONSE_SCREEN'] = (prompt.replace("    print(", "print(") if scenario == 'indent_changed'
                                        else prompt.replace('echo harmless', 'rm -rf important-directory'))
    if scenario == 'footer_input':
        if agent == 'codex': prompt += '\nPress enter to confirm'
        env['AFTER_RESPONSE_SCREEN'] = prompt + '\n\nCommand finished.\n❯ Type your next instruction'
    Path(env['SCREEN']).write_text(prompt)
    if scenario == 'vanished': env['AFTER_RESPONSE_SCREEN'] = 'Type your next instruction'
    if scenario == 'changed': env['AFTER_RESPONSE_SCREEN'] = prompt.replace('Allow', 'Permit').replace('proceed', 'continue')
    if scenario == 'final_transient_read': env['FINAL_READ_FAILURES'] = '2'
    if scenario == 'read_error': env['READ_FAIL_AFTER_RESPONSE'] = '1'
    if scenario == 'send_error': env['SEND_FAIL'] = '1'
    if scenario in ('transient_read', 'persistent_read'):
        env.update(POST_REGISTER_FAILURES='2' if scenario == 'transient_read' else '50',
                   PENDING_POLLS='1' if scenario == 'transient_read' else '50')
    if scenario == 'deny_without_key': env.update(CHOICE='', DECISION='deny')
    script = 'codex-permission-request.sh' if agent == 'codex' else 'permission-request.sh'
    result = subprocess.run([str(HOOK_DIR / script)], env=env, text=True, capture_output=True,
                            input='{"tool_name":"Bash","tool_input":{"command":"ls"}}', timeout=5)
    assert result.returncode == 0
    assert result.stdout == ''
    wait_for_file(env['CANCELLED'])
    sends = [call for call in calls(env) if call[1] in ('send', 'send-key', 'send-keys')]
    assert len(sends) == (1 if scenario in ('send_error', 'transient_read', 'deny_without_key', 'old_history', 'unnumbered', 'final_transient_read', 'old_footer_history', 'indent_changed') else 0)
    if scenario == 'deny_without_key':
        assert sends[0][-1] == ('2' if agent == 'claude' else 'escape' if backend == 'cmux' else 'Escape')
    payloads = [json.loads(line) for line in Path(env['PAYLOADS']).read_text().splitlines()]
    notices = [body for body in payloads if body.get('title') == '承認待ち']
    assert bool(notices) == (scenario in ('read_error', 'send_error', 'persistent_read', 'unnumbered_changed'))
    if notices:
        assert notices[-1]['message'] == ('端末で操作してください' if scenario in ('read_error', 'send_error', 'unnumbered_changed') else '端末で確認してください')
    if scenario == 'persistent_read':
        assert Path(env['CALLS'] + '.failures').read_text() == '45'


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
def test_permission_notification_when_transport_is_unavailable(terminal_env, backend):
    env = terminal_env
    env['CLI_FAIL'] = '1'
    env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else env.update(CMUX_SURFACE_ID='surface-1')
    result = subprocess.run([str(HOOK_DIR / 'notification.sh')], env=env, text=True, capture_output=True,
                            input='{"notification_type":"permission_prompt"}', timeout=5)
    assert result.returncode == 0
    assert json.loads(Path(env['PAYLOADS']).read_text())['title'] == '承認待ち'


def test_unavailable_cmux_codex_uses_direct_response(terminal_env):
    terminal_env.update(CMUX_SURFACE_ID='surface-1', CLI_FAIL='1')
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env,
                            input='{}', text=True, capture_output=True, timeout=5)
    assert json.loads(result.stdout)['hookSpecificOutput']['decision']['behavior'] == 'allow'
    assert not json.loads(Path(terminal_env['PAYLOADS']).read_text())['has_tmux']


@pytest.mark.parametrize('variables', [
    {'TMUX': 'socket', 'TMUX_PANE': '%1', 'PANE_PID': '777777'},
    {'CMUX_SURFACE_ID': 'surface-1', 'ANCESTOR_COMM': '/bin/codex', 'ANCESTOR_TTY': '??'},
])
def test_unverified_codex_terminal_returns_direct_decision(terminal_env, variables):
    terminal_env.update(variables)
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env,
                            input='{}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert json.loads(result.stdout)['hookSpecificOutput']['decision']['behavior'] == 'allow'
    assert not json.loads(Path(terminal_env['PAYLOADS']).read_text())['has_tmux']
    assert not Path(terminal_env['SENT']).exists()


def test_cmux_timeout_and_lazy_name_resolution(terminal_env):
    terminal_env.update(CMUX_SURFACE_ID='surface-1', CMUX_WORKSPACE_ID='workspace-id')
    assert shell(terminal_env, ':').returncode == 0
    assert calls(terminal_env) == []
    terminal_env['CLI_SLEEP'] = '1'
    started = time.monotonic()
    result = shell(terminal_env, 'term_capture')
    assert result.returncode != 0
    assert result.stdout == result.stderr == ''
    assert time.monotonic() - started < 4


def test_fallback_notification_escapes_workspace_and_message(terminal_env):
    title = 'quote" slash\\ newline\nend'
    terminal_env.update(CMUX_SURFACE_ID='surface-1', CMUX_WORKSPACE_ID='workspace-id', WORKSPACE_TITLE=title)
    assert shell(terminal_env, 'notify_fallback "$WORKSPACE_TITLE"').returncode == 0
    body = json.loads(Path(terminal_env['PAYLOADS']).read_text())
    assert body['message'] == title
    assert body['hostname'].endswith(':' + title)


@pytest.mark.parametrize('agent', ['claude', 'codex', 'agy'])
def test_moved_surface_falls_back_to_individual_notification(terminal_env, agent, tmp_path):
    terminal_env.update(CMUX_SURFACE_ID='moved-surface', CMUX_WORKSPACE_ID='workspace-id',
                        PROMPT_RELAY_IDLE_SCOPE='session', PROMPT_RELAY_CODEX_GOAL_AWARE='false',
                        PROMPT_RELAY_STATE_DIR=str(tmp_path / 'states'))
    args = [str(HOOK_DIR / 'notification.sh'), '--agent', agent]
    if agent == 'agy': args += ['--event', 'Stop']
    result = subprocess.run(args, env=terminal_env, input='{"hook_event_name":"Stop"}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    if agent == 'claude':
        assert not Path(terminal_env['PAYLOADS']).exists()
        result = subprocess.run(args, env=terminal_env, input='{"hook_event_name":"Notification","notification_type":"idle_prompt"}',
                                text=True, capture_output=True, timeout=5)
        assert result.returncode == 0
    path = Path(terminal_env['PAYLOADS'])
    if agent == 'agy':
        assert not path.exists()
    else:
        body = json.loads(path.read_text())
        assert '全エージェント' not in body['message']
    assert not (tmp_path / 'states').exists()


def test_cmux_id_comparisons_ignore_case(terminal_env, monkeypatch, tmp_path):
    for key, value in terminal_env.items(): monkeypatch.setenv(key, value)
    monkeypatch.setenv('CMUX_SURFACE_ID', 'SURFACE-1')
    monkeypatch.setenv('CMUX_WORKSPACE_ID', 'workspace-id')
    monkeypatch.setenv('PROMPT_RELAY_STATE_DIR', str(tmp_path / 'states'))
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '0')
    ctx = idle_state.context('cmux', check_membership=True)
    assert ctx is not None
    a = idle_state.IdleState(ctx, 'host')
    b = idle_state.IdleState(dict(ctx, pane='SURFACE-2'), 'host')
    b.update('busy')
    assert not a.claim_notification(a.update('idle'))
    assert b.pane_path('SURFACE-2').exists()
    assert b.claim_notification(b.update('idle'))


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
def test_new_claude_watcher_prevents_old_reply(terminal_env, backend):
    env = terminal_env
    env.update(REPLACE_WATCHER='1', PROMPT_RELAY_TIMEOUT='5')
    env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else env.update(CMUX_SURFACE_ID=str(uuid.uuid4()))
    Path(env['SCREEN']).write_text(CLAUDE_PROMPT)
    result = subprocess.run([str(HOOK_DIR / 'permission-request.sh')], env=env, input='{}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    wait_for_file(env['CANCELLED'])
    assert not any(call[1] in ('send', 'send-key', 'send-keys') for call in calls(env))
    target = env['TEST_SESSION'] + ':0.0' if backend == 'tmux' else 'cmux:' + env['CMUX_SURFACE_ID']
    (Path(env['PROMPT_RELAY_RUNTIME_DIR']) / ('prompt-relay-' + target.replace(':', '_').replace('.', '_') + '.watcher')).unlink()


def test_pretool_capture_failure_does_not_invent_permission_notification(terminal_env):
    env = terminal_env
    env.update(CMUX_SURFACE_ID=str(uuid.uuid4()), CLI_FAIL='1')
    result = subprocess.run([str(HOOK_DIR / 'permission-request.sh')], env=env, input='{"tool_name":"Read"}',
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    watcher = Path(env['PROMPT_RELAY_RUNTIME_DIR']) / ('prompt-relay-cmux_' + env['CMUX_SURFACE_ID'] + '.watcher')
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        reads = [call for call in calls(env) if 'read-screen' in call]
        if len(reads) == 5 and not watcher.exists(): break
        time.sleep(0.02)
    assert len(reads) == 5
    assert not watcher.exists()
    assert not Path(env['PAYLOADS']).exists()


def test_unavailable_cmux_required_hybrid_exits_without_direct_response(terminal_env):
    terminal_env.update(CMUX_SURFACE_ID='surface-1', CLI_FAIL='1', PROMPT_RELAY_CODEX_MODE='tmux')
    result = subprocess.run([str(HOOK_DIR / 'codex-permission-request.sh')], env=terminal_env,
                            input='{}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ''
    assert not Path(terminal_env['PAYLOADS']).exists()


@pytest.mark.parametrize('agent', ['claude', 'agy'])
def test_busy_is_recorded_without_enumeration_and_blocks_false_completion(terminal_env, monkeypatch, tmp_path, agent):
    env = terminal_env
    env.update(CMUX_SURFACE_ID='surface-1', CMUX_WORKSPACE_ID='workspace-id',
               PROMPT_RELAY_IDLE_SCOPE='session', PROMPT_RELAY_STATE_DIR=str(tmp_path / 'states'),
               PROMPT_RELAY_IDLE_GRACE='0')
    for key, value in env.items(): monkeypatch.setenv(key, value)
    ctx = idle_state.context('cmux')
    host = subprocess.check_output(['hostname', '-s'], text=True).strip()
    a = idle_state.IdleState(ctx, host)
    b = idle_state.IdleState(dict(ctx, pane='surface-2'), host)
    a.update('idle')
    token = b.update('idle')
    args = [str(HOOK_DIR / 'notification.sh'), '--agent', agent]
    if agent == 'agy': args += ['--event', 'PreInvocation']
    result = subprocess.run(args, env=dict(env, SECOND_PANE_FAIL='1'),
                            input='{"hook_event_name":"UserPromptSubmit"}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert a.read(a.pane_path('surface-1'))['status'] == 'busy'
    assert not any('list-panes' in call or 'list-pane-surfaces' in call for call in calls(env))
    assert not b.claim_notification(token)


def test_stop_enumeration_failure_keeps_context_and_records_idle(terminal_env, monkeypatch, tmp_path):
    env = terminal_env
    env.update(CMUX_SURFACE_ID='surface-1', CMUX_WORKSPACE_ID='workspace-id',
               PROMPT_RELAY_IDLE_SCOPE='session', PROMPT_RELAY_STATE_DIR=str(tmp_path / 'states'),
               SECOND_PANE_FAIL='1', PROMPT_RELAY_IDLE_GRACE='0')
    for key, value in env.items(): monkeypatch.setenv(key, value)
    ctx = idle_state.context('cmux', check_membership=True)
    assert ctx is not None
    host = subprocess.check_output(['hostname', '-s'], text=True).strip()
    state = idle_state.IdleState(ctx, host)
    state.update('busy')
    result = subprocess.run([str(HOOK_DIR / 'notification.sh'), '--agent', 'claude'], env=env,
                            input='{"hook_event_name":"Stop"}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert state.read(state.pane_path('surface-1'))['status'] == 'idle'
    with pytest.raises(subprocess.CalledProcessError):
        state.claim_notification(state.read(state.pane_path('surface-1'))['token'])
    assert not Path(env['PAYLOADS']).exists()


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
@pytest.mark.parametrize('scenario', ['allow', 'choice2', 'choice3', 'deny', 'deny_without_key',
                                     'body_changed', 'menu_changed', 'vanished', 'footer_output',
                                     'watcher_replaced', 'read_error', 'invalid_key', 'delayed'])
def test_agy_permission_relay(terminal_env, backend, scenario):
    env = terminal_env
    env['PROMPT_RELAY_TIMEOUT'] = '8'
    env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else env.update(
        CMUX_SURFACE_ID=str(uuid.uuid4()), CMUX_WORKSPACE_ID='workspace-id')
    prompt = (HOOK_DIR / 'fixtures' / f'agy_permission_{backend}.txt').read_text()
    Path(env['SCREEN']).write_text(prompt)
    if scenario == 'body_changed': env['AFTER_RESPONSE_SCREEN'] = prompt.replace('relay-example', 'different-command')
    if scenario == 'menu_changed': env['AFTER_RESPONSE_SCREEN'] = prompt.replace('Yes, run command', 'Yes, run another command')
    if scenario == 'vanished': env['AFTER_RESPONSE_SCREEN'] = 'Ready for input'
    if scenario == 'footer_output': env['AFTER_RESPONSE_SCREEN'] = prompt + '\nCommand completed.\n> '
    if scenario == 'watcher_replaced': env['REPLACE_WATCHER'] = '1'
    if scenario == 'read_error': env['READ_FAIL_AFTER_RESPONSE'] = '1'
    if scenario == 'invalid_key': env['CHOICE'] = '12'
    if scenario == 'choice2': env['CHOICE'] = '2'
    if scenario == 'choice3': env['CHOICE'] = '3'
    if scenario == 'deny': env.update(CHOICE='4', DECISION='deny')
    if scenario == 'deny_without_key': env.update(CHOICE='', DECISION='deny')
    if scenario == 'delayed':
        env.pop('PROMPT_RELAY_DETECT_ATTEMPTS')
        env['INITIAL_EMPTY_READS'] = '12'
    payload = {'toolCall': {'name': 'run_command', 'args': {
        'CommandLine': 'touch /tmp/relay-example.txt', 'toolSummary': 'Create example'}}}
    started = time.monotonic()
    result = subprocess.run([str(HOOK_DIR / 'permission-request.sh'), '--agent', 'agy'],
                            env=env, input=json.dumps(payload), text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == '{"decision":"allow"}\n'
    assert time.monotonic() - started < 2  # The worker must not hold the stdout pipe open.
    wait_for_file(env['CANCELLED'])
    sends = [call for call in calls(env) if call[1] in ('send', 'send-key', 'send-keys')]
    should_send = scenario in ('allow', 'choice2', 'choice3', 'deny', 'deny_without_key', 'delayed')
    assert len(sends) == int(should_send)
    if sends:
        assert sends[0][-1] == {'choice2': '2', 'choice3': '3', 'deny': '4', 'deny_without_key': '4'}.get(scenario, '1')
        if backend == 'cmux': assert '--force' in sends[0]
    requests = [json.loads(line) for line in Path(env['PAYLOADS']).read_text().splitlines()]
    request = next(body for body in requests if 'choices' in body)
    assert request['tool_name'] == 'run_command'
    assert request['description'] == 'touch /tmp/relay-example.txt'
    assert [c['number'] for c in request['choices']] == [1, 2, 3, 4]


@pytest.mark.parametrize('failure', ['none', 'missing_key', 'short_key', 'long_key', 'transport'])
def test_agy_permission_json_on_early_exit(terminal_env, failure):
    if failure == 'missing_key': terminal_env['PROMPT_RELAY_API_KEY'] = ''
    if failure == 'short_key': terminal_env['PROMPT_RELAY_API_KEY'] = 'x'
    if failure == 'long_key': terminal_env['PROMPT_RELAY_API_KEY'] = 'x' * 129
    if failure == 'transport': terminal_env.update(TMUX='socket', TMUX_PANE='%1', CLI_FAIL='1')
    result = subprocess.run([str(HOOK_DIR / 'permission-request.sh'), '--agent', 'agy'],
                            env=terminal_env, input='{}', text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == '{"decision":"allow"}\n'
    assert not Path(terminal_env['PAYLOADS']).exists()


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
@pytest.mark.parametrize('tool', [
    {'name': 'view_file', 'args': {'toolSummary': 'View hosts'}},
    {'name': 'run_command', 'args': {'CommandLine': 'git status'}},
    {'name': 'list_dir', 'args': {}},
    {'name': 'run_command', 'args': {'CommandLine': 'touch /tmp/different-command.txt'}},
])
def test_agy_unrelated_hook_cannot_register_screen_command(terminal_env, backend, tool):
    env = terminal_env
    env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else env.update(
        CMUX_SURFACE_ID=str(uuid.uuid4()))
    prompt = (HOOK_DIR / 'fixtures' / f'agy_permission_{backend}.txt').read_text()
    Path(env['SCREEN']).write_text(prompt)
    result = subprocess.run([str(HOOK_DIR / 'permission-request.sh'), '--agent', 'agy'],
                            env=env, input=json.dumps({'toolCall': tool}), text=True,
                            capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == '{"decision":"allow"}\n'
    wait_for_file(env['PAYLOADS'])  # Existing parse-failure notification, never an approval.
    payloads = [json.loads(line) for line in Path(env['PAYLOADS']).read_text().splitlines()]
    assert all('choices' not in payload for payload in payloads)
    assert not Path(env['REGISTERED']).exists()
    assert not any(call[1] in ('send', 'send-key', 'send-keys') for call in calls(env))


@pytest.mark.parametrize('backend', ['tmux', 'cmux'])
def test_agy_later_unrelated_hook_cannot_take_over_pending_approval(terminal_env, backend):
    env = terminal_env
    env.update(TMUX='socket', TMUX_PANE='%1') if backend == 'tmux' else env.update(
        CMUX_SURFACE_ID=str(uuid.uuid4()))
    env.update(PENDING_POLLS='1', PROMPT_RELAY_TIMEOUT='8')
    prompt = (HOOK_DIR / 'fixtures' / f'agy_permission_{backend}.txt').read_text()
    Path(env['SCREEN']).write_text(prompt)
    command = 'touch /tmp/relay-example.txt'
    hook = [str(HOOK_DIR / 'permission-request.sh'), '--agent', 'agy']
    first = subprocess.run(hook, env=env, text=True, capture_output=True, timeout=5,
                           input=json.dumps({'toolCall': {'name': 'run_command', 'args': {'CommandLine': command}}}))
    assert first.stdout == '{"decision":"allow"}\n'
    wait_for_file(env['REGISTERED'])
    # Change only status: this bypasses raw-screen duplicate suppression.
    Path(env['SCREEN']).write_text(prompt.replace('medium', 'high'))
    second = subprocess.run(hook, env=env, text=True, capture_output=True, timeout=5,
                            input=json.dumps({'toolCall': {'name': 'view_file', 'args': {'toolSummary': 'View hosts'}}}))
    assert second.stdout == '{"decision":"allow"}\n'
    # Wait for the second worker to finish parsing, not just for the first
    # worker's cancellation, so a late incorrect registration cannot escape.
    deadline = time.monotonic() + 8
    payloads = []
    while len(payloads) < 2 and time.monotonic() < deadline:
        payloads = [json.loads(line) for line in Path(env['PAYLOADS']).read_text().splitlines()]
        time.sleep(0.02)
    assert len(payloads) == 2
    assert 'choices' not in payloads[1]
    wait_for_file(env['CANCELLED'])
    requests = [payload for payload in payloads if 'choices' in payload]
    assert len(requests) == 1
    assert requests[0]['description'] == command
    assert not any(call[1] in ('send', 'send-key', 'send-keys') for call in calls(env))
