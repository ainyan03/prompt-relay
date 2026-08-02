#!/usr/bin/env python3
"""Codex App Server の公開 API からスレッドの goal 状態を取得する。"""

from __future__ import annotations

import json
import os
import selectors
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import TextIO


STATUS_ALIASES = {
    "budgetLimited": "budget_limited",
    "usageLimited": "usage_limited",
}


@dataclass(frozen=True)
class GoalState:
    status: str
    updated_at: int | None = None


class GoalQueryError(RuntimeError):
    pass


def _send(stream: TextIO, message: dict) -> None:
    stream.write(json.dumps(message, separators=(",", ":")) + "\n")
    stream.flush()


def _read_response(
    process: subprocess.Popen[str],
    selector: selectors.BaseSelector,
    request_id: int,
    deadline: float,
) -> dict:
    assert process.stdout is not None
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        events = selector.select(min(remaining, 0.2))
        if not events:
            if process.poll() is not None:
                raise GoalQueryError("Codex App Server exited before responding")
            continue

        line = process.stdout.readline()
        if not line:
            raise GoalQueryError("Codex App Server closed stdout")
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("id") != request_id:
            continue
        if "error" in message:
            error = message["error"]
            detail = error.get("message") if isinstance(error, dict) else str(error)
            raise GoalQueryError(detail or "Codex App Server returned an error")
        result = message.get("result")
        if not isinstance(result, dict):
            raise GoalQueryError("Codex App Server returned an invalid result")
        return result

    raise GoalQueryError("Codex App Server goal query timed out")


def query_goal(
    thread_id: str,
    *,
    codex_bin: str | None = None,
    timeout: float = 4.0,
) -> GoalState:
    """thread/goal/get を呼び、goal が無ければ status='none' を返す。"""
    executable = codex_bin or os.environ.get("PROMPT_RELAY_CODEX_BIN") or shutil.which("codex")
    if not executable:
        raise GoalQueryError("codex executable was not found")

    process = subprocess.Popen(
        [executable, "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    selector = selectors.DefaultSelector()
    assert process.stdin is not None
    assert process.stdout is not None
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout

    try:
        _send(process.stdin, {
            "method": "initialize",
            "id": 1,
            "params": {
                "clientInfo": {
                    "name": "prompt_relay",
                    "title": "Prompt Relay",
                    "version": "1.0.0",
                }
            },
        })
        _read_response(process, selector, 1, deadline)

        _send(process.stdin, {"method": "initialized"})
        _send(process.stdin, {
            "method": "thread/goal/get",
            "id": 2,
            "params": {"threadId": thread_id},
        })
        result = _read_response(process, selector, 2, deadline)

        goal = result.get("goal")
        if goal is None:
            return GoalState("none")
        if not isinstance(goal, dict):
            raise GoalQueryError("Codex App Server returned an invalid goal")

        raw_status = goal.get("status")
        if not isinstance(raw_status, str) or not raw_status:
            raise GoalQueryError("Codex goal status was missing")
        status = STATUS_ALIASES.get(raw_status, raw_status)
        updated_at = goal.get("updatedAt")
        if not isinstance(updated_at, int):
            updated_at = None
        return GoalState(status, updated_at)
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=0.5)


def _timeout_from_env() -> float:
    raw = os.environ.get("PROMPT_RELAY_CODEX_GOAL_QUERY_TIMEOUT", "4")
    try:
        value = float(raw)
    except ValueError:
        return 4.0
    return min(max(value, 0.5), 8.0)


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1]:
        print("unknown|")
        return 0

    try:
        state = query_goal(sys.argv[1], timeout=_timeout_from_env())
        print(f"{state.status}|{state.updated_at or ''}")
    except (GoalQueryError, OSError, subprocess.SubprocessError):
        # 通知 hook は goal API の障害で失敗させない。呼び出し側は保守的な
        # 「ターン完了」通知へフォールバックする。
        print("unknown|")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
