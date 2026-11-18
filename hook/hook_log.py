"""Append bounded routing metadata without affecting the hook's response."""
from datetime import datetime, timezone
import fcntl
import os
from pathlib import Path
import sys


MAX_BYTES = 256 * 1024


def write_log(destination, agent, event, backend, target, detail):
    if not destination or destination == 'off':
        return
    try:
        path = Path(destination)
        path.parent.mkdir(parents=True, exist_ok=True)
        fields = [datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
                  agent, event, backend, target, detail]
        line = ('\t'.join(str(value).replace('\t', '\\t').replace('\r', '\\r')
                          .replace('\n', '\\n')[:512] for value in fields) + '\n').encode()
        # Serialize rotation and appends across concurrent approval hooks.
        with os.fdopen(os.open(str(path) + '.lock', os.O_CREAT | os.O_WRONLY, 0o600), 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if path.exists() and path.stat().st_size + len(line) > MAX_BYTES:
                os.replace(path, str(path) + '.1')
            with os.fdopen(os.open(path, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600), 'ab') as stream:
                stream.write(line)
    except (OSError, ValueError):
        pass


if __name__ == '__main__':
    write_log(*sys.argv[1:])
