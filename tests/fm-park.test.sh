#!/usr/bin/env bash
# Behavior tests for bin/fm-park.sh: the handoff validator, park idempotence,
# automatic resume when the wait condition holds, the supervisor wake on a
# deadline or failed relaunch, the self-park detached exit, and the Claude
# self-park refusal while background shells still run. A fake control
# plane stands in for the harness endpoint (FM_PARK_CONTROL_OVERRIDE) and logs
# every lifecycle verb it receives, so no agent, terminal, or worktree is
# touched; the condition watch is the real bin/fm-procevent-when.sh runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-park-tests)
# A run from inside a Claude session must not see that session's own
# background shells; the fake agent below sets its own CLAUDE_PID.
unset CLAUDE_PID
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
    "kind=ship" "harness=claude" "spawn_gen=g1" "pr=https://github.com/example/repo/pull/7"
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
    [ -e "$g" ] && [ ! -e "${g%.result}.handled" ] && { printf '%s\n' "$g"; return 0; }
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
if FM_HOME="$H" "$PARK" validate "$TMP_ROOT/good.md" --when file:/tmp/results 2>"$TMP_ROOT/prefix.err"; then
  fail "a --when condition that is only a prefix of the handoff's was accepted"
fi
assert_grep "does not name the --when condition" "$TMP_ROOT/prefix.err" "validate matches --when exactly"
for bad in "cmd:./scripts/batch-done.sh" "pr-merged:https://gitlab.example.com/group/repo/-/merge_requests/3"; do
  handoff "$TMP_ROOT/bad-cond.md" "$bad"
  if FM_HOME="$H" "$PARK" validate "$TMP_ROOT/bad-cond.md" 2>/dev/null; then
    fail "an unwatchable condition was accepted: $bad"
  fi
done
for prose in "Results land at file:/data/run/123/results.json." "file:/data/run/123/results.json (ETA 2h)"; do
  printf '## Goal\ng\n## Done\nd\n## Waiting for\n%s\n## Next steps\nn\n' "$prose" > "$TMP_ROOT/prose.md"
  out=$(FM_HOME="$H" "$PARK" validate "$TMP_ROOT/prose.md" 2>&1) || fail "an unbackticked condition was refused: $out"
  assert_equals "handoff ok: waiting for file:/data/run/123/results.json" "$out" "an unbackticked file: condition ends at its path"
done
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

# Queue adoption may not fabricate a source or accept an unrelated condition.
H="$TMP_ROOT/h-adopt-refuse"; new_task "$H" tqueue
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
handoff "$TMP_ROOT/queue.md" "cmd:$ROOT/bin/fm-procevent-merge-queue.sh result-ready $head"
if park "$H" tqueue --handoff "$TMP_ROOT/queue.md" --adopt-merge-queue "$head" 2>"$TMP_ROOT/adopt.err"; then
  fail "queue adoption accepted an absent source"
fi
assert_absent "$H/control.log" "refused adoption leaves the worker running"
assert_no_grep "park_state=" "$H/state/tqueue.meta" "refused adoption records no park"
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register merge-queue "merge-queue-tqueue-aaaaaaaa" \
  -- "$ROOT/bin/fm-procevent-merge-queue.sh" watch tqueue "$head" >/dev/null || fail "could not seed the queue source"
handoff "$TMP_ROOT/queue.md" "file:$TMP_ROOT/unrelated"
if park "$H" tqueue --handoff "$TMP_ROOT/queue.md" --adopt-merge-queue "$head" 2>"$TMP_ROOT/adopt.err"; then
  fail "queue adoption accepted an unrelated condition"
fi
assert_absent "$H/control.log" "wrong condition cannot stop the worker"
assert_present "$H/state/procevent/merge-queue-tqueue-aaaaaaaa.source" "refused adoption preserves the existing source"
pass "queue park adoption requires its exact registered source and result condition"

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
assert_grep '^interval=30$' "$H/state/when/when-park-t2.spec" "a local wait is polled every 30 seconds, so it resumes within about a minute"
assert_contains "$(last_line "$H/state/t2.status")" "paused [at=" "park declares the wait"
assert_contains "$(last_line "$H/state/t2.status")" "until 2099-01-01T00:00:00Z" "the declared wait carries the deadline"
assert_equals "t2 exit" "$(cat "$H/control.log")" "park stops the agent through the control plane exit"
assert_equals "uncommitted work" "$(cat "$H/wt-t2/scratch.txt")" "park never touches the worktree"
handoff "$TMP_ROOT/t2b.md" "file:$TMP_ROOT/t2-other"
park "$H" t2 --handoff "$TMP_ROOT/t2b.md" >/dev/null || fail "re-parking an already parked task failed"
assert_equals 1 "$(meta_count "$H/state/t2.meta" park_state)" "re-park keeps one park record"
assert_grep "park_when=file:$TMP_ROOT/t2-other" "$H/state/t2.meta" "re-park records the new condition"
assert_equals 1 "$(find "$H/state/procevent" -name 'when-park-t2*.source' | wc -l | tr -d ' ')" "re-park keeps one watch"
token=$(sed -n 's/^park_token=//p' "$H/state/t2.meta")
: > "$TMP_ROOT/t2-results"
rc=0; park "$H" poll t2 "$token" || rc=$?
expect_code 1 "$rc" 'the old result satisfied the replacement wait'
: > "$TMP_ROOT/t2-other"
park "$H" poll t2 "$token" || fail 'the replacement result did not satisfy the re-armed wait'
out=$(park "$H" cancel t2) || fail "cancel failed: $out"
assert_grep "park_state=cancelled" "$H/state/t2.meta" "cancel marks the record"
assert_absent "$H/state/procevent/when-park-t2.source" "cancel retires the watch"
pass "park records, arms, declares, and stops; a second park re-arms instead of duplicating"

