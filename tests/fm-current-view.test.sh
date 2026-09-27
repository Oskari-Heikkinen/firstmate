#!/usr/bin/env bash
# Public receipt projection, resume and role-brief contracts, including stale
# identities, bad bindings and durable open-decision preservation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-current-view)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root, tmp = (Path(value).resolve() for value in sys.argv[1:])
home = tmp / 'home'
for name in ('data', 'state', 'config', 'projects'):
    (home / name).mkdir(parents=True, exist_ok=True)
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root),
           FM_SNAPSHOT_CREW_STATE_TIMEOUT='20')
for key in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    env.pop(key, None)

def write(name, value):
    p = home / name
    p.write_text(json.dumps(value))
    return p

def ref(p):
    return {'path': str(p.relative_to(home)), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}

def run(tool, *args, ok=True, stdin=None):
    p = subprocess.run([str(root / 'bin' / tool), *map(str, args)], env=env,
                       text=True, input=stdin, capture_output=True, timeout=90)
    assert (p.returncode == 0) == ok, (p.returncode, p.stdout, p.stderr)
    return p.stdout

intent = home / 'intent.md'
intent.write_text('Implement exactly this approved request.\n')
rationale = home / 'hazards.md'
rationale.write_text('Do not remove retained evidence.\n')
evidence = home / 'evidence.txt'
evidence.write_text('retained evidence')
ident = {'home': str(home), 'task': 'job', 'spawn_gen': 'generation-one'}
proof = write('proof.json', {**ident, 'schema': 'fm-owner-verification.v1',
                            'receipt_id': 'result-1', 'accepted': True, 'evidence': [ref(evidence)]})
r = {**ident, 'schema': 'fm-owner-receipt.v1', 'id': 'result-1', 'observed_at': time.time(),
     'milestone': 'collected', 'versions': {'kit': 'v10.1'}, 'dependencies': ['review'],
     'gaps': [], 'observer': 'observer-one', 'evidence': [ref(evidence)],
     'terminal': True, 'verification': ref(proof)}
rpath = write('receipt.json', r)
m = {**ident, 'schema': 'fm-role-packet.v1', 'role': 'analysis', 'mode': 'direct-PR',
     'owned_paths': ['data/job'], 'intent': ref(intent), 'rationale': ref(rationale),
     'receipts': [ref(rpath)]}
mpath = write('packet.json', m)
snapshot = {'schema': 'fm-fleet-snapshot.v1', 'fm_home': str(home), 'generated': '2026-09-27T00:00:00Z',
            'tasks': [{'id': 'job', 'spawn_gen': ident['spawn_gen'], 'current_state': {'state': 'done'},
                       'hints': {'open_decisions': [], 'recorded_open_decisions': [{'key': 'choose', 'verb': 'needs-decision'}]},
                       'paths': {'status_log': {'path': str(home / 'state/job.status')}}}],
            'backlog': {'records': [{'id': 'job', 'hold_kind': 'captain', 'unresolved_blocker_ids': ['review']}]}}
snap = write('snapshot.json', snapshot)

def resume():
    return json.loads(run('fm-resume-packet.sh', '--manifest', mpath, '--snapshot', snap, '--json'))

view = resume()
assert view['receipts'][0]['state'] == 'verified-terminal'
assert view['recorded_open_decisions'][0]['key'] == 'choose'
assert view['backlog'][0]['hold_kind'] == 'captain'
assert view['receipts'][0]['owner_reported_versions']['kit'] == 'v10.1'
assert view['authored_rationale_and_hazards'] == ref(rationale)
run('fm-brief.sh', 'job', 'repo', '--mode', 'direct-PR', '--role-packet', mpath)
brief = (home / 'data/job/brief.md').read_text()
assert 'Receipt-derived role context' in brief
assert 'Delivery contract: mode=direct-PR' in brief
assert "## Captain's intent\n{TASK}" in brief
assert 'worktree-isolation' in brief or 'Verify isolation' in brief
run('fm-brief.sh', 'other', 'repo', '--mode', 'local-only', '--role-packet', mpath, ok=False)
assert not (home / 'data/other/brief.md').exists()

for change, expected in [({'gaps': ['retained omission']}, 'collection-problems'),
                         ({'verification': None}, 'terminal-unverified'),
                         ({'terminal': False}, 'in-progress'),
                         ({'disposition': 'retained-for-reference'}, 'retained-for-reference'),
                         ({'spawn_gen': 'old'}, 'unknown')]:
    write('receipt.json', {**r, **change})
    write('packet.json', {**m, 'receipts': [ref(rpath)]})
    assert resume()['receipts'][0]['state'] == expected
write('receipt.json', r)
write('packet.json', {**m, 'receipts': [ref(rpath), ref(rpath)]})
assert all(row['state'] == 'unknown' for row in resume()['receipts'])
write('packet.json', {**m, 'receipts': [ref(rpath)]})
evidence.write_text('changed after verification')
assert resume()['receipts'][0]['state'] == 'unknown'
evidence.write_text('retained evidence')
new_snapshot = copy.deepcopy(snapshot)
new_snapshot['tasks'][0]['spawn_gen'] = 'replacement'
write('snapshot.json', new_snapshot)
assert resume()['receipts'][0]['state'] == 'unknown'
write('snapshot.json', snapshot)
proof_value = json.loads(proof.read_text())
proof_value['receipt_id'] = 'wrong-result'
write('proof.json', proof_value)
write('receipt.json', {**r, 'verification': ref(proof)})
write('packet.json', {**m, 'receipts': [ref(rpath)]})
assert resume()['receipts'][0]['state'] == 'unknown'
# Invalid reference refuses scaffolding before creating any brief.
run('fm-brief.sh', 'job', 'repo', '--mode', 'direct-PR', '--role-packet', mpath, ok=False)
# No cross-home references, including symlinks.
(home / 'outside').symlink_to(tmp)
write('packet.json', {**m, 'rationale': {'path': 'outside/private', 'sha256': '0' * 64}})
run('fm-resume-packet.sh', '--manifest', mpath, '--snapshot', snap, ok=False)
# The real snapshot consumes receipts and retains the raw decision fold even
# when the lifecycle projection would suppress the decision for a completed scout.
write('packet.json', {**m, 'receipts': []})
(home / 'state/job.meta').write_text('kind=scout\nspawn_gen=generation-one\nbackend=tmux\nwindow=\n')
(home / 'state/job.status').write_text('needs-decision [at=100] [key=choose]: pick\ndone [at=101]: report complete\n')
actual = json.loads(run('fm-fleet-snapshot.sh', '--json', '--receipts', mpath))
assert actual['owner_view']['role'] == 'analysis'
assert actual['tasks'][0]['hints']['recorded_open_decisions'][0]['key'] == 'choose'
with (home / 'state/job.status').open('a') as out:
    out.write('resolved [at=102] [key=choose]: actual answer\n')
actual = json.loads(run('fm-fleet-snapshot.sh', '--json', '--receipts', mpath))
assert actual['tasks'][0]['hints']['recorded_open_decisions'] == []
assert intent.read_text() == 'Implement exactly this approved request.\n'
print('PASS: receipt views, role brief validation, generation binding and decision preservation')
PY
