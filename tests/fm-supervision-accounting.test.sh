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
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
assert selection.returncode == 0, selection.stderr
assert 'tests/fm-supervision-accounting.test.sh' in selection.stdout.decode().splitlines()
assert 'tests/fm-supervision-accounting-live.test.sh' not in selection.stdout.decode().splitlines()
checks += 1


def save(name, value):
    path = tmp / name
    path.write_text(json.dumps(value))
    return path


def run(*arguments, good=True, env=None, timeout=8):
    result = subprocess.run([sys.executable, str(cli), *map(str, arguments)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=env)
    assert (result.returncode == 0) == good, (arguments, result.returncode, result.stderr)
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
    assert result['synthetic'] and result['complete_for_attached_trees']
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
extra['argv'] = ['bash', '/fixture/code/bin/fm-control.sh', 'relaunch']
changed['trace']['events'].append(extra)
reexec = json.loads(run('replay', save('reexec.json', changed)).stdout)
assert reexec['observed_births'] == 29
assert reexec['entries'][-1]['lifecycle_entry']
checks += 4

# Self-asserted complete/real/certified flags are not provenance or authority.
changed = copy.deepcopy(value)
changed['synthetic'] = changed['trace']['synthetic'] = False
changed['manifest']['certified_complete'] = True
asserted = json.loads(run('replay', save('asserted-real.json', changed)).stdout)
assert asserted['complete_for_attached_trees']
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
(tmp / 'duplicate.json').write_text('{"format":1,"format":2}')
run('replay', tmp / 'duplicate.json', good=False)
checks += 4

# Public import interface handles interleaved unfinished vfork and child exec.
capture = tmp / 'import'
capture.mkdir()
manifest = value['manifest']
(capture / 'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
raw = ('10 1.000000 vfork(<unfinished ...>\n'
       '11 1.010000 execve("/bin/bash", ["bash", "/fixture/code/bin/fm-crew-state.sh", "task-0"], 0x1 /* env */) = 0\n'
       '10 1.020000 <... vfork resumed>) = 11\n'
       '11 1.030000 clone(child_stack=NULL, flags=SIGCHLD) = 12\n'
       '12 1.040000 execve("/bin/date", ["date"], 0x1 /* env */) = 0\n'
       '12 1.050000 +++ exited with 0 +++\n'
       '11 1.060000 clone(child_stack=NULL, flags=SIGCHLD) = -1 EAGAIN (unavailable)\n')
(capture / 'strace.log').write_text(raw)
(capture / 'strace.stderr').write_bytes(b'')
metadata = {'format': 'fm-supervision-capture.v1', 'complete': True,
            'seeds': [{'pid': 10, 'start_ticks': '1', 'argv': ['bash', '/fixture/code/bin/fm-fleet-snapshot.sh'], 'home': 'fixture'}],
            'before': {'wall_ns': 1000000000, 'monotonic_ns': 1, 'machine_births': 100},
            'after': {'wall_ns': 2000000000, 'monotonic_ns': 1000000001, 'machine_births': 105},
            'raw_sha256': hashlib.sha256(raw.encode()).hexdigest(),
            'stderr_sha256': hashlib.sha256(b'').hexdigest(),
            'manifest_sha256': hashlib.sha256((capture / 'manifest.json').read_bytes()).hexdigest()}
(capture / 'finished.json').write_text(json.dumps(metadata))
trace = json.loads(run('import-strace', capture).stdout)
assert trace['losses']['unknown_parents'] == 0 and trace['losses']['unknown_lines'] == 0
assert trace['losses']['attachment_gaps'] == 1
trace_path = save('import-trace.json', trace)
report = json.loads(run('account', trace_path, '--manifest', capture / 'manifest.json').stdout)
assert report['exclusive_births']['crew-state'] == 2 and report['residual'] == 3
assert not report['complete_for_attached_trees']  # startup gaps are explicit
# Mutating the trace bytes must refuse rather than silently reinterpret them.
(capture / 'strace.log').write_text(raw + 'bad\n')
run('import-strace', capture, good=False)
checks += 2

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
    tool.write_text('#!' + sys.executable + '\nimport os,signal,sys\np=sys.argv[sys.argv.index("-o")+1]\nopen(p,"w").close()\nsignal.signal(signal.SIGINT,lambda *_:sys.exit(0))\nsignal.pause()\n')
    tool.chmod(0o700)
    start = time.monotonic()
    result = run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
                 '--output', tmp / 'bounded', '--acknowledge-ptrace', env=env)
    assert json.loads(result.stdout)['complete']
    assert time.monotonic() - start < 6
    os.kill(os.getpid(), 0)
    done = json.loads((tmp / 'bounded/finished.json').read_text())
    assert done['after']['machine_births'] >= done['before']['machine_births']
    assert done['after']['monotonic_ns'] > done['before']['monotonic_ns']
    assert (tmp / 'bounded').stat().st_mode & 0o077 == 0
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
    # Real signal delivery through the public CLI: the fake tracer is the only
    # child, and the admitted root is this test process (never signalled).
    for sig in (signal.SIGTERM, signal.SIGHUP):
        marker = tmp / ('ready-' + str(sig))
        signal_output = tmp / ('interrupted-' + str(sig))
        signal_env = dict(env, FM_FAKE_TRACER_READY=str(marker))
        tool.write_text('#!' + sys.executable + '\nimport os,signal,sys\np=sys.argv[sys.argv.index("-o")+1]\nopen(p,"w").close()\nsignal.signal(signal.SIGINT,lambda *_:sys.exit(0))\nopen(os.environ["FM_FAKE_TRACER_READY"],"w").write(str(os.getpid()))\nsignal.pause()\n')
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
    tool.write_text('#!' + sys.executable + '\nimport os,signal,sys\np=sys.argv[sys.argv.index("-o")+1]\nopen(p,"w").close()\nsignal.signal(signal.SIGINT,signal.SIG_IGN)\nsignal.pause()\n')
    start = time.monotonic()
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--output', tmp / 'hung', '--acknowledge-ptrace', good=False, env=env)
    assert time.monotonic() - start < 7
    assert not json.loads((tmp / 'hung/finished.json').read_text())['complete']
    os.kill(os.getpid(), 0)
    # Output overflow is a retained incomplete capture, not a false clean trace.
    tool.write_text('#!' + sys.executable + '\nimport sys\np=sys.argv[sys.argv.index("-o")+1]\nopen(p,"wb").write(b"x"*8192)\n')
    run('capture', '--manifest', local_path, '--home', 'fixture', '--seconds', 1,
        '--max-bytes', 4096, '--output', tmp / 'overflow', '--acknowledge-ptrace', good=False, env=env)
    assert (tmp / 'overflow/strace.log').stat().st_size <= 4096
    assert not json.loads((tmp / 'overflow/finished.json').read_text())['complete']
    checks += 10
print('ok - public P0 accounting, sealed byte reads, attribution and bounds: ' + str(checks) + ' cases')
PY
rc=$?
[ "$rc" -eq 0 ] || fail "accounting public-interface tests failed ($rc)"

# Exercise the bridge from its actual legacy library, with no active reader or
# background process. Disabled and unsupported paths may not read their record.
# Production modules have their own canonical source-aware lint roots.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"
fm_supervision_activation_supported fm-supervision-readers.v1 legacy legacy-pid-cycle.v1 legacy-epoch-check.v1 || fail 'legacy capabilities refused'
if fm_supervision_activation_supported fm-supervision-readers.v1 resident legacy-pid-cycle.v1; then fail 'resident activation accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v2 legacy legacy-pid-cycle.v1; then fail 'unsupported protocol accepted'; fi
if fm_supervision_activation_supported fm-supervision-readers.v1 legacy virtual-cycle.v2; then fail 'unsupported capability accepted'; fi
fm_supervision_fence_check 0 ignored "$TMP/fifo.json" || fail 'disabled fence did not remain inert'
if fm_supervision_fence_check 1 7 "$TMP/fifo.json"; then fail 'FIFO owner accepted'; fi
printf 'fm-supervision-owner.v1\tlegacy\t7\n' > "$TMP/owner"
fm_supervision_fence_check 1 7 "$TMP/owner" || fail 'matching epoch refused'
if fm_supervision_fence_check 1 8 "$TMP/owner"; then fail 'stale callback accepted'; fi
printf 'fm-supervision-owner.v1\tresident\t7\n' > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'unsupported owner mode accepted'; fi
printf 'fm-supervision-owner.v1\tlegacy\t7\nextra' > "$TMP/owner"
if fm_supervision_fence_check 1 7 "$TMP/owner"; then fail 'extra partial line accepted'; fi
if fm_supervision_fence_check 1 07 "$TMP/owner"; then fail 'noncanonical epoch accepted'; fi
# No helper command is needed even when the bridge is enabled.
(
  # shellcheck disable=SC2123 # Intentionally prove the APIs need no external helper.
  PATH=/nonexistent
  fm_supervision_fence_check 0 ignored /does/not/exist || exit 1
  fm_supervision_activation_supported fm-supervision-readers.v1 legacy legacy-epoch-check.v1 || exit 1
  fm_supervision_reader_capabilities
) > "$TMP/capabilities" || fail 'bridge unexpectedly needed an external command'
pass 'legacy bridge is inert when disabled, fork-free, epoch-fenced and refuses unsupported activation'