# --- the default poll cadence follows the condition kind ----------------------
H="$TMP_ROOT/h-cadence"; new_task "$H" tcmd; new_task "$H" tpr
handoff "$TMP_ROOT/tcmd.md" "cmd:true"
park "$H" tcmd --handoff "$TMP_ROOT/tcmd.md" >/dev/null || fail "park tcmd failed"
assert_grep '^interval=30$' "$H/state/when/when-park-tcmd.spec" "a cmd: wait is polled every 30 seconds"
handoff "$TMP_ROOT/tpr.md" "pr-merged:https://github.com/example/repo/pull/7"
park "$H" tpr --handoff "$TMP_ROOT/tpr.md" >/dev/null || fail "park tpr failed"
assert_grep '^interval=300$' "$H/state/when/when-park-tpr.spec" "a pr-merged: wait keeps the slower GitHub-friendly cadence"
FM_PARK_INTERVAL=7 park "$H" tcmd --handoff "$TMP_ROOT/tcmd.md" >/dev/null || fail "re-park tcmd failed"
assert_grep '^interval=7$' "$H/state/when/when-park-tcmd.spec" "FM_PARK_INTERVAL still overrides the default cadence"
pass "the resume watch polls local waits often enough to resume within about a minute"

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
out=$(FM_PARK_INTERVAL=0.1 FM_PARK_STABLE=1 park "$H" t3 --handoff "$TMP_ROOT/t3b.md" 2>&1) || fail "re-parking a resumed task failed: $out"
assert_present "${res%.result}.handled" "re-park acknowledges the resume that started this session"
assert_grep "park_state=parked" "$H/state/t3.meta" "re-park records the new park"
token=$(sed -n 's/^park_token=//p' "$H/state/t3.meta")
rc=0; park "$H" poll t3 "$token" || rc=$?
expect_code 1 "$rc" 'the completed earlier result satisfied the resumed task replacement wait'
: > "$H/control.log"
: > "$TMP_ROOT/t3-next"
start_watch "$H"
wait_for_result "$H" when-park-t3 || fail 'the replacement resume watch produced no new outcome'
next_res=$(first_result "$H" when-park-t3)
[ "$next_res" != "$res" ] || fail 'the earlier handled outcome masked the replacement resume'
assert_equals fired "$("$ROOT/bin/fm-procevent-when.sh" classify "$next_res")" 'the replacement condition did not fire its re-armed watch'
assert_equals 1 "$(grep -c '^t3 relaunch' "$H/control.log")" 'the replacement watch did not relaunch exactly once'
assert_grep "the results are at $TMP_ROOT/t3-next" "$H/data/t3/park-resume-note.md" 'the replacement resume used the earlier result'
pass "a resumed task can park again without waiting for the supervisor"

# --- a task relaunched since it parked is not relaunched again -----------------
H="$TMP_ROOT/h-superseded"; new_task "$H" t9
handoff "$TMP_ROOT/t9.md" "file:$TMP_ROOT/t9-results"
FM_PARK_INTERVAL=0.1 FM_PARK_STABLE=1 park "$H" t9 --handoff "$TMP_ROOT/t9.md" >/dev/null || fail "park t9 failed"
assert_grep "park_spawn_gen=g1" "$H/state/t9.meta" "park records the task's incarnation"
awk '{ sub(/^spawn_gen=g1$/, "spawn_gen=g2") } 1' "$H/state/t9.meta" > "$H/t9.meta" && mv "$H/t9.meta" "$H/state/t9.meta"
: > "$H/control.log"
: > "$TMP_ROOT/t9-results"
start_watch "$H"
wait_for_result "$H" when-park-t9 || fail "the superseded resume produced no outcome"
res=$(first_result "$H" when-park-t9)
assert_equals action-failed "$("$ROOT/bin/fm-procevent-when.sh" classify "$res")" "a superseded resume wakes the supervisor"
assert_grep "relaunched or respawned since it parked" "$res" "the outcome names why nothing was relaunched"
assert_no_grep "relaunch" "$H/control.log" "a superseded resume never replaces the live session"
assert_no_grep "^park_" "$H/state/t9.meta" "a superseded resume clears the park state"
wait_for_wake "$H" when-park-t9 || fail "the superseded resume did not reach the wake queue"
for _ in $(seq 1 100); do [ -e "$H/state/procevent/when-park-t9.source" ] || break; sleep 0.1; done
assert_absent "$H/state/procevent/when-park-t9.source" "the spent watch is disarmed"
pass "a task relaunched since it parked keeps its live session and the supervisor is told"

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

# --- a Claude worker with live background shells is refused before parking ----
# The fake agent stands in for the Claude process: it exports CLAUDE_PID as
# Claude does, holds an optional background shell child (a background Bash
# task or Monitor watch running a two-process pipeline), and runs the park from
# a foreground tool shell child. The background shell runs a script file so its
# own command line never names the pipeline's commands.
printf 'sleep 60 | sleep 61\n' > "$TMP_ROOT/fake-background.sh"
AGENT="$TMP_ROOT/fake-agent.sh"
cat > "$AGENT" <<'SH'
#!/usr/bin/env bash
# fake-agent.sh <with-background:0|1> <dir> <park args...>
export CLAUDE_PID=$$
bg=''
if [ "$1" = 1 ]; then
  bash "${0%/*}/fake-background.sh" &
  bg=$!
fi
dir=$2; shift 2
bash -c 'cd "$1" && shift && exec "$@"' tool-shell "$dir" "$@"
rc=$?
[ -z "$bg" ] || { pkill -P "$bg"; kill "$bg"; wait "$bg"; } 2>/dev/null
exit "$rc"
SH
chmod +x "$AGENT"
self_park_as_agent() {  # <home> <id> <with-background> <handoff> [harness]
  FM_HOME="$1" FAKE_CONTROL_LOG="$1/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" FM_PARK_SELF_EXIT_DELAY=0 \
    "$AGENT" "$3" "$1/wt-$2" "$PARK" "$2" --handoff "$4"
}

H="$TMP_ROOT/h-bg"; new_task "$H" t10
handoff "$TMP_ROOT/t10.md" "file:$TMP_ROOT/t10-results"
if self_park_as_agent "$H" t10 1 "$TMP_ROOT/t10.md" > "$TMP_ROOT/t10.out" 2>&1; then
  fail "a Claude self-park with a live background shell was accepted: $(cat "$TMP_ROOT/t10.out")"
fi
assert_grep "Background work is running" "$TMP_ROOT/t10.out" "the refusal names Claude's exit prompt"
assert_grep "sleep 60" "$TMP_ROOT/t10.out" "the refusal lists the background pipeline's first command"
assert_grep "sleep 61" "$TMP_ROOT/t10.out" "the refusal lists the background pipeline's second command"
assert_grep "Stop every background shell and Monitor watch" "$TMP_ROOT/t10.out" "the refusal tells the worker what to do"
assert_absent "$H/control.log" "a refused park never touched the agent"
assert_absent "$H/state/procevent/when-park-t10.source" "a refused park armed no watch"
assert_absent "$H/data/t10/handoff.md" "a refused park installed no handoff"
assert_no_grep "^park_" "$H/state/t10.meta" "a refused park recorded nothing"
out=$(self_park_as_agent "$H" t10 0 "$TMP_ROOT/t10.md" 2>&1) || fail "a Claude self-park with no background work failed: $out"
assert_contains "$out" "this session stops in a few seconds" "the same park succeeds once the background work is gone"
for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
assert_equals "t10 exit" "$(cat "$H/control.log" 2>/dev/null)" "the detached exit stops the session"
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t10 >/dev/null 2>&1 || true
pass "a Claude self-park refuses while background shells run and parks once they stop"

# --- other harnesses keep their park behavior ----------------------------------
H="$TMP_ROOT/h-bg-codex"; new_task "$H" t11
awk '{ sub(/^harness=claude$/, "harness=codex") } 1' "$H/state/t11.meta" > "$H/t11.meta" && mv "$H/t11.meta" "$H/state/t11.meta"
handoff "$TMP_ROOT/t11.md" "file:$TMP_ROOT/t11-results"
out=$(self_park_as_agent "$H" t11 1 "$TMP_ROOT/t11.md" 2>&1) || fail "a non-Claude self-park was refused: $out"
assert_contains "$out" "this session stops in a few seconds" "a non-Claude self-park is unaffected by background shells"
for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t11 >/dev/null 2>&1 || true
pass "the background-work refusal applies only to Claude workers"

