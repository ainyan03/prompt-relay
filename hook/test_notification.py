import json
import os
import stat
import subprocess
from pathlib import Path

import pytest


HOOK = Path(__file__).with_name("notification.sh")


def make_fake_codex(tmp_path, goal):
    executable = tmp_path / "fake-codex"
    goal_json = json.dumps(goal)
    executable.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys\n"
        f"goal = json.loads({goal_json!r})\n"
        "for line in sys.stdin:\n"
        "    message = json.loads(line)\n"
        "    if message.get('id') == 1:\n"
        "        print(json.dumps({'id': 1, 'result': {}}), flush=True)\n"
        "    elif message.get('id') == 2:\n"
        "        print(json.dumps({'id': 2, 'result': {'goal': goal}}), flush=True)\n"
    )
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
    return executable


def make_fake_curl(tmp_path):
    executable = tmp_path / "curl"
    executable.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "with open(os.environ['CURL_CAPTURE'], 'w') as f:\n"
        "    json.dump(sys.argv[1:], f)\n"
    )
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR)


def run_stop_hook(tmp_path, goal, *, codex_exists=True):
    make_fake_curl(tmp_path)
    codex = make_fake_codex(tmp_path, goal) if codex_exists else tmp_path / "missing-codex"
    capture = tmp_path / "curl.json"
    # 実行者のシェルの PROMPT_RELAY_* (例: IDLE_SCOPE=session) を持ち込まない
    env = {k: v for k, v in os.environ.items() if not k.startswith("PROMPT_RELAY_")}
    env.update({
        "PATH": f"{tmp_path}:{env['PATH']}",
        "PROMPT_RELAY_API_KEY": "test-key",
        "PROMPT_RELAY_SERVER_URL": "http://relay.test",
        "PROMPT_RELAY_CODEX_BIN": str(codex),
        "CURL_CAPTURE": str(capture),
    })
    result = subprocess.run(
        [str(HOOK)],
        input=json.dumps({
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "turn_id": "turn-1",
        }),
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
    )
    assert result.returncode == 0
    return capture


def captured_body(path):
    args = json.loads(path.read_text())
    return json.loads(args[args.index("-d") + 1])


def test_active_goal_suppresses_stop_notification(tmp_path):
    capture = run_stop_hook(tmp_path, {"status": "active", "updatedAt": 123})
    assert not capture.exists()


@pytest.mark.parametrize(
    ("status", "message"),
    [
        ("complete", "タスクが完了しました"),
        ("blocked", "タスクがブロックされました"),
        ("paused", "タスクが一時停止しました"),
        ("usageLimited", "利用上限によりタスクが停止しました"),
        ("budgetLimited", "トークン予算に達してタスクが停止しました"),
    ],
)
def test_terminal_goal_sends_state_specific_notification(tmp_path, status, message):
    capture = run_stop_hook(tmp_path, {"status": status, "updatedAt": 123})
    body = captured_body(capture)
    assert body["message"] == message
    assert body["event_id"].startswith("codex-goal:session-1:")


def test_non_goal_stop_is_described_as_turn_completion(tmp_path):
    capture = run_stop_hook(tmp_path, None)
    body = captured_body(capture)
    assert body["title"] == "Codex"
    assert body["message"] == "ターンが完了しました"
    assert body["event_id"] == "codex-turn:session-1:turn-1"


def test_goal_query_failure_falls_back_to_turn_completion(tmp_path):
    capture = run_stop_hook(tmp_path, None, codex_exists=False)
    body = captured_body(capture)
    assert body["message"] == "ターンが完了しました"
    assert body["event_id"] == "codex-turn:session-1:turn-1"


