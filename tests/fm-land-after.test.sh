#!/usr/bin/env bash
# Behavior tests for dependency-ordered landings (bin/fm-land-after.sh).
#
# Everything runs through the script's public commands, the real fm-send inbox
# plane over a stubbed tmux, real git repositories with a local bare origin, a
# stubbed forge, and the real process-event runner for the end-to-end cases.
# The suite pins: the landed condition's verdicts (landed, not yet, failed or
# cancelled), evidence surviving the blocker's cleanup, exactly-once steering
# per live waiter across reruns, a failed send staying retryable, register's
# backlog edge and immediate delivery after landing, and the full watch firing
# the steer once while a failed blocker wakes firstmate and steers nobody.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-land-after-tests)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# Stub tmux (doorbell accepted) and gh (forge state from FM_FAKE_PR_STATE).
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-w1\n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_PR_STATE:-}" in
  MERGED) printf 'state=MERGED\nmerged=true\n' ;;
  OPEN|CLOSED) printf 'state=%s\nmerged=false\n' "$FM_FAKE_PR_STATE" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0

# FM_ROOT_OVERRIDE points fm-send's guard at the test home, as in
# tests/fm-send-inbox.test.sh, so no real fleet state is consulted.
la() { FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$ROOT/bin/fm-land-after.sh" "${@:2}"; }
pe() { FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

new_home() {  # <home>
  mkdir -p "$1/state" "$1/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1/data/backlog.md"
  fm_test_track_procevent_home "$1"
}

live_waiter() {  # <home> <id>
  fm_write_meta "$1/state/$2.meta" "window=sess:fm-$2" "kind=ship" "harness=claude"
}

# A direct-push blocker whose worktree has one commit; push_blocker lands it.
direct_push_blocker() {  # <home> <id> -> sets REPO WT SHA
  REPO="$TMP_ROOT/$2-repo"
  WT="$TMP_ROOT/$2-wt"
  fm_git_worktree "$REPO" "$WT" "fm/$2"
  git -C "$WT" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m change
  SHA=$(git -C "$WT" rev-parse HEAD)
  fm_write_meta "$1/state/$2.meta" "window=sess:fm-$2" "kind=ship" "mode=direct-push" \
    "worktree=$WT" "project=$REPO"
  printf 'working [at=1]: started\n' > "$1/state/$2.status"
}
push_blocker() {  # <home> <id>
  git -C "$WT" push -q origin "HEAD:main"
  printf 'done [at=2]: landed %s on main\n' "$SHA" >> "$1/state/$2.status"
}

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && { printf '%s\n' "$g"; return 0; }
  done
  return 1
}

inbox_count() {  # <home> <id>
  local n=0 f
  for f in "$1/state/$2.inbox"/*.msg; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s\n' "$n"
}

# --- landed: direct-push not yet, landed, and evidence surviving cleanup -------
H="$TMP_ROOT/h-dp"; new_home "$H"
direct_push_blocker "$H" b1
la "$H" landed b1 >/dev/null; rc=$?
expect_code 1 "$rc" "a working blocker is not landed yet"
printf 'done [at=2]: landed %s on main\n' "$SHA" >> "$H/state/b1.status"
la "$H" landed b1 >/dev/null; rc=$?
expect_code 1 "$rc" "a claimed landing whose commit is not on the remote default is not landed"
git -C "$WT" push -q origin "HEAD:fm/b1"
printf 'done [at=3]: landed %s on fm/b1\n' "$SHA" >> "$H/state/b1.status"
la "$H" landed b1 >/dev/null; rc=$?
expect_code 1 "$rc" "a reported feature-branch tip cannot release the dependency"
assert_absent "$H/state/land-after/b1/landed" "a feature-branch push records no landed evidence"
git -C "$WT" push -q origin "HEAD:main"
out=$(la "$H" landed b1); rc=$?
expect_code 0 "$rc" "the pushed commit is landed"
assert_contains "$out" "$SHA" "the verdict names the landed commit"
rm -f "$H/state/b1.meta"
la "$H" landed b1 >/dev/null; rc=$?
expect_code 0 "$rc" "recorded evidence answers after the blocker's record is cleaned up"
pass "landed: direct-push verdicts and evidence surviving cleanup"

# --- landed: ancestry on the real default and local-only landing ---------------
H="$TMP_ROOT/h-ancestor"; new_home "$H"
direct_push_blocker "$H" ba
push_blocker "$H" ba
OTHER="$TMP_ROOT/other-pusher"
git clone --quiet "file://$REPO.origin.git" "$OTHER"
git -C "$OTHER" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m next
REMOTE_TIP=$(git -C "$OTHER" rev-parse HEAD)
git -C "$OTHER" push -q origin HEAD:main
if git -C "$WT" cat-file -e "$REMOTE_TIP^{commit}" 2>/dev/null; then
  fail "the independent remote tip unexpectedly exists in the blocker's copy"
fi
la "$H" landed ba >/dev/null; rc=$?
expect_code 0 "$rc" "a blocker remains landed when an independent pusher advances the default"
if git -C "$WT" cat-file -e "$REMOTE_TIP^{commit}" 2>/dev/null; then
  fail "ancestry evidence fetched into the blocker's copy"
fi
pass "landed: remote default ancestry"

H="$TMP_ROOT/h-local"; new_home "$H"
direct_push_blocker "$H" bl
fm_write_meta "$H/state/bl.meta" "kind=ship" "mode=local-only" "worktree=$WT" "project=$REPO"
printf 'done [at=2]: ready for local landing\n' > "$H/state/bl.status"
la "$H" landed bl >/dev/null; rc=$?
expect_code 1 "$rc" "a local ready branch is not landed"
assert_absent "$H/state/land-after/bl/landed" "local readiness records no landed evidence"
git -C "$REPO" merge --ff-only -q "$SHA"
out=$(la "$H" landed bl); rc=$?
expect_code 0 "$rc" "a locally fast-forwarded default branch releases its waiter"
assert_contains "$out" "$SHA" "local-only verdict names the landed head"
pass "landed: local-only verdict"

# --- landed: failed, PR states, and a vanished record ---------------------------
H="$TMP_ROOT/h-verdicts"; new_home "$H"
fm_write_meta "$H/state/f1.meta" "kind=ship" "mode=no-mistakes"
printf 'done [at=1]: handoff\nfailed [at=2]: tests broke\n' > "$H/state/f1.status"
out=$(la "$H" landed f1); rc=$?
expect_code 3 "$rc" "a failed blocker is a condition error"
assert_contains "$out" "tests broke" "the failure reason is carried to firstmate"
fm_write_meta "$H/state/p1.meta" "kind=ship" "mode=no-mistakes" "pr=https://github.com/o/r/pull/7"
FM_FAKE_PR_STATE=OPEN la "$H" landed p1 >/dev/null; rc=$?
expect_code 1 "$rc" "an open PR is not landed yet"
la "$H" landed p1 >/dev/null; rc=$?
expect_code 1 "$rc" "an unreadable forge is not landed yet, never an error"
FM_FAKE_PR_STATE=CLOSED la "$H" landed p1 >/dev/null; rc=$?
expect_code 3 "$rc" "a PR closed without merging is a cancelled blocker"
assert_absent "$H/state/land-after/p1/landed" "no evidence is recorded for an unlanded blocker"
FM_FAKE_PR_STATE=MERGED la "$H" landed p1 >/dev/null; rc=$?
expect_code 0 "$rc" "a merged PR is landed"
out=$(la "$H" landed gone1 2>&1); rc=$?
expect_code 3 "$rc" "a blocker with no record and no evidence wakes firstmate"
assert_contains "$out" "verify its landing by hand" "the vanished-record reason is explicit"
pass "landed: failed, PR states, and a vanished record"

# --- deliver: exactly once, skip dead waiters, refuse before landing ------------
H="$TMP_ROOT/h-deliver"; new_home "$H"
live_waiter "$H" w1
mkdir -p "$H/state/land-after/b2"
printf 'rebase please\n' > "$H/state/land-after/b2/w1.steer"
printf 'gone\n' > "$H/state/land-after/b2/w2.steer"
la "$H" deliver b2 >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" "deliver refuses without recorded landed evidence"
assert_equals 0 "$(inbox_count "$H" w1)" "nothing is steered before the blocker lands"
printf 'PR merged\n' > "$H/state/land-after/b2/landed"
out=$(la "$H" deliver b2); rc=$?
expect_code 0 "$rc" "deliver succeeds when every waiter is steered or skipped"
assert_contains "$out" "w2: not live; skipped" "a waiter no longer live is skipped"
assert_equals 1 "$(inbox_count "$H" w1)" "the live waiter receives one steer"
assert_grep 'rebase please' "$H/state/w1.inbox/001.msg" "the recorded steer text is delivered"
la "$H" deliver b2 >/dev/null; rc=$?
expect_code 0 "$rc" "a rerun is a clean no-op"
assert_equals 1 "$(inbox_count "$H" w1)" "a rerun never steers twice"
out=$(la "$H" status b2)
assert_contains "$out" "w1: steered" "status reports the delivered waiter"
assert_contains "$out" "w2: skipped" "status reports the skipped waiter"
pass "deliver: exactly once per live waiter"

# --- deliver: a crash after claiming never repeats an uncertain effect ---------
H="$TMP_ROOT/h-crashclaim"; new_home "$H"
live_waiter "$H" wc
mkdir -p "$H/state/land-after/bc"
printf 'go\n' > "$H/state/land-after/bc/wc.steer"
printf 'landed\n' > "$H/state/land-after/bc/landed"
printf '1\n' > "$H/state/land-after/bc/wc.claim"
out=$(la "$H" deliver bc); rc=$?
expect_code 1 "$rc" "an unconfirmed delivery claim requires manual checking"
assert_contains "$out" "claimed but never confirmed" "an uncertain delivery names the recovery"
assert_equals 0 "$(inbox_count "$H" wc)" "a leftover claim never sends a second steer"
assert_present "$H/state/land-after/bc/wc.claim" "an uncertain claim is preserved"
la "$H" deliver bc >/dev/null; rc=$?
expect_code 1 "$rc" "a restart still refuses to repeat the uncertain effect"
assert_equals 0 "$(inbox_count "$H" wc)" "repeated delivery preserves exactly-once steering"
pass "deliver: leftover crash claim prevents resending"

# --- deliver: a failed send stays retryable -------------------------------------
H="$TMP_ROOT/h-sendfail"; new_home "$H"
fm_write_meta "$H/state/w3.meta" "kind=ship" "harness=claude" "window=bad target"
mkdir -p "$H/state/land-after/b3"
printf 'go\n' > "$H/state/land-after/b3/w3.steer"
printf 'landed\n' > "$H/state/land-after/b3/landed"
: > "$H/state/w3.inbox" 2>/dev/null
la "$H" deliver b3 >/dev/null 2>&1; rc=$?
expect_code 1 "$rc" "a failed send fails the delivery"
assert_absent "$H/state/land-after/b3/w3.claim" "a failed send drops its claim"
rm -f "$H/state/w3.inbox"
live_waiter "$H" w3
la "$H" deliver b3 >/dev/null 2>&1; rc=$?
expect_code 0 "$rc" "a rerun after the fault delivers"
assert_equals 1 "$(inbox_count "$H" w3)" "the retried waiter is steered once"
pass "deliver: a failed send is retried by a rerun"

# --- register ---------------------------------------------------------------------
if [ "$HAVE_TASKS_AXI" -eq 1 ]; then
  H="$TMP_ROOT/h-register"; new_home "$H"
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add blk "blocker" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add wt1 "waiter" >/dev/null
  la "$H" register nolive --after blk >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a waiter that is not live is refused"
  live_waiter "$H" wt1
  out=$(la "$H" register wt1 --after blk); rc=$?
  expect_code 0 "$rc" "register succeeds for a live waiter"
  assert_contains "$out" "armed: when-land-after-blk" "register arms the blocker's watch"
  shown=$(FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" show wt1 --full)
  assert_contains "$shown" "blocked_by: blk" "the backlog records the blocked-by edge"
  assert_grep 'blk is now on the default branch' "$H/state/land-after/blk/wt1.steer" \
    "the default steer names the blocker"
  out=$(la "$H" register wt1 --after blk --steer "custom text"); rc=$?
  expect_code 0 "$rc" "re-registering an unsent waiter succeeds"
  assert_contains "$out" "already armed" "a second registration shares the armed watch"
  assert_grep 'custom text' "$H/state/land-after/blk/wt1.steer" "re-registering replaces the steer"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire land-after-blk >/dev/null
  pass "register: backlog edge, steer record, and one shared watch"

  # The backlog's durable PR link answers after cleanup, before any observation.
  H="$TMP_ROOT/h-backlog-pr"; new_home "$H"
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add old "cleaned blocker" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" 'done' old --pr https://github.com/o/r/pull/8 --no-prune >/dev/null
  FM_FAKE_PR_STATE=OPEN la "$H" landed old >/dev/null; rc=$?
  expect_code 1 "$rc" "a backlog PR link still open is not landed"
  FM_FAKE_PR_STATE=CLOSED la "$H" landed old >/dev/null; rc=$?
  expect_code 3 "$rc" "a backlog PR closed unmerged wakes firstmate"
  FM_FAKE_PR_STATE=MERGED la "$H" landed old >/dev/null; rc=$?
  expect_code 0 "$rc" "a merged backlog PR releases the cleaned-up blocker"
  assert_present "$H/state/land-after/old/landed" "the backlog PR verdict is recorded"
  pass "landed: backlog PR link after cleanup"

  # Unreadable or unconfirmed state is never mistaken for an armed watch.
  H="$TMP_ROOT/h-watch-unknown"; new_home "$H"
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add blk "blocker" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add wu "waiter" >/dev/null
  live_waiter "$H" wu
  la "$H" register wu --after blk >/dev/null || fail "unknown-state register failed"
  printf 'claimed\n' > "$H/state/when/when-land-after-blk.fired"
  out=$(la "$H" register wu --after blk 2>&1); rc=$?
  expect_code 2 "$rc" "an unconfirmed action claim refuses registration"
  assert_contains "$out" "claimed without a captured outcome" "the ambiguous claim's reason is explicit"
  assert_absent "$H/state/land-after/blk/watch-rearmed" "ambiguous state is not re-armed"
  rm -f "$H/state/when/when-land-after-blk.fired"
  pe "$H" retire when-land-after-blk >/dev/null
  out=$(la "$H" register wu --after blk 2>&1); rc=$?
  expect_code 2 "$rc" "a spec without its source registration is refused"
  assert_contains "$out" "registration is missing or mismatched" "unreadable registration names the problem"
  assert_absent "$H/state/land-after/blk/watch-rearmed" "unknown state is not re-armed"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire land-after-blk >/dev/null
  pass "register: ambiguous and unknown watches refuse reuse"

  # A waiter registered after delivery is steered at once.
  H="$TMP_ROOT/h-late"; new_home "$H"
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add blk "blocker" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add late "waiter" >/dev/null
  mkdir -p "$H/state/land-after/blk"
  printf 'landed\n' > "$H/state/land-after/blk/landed"
  printf '1\n' > "$H/state/land-after/blk/delivered"
  live_waiter "$H" late
  out=$(la "$H" register late --after blk); rc=$?
  expect_code 0 "$rc" "a late registration delivers"
  assert_contains "$out" "late: steered" "the late waiter is steered immediately"
  assert_equals 1 "$(inbox_count "$H" late)" "the late waiter receives one steer"
  assert_absent "$H/state/when/when-land-after-blk.spec" "no watch is re-armed after delivery"
  la "$H" register late --after blk >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "re-registering a steered waiter is refused"
  pass "register: a waiter registered after the blocker landed is steered at once"

  # --- end to end through the runner ---------------------------------------------
  H="$TMP_ROOT/h-e2e"; new_home "$H"
  direct_push_blocker "$H" eb
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add eb "blocker" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add ew "waiter" >/dev/null
  live_waiter "$H" ew
  FM_LAND_AFTER_INTERVAL=0.2 la "$H" register ew --after eb >/dev/null || fail "e2e register failed"
  pe "$H" reconcile >/dev/null
  sleep 1
  assert_equals 0 "$(inbox_count "$H" ew)" "nothing is steered while the blocker is unlanded"
  push_blocker "$H" eb
  for _ in $(seq 1 150); do
    first_result "$H" when-land-after-eb >/dev/null && break
    sleep 0.1
  done
  result=$(first_result "$H" when-land-after-eb)
  [ -n "$result" ] || fail "the landing watch produced no outcome"
  assert_equals fired "$(FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" classify "$result")" \
    "the watch fires once the blocker lands"
  assert_equals 1 "$(inbox_count "$H" ew)" "the waiter receives exactly one steer"
  pass "end to end: the blocker landing steers the waiter once"

  H="$TMP_ROOT/h-e2e-fail"; new_home "$H"
  fm_write_meta "$H/state/fb.meta" "kind=ship" "mode=no-mistakes"
  printf 'failed [at=1]: gave up\n' > "$H/state/fb.status"
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add fb "blocker" >/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add fw "waiter" >/dev/null
  live_waiter "$H" fw
  FM_LAND_AFTER_INTERVAL=0.1 la "$H" register fw --after fb >/dev/null || fail "failed-blocker register failed"
  pe "$H" reconcile >/dev/null
  for _ in $(seq 1 150); do
    first_result "$H" when-land-after-fb >/dev/null && break
    sleep 0.1
  done
  result=$(first_result "$H" when-land-after-fb)
  [ -n "$result" ] || fail "the failed-blocker watch produced no outcome"
  assert_equals condition-error "$(FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" classify "$result")" \
    "a failed blocker ends the watch with a condition error"
  assert_grep 'gave up' "$result" "the outcome carries the blocker's failure"
  for _ in $(seq 1 100); do
    grep -q 'procevent when when-land-after-fb' "$H/state/.wake-queue" 2>/dev/null && break
    sleep 0.1
  done
  assert_grep 'procevent when when-land-after-fb' "$H/state/.wake-queue" "firstmate is woken"
  assert_equals 0 "$(inbox_count "$H" fw)" "a failed blocker steers no one"
  pass "end to end: a failed blocker wakes firstmate and steers no one"

  FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add fw2 "new waiter" >/dev/null
  live_waiter "$H" fw2
  out=$(la "$H" register fw2 --after fb); rc=$?
  expect_code 0 "$rc" "a new waiter after a proven terminal outcome re-arms the watch"
  assert_contains "$out" "re-arming ended watch" "automatic re-arm is announced"
  assert_grep 'condition-error' "$H/state/land-after/fb/watch-rearmed" "re-arm records the retired outcome"
  out=$(la "$H" register fw2 --after fb); rc=$?
  expect_code 0 "$rc" "the old terminal result cannot retire a fresh generation"
  assert_contains "$out" "already armed" "the re-armed generation shares its fresh watch"
  assert_equals 0 "$(inbox_count "$H" fw2)" "a failed blocker never steers the new waiter"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire land-after-fb >/dev/null
  pass "register: proven terminal watch is re-armed with a result cursor"
else
  printf 'SKIP: tasks-axi is not installed; register and end-to-end cases skipped\n'
fi
