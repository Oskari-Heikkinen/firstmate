#!/usr/bin/env bash
# Structured fleet-sync receipts and coalesced overlapping refresh,
# without restart or speculative repair.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fleet-provenance)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
root, home = (Path(value).resolve() for value in sys.argv[1:])
(home / 'projects').mkdir()
work, remote, clone = home / 'work', home / 'remote.git', home / 'projects/example'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root), FM_FLEET_PRUNE='0')
for k in ('FM_PROJECTS_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
    env.pop(k, None)

def git(*args):
    return subprocess.check_output(['git', *map(str, args)], env=env, stderr=subprocess.DEVNULL, text=True).strip()
git('init', work)
git('-C', work, 'checkout', '-b', 'main')
(work / 'file').write_text('one')
git('-C', work, 'add', 'file')
git('-C', work, 'commit', '-m', 'one')
git('clone', '--bare', work, remote)
git('clone', remote, clone)
old = git('-C', clone, 'rev-parse', 'HEAD')
(work / 'file').write_text('two')
git('-C', work, 'commit', '-am', 'two')
git('-C', work, 'push', remote, 'main')
new = git('-C', work, 'rev-parse', 'HEAD')

def sync(environment=env):
    p = subprocess.run([str(root / 'bin/fm-fleet-sync.sh'), 'example'], env=environment,
                       text=True, capture_output=True, timeout=180)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p.stdout

def receipt():
    path = home / 'data/fleet-sync' / (hashlib.sha256(str(clone).encode()).hexdigest() + '.json')
    return path, json.loads(path.read_text())

assert sync().startswith('example: '), 'status lines keep the project name'
p, r = receipt()
assert r['before']['source'] == old and r['after']['source'] == new, r
assert r['after']['remote_tip'] == new and r['fetch_succeeded'] is True, r
assert r['outcome'] == 'synced'
sync()
assert receipt()[1]['outcome'] == 'current'
(clone / 'file').write_text('uncommitted')
sync()
assert receipt()[1]['outcome'] == 'stuck'
assert receipt()[1]['after']['dirty'] is True
assert (clone / 'file').read_text() == 'uncommitted'
(clone / 'file').write_text('two')
sync()
p, r = receipt()
# Fetch failure retains observed tracking/source commits but never current-remote proof.
git('-C', clone, 'remote', 'set-url', 'origin', home / 'absent.git')
sync()
assert receipt()[1]['fetch_succeeded'] is False
git('-C', clone, 'remote', 'set-url', 'origin', remote)
# Real git work is preserved, but a bounded fetch delay makes overlap deterministic.
tools = home / 'tools'
tools.mkdir()
real_git = shutil.which('git')
wrapper = tools / 'git'
wrapper.write_text('#!/usr/bin/env bash\n'
                   'if [ "${3:-}" = fetch ]; then\n'
                   f'  echo fetch >> "{home}/fetch-count"\n'
                   f'  for _ in $(seq 1200); do [ -e "{home}/release" ] && break; sleep .1; done\n'
                   'fi\n'
                   f'exec "{real_git}" "$@"\n')
wrapper.chmod(0o755)
slow_env = dict(env, PATH=str(tools) + os.pathsep + env['PATH'])
command = [str(root / 'bin/fm-fleet-sync.sh'), 'example']

def overlap(late_requests):
    """Hold one fetch in flight, send later requests, then release every fetch."""
    for name in ('fetch-count', 'release'):
        (home / name).unlink(missing_ok=True)
    first = subprocess.Popen(command, env=slow_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(1500):
        if (home / 'fetch-count').exists():
            break
        time.sleep(.02)
    else:
        raise AssertionError('first fetch did not start')
    later = [subprocess.Popen(command, env=slow_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
             for _ in range(late_requests)]
    # Later requests stamp arrival at entry, before handing off to the receipt
    # helper, so each one's waiting helper child proves its arrival is stamped.
    for _ in range(3000):
        listing = subprocess.run(['ps', '-A', '-o', 'ppid=,args='], text=True,
                                 capture_output=True).stdout.splitlines()
        waiting = {int(row.split(None, 1)[0]) for row in listing
                   if 'fm-fleet-provenance.py' in row}
        if all(process.pid in waiting for process in later):
            break
        time.sleep(.02)
    (home / 'release').write_text('')
    outputs = [process.communicate(timeout=180) for process in [first, *later]]
    assert all(process.returncode == 0 for process in [first, *later]), outputs
    return len((home / 'fetch-count').read_text().splitlines()), [out for out, _ in outputs]

# A request arriving after a fetch began never reuses it: the remote may have moved.
fetches, outputs = overlap(1)
assert fetches == 2, (fetches, outputs)
assert not any('coalesced refresh' in out for out in outputs), outputs
# Requests queued together behind that in-flight run share its successor's fetch.
fetches, outputs = overlap(2)
assert fetches == 2, (fetches, outputs)
assert sum('coalesced refresh' in out for out in outputs[1:]) == 1, outputs
assert receipt()[1]['after']['source'] == new
# A corrupt prior receipt is replaced, never trusted for coalescing or fatal.
receipt()[0].write_text('{not json')
sync()
assert receipt()[1]['outcome'] == 'current'
# An unavailable receipt store warns but never costs the refresh itself.
git('-C', work, 'commit', '--allow-empty', '-m', 'three')
git('-C', work, 'push', remote, 'main')
newest = git('-C', work, 'rev-parse', 'HEAD')
store = home / 'data/fleet-sync'
store.rename(home / 'data/fleet-sync.aside')
store.write_text('not a directory')
unstored = subprocess.run([str(root / 'bin/fm-fleet-sync.sh'), 'example'], env=env,
                          text=True, capture_output=True, timeout=180)
assert unstored.returncode == 0 and 'receipt unavailable' in unstored.stderr, unstored
assert git('-C', clone, 'rev-parse', 'HEAD') == newest
store.unlink()
(home / 'data/fleet-sync.aside').rename(store)
# Every wait is bounded. A fetch that never returns costs one child bound.
hang_tools = home / 'hang-tools'
hang_tools.mkdir()
hang = hang_tools / 'git'
hang.write_text('#!/usr/bin/env bash\n'
                'if [ "${3:-}" = fetch ]; then\n'
                f'  echo $$ >> "{home}/hung-pids"\n'
                f'  for _ in $(seq 3000); do [ -e "{home}/hang-release" ] && break; sleep .1; done\n'
                'fi\n'
                f'exec "{real_git}" "$@"\n')
hang.chmod(0o755)
hang_env = dict(env, PATH=str(hang_tools) + os.pathsep + env['PATH'], FM_FLEET_SYNC_FETCH_TIMEOUT='600')
# The session sweep that reaches a bounded fetch's own process group reads /proc.
linux = Path('/proc/self/stat').exists()

def hung_pids():
    path = home / 'hung-pids'
    return [int(pid) for pid in path.read_text().split()] if path.exists() else []

def running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
    except (OSError, IndexError):
        return True

def all_stopped(pids):
    for _ in range(600):
        if not any(running(pid) for pid in pids):
            return True
        time.sleep(.05)
    return False

try:
    # The child bound stops the whole refresh, its bounded fetch included; the
    # bound leaves a loaded runner room to reach the fetch first.
    p = subprocess.run(command, env=dict(hang_env, FM_FLEET_SYNC_CHILD_TIMEOUT='10'),
                       text=True, capture_output=True, timeout=180)
    assert p.returncode == 0, (p.stdout, p.stderr)
    assert 'example: skipped: refresh timed out after 10s' in p.stdout, (p.stdout, p.stderr)
    assert receipt()[1]['outcome'] == 'failed' and receipt()[1]['fetch_succeeded'] is False, receipt()[1]
    timed_out = hung_pids()
    assert timed_out, 'the hung fetch never started'
    assert not linux or all_stopped(timed_out), 'a timed-out refresh left its bounded fetch running'
    # A request behind a refresh that still holds the clone's lock gives up at its deadline.
    before_wait = receipt()[0].read_bytes()
    with (home / 'data/fleet-sync' / (hashlib.sha256(str(clone).encode()).hexdigest() + '.lock')).open('a') as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        p = subprocess.run(command, env=dict(hang_env, FM_FLEET_SYNC_LOCK_WAIT='1'),
                           text=True, capture_output=True, timeout=180)
    assert p.returncode == 0, (p.stdout, p.stderr)
    assert 'example: skipped: refresh lock wait timed out after 1s' in p.stdout, (p.stdout, p.stderr)
    assert hung_pids() == timed_out, 'a request that never got the lock still fetched'
    assert receipt()[0].read_bytes() == before_wait, 'a lock-wait timeout replaced the receipt'
    # A group TERM to the caller, as bootstrap sends at its refresh bound, reaches the child's own session.
    caller = subprocess.Popen(command, env=hang_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, start_new_session=True)
    for _ in range(3000):
        if len(hung_pids()) > len(timed_out):
            break
        time.sleep(.02)
    else:
        raise AssertionError('the refresh to be stopped never reached its fetch')
    os.killpg(caller.pid, signal.SIGTERM)
    caller.communicate(timeout=60)
    stopped = hung_pids()[len(timed_out):]
    assert not linux or all_stopped(stopped), 'a TERM to the caller left the refresh child fetching'
finally:
    (home / 'hang-release').write_text('')
print('PASS: sync receipts, concurrent coalescing and dirty/fetch refusal, bounded waits')
PY