# Saved work uses real Git objects, not a stubbed preservation verdict.
# shellcheck source=tests/suspend-helpers.sh
. "$ROOT/tests/suspend-helpers.sh"
dir=$(suspend_case "$TMP_ROOT" saved-park) || fail 'saved fixture failed'
id=saved-park; home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
[ ! -e "$home/config/park-release" ] || fail 'fixture unexpectedly enabled release'
suspend_lib "$dir" fm_suspend_enabled "$home/config" && fail 'release must default off'
printf 'o\nn\n' > "$home/config/park-release"
suspend_lib "$dir" fm_suspend_enabled "$home/config" && fail 'malformed multi-line switch enabled release'
printf 'on\n' > "$home/config/park-release"
suspend_lib "$dir" fm_suspend_enabled "$home/config" || fail 'per-home canary switch did not enable release'
suspend_lib "$dir" fm_suspend_record "$meta" 'park_when=file:/durable/result' 'wait_started_at=1000' || fail 'record update failed'
suspend_lib "$dir" fm_suspend_qualified "$meta" 87399 && fail 'release qualified before 24h'
suspend_lib "$dir" fm_suspend_qualified "$meta" 87400 || fail 'release failed to qualify at 24h'
suspend_lib "$dir" fm_suspend_record "$meta" 'park_open_ended=1' || fail 'record update failed'
suspend_lib "$dir" fm_suspend_qualified "$meta" 1000 || fail 'open-ended wait was not immediate'
suspend_lib "$dir" fm_suspend_record "$meta" 'park_open_ended=0' "park_when=inbox:$id" || fail 'record update failed'
suspend_lib "$dir" fm_suspend_qualified "$meta" 1000 || fail 'inbox wait was not immediate'
suspend_lib "$dir" fm_suspend_record "$meta" 'park_relocation_safe=0' || fail 'record update failed'
suspend_lib "$dir" fm_suspend_qualified "$meta" 999999 && fail 'age overrode missing relocation proof'
suspend_lib "$dir" fm_suspend_record "$meta" 'park_relocation_safe=1' || fail 'record update failed'
printf 'dirty\n' >> "$wt/file"
suspend_lib "$dir" fm_suspend_save "$meta" "$id" "$home" "$home/data" "$wt" && fail 'dirty work was saved for release'
assert_absent "$home/data/$id/suspension.json" 'dirty refusal created saved custody'
git -C "$wt" checkout -- file
printf 'cache\n' > "$wt/unknown"
printf 'unknown\n' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
suspend_lib "$dir" fm_suspend_clean_copy "$wt" && fail 'unknown ignored artifact qualified for return'
rm "$wt/unknown"
suspend_saved "$dir" "$id" || fail 'clean committed work did not save'
suspend_lib "$dir" fm_suspend_validate "$meta" "$id" "$home" "$home/data" || fail 'saved proof did not validate'
assert_present "$home/data/$id/suspension.bundle" 'unpublished head has no bundle'
head=$(git -C "$dir/project" rev-parse "fm/$id")
[ "$head" = "$(jq -r .head "$home/data/$id/suspension.json")" ] || fail 'saved branch head drifted'
FM_HOME="$home" "$PARK" check "inbox:$id" >/dev/null && fail 'ordinary inbox wait picked itself up'
mkdir -p "$home/state/$id.inbox/handled"
printf 'reminder, not authority\n' > "$home/state/$id.inbox/001.msg"
FM_HOME="$home" "$PARK" check "inbox:$id" >/dev/null && fail 'a reminder authorized pickup'
FM_HOME="$home" "$PARK" pickup "$id" || fail 'explicit pickup failed'
FM_HOME="$home" "$PARK" check "inbox:$id" || fail 'explicit pickup did not clear the wait'
assert_present "$home/state/$id.inbox/001.msg" 'condition consumed an ordinary inbox message'
printf 'tamper\n' >> "$home/data/$id/suspension.bundle"
suspend_lib "$dir" fm_suspend_validate "$meta" "$id" "$home" "$home/data" && fail 'bundle corruption validated'
pass 'copy-free qualification is off by default, uses continuous 24h/immediate policy, refuses dirty/unknown work and proves its saved head'

# Re-arm preserves continuous age, but genuine new work resets it.
H="$TMP_ROOT/h-age"; new_task "$H" age
handoff "$TMP_ROOT/age.md" "file:$TMP_ROOT/age-result"
park "$H" age --handoff "$TMP_ROOT/age.md" >/dev/null || fail 'age park failed'
awk '{sub(/^wait_started_at=.*/, "wait_started_at=1000")} 1' "$H/state/age.meta" > "$H/age-meta"
mv "$H/age-meta" "$H/state/age.meta"
park "$H" age --handoff "$TMP_ROOT/age.md" >/dev/null || fail 'age repark failed'
suspend_assert_matches '^wait_started_at=1000$' "$H/state/age.meta" 're-arming reset the continuous clock'
park "$H" resume age >/dev/null || fail 'retained age resume failed'
# Preserve existing captured-result acknowledgement rules; this manual resume
# did not generate a process-event result.
park "$H" age --handoff "$TMP_ROOT/age.md" >/dev/null || fail 'new work repark failed'
suspend_assert_no_match '^wait_started_at=1000$' "$H/state/age.meta" 'a completed wait retained its old age'
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-age >/dev/null 2>&1 || true
assert_equals 1 "$(grep -c '^wait_started_at=' "$H/state/age.meta")" 'continuous clock was duplicated on re-arm'
pass 'only the same uninterrupted condition retains its wait age'

