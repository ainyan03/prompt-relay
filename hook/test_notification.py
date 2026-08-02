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
    env = os.environ.copy()
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
