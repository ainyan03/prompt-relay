from concurrent.futures import ThreadPoolExecutor

import pytest

import idle_state


@pytest.fixture
def states(tmp_path, monkeypatch):
    monkeypatch.setenv('PROMPT_RELAY_STATE_DIR', str(tmp_path))
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '0')
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1\n%2')
    return [idle_state.IdleState({'session': '$1', 'name': 'team', 'pane': pane}, 'host')
            for pane in ('%1', '%2')]


def test_all_idle_claims_only_once_even_concurrently(states):
    a, b = states
    a.update('busy')
    b.update('busy')
    tokens = [a.update('idle'), b.update('idle')]
    with ThreadPoolExecutor() as executor:
        results = list(executor.map(lambda pair: pair[0].claim_notification(pair[1]), zip(states, tokens)))
    assert sorted(results) == [False, True]
    assert not a.claim_notification(a.update('idle'))
    a.update('busy')
    assert a.claim_notification(a.update('idle'))


def test_busy_peer_blocks_notification(states):
    a, b = states
    b.update('busy')
    assert not a.claim_notification(a.update('idle'))


def test_removed_pane_is_pruned(states, monkeypatch):
    a, b = states
    b.update('busy')
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1')
    assert a.claim_notification(a.update('idle'))
    assert not b.pane_path('%2').exists()


def test_resume_or_new_stop_invalidates_previous_check(states):
    a, _ = states
    token = a.update('idle')
    a.update('busy')
    assert not a.claim_notification(token)
    a.update('idle')
    assert not a.claim_notification(token)


def test_untracked_live_panes_do_not_block(states):
    a, _ = states
    assert a.claim_notification(a.update('idle'))


def test_missing_self_does_not_notify(states, monkeypatch):
    a, _ = states
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%2')
    assert not a.claim_notification(a.update('idle'))


def test_old_timer_cannot_claim_later_peer_idle(states, monkeypatch):
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '5')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 100)
    a, b = states
    a.update('busy')
    b.update('busy')
    old = a.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 101)
    b.update('busy')
    current = b.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 105)
    assert not a.claim_notification(old)
    monkeypatch.setattr(idle_state.time, 'time', lambda: 106)
    assert b.claim_notification(current)


def test_repeated_stop_keeps_original_idle_time(states):
    a, b = states
    a.update('busy')
    b.update('busy')
    a.update('idle')
    first = b.update('idle')
    assert b.claim_notification(first)
    b.update('busy')
    repeated = a.update('idle')
    assert not a.claim_notification(repeated)
    current = b.update('idle')
    assert b.claim_notification(current)
    assert not b.claim_notification(b.update('idle'))


def test_new_busy_peer_exits_during_old_idle_timer(states, monkeypatch):
    a, b = states
    a.update('busy')
    candidate = a.update('idle')
    b.update('busy')
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1')
    assert a.claim_notification(candidate)
    assert not b.pane_path('%2').exists()
    assert not a.claim_notification(a.update('idle'))


def test_repeated_idle_preserves_grace_deadline(states, monkeypatch):
    a, _ = states
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '5')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 100)
    original = a.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 103)
    repeated = a.update('idle')
    assert repeated != original
    assert a.read(a.pane_path('%1'))['since'] == 100
    assert not a.claim_notification(original)
    assert not a.claim_notification(repeated)
    monkeypatch.setattr(idle_state.time, 'time', lambda: 105)
    assert a.claim_notification(repeated)
    assert a.read(a.directory / 'meta') == {'notified_since': 100}
    assert not a.claim_notification(a.update('idle'))


def test_busy_and_next_idle_get_new_transition_times(states, monkeypatch):
    a, _ = states
    monkeypatch.setattr(idle_state.time, 'time', lambda: 100)
    a.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 110)
    a.update('busy')
    assert a.read(a.pane_path('%1'))['since'] == 110
    monkeypatch.setattr(idle_state.time, 'time', lambda: 111)
    assert a.claim_notification(a.update('idle'))
    assert a.read(a.pane_path('%1'))['since'] == 111


def test_check_waits_only_until_original_idle_deadline(states, monkeypatch):
    a, _ = states
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '5')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 100)
    a.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 103)
    token = a.update('idle')
    sleeps = []

    def advance(seconds):
        sleeps.append(seconds)
        monkeypatch.setattr(idle_state.time, 'time', lambda: 103 + seconds)

    monkeypatch.setattr(idle_state.time, 'sleep', advance)
    monkeypatch.setattr(idle_state.sys, 'argv', [
        'idle_state.py', 'check', idle_state.json.dumps(a.ctx), 'host', token,
    ])
    assert idle_state.main() == 0
    assert sleeps == [2]


def test_notified_idle_does_not_revive_after_latest_notifier_closes(states, monkeypatch):
    a, b = states
    monkeypatch.setattr(idle_state.time, 'time', lambda: 100)
    assert a.claim_notification(a.update('idle'))
    monkeypatch.setattr(idle_state.time, 'time', lambda: 110)
    b.update('busy')
    assert b.claim_notification(b.update('idle'))
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1')
    assert not a.claim_notification(a.update('idle'))
    assert a.read(a.directory / 'meta') == {'notified_since': 110}
    assert not b.pane_path('%2').exists()


@pytest.mark.parametrize('pruned', [False, True])
def test_latest_worker_can_notify_after_its_pane_closes(states, monkeypatch, pruned):
    a, b = states
    monkeypatch.setenv('PROMPT_RELAY_IDLE_GRACE', '5')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 100)
    a.update('busy')
    b.update('busy')
    earlier = a.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 102)
    later = b.update('idle')
    monkeypatch.setattr(idle_state.time, 'time', lambda: 105)
    assert not a.claim_notification(earlier)
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1')
    if pruned:
        b.pane_path('%2').unlink()
    monkeypatch.setattr(idle_state.time, 'time', lambda: 107)
    assert b.claim_notification(later)
    assert not b.pane_path('%2').exists()
    assert not a.claim_notification(earlier)
    assert not b.claim_notification(later)


def test_closed_pane_token_is_checked_before_pruning(states, monkeypatch):
    a, b = states
    a.update('idle')
    stale = b.update('idle')
    b.update('busy')
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1')
    assert not b.claim_notification(stale)
    assert b.pane_path('%2').exists()


def test_check_accepts_pruned_self_state(states, monkeypatch):
    a, b = states
    a.update('idle')
    token = b.update('idle')
    b.pane_path('%2').unlink()
    monkeypatch.setattr(idle_state, 'tmux', lambda *args: '%1')
    monkeypatch.setattr(idle_state.sys, 'argv', [
        'idle_state.py', 'check', idle_state.json.dumps(b.ctx), 'host', token,
    ])
    assert idle_state.main() == 0


def test_busy_if_needed_skips_write_and_keeps_transition(states, monkeypatch):
    a, _ = states
    token = a.update('busy')
    previous = a.read(a.pane_path('%1'))

    def unexpected_write(*args):
        pytest.fail('Repeated PreInvocation must not rewrite busy state')

    monkeypatch.setattr(a, 'write', unexpected_write)
    assert a.update('busy', skip_if_busy=True) == token
    assert a.read(a.pane_path('%1')) == previous
