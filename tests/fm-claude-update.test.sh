#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-claude-update.sh (docs/claude-update.md).
#
# Every case runs against a fake npm: `view` prints a fixture registry answer,
# and `install --global --prefix P PKG@V` lays out an npm global prefix whose
# bin/claude links to a fake binary that prints V, or fails, leaves a stub, or
# prints the wrong version, as the case's mode file says. A fake df reports the
# free space, so nothing touches the registry or the real Claude Code.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for v in ROOT STATE PACKAGE BIN TAG MIN_AGE_HOURS MIN_BYTES MIN_FREE_MB KEEP KEEP_FAILED INSTALL_SECS VIEW_RETRY_SECS STALE_HOURS NPM NOW; do
  unset "FM_CLAUDE_UPDATE_$v"
done
TMP_ROOT=$(fm_test_tmproot fm-claude-update)
TOOL="$ROOT/bin/fm-claude-update.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE"
NOW=1792454400 # 2026-10-20T00:00:00Z

cat >"$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
# Fake npm. view: $FAKE/view (absent = failure). install: lay out a prefix whose
# binary behaves as $FAKE/mode-<version> says (ok, fail, stub, wrong).
printf '%s\n' "$*" >>"$FAKE/calls"
case "$1" in
  view)
    [ -r "$FAKE/view" ] || { echo "npm error network" >&2; exit 1; }
    cat "$FAKE/view" ;;
  install)
    prefix='' spec=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --prefix) prefix=$2; shift ;;
        -*|install) ;;
        *) spec=$1 ;;
      esac
      shift
    done
    ver=${spec##*@}
    mode=$(cat "$FAKE/mode-$ver" 2>/dev/null || echo ok)
    echo "fake install $spec into $prefix ($mode)"
    [ "$mode" = fail ] && { echo "npm error ETARGET" >&2; exit 1; }
    pkg="$prefix/lib/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$pkg/bin" "$prefix/bin"
    printed=$ver
    [ "$mode" = wrong ] && printed=0.0.1
    printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "$printed" >"$pkg/bin/claude.exe"
    [ "$mode" = stub ] || head -c 4000 /dev/zero | tr '\0' '#' >>"$pkg/bin/claude.exe"
    chmod +x "$pkg/bin/claude.exe"
    ln -s ../lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe "$prefix/bin/claude" ;;
esac
SH
cat >"$FAKEBIN/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 100000000 1 ${FAKE_FREE_KB:-50000000} 1% /"
SH
chmod +x "$FAKEBIN/npm" "$FAKEBIN/df"
export PATH="$FAKEBIN:$PATH" FAKE

R="$TMP_ROOT/root"
S="$TMP_ROOT/state"

reset() {
  rm -rf "$R" "$S" "$FAKE"
  mkdir -p "$FAKE"
  unset FAKE_FREE_KB
}

# registry LATEST VERSION=ISO...: write the fake `npm view` answer.
registry() {
  local latest=$1 pair
  shift
  {
    printf '{"dist-tags":{"latest":"%s"},"time":{"created":"2020-01-01T00:00:00.000Z"' "$latest"
    for pair in "$@"; do
      printf ',"%s":"%s"' "${pair%%=*}" "${pair#*=}"
    done
    printf '}}\n'
  } >"$FAKE/view"
}

run_tool() {
  FM_CLAUDE_UPDATE_ROOT="$R" FM_CLAUDE_UPDATE_STATE="$S" FM_CLAUDE_UPDATE_NPM="$FAKEBIN/npm" \
    FM_CLAUDE_UPDATE_MIN_BYTES=2000 FM_CLAUDE_UPDATE_VIEW_RETRY_SECS=0 \
    FM_CLAUDE_UPDATE_NOW="${AT:-$NOW}" "$TOOL" "$@"
}

live() { readlink "$R/current"; }
prev() { readlink "$R/previous"; }

test_install_adopts_and_verifies() {
  reset
  local out
  out=$(run_tool install 2.1.300 2>&1) || fail "install exits 0: $out"
  assert_contains "$out" "switched nothing -> 2.1.300" "install reports the switch"
  assert_equals versions/2.1.300 "$(live)" "current points at the new version"
  assert_equals "2.1.300 (Claude Code)" "$("$R/current/bin/claude" --version)" "current/bin/claude runs"
  assert_grep "--allow-scripts=@anthropic-ai/claude-code" "$FAKE/calls" "install allows the package's install script"
  assert_grep "--foreground-scripts" "$FAKE/calls" "install shows script output in its log"
  assert_present "$R/versions/2.1.300/.fm-claude-update/install.log" "the install log stays with the version"
  assert_present "$S/last-ok" "a healthy install records last-ok"
  pass "install puts a version in its own folder, verifies it and makes it current"
}

test_run_waits_for_release_age() {
  reset
  run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
  registry 2.1.302 2.1.300=2026-10-18T00:00:00Z 2.1.301=2026-10-18T12:00:00Z 2.1.302=2026-10-19T23:00:00Z
  local out
  out=$(run_tool run 2>&1) || fail "run exits 0: $out"
  assert_contains "$out" "switched 2.1.300 -> 2.1.301" "run takes the newest release past 24h, not the 1h-old one"
  assert_equals versions/2.1.301 "$(live)" "current is the aged release"
  assert_equals versions/2.1.300 "$(prev)" "previous keeps the old version"
  assert_equals "2.1.300 (Claude Code)" "$("$R/previous/bin/claude" --version)" "previous still runs"
  out=$(run_tool run 2>&1) || fail "rerun exits 0"
  assert_contains "$out" "2.1.301 is current and verified" "a rerun changes nothing"
  out=$(FM_CLAUDE_UPDATE_MIN_AGE_HOURS=0 run_tool run 2>&1) || fail "zero-age run exits 0"
  assert_contains "$out" "switched 2.1.301 -> 2.1.302" "the age is a setting"
  assert_grep "installing @anthropic-ai/claude-code@2.1.302" "$S/log" "the log says what was installed"
  pass "run takes the newest release past the minimum age and keeps the previous one"
}

test_run_never_downgrades() {
  reset
  run_tool install 2.1.305 >/dev/null 2>&1 || fail "seed install"
  registry 2.1.305 2.1.304=2026-10-17T00:00:00Z 2.1.305=2026-10-19T23:00:00Z
  local out
  out=$(run_tool run 2>&1) || fail "run exits 0: $out"
  assert_contains "$out" "kept 2.1.305" "run keeps a newer live version"
  assert_equals versions/2.1.305 "$(live)" "current is untouched"
  pass "run never downgrades below the live version"
}

check_failure() { # label: current unchanged, alarm standing, evidence kept
  assert_equals versions/2.1.300 "$(live)" "$1: current is unchanged"
  assert_equals "2.1.300 (Claude Code)" "$("$R/current/bin/claude" --version)" "$1: live claude still runs"
  assert_present "$S/alarm" "$1: the alarm stands"
  assert_grep "live claude unchanged (2.1.300)" "$S/alarm" "$1: the alarm says live claude is unchanged"
}

test_failures_leave_live_untouched() {
  local mode out code reason
  for mode in fail stub wrong; do
    reset
    run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
    registry 2.1.301 2.1.300=2026-10-17T00:00:00Z 2.1.301=2026-10-18T00:00:00Z
    echo "$mode" >"$FAKE/mode-2.1.301"
    out=$(run_tool run 2>&1)
    code=$?
    expect_code 1 "$code" "$mode install"
    check_failure "$mode install"
    case "$mode" in
      fail) reason="npm install of @anthropic-ai/claude-code@2.1.301 exited 1" ;;
      stub) reason="under the 2000-byte floor" ;;
      wrong) reason="printed '0.0.1 (Claude Code)', not 2.1.301" ;;
    esac
    assert_contains "$out" "$reason" "$mode install names the cause"
    assert_grep "$reason" "$S/alarm" "$mode install alarm names the cause"
    assert_absent "$R/versions/2.1.301" "$mode install never reaches versions/"
    [ -n "$(find "$R/failed" -mindepth 3 -maxdepth 3 -name install.log)" ] || fail "$mode install keeps its log under failed/"
  done
  rm -f "$FAKE/mode-2.1.301"
  out=$(run_tool run 2>&1) || fail "the fixed release installs: $out"
  assert_absent "$S/alarm" "a healthy run clears the alarm"
  pass "a failed install, a stub binary and a wrong version alarm and leave live claude untouched"
}

