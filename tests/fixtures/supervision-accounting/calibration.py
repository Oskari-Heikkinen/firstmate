"""GitHub CI fixture plan builder; never reads a live home.

Usage: python3 calibration.py CHECKOUT SCRATCH PLAN [ci/supervision-plans/NAME.json]
An optional tracked, reviewed plan supplies real-home pins and matched fixtures.
Only explicit @REVISION@ and @CHECKOUT@ tokens are resolved in that plan; its
synthetic flag, configuration and work-mix seals are never inferred or relabelled.
The default plan remains synthetic. Native logger probes execute in CI only.
"""
import base64
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import sys

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('calibration fixtures run only on GitHub-hosted Actions')

root, scratch, output = [Path(p).resolve() for p in sys.argv[1:4]]
scratch.mkdir(mode=0o700, exist_ok=False)
revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
spec = importlib.util.spec_from_file_location('accounting', root / 'bin/fm-supervision-accounting.py')
accounting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accounting)


def sealed_file(path, data):
    return dict(path=path, base64=base64.b64encode(data).decode(), sha256=hashlib.sha256(data).hexdigest())


profiles = []
for family in accounting.SOURCE_FAMILIES:
    files = [sealed_file('config/backend', b'tmux\n'),
             sealed_file('config/backlog-backend', b'manual\n')]
    args = {'crew-state': ['missing-task'], 'wake-drain': [],
            'fleet-snapshot': ['--contribution-input']}.get(family)
    qualification = 'Synthetic empty-home invocation; not a live-fleet price.'
    ticks, unit = 1, 'invocation-v1'
    argv = ['/bin/bash', str(root / ('bin/fm-' + family + '.sh')), *(args or [])]
    if family in ('watch', 'supervision-host', 'spawn', 'control'):
        argv = ['/bin/bash', str(root / 'tests/fixtures/supervision-accounting/calibration-tick.sh'), str(root), family]
        if family == 'watch':
            # Existing queue grammar, a result already captured (no source/actor).
            files += [sealed_file('state/.wake-queue', b'1\t1\tcheck\tprocevent:fixture:1\tcheck: fixture\n'),
                      sealed_file('state/home-summary.json', b'{}\n')]
            unit = 'watch-iteration-v1'
            qualification = 'Synthetic first-iteration queued-result wake with no crews or sources, fresh summary; includes startup/watchdog/close, NOT a quiet steady iteration or a mixed-home price.'
        elif family == 'supervision-host':
            ticks, unit = 2, 'half-second-wait-v1'
            qualification = 'Synthetic stable-identity wait interval at POLL=1, two native half-second waits plus real periodic identity/boundary work; includes source/FIFO startup. Private self identity, no arm/engine activation; readiness/changed-identity/engine work excluded.'
        else:
            qualification = 'Synthetic admission-refusal invocation only (invalid task id with explicit delivery operands and pre-spawn guard skipped for spawn, missing operands for control); NOT successful lifecycle or guard cost.'
    profile = dict(home='fixture', family=family, code_ref=revision,
                   configuration_sha256=hashlib.sha256(b'backend=tmux\n').hexdigest(),
                   work_mix_sha256=hashlib.sha256(accounting.dump(files).encode()).hexdigest(),
                   tick_unit=unit, qualification=qualification)
    if args is None and family not in ('watch', 'supervision-host', 'spawn', 'control'):
        profile['unavailable'] = 'No reviewed isolated fixture for this unit; no invented price.'
    else:
        profile.update(fixture_files=files, ticks_per_sample=ticks, argv=argv)
        profile['environment'] = [dict(name=k, value=v) for k, v in {
            'FM_HOME': '@FIXTURE@', 'FM_ROOT_OVERRIDE': '@FIXTURE@',
            'FM_STATE_OVERRIDE': '@FIXTURE@/state', 'FM_DATA_OVERRIDE': '@FIXTURE@/data',
            'FM_CONFIG_OVERRIDE': '@FIXTURE@/config', 'FM_PROJECTS_OVERRIDE': '@FIXTURE@/projects',
            'FM_SUPERVISION_ACTOR': 'main', 'FM_SUPERVISION_TICKS': '1',
            'FM_SUPERVISION_HOST_PRIMARY': 'pi', 'FM_SUPERVISION_HOST_COOLDOWN': '60',
            'HOME': '@FIXTURE@', 'FM_HARNESS': 'claude', 'FM_BACKLOG_BACKEND': 'manual'}.items()]
    profiles.append(profile)
plan = dict(format='fm-supervision-calibration-plan.v1', synthetic=True,
            allocation='exclusive-home-family-v1', profiles=profiles)
if len(sys.argv) > 4:
    selected = sys.argv[4]
    if not re.fullmatch(r'ci/supervision-plans/[a-z0-9][a-z0-9-]{0,63}\.json', selected):
        raise SystemExit('reviewed plan must be ci/supervision-plans/NAME.json')
    subprocess.run(['git', '-C', str(root), 'ls-files', '--error-unmatch', '--', selected], check=True)
    path = root / selected
    if path.is_symlink() or path.parent.is_symlink() or path.parent.parent.is_symlink():
        raise SystemExit('reviewed plan path must not contain symlinks')
    # These two portable placeholders bind the reviewed command to this exact
    # run. Do not expand arbitrary environment variables or shell expressions.
    plan = accounting.prepare_calibration_plan(accounting.load_json(path), revision, str(root))
output.write_text(json.dumps(plan, indent=2) + '\n')

# Native syscall probe, separate from calibrated costs. Empty PATH proves no
# helpers; syscall evidence checks that concurrent entry is one O_APPEND write.
probe = scratch / 'write-probe'
probe.mkdir()
probe_trace = scratch / 'write-probe.trace'
subprocess.run(['strace', '-f', '-qq', '-s', '65536', '-e', 'trace=process,openat,write',
                '-o', str(probe_trace), '/bin/bash', '-c',
                '. "$1/bin/fm-supervision-lib.sh"; PATH=/nonexistent; '
                'fm_supervision_tick_entry "$2" "$2" crew-state',
                'fixture', str(root), str(probe)],
               env=dict(os.environ, FM_SUPERVISION_TICKS='1', BASH_ENV='/dev/null'), check=True, timeout=10)
trace = probe_trace.read_text()
assert not re.search(r'\b(?:clone|clone3|fork|vfork)\(', trace), trace
writes = re.findall(r'write\(\d+, "fm-supervision-tick\.v3', trace)
assert len(writes) == 1 and 'O_APPEND' in trace, trace
assert len((probe / '.supervision-entries.tsv').read_bytes().splitlines()) == 1
print('ok - native journal append: one O_APPEND write, zero child births')
