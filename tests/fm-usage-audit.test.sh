#!/usr/bin/env bash
# Audit measured usage vs inferred status activity, exact-ID conflicts, local
# privacy, repeated scripts and duplicate/truncated ledger uncertainty.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-audit)
mkdir "$TMP_ROOT/home"
python3 - "$ROOT" "$TMP_ROOT/home" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root, home = (Path(value).resolve() for value in sys.argv[1:])
secret = 'PRIVATE-PROMPT-NOT-FOR-OUTPUT'
usage = {'schema': 'fm-usage.v1', 'id': 'call-1', 'role': 'analyst', 'ts': 100,
         'input_tokens': 1000, 'cached_input_tokens': 800, 'output_tokens': 10,
         'context_tokens': 1100, 'cycle_kind': 'receipt-only', 'prompt': secret}
def jsonl(name, values):
    (home / name).write_text(''.join(json.dumps(v) + '\n' for v in values))
jsonl('usage.jsonl', [usage, usage, {**usage, 'id': 'conflict'},
                     {**usage, 'id': 'conflict', 'input_tokens': 2000},
                     {**usage, 'id': 'out-of-window', 'ts': 99}])
ledger = {'v': 1, 'ts': 100, 'event': 'task.status', 'task': 'one', 'state': 'paused', 'text': secret}
event = {'schema': 'fm-audit-event.v1', 'id': 'e1', 'ts': 100, 'task': 'one',
         'spawn_gen': 'new', 'correlation': 'request', 'event': 'produced'}
jsonl('events.jsonl', [ledger, ledger, event, event,
                      {**event, 'id': 'e2', 'ts': 107, 'event': 'consumed', 'consumer': 'analysis'},
                      {**event, 'id': 'e3', 'ts': 101, 'spawn_gen': 'old', 'event': 'consumed', 'consumer': 'analysis'}])
with (home / 'events.jsonl').open('a') as out:
    out.write('{"v":1')
(home / 'status').write_text(f'paused [at=100]: {secret}\nack [at=101]: {secret}\n'
                           f'working: {secret}\ndone [at=99]: old\n')
(home / 'scripts').mkdir()
(home / 'scripts/a.py').write_text(secret)
(home / 'scripts/b.py').write_text(secret)

def run(*args, ok=True):
    p = subprocess.run([str(root / 'bin/fm-usage-audit.sh'), '--home', str(home), *map(str, args)],
                       text=True, capture_output=True, timeout=30)
    assert (p.returncode == 0) == ok, p.stderr
    assert secret not in p.stdout + p.stderr
    return json.loads(p.stdout) if ok else None

args = ['--usage', 'usage.jsonl', '--events', 'events.jsonl', '--status', 'status',
        '--scripts', 'scripts', '--since', '100', '--until', '110']
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
a = run(*args)
assert a == run(*args), 'fixed-input audit must be deterministic'
assert before == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
role = a['actual_usage']['by_role']['analyst']
assert role['calls'] == 1 and role['input_tokens'] == 1000 and role['cached_input_tokens'] == 800
assert role['mean_context_tokens'] == 1100
assert role['exporter_cycle_kinds'] == {'receipt-only': 1}
assert a['quality']['conflicting_usage_ids'] == 1
assert a['quality']['incomplete_tails'] == 1
assert a['fleet_ledger']['raw_counts'] == {'task.status': 2}
assert a['fleet_ledger']['exact_unique_lower_bound'] == {'task.status': 1}
assert a['event_to_consumer_latency'][0]['seconds'] == 7
assert len(a['event_to_consumer_latency']) == 1
assert a['status_observations']['lines'] == 2
assert a['status_observations']['by_verb'] == {'paused': 1, 'ack': 1}
assert len(a['identical_scripts'][0]['copies']) == 2
assert a['script_inventory']['by_suffix'] == {'.py': 2}
assert a['status_observations']['characters_with_newlines'] == a['status_observations']['characters'] + 2
(home / 'queue.log').write_text('HANDOFF task=one\nRESULT outcome=landed main=abcdef0123\n'
                               'RESULT outcome=landed main=abcdef0123\nRESULT outcome=culprit\n')
q = run('--queue-log', 'queue.log', '--line-limit', '3')['queue_log']
assert q['by_kind'] == {'HANDOFF': 1, 'RESULT': 2} and q['distinct_landed_main_commits'] == 1
assert q['outcomes'] == {'landed': 2}
assert run('--status', 'status', '--line-limit', '1')['status_observations']['lines'] == 1
(home / 'approvals').mkdir()
(home / 'approvals/a.public.json').write_text('{}')
(home / 'approvals/a.release.json').write_text('{}')
assert run('--inventory', 'approvals')['directory_inventories'][0]['by_suffix'] == {'.public.json': 1, '.release.json': 1}
assert run('--status', 'status')['actual_usage']['available'] is False
assert run(*args, '--usage', 'usage.jsonl')['quality']['duplicate_input_paths'] == 1
run('--status', root / 'AGENTS.md', ok=False)
# An explicitly selected sibling root admits absolute inputs; relative ones stay home-local.
sibling = home.parent / 'sibling-root'
sibling.mkdir()
(sibling / 'queue.log').write_text('RESULT outcome=landed main=abcdef0123\n')
assert run('--also-root', sibling, '--queue-log', sibling / 'queue.log')['queue_log']['outcomes'] == {'landed': 1}
run('--queue-log', sibling / 'queue.log', ok=False)
(home / 'escape').symlink_to(root / 'AGENTS.md')
run('--status', 'escape', ok=False)
jsonl('invalid.jsonl', [{**usage, 'cached_input_tokens': 9999}, {**usage, 'input_tokens': -1},
                        {**usage, 'context_tokens': True}, {**usage, 'role': secret + ' space'}])
assert run('--usage', 'invalid.jsonl')['quality']['invalid_usage_rows'] == 4
# Contradictory productions cannot manufacture one unambiguous latency.
jsonl('ambiguous.jsonl', [event, {**event, 'id': 'other'},
                        {**event, 'id': 'end', 'ts': 120, 'event': 'consumed', 'consumer': 'a'}])
assert run('--events', 'ambiguous.jsonl')['event_to_consumer_latency'] == []
jsonl('conflict-events.jsonl', [event, {**event, 'ts': 101}, {**event, 'id': 'alternative'},
                              {**event, 'id': 'end', 'ts': 120, 'event': 'consumed', 'consumer': 'a'}])
assert run('--events', 'conflict-events.jsonl')['event_to_consumer_latency'] == []
print('PASS: deterministic private audit, measured calls, inferred candidates, identity/latency and coverage uncertainty')
PY
