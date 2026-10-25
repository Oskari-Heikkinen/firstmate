#!/usr/bin/env bash
# P0 public-interface tests. Synthetic inputs and fake tracer only; no live
# endpoints, profiler, workload, home state or mode switch. Run in CI, not on
# the operator laptop. Fixtures exercise six/thirty crews and negative controls.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-supervision-accounting)
export FM_ACCOUNTING_TEST_ROOT="$ROOT" FM_ACCOUNTING_TEST_TMP="$TMP"
python3 - <<'PY'
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ['FM_ACCOUNTING_TEST_ROOT'])
tmp = Path(os.environ['FM_ACCOUNTING_TEST_TMP'])
cli = root / 'bin/fm-supervision-accounting.py'
spec = importlib.util.spec_from_file_location('fixture', root / 'tests/fixtures/supervision-accounting/fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
checks = 0
# Routing is observed through the public selector, not implementation bytes.
selection = subprocess.run(['bash', str(root / 'bin/fm-test-run.sh'), '--list',
                            '--family', 'pure-contract-unit', '--tier', 'gate'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
assert selection.returncode == 0, selection.stderr
assert 'tests/fm-supervision-accounting.test.sh' in selection.stdout.decode().splitlines()
assert 'tests/fm-supervision-accounting-live.test.sh' not in selection.stdout.decode().splitlines()
checks += 1


def save(name, value):
    path = tmp / name
    path.write_text(json.dumps(value))
    return path


def run(*arguments, good=True, env=None, timeout=30):
    result = subprocess.run([sys.executable, str(cli), *map(str, arguments)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env)
    assert result.returncode == (0 if good else 2), (arguments, result.returncode, result.stderr)
    if not good:
        assert not result.stdout and b'refused:' in result.stderr, (arguments, result)
        assert b'Traceback' not in result.stderr, result.stderr
    return result


def reject(value, label):
    run('replay', save(label + '.json', value), good=False)


for count in (6, 30):
    value = fixture.make(count)
    path = save(str(count) + '.json', value)
    result = json.loads(run('replay', path).stdout)
    assert result['observed_births'] == 4 * count + 5
    assert sum(result['exclusive_births'].values()) == result['observed_births']
    assert result['exclusive_births']['crew-state'] == 4 * count
    assert result['exclusive_births']['fleet-snapshot'] == 1
    assert result['exclusive_births']['watch'] == 1
    assert result['exclusive_births']['spawn'] == 1  # not the sourced-library mention
    assert result['residual'] == 3
    assert result['caller_edges']['fleet-snapshot -> crew-state'] == count
    assert result['entry_counts']['crew-state'] == count
    assert result['births_by_origin_ancestry']['watch'] == result['observed_births']
    assert sum(row['exclusive_child_births'] + row['self_births']
               for row in result['per_invocation'].values()) == result['observed_births']
    crew_invocations = [row for row in result['per_invocation'].values() if row['family'] == 'crew-state']
    assert len(crew_invocations) == count
    assert all(row['self_births'] == 1 and row['exclusive_child_births'] == 3 for row in crew_invocations)
    assert sum(entry['lifecycle_entry'] for entry in result['entries']) == 1
    assert result['claimed_births_per_second_saved'] == 0 and 'b0_eligible' not in result
    assert result['b0_status'] == 'pending-reviewed-real-capture'
    assert result['synthetic'] and not result['complete_for_attached_trees']
    assert result['seed_cmdline_hints'] == 1
    assert result['seed_ownership'] == [{'id': 'root', 'family': 'watch',
                                        'evidence': 'proc-exe-cmdline',
                                        'qualification': 'cmdline-hint-not-observed-entry'}]
    assert result['format'] == 'fm-supervision-accounting.v1'
    assert result['duration_ns'] == 60000000000
    assert result['machine_births'] == 4 * count + 8
    assert result['births_per_second'] == (4 * count + 5) / 60
    assert result['thread_births_included'] == 0
    assert result['sealed_records'] == 3 and result['requests'] == count
    assert result['losses'] == dict.fromkeys(value['trace']['losses'], 0)
    expected_totals = {'crew-state': 4 * count, 'watch': 1, 'wake-drain': 1,
                       'fleet-snapshot': 1, 'spawn': 1, 'control': 1, 'unattributed': 0}
    assert result['exclusive_births'] == expected_totals
    assert result['births_by_origin_ancestry'] == dict.fromkeys(expected_totals, 0) | {'watch': 4 * count + 5}
    expected_counts = {'crew-state': count, 'watch': 0, 'wake-drain': 1,
                       'fleet-snapshot': 1, 'spawn': 1, 'control': 1}
    assert result['entry_counts'] == expected_counts
    assert result['caller_edges'] == {'watch -> fleet-snapshot': 1,
                                      'fleet-snapshot -> crew-state': count,
                                      'watch -> wake-drain': 1, 'watch -> spawn': 1,
                                      'watch -> control': 1}
    expected_invocations = {'root:initial': {'family': 'watch', 'seed': True,
                                            'self_births': 0, 'exclusive_child_births': 1},
                            'unattributed': {'family': 'unattributed', 'seed': False,
                                             'self_births': 0, 'exclusive_child_births': 0}}
    ids = ['summary', *['crew-' + str(n) for n in range(count)], 'wake-drain', 'spawn', 'control']
    assert [e['id'] for e in result['entries']] == ids
    for index, ident in enumerate(ids):
        e = result['entries'][index]
        family = 'crew-state' if ident.startswith('crew-') else 'fleet-snapshot' if ident == 'summary' else ident
        invocation = ident + ':entry:' + str(index)
        assert e['invocation'] == invocation and e['family'] == family
        assert e['caller_family'] == ('fleet-snapshot' if family == 'crew-state' else 'watch')
        assert e['caller_invocation'] == ('summary:entry:0' if family == 'crew-state' else 'root:initial')
        assert e['home'] == 'fixture' and e['exec_evidence'] == 'execve' and e['executable'] == '/bin/bash'
        assert e['at_ns'] == next(ev['at_ns'] for ev in value['trace']['events']
                                   if ev['id'] == ident and ev['kind'] == 'exec')
        expected_invocations[invocation] = {'family': family, 'seed': False, 'self_births': 1,
                                            'exclusive_child_births': 3 if family == 'crew-state' else 0}
    assert result['per_invocation'] == expected_invocations
    for record in value['records']:
        raw = run('read-record', path, '--kind', record['kind'], '--name', record['name']).stdout
        assert raw == base64.b64decode(record['base64'])
    # Cheap counterpart preserves the exact entry/request schedule, removing
    # only redundant synthetic date/stat descendants, not actual observations.
    cheap = copy.deepcopy(value)
    cheap['trace']['events'] = [event for event in value['trace']['events']
                                if not event['id'].endswith(('-date', '-stat'))]
    cheap['trace']['machine_births'] -= 2 * count
    cheap_result = json.loads(run('replay', save('cheap-' + str(count) + '.json', cheap)).stdout)
    assert cheap_result['exclusive_births']['crew-state'] == 2 * count
    assert cheap_result['entries'] == result['entries']
    assert cheap_result['residual'] == result['residual']
    assert cheap_result['observed_births'] == 2 * count + 5
    assert cheap_result['machine_births'] == 2 * count + 8
    assert cheap_result['births_per_second'] == (2 * count + 5) / 60
    expected_totals['crew-state'] = 2 * count
    assert cheap_result['exclusive_births'] == expected_totals
    assert cheap_result['entry_counts'] == expected_counts
    assert cheap_result['caller_edges'] == result['caller_edges']
    for row in expected_invocations.values():
        if row['family'] == 'crew-state':
            row['exclusive_child_births'] = 1
    assert cheap_result['per_invocation'] == expected_invocations
    assert cheap_result['births_by_origin_ancestry'] == dict.fromkeys(expected_totals, 0) | {'watch': 2 * count + 5}
    assert cheap_result['duration_ns'] == result['duration_ns']
    checks += 1

value = fixture.make(6)
for field, mutation in (
    ('sealed-record', lambda v: v['records'][0].update(sha256='0' * 64)),
    ('bad-base64', lambda v: v['records'][0].update(base64='!')),
    ('duplicate-record', lambda v: v['records'].append(v['records'][0])),
    ('version', lambda v: v.update(format='fm-supervision-replay.v2')),
    ('provenance', lambda v: v.update(synthetic=False)),
    ('negative-counter', lambda v: v['trace'].update(machine_births=-1)),
    ('time-reversed', lambda v: v['trace'].update(end_ns=0)),
    ('duplicate-birth', lambda v: v['trace']['events'].insert(2, v['trace']['events'][1])),
    ('late-request', lambda v: v['requests'][0].update(at_ns=90000000000)),
    ('orphan-birth', lambda v: v['trace']['events'][1].update(parent='missing')),
    ('duplicate-home', lambda v: v['manifest']['homes'].append(v['manifest']['homes'][0])),
    ('enrollment', lambda v: v['manifest'].update(enrolled_homes=['other'])),
    ('unknown-field', lambda v: v['manifest']['homes'][0].update(guess='healthy')),
    ('unknown-exec', lambda v: v['trace']['events'][2].update(argv=[])),
):
    changed = copy.deepcopy(value)
    mutation(changed)
    reject(changed, field)
    checks += 1

# Keep contradictions instead of clipping them or presenting a false savings.
changed = copy.deepcopy(value)
changed['trace']['machine_births'] = 1
negative = json.loads(run('replay', save('contradiction.json', changed)).stdout)
assert negative['residual'] < 0 and not negative['complete_for_attached_trees']
changed = copy.deepcopy(value)
changed['trace']['losses']['unresolved_argv'] = 1
lossy = json.loads(run('replay', save('lossy.json', changed)).stdout)
assert not lossy['complete_for_attached_trees']
changed = copy.deepcopy(value)
changed['trace']['events'][1]['thread'] = True
threads = json.loads(run('replay', save('threads.json', changed)).stdout)
assert threads['thread_births_included'] == 1 and threads['observed_births'] == 29
# Executing a script twice without a birth must not invent a second birth.
changed = copy.deepcopy(value)
extra = copy.deepcopy(changed['trace']['events'][-1])
extra['at_ns'] += 1
extra['argv'] = ['bash', '/fixture/code/bin/fm-control.sh', 'task-0', 'relaunch', '--note', 'saved work']
changed['trace']['events'].append(extra)
reexec = json.loads(run('replay', save('reexec.json', changed)).stdout)
assert reexec['observed_births'] == 29
assert reexec['entries'][-1]['lifecycle_entry']
checks += 4

# F1: the public control grammar is TARGET VERB, never VERB TARGET.
# Each valid verb has an unknown/malformed counterpart, including a task named
# after a verb. Entry classification does not certify CLI admission or effect.
for arguments, target, action, shape, lifecycle in (
    (['task-0', 'interrupt'], 'task-0', 'interrupt', 'recognized', True),
    (['task-0', 'exit'], 'task-0', 'exit', 'recognized', True),
    (['task-0', 'relaunch', '--note', 'saved work'], 'task-0', 'relaunch', 'recognized', True),
    (['relaunch', 'state'], 'relaunch', 'state', 'unknown', False),
    (['interrupt'], 'interrupt', '', 'malformed', False),
    ([], '', '', 'malformed', False),
    (['task-0', 'resume'], 'task-0', 'resume', 'unknown', False),
    (['task-0', 'restart'], 'task-0', 'restart', 'unknown', False),
    (['task-0', 'start'], 'task-0', 'start', 'unknown', False),
    (['task-0', 'stop'], 'task-0', 'stop', 'unknown', False),
):
    changed = copy.deepcopy(value)
    event = next(e for e in changed['trace']['events'] if e['id'] == 'control' and e['kind'] == 'exec')
    event['argv'] = ['bash', '/fixture/code/bin/fm-control.sh', *arguments]
    result = json.loads(run('replay', save('control-grammar.json', changed)).stdout)
    entry = next(e for e in result['entries'] if e['family'] == 'control')
    assert (entry['target'], entry['action'], entry['call_shape'], entry['lifecycle_entry']) == (
        target, action, shape, lifecycle), entry
    assert result['entry_counts']['control'] == 1
    checks += 1

# Seed argv is mutable proc cmdline, NOT a kernel-observed script entry. Even
# a matching executable can establish only an explicitly reported ancestry hint.
changed = copy.deepcopy(value)
changed['trace']['events'][0]['executable'] = '/bin/echo'
seed_control = json.loads(run('replay', save('forged-seed.json', changed)).stdout)
assert seed_control['seed_cmdline_hints'] == 0
assert seed_control['seed_ownership'][0]['family'] == 'unattributed'
assert seed_control['entry_counts']['watch'] == 0
for field in ('executable', 'exec_evidence'):
    changed = copy.deepcopy(value)
    del changed['trace']['events'][0][field]
    reject(changed, 'seed-missing-' + field)
changed = copy.deepcopy(value)
changed['trace']['events'][0]['exec_evidence'] = 'execve'
reject(changed, 'seed-fabricated-proof')
checks += 4

# A fully observed in-window entry can give a structural complete verdict
# without claiming seed proof or B0; use this as the loss/seed negative control.
complete = copy.deepcopy(value)
complete['trace']['events'] = complete['trace']['events'][:3]
complete['trace']['events'][0].update(executable='/usr/bin/python3', argv=['python3'])
complete['trace']['events'][2]['argv'] = ['bash', '/fixture/code/bin/fm-watch.sh']
complete['trace']['machine_births'] = 4
complete_result = json.loads(run('replay', save('complete.json', complete)).stdout)
assert complete_result['complete_for_attached_trees'] and complete_result['seed_cmdline_hints'] == 0
assert complete_result['exclusive_births']['watch'] == 1 and complete_result['residual'] == 3
assert complete_result['b0_status'] == 'pending-reviewed-real-capture'
changed = copy.deepcopy(complete)
changed['trace']['losses']['unresolved_argv'] = 1
assert not json.loads(run('replay', save('complete-with-loss.json', changed)).stdout)['complete_for_attached_trees']
changed = copy.deepcopy(complete)
changed['trace']['events'][0].update(executable='/bin/bash', argv=['bash', '/fixture/code/bin/fm-watch.sh'])
assert not json.loads(run('replay', save('complete-with-hint.json', changed)).stdout)['complete_for_attached_trees']
for field, bad in (('exec_evidence', 'proc-exe-cmdline'), ('executable', '/bin/ba\x00sh'),
                   ('argv', ['bash', 'bad\x00arg'])):
    changed = copy.deepcopy(complete)
    changed['trace']['events'][2][field] = bad
    reject(changed, 'invalid-exec-' + field)
checks += 6

# F6: loss/unknown/completeness paths must discriminate against a genuinely
# complete positive, not a seed-hinted fixture that is already incomplete.
for field in complete['trace']['losses']:
    changed = copy.deepcopy(complete)
    changed['trace']['losses'][field] = 2
    result = json.loads(run('replay', save('loss-' + field + '.json', changed)).stdout)
    assert result['losses'] == changed['trace']['losses']
    assert not result['complete_for_attached_trees']
    checks += 1
changed = copy.deepcopy(complete)
changed['trace']['capture_complete'] = False
assert not json.loads(run('replay', save('incomplete.json', changed)).stdout)['complete_for_attached_trees']
changed = copy.deepcopy(complete)
changed['trace']['machine_births'] = 0
result = json.loads(run('replay', save('negative-complete.json', changed)).stdout)
assert result['residual'] == -1 and not result['complete_for_attached_trees']
changed = copy.deepcopy(complete)
changed['trace']['events'] = changed['trace']['events'][:2]
result = json.loads(run('replay', save('unattributed.json', changed)).stdout)
assert result['exclusive_births']['unattributed'] == 1 and not result['complete_for_attached_trees']
# Origin is fixed at birth, whereas direct entry/future descendants change owner.
changed = copy.deepcopy(complete)
changed['trace']['events'][2]['argv'] = ['bash', '/fixture/code/bin/fm-spawn.sh', 'task-0', '--restore']
for ident, parent, script in (('c', 'summary', 'fm-control.sh'), ('d', 'c', 'fm-crew-state.sh')):
    changed['trace']['events'].extend([
        {'kind': 'birth', 'id': ident, 'parent': parent, 'at_ns': len(changed['trace']['events']) + 1,
         'argv': [], 'home': '', 'thread': True, 'executable': '', 'exec_evidence': 'none'},
        {'kind': 'exec', 'id': ident, 'parent': '', 'at_ns': len(changed['trace']['events']) + 2,
         'argv': ['bash', '/fixture/code/bin/' + script, 'task-0', 'exit'], 'home': '',
         'thread': False, 'executable': '/bin/bash', 'exec_evidence': 'execve'}])
result = json.loads(run('replay', save('origin.json', changed)).stdout)
assert result['observed_births'] == 3 and result['thread_births_included'] == 2
assert result['residual'] == 1 and result['births_per_second'] == 3 / 60
assert result['births_by_origin_ancestry']['unattributed'] == 1
assert result['births_by_origin_ancestry']['spawn'] == 2
assert {k: v for k, v in result['exclusive_births'].items() if v} == {'spawn': 1, 'control': 1, 'crew-state': 1}
assert result['entries'][0]['action'] == 'restore'
assert result['entries'][1]['lifecycle_entry'] and result['entries'][1]['action'] == 'exit'
assert result['complete_for_attached_trees']
checks += 4

# All nonempty adapter response fields are loaded but never executed.
# Every negative starts otherwise-valid, so a removed guard cannot hide behind
# an unrelated version/type/seed failure. Test both response byte streams.
for field, bad in (('adapter', ''), ('generation', ''), ('at_ns', -1),
                   ('at_ns', 60000000001), ('exit_status', -1), ('exit_status', 256),
                   ('exit_status', True), ('stdout_base64', '!'), ('stderr_base64', '!'),
                   ('stdout_base64', base64.b64encode(b'x' * 1048577).decode()),
                   ('stderr_base64', base64.b64encode(b'x' * 1048577).decode()),
                   ('unexpected', 'field')):
    changed = copy.deepcopy(complete)
    changed['requests'][0]['adapter_responses'][0][field] = bad
    reject(changed, 'response-' + field)
    checks += 1
for field in ('adapter', 'generation', 'at_ns', 'exit_status', 'stdout_base64', 'stderr_base64'):
    changed = copy.deepcopy(complete)
    del changed['requests'][0]['adapter_responses'][0][field]
    reject(changed, 'response-missing-' + field)
    checks += 1
changed = copy.deepcopy(complete)
changed['requests'][0]['at_ns'] = 1
changed['requests'][0]['adapter_responses'][0]['at_ns'] = 0
reject(changed, 'response-before-request')
changed = copy.deepcopy(complete)
changed['requests'][1]['id'] = changed['requests'][0]['id']
reject(changed, 'request-duplicate')
changed = copy.deepcopy(complete)
changed['requests'][1]['at_ns'] = 3
changed['requests'][2]['at_ns'] = 2
reject(changed, 'request-order')
checks += 3
# Independently invalidate schema type, required/closed fields and numeric,
# string and array bounds. In particular bool is not a JSON integer and the
# string "false" is not capture_complete=false.
for field, bad in (('capture_complete', 'false'), ('synthetic', 1), ('machine_births', True),
                   ('monotonic_duration_ns', 0), ('monotonic_duration_ns', 310000000001),
                   ('format', 'fm-supervision-trace.v2'), ('events', {}), ('start_ns', -1),
                   ('end_ns', 0), ('unknown', 1)):
    changed = copy.deepcopy(complete)
    changed['trace'][field] = bad
    reject(changed, 'trace-' + field)
    checks += 1
for field, bad in (('id', ''), ('id', 'x' * 201), ('kind', 'unknown'), ('at_ns', -1),
                   ('at_ns', 60000000001), ('argv', ['x' * 65537]), ('argv', ['x'] * 4097),
                   ('thread', 'false'), ('parent', 'x' * 201), ('home', 'x' * 65),
                   ('exec_evidence', 'none'), ('unknown', 1)):
    changed = copy.deepcopy(complete)
    changed['trace']['events'][2][field] = bad
    reject(changed, 'event-' + field)
    checks += 1
for label, mutate in (
    ('seed-parent', lambda t: t['events'][0].update(parent='unexpected')),
    ('seed-thread', lambda t: t['events'][0].update(thread=True)),
    ('seed-home', lambda t: t['events'][0].update(home='unknown')),
    ('duplicate-seed', lambda t: t['events'].insert(1, copy.deepcopy(t['events'][0]))),
    ('exec-parent', lambda t: t['events'][2].update(parent='root')),
    ('exec-thread', lambda t: t['events'][2].update(thread=True)),
    ('exec-home', lambda t: t['events'][2].update(home='fixture')),
    ('exec-orphan', lambda t: t['events'][2].update(id='missing')),
    ('birth-argv', lambda t: t['events'][1].update(argv=['fabricated'])),
    ('birth-exe', lambda t: t['events'][1].update(executable='/bin/bash')),
    ('birth-evidence', lambda t: t['events'][1].update(exec_evidence='execve')),
    ('birth-home', lambda t: t['events'][1].update(home='fixture')),
    ('event-order', lambda t: t['events'][2].update(at_ns=0)),
    ('loss-negative', lambda t: t['losses'].update(unknown_parents=-1)),
    ('loss-type', lambda t: t['losses'].update(unknown_parents=False)),
):
    changed = copy.deepcopy(complete)
    mutate(changed['trace'])
    reject(changed, label)
    checks += 1

# Exercise validate-manifest itself, including populated optional inventories.
full_manifest = copy.deepcopy(complete['manifest'])
full_home = full_manifest['homes'][0]
full_home['sources'] = [{'id': 's', 'registration_token': 'token', 'result_sequence': 4,
                         'claim_identity': 'pid:start', 'executor_version': 'legacy'}]
full_home['checks'] = [{'id': 'check', 'binding': 'digest', 'interval_ms': 300000}]
full_home['capture_roots'] = [{'pid': 10, 'start_ticks': '1'}]
full_home['unsupported_integrations'] = ['unsupported']
full_home['tasks'][0].update(park_token='park', custody_phase='retained')
assert json.loads(run('validate-manifest', save('manifest-valid.json', full_manifest)).stdout) == {
    'valid': True, 'certified_complete': False, 'homes': 1}
certified = copy.deepcopy(full_manifest)
certified['certified_complete'] = True
assert json.loads(run('validate-manifest', save('manifest-certified.json', certified)).stdout) == {
    'valid': True, 'certified_complete': True, 'homes': 1}
for field in ('tasks', 'sources', 'checks', 'timers', 'capture_roots'):
    changed = copy.deepcopy(full_manifest)
    changed['homes'][0][field].append(copy.deepcopy(changed['homes'][0][field][0]))
    run('validate-manifest', save('manifest-duplicate-' + field + '.json', changed), good=False)
    checks += 1
for field, bad in (('home', '/fixture/../fixture'), ('code_root', '/fixture/code/'),
                   ('state_root', '/elsewhere/state'), ('state_root', '/fixture-neighbor/state'),
                   ('code_ref', 'g' * 40), ('remote', 'false'), ('published_at', 'unknown'),
                   ('configuration_sha256', '0' * 63), ('timers', []), ('owner', ''),
                   ('state_identity', {'device': 1, 'inode': 0}), ('capture_roots', [{'pid': 0, 'start_ticks': '1'}]),
                   ('capture_roots', [{'pid': 4194305, 'start_ticks': '1'}]),
                   ('capture_roots', [{'pid': 10, 'start_ticks': 'bad'}]),
                   ('unsupported_integrations', ['same', 'same'])):
    changed = copy.deepcopy(full_manifest)
    changed['homes'][0][field] = bad
    run('validate-manifest', save('manifest-bad-' + field + '.json', changed), good=False)
    checks += 1
changed = copy.deepcopy(full_manifest)
changed['homes'][0]['timers'][0]['bound_ms'] = 14999
run('validate-manifest', save('timer-bound.json', changed), good=False)
changed = copy.deepcopy(full_manifest)
changed['enrolled_homes'] = ['fixture', 'fixture']
run('validate-manifest', save('duplicate-enrollment.json', changed), good=False)
changed = copy.deepcopy(full_manifest)
del changed['homes'][0]['state_identity']
run('validate-manifest', save('missing-identity.json', changed), good=False)
checks += 5

# Self-asserted complete/real/certified flags are not provenance or authority.
changed = copy.deepcopy(value)
changed['synthetic'] = changed['trace']['synthetic'] = False
changed['manifest']['certified_complete'] = True
asserted = json.loads(run('replay', save('asserted-real.json', changed)).stdout)
assert not asserted['complete_for_attached_trees'] and asserted['seed_cmdline_hints'] == 1
assert 'b0_eligible' not in asserted and asserted['b0_status'] == 'pending-reviewed-real-capture'
checks += 1

# Input reads are bounded and refuse special files/symlinks without blocking.
link = tmp / 'link.json'
link.symlink_to(tmp / '6.json')
run('replay', link, good=False)
fifo = tmp / 'fifo.json'
os.mkfifo(fifo)
run('replay', fifo, good=False, timeout=2)
run('replay', tmp / 'absent', good=False)
# Otherwise valid input: removing duplicate-key detection must change the verdict.
(tmp / 'duplicate.json').write_text(json.dumps(complete).replace(
    '"capture_complete": true', '"capture_complete": false, "capture_complete": true'))
run('replay', tmp / 'duplicate.json', good=False)
checks += 4

# Import and account only sealed SYNTHETIC records through the public CLI.
manifest = value['manifest']


def imported(name, raw, enrollment=None, seed_argv=None, seed_exe='/bin/bash'):
    capture = tmp / name
    capture.mkdir()
    enrollment = enrollment or manifest
    (capture / 'manifest.json').write_text(json.dumps(enrollment, sort_keys=True, indent=2) + '\n')
    (capture / 'strace.log').write_text(raw)
    (capture / 'strace.stderr').write_bytes(b'')
    metadata = {'format': 'fm-supervision-capture.v1', 'complete': True,
                'seeds': [{'pid': 10, 'start_ticks': '1', 'executable': seed_exe,
                           'exec_evidence': 'proc-exe-cmdline',
                           'argv': seed_argv or ['bash', '/fixture/code/bin/fm-fleet-snapshot.sh'],
                           'home': 'fixture'}],
                'before': {'wall_ns': 1000000000, 'monotonic_ns': 1, 'machine_births': 100},
                'after': {'wall_ns': 2000000000, 'monotonic_ns': 1000000001, 'machine_births': 105},
                'raw_sha256': hashlib.sha256(raw.encode()).hexdigest(),
                'stderr_sha256': hashlib.sha256(b'').hexdigest(),
                'manifest_sha256': hashlib.sha256((capture / 'manifest.json').read_bytes()).hexdigest()}
    (capture / 'finished.json').write_text(json.dumps(metadata))
    trace = json.loads(run('import-strace', capture).stdout)
    report = json.loads(run('account', save(name + '-trace.json', trace),
                            '--manifest', capture / 'manifest.json').stdout)
    return trace, report, capture


raw = ('10 1.000000 vfork(<unfinished ...>\n'
       '11 1.010000 execve("/bin/bash", ["bash", "/fixture/code/bin/fm-crew-state.sh", "task-0"], 0x1 /* env */) = 0\n'
       '10 1.020000 <... vfork resumed>) = 11\n'
       '11 1.030000 clone(child_stack=NULL, flags=SIGCHLD) = 12\n'
       '12 1.040000 execve("/bin/date", ["date"], 0x1 /* env */) = 0\n'
       '12 1.050000 +++ exited with 0 +++\n'
       '11 1.060000 clone(child_stack=NULL, flags=SIGCHLD) = -1 EAGAIN (unavailable)\n')
trace, report, capture = imported('import', raw)
assert trace['losses']['unknown_parents'] == 0 and trace['losses']['unknown_lines'] == 0
assert trace['losses']['attachment_gaps'] == 1
assert report['exclusive_births']['crew-state'] == 2 and report['residual'] == 3
assert not report['complete_for_attached_trees']  # startup gaps are explicit
# Mutating the trace bytes must refuse rather than silently reinterpret them.
(capture / 'strace.log').write_text(raw + 'bad\n')
run('import-strace', capture, good=False)
checks += 2

# F2: kernel executable evidence, not argv[0], identifies direct entries.
script = '/fixture/code/bin/fm-spawn.sh'
for index, (executable, argv, expected) in enumerate((
    ('/bin/echo', [script, 'hello'], False),
    ('/bin/echo', ['bash', script, 'task-0'], False),
    ('/other/bash', ['bash', script, 'task-0'], False),
    ('/bin/bash', ['arbitrary-argv0', script, 'task-0'], True),
    ('/usr/bin/bash', ['bash', '-ex', '--', script, 'task-0'], True),
    ('/bin/sh', ['sh', '--', script, 'task-0'], True),
    ('/bin/bash', ['bash', '-c', script, 'task-0'], False),
    ('/bin/bash', ['bash', '-s', script, 'task-0'], False),
    ('/bin/bash', ['bash', '--rcfile', script, 'task-0'], False),
    (script, ['alternate-argv0', 'task-0'], True),
)):
    for syscall in ('execve', 'execveat'):
        args = json.dumps(executable) + ', ' + json.dumps(argv) + ', 0x1 /* env */'
        if syscall == 'execveat':
            args = 'AT_FDCWD, ' + args + ', 0'
        raw = ('10 1.000001 clone(flags=SIGCHLD) = 11\n'
               '11 1.000002 ' + syscall + '(' + args + ') = 0\n')
        trace, report, _ = imported('exec-' + syscall + '-' + str(index), raw,
                                    seed_argv=['bash', '/fixture/code/bin/fm-watch.sh'])
        event = trace['events'][-1]
        assert event['executable'] == executable and event['exec_evidence'] == syscall
        assert event['argv'] == argv and trace['losses']['unresolved_argv'] == 0
        assert report['entry_counts']['spawn'] == int(expected), report
        assert report['exclusive_births']['spawn'] == int(expected)
        assert report['exclusive_births']['watch'] == int(not expected)
        assert report['observed_births'] == 1 and report['seed_cmdline_hints'] == 1
        if expected:
            assert report['entries'][0]['target'] == 'task-0'
            assert report['entries'][0]['exec_evidence'] == syscall
        checks += 1

# Relative and fd-only identities cannot be upgraded from a forged argv[0].
for index, executable in enumerate(('', 'fm-spawn.sh')):
    raw = ('10 1.000001 fork() = 11\n11 1.000002 execveat(3, '
           + json.dumps(executable) + ', ["/fixture/code/bin/fm-spawn.sh", "task-0"], '
           '0x1 /* env */, AT_EMPTY_PATH) = 0\n')
    trace, report, _ = imported('unresolved-exec-' + str(index), raw)
    assert trace['losses']['unresolved_argv'] == 1
    assert trace['events'][-1]['executable'] == executable
    assert report['entry_counts']['spawn'] == 0 and not report['complete_for_attached_trees']
    checks += 1

# F3: original entry ordinals preserve causality even at tied timestamps.
# Cover vfork and both clone spellings, with a second nested unfinished call.
for index, (call, operands) in enumerate((('vfork', ''), ('clone', 'flags=SIGCHLD'),
                                        ('clone3', '{flags=SIGCHLD}, 88'))):
    for tied in (True, False):
        t_child, t_resume = ('1.000001', '1.000001') if tied else ('1.000002', '1.000003')
        raw = ('10 1.000001 ' + call + '(' + operands + '<unfinished ...>\n'
               '11 ' + t_child + ' execve("/bin/bash", ["bash", "/fixture/code/bin/fm-crew-state.sh", "task-0"], 0x1 /* env */) = 0\n'
               '10 ' + t_resume + ' <... ' + call + ' resumed>) = 11\n'
               '11 1.000004 ' + call + '(' + operands + '<unfinished ...>\n'
               '12 1.000004 execve("/bin/date", ["date"], 0x1 /* env */) = 0\n'
               '11 1.000004 <... ' + call + ' resumed>) = 12\n')
        trace, report, _ = imported('tied-' + str(index) + '-' + str(tied), raw)
        assert trace['losses']['unknown_parents'] == 0 and trace['losses']['unfinished_calls'] == 0
        assert trace['losses']['unknown_lines'] == 0
        assert [e['kind'] for e in trace['events']] == ['seed', 'birth', 'exec', 'birth', 'exec']
        assert report['entry_counts']['crew-state'] == 1
        assert report['exclusive_births']['crew-state'] == 2
        assert report['observed_births'] == 2 and report['residual'] == 3
        checks += 1
# Genuine orphan exec is still a declared loss, not a fabricated child.
trace, report, _ = imported('orphan-exec', '11 1.000001 execve("/bin/date", ["date"], 0x1 /* env */) = 0\n')
assert trace['losses']['unknown_parents'] == 1 and report['entries'] == []
assert report['observed_births'] == 0
checks += 1

# F5: executable-path brackets and quoted/escaped UTF-8 bytes cannot become
# the argv delimiter. Non-entry paths remain non-entries (negative control).
def c_quote(text):
    return '"' + ''.join('\\%03o' % b if b >= 128 else '\\' + chr(b) if b in (34, 92)
                         else chr(b) for b in text.encode('utf-8')) + '"'


for index, code_root in enumerate(('/fixture/[code]', '/fixture/quote"back\\slash', '/fixture/ää')):
    enrollment = copy.deepcopy(manifest)
    enrollment['homes'][0]['code_root'] = code_root
    for direct in (True, False):
        executable = code_root + '/bin/fm-spawn.sh' if direct else code_root + '/bin/echo'
        raw = ('10 1.000001 fork() = 11\n11 1.000002 execve(' + c_quote(executable) + ', ['
               + c_quote(code_root + '/bin/fm-spawn.sh') + ', "task-0"], 0x1 /* env */) = 0\n')
        trace, report, _ = imported('path-' + str(index) + '-' + str(direct), raw, enrollment)
        assert trace['events'][-1]['executable'] == executable
        assert trace['losses']['unresolved_argv'] == 0 and trace['losses']['unknown_lines'] == 0
        assert report['entry_counts']['spawn'] == int(direct)
        checks += 1

# F6: exact imported losses and identities, not merely incomplete=true.
# These never invoke strace; all files are sealed synthetic input.
loss_cases = (
    ('unknown', 'not strace\n', 'unknown_lines', 1),
    ('unknown-call', '10 1.000001 mystery() = 0\n', 'unknown_lines', 1),
    ('malformed-call', '10 1.000001 clone(unterminated\n', 'unknown_lines', 1),
    ('pending', '10 1.000001 vfork(<unfinished ...>\n', 'unfinished_calls', 1),
    ('resume-without-entry', '10 1.000001 <... vfork resumed>) = 11\n', 'unfinished_calls', 1),
    ('pending-replaced', '10 1.000001 fork(<unfinished ...>\n10 1.000002 fork(<unfinished ...>\n', 'unfinished_calls', 2),
    ('orphan-parent', '99 1.000001 fork() = 11\n', 'unknown_parents', 1),
    ('truncated-argv', '10 1.000001 fork() = 11\n11 1.000002 execve("/bin/bash", ["bash", ...], 0x1) = 0\n', 'unresolved_argv', 1),
    ('nul-argv', '10 1.000001 fork() = 11\n11 1.000002 execve("/bin/bash", ["ba\\000sh"], 0x1) = 0\n', 'unresolved_argv', 1),
    ('invalid-escape', '10 1.000001 fork() = 11\n11 1.000002 execve("/bin/bash", ["ba\\qsh"], 0x1) = 0\n', 'unresolved_argv', 1),
)
for name, raw, loss, expected in loss_cases:
    trace, report, _ = imported('loss-import-' + name, raw)
    expected_losses = dict.fromkeys(trace['losses'], 0)
    expected_losses.update(attachment_gaps=1)
    expected_losses[loss] = expected
    assert trace['losses'] == expected_losses, (name, trace)
    assert report['losses'] == expected_losses and not report['complete_for_attached_trees']
    assert report['entry_counts'] == dict.fromkeys(report['entry_counts'], 0)
    assert report['observed_births'] == int(name in ('orphan-parent', 'truncated-argv', 'nul-argv', 'invalid-escape'))
    checks += 1
raw = ('10 1.000001 clone(flags=CLONE_VM|CLONE_THREAD) = 11\n'
       '[pid 11] 1.000002 execve("/bin/date", ["date"], 0x1) = -1 ENOENT (missing)\n'
       '11 1.000003 +++ killed by SIGKILL +++\n'
       '10 1.000004 fork() = 11\n'
       '11 1.000005 execve("/bin/bash", ["bash", "/fixture/code/bin/fm-crew-state.sh", "task-0"], 0x1) = 0\n'
       '11 1.000006 +++ exited with 0 +++\n'
       '10 1.000007 fork() = -1 EAGAIN (unavailable)\n'
       '10 1.000008 wait4(-1, [], WNOHANG, NULL) = 0\n'
       '10 1.000009 waitid(P_ALL, 0, {}, WEXITED, NULL) = 0\n'
       '10 1.000010 --- SIGCHLD {si_signo=SIGCHLD} ---\n'
       '10 1.000011 exit_group(0) = ?\n')
trace, report, capture = imported('pid-reuse', raw)
births = [e for e in trace['events'] if e['kind'] == 'birth']
assert [e['id'] for e in births] == ['11:1000001000:1', '11:1000004000:4']
assert births[0]['thread'] and not births[1]['thread']
assert all(e['parent'] == 'seed:10:1' for e in births)
assert trace['losses'] == dict.fromkeys(trace['losses'], 0) | {'attachment_gaps': 1}
assert report['observed_births'] == 2 and report['thread_births_included'] == 1
assert report['exclusive_births']['fleet-snapshot'] == 1 and report['exclusive_births']['crew-state'] == 1
assert report['births_per_second'] == 2 and report['residual'] == 3
assert report['entry_counts']['crew-state'] == 1
# Missed exit still creates a new generation but explicitly declares loss.
trace, report, _ = imported('pid-reuse-missed-exit', raw.replace('11 1.000003 +++ killed by SIGKILL +++\n', ''))
assert trace['losses']['unknown_lines'] == 1 and report['observed_births'] == 2
checks += 2
# Each seal independently protects otherwise-valid evidence. Preserve and
# restore the bytes between probes so rejection cannot have the wrong cause.
for filename, bad_bytes in (('strace.log', b'changed'), ('strace.stderr', b'changed'),
                            ('manifest.json', (json.dumps(full_manifest)).encode())):
    target = capture / filename
    original = target.read_bytes()
    target.write_bytes(bad_bytes)
    refused = run('import-strace', capture, good=False)
    assert b'digest mismatch' in refused.stderr or b'manifest changed' in refused.stderr
    target.write_bytes(original)
    assert json.loads(run('import-strace', capture).stdout)['losses']['attachment_gaps'] == 1
    checks += 1
metadata_path = capture / 'finished.json'
metadata_original = metadata_path.read_bytes()
for field, bad in (('format', 'fm-supervision-capture.v2'), ('complete', 'false')):
    metadata = json.loads(metadata_original)
    metadata[field] = bad
    metadata_path.write_text(json.dumps(metadata))
    run('import-strace', capture, good=False)
metadata_path.write_bytes(metadata_original)
raw_path = capture / 'strace.log'
raw_original = raw_path.read_bytes()
raw_path.write_bytes(b'\xff')
metadata = json.loads(metadata_original)
metadata['raw_sha256'] = hashlib.sha256(b'\xff').hexdigest()
metadata_path.write_text(json.dumps(metadata))
run('import-strace', capture, good=False)
raw_path.write_bytes(raw_original)
metadata_path.write_bytes(metadata_original)
checks += 3

# Read-only probe never claims a successful attachment or permission proof.
probe = json.loads(run('probe').stdout)
assert probe['attach_attempted'] is False and probe['permission_proven'] is False
checks += 1

# Portable guard integration: shared disable/opt-in semantics must run before
# the dedicated capture authorization and before any tool or input checks.
for family_setting, capture_setting, expected in (
    (None, None, b'skip: live: opt-in; set FM_SUPERVISION_CAPTURE_LIVE=1 to run'),
    ('0', None, b'skip: live: disabled by FM_LIVE=0'),
    ('1', None, b'skip: live capture disabled'),
    ('1', '0', b'skip: live: disabled by FM_SUPERVISION_CAPTURE_LIVE=0'),
):
    guard_env = dict(os.environ)
    for key, setting in (('FM_LIVE', family_setting), ('FM_SUPERVISION_CAPTURE_LIVE', capture_setting)):
        guard_env.pop(key, None)
        if setting is not None:
            guard_env[key] = setting
    guard = subprocess.run(['bash', str(root / 'tests/fm-supervision-accounting-live.test.sh')],
                           env=guard_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
    assert guard.returncode == 0 and expected in guard.stdout, (guard.returncode, guard.stdout, guard.stderr)
    checks += 1

# Linux capture bounds with a fake tracer, never ptrace. The published root is
# this test process, and must remain alive and unsignalled after every case.
if sys.platform == 'linux' and hasattr(os, 'pidfd_open'):
    fakebin = tmp / 'fakebin'
    fakebin.mkdir()
    tool = fakebin / 'strace'
    env = dict(os.environ, PATH=str(fakebin), FM_SUPERVISION_CAPTURE_LIVE='1')
    fields = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()
    local = copy.deepcopy(manifest)
    local['homes'][0]['capture_roots'] = [{'pid': os.getpid(), 'start_ticks': fields[19]}]
    local_path = save('capture-manifest.json', local)
    def write_tracer(body):
        # Refuse a broadened or incomplete attach argv, including omission of
        # any admitted -p root. No real tracer or target inspection is used.
        tool.write_text('#!' + sys.executable + '\nimport json,os,pathlib,signal,sys\n'
                        'p=sys.argv[sys.argv.index("-o")+1]\n'
                        'expected=["-f","-qq","-ttt","-s","4096","-e","trace=process","-o",p,"-p",'
                        + repr(str(os.getpid())) + ']\n'
                        'assert sys.argv[1:]==expected,sys.argv\n'
                        'assert pathlib.Path(p).name=="strace.log"\n'
                        'pathlib.Path(p).with_name("tracer-argv.json").write_text(json.dumps(sys.argv))\n'
                        + body)
        tool.chmod(0o700)

    write_tracer('open(p,"w").write("synthetic tracer bytes\\n")\n'
                 'signal.signal(signal.SIGINT,lambda *_:sys.exit(0))\nsignal.pause()\n')
    start = time.monotonic()
    result = run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
                 '--output', tmp / 'bounded', '--acknowledge-ptrace', env=env)
    assert json.loads(result.stdout)['complete']
    assert time.monotonic() - start < 15
    os.kill(os.getpid(), 0)
    done = json.loads((tmp / 'bounded/finished.json').read_text())
    assert done['after']['machine_births'] >= done['before']['machine_births']
    assert done['after']['monotonic_ns'] > done['before']['monotonic_ns']
    bounded = tmp / 'bounded'
    assert bounded.stat().st_mode & 0o077 == 0
    for filename in ('manifest.json', 'strace.log', 'strace.stderr', 'started.json', 'finished.json'):
        assert (bounded / filename).stat().st_mode & 0o077 == 0, filename
    assert done['complete'] and done['tracer_rc'] == 0
    assert done['command'] == json.loads((bounded / 'tracer-argv.json').read_text())
    assert done['duration_bound_s'] == 1 and done['byte_bound'] == 67108864
    assert done['raw_sha256'] == hashlib.sha256((bounded / 'strace.log').read_bytes()).hexdigest()
    assert done['stderr_sha256'] == hashlib.sha256((bounded / 'strace.stderr').read_bytes()).hexdigest()
    assert done['manifest_sha256'] == hashlib.sha256((bounded / 'manifest.json').read_bytes()).hexdigest()
    assert done['seeds'] == [{'pid': os.getpid(), 'start_ticks': fields[19],
                              'argv': [v.decode('utf-8', 'surrogateescape') for v in
                                       Path('/proc/self/cmdline').read_bytes().rstrip(b'\0').split(b'\0')],
                              'executable': os.readlink('/proc/self/exe'),
                              'exec_evidence': 'proc-exe-cmdline', 'home': 'fixture'}]
    for boundary_name in ('before', 'after'):
        row = done[boundary_name]
        assert row['wall_ns'] <= row['counter_sample_end_wall_ns']
        assert row['cpu_ticks'] and all(type(n) is int and n >= 0 for n in row['cpu_ticks'])
        assert row['loadavg'] and row['monotonic_ns'] > 0 and row['machine_births'] > 0
    assert set(done['usage']) == {'collector_user_s', 'collector_system_s', 'tracer_user_s',
                                   'tracer_system_s', 'tracer_peak_rss_kib'}
    assert all(n >= 0 for n in done['usage'].values()) and done['usage']['tracer_peak_rss_kib'] > 0
    started = json.loads((bounded / 'started.json').read_text())
    assert not started['complete'] and started['before'] == done['before']
    assert started['command'] == done['command'] and started['seeds'] == done['seeds']
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--output', tmp / 'no-ack', good=False, env=env)
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 301,
        '--output', tmp / 'too-long', '--acknowledge-ptrace', good=False, env=env)
    local['homes'][0]['capture_roots'][0]['start_ticks'] = '0'
    bad = save('bad-identity.json', local)
    run('capture', '--manifest', bad, '--home', 'fixture', '--seconds', 1,
        '--output', tmp / 'bad-id', '--acknowledge-ptrace', good=False, env=env)
    no_live = dict(env)
    no_live.pop('FM_SUPERVISION_CAPTURE_LIVE', None)
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--output', tmp / 'no-live', '--acknowledge-ptrace', good=False, env=no_live)
    assert not (tmp / 'no-live').exists()
    for label, home_patch in (('remote', {'remote': True}), ('no-roots', {'capture_roots': []})):
        changed = copy.deepcopy(local)
        changed['homes'][0].update(home_patch)
        output = tmp / ('refused-' + label)
        run('capture', '--manifest', save(label + '.json', changed), '--home', 'fixture',
            '--seconds', 1, '--output', output, '--acknowledge-ptrace', good=False, env=env)
        assert not output.exists()
    for label, overrides, capture_env in (
        ('home', ['--home', 'not-enrolled'], env),
        ('zero-seconds', ['--seconds', '0'], env),
        ('small-cap', ['--max-bytes', '4095'], env),
        ('large-cap', ['--max-bytes', '67108865'], env),
        ('no-tool', [], dict(env, PATH=str(tmp / 'not-a-tool-dir'))),
        ('invalid-enable', [], dict(env, FM_SUPERVISION_CAPTURE_LIVE='2')),
    ):
        output = tmp / ('refused-' + label)
        run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
            '--output', output, '--acknowledge-ptrace', *overrides, good=False, env=capture_env)
        assert not output.exists()
    prior = {p.name: p.read_bytes() for p in bounded.iterdir()}
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--output', bounded, '--acknowledge-ptrace', good=False, env=env)
    assert prior == {p.name: p.read_bytes() for p in bounded.iterdir()}
    # Empty stderr is load-bearing even on an exit-0 tracer. Every refused
    # capture retains seals, status and private input/output for diagnosis.
    for label, body, expected_rc in (
        ('stderr', 'open(p,"w").write("partial")\nsys.stderr.write("attach denied\\n")\n', 0),
        ('bad-exit', 'open(p,"w").write("partial")\nsys.exit(13)\n', 13),
        ('wrong-scope', 'expected.append("unexpected")\nassert sys.argv[1:]==expected\n', 1),
    ):
        write_tracer(body)
        output = tmp / label
        run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
            '--output', output, '--acknowledge-ptrace', good=False, env=env)
        refused = json.loads((output / 'finished.json').read_text())
        assert not refused['complete'] and refused['tracer_rc'] == expected_rc
        assert refused['raw_sha256'] == hashlib.sha256((output / 'strace.log').read_bytes()).hexdigest()
        assert refused['stderr_sha256'] == hashlib.sha256((output / 'strace.stderr').read_bytes()).hexdigest()
        if label in ('stderr', 'wrong-scope'):
            assert (output / 'strace.stderr').read_bytes()
        assert (output / 'started.json').exists() and output.stat().st_mode & 0o077 == 0
    # Real signal delivery through the public CLI: the fake tracer is the only
    # child, and the admitted root is this test process (never signalled).
    for sig in (signal.SIGTERM, signal.SIGHUP):
        marker = tmp / ('ready-' + str(sig))
        signal_output = tmp / ('interrupted-' + str(sig))
        signal_env = dict(env, FM_FAKE_TRACER_READY=str(marker))
        write_tracer('open(p,"w").close()\nsignal.signal(signal.SIGINT,lambda *_:sys.exit(0))\n'
                     'open(os.environ["FM_FAKE_TRACER_READY"],"w").write(str(os.getpid()))\nsignal.pause()\n')
        collector = subprocess.Popen([sys.executable, str(cli), 'capture', '--manifest', str(local_path),
                                      '--home', 'fixture', '--seconds', '30', '--output', str(signal_output),
                                      '--acknowledge-ptrace'], env=signal_env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not marker.exists() and collector.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            assert marker.exists(), 'fake tracer did not become ready'
            collector.send_signal(sig)
            stdout, stderr = collector.communicate(timeout=6)
            assert collector.returncode == 2, (stdout, stderr)
            assert b'refused: interrupted' in stderr and b'Traceback' not in stderr
            assert not json.loads((signal_output / 'finished.json').read_text())['complete']
            try:
                os.kill(int(marker.read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('interrupted collector left its tracer alive')
            os.kill(os.getpid(), 0)
        finally:
            if collector.poll() is None:
                collector.kill()
                collector.communicate(timeout=6)
    # A tracer ignoring SIGINT still cannot extend the recording indefinitely.
    write_tracer('open(p,"w").close()\nsignal.signal(signal.SIGINT,signal.SIG_IGN)\nsignal.pause()\n')
    start = time.monotonic()
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--output', tmp / 'hung', '--acknowledge-ptrace', good=False, env=env)
    assert time.monotonic() - start < 20
    assert not json.loads((tmp / 'hung/finished.json').read_text())['complete']
    os.kill(os.getpid(), 0)
    # Output overflow is a retained incomplete capture, not a false clean trace.
    write_tracer('open(p,"wb").write(b"x"*8192)\n')
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--max-bytes', 4096, '--output', tmp / 'overflow', '--acknowledge-ptrace', good=False, env=env)
    assert (tmp / 'overflow/strace.log').stat().st_size <= 4096
    assert not json.loads((tmp / 'overflow/finished.json').read_text())['complete']
    checks += 22
# Proc route: exact machine denominator, deliberately incomplete attribution.
# Snapshot data is synthetic; neither fixtures nor cmdline hints certify B0.
proc_manifest = copy.deepcopy(manifest)
proc_manifest['homes'][0]['capture_roots'] = [{'pid': 10, 'start_ticks': '1'}]
other = copy.deepcopy(proc_manifest['homes'][0])
other.update(id='other', home='/other', state_root='/other/state',
             capture_roots=[{'pid': 20, 'start_ticks': '2'}])
# Shared code root must never imply shared home identity.
proc_manifest['homes'].append(other)
proc_manifest['enrolled_homes'].append('other')


def task(pid, parent, start, user=0, system=0, script='fm-watch.sh'):
    return dict(pid=pid, ppid=parent, start_ticks=start, user_ticks=user,
                system_ticks=system, executable='/bin/bash',
                argv=['bash', '/fixture/code/bin/' + script], hint_unavailable=False)


def snap(at, births, cpu, tasks):
    return dict(boundary=dict(monotonic_ns=at * 1000000000, wall_ns=at * 1000000000,
                              machine_births=births, cpu_ticks=cpu,
                              uptime_lower_ticks=at * 100, uptime_upper_ticks=at * 100 + 2,
                              boot_id='00000000-0000-0000-0000-000000000000'),
                tasks=tasks, unreadable=0, vanished=0, scan_ns=100)


proc_value = dict(format='fm-supervision-proc.v1', synthetic=True, manifest=proc_manifest,
                  clock_ticks=100, snapshots=[
    snap(10, 100, [100, 0, 100, 100, 0, 0, 0, 0, 40, 0],
         [task(10, 1, 1, 10, 5), task(20, 1, 2, 4, 2)]),
    snap(11, 110, [120, 0, 110, 100, 0, 0, 0, 0, 50, 0],
         [task(10, 1, 1, 14, 7), task(20, 1, 2, 6, 3),
          task(11, 10, 1050, 2, 1, 'fm-crew-state.sh'),
          task(21, 20, 1051, 0, 0, 'fm-wake-drain.sh'),
          task(30, 1, 1001)]),  # uncertain boundary jiffy, not counted as a birth
    snap(12, 120, [140, 0, 120, 100, 0, 0, 0, 0, 60, 0],
         [task(10, 1, 1, 17, 8), task(20, 1, 2, 8, 4),
          task(11, 10, 1050, 5, 2, 'fm-crew-state.sh'),
          task(21, 20, 1051, 1, 0, 'fm-wake-drain.sh'),
          task(30, 1, 1001), task(31, 1, 1150)])])


def proc_report(v, label='proc'):
    return json.loads(run('account-proc', save(label + '.json', v)).stdout)


p = proc_report(proc_value)
assert p['machine'] == dict(births=20, births_per_second=10.0, busy_cpu_ticks=60,
                            busy_cpu_one_core_percent=30.0)
assert p['observed'] == dict(process_births_lower_bound=3, user_ticks=15,
                             system_ticks=6, cpu_one_core_percent_lower_bound=10.5)
assert p['residual'] == dict(births_not_observed=17, busy_cpu_ticks_not_observed=39)
assert p['exclusive_measured_supervision_by_home_family'] is None
assert p['b0_status'] == 'incomplete-unprivileged-attribution'
assert p['claimed_births_per_second_saved'] == 0
rows = {(r['home'], r['family']): r for r in p['provisional_not_measured_attribution']}
assert rows['fixture', 'crew-state']['observed_process_births'] == 1
assert rows['other', 'wake-drain']['observed_process_births'] == 1
assert rows['unattributed', 'unattributed']['observed_process_births'] == 1
assert rows['fixture', 'watch']['user_ticks'] == 7
assert sum(r['observed_process_births'] for r in rows.values()) == 3
assert sum(r['user_ticks'] + r['system_ticks'] for r in rows.values()) == 21
assert p['losses']['single_sample_identities'] == 1
assert p['startup_coverage']['existing_identities_observed'] == 3
assert p['synthetic']
checks += 1

# Every family is merely a mutable-cmdline/ancestry hint, never entry evidence.
for family in ('crew-state', 'watch', 'wake-drain', 'fleet-snapshot', 'spawn', 'control'):
    changed = copy.deepcopy(proc_value)
    for s in changed['snapshots'][1:]:
        s['tasks'][2]['argv'][1] = '/fixture/code/bin/fm-' + family + '.sh'
    result = proc_report(changed, 'proc-' + family)
    assert any(r['home'] == 'fixture' and r['family'] == family
               and r['observed_process_births'] >= 1
               for r in result['provisional_not_measured_attribution'])
    assert result['exclusive_measured_supervision_by_home_family'] is None
    checks += 1

# PID reuse is a new identity, not a negative CPU delta or inherited ancestry.
changed = copy.deepcopy(proc_value)
changed['snapshots'][-1]['tasks'][2] = task(11, 1, 1155)
result = proc_report(changed, 'proc-reuse')
assert result['observed']['process_births_lower_bound'] == 4
assert result['observed']['user_ticks'] == 12
# A later exec/reparent must not transfer earlier work to its new family.
changed = copy.deepcopy(proc_value)
changed['snapshots'][-1]['tasks'][2]['argv'][1] = '/fixture/code/bin/fm-control.sh'
result = proc_report(changed, 'proc-reexec')
assert result['losses']['observed_hint_changes'] == 1
assert not any(r['family'] == 'control' and r['user_ticks']
               for r in result['provisional_not_measured_attribution'])
# A gap/failed read never turns unknown into zero loss or full attribution.
changed = copy.deepcopy(proc_value)
changed['snapshots'][1].update(unreadable=3, vanished=2)
changed['snapshots'][1]['tasks'][2].update(argv=[], executable='', hint_unavailable=True)
result = proc_report(changed, 'proc-loss')
assert result['losses']['unreadable_pid_samples'] == 3
assert result['losses']['vanished_pid_samples'] == 2
assert result['losses']['unavailable_hint_samples'] == 1
changed = copy.deepcopy(proc_value)
changed['snapshots'][-1]['boundary']['machine_births'] = 101
changed['snapshots'][1]['boundary']['machine_births'] = 101
changed['snapshots'][-1]['boundary']['cpu_ticks'] = changed['snapshots'][0]['boundary']['cpu_ticks']
result = proc_report(changed, 'proc-contradiction')
assert result['residual'] == dict(births_not_observed=-2, busy_cpu_ticks_not_observed=-21)
checks += 4

for label, mutate in (
    ('boot', lambda v: v['snapshots'][-1]['boundary'].update(boot_id='f' * 36)),
    ('clock', lambda v: v['snapshots'][-1]['boundary'].update(monotonic_ns=1)),
    ('counter', lambda v: v['snapshots'][-1]['boundary'].update(machine_births=99)),
    ('cpu', lambda v: v['snapshots'][-1]['tasks'][0].update(user_ticks=1)),
    ('duplicate', lambda v: v['snapshots'][0]['tasks'].append(v['snapshots'][0]['tasks'][0])),
    ('remote', lambda v: v['manifest']['homes'][0].update(remote=True)),
    ('machine', lambda v: v['manifest']['homes'][0].update(machine='elsewhere')),
    ('shared-root', lambda v: v['manifest']['homes'][1].update(capture_roots=[{'pid': 10, 'start_ticks': '1'}])),
    ('extra', lambda v: v.update(estimate=1)),
    ('type', lambda v: v.update(clock_ticks=True)),
    ('bound', lambda v: v['snapshots'][-1]['boundary'].update(monotonic_ns=400000000000)),
):
    changed = copy.deepcopy(proc_value)
    mutate(changed)
    run('account-proc', save('proc-bad-' + label + '.json', changed), good=False)
    checks += 1

# Authorized fixture-only seam: the real whole-run alarm and the same scan
# deadline/task-cap guards as live capture. Each starts from a successful
# fixture, changes ONE guard input and requires that guard's exact refusal.
# Removing its guard would instead produce exit 0 and fail the assertion.
bounds = dict(format='fm-supervision-proc-bounds-fixture.v1', synthetic=True,
              deadline_ms=1000, pause_ms=0, scan_deadline_ms=100, clock_ms=10,
              task_limit=2, pids=[1, 2])
bounds_path = save('proc-bounds-valid.json', bounds)
assert json.loads(run('check-proc-fixture', bounds_path).stdout) == dict(synthetic=True, tasks_read=2)
for label, updates, diagnostic in (
    ('alarm', dict(deadline_ms=10, pause_ms=200), b'proc total deadline exceeded'),
    ('scan-deadline', dict(clock_ms=100), b'proc scan exceeded duration bound'),
    ('task-cap', dict(task_limit=1), b'proc task cap exceeded'),
):
    changed = dict(bounds, **updates)
    refusal = run('check-proc-fixture', save('proc-bounds-' + label + '.json', changed), good=False)
    assert diagnostic in refusal.stderr, refusal.stderr
    checks += 1
for label, updates in (
    ('not-synthetic', dict(synthetic=False)),
    ('privileged-route', dict(proc_root='/proc')),
    ('pause-bound', dict(pause_ms=201)),
    ('alarm-bound', dict(deadline_ms=0)),
    ('scan-bound', dict(scan_deadline_ms=0)),
    ('cap-bound', dict(task_limit=32768)),
):
    run('check-proc-fixture', save('proc-bounds-bad-' + label + '.json', dict(bounds, **updates)), good=False)
    checks += 1
# The synthetic probe format is not a live manifest or a raw proc capture.
run('account-proc', bounds_path, good=False)
checks += 1

# Public collector integration in CI only: read the already running test
# process, not a launched workload. No ptrace tool or permission is needed.
# A root CI container exercises the root refusal rather than claiming coverage.
if sys.platform == 'linux':
    env_proc = dict(os.environ, FM_SUPERVISION_PROC_LIVE='1')
    local = copy.deepcopy(manifest)
    fields = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()
    local['homes'][0]['capture_roots'] = [{'pid': os.getpid(), 'start_ticks': fields[19]}]
    local_path = save('proc-live-ci-manifest.json', local)
    caps = next(line.split()[1] for line in Path('/proc/self/status').read_text().splitlines()
                if line.startswith('CapEff:'))
    privileged = os.geteuid() == 0 or int(caps, 16) != 0
    output = tmp / 'proc-bounded-ci'
    start = time.monotonic()
    result = run('capture-proc', '--manifest', local_path, '--seconds', 1, '--output', output,
                 env=env_proc, good=not privileged, timeout=12)
    assert time.monotonic() - start < 10
    if not privileged:
        recorded = json.loads((output / 'proc.json').read_bytes())
        report = json.loads((output / 'report.json').read_bytes())
        assert not recorded['synthetic'] and len(recorded['snapshots']) >= 2
        assert report == proc_report(recorded, 'proc-ci-replay')
        assert json.loads(result.stdout)['total_bytes'] == sum(p.stat().st_size for p in output.iterdir())
        assert json.loads(result.stdout)['total_bytes'] < 8 * 1024 * 1024
        for pth in [output, *output.iterdir()]:
            assert pth.stat().st_mode & 0o077 == 0
        for label, extra, environment in (
            ('no-live', [], dict(env_proc, FM_SUPERVISION_PROC_LIVE='0')),
            ('duration', ['--seconds', '301'], env_proc),
            ('interval', ['--interval-ms', '999'], env_proc),
            ('cap', ['--max-bytes', '67108865'], env_proc),
            ('overflow', ['--max-bytes', '4096'], env_proc),
        ):
            run('capture-proc', '--manifest', local_path, '--seconds', 1,
                '--output', tmp / ('proc-refuse-' + label), *extra, env=environment, good=False)
        old = {p.name: p.read_bytes() for p in output.iterdir()}
        run('capture-proc', '--manifest', local_path, '--seconds', 1,
            '--output', output, env=env_proc, good=False)
        assert old == {p.name: p.read_bytes() for p in output.iterdir()}
        run('capture-proc', '--manifest', bounds_path, '--seconds', 1,
            '--output', tmp / 'proc-reject-fixture-format', env=env_proc, good=False)
        injected_manifest = copy.deepcopy(local)
        injected_manifest['fixture'] = bounds
        run('capture-proc', '--manifest', save('proc-injected-manifest.json', injected_manifest),
            '--seconds', 1, '--output', tmp / 'proc-reject-injected-manifest', env=env_proc, good=False)
        local['homes'][0]['capture_roots'][0]['start_ticks'] = '0'
        run('capture-proc', '--manifest', save('proc-stale.json', local), '--seconds', 1,
            '--output', tmp / 'proc-stale-root', env=env_proc, good=False)
    else:
        assert not output.exists()
    # There is no flag to request sudo, ptrace, perf, BPF or arbitrary commands.
    for flag in ('--sudo', '--ptrace', '--perf', '--bpf', '--command', '--fixture',
                 '--proc-root', '--clock-ms', '--task-limit', '--deadline-ms'):
        refused = subprocess.run([sys.executable, str(cli), 'capture-proc', '--manifest', str(local_path),
                                  '--seconds', '1', '--output', str(tmp / 'privileged'), flag],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
        assert refused.returncode == 2 and b'unrecognized arguments' in refused.stderr
    checks += 8
print('ok - public P0 accounting, sealed byte reads, attribution and bounds: ' + str(checks) + ' cases')
PY
rc=$?
[ "$rc" -eq 0 ] || fail "accounting public-interface tests failed ($rc)"

# Exercise the bridge from its actual legacy library, with no active reader or
# background process. Disabled and unsupported paths may not read their record.
# Production modules have their own canonical source-aware lint roots.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"
printf '%s\n' fm-supervision-readers.v1 legacy-pid-cycle.v1 legacy-epoch-check.v1 > "$TMP/expected-capabilities"
fm_supervision_reader_capabilities > "$TMP/actual-capabilities"
cmp -s "$TMP/expected-capabilities" "$TMP/actual-capabilities" || fail 'capability inventory differs from supported legacy APIs'
fm_supervision_activation_supported fm-supervision-readers.v1 legacy legacy-pid-cycle.v1 legacy-epoch-check.v1 || fail 'legacy capabilities refused'
# Every advertised capability works alone and together; none licenses resident
# activation. The protocol line is not itself an activation requirement.
for capability in legacy-pid-cycle.v1 legacy-epoch-check.v1; do
  fm_supervision_activation_supported fm-supervision-readers.v1 legacy "$capability" || fail 'advertised capability refused'
  if fm_supervision_activation_supported fm-supervision-readers.v1 resident "$capability"; then fail 'advertisement licensed resident mode'; fi
done
if fm_supervision_activation_supported; then fail 'missing activation arguments accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1; then fail 'missing mode and requirements accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 legacy; then fail 'missing requirement accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 legacy ''; then fail 'empty capability accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 legacy fm-supervision-readers.v1; then fail 'protocol accepted as capability'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 legacy legacy-pid-cycle.v1 unknown; then fail 'unknown trailing capability accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 unknown legacy-pid-cycle.v1; then fail 'unknown activation mode accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 resident legacy-pid-cycle.v1; then fail 'resident activation accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v2 legacy legacy-pid-cycle.v1; then fail 'unsupported protocol accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 legacy virtual-cycle.v2; then fail 'unsupported capability accepted'; fi
fm_supervision_fence_check 0 ignored "$TMP/fifo.json" || fail 'disabled fence did not remain inert'
if fm_supervision_fence_check 1 7 "$TMP/fifo.json"; then fail 'FIFO owner accepted'; fi
printf 'fm-supervision-owner.v1\tlegacy\t7\n' > "$TMP/owner"
fm_supervision_fence_check 1 7 "$TMP/owner" || fail 'matching epoch refused'
if fm_supervision_fence_check; then fail 'missing fence arguments accepted'; fi
if fm_supervision_fence_check 0; then fail 'missing disabled-fence arguments accepted'; fi
if fm_supervision_fence_check 1 7; then fail 'missing owner path accepted'; fi
if fm_supervision_fence_check 1 7 "$TMP/owner" extra; then fail 'extra fence arguments accepted'; fi
for enable in '' 2 -1 true false invalid; do
  if fm_supervision_fence_check "$enable" 7 "$TMP/no-owner"; then fail 'invalid enable bit accepted'; fi
  if fm_supervision_fence_check "$enable" 7 "$TMP/owner"; then fail 'invalid enable bit accepted with valid record'; fi
done
for epoch in '' 0 00 01 -1 +7 7x ' 7' '7 ' 1000000000000000000; do
  if fm_supervision_fence_check 1 "$epoch" "$TMP/owner"; then fail 'invalid expected epoch accepted'; fi
  if fm_supervision_fence_check 1 "$epoch" "$TMP/no-owner"; then fail 'invalid epoch bypassed owner check'; fi
done
printf 'fm-supervision-owner.v1\tlegacy\t999999999999999999\n' > "$TMP/owner"
fm_supervision_fence_check 1 999999999999999999 "$TMP/owner" || fail 'largest supported epoch refused'
printf 'fm-supervision-owner.v1\tlegacy\t7\n' > "$TMP/owner"
if fm_supervision_fence_check 1 8 "$TMP/owner"; then fail 'stale callback accepted'; fi
printf 'fm-supervision-owner.v1\tresident\t7\n' > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'unsupported owner mode accepted'; fi
printf 'fm-supervision-owner.v1\tlegacy\t7\nextra' > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'extra partial line accepted'; fi
if fm_supervision_fence_check 1 07 "$TMP/owner"; then fail 'noncanonical epoch accepted'; fi
# F4: read normally discards NUL. Every binary position must fail closed,
# beside a byte-exact positive control; no producer or live record is involved.
for binary_record in 'fm-supervision-owner.v1\tlegacy\t7\0\n' \
  'fm-supervision-owner.v1\tleg\0acy\t7\n' \
  'fm-supervision-ow\0ner.v1\tlegacy\t7\n' \
  'fm-supervision-owner.v1\tlegacy\t7\n\0'; do
  printf '%b' "$binary_record" > "$TMP/owner"
  if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'NUL owner accepted'; fi
  printf 'fm-supervision-owner.v1\tlegacy\t7\n' > "$TMP/owner"
  fm_supervision_fence_check 1 7 "$TMP/owner" || fail 'binary negative control refused valid owner'
done
printf 'fm-supervision-owner.v1\tlegacy\t7' > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'unterminated owner accepted'; fi
printf 'fm-supervision-owner.v1\tlegacy\t7\n\n' > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'extra newline accepted'; fi
printf '%064d' 0 > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'size-bound owner accepted'; fi
printf 'fm-supervision-owner.v1\tlegacy\t7\n' > "$TMP/owner"
ln -s "$TMP/owner" "$TMP/owner-link"
if fm_supervision_fence_check 1 7 "$TMP/owner-link"; then fail 'symlink owner accepted'; fi
if fm_supervision_fence_check 1 7 "$TMP/no-owner"; then fail 'missing owner accepted'; fi
if fm_supervision_fence_check invalid 7 "$TMP/owner"; then fail 'invalid enable accepted'; fi
# An empty file is unknown, not epoch zero or successful EOF. Independently
# check unsupported protocol/epoch spelling and arbitrary binary bytes.
for owner_record in '' 'fm-supervision-owner.v2\tlegacy\t7\n' \
  'fm-supervision-owner.v1\tunknown\t7\n' 'fm-supervision-owner.v1\tlegacy\t07\n' \
  'fm-supervision-owner.v1\tlegacy\t7\r\n' '\377\n'; do
  printf '%b' "$owner_record" > "$TMP/owner"
  if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'unknown/malformed owner accepted'; fi
done
printf 'fm-supervision-owner.v1\tlegacy\t7\n' > "$TMP/owner"
chmod 000 "$TMP/owner"
if [ -r "$TMP/owner" ]; then
  printf 'skip: unreadable-owner negative requires nonprivileged file permissions\n'
else
  if fm_supervision_fence_check 1 7 "$TMP/owner" 2>/dev/null; then fail 'unreadable owner accepted'; fi
fi
chmod 600 "$TMP/owner"
fm_supervision_fence_check 1 7 "$TMP/owner" || fail 'readable owner control refused'
fm_supervision_fence_check 0 invalid "$TMP/no-owner" || fail 'disabled fence inspected absent owner or epoch'
fm_supervision_fence_check 0 invalid "$TMP/owner-link" || fail 'disabled fence inspected symlink owner'
if fm_supervision_fence_check 1 7 "$TMP"; then fail 'directory owner accepted'; fi
# No helper command is needed even when the bridge is enabled.
(
  # shellcheck disable=SC2123 # Intentionally prove the APIs need no external helper.
  PATH=/nonexistent
  fm_supervision_fence_check 0 ignored /does/not/exist || exit 1
  fm_supervision_fence_check 1 7 "$TMP/owner" || exit 1
  fm_supervision_activation_supported fm-supervision-readers.v1 legacy legacy-epoch-check.v1 || exit 1
  fm_supervision_reader_capabilities
) > "$TMP/capabilities" || fail 'bridge unexpectedly needed an external command'
cmp -s "$TMP/expected-capabilities" "$TMP/capabilities" || fail 'fork-free capability inventory differs'
pass 'legacy bridge is inert when disabled, fork-free, epoch-fenced and refuses unsupported activation'
