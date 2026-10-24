#!/usr/bin/env bash
# Opt-in real strace/ptrace/pidfd contract guard, ordinary workload only.
# Does not create a workload, endpoint or target process. Never installs,
# elevates, changes ptrace policy or drives a backend lifecycle.
#
# Required after the explicit reviewed capture/prerequisite go:
#   FM_SUPERVISION_CAPTURE_LIVE=1 (FM_LIVE alone is insufficient)
#   FM_SUPERVISION_CAPTURE_MANIFEST=/absolute/owner-published-manifest.json
#   FM_SUPERVISION_CAPTURE_HOME=<enrolled-home-id>
#   FM_SUPERVISION_CAPTURE_OUTPUT=/absolute/fresh/private-evidence-directory
# Optional: FM_SUPERVISION_CAPTURE_SECONDS=5 (1..30).
# Default: skip/refuse live execution. Opted-in missing tools/inputs or an
# empty/incompatible trace FAIL; no successful live-format proof is invented.
# The output directory is retained as private evidence, not auto-cleaned.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SUPERVISION_CAPTURE_LIVE:-}" != 1 ]; then
  printf '%s\n' 'skip: live capture disabled; requires dedicated reviewed FM_SUPERVISION_CAPTURE_LIVE=1 opt-in'
  exit 0
fi
fm_live_gate opt-in FM_SUPERVISION_CAPTURE_LIVE python3 strace
[ "$(uname -s)" = Linux ] || fail 'real accounting guard requires Linux pidfds and ptrace'
manifest=${FM_SUPERVISION_CAPTURE_MANIFEST:-}
home=${FM_SUPERVISION_CAPTURE_HOME:-}
output=${FM_SUPERVISION_CAPTURE_OUTPUT:-}
seconds=${FM_SUPERVISION_CAPTURE_SECONDS:-5}
case "$manifest" in /*) ;; *) fail 'an absolute owner manifest path is required' ;; esac
case "$output" in /*) ;; *) fail 'an absolute fresh private evidence directory is required' ;; esac
[ -n "$home" ] || fail 'an explicit enrolled home id is required'
case "$seconds" in ''|*[!0-9]*|0*) fail 'duration must be 1..30 seconds' ;; esac
[ "${#seconds}" -le 2 ] && [ "$seconds" -le 30 ] || fail 'duration must be 1..30 seconds'

python3 "$ROOT/bin/fm-supervision-accounting.py" capture --manifest "$manifest" --home "$home" \
  --output "$output" --seconds "$seconds" --acknowledge-ptrace || fail 'real capture refused; retain evidence and route failure'
# All output remains beneath the freshly created private directory.
python3 "$ROOT/bin/fm-supervision-accounting.py" import-strace "$output" > "$output/trace.json" || fail 'real strace import refused'
python3 "$ROOT/bin/fm-supervision-accounting.py" account "$output/trace.json" \
  --manifest "$output/manifest.json" > "$output/accounting.json" || fail 'real trace accounting refused'
FM_ACCOUNTING_LIVE_OUTPUT="$output" python3 - <<'PY'
import json
import os
from pathlib import Path

output = Path(os.environ['FM_ACCOUNTING_LIVE_OUTPUT'])
trace = json.loads((output / 'trace.json').read_text())
report = json.loads((output / 'accounting.json').read_text())
metadata = json.loads((output / 'finished.json').read_text())
assert metadata['complete'] and trace['capture_complete'], 'incomplete real collector'
assert metadata['tracer_rc'] in (0, -2), 'unexpected tracer termination'
assert metadata['after']['machine_births'] >= metadata['before']['machine_births'], 'machine counter contradiction'
assert trace['losses']['attachment_gaps'] == 1, 'startup gap must remain explicit'
assert not any(count for key, count in trace['losses'].items() if key != 'attachment_gaps'), 'real strace format/ancestry losses'
assert any(event['kind'] == 'birth' for event in trace['events']), 'no real birth to prove parser'
assert any(event['kind'] == 'exec' and event['argv'] for event in trace['events']), 'no real argv to prove parser'
assert report['residual'] >= 0, 'machine cross-check contradiction'
assert 'b0_eligible' not in report and report['b0_status'] == 'pending-reviewed-real-capture', 'code may not certify B0'
print('real capture/import/cleanup syntax proof; startup gap and B0 review remain pending')
PY
rc=$?
[ "$rc" -eq 0 ] || fail "real capture contract failed ($rc); retained at $output"
pass 'real strace format and bounded collector contract on admitted ordinary workload; not B0 certification'
