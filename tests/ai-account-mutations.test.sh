#!/usr/bin/env bash
# Standing delta mutants for recorded account moves and outcome delivery.
# Private script copies only; run the public-command fixture suite to judge
# each mutant. An unmutated baseline must pass; timeouts are errors, not kills.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot ai-account-mutants)

if ! python3 - "$ROOT/bin/fm-account.sh" "$TMP_ROOT" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
live_guard = 'if [ "$MOVE_FROM" = "$acct" ] && { [ "$live" = "$acct" ] || [ "$live" = none ]; }; then'
mutants = {
    "R1-worker-record-only": (
        '  ' + live_guard + '\n    echo "unchanged:',
        '  if [ "$MOVE_FROM" = "$acct" ]; then\n    echo "unchanged:'),
    "R1-mate-record-only": (
        '    ' + live_guard + '\n      log_move',
        '    if [ "$MOVE_FROM" = "$acct" ]; then\n      log_move'),
    "R1-record-hides-restart-failure": (
        'if [ "$4" = 0 ] && [ "$(fm_account_recorded_name "$STATE/$1.meta")" = "$3" ] &&\n'
        '    { [ "$live" = "$3" ] || [ "$live" = none ]; }; then',
        'if [ "$(fm_account_recorded_name "$STATE/$1.meta")" = "$3" ]; then'),
    "R2-root-dangling-pin": (
        '{ [ ! -e "$CONFIG/claude-account" ] && [ ! -L "$CONFIG/claude-account" ]; }',
        '[ ! -e "$CONFIG/claude-account" ]'),
    "R3-omit-final-outcome": (
        "trap 'move_finish $?' EXIT", "trap ':' EXIT"),
    "R3-omit-events": ('move_event() {\n', 'move_event() {\n  return 0\n'),
    "R3-omit-registration": (
        'move_alert register "$MOVE_STORE" account-move account-move-events.status fm-account || die',
        ': || die'),
    "R3-clear-failed-delivery": (
        'move_alert assert "$MOVE_STORE" account-move account-move-incomplete \\\n      "outcome=$MOVE_OUTCOME;',
        'move_alert clear "$MOVE_STORE" account-move account-move-incomplete \\\n      "outcome=$MOVE_OUTCOME;'),
    "R4-M8-swallow-control-failure": (
        '*) (cmd_use "$id" "$acct" --note "Moved to subscription account $acct; continue the same task from its current records and copy.") || rc=$? ;;',
        '*) (cmd_use "$id" "$acct" --note "Moved to subscription account $acct; continue the same task from its current records and copy.") || rc=$?; [ "$rc" != 1 ] || rc=0 ;;'),
}
for name, (old, new) in mutants.items():
    if source.count(old) != 1:
        raise SystemExit(f"mutation input missing or ambiguous: {name}")
    target = root / f"{name}.sh"
    target.write_text(source.replace(old, new, 1))
    target.chmod(0o700)
PY
then
  fail 'could not prepare delta mutants'
fi

rc=0
fm_run_timed 180 bash "$ROOT/tests/ai-account.test.sh" > "$TMP_ROOT/baseline.log" 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
  cat "$TMP_ROOT/baseline.log"
  fail "unmutated baseline failed (exit $rc); mutants cannot be judged"
fi
errors=0
for script in "$TMP_ROOT"/*.sh; do
  id=${script##*/}; id=${id%.sh}
  if ! bash -n "$script"; then
    printf 'not ok - %s invalid mutation\n' "$id"
    errors=$((errors + 1))
    continue
  fi
  rc=0
  fm_run_timed 180 env FM_AI_ACCOUNT_TEST_SOURCE="$script" bash "$ROOT/tests/ai-account.test.sh" > "$TMP_ROOT/$id.log" 2>&1 || rc=$?
  if [ "$rc" = 1 ] && grep -q '^not ok' "$TMP_ROOT/$id.log"; then
    printf 'ok - %s killed\n' "$id"
    grep '^not ok' "$TMP_ROOT/$id.log"
  else
    printf 'not ok - %s survived or could not be judged (exit %s)\n' "$id" "$rc"
    cat "$TMP_ROOT/$id.log"
    errors=$((errors + 1))
  fi
done
[ "$errors" = 0 ] || fail "$errors delta mutants survived or could not be judged"
pass 'all nine account-move delta mutants killed after an unmutated baseline pass'
