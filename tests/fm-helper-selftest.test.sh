#!/usr/bin/env bash
# Contract tests for bin/fm-helper-selftest.sh - the CI gate over pinned
# helpers' contract self-tests: select names a gated helper only when one of
# its trigger paths (or the gate itself) changed, and fails closed on an
# unreadable diff; run takes the served versions from the helper's own
# --interface answers, runs each version's --self-test hermetically, fails
# naming every failing helper and version, and fails a run that leaves temp
# state or changes its checkout. Each case drives a fixture helper whose
# behavior comes from a config file beside it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-helper-selftest.sh"

assert_present "$GATE" "bin/fm-helper-selftest.sh is missing"
[ -x "$GATE" ] || fail "bin/fm-helper-selftest.sh must be executable"

TMP=$(fm_test_tmproot fm-helper-selftest)
REPO="$TMP/repo"
FAKE="$REPO/bin/fm-fake.sh"

fixture_git() {
  git -C "$REPO" -c user.name=test -c user.email=test@example.invalid "$@"
}

# The fixture repository: the gate, stand-ins for the gated helper and its
# pinned siblings, and a fake helper serving fm-fake-interface/v1 to v3 as
# bin/fake.conf says.
init_fixture() {
  mkdir -p "$REPO/bin" "$REPO/src"
  cp "$GATE" "$REPO/bin/fm-helper-selftest.sh"
  printf 'one\n' >"$REPO/bin/fm-disk-room.sh"
  printf 'one\n' >"$REPO/bin/fm-storage-admission-lib.sh"
  printf 'one\n' >"$REPO/bin/fm-vhdx-bat.py"
  printf 'one\n' >"$REPO/src/other.txt"
  cat >"$FAKE" <<'SH'
#!/usr/bin/env bash
latest=v3 unserved='' failing='' odd='' leak='' dirty=''
. "${BASH_SOURCE[0]%/*}/fake.conf"
case "$1" in
  --interface)
    v=${2:-$latest}
    case " $odd " in *" $v "*) echo "garbled"; exit 3 ;; esac
    [ -z "${2:-}" ] || case " $unserved " in *" $2 "*) echo "fake: interface $v is not served"; exit 1 ;; esac
    echo "fm-fake-interface/$v" ;;
  --self-test)
    [ -z "$leak" ] || : >"$TMPDIR/leftover"
    [ -z "$dirty" ] || : >"${BASH_SOURCE[0]%/*}/dirt"
    case " $failing " in *" $2 "*) echo "fake: self-test $2 failed: broken"; exit 1 ;; esac
    echo "fake: self-test $2 passed HOME=$HOME FM_HOME=$FM_HOME TMPDIR=$TMPDIR PWD=$PWD CALLER=${FM_CALLER_PROBE:-unset}" ;;
esac
SH
  chmod +x "$FAKE" "$REPO/bin/fm-helper-selftest.sh"
  : >"$REPO/bin/fake.conf"
  git -C "$REPO" init -q
  fixture_git add .
  fixture_git commit -qm baseline
  git -C "$REPO" branch base
}

# fake_conf <line>...: the fake helper's behavior for the next run.
fake_conf() {
  printf '%s\n' "$@" >"$REPO/bin/fake.conf"
}

# gate_run <name> <args>...: the gate with a scratch TMPDIR and a caller
# setting the helper must never see; writes <name>.log and <name>.sum and
# sets RC.
gate_run() {
  local name=$1
  shift
  rm -rf "$TMP/$name.tmp"
  mkdir -p "$TMP/$name.tmp"
  : >"$TMP/$name.sum"
  RC=0
  (cd "$REPO" && TMPDIR="$TMP/$name.tmp" FM_CALLER_PROBE=leaked GITHUB_STEP_SUMMARY="$TMP/$name.sum" \
    bin/fm-helper-selftest.sh "$@") >"$TMP/$name.log" 2>&1 || RC=$?
}

# The status the fixture checkout must keep across a run.
reset_checkout() {
  rm -f "$REPO/bin/dirt"
  fake_conf ''
  fixture_git commit -qam conf --allow-empty
}

