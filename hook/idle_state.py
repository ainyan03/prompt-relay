"""Atomic terminal group idle tracking for the notification hook."""

import fcntl
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager


_MISSING = object()


def tmux(*args):
    return subprocess.check_output(['tmux', *args], text=True, stderr=subprocess.DEVNULL).strip()


def cmux_output(*args):
    executable = (os.environ.get('CMUX_BUNDLED_CLI_PATH') or shutil.which('cmux')
                  or '/Applications/cmux.app/Contents/Resources/bin/cmux')
    return subprocess.check_output([executable, *args], text=True,
                                   stderr=subprocess.DEVNULL, timeout=2)


def cmux(*args):
    return json.loads(cmux_output('--json', '--id-format', 'uuids', *args))


def cmux_name(workspace):
    for item in cmux('list-workspaces')['workspaces']:
        if item['id'].lower() == workspace.lower():
            return item.get('title') or ''
    return ''


def context(backend, check_membership=False):
    if backend == 'cmux':
        pane = os.environ.get('CMUX_SURFACE_ID')
        session = os.environ.get('CMUX_WORKSPACE_ID')
        if not pane or not session:
            return None
        ctx = {'pane': pane, 'session': session, 'name': '', 'backend': 'cmux'}
        # A moved surface no longer participates in its startup workspace.
        # Resolve the display name lazily when constructing a notification.
        if check_membership:
            try:
                if pane.lower() not in live_panes(ctx):
                    return None
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
                pass  # Failed enumeration must not drop a known context or a busy update.
        return ctx
    if backend != 'tmux':
        return None
    pane = os.environ.get('TMUX_PANE')
    if not pane or not os.environ.get('TMUX'):
        return None
    try:
        value = tmux('display-message', '-p', '-t', pane, '#{session_id}\t#{session_name}')
        session_id, name = value.split('\t', 1)
        if not session_id or not name:
            return None
        return {'pane': pane, 'session': session_id, 'name': name}
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def live_panes(ctx):
    if ctx.get('backend') != 'cmux':
        return set(tmux('list-panes', '-s', '-t', ctx['session'], '-F', '#{pane_id}').splitlines())
    workspace = ctx['session']
    live = set()
    # list-pane-surfaces without --pane only includes the focused pane.
    # Do not prune any state until all pane queries have succeeded.
    for pane in cmux('list-panes', '--workspace', workspace)['panes']:
        data = cmux('list-pane-surfaces', '--workspace', workspace, '--pane', pane['id'])
        live.update(surface['id'].lower() for surface in data['surfaces'])
    return live


class IdleState:
    def __init__(self, ctx, host):
        self.ctx = ctx
        root = Path(os.environ.get('PROMPT_RELAY_STATE_DIR', f'/tmp/prompt-relay-state-{os.getuid()}'))
        group = ('cmux:' if ctx.get('backend') == 'cmux' else '') + ctx['session']
        self.directory = root / host.encode().hex() / group.encode().hex()

    @contextmanager
    def locked(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / 'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def read(self, path, default=None):
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            return default

    def write(self, path, data):
        fd, temporary = tempfile.mkstemp(dir=self.directory, prefix='.state-')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(data, stream)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def pane_path(self, pane):
        return self.directory / (pane.encode().hex() + '.json')

    def update(self, status, *, skip_if_busy=False):
        token = uuid.uuid4().hex
        with self.locked():
            path = self.pane_path(self.ctx['pane'])
            previous = self.read(path)
            if skip_if_busy and previous and previous['status'] == 'busy':
                return previous['token']
            # Preserve the original idle transition on Stop retransmission;
            # the latest live idle transition sets the session grace deadline.
            since = (previous['since']
                     if status == 'idle' and previous and previous['status'] == 'idle'
                     else time.time())
            # A failed busy state write is equivalent to a missing hook event:
            # recovering from that failure is outside this tracking contract.
            self.write(path, {'pane': self.ctx['pane'], 'status': status,
                              'since': since, 'token': token})
        return token

    def claim_notification(self, token):
        with self.locked():
            own = self.read(self.pane_path(self.ctx['pane']), _MISSING)
            if own is not _MISSING and (own['token'] != token or own['status'] != 'idle'):
                return False
            # A failed query is not evidence that the session has become idle.
            live = live_panes(self.ctx)
            states = []
            for path in self.directory.glob('*.json'):
                state = self.read(path)
                pane = state['pane'].lower() if self.ctx.get('backend') == 'cmux' else state['pane']
                if pane not in live:
                    path.unlink()
                else:
                    states.append(state)
            if not states or any(state['status'] != 'idle' for state in states):
                return False
            latest_since = max(state['since'] for state in states)
            if time.time() < latest_since + grace():
                return False
            meta_path = self.directory / 'meta'
            meta = self.read(meta_path, {})
            # Closed panes may reduce the live maximum. A time watermark keeps
            # their removal from reviving an already notified, older idle state.
            if 'notified_since' in meta and latest_since <= meta['notified_since']:
                return False
            self.write(meta_path, {'notified_since': latest_since})
            return True


def grace():
    return max(0, float(os.environ.get('PROMPT_RELAY_IDLE_GRACE', '5')))


def main():
    action = sys.argv[1]
    if action == 'cmux-run':
        sys.stdout.write(cmux_output(*sys.argv[2:]))
        return 0
    if action == 'cmux-name':
        print(cmux_name(sys.argv[2]))
        return 0
    if action == 'context':
        ctx = context(sys.argv[2], '--check-membership' in sys.argv[3:])
        if ctx:
            print(json.dumps(ctx))
        return 0
    ctx = json.loads(sys.argv[2])
    state = IdleState(ctx, sys.argv[3])
    if action == 'busy-if-needed':
        state.update('busy', skip_if_busy=True)
        return 0
    if action in ('busy', 'idle'):
        token = state.update(action)
        if action == 'idle':
            print(token)
        return 0
    if action == 'launch':
        # Create a separate session so hook process-group cleanup cannot kill
        # the grace timer or the notification sender.
        subprocess.Popen(
            ['bash', sys.argv[5], '--idle-worker', sys.argv[2], sys.argv[3],
             sys.argv[4], sys.argv[6]],
            start_new_session=True, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return 0
    if action == 'check':
        own = state.read(state.pane_path(ctx['pane']), _MISSING)
        if own is not _MISSING:
            if own['status'] != 'idle' or own['token'] != sys.argv[4]:
                return 1
            # Retransmission restarts the worker, not the original grace deadline.
            time.sleep(max(0, own['since'] + grace() - time.time()))
        # A closed pane's file may already have been pruned by another worker.
        # The session-wide deadline and watermark still govern its claim.
        return 0 if state.claim_notification(sys.argv[4]) else 1
    return 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        sys.exit(1)
