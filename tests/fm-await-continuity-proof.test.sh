#!/usr/bin/env bash
# Temporary ci/try-only proof; remove this and its tier row before candidate CI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-await-continuity-proof)
git clone --quiet --shared "$ROOT" "$TMP_ROOT/copy"
git -C "$TMP_ROOT/copy" checkout --quiet --detach "$(git -C "$ROOT" rev-parse HEAD)"
python3 - "$TMP_ROOT" <<'PY'
from pathlib import Path
import subprocess, sys
work = Path(sys.argv[1])
copy = work / 'copy'
selection = work / 'selection'
selection.write_text('tests/fm-park.test.sh:case_await_declaration_continuity\n')
def run(name):
    log = work / (name + '.log')
    with log.open('w') as out:
        result = subprocess.run(['bash', str(copy/'bin/fm-test-run.sh'), '--from-list', str(selection)],
                                cwd=copy, stdout=out, stderr=subprocess.STDOUT)
    text = log.read_text(errors='replace')
    print(text, flush=True)
    return result.returncode, text
rc, _ = run('baseline')
if rc:
    raise SystemExit('positive ordinary-await continuity baseline failed')
print('positive ordinary-await continuity baseline passed', flush=True)
source = copy/'bin/fm-park.sh'
original = source.read_text()
probes = [
    ('active-declaration', '  live_wait_status_matches "$2"\n', '  return 0 # isolated declaration guard reversion\n',
     "('probe', 'working', 'pre-expiry working status is preserved')"),
    ('terminal-publication', '  live_wait_is_current "$2" "$3" \\\n', '  true \\\n',
     "('success', 'working', 'pre-expiry working status is preserved')"),
]
errors = []
for name, old, new, assertion in probes:
    if original.count(old) != 1:
        errors.append(name+': guard preparation was not unique')
        continue
    source.write_text(original.replace(old, new, 1))
    try:
        rc, text = run(name)
        if rc == 0 or assertion not in text or 'not ok - ordinary await declaration continuity' not in text:
            errors.append(name+': reversion did not fail its own assertion')
        else:
            print('counterfactual '+name+': '+assertion, flush=True)
    finally:
        source.write_text(original)
if errors:
    raise SystemExit('\n'.join(errors))
print('ok - ordinary-await declaration and terminal-publication guards fail their own assertions')
PY
