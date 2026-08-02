import json
import stat

import pytest

from codex_goal_status import GoalQueryError, query_goal


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
        "        print(json.dumps({'id': 1, 'result': {'codexHome': '/tmp'}}), flush=True)\n"
        "    elif message.get('id') == 2:\n"
        "        print(json.dumps({'id': 2, 'result': {'goal': goal}}), flush=True)\n"
    )
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
    return str(executable)


def test_active_goal(tmp_path):
    codex = make_fake_codex(tmp_path, {"status": "active", "updatedAt": 123})
    assert query_goal("thread-1", codex_bin=codex, timeout=2).status == "active"


@pytest.mark.parametrize(
    ("wire_status", "expected"),
    [("budgetLimited", "budget_limited"), ("usageLimited", "usage_limited")],
)
def test_normalizes_camel_case_statuses(tmp_path, wire_status, expected):
    codex = make_fake_codex(tmp_path, {"status": wire_status, "updatedAt": 456})
    state = query_goal("thread-1", codex_bin=codex, timeout=2)
    assert state.status == expected
    assert state.updated_at == 456


def test_no_goal(tmp_path):
    codex = make_fake_codex(tmp_path, None)
    assert query_goal("thread-1", codex_bin=codex, timeout=2).status == "none"


def test_invalid_goal_is_rejected(tmp_path):
    codex = make_fake_codex(tmp_path, {"updatedAt": 123})
    with pytest.raises(GoalQueryError, match="status"):
        query_goal("thread-1", codex_bin=codex, timeout=2)