# Portable end-to-end release: fake terminals/native leases, real preservation,
# locks and policy checks. No local test run is needed to exercise it in CI.
for scenario in off true nm raw dependency symlink route job bad-endpoint lease kill return reuse park stop poll; do
  id="release-$scenario"; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'release fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
  suspend_idle_terminal "$dir" "$id"
  [ "$scenario" = off ] || printf 'on\n' > "$home/config/park-release"
  case "$scenario" in
    true) : > "$dir/result"; suspend_lib "$dir" fm_suspend_record "$meta" "park_when=file:$dir/result" ;;
    nm) suspend_lib "$dir" fm_suspend_record "$meta" 'mode=no-mistakes' ;;
    raw) suspend_lib "$dir" fm_suspend_record "$meta" 'harness=custom-launch' ;;
    reuse) : > "$dir/reuse-after-return" ;;
    dependency) printf 'local input %s\n' "$wt/file" >> "$home/data/$id/handoff.md" ;;
    symlink)
      ln -s "$wt" "$home/apparently-durable-results"
      suspend_lib "$dir" fm_suspend_record "$meta" "park_when=file:$home/apparently-durable-results/missing-result" ;;
    route)
      mkdir -p "$home/state/task-inbox-routes"
      jq -n --arg id "$id" '{schema:"fm-task-milestone-route.v1",producer:{task:$id,generation:"g1"},consumer:{task:"other",generation:"g2"}}' > "$home/state/task-inbox-routes/route.json" ;;
    job) printf '[{"pid":12345678}]\n' > "$dir/processes.json" ;;
    bad-endpoint) suspend_lib "$dir" fm_suspend_record "$meta" 'window=malformed' ;;
    lease) printf '%s\n' "$$" > "$home/state/.lock"; printf 'branch\t%s\t1\n' "$$" > "$home/state/.lease-$id" ;;
    kill) : > "$dir/fail-kill" ;;
    return) : > "$dir/fail-return" ;;
  esac
  rc=0
  case "$scenario" in
    off|park)
      FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" suspend_park "$dir" "$id" --handoff "$home/data/$id/handoff.md" --relocation-safe > "$dir/out" 2>&1 || rc=$?
      fm_test_track_procevent_home "$home" ;;
    stop)
      FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" FM_PARK_SELF_EXIT_DELAY=0 suspend_park "$dir" stop "$id" > "$dir/out" 2>&1 || rc=$? ;;
    poll) suspend_park "$dir" poll "$id" p1 > "$dir/out" 2>&1 || rc=$? ;;
    *)
      suspend_register_release "$dir" "$id" || fail 'could not register release policy action'
      suspend_run_release "$dir" "$id" || fail "registered release runner failed: $(cat "$dir/runner.out")"
      rc=$(sed -n 's/^action_exit: //p' "$dir/action-result")
      rc=${rc:-0}; cp "$dir/action-result" "$dir/out" ;;
  esac
  case "$scenario" in
    reuse)
      expect_code 0 "$rc" "fresh successor prevented logical suspension: $(cat "$dir/out")"
      suspend_assert_matches '^copy_state=released$' "$meta" 'immediate reuse lost saved custody'
      suspend_assert_matches '^treehouse_lease_id=$' "$meta" 'historical lease remained active authority'
      assert_grep "home=$dir/foreign-home" "${wt%/*}/.fm-slot-owner" 'release erased a same-slug successor claim after returning its lease'
      assert_equals 'foreign uncommitted work' "$(cat "$wt/file")" 'release touched successor work'
      assert_equals successor-lease "$(jq -r .worktrees[0].lease_id "$dir/.treehouse/pool/treehouse-state.json")" 'release altered the successor native lease' ;;
    park)
      expect_code 0 "$rc" "park registration failed: $(cat "$dir/out")"
      suspend_assert_matches '^copy_state=retained$' "$meta" 'park performed expensive release before its action ran'
      assert_absent "$dir/calls" 'park/stop ran release inline'
      sid=$(sed -n 's/^park_release_source=//p' "$meta")
      [ -n "$sid" ] || fail 'park did not register its separate release source'
      suspend_run_release "$dir" "$id" || fail "release action runner failed: $(cat "$dir/runner.out")"
      assert_equals fired "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$dir/action-result")" "release action did not complete: $(cat "$dir/action-result")"
      suspend_assert_matches '^copy_state=released$' "$meta" "bounded action did not release"
      assert_grep 'return --if-lease-holder' "$dir/calls" 'release bypassed exact native return'
      suspend_lib "$dir" fm_suspend_validate "$meta" "$id" "$home" "$home/data" || fail 'released proof did not validate'
      assert_present "$home/data/$id/suspension.bundle" 'release discarded unlanded commits'
      rc=0; suspend_park "$dir" poll "$id" retired > "$dir/retired" 2>&1 || rc=$?
      expect_code 2 "$rc" 'retired poll token became authority'
      suspend_park "$dir" resume "$id" retired > "$dir/retired" 2>&1 && fail 'retired resume token became authority' ;;
    kill|return)
      expect_code 1 "$rc" 'failed close/return claimed success'
      suspend_assert_matches '^copy_state=release-prepared$' "$meta" 'interrupted release lost its transaction'
      suspend_assert_matches 'blocked.*copy-custody' "$home/state/$id.status" 'failed transaction did not wake its owner'
      rc=0; suspend_park "$dir" poll "$id" p1 > "$dir/interrupted" 2>&1 || rc=$?
      expect_code 1 "$rc" 'unfinished custody consumed the resume condition error budget'
      suspend_park "$dir" resume "$id" p1 > "$dir/interrupted" 2>&1 && fail 'unfinished custody resumed'
      assert_present "$home/data/$id/suspension.bundle" 'failed transaction lost saved work' ;;
    *)
      case "$scenario" in
        bad-endpoint) expect_code 1 "$rc" 'invalid endpoint was accepted for release' ;;
        lease) expect_code 6 "$rc" 'other supervision actor lease was ignored' ;;
        poll) expect_code 1 "$rc" 'ordinary inbox polling became an error/authority' ;;
        *) expect_code 0 "$rc" "qualification/stop was treated as failure: $(cat "$dir/out")" ;;
      esac
      if [ "$scenario" = bad-endpoint ] || [ "$scenario" = lease ]; then
        rc=0; suspend_park "$dir" poll "$id" p1 > "$dir/check-only" 2>&1 || rc=$?
        expect_code 1 "$rc" 'release refusal consumed the unrelated condition error budget'
      fi
      suspend_assert_matches '^copy_state=retained$' "$meta" 'unsafe/default-off park changed copy custody'
      assert_absent "$home/data/$id/suspension.json" 'failed qualification began a saved transaction'
      assert_absent "$dir/terminal-calls" 'failed qualification closed its endpoint'
      [ ! -e "$dir/calls" ] || suspend_assert_no_match '^return ' "$dir/calls" 'failed qualification returned a copy' ;;
  esac
  pass "portable park release: $scenario"
done

# Manual/tokenless entry cannot bypass the registered bounded action.
id=release-entrypoint; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'entrypoint fixture failed'
home="$dir/home"; meta="$home/state/$id.meta"
printf 'on\n' > "$home/config/park-release"
suspend_idle_terminal "$dir" "$id"
for entry in missing empty tokened; do
  rc=0
  case "$entry" in
    missing) suspend_park "$dir" release "$id" > "$dir/out" 2>&1 || rc=$? ;;
    empty) suspend_park "$dir" release "$id" '' > "$dir/out" 2>&1 || rc=$? ;;
    tokened) suspend_park "$dir" release "$id" p1 > "$dir/out" 2>&1 || rc=$? ;;
  esac
  [ "$rc" -ne 0 ] || fail 'manual/tokenless release bypassed action custody'
  assert_absent "$dir/calls" 'manual entry touched the native copy'
  suspend_assert_matches '^copy_state=retained$' "$meta" 'manual entry changed custody'
done
suspend_register_release "$dir" "$id" || fail 'entrypoint source registration failed'
suspend_lib "$dir" fm_suspend_record "$meta" 'park_exit_confirmed=' || fail 'could not model an unconfirmed stop'
rc=0; suspend_park "$dir" release-ready "$id" p1 || rc=$?
expect_code 1 "$rc" 'unconfirmed stop licensed a release action'
assert_absent "$dir/calls" 'missing stop receipt touched the copy'
# A stale callback remains inert even in the existing runner context, before
# the attempt claim; forging that context alone cannot bypass incarnation proof.
FM_PROCEVENT_IN_RUNNER=1 suspend_park "$dir" release "$id" retired > "$dir/out" 2>&1 || fail 'stale action was not inert'
suspend_assert_no_match '^park_release_attempt=p1$' "$meta" 'stale/unconfirmed action claimed current custody'
assert_absent "$dir/calls" 'stale/unconfirmed callback touched native custody'
suspend_park "$dir" cancel "$id" >/dev/null || fail 'could not retire entrypoint fixture'
pass 'every release needs a bounded runner, current token, verified stop and one-attempt claim'