test_every_served_version_passes() {
  reset_checkout
  fake_conf "unserved='v1'"
  fixture_git commit -qam conf
  gate_run pass run bin/fm-fake.sh
  expect_code 0 "$RC" "every served version passing: $(cat "$TMP/pass.log")"
  assert_grep "bin/fm-fake.sh serves fm-fake-interface/v3 (latest)" "$TMP/pass.log" "the latest version is read from --interface"
  assert_grep "bin/fm-fake.sh fm-fake-interface/v1: not served (fake: interface v1 is not served)" "$TMP/pass.log" \
    "a version the helper does not serve is reported, not run"
  assert_grep "pass bin/fm-fake.sh fm-fake-interface/v2: fake: self-test v2 passed" "$TMP/pass.log" "v2 runs its self-test"
  assert_grep "pass bin/fm-fake.sh fm-fake-interface/v3: fake: self-test v3 passed" "$TMP/pass.log" "v3 runs its self-test"
  assert_no_grep "self-test v1" "$TMP/pass.log" "an unserved version's self-test never runs"
  assert_grep "fm-helper-selftest: every served version passed: bin/fm-fake.sh" "$TMP/pass.log" "success is reported"
  assert_grep "pass bin/fm-fake.sh fm-fake-interface/v3" "$TMP/pass.sum" "the step summary carries the lines"
  pass "every served version's self-test runs and passes; an unserved version is reported and skipped"
}

test_calls_are_hermetic() {
  local line world
  line=$(grep -F "self-test v3 passed" "$TMP/pass.log") || fail "the pass case printed no v3 line"
  assert_contains "$line" "CALLER=unset" "a caller's environment must not reach the helper"
  world=${line#*HOME=}
  world=${world%%/home *}
  case "$world" in
    "$TMP/pass.tmp/fm-helper-selftest."*) ;;
    *) fail "HOME must sit in a fresh temp directory under TMPDIR, got '$world' ($line)" ;;
  esac
  assert_contains "$line" "FM_HOME=$world/home TMPDIR=$world/tmp PWD=$world/work" \
    "FM_HOME, TMPDIR and the working directory sit in the same temp world"
  [ -z "$(ls -A "$TMP/pass.tmp")" ] || fail "the gate left its temp world behind: $(ls -A "$TMP/pass.tmp")"
  pass "each call sees only PATH and its own temp world, which the gate removes"
}

test_failing_versions_are_each_named() {
  reset_checkout
  fake_conf "failing='v2 v3'"
  fixture_git commit -qam conf
  gate_run failing run bin/fm-fake.sh
  expect_code 1 "$RC" "a failing self-test fails the gate"
  assert_grep "pass bin/fm-fake.sh fm-fake-interface/v1" "$TMP/failing.log" "a passing version still runs"
  assert_grep "::error::fm-helper-selftest: bin/fm-fake.sh fm-fake-interface/v2: --self-test v2 exited 1: fake: self-test v2 failed: broken" \
    "$TMP/failing.log" "v2's failure is annotated with its first line"
  assert_grep "::error::fm-helper-selftest: bin/fm-fake.sh fm-fake-interface/v3: --self-test v3 exited 1" \
    "$TMP/failing.log" "v3 runs after v2 failed and is named too"
  assert_grep "fm-helper-selftest: failed: bin/fm-fake.sh fm-fake-interface/v2; bin/fm-fake.sh fm-fake-interface/v3" \
    "$TMP/failing.log" "the closing line names each failing version"
  pass "every failing version fails the gate by name, and the others still run"
}

test_unreadable_answers_fail() {
  reset_checkout
  fake_conf "odd='v2'"
  fixture_git commit -qam conf
  gate_run odd run bin/fm-fake.sh
  expect_code 1 "$RC" "an --interface vK answer that is neither served nor exit 1 fails"
  assert_grep "FAIL bin/fm-fake.sh fm-fake-interface/v2: --interface v2 answered neither fm-fake-interface/v2 nor exit 1 (exit 3: garbled)" \
    "$TMP/odd.log" "the odd answer is named"

  reset_checkout
  fake_conf "latest='x'"
  fixture_git commit -qam conf
  gate_run latest run bin/fm-fake.sh
  expect_code 1 "$RC" "an unreadable latest version fails"
  assert_grep "FAIL bin/fm-fake.sh: --interface did not print <name>/v<N> (exit 0: fm-fake-interface/x)" "$TMP/latest.log" \
    "the unreadable latest answer is named"

  reset_checkout
  fake_conf "unserved='v1 v2 v3'"
  fixture_git commit -qam conf
  gate_run none run bin/fm-fake.sh
  expect_code 1 "$RC" "a helper serving none of its versions fails"
  assert_grep "FAIL bin/fm-fake.sh: serves none of v1 to v3, not even its latest" "$TMP/none.log" "the empty set is named"

  gate_run missing run bin/fm-absent.sh
  expect_code 1 "$RC" "a missing helper fails"
  assert_grep "FAIL bin/fm-absent.sh: not an executable file" "$TMP/missing.log" "the missing helper is named"
  pass "an unreadable or empty version answer, or a missing helper, fails instead of passing empty"
}

