"""GitHub CI fixture plan builder; no live homes, endpoints or lifecycle calls.

Usage: python3 calibration.py CHECKOUT SCRATCH PLAN
Produces isolated empty-home read workloads, NOT representative fleet costs.
Also checks the builtin logger's actual single-write/no-child behavior in CI.
Missing safe single-tick fixtures remain gaps instead of help-command prices.
"""
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys

if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('calibration fixtures run only on GitHub-hosted Actions')

root, scratch, output = map(lambda p: Path(p).resolve(), sys.argv[1:])
scratch.mkdir(mode=0o700, exist_ok=False)
revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
profiles = []
for family in ('crew-state', 'watch', 'wake-drain', 'fleet-snapshot', 'spawn', 'control',
               'procevent-reconcile', 'park-check', 'owner-guard', 'attached-arm',
               'supervision-host', 'custom-check', 'turnend-guard'):
    home = scratch / family
    for directory in ('state', 'data', 'config', 'projects'):
        (home / directory).mkdir(parents=True)
    (home / 'config/backend').write_text('tmux\n')
    # Empty configuration and work mix are explicit pins, not copied from a
    # deployment. No profile can match a live home accidentally by revision alone.
    files = [dict(path='config/backend', base64=base64.b64encode(b'tmux\n').decode(),
                  sha256=hashlib.sha256(b'tmux\n').hexdigest()),
             dict(path='config/backlog-backend', base64=base64.b64encode(b'manual\n').decode(),
                  sha256=hashlib.sha256(b'manual\n').hexdigest())]
    shape = (json.dumps(files, sort_keys=True, indent=2) + '\n').encode()
    profile = dict(home='fixture', family=family, code_ref=revision,
                   configuration_sha256=hashlib.sha256(b'backend=tmux\n').hexdigest(),
                   work_mix_sha256=hashlib.sha256(shape).hexdigest(),
                   tick_unit='one isolated empty-home ' + family + ' invocation',
                   qualification='Synthetic empty-home shape; not a live-fleet cost or B0 calibration.')
    args = {'crew-state': ['missing-task'], 'wake-drain': [],
            'fleet-snapshot': ['--contribution-input']}.get(family)
    if args is None:
        profile['unavailable'] = 'No isolated single-tick fixture for this unit; no lifecycle or standing loop is run.'
    else:
        profile['fixture_files'] = files
        profile['ticks_per_sample'] = 1
        profile['tick_unit'] = 'invocation-v1'
        profile['argv'] = ['/bin/bash', str(root / ('bin/fm-' + family + '.sh')), *args]
        profile['environment'] = [dict(name=k, value=v) for k, v in {
            'FM_HOME': '@FIXTURE@', 'FM_ROOT_OVERRIDE': '@FIXTURE@',
            'FM_STATE_OVERRIDE': '@FIXTURE@/state', 'FM_DATA_OVERRIDE': '@FIXTURE@/data',
            'FM_CONFIG_OVERRIDE': '@FIXTURE@/config', 'FM_PROJECTS_OVERRIDE': '@FIXTURE@/projects',
            'FM_SUPERVISION_ACTOR': 'main', 'FM_SUPERVISION_TICKS': '1',
            'HOME': '@FIXTURE@', 'FM_HARNESS': 'claude',
            'FM_BACKLOG_BACKEND': 'manual'}.items()]
    profiles.append(profile)
output.write_text(json.dumps(dict(format='fm-supervision-calibration-plan.v1', synthetic=True,
                                 allocation='exclusive-home-family-v1',
                                 profiles=profiles), indent=2) + '\n')

# This is a correctness probe, separate from calibrated costs. An empty PATH
# rules out a helper, while native syscall evidence proves one small O_APPEND
# write rather than relying on how a mocked shell implements printf.
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
writes = re.findall(r'write\(\d+, "fm-supervision-tick\.v2', trace)
assert len(writes) == 1 and 'O_APPEND' in trace, trace
assert len((probe / '.supervision-entries.tsv').read_bytes().splitlines()) == 1
print('ok - native journal append: one O_APPEND write, zero child births')