# A short, relocation-safe wait resolves before the 24-hour release threshold.
# Resuming it must retire the optional release source even if it never fired.
id=resume-before-release; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'short resume fixture failed'
home="$dir/home"; meta="$home/state/$id.meta"
suspend_idle_terminal "$dir" "$id"; printf 'on\n' > "$home/config/park-release"
handoff "$dir/handoff.md" "file:$dir/result"
FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" suspend_park "$dir" "$id" --handoff "$dir/handoff.md" --relocation-safe > "$dir/out" 2>&1 || fail 'short park failed'
fm_test_track_procevent_home "$home"
sid=$(sed -n 's/^park_release_source=//p' "$meta"); token=$(sed -n 's/^park_token=//p' "$meta")
[ -n "$sid" ] || fail 'short qualified park had no release source'
rc=0; suspend_park "$dir" release-ready "$id" "$token" || rc=$?
expect_code 1 "$rc" 'short wait released before qualification'
: > "$dir/result"
FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" suspend_park "$dir" resume "$id" "$token" > "$dir/out" 2>&1 || fail 'short park did not resume'
suspend_assert_matches '^park_state=resumed$' "$meta" 'short wait did not record resumption'
suspend_assert_matches '^park_release_source=$' "$meta" 'resumption retained an obsolete source pointer'
assert_absent "$home/state/procevent/$sid.source" 'resumption orphaned an unqualified release source until its deadline'
assert_absent "$home/state/when/$sid.spec" 'resumption left the release condition runnable'
assert_absent "$dir/calls" 'short resumption unnecessarily touched native copy custody'
rc=0; suspend_park "$dir" release-ready "$id" "$token" || rc=$?
expect_code 2 "$rc" 'a retired release incarnation kept answering not-yet'
pass 'resumption before release qualification retires the optional source and rejects its stale incarnation'

# Timeout belongs to the action, not the cheap condition. An injected slow
# native close occurs after real saved-custody preparation; the standard when
# runner must immediately capture failure and the release must clean its locks.
# Keep the same five-second envelope/assertion: the release's own shorter work
# deadline, not an outer TERM trap or an extra test delay, must provide cleanup.
id=release-timeout; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'timeout fixture failed'
home="$dir/home"; meta="$home/state/$id.meta"
suspend_idle_terminal "$dir" "$id"
printf 'on\n' > "$home/config/park-release"; : > "$dir/slow-kill"
FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" FM_PARK_RELEASE_TIMEOUT=5 suspend_park "$dir" "$id" --handoff "$home/data/$id/handoff.md" --relocation-safe > "$dir/out" 2>&1 || fail 'timeout park registration failed'
fm_test_track_procevent_home "$home"
sid=$(sed -n 's/^park_release_source=//p' "$meta"); token=$(sed -n 's/^park_token=//p' "$meta")
# Readiness and ordinary condition checks must not invoke even one native call.
suspend_park "$dir" release-ready "$id" "$token" || fail 'stopped long wait was not action-ready'
rc=0; suspend_park "$dir" poll "$id" "$token" || rc=$?
expect_code 1 "$rc" 'cheap poll ignored its unresolved condition'
assert_absent "$dir/calls" 'cheap condition executed expensive custody'
suspend_run_release "$dir" "$id" || fail "bounded action did not capture its outcome: $(cat "$dir/runner.out")"
assert_equals action-failed "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$dir/action-result")" 'timeout poisoned the condition budget instead of producing an action failure'
suspend_assert_matches '^copy_state=release-prepared$' "$meta" "injected native timeout did not preserve prepared custody: $(cat "$dir/action-result")"
suspend_assert_matches 'blocked.*copy-custody' "$home/state/$id.status" 'prepared interruption did not immediately notify the owner'
assert_absent "$home/state/.control-$id.lock" 'interrupted action left its control lock held'
meta_lock=$(suspend_lib "$dir" fm_meta_lock_path "$meta")
project_lock=$(suspend_lib "$dir" fm_treehouse_project_lock_path "$dir/project")
assert_absent "$meta_lock" 'interrupted action left its metadata lock held'
assert_absent "$project_lock" 'interrupted action left its allocation lock held'
count=$(wc -l < "$dir/calls")
SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" run "$sid" > "$dir/retry-result" || fail 'claimed-action read failed'
assert_equals ambiguous "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$dir/retry-result")" 'the same action was executed twice'
assert_equals "$count" "$(wc -l < "$dir/calls")" 'a claimed release repeated native custody'
suspend_assert_matches "^park_release_notified=$token$" "$meta" 'ordinary cleanup did not publish its notification receipt'
cp "$meta" "$dir/meta-notified"
rc=0; suspend_park "$dir" poll "$id" "$token" || rc=$?
expect_code 1 "$rc" 'prepared custody interruption poisoned resume polling'
suspend_park "$dir" resume "$id" "$token" > "$dir/resume" 2>&1 && fail 'interrupted custody resumed automatically'
FM_HOME="$home" "$ROOT/bin/fm-control.sh" "$id" relaunch --note continue > "$dir/control" 2>&1 && fail 'ordinary notified failure restored uncertain custody'
assert_equals 1 "$(grep -c 'blocked.*copy-custody' "$home/state/$id.status")" 'ordinary notification receipt did not suppress contradictory backstop alerts'
suspend_assert_no_match 'release attempt interrupted; custody uncertain' "$home/state/$id.status" 'ordinary live-parent cleanup was relabeled as a hard kill'
cmp -s "$meta" "$dir/meta-notified" || fail 'receipt deduplication changed prepared custody'
assert_equals "$count" "$(wc -l < "$dir/calls")" 'receipt deduplication retried native custody'
suspend_park "$dir" cancel "$id" || fail 'could not retire interrupted copy release'
assert_absent "$home/state/procevent/$sid.source" 'cancellation orphaned its release source'
pass 'release is separately bounded/claimed and interruption is immediate, lock-clean and isolated from the wait condition budget'

# Ordinary save refusals are not action failures. Inject only the save step;
# qualification/ownership must still run, and original custody stays retained.
for refusal in profile branch mktemp jq rev-parse; do
  id="release-save-refusal-$refusal"; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'save refusal fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
  suspend_idle_terminal "$dir" "$id"
  printf 'on\n' > "$home/config/park-release"
  printf '%s\n' "$refusal" > "$dir/save-refusal"
  case "$refusal" in
    profile) suspend_lib "$dir" fm_suspend_record "$meta" 'harness=pi-custom-wrapper' || fail 'unsupported profile injection failed' ;;
    branch) suspend_lib "$dir" fm_suspend_record "$meta" 'branch=fm/not-the-saved-branch' || fail 'branch mismatch injection failed' ;;
  esac
  command -v git > "$dir/real-git"
  command -v mktemp > "$dir/real-mktemp"
  command -v jq > "$dir/real-jq"
  cat > "$dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "$SUSPEND_DIR/save-refusal")" = rev-parse ]; then
  case "$*" in *'rev-parse --verify HEAD') exit 1 ;; esac
