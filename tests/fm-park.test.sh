#!/usr/bin/env bash
# Behavior tests for bin/fm-park.sh: the handoff validator, park idempotence,
# automatic resume when the wait condition holds, the supervisor wake on a
# deadline or failed relaunch, and the self-park detached exit. A fake control
# plane stands in for the harness endpoint (FM_PARK_CONTROL_OVERRIDE) and logs
# every lifecycle verb it receives, so no agent, terminal, or worktree is
# touched; the condition watch is the real bin/fm-procevent-when.sh runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-park-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
PARK="$ROOT/bin/fm-park.sh"

CONTROL="$TMP_ROOT/fake-control.sh"
cat > "$CONTROL" <<'SH'
#!/usr/bin/env bash
# Fake fm-control.sh: log the call; FAKE_CONTROL_FAIL=<verb> makes that verb fail.
printf '%s\n' "$*" >> "$FAKE_CONTROL_LOG"
[ "${FAKE_CONTROL_FAIL:-}" != "$2" ] || { echo "fake $2 failure" >&2; exit 1; }
echo "fake $2 ok"
SH
chmod +x "$CONTROL"

# new_task <home> <id>: a ship task record with a PR at its tail, plus a
# worktree holding an uncommitted change that parking must never touch.
new_task() {
  local home=$1 id=$2
  mkdir -p "$home/state" "$home/data" "$home/wt-$id"
  fm_test_track_procevent_home "$home"
  printf 'uncommitted work\n' > "$home/wt-$id/scratch.txt"
  fm_write_meta "$home/state/$id.meta" "window=fm:fm-$id" "worktree=$home/wt-$id" \
    "kind=ship" "harness=claude" "pr=https://github.com/example/repo/pull/7"
  printf 'working [at=1]: started\n' > "$home/state/$id.status"
}