test_leftovers_fail() {
  reset_checkout
  fake_conf "leak=1"
  fixture_git commit -qam conf
  gate_run leak run bin/fm-fake.sh
  expect_code 1 "$RC" "temp state left behind fails"
  assert_grep "FAIL bin/fm-fake.sh: not hermetic: left temp state in its TMPDIR:" "$TMP/leak.log" "the leftover is named"

  reset_checkout
  fake_conf "dirty=1"
  fixture_git commit -qam conf
  gate_run dirty run bin/fm-fake.sh
  expect_code 1 "$RC" "a write into the checkout fails"
  assert_grep "FAIL bin/fm-fake.sh: not hermetic: changed the checkout $REPO (git status differs)" "$TMP/dirty.log" \
    "the changed checkout is named"
  rm -f "$REPO/bin/dirt"
  pass "a self-test that leaves temp state or writes into its checkout fails"
}

test_each_helper_is_checked() {
  reset_checkout
  fake_conf "failing='v1'"
  fixture_git commit -qam conf
  gate_run two run bin/fm-absent.sh bin/fm-fake.sh
  expect_code 1 "$RC" "one bad helper fails the run"
  assert_grep "FAIL bin/fm-absent.sh: not an executable file" "$TMP/two.log" "the first helper's failure is named"
  assert_grep "pass bin/fm-fake.sh fm-fake-interface/v3" "$TMP/two.log" "the next helper still runs"
  assert_grep "fm-helper-selftest: failed: bin/fm-absent.sh; bin/fm-fake.sh fm-fake-interface/v1" "$TMP/two.log" \
    "the closing line names both"
  pass "every named helper is checked, whatever an earlier one did"
}

# select_on <name> <path>: commit a comment line appended to <path> on a fresh
# work branch and run select against base.
select_on() {
  git -C "$REPO" checkout -q -B "work-$1" base
  printf '# two\n' >>"$REPO/$2"
  fixture_git commit -qam "change $2"
  gate_run "$1" select --base base
}

test_select_names_changed_helpers() {
  select_on room bin/fm-disk-room.sh
  expect_code 0 "$RC" "select on a helper change"
  assert_equals bin/fm-disk-room.sh "$(cat "$TMP/room.log")" "a changed helper is selected"
  select_on lib bin/fm-storage-admission-lib.sh
  assert_equals bin/fm-disk-room.sh "$(cat "$TMP/lib.log")" "a changed pinned sibling selects its helper"
  select_on gate bin/fm-helper-selftest.sh
  assert_equals bin/fm-disk-room.sh "$(cat "$TMP/gate.log")" "a change to the gate selects every helper"
  select_on other src/other.txt
  expect_code 0 "$RC" "select on an unrelated change"
  assert_equals '' "$(cat "$TMP/other.log")" "an unrelated change selects nothing"
  gate_run all select --all
  assert_equals bin/fm-disk-room.sh "$(cat "$TMP/all.log")" "--all lists every gated helper"
  gate_run badbase select --base no-such-ref
  expect_code 1 "$RC" "an unreadable base fails closed"
  assert_grep "fm-helper-selftest: cannot find the merge base of no-such-ref and HEAD" "$TMP/badbase.log" "the failure is named"
  git -C "$REPO" checkout -q -B main base
  pass "select names a helper whose trigger paths or gate changed, nothing otherwise, and fails closed"
}

test_usage_errors() {
  local args
  for args in '' 'bogus' 'run' 'select --bogus' 'select --base'; do
    # shellcheck disable=SC2086 # each case is a word list.
    gate_run usage $args
    expect_code 2 "$RC" "'$args' must be a usage error"
  done
  pass "usage errors exit 2"
}

init_fixture
test_every_served_version_passes
test_calls_are_hermetic
test_failing_versions_are_each_named
test_unreadable_answers_fail
test_leftovers_fail
test_each_helper_is_checked
test_select_names_changed_helpers
test_usage_errors