fi
exec "$(cat "$SUSPEND_DIR/real-git")" "$@"
SH
  cat > "$dir/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "$SUSPEND_DIR/save-refusal")" = mktemp ]; then
  case "$*" in *'.suspend-save.'*) exit 1 ;; esac
fi
exec "$(cat "$SUSPEND_DIR/real-mktemp")" "$@"
SH
  cat > "$dir/fakebin/jq" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "$SUSPEND_DIR/save-refusal")" = jq ]; then
  case "$*" in *'--arg k project'*) exit 1 ;; esac
fi
exec "$(cat "$SUSPEND_DIR/real-jq")" "$@"
SH
  chmod +x "$dir/fakebin/git" "$dir/fakebin/mktemp" "$dir/fakebin/jq"
  suspend_register_release "$dir" "$id" || fail 'ordinary refusal registration failed'
  suspend_run_release "$dir" "$id" || fail 'ordinary refusal result was not captured'
  assert_equals fired "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$dir/action-result")" "ordinary $refusal save refusal escalated as action-failed"
  suspend_assert_matches '^copy_retain_reason=saved-work proof unavailable before preparation;' "$meta" 'ordinary save refusal lost its durable reason'
  suspend_assert_matches '^copy_state=retained$' "$meta" 'ordinary refusal invented prepared custody'
  suspend_assert_matches '^park_state=parked$' "$meta" 'ordinary refusal changed its wait'
  suspend_assert_matches '^treehouse_lease_id=old-lease$' "$meta" 'ordinary refusal lost native acquisition'
  assert_equals "fm/$id" "$(git -C "$wt" symbolic-ref --short HEAD)" 'ordinary refusal detached/changed the work branch'
  assert_equals 'unlanded saved work' "$(cat "$wt/file")" 'ordinary refusal changed work'
  assert_present "${wt%/*}/.fm-slot-owner" 'ordinary refusal erased its reservation'
  assert_absent "$dir/terminal-calls" 'ordinary refusal closed its endpoint'
  suspend_assert_no_match '^return ' "$dir/calls" 'ordinary refusal returned the copy'
  suspend_assert_no_match 'blocked.*copy-release-timeout' "$home/state/$id.status" 'ordinary refusal was mislabeled a deadline'
  assert_absent "$home/state/.control-$id.lock" 'ordinary refusal stranded lifecycle control'
  assert_absent "$home/state/.meta-$id.lock" 'ordinary refusal stranded metadata'
  assert_absent "$(suspend_lib "$dir" fm_treehouse_project_lock_path "$dir/project")" 'ordinary refusal stranded allocation'
  pass "ordinary $refusal save refusal records why the same wait/copy/lease/work remain intact"
done

# Every timed preparation step can consume the budget, not only bundle/import.
# Expiry must fail the action, retain custody and clean locks, never masquerade
# as dirty/job/evidence qualification or reach return/endpoint close.
for step in bundle import clean quiet evidence; do
  id="release-save-timeout-$step"; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'save deadline fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
  suspend_idle_terminal "$dir" "$id"; printf 'on\n' > "$home/config/park-release"
  command -v git > "$dir/real-git"
  printf '%s\n' "$step" > "$dir/slow-git-kind"
  cat > "$dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$(cat "$SUSPEND_DIR/slow-git-kind"): $* " in
  bundle:*' bundle create '*|import:*' fetch -q '*|clean:*' status --porcelain '*) /bin/sleep 8 ;;
esac
exec "$(cat "$SUSPEND_DIR/real-git")" "$@"
SH
  chmod +x "$dir/fakebin/git"
  if [ "$step" = quiet ]; then
    mv "$dir/fakebin/treehouse" "$dir/quick-treehouse"
    cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case " $* " in *' status --json '*) /bin/sleep 8 ;; esac
exec "$SUSPEND_DIR/quick-treehouse" "$@"
SH
    chmod +x "$dir/fakebin/treehouse"
  fi
  if [ "$step" = evidence ]; then
    command -v find > "$dir/real-find"
    cat > "$dir/fakebin/find" <<'SH'
