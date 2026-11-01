#!/usr/bin/env bash
# Temporary try-branch driver for the U1 revert table; it never lands.
# For each mutant in tests/fm-owner-notice-mutants.json it copies bin/, tests/
# and docs/ into its own directory, applies the mutant's edits there and runs
# the one case that owns the row with FM_TEST_ONLY. Each case also runs once
# unmutated and must pass. A mutant is killed when its case fails (a "not ok"
# line) or times out; a case that never ran (no marker) is a spec error.
set -u

# run_one <id> <case> <timeout>: one run; writes <dir>/verdict.
run_one() {
  local id=$1 cs=$2 to=$3 dir rc verdict
  dir="$TMP_ROOT/$id"
  mkdir -p "$dir"
  cp -R "$ROOT/bin" "$ROOT/tests" "$ROOT/docs" "$dir/"
  case "$id" in
    BASE-*) ;;
    *)
      if ! python3 "$APPLY" "$SPEC" "$id" "$dir" > "$dir/apply.out" 2>&1; then
        printf 'MUTANT %s %s SPEC-ERROR apply\n' "$id" "$cs" > "$dir/verdict"
        return 0
      fi ;;
  esac
  timeout -k 10 "$to" env FM_TEST_ONLY="$cs" FM_TEST_ONLY_MARKER="$dir/marker" \
    bash "$dir/tests/fm-owner-notice.test.sh" > "$dir/out" 2>&1
  rc=$?
  if [ ! -e "$dir/marker" ]; then
    verdict='SPEC-ERROR'
  else
    case "$id:$rc" in
      BASE-*:0) verdict='base-ok' ;;
      BASE-*) verdict='BASE-FAIL' ;;
      *:124|*:137) verdict='killed-timeout' ;;
      *:0) verdict='SURVIVED' ;;
      *) if grep -q '^not ok' "$dir/out"; then verdict=killed; else verdict=ERRORED; fi ;;
    esac
  fi
  printf 'MUTANT %s %s %s rc=%s\n' "$id" "$cs" "$verdict" "$rc" > "$dir/verdict"
}

# A worker runs before lib.sh, so it keeps the parent's exported temp root.
if [ "${1:-}" = --one ]; then
  run_one "$2" "$3" "$4"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPEC="$ROOT/tests/fm-owner-notice-mutants.json"
APPLY="$ROOT/tests/fm-owner-notice-mutants-apply.py"
TMP_ROOT=$(fm_test_tmproot fm-owner-notice-mutants)
JOBS=$(nproc 2>/dev/null || echo 2)
export ROOT SPEC APPLY TMP_ROOT

python3 - "$SPEC" > "$TMP_ROOT/plan" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
for case in sorted({m["case"] for m in spec}):
    print("BASE-%s %s 300" % (case, case))
for m in spec:
    print("%s %s %d" % (m["id"], m["case"], m["timeout"]))
PY
[ -s "$TMP_ROOT/plan" ] || fail "no mutant plan from $SPEC"

xargs -P "$JOBS" -n 3 bash "${BASH_SOURCE[0]}" --one < "$TMP_ROOT/plan"

bad=0
while read -r id _ _; do
  if [ ! -s "$TMP_ROOT/$id/verdict" ]; then
    printf 'MUTANT %s - NO-VERDICT\n' "$id"
    bad=$((bad + 1))
    continue
  fi
  cat "$TMP_ROOT/$id/verdict"
  case "$(cat "$TMP_ROOT/$id/verdict")" in
    *" killed"*|*" base-ok "*) ;;
    *)
      bad=$((bad + 1))
      printf '# --- %s output tail\n' "$id"
      tail -n 25 "$TMP_ROOT/$id/out" 2>/dev/null | sed 's/^/# /'
      sed 's/^/# /' "$TMP_ROOT/$id/apply.out" 2>/dev/null ;;
  esac
done < "$TMP_ROOT/plan"
[ "$bad" = 0 ] || fail "$bad mutant run(s) not killed or baseline not green"
pass "every U1 revert mutant is killed and every owning case passes unmutated"