test_version_check_and_room() {
  reset
  run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
  local out code
  out=$(run_tool run 2>&1)
  code=$?
  expect_code 1 "$code" "unreadable registry"
  check_failure "unreadable registry"
  assert_contains "$out" "version check failed" "the registry failure is named"
  assert_equals 2 "$(grep -c '^view' "$FAKE/calls")" "the version check is retried once"
  registry 2.1.301 2.1.301=2026-10-18T00:00:00Z
  out=$(FAKE_FREE_KB=1000 run_tool run 2>&1)
  code=$?
  expect_code 1 "$code" "no room"
  check_failure "no room"
  assert_contains "$out" "not enough room" "the room failure is named"
  pass "an unreadable registry and a full disk alarm without touching live claude"
}

test_lock_skips_run() {
  reset
  run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
  registry 2.1.301 2.1.301=2026-10-18T00:00:00Z
  local out code
  exec 8>>"$S/lock"
  flock -n 8 || fail "test takes the lock"
  out=$(run_tool run 2>&1) || fail "a locked run exits 0: $out"
  assert_grep "skipped: another claude-update run holds the lock" "$S/log" "the skip is logged"
  out=$(run_tool rollback 2>&1)
  code=$?
  expect_code 75 "$code" "a locked rollback"
  exec 8>&-
  assert_equals versions/2.1.300 "$(live)" "nothing switched under the lock"
  pass "a run that finds the lock held logs a skip and changes nothing"
}