#!/usr/bin/env bash
case "${1-}" in "$SUSPEND_DIR"/home/data/*) /bin/sleep 8 ;; esac
exec "$(cat "$SUSPEND_DIR/real-find")" "$@"
SH
    chmod +x "$dir/fakebin/find"
  fi
  FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" FM_PARK_RELEASE_TIMEOUT=5 suspend_park "$dir" "$id" --handoff "$home/data/$id/handoff.md" --relocation-safe > "$dir/out" 2>&1 || fail 'save deadline park failed'
  fm_test_track_procevent_home "$home"
  suspend_run_release "$dir" "$id" || fail 'save deadline result was not captured'
  assert_equals action-failed "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$dir/action-result")" 'save timeout was reported as a completed release'
  suspend_assert_matches 'blocked.*copy-release-timeout' "$home/state/$id.status" 'save timeout missed its immediate retained-work notification'
  suspend_assert_matches '^copy_state=retained$' "$meta" 'partial saved proof became release-prepared custody'
  assert_equals 'unlanded saved work' "$(cat "$wt/file")" 'save timeout changed committed work'
  assert_present "${wt%/*}/.fm-slot-owner" 'save timeout lost the old protected acquisition'
  assert_absent "$dir/terminal-calls" 'save timeout closed the protected endpoint'
  if [ -e "$dir/calls" ]; then
    suspend_assert_no_match '^return ' "$dir/calls" 'preparation timeout returned incomplete saved custody'
  fi
  suspend_assert_no_match '^copy_retain_reason=(typed route|declared evidence)' "$meta" 'deadline was mislabeled as unsafe work/job/evidence'
  assert_absent "$home/state/.control-$id.lock" 'save deadline stranded the control lock'
  assert_absent "$home/state/.meta-$id.lock" 'save deadline stranded the metadata lock'
  assert_absent "$(suspend_lib "$dir" fm_treehouse_project_lock_path "$dir/project")" 'save deadline stranded the project lock'
  pass "internal $step deadline retains unsaved copy and cleans locks before the outer action envelope"
done

# A hard kill cannot run traps, and a separately grouped child may survive.
# The next listener/restore entry only notifies uncertainty: it must preserve
# every lock/record/lease/copy without cleanup or native retry.
for entry in poll resume control; do
  id="release-hard-kill-$entry"; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'hard-kill fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
  suspend_lib "$dir" fm_suspend_save "$meta" "$id" "$home" "$home/data" "$wt" || fail 'could not prepare saved custody'
  rc=0
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-suspend-lib.sh"
    fm_current_pid attempt
    fm_lock_try_acquire "$STATE/.fm-lease-command.lock" || exit 2
    fm_lock_try_acquire "$STATE/.control-$2.lock" || exit 2
    fm_lock_try_acquire "$(fm_meta_lock_path "$STATE/$2.meta")" || exit 2
    fm_lock_try_acquire "$(fm_treehouse_project_lock_path "$3")" || exit 2
    identity=$(fm_pid_identity "$attempt") || exit 2
    fm_suspend_record "$STATE/$2.meta" "park_release_pid=$attempt" "park_release_pid_identity=$identity" "park_release_attempt=p1" || exit 2
    kill -KILL "$attempt"
  ' _ "$ROOT" "$id" "$dir/project" > "$dir/killed" 2>&1 || rc=$?
  expect_code 137 "$rc" 'hard-kill fixture did not leave its locks via an actual SIGKILL'
  assert_present "$home/state/.control-$id.lock" 'fixture did not retain interrupted control custody'
  cp "$meta" "$dir/meta-before"
  attempt=$(sed -n 's/^park_release_pid=//p' "$meta")
  suspend_assert_no_match 'blocked.*copy-custody' "$home/state/$id.status" 'fixture unexpectedly ran cleanup on KILL'
  rc=0
  case "$entry" in
    poll) suspend_park "$dir" poll "$id" p1 > "$dir/reconcile" 2>&1 || rc=$?; expect_code 1 "$rc" 'hard-killed prepared poll poisoned the wait error budget' ;;
    resume) suspend_park "$dir" resume "$id" p1 > "$dir/reconcile" 2>&1 || rc=$?; expect_code 1 "$rc" 'prepared park resume allocated another copy' ;;
    control) FM_HOME="$home" "$ROOT/bin/fm-control.sh" "$id" relaunch --note continue > "$dir/reconcile" 2>&1 || rc=$?; expect_code 1 "$rc" 'prepared control restore allocated another copy' ;;
  esac
  assert_grep 'release attempt interrupted; custody uncertain; supervisor must reconcile' "$home/state/$id.status" 'hard kill was not notified without a native custody claim'
  for lock in "$home/state/.control-$id.lock" "$home/state/.meta-$id.lock" "$home/state/.fm-lease-command.lock" "$(suspend_lib "$dir" fm_treehouse_project_lock_path "$dir/project")"; do
    assert_present "$lock" 'hard-kill backstop freed a custody lock'
    assert_equals "$attempt" "$(cat "$lock/pid")" 'hard-kill backstop reassigned a custody lock'
  done
  cmp -s "$meta" "$dir/meta-before" || fail 'notification-only backstop changed custody records'
  assert_equals old-lease "$(jq -r .worktrees[0].lease_id "$dir/.treehouse/pool/treehouse-state.json")" 'hard-kill backstop changed native acquisition'
  assert_equals 'unlanded saved work' "$(cat "$wt/file")" 'hard-kill backstop changed work'
  assert_absent "$dir/calls" 'hard-kill backstop touched native custody'
  suspend_assert_matches '^copy_state=release-prepared$' "$meta" 'hard-kill reconciliation manufactured returned/restored custody'
  suspend_lib "$dir" fm_suspend_validate "$meta" "$id" "$home" "$home/data" || fail 'hard-kill reconciliation lost saved proof'
  suspend_park "$dir" poll "$id" p1 >/dev/null 2>&1 && fail 'interrupted custody became resumable on a second notification'
  assert_equals 1 "$(grep -c 'blocked.*copy-custody' "$home/state/$id.status")" 'later polls repeated the same interrupted-custody notification'
  pass "hard-killed release is notified once by $entry without freeing locks or changing/retrying uncertain custody"
done

id=release-live-attempt; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'live attempt fixture failed'
home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
suspend_lib "$dir" fm_suspend_save "$meta" "$id" "$home" "$home/data" "$wt" || fail 'could not prepare live custody'
identity=$(suspend_lib "$dir" fm_pid_identity "$$") || fail 'could not read live parent identity'
suspend_lib "$dir" fm_suspend_record "$meta" "park_release_pid=$$" "park_release_pid_identity=$identity" || fail 'could not bind live attempt'
# An unrelated live project-lock owner must also stay untouched on dead-attempt
# reconciliation. Its actual ownership is acquired through the public primitive.
FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2"; printf "%s\n" "$3" > "$2/pid"' _ \
  "$ROOT" "$(suspend_lib "$dir" fm_treehouse_project_lock_path "$dir/project")" "$$" || fail 'could not hold project lock'
rc=0; suspend_park "$dir" poll "$id" p1 || rc=$?
expect_code 1 "$rc" 'live prepared attempt became resumable'
suspend_assert_no_match 'blocked.*copy-custody' "$home/state/$id.status" 'a live release was falsely reported interrupted'
# Rebind to a proven dead PID while preserving the live unrelated project lock.
FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-suspend-lib.sh"; fm_current_pid pid; fm_suspend_record "$2" "park_release_pid=$pid"' _ \
  "$ROOT" "$meta" || fail 'could not bind dead attempt'
rc=0; suspend_park "$dir" poll "$id" p1 || rc=$?
expect_code 1 "$rc" 'dead prepared attempt became resumable'
suspend_assert_matches 'blocked.*copy-custody' "$home/state/$id.status" 'dead attempt was not notified beside a foreign live project holder'
assert_equals "$$" "$(cat "$(suspend_lib "$dir" fm_treehouse_project_lock_path "$dir/project")/pid")" 'backstop removed a live successor project lock'
assert_absent "$dir/calls" 'live/dead backstop used native operations'
pass 'interruption backstop refuses live attempts and preserves other live lock holders'

# A bare live PID is not proof of this release parent. Exercise missing,
# mismatched (PID reuse), and unreadable identity without touching custody.
for uncertainty in identity-missing identity-mismatch identity-unreadable stale-receipt; do
  id="release-$uncertainty"; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'identity fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
  suspend_lib "$dir" fm_suspend_save "$meta" "$id" "$home" "$home/data" "$wt" || fail 'could not prepare identity custody'
  identity=$(suspend_lib "$dir" fm_pid_identity "$$") || fail 'could not read actual live parent identity'
  case "$uncertainty" in
    identity-missing) identity='' ;;
    identity-mismatch|stale-receipt) identity="different-parent:$identity" ;;
    identity-unreadable)
      mkdir -p "$dir/proc/$$"
      printf 'invalid stat\n' > "$dir/proc/$$/stat"
      printf 'nonempty cmdline\n' > "$dir/proc/$$/cmdline" ;;
  esac
  suspend_lib "$dir" fm_suspend_record "$meta" "park_release_pid=$$" "park_release_pid_identity=$identity" || fail 'could not bind identity evidence'
  [ "$uncertainty" != stale-receipt ] || suspend_lib "$dir" fm_suspend_record "$meta" 'park_release_notified=previous-token' || fail 'could not bind stale receipt'
  cp "$meta" "$dir/meta-before"
  rc=0
  if [ "$uncertainty" = identity-unreadable ]; then
    FM_PROC_ROOT_OVERRIDE="$dir/proc" suspend_park "$dir" poll "$id" p1 > "$dir/out" 2>&1 || rc=$?
  else
    suspend_park "$dir" poll "$id" p1 > "$dir/out" 2>&1 || rc=$?
  fi
  expect_code 1 "$rc" 'uncertain parent identity consumed the condition error budget'
  assert_grep 'parent identity is missing, unreadable or mismatched' "$dir/out" 'identity uncertainty lost its diagnostic'
  assert_grep 'release attempt interrupted; custody uncertain; supervisor must reconcile' "$home/state/$id.status" 'live reused/unprovable PID suppressed notification'
  suspend_park "$dir" resume "$id" p1 > "$dir/resume" 2>&1 && fail 'uncertain identity restored custody'
  FM_HOME="$home" "$ROOT/bin/fm-control.sh" "$id" relaunch --note continue > "$dir/control" 2>&1 && fail 'direct control restored uncertain identity'
  assert_equals 1 "$(grep -c 'blocked.*copy-custody' "$home/state/$id.status")" 'identity uncertainty repeated the notification'
  cmp -s "$meta" "$dir/meta-before" || fail 'identity backstop changed custody records'
  assert_equals old-lease "$(jq -r .worktrees[0].lease_id "$dir/.treehouse/pool/treehouse-state.json")" 'identity backstop changed native lease'
  assert_equals 'unlanded saved work' "$(cat "$wt/file")" 'identity backstop changed work'
  assert_present "${wt%/*}/.fm-slot-owner" 'identity backstop freed protected work'
  assert_absent "$dir/calls" 'identity backstop touched native custody'
  pass "$uncertainty notifies once without cleanup, retry or restoration"
done

for uncertainty in missing malformed; do
  id="release-pid-$uncertainty"; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'uncertain PID fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
  suspend_lib "$dir" fm_suspend_save "$meta" "$id" "$home" "$home/data" "$wt" || fail 'could not prepare uncertain custody'
  [ "$uncertainty" != malformed ] || suspend_lib "$dir" fm_suspend_record "$meta" 'park_release_pid=not-a-pid' || fail 'could not inject invalid PID'
  cp "$meta" "$dir/meta-before"
  rc=0; suspend_park "$dir" poll "$id" p1 > "$dir/out" 2>&1 || rc=$?
  expect_code 1 "$rc" 'uncertain prepared PID consumed the condition error budget'
  assert_grep 'attempt PID is missing or invalid' "$dir/out" 'uncertain PID lost its concrete stderr diagnostic'
  cmp -s "$meta" "$dir/meta-before" || fail 'uncertain PID changed custody records'
  assert_grep 'release attempt interrupted; custody uncertain; supervisor must reconcile' "$home/state/$id.status" 'unprovable parent death did not raise its uncertainty notification'
  suspend_park "$dir" resume "$id" p1 > "$dir/resume" 2>&1 && fail 'uncertain PID restored work'
  assert_absent "$dir/calls" 'uncertain PID touched native custody'
  assert_present "${wt%/*}/.fm-slot-owner" 'uncertain PID released slot custody'
  pass "$uncertainty attempt PID stays not-yet, notifies uncertainty and leaves all custody unchanged"
done

id=release-notification-failure; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'notification failure fixture failed'
WHEN="$ROOT/bin/fm-procevent-when.sh"
home="$dir/home"; meta="$home/state/$id.meta"; wt="$dir/.treehouse/pool/1/project"
suspend_lib "$dir" fm_suspend_save "$meta" "$id" "$home" "$home/data" "$wt" || fail 'could not prepare failed notification custody'
FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-suspend-lib.sh"; fm_current_pid pid; fm_suspend_record "$2" "park_release_pid=$pid"' _ \
  "$ROOT" "$meta" || fail 'could not bind dead attempt for notification failure'
rm "$home/state/$id.status"; mkdir "$home/state/$id.status"
cp "$meta" "$dir/meta-before"
rc=0; suspend_park "$dir" poll "$id" p1 > "$dir/out" 2>&1 || rc=$?
expect_code 2 "$rc" 'notification-write failure silently consumed its owner-visible fallback'
assert_grep 'cannot append copy-custody notification' "$dir/out" 'notification failure did not identify the concrete append error'
cmp -s "$meta" "$dir/meta-before" || fail 'failed append was marked notified or changed saved custody'
assert_absent "$dir/calls" 'notification failure touched native custody'
SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$home" "$WHEN" arm "notification-$id" \
  --stable 1 --interval 1 --deadline 20 --error-budget 2 \
  --condition "$PARK" poll "$id" p1 --action /bin/true >/dev/null || fail 'could not arm notification-failure fallback'
fm_test_track_procevent_home "$home"
SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "when-notification-$id" \
  > "$dir/fallback" 2>&1 || fail 'notification failure fallback was not durably captured'
result=$(first_result "$home" "when-notification-$id") || fail 'no owner-visible condition-error result was published'
assert_equals condition-error "$(FM_HOME="$home" "$WHEN" classify "$result")" 'notification failure did not wake through the existing error-budget outcome'
suspend_park "$dir" resume "$id" p1 > "$dir/resume" 2>&1 && fail 'notification failure restored work'
assert_present "${wt%/*}/.fm-slot-owner" 'notification failure returned protected work'
pass 'failed custody notification uses the existing condition-error outcome without new channels or restore'

id=pickup-authority; dir=$(suspend_case "$TMP_ROOT" "$id"); home="$dir/home"; meta="$home/state/$id.meta"
suspend_saved "$dir" "$id" || fail 'authority save fixture failed'
for actor in "$id" another-worker; do
  FM_TASK_ID="$actor" suspend_park "$dir" pickup "$id" > "$dir/out" 2>&1 && fail 'task-worker authorized pickup'
done
FM_SUPERVISION_ACTOR=unknown suspend_park "$dir" pickup "$id" > "$dir/out" 2>&1 && fail 'unknown actor authorized pickup'
printf '%s\n' "$$" > "$home/state/.lock"; printf 'branch\t%s\t1\n' "$$" > "$home/state/.lease-$id"
suspend_park "$dir" pickup "$id" > "$dir/out" 2>&1 && fail 'another actor lease authorized pickup'
rm "$home/state/.lease-$id"
suspend_park "$dir" pickup "$id" || fail 'unmarked owner shell was refused'

FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" FAKE_CONTROL_FAIL=relaunch suspend_park "$dir" resume "$id" > "$dir/out" 2>&1 && fail 'failed admission reported resumed'
suspend_assert_matches '^park_state=parked$' "$meta" 'pre-allocation failure stranded the wait'
suspend_assert_matches '^copy_state=released$' "$meta" 'pre-allocation failure changed saved custody'
# Cancellation stops automation, not obligations; only the tokenless owner can
# reinstate it, and the resume note must not falsely say the wait was resolved.
printf 'needs-decision [key=approval]: pending approval\n' >> "$home/state/$id.status"
suspend_park "$dir" cancel "$id" || fail 'saved cancel failed'
suspend_park "$dir" resume "$id" p1 > "$dir/out" 2>&1 && fail 'cancelled listener resumed work'
FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" suspend_park "$dir" resume "$id" || fail 'explicit owner could not resume cancellation'
assert_grep 'does not resolve or waive any approval' "$home/data/$id/park-resume-note.md" 'cancellation resumption falsely waived an obligation'
suspend_assert_matches 'needs-decision.*approval' "$home/state/$id.status" 'resumption erased the existing approval'
pass 'pickup rejects task workers and competing leases; failed admission is retryable; cancellation preserves explicit owner restoration and approvals'