@pytest.fixture
def idle_env(tmp_path):
    tmux = tmp_path / 'tmux'
    tmux.write_text(
        '#!/usr/bin/env python3\n'
        'import os, sys\n'
        'from pathlib import Path\n'
        'if os.environ.get("TMUX_FAIL"): sys.exit(1)\n'
        'if sys.argv[1] == "list-panes": print(Path(os.environ["TMUX_LIVE_PANES_FILE"]).read_text())\n'
        'elif "#{session_id}" in sys.argv[-1]: print("$1\\tteam")\n'
        'else: print("team")\n'
    )
    tmux.chmod(0o755)
    curl = tmp_path / 'curl'
    curl.write_text(
        '#!/usr/bin/env python3\n'
        'import json, os, sys\n'
        'with open(os.environ["CURL_CAPTURE"], "a") as stream:\n'
        '    stream.write(json.dumps(json.loads(sys.argv[sys.argv.index("-d") + 1])) + "\\n")\n'
    )
    curl.chmod(0o755)
    live_panes = tmp_path / 'live-panes'
    live_panes.write_text('%1\n%2\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('PROMPT_RELAY_')}
    env.update({
        'TMUX_LIVE_PANES_FILE': str(live_panes),
        'PATH': f'{tmp_path}:{env["PATH"]}',
        'PROMPT_RELAY_API_KEY': 'test-key',
        'PROMPT_RELAY_SERVER_URL': 'http://relay.test',
        'PROMPT_RELAY_SERVER_URL_2': '',
        'PROMPT_RELAY_IDLE_SCOPE': 'session',
        'PROMPT_RELAY_IDLE_GRACE': '0',
        'PROMPT_RELAY_STATE_DIR': str(tmp_path / 'states'),
        'PROMPT_RELAY_CODEX_GOAL_AWARE': 'false',
        'CURL_CAPTURE': str(tmp_path / 'notifications'),
        'TMUX_PANE': '%1',
    })
    return env


def run_idle_hook(env, event, agent='claude', **extra):
    command = [str(HOOK)] + (['--agent', agent] if agent else [])
    result = subprocess.run(command, env=env, input=json.dumps({'hook_event_name': event, **extra}),
                            text=True, capture_output=True, timeout=5)
    assert result.returncode == 0
    assert result.stdout == ''
    return result


def notifications(env):
    path = Path(env['CURL_CAPTURE'])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def wait_for_notifications(env, count):
    import time
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        found = notifications(env)
        if len(found) >= count:
            return found
        time.sleep(0.02)
    pytest.fail(f'Expected {count} notifications, got {notifications(env)}')


@pytest.mark.parametrize(('event', 'agent'), [('UserPromptSubmit', 'claude'), ('Stop', 'claude'),
                                              ('UserPromptSubmit', 'codex'), ('UserPromptSubmit', None)])
def test_pane_mode_new_hooks_are_noops(idle_env, event, agent):
    idle_env['PROMPT_RELAY_IDLE_SCOPE'] = 'pane'
    run_idle_hook(idle_env, event, agent)
    assert not notifications(idle_env)
    assert not Path(idle_env['PROMPT_RELAY_STATE_DIR']).exists()


def test_session_notifies_once_for_all_idle(idle_env):
    import time
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(idle_env, 'UserPromptSubmit')
    run_idle_hook(peer, 'UserPromptSubmit', 'codex', turn_id='turn-1')
    run_idle_hook(idle_env, 'Stop', background_tasks=[{'status': 'running'}])
    time.sleep(0.15)
    assert not notifications(idle_env)
    run_idle_hook(peer, 'Stop', 'codex', session_id='session-1', turn_id='turn-1')
    body = wait_for_notifications(idle_env, 1)[0]
    assert body['tmux_target'].endswith(':team')
    assert body['title'] == 'Done'
    assert body['message'] == '全エージェントの処理が完了しました'
    assert body['event_id'] == 'codex-turn:session-1:turn-1'
    run_idle_hook(idle_env, 'Stop')
    run_idle_hook(peer, 'Stop', 'codex')
    time.sleep(0.2)
    assert len(notifications(idle_env)) == 1


def test_claude_stop_uses_session_message(idle_env):
    run_idle_hook(idle_env, 'Stop')
    body = wait_for_notifications(idle_env, 1)[0]
    assert body['title'] == 'Done'
    assert body['message'] == '全エージェントの処理が完了しました'


def test_session_ignores_legacy_idle_notification(idle_env):
    run_idle_hook(idle_env, 'Notification', notification_type='idle_prompt')
    assert not notifications(idle_env)
    assert not Path(idle_env['PROMPT_RELAY_STATE_DIR']).exists()


@pytest.mark.parametrize(('payload', 'sent'), [
    ({'notification_type': 'idle_prompt'}, True),
    ({}, True),
    ({'notification_type': 'permission_prompt'}, False),
])
def test_pane_mode_claude_notification_uses_idle_message(idle_env, payload, sent):
    # 実際の Claude Code の入力は hook_event_name=Notification + notification_type
    idle_env['PROMPT_RELAY_IDLE_SCOPE'] = 'pane'
    run_idle_hook(idle_env, 'Notification', None, **payload)
    found = notifications(idle_env)
    if sent:
        assert len(found) == 1
        assert found[0]['title'] == 'Done'
        assert found[0]['message'] == '処理が完了しました'
    else:
        assert not found


@pytest.mark.parametrize('failure', ['missing_pane', 'tmux_failure'])
def test_session_falls_back_to_pane_mode(idle_env, failure):
    if failure == 'missing_pane':
        idle_env.pop('TMUX_PANE')
    else:
        idle_env['TMUX_FAIL'] = '1'
    run_idle_hook(idle_env, 'Stop')
    assert not notifications(idle_env)
    run_idle_hook(idle_env, 'idle_prompt', None)
    assert notifications(idle_env)[0]['message'] == '処理が完了しました'
    assert not Path(idle_env['PROMPT_RELAY_STATE_DIR']).exists()


def test_grace_does_not_block_hook_and_resume_cancels_notification(idle_env):
    import time
    idle_env['PROMPT_RELAY_IDLE_GRACE'] = '1'
    started = time.monotonic()
    run_idle_hook(idle_env, 'Stop')
    assert time.monotonic() - started < 1
    run_idle_hook(idle_env, 'UserPromptSubmit')
    time.sleep(1.2)
    assert not notifications(idle_env)


def test_active_goal_keeps_session_busy(idle_env):
    idle_env['PROMPT_RELAY_CODEX_GOAL_AWARE'] = 'true'
    idle_env['PROMPT_RELAY_CODEX_BIN'] = str(make_fake_codex(Path(idle_env['CURL_CAPTURE']).parent,
                                                          {'status': 'active', 'updatedAt': 123}))
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(peer, 'Stop', 'codex', session_id='session-1')
    run_idle_hook(idle_env, 'Stop')
    import time
    time.sleep(0.2)
    assert not notifications(idle_env)


@pytest.mark.parametrize('repeat_stop', [False, True])
def test_old_stop_cannot_notify_new_turn_before_its_grace(idle_env, repeat_stop):
    import time
    idle_env['PROMPT_RELAY_IDLE_GRACE'] = '0.8'
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(idle_env, 'UserPromptSubmit', 'codex')
    run_idle_hook(peer, 'UserPromptSubmit', 'codex')
    run_idle_hook(idle_env, 'Stop', 'codex', session_id='a', turn_id='a1')
    if repeat_stop:
        run_idle_hook(peer, 'Stop', 'codex', session_id='b', turn_id='b1')
        first = wait_for_notifications(idle_env, 1)
        assert first[0]['event_id'] == 'codex-turn:b:b1'
    run_idle_hook(peer, 'UserPromptSubmit', 'codex')
    if repeat_stop:
        run_idle_hook(idle_env, 'Stop', 'codex', session_id='a', turn_id='a1')
    time.sleep(0.35)
    started = time.monotonic()
    run_idle_hook(peer, 'Stop', 'codex', session_id='b', turn_id='b2')
    # A's older timer expires in this interval, while B's grace is pending.
    time.sleep(0.45)
    previous_count = 1 if repeat_stop else 0
    assert len(notifications(idle_env)) == previous_count
    found = wait_for_notifications(idle_env, previous_count + 1)
    assert time.monotonic() - started >= 0.8
    assert found[-1]['event_id'] == 'codex-turn:b:b2'
    time.sleep(0.15)
    assert len(notifications(idle_env)) == previous_count + 1


def test_notification_survives_hook_process_group_cleanup(idle_env):
    import signal
    idle_env['PROMPT_RELAY_IDLE_GRACE'] = '0.7'
    process = subprocess.Popen(
        [str(HOOK), '--agent', 'claude'], env=idle_env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    output, errors = process.communicate(json.dumps({'hook_event_name': 'Stop'}), timeout=5)
    assert process.returncode == 0
    assert output == ''
    assert errors == ''
    # This is a newly created, isolated group, never the test runner's group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass  # Expected when the hook's worker has successfully detached.
    assert wait_for_notifications(idle_env, 1)[0]['title'] == 'Done'


def test_pending_idle_notifies_after_new_busy_peer_closes(idle_env):
    idle_env['PROMPT_RELAY_IDLE_GRACE'] = '0.8'
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(idle_env, 'UserPromptSubmit', 'codex')
    run_idle_hook(idle_env, 'Stop', 'codex', session_id='a', turn_id='a1')
    run_idle_hook(peer, 'UserPromptSubmit', 'codex')
    Path(idle_env['TMUX_LIVE_PANES_FILE']).write_text('%1\n')
    found = wait_for_notifications(idle_env, 1)
    assert found[0]['event_id'] == 'codex-turn:a:a1'
    run_idle_hook(idle_env, 'Stop', 'codex', session_id='a', turn_id='a1')
    import time
    time.sleep(0.15)
    assert len(notifications(idle_env)) == 1


def test_old_idle_is_not_renotified_after_new_notifier_closes(idle_env):
    import time
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(idle_env, 'Stop')
    wait_for_notifications(idle_env, 1)
    run_idle_hook(peer, 'UserPromptSubmit')
    run_idle_hook(peer, 'Stop')
    wait_for_notifications(idle_env, 2)
    Path(idle_env['TMUX_LIVE_PANES_FILE']).write_text('%1\n')
    run_idle_hook(idle_env, 'Stop')
    time.sleep(0.4)
    assert len(notifications(idle_env)) == 2


def test_closed_last_idle_worker_notifies_after_earlier_worker_exits(idle_env):
    import time
    idle_env['PROMPT_RELAY_IDLE_GRACE'] = '1.2'
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(idle_env, 'UserPromptSubmit', 'codex')
    run_idle_hook(peer, 'UserPromptSubmit', 'codex')
    run_idle_hook(idle_env, 'Stop', 'codex', session_id='a', turn_id='a1')
    time.sleep(0.55)
    run_idle_hook(peer, 'Stop', 'codex', session_id='b', turn_id='b1')
    # Let A's grace expire while B is still present and in its grace period.
    time.sleep(0.65)
    assert not notifications(idle_env)
    Path(idle_env['TMUX_LIVE_PANES_FILE']).write_text('%1\n')
    found = wait_for_notifications(idle_env, 1)
    assert found[0]['event_id'] == 'codex-turn:b:b1'
    time.sleep(0.15)
    assert len(notifications(idle_env)) == 1


@pytest.mark.parametrize(('status', 'title', 'message'), [
    (None, 'Done', '全エージェントの処理が完了しました'),
    ('complete', 'Done', '全エージェントの処理が完了しました'),
    ('blocked', 'Codex', 'タスクがブロックされました'),
    ('paused', 'Codex', 'タスクが一時停止しました'),
    ('usageLimited', 'Codex', '利用上限によりタスクが停止しました'),
    ('budgetLimited', 'Codex', 'トークン予算に達してタスクが停止しました'),
    ('query_failure', 'Done', '全エージェントの処理が完了しました'),
])
def test_session_codex_messages_keep_event_ids(idle_env, tmp_path, status, title, message):
    idle_env['PROMPT_RELAY_CODEX_GOAL_AWARE'] = 'true'
    if status == 'query_failure':
        idle_env['PROMPT_RELAY_CODEX_BIN'] = str(tmp_path / 'missing-codex')
    else:
        goal = {'status': status, 'updatedAt': 123} if status else None
        idle_env['PROMPT_RELAY_CODEX_BIN'] = str(make_fake_codex(tmp_path, goal))
    run_idle_hook(idle_env, 'Stop', 'codex', session_id='session-1', turn_id='turn-1')
    body = wait_for_notifications(idle_env, 1)[0]
    assert body['title'] == title
    assert body['message'] == message
    if status not in (None, 'query_failure'):
        normalized = {'usageLimited': 'usage_limited', 'budgetLimited': 'budget_limited'}.get(status, status)
        assert body['event_id'] == f'codex-goal:session-1:{normalized}:123'
    else:
        assert body['event_id'] == 'codex-turn:session-1:turn-1'


def run_agy_hook(env, event, payload=None):
    result = subprocess.run(
        [str(HOOK), '--agent', 'agy', '--event', event], env=env,
        input=json.dumps(payload if payload is not None else {
            'conversationId': 'conversation-1', 'fullyIdle': False,
        }), text=True, capture_output=True, timeout=5,
    )
    assert result.returncode == 0
    assert result.stdout == '{}\n'
    return result


@pytest.mark.parametrize('scope', ['pane', 'session'])
@pytest.mark.parametrize('event', ['PreInvocation', 'Stop'])
@pytest.mark.parametrize('key', ['test-key', '', 'short'])
def test_agy_always_returns_one_json_object(idle_env, scope, event, key):
    idle_env.update(PROMPT_RELAY_IDLE_SCOPE=scope, PROMPT_RELAY_API_KEY=key)
    run_agy_hook(idle_env, event)
    if scope == 'pane' or key != 'test-key':
        assert not notifications(idle_env)
        assert not Path(idle_env['PROMPT_RELAY_STATE_DIR']).exists()
    elif event == 'PreInvocation':
        files = list(Path(idle_env['PROMPT_RELAY_STATE_DIR']).rglob('*.json'))
        assert len(files) == 1
        assert json.loads(files[0].read_text())['status'] == 'busy'
        assert not notifications(idle_env)
    else:
        body = wait_for_notifications(idle_env, 1)[0]
        assert body['title'] == 'Done'
        assert body['message'] == '全エージェントの処理が完了しました'
        assert body['tmux_target'].endswith(':team')
        assert 'event_id' not in body


@pytest.mark.parametrize('event', ['PreInvocation', 'Stop'])
@pytest.mark.parametrize('failure', ['missing_pane', 'tmux_failure'])
def test_agy_without_session_only_returns_json(idle_env, event, failure):
    if failure == 'missing_pane':
        idle_env.pop('TMUX_PANE')
    else:
        idle_env['TMUX_FAIL'] = '1'
    run_agy_hook(idle_env, event)
    assert not notifications(idle_env)
    assert not Path(idle_env['PROMPT_RELAY_STATE_DIR']).exists()


@pytest.mark.parametrize('last', ['agy', 'claude'])
def test_agy_and_claude_notify_once_when_both_idle(idle_env, last):
    import time
    peer = dict(idle_env, TMUX_PANE='%2')
    run_idle_hook(idle_env, 'UserPromptSubmit')
    run_agy_hook(peer, 'PreInvocation')
    if last == 'agy':
        run_idle_hook(idle_env, 'Stop')
    else:
        run_agy_hook(peer, 'Stop')
    time.sleep(0.15)
    assert not notifications(idle_env)
    if last == 'agy':
        run_agy_hook(peer, 'Stop', {'fullyIdle': False, 'terminationReason': 'done'})
    else:
        run_idle_hook(idle_env, 'Stop')
    body = wait_for_notifications(idle_env, 1)[0]
    assert body['message'] == '全エージェントの処理が完了しました'
    run_agy_hook(peer, 'Stop')
    run_idle_hook(idle_env, 'Stop')
    time.sleep(0.15)
    assert len(notifications(idle_env)) == 1


def test_agy_repeated_preinvocation_does_not_parse_or_rewrite_busy_state(idle_env):
    run_agy_hook(idle_env, 'PreInvocation')
    path = next(Path(idle_env['PROMPT_RELAY_STATE_DIR']).rglob('*.json'))
    previous = path.read_bytes()
    modified = path.stat().st_mtime_ns
    result = subprocess.run(
        [str(HOOK), '--agent', 'agy', '--event', 'PreInvocation'], env=idle_env,
        input='not JSON', text=True, capture_output=True, timeout=5,
    )
    assert result.returncode == 0
    assert result.stdout == '{}\n'
    assert path.read_bytes() == previous
    assert path.stat().st_mtime_ns == modified
    assert not notifications(idle_env)
