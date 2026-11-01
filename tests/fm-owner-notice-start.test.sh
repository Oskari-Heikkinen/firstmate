#!/usr/bin/env bash
# Attempted-start reader contract: R-U2-12(f), R5-n1 and its pre-install sibling.
# Callable shared with the handoff adapter; fixture files only, no live watcher.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
T=$(fm_test_tmproot owner-notice-start)
trap 'rm -rf "$T"' EXIT
PYTHONPATH="$ROOT/bin" python3 - "$T" <<'PY'
import os
import pathlib
import sys
import time
from types import SimpleNamespace
import fm_owner_notice_format as fmt
import fm_owner_notice_runtime as runtime

root = pathlib.Path(sys.argv[1]) / 'owner-notices'
root.mkdir()
owner = SimpleNamespace(root=str(root), tmp=str(root / '.tmp'))
pid, start = fmt.own_identity()
now = int(time.time())
status = lambda **kw: runtime.runner_start_status(str(root), now=now, **kw)
assert not status()['live']
token = runtime.reserve(owner)
spawned = dict(pid=pid, starttime=start, token=token)
assert status(spawned=spawned)['first_start']
assert status(spawned=spawned)['grace']
# Reservation itself is never liveness.
assert not status()['live']
runtime.start_record(owner, pid, pid, token)
assert status()['grace']
# Crash before installation: a new attempt never inherits the first grace,
# even if .runner and .runner-beat have never existed.
for _ in range(5):
    token = runtime.reserve(owner)
    spawned['token'] = token
    assert not status(spawned=spawned)['first_start']
    assert not status(spawned=spawned)['grace']
    assert not status()['grace']
# Installed phase uses the same history.
(root / '.runner-starting' / f'{pid}-{start}').unlink()
runtime.start_record(owner, pid, pid, token)
runtime.start_record(owner, pid, pid, token, install=True)
assert status()['live'] and not status()['grace']
# One restart after a beat gets grace, but the second does not.
beat = {'attempt': token}
token = runtime.reserve(owner)
spawned['token'] = token
assert status(beat=beat, spawned=spawned)['grace']
token = runtime.reserve(owner)
spawned['token'] = token
assert not status(beat=beat, spawned=spawned)['grace']
# A token with a reused/wrong process start is not a live candidate.
assert not status(spawned=dict(spawned, pid=999999999))['grace']
# Invalid/partial/empty state is not first-start absence.
path = root / '.runner-attempt'
good = path.read_bytes()
for raw in (b'', b' ', b'token=x\n', good.rstrip(b'\n'), good + b'\x00'):
    path.write_bytes(raw)
    try:
        status()
    except (fmt.FormatError, OSError):
        pass
    else:
        raise AssertionError('unknown history granted a verdict')
path.unlink()
os.mkfifo(path)
try:
    status()
except (fmt.FormatError, OSError):
    pass
else:
    raise AssertionError('FIFO history accepted')
path.unlink()
path.symlink_to(root / 'missing')
try:
    status()
except (fmt.FormatError, OSError):
    pass
else:
    raise AssertionError('dangling history accepted')
# The shared process snapshot supplies parent AND start identity. Exercise the
# non-/proc reader with otherwise-valid output on an error exit, not just empty
# output that would be rejected by its shape guard anyway.
from unittest.mock import patch
import builtins
open_original, isdir_original = builtins.open, os.path.isdir

def no_proc(path, *args, **kwargs):
    if str(path).startswith('/proc/'):
        raise FileNotFoundError(str(path))
    return open_original(path, *args, **kwargs)

with patch('builtins.open', no_proc), patch('os.path.isdir', lambda p: False if p == '/proc/self' else isdir_original(p)):
    good = '123 Sun Nov  1 22:00:00 2026\n'
    for code, output in ((1, good), (0, ''), (0, '123\n'), (0, 'bad Sun Nov 1 22:00:00 2026\n'),
                         (0, '١٢٣ Sun Nov 1 22:00:00 2026\n')):
        with patch.object(fmt.subprocess, 'run', return_value=SimpleNamespace(returncode=code, stdout=output)):
            assert fmt.process_identity(pid) == (None, None), (code, output)
    for error in (OSError('ps unavailable'), UnicodeDecodeError('utf8', b'\xff', 0, 1, 'bad output'),
                  fmt.subprocess.TimeoutExpired('ps', 5)):
        with patch.object(fmt.subprocess, 'run', side_effect=error):
            assert fmt.process_identity(pid) == (None, None)
    with patch.object(fmt.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=good)):
        assert fmt.process_identity(pid) == ('Sun-Nov-1-22:00:00-2026', 123)
        assert fmt.pid_starttime(pid) == 'Sun-Nov-1-22:00:00-2026'
print('PASS attempted-start history, both phases, process snapshot and repeated pre-install failures')
PY
