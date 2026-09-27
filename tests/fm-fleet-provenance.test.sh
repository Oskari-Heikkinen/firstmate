#!/usr/bin/env bash
# Structured fleet-sync receipts, coalesced overlapping refresh and application
# provenance join, without restart or speculative repair.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-fleet-provenance)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
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

sync()
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
evidence = home / 'app-evidence.json'
evidence.write_text('{"owner":"application"}')
ref = {'path': str(evidence.relative_to(home)), 'sha256': hashlib.sha256(evidence.read_bytes()).hexdigest()}
app = {'schema': 'fm-application-observations.v1', 'clone': str(clone), 'stages': {
    name: {'revision': new, 'identity': name + '-instance', 'observed_at': time.time(), 'evidence': ref}
    for name in ('build', 'server', 'browser')}}
app_path = home / 'application.json'

def readout(with_app=True, ok=True):
    app_path.write_text(json.dumps(app))
    command = [str(root / 'bin/fm-application-provenance.sh'), str(p)]
    if with_app:
        command += ['--application', str(app_path)]
    run = subprocess.run(command, env=env, text=True, capture_output=True)
    assert (run.returncode == 0) == ok, run.stderr
    return json.loads(run.stdout) if ok else None

assert readout(False)['application_state'] == 'unknown'
assert readout()['application_state'] == 'owner-reported-match'
app['stages']['browser']['revision'] = old
assert readout()['application_state'] == 'source-updated-app-not-updated'
app['stages']['browser']['observed_at'] = 1
assert readout()['application_state'] == 'unknown'
app['stages']['browser']['observed_at'] = time.time() + 999
assert readout()['stages']['browser']['state'] == 'unknown'
app['clone'] = str(work)
readout(ok=False)
app['clone'] = str(clone)
app['stages']['browser']['observed_at'] = time.time()
evidence.write_text('changed')
assert readout()['stages']['build']['state'] == 'unknown'
# Fetch failure retains observed tracking/source commits but never current-remote proof.
git('-C', clone, 'remote', 'set-url', 'origin', home / 'absent.git')
sync()
assert receipt()[1]['fetch_succeeded'] is False
assert readout(False)['source_current'] is False, readout(False)
git('-C', clone, 'remote', 'set-url', 'origin', remote)
# Real git work is preserved, but a bounded fetch delay makes overlap deterministic.
tools = home / 'tools'
tools.mkdir()
real_git = shutil.which('git')
wrapper = tools / 'git'
wrapper.write_text('#!/usr/bin/env bash\n'
                   'if [ "${3:-}" = fetch ]; then\n'
                   f'  echo fetch >> "{home}/fetch-count"\n'
                   '  sleep 2\nfi\n'
                   f'exec "{real_git}" "$@"\n')
wrapper.chmod(0o755)
slow_env = dict(env, PATH=str(tools) + os.pathsep + env['PATH'])
command = [str(root / 'bin/fm-fleet-sync.sh'), 'example']
one = subprocess.Popen(command, env=slow_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
for _ in range(1500):
    if (home / 'fetch-count').exists():
        break
    time.sleep(.02)
else:
    raise AssertionError('first fetch did not start')
two = subprocess.Popen(command, env=slow_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
out1, err1 = one.communicate(timeout=180)
out2, err2 = two.communicate(timeout=180)
assert one.returncode == two.returncode == 0, (out1, err1, out2, err2)
assert (home / 'fetch-count').read_text().splitlines() == ['fetch'], ((home / 'fetch-count').read_text(), out1, err1, out2, err2, receipt()[1])
assert 'coalesced refresh' in out2
assert receipt()[1]['after']['source'] == new
# No application evidence file was rewritten by a source refresh.
assert evidence.read_text() == 'changed'
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
print('PASS: sync receipts, concurrent coalescing, dirty/fetch refusal and explicit application provenance')
PY
