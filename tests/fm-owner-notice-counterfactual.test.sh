#!/usr/bin/env bash
# Try-only counterfactual driver. Never land this file or its mutation data.
# Revert exactly one guard in a fixture copy, then require its owning public
# behavior case to fail on the named assertion. Healthy evidence is the prior
# owning-case CI run; baseline=true adds a healthy run only for a new case.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-owner-notice-counterfactual)
SPEC="$ROOT/tests/fm-owner-notice-counterfactual.json"
MID=$(jq -er .id "$SPEC") || fail 'missing counterfactual id'
CASE=$(jq -er .case "$SPEC") || fail 'missing counterfactual case'
EXPECTED=$(jq -er .expect "$SPEC") || fail 'missing counterfactual assertion'
COPY="$TMP_ROOT/copy"
mkdir "$COPY"
cp -R "$ROOT/bin" "$ROOT/tests" "$ROOT/docs" "$COPY/" || fail 'copy fixture sources'
if [ "$(jq -r .baseline "$SPEC")" = true ]; then
  timeout -k 10 300 env FM_TEST_ONLY="$CASE" FM_TEST_ONLY_MARKER="$TMP_ROOT/base.marker" \
    bash "$COPY/tests/fm-owner-notice.test.sh" > "$TMP_ROOT/base.out" 2>&1
  base_rc=$?
  cat "$TMP_ROOT/base.out"
  [ -e "$TMP_ROOT/base.marker" ] || fail "$MID healthy owning case never ran"
  [ "$base_rc" = 0 ] || fail "$MID healthy owning case failed rc=$base_rc"
  printf 'COUNTERFACTUAL %s %s baseline-pass\n' "$MID" "$CASE"
fi
if ! python3 - "$SPEC" "$COPY" <<'PY'
import json
import pathlib
import sys
spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
for relative, old, new in spec['edits']:
    path = root / relative
    text = path.read_text()
    if text.count(old) != 1:
        sys.exit('counterfactual edit not unique: ' + relative)
    text = text.replace(old, new)
    if relative.endswith('.py'):
        compile(text, relative, 'exec')
    path.write_text(text)
print('COUNTERFACTUAL applied', spec['id'])
PY
then
  fail "$MID mutation preparation failed"
fi
timeout -k 10 300 env FM_TEST_ONLY="$CASE" FM_TEST_ONLY_MARKER="$TMP_ROOT/mutant.marker" \
  bash "$COPY/tests/fm-owner-notice.test.sh" > "$TMP_ROOT/mutant.out" 2>&1
rc=$?
sed 's/^/# mutant: /' "$TMP_ROOT/mutant.out"
[ -e "$TMP_ROOT/mutant.marker" ] || fail "$MID owning case never ran"
[ "$rc" != 0 ] || fail "$MID SURVIVED: owning case passed with guard reverted"
[ "$rc" != 124 ] && [ "$rc" != 137 ] || fail "$MID timed out; not accepted as an assertion failure"
grep -q '^not ok' "$TMP_ROOT/mutant.out" || fail "$MID failed without a behavior assertion"
grep -F "$EXPECTED" "$TMP_ROOT/mutant.out" > /dev/null || fail "$MID failed without expected assertion: $EXPECTED"
printf 'COUNTERFACTUAL %s %s killed rc=%s assertion=%s\n' "$MID" "$CASE" "$rc" "$EXPECTED"
pass "$MID owning behavior case rejects the isolated reverted guard"