handoff() {  # <file> <condition>
  cat > "$1" <<EOF
# Handoff
## Goal
Land the analysis.
## Done
- queued the run
## Waiting for
The run output: \`$2\`
## Next steps
- read the results and write the report
EOF
}

park() { (cd "$TMP_ROOT" && FM_HOME="$1" FAKE_CONTROL_LOG="$1/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" "$PARK" "${@:2}"); }
meta_count() { grep -c "^$2=" "$1" || true; }
last_line() { tail -n 1 "$1"; }

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && { printf '%s\n' "$g"; return 0; }
  done
  return 1
}

wait_for_result() {  # <home> <source-id>
  for _ in $(seq 1 200); do
    first_result "$1" "$2" >/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_for_wake() {  # <home> <source-id>: the outcome reached the durable wake queue
  for _ in $(seq 1 100); do
    grep -F "procevent when $2 " "$1/state/.wake-queue" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# start_watch <home>: launch the registered runners with the fake control plane
# in their environment, as the watcher's reconcile would.
start_watch() {
  FM_HOME="$1" FAKE_CONTROL_LOG="$1/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
}

# --- handoff validation ------------------------------------------------------
H="$TMP_ROOT/h-validate"; mkdir -p "$H/state"
handoff "$TMP_ROOT/good.md" "file:/tmp/results.json"
out=$(FM_HOME="$H" "$PARK" validate "$TMP_ROOT/good.md") || fail "a complete handoff was refused"
assert_contains "$out" "file:/tmp/results.json" "validate reads the condition from Waiting for"
printf '## Goal\nship it\n## Done\n\n## Waiting for\nlater\n' > "$TMP_ROOT/bad.md"
if FM_HOME="$H" "$PARK" validate "$TMP_ROOT/bad.md" 2>"$TMP_ROOT/bad.err"; then
  fail "an incomplete handoff was accepted"
fi
assert_grep 'section "done" is missing or empty' "$TMP_ROOT/bad.err" "validate names the empty Done section"
assert_grep 'section "next steps" is missing or empty' "$TMP_ROOT/bad.err" "validate names the missing Next steps section"
assert_grep '"Waiting for" names no condition' "$TMP_ROOT/bad.err" "validate requires a machine-checkable condition"
if FM_HOME="$H" "$PARK" validate "$TMP_ROOT/good.md" --when file:/elsewhere 2>"$TMP_ROOT/when.err"; then
  fail "a --when condition absent from the handoff was accepted"
fi
assert_grep "does not name the --when condition" "$TMP_ROOT/when.err" "validate ties --when to the handoff"
handoff "$TMP_ROOT/rel.md" "file:relative/path"
if FM_HOME="$H" "$PARK" validate "$TMP_ROOT/rel.md" 2>"$TMP_ROOT/rel.err"; then
  fail "a relative file: condition was accepted"
fi
assert_grep "absolute path" "$TMP_ROOT/rel.err" "validate refuses a relative file: condition"
cat > "$TMP_ROOT/word.md" <<'EOF'
## Goal
g
## Done
d
## Waiting for
nightly profile: fast
the run: `file:/data/run/results.json`
## Next steps
n
EOF
out=$(FM_HOME="$H" "$PARK" validate "$TMP_ROOT/word.md" 2>&1) || fail "a kind inside a word hid the real condition: $out"
assert_contains "$out" "file:/data/run/results.json" "validate prefers the backticked condition over a word containing a kind"
pass "the handoff validator requires every section and one well-formed condition"

# --- park refuses a missing handoff and leaves the agent running --------------
H="$TMP_ROOT/h-refuse"; new_task "$H" t1
if park "$H" t1 --handoff "$TMP_ROOT/missing.md" 2>"$TMP_ROOT/refuse.err"; then
  fail "park accepted a missing handoff"
fi
assert_grep "missing or unreadable" "$TMP_ROOT/refuse.err" "park names the missing handoff"
assert_absent "$H/control.log" "a refused park never touched the agent"
assert_absent "$H/state/procevent/when-park-t1.source" "a refused park armed no watch"
pass "park refuses a missing handoff without stopping anything"

# --- park records, arms, declares the wait, and stops the agent; re-park re-arms
H="$TMP_ROOT/h-park"; new_task "$H" t2
handoff "$TMP_ROOT/t2.md" "file:$TMP_ROOT/t2-results"
out=$(park "$H" t2 --handoff "$TMP_ROOT/t2.md" --deadline 2099-01-01T00:00Z) || fail "park failed: $out"
assert_present "$H/data/t2/handoff.md" "park installs the handoff in the task's data directory"
assert_grep "park_state=parked" "$H/state/t2.meta" "park records the parked state"
assert_grep "park_when=file:$TMP_ROOT/t2-results" "$H/state/t2.meta" "park records the condition"
assert_grep "park_deadline=2099-01-01T00:00:00Z" "$H/state/t2.meta" "park records the deadline"
assert_equals "pr=https://github.com/example/repo/pull/7" "$(last_line "$H/state/t2.meta")" "the PR stays the record's tail"
assert_present "$H/state/procevent/when-park-t2.source" "park arms the resume watch"
assert_contains "$(last_line "$H/state/t2.status")" "paused [at=" "park declares the wait"
assert_contains "$(last_line "$H/state/t2.status")" "until 2099-01-01T00:00:00Z" "the declared wait carries the deadline"
assert_equals "t2 exit" "$(cat "$H/control.log")" "park stops the agent through the control plane exit"
assert_equals "uncommitted work" "$(cat "$H/wt-t2/scratch.txt")" "park never touches the worktree"
handoff "$TMP_ROOT/t2b.md" "file:$TMP_ROOT/t2-other"
park "$H" t2 --handoff "$TMP_ROOT/t2b.md" >/dev/null || fail "re-parking an already parked task failed"
assert_equals 1 "$(meta_count "$H/state/t2.meta" park_state)" "re-park keeps one park record"
assert_grep "park_when=file:$TMP_ROOT/t2-other" "$H/state/t2.meta" "re-park records the new condition"
assert_equals 1 "$(find "$H/state/procevent" -name 'when-park-t2*.source' | wc -l | tr -d ' ')" "re-park keeps one watch"
assert_grep "file:$TMP_ROOT/t2-other" "$H/state/when/when-park-t2.spec" "re-park re-arms the watch on the new condition"
out=$(park "$H" cancel t2) || fail "cancel failed: $out"
assert_grep "park_state=cancelled" "$H/state/t2.meta" "cancel marks the record"
assert_absent "$H/state/procevent/when-park-t2.source" "cancel retires the watch"
pass "park records, arms, declares, and stops; a second park re-arms instead of duplicating"

# --- the condition relaunches the task with the handoff and a results pointer --
H="$TMP_ROOT/h-resume"; new_task "$H" t3
handoff "$TMP_ROOT/t3.md" "file:$TMP_ROOT/t3-results"
FM_PARK_INTERVAL=0.1 FM_PARK_STABLE=1 park "$H" t3 --handoff "$TMP_ROOT/t3.md" >/dev/null || fail "park t3 failed"
: > "$TMP_ROOT/t3-results"
start_watch "$H"
wait_for_result "$H" when-park-t3 || fail "the resume watch produced no outcome"
res=$(first_result "$H" when-park-t3)
assert_equals fired "$("$ROOT/bin/fm-procevent-when.sh" classify "$res")" "the watch fired the resume"
relaunch=$(grep '^t3 relaunch' "$H/control.log") || fail "resume did not relaunch the task: $(cat "$H/control.log")"
note=${relaunch##* }
assert_grep "$H/data/t3/handoff.md" "$note" "the relaunch note points at the handoff"
assert_grep "the results are at $TMP_ROOT/t3-results" "$note" "the relaunch note points at the results"
assert_grep "park_state=resumed" "$H/state/t3.meta" "resume records the relaunch"
assert_contains "$(last_line "$H/state/t3.status")" "working [at=" "resume ends the declared wait"
assert_equals "uncommitted work" "$(cat "$H/wt-t3/scratch.txt")" "resume never touches the worktree"
pass "the condition relaunches the parked task as a fresh session with its handoff"

# --- the resumed session parks again at once ------------------------------------
wait_for_wake "$H" when-park-t3 || fail "the resume did not reach the wake queue"
handoff "$TMP_ROOT/t3b.md" "file:$TMP_ROOT/t3-next"
out=$(park "$H" t3 --handoff "$TMP_ROOT/t3b.md" 2>&1) || fail "re-parking a resumed task failed: $out"
assert_present "${res%.result}.handled" "re-park acknowledges the resume that started this session"
assert_grep "park_state=parked" "$H/state/t3.meta" "re-park records the new park"
assert_grep "file:$TMP_ROOT/t3-next" "$H/state/when/when-park-t3.spec" "re-park arms the watch on the new condition"
pass "a resumed task can park again without waiting for the supervisor"

# --- a failed relaunch wakes the supervisor and keeps the record --------------
H="$TMP_ROOT/h-fail"; new_task "$H" t4
handoff "$TMP_ROOT/t4.md" "file:$TMP_ROOT/t4-results"
FM_PARK_INTERVAL=0.1 FM_PARK_STABLE=1 park "$H" t4 --handoff "$TMP_ROOT/t4.md" >/dev/null || fail "park t4 failed"
: > "$TMP_ROOT/t4-results"
FAKE_CONTROL_FAIL=relaunch start_watch "$H"
wait_for_result "$H" when-park-t4 || fail "the failing resume produced no outcome"
res=$(first_result "$H" when-park-t4)
assert_equals action-failed "$("$ROOT/bin/fm-procevent-when.sh" classify "$res")" "a failed relaunch is an action failure"
assert_grep "could not be relaunched" "$res" "the outcome carries the relaunch error"
assert_grep "park_state=resume-failed" "$H/state/t4.meta" "the record says the resume failed"
assert_grep "park_handoff=$H/data/t4/handoff.md" "$H/state/t4.meta" "the record keeps the handoff"
wait_for_wake "$H" when-park-t4 || fail "the failure did not wake the supervisor"
pass "a failed relaunch wakes the supervisor and leaves the park record intact"

# --- a deadline with no result wakes the supervisor instead of relaunching ----
H="$TMP_ROOT/h-deadline"; new_task "$H" t5
handoff "$TMP_ROOT/t5.md" "file:$TMP_ROOT/t5-never"
deadline=$(date -u -d "@$(( $(date +%s) + 2 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -r "$(( $(date +%s) + 2 ))" +%Y-%m-%dT%H:%M:%SZ)
FM_PARK_INTERVAL=0.2 park "$H" t5 --handoff "$TMP_ROOT/t5.md" --deadline "$deadline" >/dev/null || fail "park t5 failed"
start_watch "$H"
wait_for_result "$H" when-park-t5 || fail "the deadline produced no outcome"
res=$(first_result "$H" when-park-t5)
assert_equals never-true "$("$ROOT/bin/fm-procevent-when.sh" classify "$res")" "the deadline ends the watch"
assert_no_grep "relaunch" "$H/control.log" "a deadline never relaunches"
wait_for_wake "$H" when-park-t5 || fail "the deadline did not wake the supervisor"
assert_grep "park_state=parked" "$H/state/t5.meta" "the record still says parked for the supervisor to decide"
if park "$H" t5 --handoff "$TMP_ROOT/t5.md" 2>"$TMP_ROOT/t5.err"; then
  fail "re-park acknowledged a deadline outcome that belongs to the supervisor"
fi
assert_absent "${res%.result}.handled" "re-park leaves a non-fired outcome unhandled"
pass "a deadline without the result wakes the supervisor instead of relaunching"

# --- a worker parking itself returns before its session is stopped ------------
H="$TMP_ROOT/h-self"; new_task "$H" t6
handoff "$TMP_ROOT/t6.md" "file:$TMP_ROOT/t6-results"
out=$(cd "$H/wt-t6" && FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
  FM_PARK_SELF_EXIT_DELAY=0 "$PARK" t6 --handoff "$TMP_ROOT/t6.md") || fail "self-park failed: $out"
assert_contains "$out" "this session stops in a few seconds" "self-park returns before stopping its own session"
for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
assert_equals "t6 exit" "$(cat "$H/control.log" 2>/dev/null)" "the detached exit stops the session"
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t6 >/dev/null 2>&1 || true
pass "a worker parking itself gets a detached exit"

# --- self-park is recognized by FM_TASK_ID from outside the worktree ----------
H="$TMP_ROOT/h-selfid"; new_task "$H" t7
handoff "$TMP_ROOT/t7.md" "file:$TMP_ROOT/t7-results"
out=$(cd "$TMP_ROOT" && FM_TASK_ID=t7 FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
  FM_PARK_SELF_EXIT_DELAY=0 "$PARK" t7 --handoff "$TMP_ROOT/t7.md") || fail "self-park by task id failed: $out"
assert_contains "$out" "this session stops in a few seconds" "a worker outside its worktree still self-parks"
for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
assert_equals "t7 exit" "$(cat "$H/control.log" 2>/dev/null)" "the detached exit stops the session"
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t7 >/dev/null 2>&1 || true
pass "FM_TASK_ID marks a self-park wherever the worker's shell is"

# --- a failed detached exit wakes the supervisor ------------------------------
H="$TMP_ROOT/h-selffail"; new_task "$H" t8
handoff "$TMP_ROOT/t8.md" "file:$TMP_ROOT/t8-results"
out=$(cd "$H/wt-t8" && FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
  FAKE_CONTROL_FAIL=exit FM_PARK_SELF_EXIT_DELAY=0 "$PARK" t8 --handoff "$TMP_ROOT/t8.md") || fail "self-park t8 failed: $out"
for _ in $(seq 1 100); do grep -q '^blocked' "$H/state/t8.status" && break; sleep 0.1; done
assert_contains "$(last_line "$H/state/t8.status")" "blocked [at=" "a failed detached exit appends a blocked line"
assert_contains "$(last_line "$H/state/t8.status")" "$H/data/t8/park-exit.log" "the blocked line names the exit log"
assert_grep "fake exit failure" "$H/data/t8/park-exit.log" "the exit log keeps the failure"
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t8 >/dev/null 2>&1 || true
pass "a self-park whose exit fails wakes the supervisor instead of idling silently"