test_rollback() {
  reset
  run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
  run_tool install 2.1.301 >/dev/null 2>&1 || fail "second install"
  local out
  out=$(run_tool rollback 2>&1) || fail "rollback exits 0: $out"
  assert_equals versions/2.1.300 "$(live)" "rollback makes previous current"
  assert_equals versions/2.1.301 "$(prev)" "the rolled-back version becomes previous"
  assert_grep 2.1.301 "$S/skipped-versions" "the rolled-back version is skipped"
  registry 2.1.301 2.1.300=2026-10-17T00:00:00Z 2.1.301=2026-10-18T00:00:00Z
  out=$(run_tool run 2>&1) || fail "run after rollback exits 0"
  assert_equals versions/2.1.300 "$(live)" "run does not retake a skipped version"
  run_tool install 2.1.301 >/dev/null 2>&1 || fail "reinstall by hand"
  assert_no_grep 2.1.301 "$S/skipped-versions" "install by hand lifts the skip"
  rm -f "$R/previous"
  out=$(run_tool rollback 2>&1) && fail "rollback without previous must fail"
  assert_contains "$out" "no previous version is kept" "the refusal names why"
  pass "rollback swaps back in one step and run then skips the bad version"
}

test_stage_switches_nothing() {
  reset
  run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
  local out
  out=$(run_tool stage 2.1.302 2>&1) || fail "stage exits 0: $out"
  assert_contains "$out" "nothing switched" "stage says it switched nothing"
  assert_equals versions/2.1.300 "$(live)" "stage leaves current"
  assert_present "$R/versions/2.1.302/bin/claude" "stage keeps the verified copy"
  out=$(run_tool install 2.1.302 2>&1) || fail "install of a staged version"
  assert_equals 1 "$(grep -c '2.1.302$' "$FAKE/calls")" "a staged version is not installed twice"
  assert_equals "" "$(run_tool status 2>&1 >/dev/null)" "status without skipped-versions prints no error"
  pass "stage installs and verifies without switching"
}

test_check_lines() {
  reset
  local out
  out=$(run_tool check)
  assert_contains "$out" "no healthy run on record" "missing state is reported, not taken as healthy"
  run_tool install 2.1.300 >/dev/null 2>&1 || fail "seed install"
  out=$(run_tool check)
  assert_contains "$out" "claude-update recovered" "the clear is reported once"
  assert_equals "" "$(run_tool check)" "a healthy state stays quiet"
  out=$(run_tool run 2>&1)
  out=$(run_tool check)
  assert_contains "$out" "claude-update failed" "a new alarm is reported"
  assert_equals "" "$(run_tool check)" "a standing alarm is not repeated at once"
  assert_contains "$(AT=$((NOW + 21600)) run_tool check)" "claude-update failed" "a standing alarm repeats after 6 hours"
  rm -f "$S/alarm"
  run_tool check >/dev/null
  assert_contains "$(AT=$((NOW + 51 * 3600)) run_tool check)" "no healthy run since" "a stale updater is reported"
  pass "check reports new alarms, repeats, recovery and staleness"
}

test_arm_and_disarm() {
  reset
  local home out obs
  home="$TMP_ROOT/home"
  mkdir -p "$home/state"
  chmod 700 "$home/state"
  obs=$(fm_check_rename_observer "$TMP_ROOT/arm-observer")
  out=$(PATH="$obs:$PATH" FM_TEST_MV_LOG="$TMP_ROOT/arm-mv.log" FM_TEST_CHECK="$home/state/claude-update.check.sh" \
    FM_HOME="$home" FM_CLAUDE_UPDATE_ROOT="$R" FM_CLAUDE_UPDATE_STATE="$S" "$TOOL" arm) || fail "arm exits 0"
  assert_contains "$out" "armed: $home/state/claude-update.check.sh" "arm names the shim"
  assert_present "$home/state/claude-update.check-trust" "arm binds the shim's bytes"
  assert_equals "trust absent|check bound" "$(paste -sd'|' "$TMP_ROOT/arm-mv.log")" "arm binds the shim before it appears"
  out=$(FM_CLAUDE_UPDATE_ROOT='' FM_CLAUDE_UPDATE_STATE='' "$home/state/claude-update.check.sh")
  assert_contains "$out" "$S/last-ok missing" "the shim carries the arm-time settings"
  FM_HOME="$home" "$TOOL" disarm >/dev/null || fail "disarm exits 0"
  assert_absent "$home/state/claude-update.check.sh" "disarm removes the shim"
  pass "arm registers the watcher check with its settings and disarm retires it"
}

test_misuse() {
  local code
  run_tool install >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "install without a version"
  run_tool install latest >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "install with a tag"
  FM_CLAUDE_UPDATE_KEEP=1 run_tool status >/dev/null 2>&1
  code=$?
  expect_code 2 "$code" "keep below 2"
  pass "misuse exits 2"
}

test_install_adopts_and_verifies
test_run_waits_for_release_age
test_run_never_downgrades
test_failures_leave_live_untouched
test_version_check_and_room
test_lock_skips_run
test_rollback
test_stage_switches_nothing
test_check_lines
test_arm_and_disarm
test_misuse
