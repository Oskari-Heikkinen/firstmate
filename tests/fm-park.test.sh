#!/usr/bin/env bash
# Behavior tests for bin/fm-park.sh: the handoff validator, park idempotence,
# the cross-home condition checkers with their per-kind default deadlines, the
# park-time refusal of a condition whose check errors,
# automatic resume when the wait condition holds, the supervisor wake on a
# deadline or failed relaunch, the self-park detached exit, and the Claude
# self-park refusal while background shells still run, the live-wait rule
# for self-parks and its `await` waiter. A fake control
# plane stands in for the harness endpoint (FM_PARK_CONTROL_OVERRIDE) and logs
# every lifecycle verb it receives, so no agent, terminal, or worktree is
# touched; the condition watch is the real bin/fm-procevent-when.sh runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/suspend-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/suspend-helpers.sh"

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

# Fake gh and heavy-job.sh for the GitHub and heavy-slot conditions: each logs
# its argv and answers from a state file the case writes; FAKE_FAIL makes the
# read fail as an unreachable source would.
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
# The condition checks read the machine-wide heavy-job config from here, so
# none leaks in from the host running the tests.
TEST_XDG="$TMP_ROOT/xdg"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_STATE.gh-args"
[ ! -e "$FAKE_STATE.fail" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
cat "$FAKE_STATE"
SH
cat > "$TMP_ROOT/heavy-job.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_STATE.heavy-args"
[ "$1" = record ] || { echo "only record is a read verb" >&2; exit 64; }
[ -e "$FAKE_STATE" ] || { echo "heavy-job: [Errno 2] No such file or directory: jobs/$2.json" >&2; exit 2; }
printf '{"schema": "heavy-slot-job/v1", "id": "%s", "state": "%s"}\n' "$2" "$(cat "$FAKE_STATE")"
SH
chmod +x "$FAKEBIN/gh" "$TMP_ROOT/heavy-job.sh"
fake_park() {  # <state-file> <home> <args>...: park with the fakes on PATH
  PATH="$FAKEBIN:$PATH" XDG_CONFIG_HOME="$TEST_XDG" FAKE_STATE="$1" park "${@:2}"
}
check_rc() {  # <state-file> <home> <condition>: print the check's exit code
  local rc=0
  PATH="$FAKEBIN:$PATH" XDG_CONFIG_HOME="$TEST_XDG" FAKE_STATE="$1" FM_HOME="$2" "$PARK" check "$3" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}
deadline_in() {  # <meta>: seconds from now to the recorded park deadline
  local iso
  iso=$(sed -n 's/^park_deadline=//p' "$1" | tail -1)
  echo $(( $(date -u -d "$iso" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$iso" +%s) - $(date +%s) ))
}

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
# bare_poll <home> <task-id> <token>: poll with no command on PATH and stderr in
# <home>/poll.err, so an answer shows the poll started no process to give it.
bare_poll() { (cd "$TMP_ROOT" && PATH="$TMP_ROOT/no-commands" FM_HOME="$1" "$BASH" "$PARK" poll "${@:2}" 2> "$1/poll.err"); }
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
case_handoff_validation() {
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
}

# --- park refuses a missing handoff and leaves the agent running --------------
case_park_refuses_missing_handoff() {
  H="$TMP_ROOT/h-refuse"; new_task "$H" t1
  if park "$H" t1 --handoff "$TMP_ROOT/missing.md" 2>"$TMP_ROOT/refuse.err"; then
    fail "park accepted a missing handoff"
  fi
  assert_grep "missing or unreadable" "$TMP_ROOT/refuse.err" "park names the missing handoff"
  assert_absent "$H/control.log" "a refused park never touched the agent"
  assert_absent "$H/state/procevent/when-park-t1.source" "a refused park armed no watch"
  pass "park refuses a missing handoff without stopping anything"
}

# Queue adoption may not fabricate a source or accept an unrelated condition.
case_queue_adoption_refusal() {
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
}

# --- park records, arms, declares the wait, and stops the agent; re-park re-arms
case_park_records_and_rearms() {
  H="$TMP_ROOT/h-park"; new_task "$H" t2
  handoff "$TMP_ROOT/t2.md" "file:$TMP_ROOT/t2-results"
  out=$(park "$H" t2 --handoff "$TMP_ROOT/t2.md" --deadline 2099-01-01T00:00Z) || fail "park failed: $out"
  assert_present "$H/data/t2/handoff.md" "park installs the handoff in the task's data directory"
  assert_grep "park_state=parked" "$H/state/t2.meta" "park records the parked state"
  assert_grep "park_when=file:$TMP_ROOT/t2-results" "$H/state/t2.meta" "park records the condition"
  assert_grep "park_deadline=2099-01-01T00:00:00Z" "$H/state/t2.meta" "park records the deadline"
  assert_equals "pr=https://github.com/example/repo/pull/7" "$(last_line "$H/state/t2.meta")" "the PR stays the record's tail"
  assert_present "$H/state/procevent/when-park-t2.source" "park arms the resume watch"
  assert_equals 60 "$(sed -n 's/^interval=//p' "$H/state/when/when-park-t2.spec")" "a local wait samples changes every 60 seconds, so it resumes within about two minutes"
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
}

# --- the default poll cadence follows the condition kind ----------------------
case_default_cadence() {
  H="$TMP_ROOT/h-cadence"; new_task "$H" tcmd; new_task "$H" tpr; new_task "$H" tgh
  handoff "$TMP_ROOT/tcmd.md" "cmd:true"
  park "$H" tcmd --handoff "$TMP_ROOT/tcmd.md" >/dev/null || fail "park tcmd failed"
  assert_equals 60 "$(sed -n 's/^interval=//p' "$H/state/when/when-park-tcmd.spec")" "a cmd: wait is polled every 60 seconds"
  handoff "$TMP_ROOT/tpr.md" "pr-merged:https://github.com/example/repo/pull/7"
  printf 'OPEN\n' > "$TMP_ROOT/tpr.state"
  fake_park "$TMP_ROOT/tpr.state" "$H" tpr --handoff "$TMP_ROOT/tpr.md" >/dev/null || fail "park tpr failed"
  assert_equals 300 "$(sed -n 's/^interval=//p' "$H/state/when/when-park-tpr.spec")" "a pr-merged: wait keeps the slower GitHub-friendly cadence"
  handoff "$TMP_ROOT/tgh.md" "gh-run:example/repo:123"
  printf 'queued\n' > "$TMP_ROOT/tgh.state"
  fake_park "$TMP_ROOT/tgh.state" "$H" tgh --handoff "$TMP_ROOT/tgh.md" >/dev/null || fail "park tgh failed"
  assert_equals 120 "$(sed -n 's/^interval=//p' "$H/state/when/when-park-tgh.spec")" "gh-run keeps its longer cadence"
  FM_PARK_INTERVAL=7 park "$H" tcmd --handoff "$TMP_ROOT/tcmd.md" >/dev/null || fail "re-park tcmd failed"
  assert_equals 7 "$(sed -n 's/^interval=//p' "$H/state/when/when-park-tcmd.spec")" "FM_PARK_INTERVAL still overrides the default cadence"
  pass "the resume watch samples local waits every minute and retains remote cadences"
}

# --- park resolves its own directory and root as cd and pwd print them --------
# The resume watch runs the condition path park records, and an unset FM_HOME
# falls back to the script's root, so linked, dotted and relative invocations
# must resolve exactly as cd and pwd do.
case_park_resolves_its_directory() {
  fake="$TMP_ROOT/linked-bin"; link="$TMP_ROOT/linked-root"
  mkdir -p "$fake/bin"
  ln -s "$ROOT"/bin/* "$fake/bin/"
  ln -s "$ROOT" "$link"
  new_task "$fake" td
  handoff "$TMP_ROOT/td.md" "file:$TMP_ROOT/td-results"
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    FAKE_CONTROL_LOG="$fake/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
    "$fake/bin/fm-park.sh" td --handoff "$TMP_ROOT/td.md" 2>&1) || fail "park without FM_HOME failed: $out"
  assert_grep "park_state=parked" "$fake/state/td.meta" "park without FM_HOME records the park in its own root"
  assert_equals "$(cd "$fake/bin" && pwd)/fm-park.sh" "$(sed -n '/^argv:$/{n;p;q;}' "$fake/state/when/when-park-td.spec")" \
    "park without FM_HOME arms its own path as the condition"
  H="$TMP_ROOT/h-resolve"; n=0
  for invoked in "$link/bin/fm-park.sh" "$link/bin/../bin/fm-park.sh" linked-root/bin/fm-park.sh; do
    n=$((n + 1)); new_task "$H" "tr$n"
    handoff "$TMP_ROOT/tr$n.md" "file:$TMP_ROOT/tr$n-results"
    out=$(cd "$TMP_ROOT" && FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
      "$invoked" "tr$n" --handoff "$TMP_ROOT/tr$n.md" 2>&1) || fail "park through $invoked failed: $out"
    condition=$(sed -n '/^argv:$/{n;p;q;}' "$H/state/when/when-park-tr$n.spec")
    assert_equals "$(cd "$TMP_ROOT" && cd "$(dirname "$invoked")" && pwd)/fm-park.sh" "$condition" \
      "park through $invoked arms the path cd and pwd print"
    token=$(sed -n 's/^park_token=//p' "$H/state/tr$n.meta")
    rc=0; (cd / && FM_HOME="$H" "$condition" poll "tr$n" "$token") || rc=$?
    expect_code 1 "$rc" "the condition armed through $invoked read an unmet wait"
    : > "$TMP_ROOT/tr$n-results"
    (cd / && FM_HOME="$H" "$condition" poll "tr$n" "$token") || fail "the condition armed through $invoked missed its result"
  done
  pass "park arms the directory and root cd and pwd print from linked, dotted and relative invocations"
}

# --- a poll on a settled copy answers in the shell ----------------------------
# The resume watch runs poll on every interval. Unless the record shows a release
# to reconcile, a poll reads its record and checks a file or inbox wait without
# starting a process, so with no command on PATH it answers as it always has.
case_poll_answers_in_the_shell() {
  H="$TMP_ROOT/h-shell-poll"; new_task "$H" tsp; new_task "$H" tsi
  mkdir -p "$TMP_ROOT/no-commands"
  handoff "$TMP_ROOT/tsp.md" "file:$TMP_ROOT/tsp-results"
  park "$H" tsp --handoff "$TMP_ROOT/tsp.md" >/dev/null || fail "park tsp failed"
  token=$(sed -n 's/^park_token=//p' "$H/state/tsp.meta")
  : > "$TMP_ROOT/tsp-results"
  rc=0; bare_poll "$H" tsp retired-token || rc=$?
  expect_code 2 "$rc" "a poll without commands accepted another park's token"
  for copy in '' retained released restore-prepared unknown; do
    case "$copy" in
      ''|retained|released) unmet=1 met=0 ;;
      restore-prepared) unmet=1 met=1 ;;
      *) unmet=2 met=2 ;;
    esac
    [ -z "$copy" ] || printf 'copy_state=%s\n' "$copy" >> "$H/state/tsp.meta"
    rm -f "$TMP_ROOT/tsp-results"
    rc=0; bare_poll "$H" tsp "$token" || rc=$?
    expect_code "$unmet" "$rc" "a poll without commands misread an unmet wait with copy_state '$copy'"
    : > "$TMP_ROOT/tsp-results"
    rc=0; bare_poll "$H" tsp "$token" || rc=$?
    expect_code "$met" "$rc" "a poll without commands misread a met wait with copy_state '$copy'"
    assert_equals '' "$(cat "$H/poll.err")" "a poll without commands printed an error with copy_state '$copy'"
  done
  printf 'copy_state=retained\nkind=secondmate\n' >> "$H/state/tsp.meta"
  rc=0; bare_poll "$H" tsp "$token" || rc=$?
  expect_code 1 "$rc" "a poll without commands accepted a secondmate record"
  assert_contains "$(cat "$H/poll.err")" "is kind 'secondmate'" "a poll without commands misread the record's kind"
  printf 'kind=ship\nremote_host=elsewhere\n' >> "$H/state/tsp.meta"
  rc=0; bare_poll "$H" tsp "$token" || rc=$?
  expect_code 1 "$rc" "a poll without commands accepted another host's task"
  assert_contains "$(cat "$H/poll.err")" "runs on another host" "a poll without commands missed the record's host"
  handoff "$TMP_ROOT/tsi.md" "inbox:tsi"
  park "$H" tsi --handoff "$TMP_ROOT/tsi.md" >/dev/null || fail "park tsi failed"
  token=$(sed -n 's/^park_token=//p' "$H/state/tsi.meta")
  rc=0; bare_poll "$H" tsi "$token" || rc=$?
  expect_code 1 "$rc" "a poll without commands picked up an inbox wait by itself"
  park "$H" pickup tsi >/dev/null || fail "pickup tsi failed"
  bare_poll "$H" tsi "$token" || fail "a poll without commands missed an explicit pickup"
  assert_equals '' "$(cat "$H/poll.err")" "an inbox poll without commands printed an error"
  pass "a poll on a settled copy reads its record and checks its wait without starting a process"
}

# --- a delivery resumes the inbox park it is addressed to ---------------------
# The real listener fires and relaunches on fm-send's own pickup, and on the
# request a task worker's send leaves, each within the park's interval x stable.
case_delivery_resumes_inbox_park() {
  local id res
  H="$TMP_ROOT/h-deliver"; mkdir -p "$H/config" "$H/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/terminal-calls"\nexit 9\n' "$H" > "$H/fakebin/tmux"
  chmod +x "$H/fakebin/tmux"
  for id in tdd tdr; do
    new_task "$H" "$id"
    handoff "$TMP_ROOT/$id.md" "inbox:$id"
    FM_PARK_INTERVAL=0.1 FM_PARK_STABLE=1 park "$H" "$id" --handoff "$TMP_ROOT/$id.md" >/dev/null || fail "park $id failed"
  done
  start_watch "$H"
  PATH="$H/fakebin:$PATH" FM_HOME="$H" "$ROOT/bin/fm-send.sh" tdd 'the answer is in' > "$H/send.out" 2>&1 || fail "delivery to tdd failed: $(cat "$H/send.out")"
  PATH="$H/fakebin:$PATH" FM_TASK_ID=some-worker FM_HOME="$H" "$ROOT/bin/fm-send.sh" tdr 'from a worker' > "$H/send.out" 2>&1 || fail "a worker's delivery to tdr failed: $(cat "$H/send.out")"
  for id in tdd tdr; do
    wait_for_result "$H" "when-park-$id" || fail "the delivery to $id never fired its inbox park"
    res=$(first_result "$H" "when-park-$id")
    assert_equals fired "$("$ROOT/bin/fm-procevent-when.sh" classify "$res")" "the $id watch did not fire the resume"
    grep "^$id relaunch" "$H/control.log" >/dev/null || fail "the delivery did not relaunch $id: $(cat "$H/control.log")"
    assert_grep "park_state=resumed" "$H/state/$id.meta" "the $id resume was not recorded"
  done
  assert_absent "$H/state/tdr.inbox/.pickup-requested" "the acted-on request was left behind"
  assert_absent "$H/terminal-calls" "a delivery rang a parked terminal"
  pass "a delivery to an inbox park relaunches it through the listener, directly or through a worker's request"
}

# --- a pickup request from outside the lease reaches the park's own poll -----
case_inbox_pickup_request() {
  H="$TMP_ROOT/h-request"; new_task "$H" tsr; new_task "$H" tsf
  req="$H/state/tsr.inbox/.pickup-requested"
  rc=0; park "$H" request-pickup tsr-missing 2>/dev/null || rc=$?
  expect_code 3 "$rc" "a request for an unknown task recorded something"
  handoff "$TMP_ROOT/tsf.md" "file:$TMP_ROOT/tsf-results"
  park "$H" tsf --handoff "$TMP_ROOT/tsf.md" >/dev/null || fail "park tsf failed"
  mkdir -p "$H/state/tsf.inbox"
  rc=0; park "$H" request-pickup tsf || rc=$?
  expect_code 3 "$rc" "a request for a park that does not wait on its inbox recorded something"
  assert_absent "$H/state/tsf.inbox/.pickup-requested" "a non-inbox park took a pickup request"
  handoff "$TMP_ROOT/tsr.md" "inbox:tsr"
  park "$H" tsr --handoff "$TMP_ROOT/tsr.md" >/dev/null || fail "park tsr failed"
  token=$(sed -n 's/^park_token=//p' "$H/state/tsr.meta")
  rc=0; park "$H" request-pickup tsr > "$H/request.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "a request without an inbox directory was reported recorded"
  assert_contains "$(cat "$H/request.out")" "has no inbox directory" "the missing inbox directory was not named"
  mkdir -p "$H/state/tsr.inbox"
  # The delivery is the event: with no unhandled record there is nothing to resume.
  rc=0; FM_TASK_ID=some-worker park "$H" request-pickup tsr 2>/dev/null || rc=$?
  expect_code 1 "$rc" "a request with no delivered message was recorded"
  assert_absent "$req" "a request with no delivered message was left"
  printf 'steer\n' > "$H/state/tsr.inbox/001.msg"

  # The request needs no lease and grants nothing until the park's poll acts.
  FM_TASK_ID=some-worker park "$H" request-pickup tsr || fail "a task worker could not request a pickup"
  assert_equals "$token" "$(cat "$req")" "the request does not name the current park"
  rc=0; park "$H" check inbox:tsr || rc=$?
  expect_code 1 "$rc" "a pickup request alone satisfied the inbox wait"

  # A request for an earlier park is never acted on, nor removed by the poll.
  printf 'park.retired\n' > "$req"
  rc=0; park "$H" poll tsr "$token" || rc=$?
  expect_code 1 "$rc" "a stale request picked up the current park"
  assert_present "$req" "the poll removed a request it did not act on"

  # Nor does the poll act on a current request once no unhandled record waits.
  mkdir -p "$H/state/tsr.inbox/handled"; mv "$H/state/tsr.inbox/001.msg" "$H/state/tsr.inbox/handled/"
  printf '%s\n' "$token" > "$req"
  rc=0; park "$H" poll tsr "$token" || rc=$?
  expect_code 1 "$rc" "a request with every message handled picked up the park"
  assert_present "$req" "the poll removed a request it did not act on"
  mv "$H/state/tsr.inbox/handled/001.msg" "$H/state/tsr.inbox/"

  # A request the poll cannot read is a condition error, never a silent skip.
  : > "$req"
  rc=0; park "$H" poll tsr "$token" > "$H/poll.out" 2>&1 || rc=$?
  expect_code 2 "$rc" "an empty pickup request was not a condition error"
  assert_contains "$(cat "$H/poll.out")" "empty or unreadable" "the empty request was not named"
  rm -f "$req"; mkdir "$req"
  rc=0; park "$H" poll tsr "$token" > "$H/poll.out" 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-regular pickup request was not a condition error"
  assert_contains "$(cat "$H/poll.out")" "is not a regular file" "the non-regular request was not named"
  rc=0; park "$H" request-pickup tsr 2>/dev/null || rc=$?
  expect_code 1 "$rc" "a request was recorded over a non-regular request path"
  [ -z "$(ls -A "$req")" ] || fail "the request was written inside a directory at its path"
  rmdir "$req"
  # A symlink at the request path is refused both ways, even one that points at
  # a regular file holding the current token.
  printf '%s\n' "$token" > "$TMP_ROOT/tsr-linked-request"
  ln -s "$TMP_ROOT/tsr-linked-request" "$req"
  rc=0; park "$H" poll tsr "$token" > "$H/poll.out" 2>&1 || rc=$?
  expect_code 2 "$rc" "a symlinked pickup request was not a condition error"
  assert_contains "$(cat "$H/poll.out")" "is not a regular file" "the symlinked request was not named"
  assert_no_grep "park_pickup=$token" "$H/state/tsr.meta" "a symlinked request picked up the park"
  rc=0; park "$H" request-pickup tsr 2>/dev/null || rc=$?
  expect_code 1 "$rc" "a request was recorded over a symlink at its path"
  [ -L "$req" ] || fail "the request replaced a symlink at its path"
  assert_equals "$token" "$(cat "$TMP_ROOT/tsr-linked-request")" "the request was written through a symlink"
  rm -f "$req"
  # A FIFO at the request path is a condition error that never blocks the poll.
  mkfifo "$req"
  rc=0; park "$H" poll tsr "$token" > "$H/poll.out" 2>&1 &
  fm_exit_guarded_wait "$!" "a poll over a FIFO pickup request" || rc=$?
  expect_code 2 "$rc" "a FIFO pickup request was not a condition error"
  assert_contains "$(cat "$H/poll.out")" "is not a regular file" "the FIFO request was not named"
  rm -f "$req"

  # The other supervision actor's live lease defers the pickup to a later poll.
  park "$H" request-pickup tsr || fail "the request could not be recorded again"
  printf '%s\n' "$$" > "$H/state/.lock"; printf 'branch\t%s\t1\n' "$$" > "$H/state/.lease-tsr"
  rc=0; park "$H" poll tsr "$token" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "a refused lease did not leave the request for a later poll"
  assert_present "$req" "a refused lease dropped the request"
  assert_no_grep "park_pickup=$token" "$H/state/tsr.meta" "a refused lease recorded the pickup"
  rm -f "$H/state/.lease-tsr" "$H/state/.lock"

  park "$H" poll tsr "$token" || fail "the park's poll did not act on its current request"
  assert_grep "park_pickup=$token" "$H/state/tsr.meta" "the poll did not record the pickup"
  assert_absent "$req" "the acted-on request was left behind"
  park "$H" check inbox:tsr || fail "the requested pickup did not satisfy the inbox wait"

  # A new park drops a request for the park it replaces.
  printf '%s\n' "$token" > "$req"
  park "$H" tsr --handoff "$TMP_ROOT/tsr.md" >/dev/null || fail "re-park tsr failed"
  assert_absent "$req" "a new park kept the request for the park it replaced"

  # An inbox path that is a symlink holds no request, and nothing is written
  # through it.
  new_task "$H" tsl
  handoff "$TMP_ROOT/tsl.md" "inbox:tsl"
  park "$H" tsl --handoff "$TMP_ROOT/tsl.md" >/dev/null || fail "park tsl failed"
  mkdir -p "$TMP_ROOT/tsl-linked-inbox"; printf 'steer\n' > "$TMP_ROOT/tsl-linked-inbox/001.msg"
  ln -s "$TMP_ROOT/tsl-linked-inbox" "$H/state/tsl.inbox"
  rc=0; park "$H" request-pickup tsl > "$H/request.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "a request was recorded through a symlinked inbox"
  assert_contains "$(cat "$H/request.out")" "has no inbox directory" "the symlinked inbox was not named"
  assert_absent "$TMP_ROOT/tsl-linked-inbox/.pickup-requested" "the request was written through a symlinked inbox"
  pass "a pickup request from outside the lease resumes only its own park, through the park's lease-guarded poll"
}

# --- a park that changes while the requested pickup waits for the lease ------
# The poll read the park, then waits on the lease guard lock another command
# holds; the park is replaced meanwhile. The pickup must neither record the new
# park nor turn the change into a condition error.
case_inbox_pickup_race() {
  local token hp pp realsleep rc i
  H="$TMP_ROOT/h-race"; new_task "$H" tpr; mkdir -p "$H/fakebin"
  handoff "$TMP_ROOT/tpr.md" "inbox:tpr"
  park "$H" tpr --handoff "$TMP_ROOT/tpr.md" >/dev/null || fail "park tpr failed"
  token=$(sed -n 's/^park_token=//p' "$H/state/tpr.meta")
  mkdir -p "$H/state/tpr.inbox"; printf 'steer\n' > "$H/state/tpr.inbox/001.msg"
  FM_TASK_ID=some-worker park "$H" request-pickup tpr || fail "the tpr request could not be recorded"
  # The poll's first sleep is its wait for the held lock, after it read the park.
  realsleep=$(command -v sleep)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/sleep-calls"\nexec %s "$@"\n' "$H" "$realsleep" > "$H/fakebin/sleep"
  chmod +x "$H/fakebin/sleep"
  STATE="$H/state" bash -c '. "$1/fm-wake-lib.sh"; fm_lock_acquire_wait "$STATE/.fm-lease-command.lock"; : > "$2/held"; while [ ! -e "$2/release" ]; do sleep 0.1; done; fm_lock_release "$STATE/.fm-lease-command.lock"' _ "$ROOT/bin" "$H" &
  hp=$!
  i=0; while [ ! -e "$H/held" ] && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$H/held" ] || fail "the lock holder never took the lease guard lock"
  PATH="$H/fakebin:$PATH" FM_SUPERVISION_ACTOR=main park "$H" poll tpr "$token" > "$H/poll.out" 2>&1 &
  pp=$!
  i=0; while [ ! -s "$H/sleep-calls" ] && kill -0 "$pp" 2>/dev/null && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$H/sleep-calls" ] || { : > "$H/release"; wait "$hp"; fail "the poll never waited on the held lock: $(cat "$H/poll.out")"; }
  sed 's/^park_token=.*/park_token=park.next/' "$H/state/tpr.meta" > "$H/state/tpr.meta.new"
  mv "$H/state/tpr.meta.new" "$H/state/tpr.meta"
  : > "$H/release"
  rc=0; fm_exit_guarded_wait "$pp" "a poll racing a new park" || rc=$?
  wait "$hp" || fail "the lock holder failed"
  expect_code 1 "$rc" "a park replaced under the requested pickup was not left for its next poll"
  assert_equals 'park_pickup=' "$(grep '^park_pickup=' "$H/state/tpr.meta")" "the requested pickup recorded a park"
  assert_present "$H/state/tpr.inbox/.pickup-requested" "the poll removed a request it did not act on"
  pass "a park replaced while its requested pickup waits for the lease is neither picked up nor an error"
}

# --- the observation hint reads only a regular pickup request ---------------
case_inbox_hint_request_shapes() {
  local token req rc out
  H="$TMP_ROOT/h-hint"; new_task "$H" tph
  handoff "$TMP_ROOT/tph.md" "inbox:tph"
  park "$H" tph --handoff "$TMP_ROOT/tph.md" >/dev/null || fail "park tph failed"
  token=$(sed -n 's/^park_token=//p' "$H/state/tph.meta")
  mkdir -p "$H/state/tph.inbox"; req="$H/state/tph.inbox/.pickup-requested"
  printf '%s\n' "$token" > "$req"
  out=$(STATE="$H/state" FM_HOME="$H" SCRIPT_DIR="$ROOT/bin" bash -c '. "$1/fm-wake-lib.sh"; . "$1/fm-pr-lib.sh"; . "$1/fm-park-observe-lib.sh"; fm_park_observation_to o "$SCRIPT_DIR/fm-park.sh" poll tph "$2" || exit; printf "%s\n" "$o"' _ "$ROOT/bin" "$token") \
    || fail "the hint could not observe a regular pickup request"
  assert_contains "$out" "inbox:$token" "the hint does not carry the request"
  rm -f "$req"; mkfifo "$req"
  rc=0
  STATE="$H/state" FM_HOME="$H" SCRIPT_DIR="$ROOT/bin" bash -c '. "$1/fm-wake-lib.sh"; . "$1/fm-pr-lib.sh"; . "$1/fm-park-observe-lib.sh"; fm_park_observation_to o "$SCRIPT_DIR/fm-park.sh" poll tph "$2"' _ "$ROOT/bin" "$token" &
  fm_exit_guarded_wait "$!" "the hint over a FIFO pickup request" || rc=$?
  expect_code 1 "$rc" "a FIFO pickup request did not force the full poll"
  pass "the observation hint carries a regular pickup request and leaves any other shape to the full poll"
}

# --- the cross-home condition kinds each read their own source ----------------
case_cross_home_conditions() {
  H="$TMP_ROOT/h-kinds"; mkdir -p "$H/state" "$H/config"
  st="$TMP_ROOT/kinds.state"
  # receipt: is file: under another name.
  assert_equals 1 "$(check_rc "$st" "$H" "receipt:$TMP_ROOT/kinds-receipt")" "an absent receipt is not yet"
  : > "$TMP_ROOT/kinds-receipt"
  assert_equals 0 "$(check_rc "$st" "$H" "receipt:$TMP_ROOT/kinds-receipt")" "a present receipt holds"
  assert_equals 2 "$(check_rc "$st" "$H" "receipt:kinds-receipt")" "a relative receipt is an error"
  # merge-result: reads this home's configured queue for the full head.
  head=0123456789abcdef0123456789abcdef01234567
  assert_equals 2 "$(check_rc "$st" "$H" "merge-result:$head")" "an unconfigured merge queue is an error"
  out=$(FM_HOME="$H" "$PARK" check "merge-result:$head" 2>&1)
  assert_contains "$out" "config/merge-queue" "the unconfigured queue error names the missing config"
  mkdir -p "$TMP_ROOT/kinds-queue"; : > "$TMP_ROOT/kinds-queue/queue.log"
  printf 'dir=%s\nhome=test-home\n' "$TMP_ROOT/kinds-queue" > "$H/config/merge-queue"
  assert_equals 1 "$(check_rc "$st" "$H" "merge-result:$head")" "a head without a result is pending"
  printf 'RESULT 2026-10-17T12:00:00Z head=%s outcome=taken\n' "$head" >> "$TMP_ROOT/kinds-queue/queue.log"
  assert_equals 1 "$(check_rc "$st" "$H" "merge-result:$head")" "a taken head is still pending"
  printf 'RESULT 2026-10-17T12:30:00Z head=%s outcome=landed main=%s\n' "$head" "$head" >> "$TMP_ROOT/kinds-queue/queue.log"
  assert_equals 0 "$(check_rc "$st" "$H" "merge-result:$head")" "a final result holds"
  assert_equals 2 "$(check_rc "$st" "$H" "merge-result:${head:0:12}")" "a short head is an error"
  # heavy: reads only the slot's heavy-job.sh record verb.
  assert_equals 2 "$(check_rc "$st" "$H" heavy:job-1)" "an unconfigured heavy-job.sh is an error"
  printf 'path=%s\n' "$TMP_ROOT/heavy-job.sh" > "$H/config/heavy-job"
  assert_equals 2 "$(check_rc "$st" "$H" heavy:job-1)" "a missing job record is an error"
  for state in queued running; do
    printf '%s\n' "$state" > "$st"
    assert_equals 1 "$(check_rc "$st" "$H" heavy:job-1)" "a $state heavy job is not yet"
  done
  for state in finished failed stopped; do
    printf '%s\n' "$state" > "$st"
    assert_equals 0 "$(check_rc "$st" "$H" heavy:job-1)" "a $state heavy job has ended"
  done
  printf 'mystery\n' > "$st"
  assert_equals 2 "$(check_rc "$st" "$H" heavy:job-1)" "an unknown heavy job state is an error"
  rm -f "$H/config/heavy-job"
  printf 'running\n' > "$st"
  mkdir -p "$TEST_XDG/firstmate"
  printf 'path=%s\n' "$TMP_ROOT/heavy-job.sh" > "$TEST_XDG/firstmate/heavy-job"
  assert_equals 1 "$(check_rc "$st" "$H" heavy:job-1)" "the machine-wide config locates heavy-job.sh"
  rm -f "$TEST_XDG/firstmate/heavy-job"
  assert_equals 2 "$(check_rc "$st" "$H" heavy:../job)" "a path-like job id is an error"
  assert_equals "" "$(grep -v '^record job-1$' "$st.heavy-args" || true)" "heavy: calls heavy-job.sh only as record <job-id>"
  # gh-run: names its repository explicitly and waits for completion.
  : > "$st.gh-args"
  for status in queued in_progress waiting; do
    printf '%s\n' "$status" > "$st"
    assert_equals 1 "$(check_rc "$st" "$H" gh-run:example/repo:42)" "a $status run is not yet"
  done
  printf 'completed\n' > "$st"
  assert_equals 0 "$(check_rc "$st" "$H" gh-run:example/repo:42)" "a completed run holds"
  assert_grep "run view 42 -R example/repo " "$st.gh-args" "gh-run: reads the run with -R"
  : > "$st.fail"
  assert_equals 2 "$(check_rc "$st" "$H" gh-run:example/repo:42)" "an unreadable run is an error"
  rm -f "$st.fail"
  assert_equals 2 "$(check_rc "$st" "$H" gh-run:example/repo)" "a gh-run: without a run id is an error"
  # Each kind is found in a handoff, backticked or not.
  printf '## Goal\ng\n## Done\nd\n## Waiting for\nCI on the head: gh-run:example/repo:42.\n## Next steps\nn\n' > "$TMP_ROOT/kinds.md"
  out=$(FM_HOME="$H" "$PARK" validate "$TMP_ROOT/kinds.md" 2>&1) || fail "an unbackticked gh-run: was refused: $out"
  assert_equals "handoff ok: waiting for gh-run:example/repo:42" "$out" "an unbackticked gh-run: ends at its run id"
  for cond in "receipt:/tmp/r" "merge-result:$head" "heavy:job-1"; do
    handoff "$TMP_ROOT/kinds.md" "$cond"
    out=$(FM_HOME="$H" "$PARK" validate "$TMP_ROOT/kinds.md" 2>&1) || fail "validate refused $cond: $out"
    assert_equals "handoff ok: waiting for $cond" "$out" "validate reads $cond"
  done
  pass "receipt:, merge-result:, heavy: and gh-run: each have a tested checker"
}

# --- the cross-home kinds default to short deadlines; overrides still win -----
case_kind_default_deadlines() {
  H="$TMP_ROOT/h-deadlines"; mkdir -p "$H/config"
  st="$TMP_ROOT/deadlines.state"
  head=89abcdef0123456789abcdef0123456789abcdef
  mkdir -p "$TMP_ROOT/deadlines-queue"; : > "$TMP_ROOT/deadlines-queue/queue.log"
  printf 'dir=%s\nhome=test-home\n' "$TMP_ROOT/deadlines-queue" > "$H/config/merge-queue"
  printf 'path=%s\n' "$TMP_ROOT/heavy-job.sh" > "$H/config/heavy-job"
  new_task "$H" dmr; new_task "$H" dgh; new_task "$H" dhv; new_task "$H" drc; new_task "$H" dfile
  handoff "$TMP_ROOT/dmr.md" "merge-result:$head"
  fake_park "$st" "$H" dmr --handoff "$TMP_ROOT/dmr.md" >/dev/null || fail "park dmr failed"
  left=$(deadline_in "$H/state/dmr.meta")
  [ "$left" -gt 10500 ] && [ "$left" -le 10800 ] || fail "a merge-result: wait defaults to three hours, got $left seconds"
  printf 'in_progress\n' > "$st"
  handoff "$TMP_ROOT/dgh.md" "gh-run:example/repo:42"
  fake_park "$st" "$H" dgh --handoff "$TMP_ROOT/dgh.md" >/dev/null || fail "park dgh failed"
  left=$(deadline_in "$H/state/dgh.meta")
  [ "$left" -gt 21300 ] && [ "$left" -le 21600 ] || fail "a gh-run: wait defaults to six hours, got $left seconds"
  assert_equals 120 "$(sed -n 's/^interval=//p' "$H/state/when/when-park-dgh.spec")" "a gh-run: wait polls GitHub every two minutes"
  printf 'running\n' > "$st"
  handoff "$TMP_ROOT/dhv.md" "heavy:job-2"
  fake_park "$st" "$H" dhv --handoff "$TMP_ROOT/dhv.md" >/dev/null || fail "park dhv failed"
  left=$(deadline_in "$H/state/dhv.meta")
  [ "$left" -gt 42900 ] && [ "$left" -le 43200 ] || fail "a heavy: wait defaults to twelve hours, got $left seconds"
  handoff "$TMP_ROOT/drc.md" "receipt:$TMP_ROOT/drc-receipt"
  park "$H" drc --handoff "$TMP_ROOT/drc.md" >/dev/null || fail "park drc failed"
  left=$(deadline_in "$H/state/drc.meta")
  [ "$left" -gt 86100 ] && [ "$left" -le 86400 ] || fail "a receipt: wait defaults to a day, got $left seconds"
  handoff "$TMP_ROOT/dfile.md" "file:$TMP_ROOT/dfile-results"
  park "$H" dfile --handoff "$TMP_ROOT/dfile.md" >/dev/null || fail "park dfile failed"
  left=$(deadline_in "$H/state/dfile.meta")
  [ "$left" -gt 604500 ] && [ "$left" -le 604800 ] || fail "a file: wait keeps the seven-day default, got $left seconds"
  FM_PARK_DEADLINE_MERGE_RESULT_SECS=600 fake_park "$st" "$H" dmr --handoff "$TMP_ROOT/dmr.md" >/dev/null || fail "re-park dmr failed"
  left=$(deadline_in "$H/state/dmr.meta")
  [ "$left" -gt 300 ] && [ "$left" -le 600 ] || fail "FM_PARK_DEADLINE_MERGE_RESULT_SECS overrides the default, got $left seconds"
  fake_park "$st" "$H" dmr --handoff "$TMP_ROOT/dmr.md" --deadline 2099-01-01T00:00Z >/dev/null || fail "re-park dmr with --deadline failed"
  assert_grep "park_deadline=2099-01-01T00:00:00Z" "$H/state/dmr.meta" "--deadline overrides the kind's default"
  if FM_PARK_DEADLINE_HEAVY_SECS=soon fake_park "$st" "$H" dhv --handoff "$TMP_ROOT/dhv.md" 2>"$TMP_ROOT/dhv.err"; then
    fail "a malformed per-kind deadline was accepted"
  fi
  assert_grep "positive number of seconds" "$TMP_ROOT/dhv.err" "a malformed per-kind deadline is named"
  pass "cross-home waits default to deadlines of hours, and --deadline or the kind's knob overrides them"
}

# --- park runs the check once and refuses a condition that errors -------------
case_park_time_refusal() {
  H="$TMP_ROOT/h-precheck"; mkdir -p "$H/config"; new_task "$H" pbad; new_task "$H" pmiss; new_task "$H" pok; new_task "$H" pheavy; new_task "$H" pslow
  cat > "$TMP_ROOT/check-error.sh" <<'SH'
#!/usr/bin/env bash
echo "gh: no repository found; pass -R" >&2
exit 2
SH
  cat > "$TMP_ROOT/check-missing.sh" <<SH
#!/usr/bin/env bash
"$TMP_ROOT/no-such-result.sh"
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/check-pending.sh"
  chmod +x "$TMP_ROOT/check-error.sh" "$TMP_ROOT/check-missing.sh" "$TMP_ROOT/check-pending.sh"
  handoff "$TMP_ROOT/pbad.md" "cmd:$TMP_ROOT/check-error.sh"
  if park "$H" pbad --handoff "$TMP_ROOT/pbad.md" 2>"$TMP_ROOT/pbad.err"; then
    fail "park accepted a condition whose check exits 2"
  fi
  assert_grep "failed with exit 2" "$TMP_ROOT/pbad.err" "the refusal names the check's exit"
  assert_grep "no repository found; pass -R" "$TMP_ROOT/pbad.err" "the refusal shows the check's own output"
  assert_absent "$H/control.log" "a refused park never touches the agent"
  assert_absent "$H/state/procevent/when-park-pbad.source" "a refused park arms no watch"
  assert_no_grep "park_state=" "$H/state/pbad.meta" "a refused park records nothing"
  assert_absent "$H/data/pbad/handoff.md" "a refused park installs no handoff"
  handoff "$TMP_ROOT/pmiss.md" "cmd:$TMP_ROOT/check-missing.sh"
  if park "$H" pmiss --handoff "$TMP_ROOT/pmiss.md" 2>"$TMP_ROOT/pmiss.err"; then
    fail "park accepted a check that calls a missing script"
  fi
  assert_grep "failed with exit 127" "$TMP_ROOT/pmiss.err" "a check calling a missing script is refused"
  printf 'path=%s\n' "$TMP_ROOT/heavy-job.sh" > "$H/config/heavy-job"
  handoff "$TMP_ROOT/pheavy.md" "heavy:never-submitted"
  if fake_park "$TMP_ROOT/pheavy.absent" "$H" pheavy --handoff "$TMP_ROOT/pheavy.md" 2>"$TMP_ROOT/pheavy.err"; then
    fail "park accepted a heavy: wait on a job with no record"
  fi
  assert_grep "cannot read heavy job never-submitted" "$TMP_ROOT/pheavy.err" "a heavy: wait on an unknown job is refused with the reason"
  handoff "$TMP_ROOT/pslow.md" "cmd:sleep 10"
  if FM_PARK_PRECHECK_TIMEOUT=1 park "$H" pslow --handoff "$TMP_ROOT/pslow.md" 2>"$TMP_ROOT/pslow.err"; then
    fail "park accepted a check that outlived its bound"
  fi
  assert_grep "failed with exit 124" "$TMP_ROOT/pslow.err" "a check that outlives its bound is refused"
  assert_grep "did not finish within 1 seconds" "$TMP_ROOT/pslow.err" "the refusal says the check timed out"
  assert_no_grep "park_state=" "$H/state/pslow.meta" "a timed-out check parks nothing"
  handoff "$TMP_ROOT/pok.md" "cmd:$TMP_ROOT/check-pending.sh"
  park "$H" pok --handoff "$TMP_ROOT/pok.md" >/dev/null || fail "park refused a check that is merely not yet true"
  assert_grep "park_state=parked" "$H/state/pok.meta" "a pending check parks"
  pass "park runs the condition once and refuses one whose check errors, showing why"
}

# --- the condition relaunches the task with the handoff and a results pointer --
case_resume_and_repark() {
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
  assert_equals 1 "$(grep -c '^[0-9][0-9]*$' "$H/state/.park-churn/t3")" "resume records itself for the park-churn alarm"
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
}

# --- a task relaunched since it parked is not relaunched again -----------------
case_superseded_resume() {
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
}

# --- a failed relaunch wakes the supervisor and keeps the record --------------
case_failed_relaunch() {
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
  assert_absent "$H/state/.park-churn/t4" "a failed relaunch is not counted as a resume"
  assert_grep "park_handoff=$H/data/t4/handoff.md" "$H/state/t4.meta" "the record keeps the handoff"
  wait_for_wake "$H" when-park-t4 || fail "the failure did not wake the supervisor"
  pass "a failed relaunch wakes the supervisor and leaves the park record intact"
}

# --- a deadline with no result wakes the supervisor instead of relaunching ----
case_deadline_wakes_supervisor() {
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
}

# --- a worker parking itself returns before its session is stopped ------------
case_self_park_detached_exit() {
  H="$TMP_ROOT/h-self"; new_task "$H" t6
  handoff "$TMP_ROOT/t6.md" "file:$TMP_ROOT/t6-results"
  out=$(cd "$H/wt-t6" && FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
    FM_PARK_SELF_EXIT_DELAY=0 "$PARK" t6 --handoff "$TMP_ROOT/t6.md" --expect +7200) || fail "self-park failed: $out"
  assert_contains "$out" "this session stops in a few seconds" "self-park returns before stopping its own session"
  for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
  assert_equals "t6 exit" "$(cat "$H/control.log" 2>/dev/null)" "the detached exit stops the session"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t6 >/dev/null 2>&1 || true
  pass "a worker parking itself gets a detached exit"
}

# --- self-park is recognized by FM_TASK_ID from outside the worktree ----------
case_self_park_by_task_id() {
  H="$TMP_ROOT/h-selfid"; new_task "$H" t7
  handoff "$TMP_ROOT/t7.md" "file:$TMP_ROOT/t7-results"
  out=$(cd "$TMP_ROOT" && FM_TASK_ID=t7 FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
    FM_PARK_SELF_EXIT_DELAY=0 "$PARK" t7 --handoff "$TMP_ROOT/t7.md" --expect +7200) || fail "self-park by task id failed: $out"
  assert_contains "$out" "this session stops in a few seconds" "a worker outside its worktree still self-parks"
  for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
  assert_equals "t7 exit" "$(cat "$H/control.log" 2>/dev/null)" "the detached exit stops the session"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t7 >/dev/null 2>&1 || true
  pass "FM_TASK_ID marks a self-park wherever the worker's shell is"
}

# --- a failed detached exit wakes the supervisor ------------------------------
case_self_park_exit_failure() {
  H="$TMP_ROOT/h-selffail"; new_task "$H" t8
  handoff "$TMP_ROOT/t8.md" "file:$TMP_ROOT/t8-results"
  out=$(cd "$H/wt-t8" && FM_HOME="$H" FAKE_CONTROL_LOG="$H/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
    FAKE_CONTROL_FAIL=exit FM_PARK_SELF_EXIT_DELAY=0 "$PARK" t8 --handoff "$TMP_ROOT/t8.md" --expect +7200) || fail "self-park t8 failed: $out"
  for _ in $(seq 1 100); do grep -q '^blocked' "$H/state/t8.status" && break; sleep 0.1; done
  assert_contains "$(last_line "$H/state/t8.status")" "blocked [at=" "a failed detached exit appends a blocked line"
  assert_contains "$(last_line "$H/state/t8.status")" "$H/data/t8/park-exit.log" "the blocked line names the exit log"
  assert_grep "fake exit failure" "$H/data/t8/park-exit.log" "the exit log keeps the failure"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t8 >/dev/null 2>&1 || true
  pass "a self-park whose exit fails wakes the supervisor instead of idling silently"
}

# self_park <home> <id> <park-args...>: park as the task's own worker would,
# with stderr in <home>/self.err.
self_park() {
  (cd "$TMP_ROOT" && FM_TASK_ID=$2 FM_HOME="$1" FAKE_CONTROL_LOG="$1/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" \
    FM_PARK_SELF_EXIT_DELAY=0 "$PARK" "$2" "${@:3}" 2> "$1/self.err")
}
# refused_self_park <home> <id> <expected-rc> <what> <park-args...>: the self-park
# exits <expected-rc> and installs nothing.
refused_self_park() {
  local rc=0
  self_park "$1" "$2" "${@:5}" > /dev/null || rc=$?
  expect_code "$3" "$rc" "$4"
  assert_no_grep "park_state=" "$1/state/$2.meta" "$4 records no park"
  assert_absent "$1/control.log" "$4 stops no session"
  assert_absent "$1/state/procevent/when-park-$2.source" "$4 arms no resume watch"
}

# --- a worker parking itself waits live on a wait expected within the threshold
case_live_wait_rule() {
  H="$TMP_ROOT/h-live"; new_task "$H" tl
  handoff "$TMP_ROOT/tl.md" "file:$TMP_ROOT/tl-results"
  refused_self_park "$H" tl 1 'a self-park with no expected time' --handoff "$TMP_ROOT/tl.md"
  assert_grep "with --expect <UTC|+seconds>" "$H/self.err" "the refusal names the missing expected time"
  refused_self_park "$H" tl 4 'a self-park expected within the threshold' --handoff "$TMP_ROOT/tl.md" --expect +600
  assert_grep "fm-park.sh await tl file:$TMP_ROOT/tl-results\`" "$H/self.err" \
    "the refusal gives the live waiter for the same condition"
  refused_self_park "$H" tl 4 'a self-park expected within the default threshold by UTC time' --handoff "$TMP_ROOT/tl.md" \
    --expect "$(date -u -d "@$(( $(date +%s) + 3000 ))" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$(( $(date +%s) + 3000 ))" +%Y-%m-%dT%H:%MZ)"
  refused_self_park "$H" tl 1 'a malformed expected time' --handoff "$TMP_ROOT/tl.md" --expect soon
  assert_grep "--expect must be a UTC time" "$H/self.err" "the refusal names the malformed expected time"
  handoff "$TMP_ROOT/tl-inbox.md" "inbox:tl"
  refused_self_park "$H" tl 4 'a self-park on its own inbox expected soon' --handoff "$TMP_ROOT/tl-inbox.md" --expect +60
  assert_grep "paused [wait=inbox:tl]" "$H/self.err" "an inbox wait is told to declare itself and end its turn"
  pass "a self-park expected within the live-wait threshold, or with no expected time, is refused before anything is installed"

  self_park "$H" tl --handoff "$TMP_ROOT/tl.md" --expect +3600 > /dev/null || fail "a self-park expected at the threshold was refused: $(cat "$H/self.err")"
  assert_grep "park_state=parked" "$H/state/tl.meta" "a wait expected at the threshold parks"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tl >/dev/null 2>&1 || true
  pass "a self-park expected at or past the threshold parks"
}

# A condition precheck crosses a clock tick deterministically, without sleeping.
# Both estimate forms must use one observation of now to classify the boundary.
case_live_wait_clock_boundary() {
  local mode seconds expect PATH="$TMP_ROOT/clock-bin:$PATH"
  local PARK_CLOCK_DATE PARK_CLOCK_BASE=2000000040 PARK_CLOCK_MARK
  export PARK_CLOCK_DATE PARK_CLOCK_BASE PARK_CLOCK_MARK
  PARK_CLOCK_DATE=$(command -v date)
  mkdir -p "$TMP_ROOT/clock-bin"
  cat > "$TMP_ROOT/clock-bin/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then
  if [ -f "$PARK_CLOCK_MARK" ]; then
    printf '%s\n' "$((PARK_CLOCK_BASE + 2))"
  else
    printf '%s\n' "$PARK_CLOCK_BASE"
  fi
else
  exec "$PARK_CLOCK_DATE" "$@"
fi
SH
  cat > "$TMP_ROOT/clock-condition" <<'SH'
#!/usr/bin/env bash
printf 'prechecked\n' > "$PARK_CLOCK_MARK"
exit 1
SH
  chmod +x "$TMP_ROOT/clock-bin/date" "$TMP_ROOT/clock-condition"
  export PATH
  for mode in relative utc; do
    for seconds in 3599 3600 3601; do
      H="$TMP_ROOT/h-clock-$mode-$seconds"; new_task "$H" tclock
      PARK_CLOCK_MARK="$H/prechecked"
      handoff "$H/input.md" "cmd:$TMP_ROOT/clock-condition"
      expect=+$seconds
      if [ "$mode" = utc ]; then
        expect=$("$PARK_CLOCK_DATE" -u -d "@$((PARK_CLOCK_BASE + seconds))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || "$PARK_CLOCK_DATE" -u -r "$((PARK_CLOCK_BASE + seconds))" +%Y-%m-%dT%H:%M:%SZ)
      fi
      if [ "$seconds" -lt 3600 ]; then
        refused_self_park "$H" tclock 4 "$mode wait below threshold after clock tick" --handoff "$H/input.md" --expect "$expect"
      else
        self_park "$H" tclock --handoff "$H/input.md" --expect "$expect" >/dev/null \
          || fail "$mode wait at/past threshold changed classification after clock tick: $(cat "$H/self.err")"
        assert_grep "park_state=parked" "$H/state/tclock.meta" "$mode wait at/past threshold parks after clock tick"
        FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tclock >/dev/null 2>&1 || true
      fi
      assert_grep "prechecked" "$PARK_CLOCK_MARK" "the precheck advanced the clock before routing the $mode wait"
      assert_equals "$((PARK_CLOCK_BASE + 2))" "$(date +%s)" "the clock really diverged from the estimate's initial sample"
    done
  done
  pass "clock ticks during precheck cannot change relative or UTC estimate classification"
}

# --- a park that firstmate or the memory guard asked for always parks ----------
case_live_wait_exemptions() {
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  H="$TMP_ROOT/h-live-open"; new_task "$H" to
  handoff "$TMP_ROOT/to.md" "file:$TMP_ROOT/to-results"
  self_park "$H" to --handoff "$TMP_ROOT/to.md" --open-ended > /dev/null \
    || fail "an open-ended self-park was refused: $(cat "$H/self.err")"
  assert_grep "park_open_ended=1" "$H/state/to.meta" "an open-ended self-park parks with no expected time"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-to >/dev/null 2>&1 || true
  H="$TMP_ROOT/h-live-adopt"; new_task "$H" tqa
  mkdir -p "$H/config" "$TMP_ROOT/live-queue"
  : > "$TMP_ROOT/live-queue/queue.log"
  printf 'dir=%s\n' "$TMP_ROOT/live-queue" > "$H/config/merge-queue"
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register merge-queue "merge-queue-tqa-aaaaaaaa" \
    -- "$ROOT/bin/fm-procevent-merge-queue.sh" watch tqa "$head" >/dev/null || fail "could not seed the queue source"
  handoff "$TMP_ROOT/tqa.md" "cmd:$ROOT/bin/fm-procevent-merge-queue.sh result-ready $head"
  self_park "$H" tqa --handoff "$TMP_ROOT/tqa.md" --adopt-merge-queue "$head" --expect +60 > /dev/null \
    || fail "an adopted short queue wait was refused: $(cat "$H/self.err")"
  assert_grep "park_source=merge-queue-tqa-aaaaaaaa" "$H/state/tqa.meta" "a live queue wait adopts the existing source"
  assert_grep "park_state=live" "$H/state/tqa.meta" "a short adopted queue wait stays live"
  assert_absent "$H/control.log" "a short queue wait stops no worker"
  assert_absent "$H/state/procevent/when-park-tqa.source" "a short queue wait arms no competing result action"
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" retire merge-queue-tqa-aaaaaaaa >/dev/null 2>&1 || true
  pass "open-ended parks remain exempt but adopted short queue waits stay live"
}
case_live_wait_requested() {
  local estimate mode
  local -a args
  for mode in requested supervisor open-ended zero; do
    for estimate in absent '' soon +60 9999999999999999999999; do
      H="$TMP_ROOT/h-live-req-$mode-${estimate:-empty}"; new_task "$H" tq
      handoff "$H/input.md" "file:$H/results"
      mkdir -p "$H/config"
      printf 'invalid\n' > "$H/config/park-live-wait-minutes"
      args=()
      [ "$estimate" = absent ] || args+=(--expect "$estimate")
      case "$mode" in
        requested) args+=(--requested) ;;
        open-ended) args+=(--open-ended) ;;
        zero) printf '0\n' > "$H/config/park-live-wait-minutes" ;;
      esac
      if [ "$mode" = supervisor ]; then
        park "$H" tq --handoff "$H/input.md" ${args[@]+"${args[@]}"} >/dev/null || fail "supervisor estimate $estimate refused"
      else
        self_park "$H" tq --handoff "$H/input.md" ${args[@]+"${args[@]}"} >/dev/null \
          || fail "$mode estimate $estimate refused: $(cat "$H/self.err")"
      fi
      assert_grep "park_state=parked" "$H/state/tq.meta" "$mode does not interpret irrelevant estimates"
      FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tq >/dev/null 2>&1 || true
    done
  done
  H="$TMP_ROOT/h-requested-unsafe"; new_task "$H" tq
  printf 'unsafe handoff\n' > "$H/input.md"
  refused_self_park "$H" tq 1 'a requested park still validates custody and handoff' --handoff "$H/input.md" --requested --expect soon
  pass "requested parks outrank estimate and threshold validation, never handoff safety"
}

# --- the threshold setting is read every run and a bad one refuses --------------
case_live_wait_threshold_file() {
  local shape
  for shape in empty words range dir; do
    H="$TMP_ROOT/h-live-cfg-$shape"; new_task "$H" tc
    mkdir -p "$H/config"
    case "$shape" in
      empty) : > "$H/config/park-live-wait-minutes" ;;
      words) printf 'sixty\n' > "$H/config/park-live-wait-minutes" ;;
      range) printf '1441\n' > "$H/config/park-live-wait-minutes" ;;
      dir) mkdir "$H/config/park-live-wait-minutes" ;;
    esac
    handoff "$TMP_ROOT/tc-$shape.md" "file:$TMP_ROOT/tc-results"
    refused_self_park "$H" tc 1 "a self-park under a $shape threshold file" --handoff "$TMP_ROOT/tc-$shape.md" --expect +7200
    assert_grep "$H/config/park-live-wait-minutes must hold whole minutes" "$H/self.err" "a $shape threshold file is named, not defaulted"
  done
  pass "an empty, unparsable, out-of-range or non-file threshold setting refuses and names the file"

  H="$TMP_ROOT/h-live-cfg-ten"; new_task "$H" tt
  mkdir -p "$H/config"; printf '10\n' > "$H/config/park-live-wait-minutes"
  handoff "$TMP_ROOT/tt.md" "file:$TMP_ROOT/tt-results"
  refused_self_park "$H" tt 4 'a self-park expected within a ten-minute threshold' --handoff "$TMP_ROOT/tt.md" --expect +590
  self_park "$H" tt --handoff "$TMP_ROOT/tt.md" --expect +1200 > /dev/null || fail "a ten-minute threshold refused a 20-minute wait: $(cat "$H/self.err")"
  assert_grep "park_state=parked" "$H/state/tt.meta" "the configured threshold replaces the default"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tt >/dev/null 2>&1 || true

  H="$TMP_ROOT/h-live-cfg-zero"; new_task "$H" tz
  mkdir -p "$H/config"; printf '0\n' > "$H/config/park-live-wait-minutes"
  handoff "$TMP_ROOT/tz.md" "file:$TMP_ROOT/tz-results"
  self_park "$H" tz --handoff "$TMP_ROOT/tz.md" > /dev/null || fail "a zero threshold still refused a self-park: $(cat "$H/self.err")"
  assert_grep "park_state=parked" "$H/state/tz.meta" "a zero threshold parks every wait"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tz >/dev/null 2>&1 || true
  pass "the threshold setting applies on the next park, and 0 parks every wait"
}

# --- the live waiter declares the wait and ends on the condition ---------------
# await <home> <id> <condition>: run the live waiter with stderr in <home>/await.err.
await() { FM_HOME="$1" "$PARK" await "$2" "$3" 2> "$1/await.err"; }

case_await_holds() {
  local pid rc=0 line
  H="$TMP_ROOT/h-await"; new_task "$H" ta
  : > "$TMP_ROOT/ta-done"
  out=$(await "$H" ta "file:$TMP_ROOT/ta-done") || fail "a holding condition did not end the waiter at once: $(cat "$H/await.err")"
  assert_contains "$out" "already holds" "a condition that already holds is reported"
  assert_contains "$(last_line "$H/state/ta.status")" 'live wait over' "even the first dependency read is declared and then resolved"
  rc=0; await "$H" ta "inbox:ta" > /dev/null || rc=$?
  expect_code 2 "$rc" "an inbox wait needs no waiter"
  assert_grep "paused [wait=inbox:ta]" "$H/await.err" "an inbox waiter is told to declare the inbox wait instead"
  pass "the live waiter ends at once on a holding condition and refuses an inbox wait"

  FM_PARK_INTERVAL=0.2 FM_HOME="$H" "$PARK" await ta "file:$TMP_ROOT/ta-results" > "$H/await.out" 2> "$H/await.err" &
  pid=$!
  # This log already holds the immediate wait's declaration. Await the new
  # process incarnation, not a historical declaration from that earlier wait.
  for _ in $(seq 1 200); do grep -Fq "paused [wait=process:$pid:" "$H/state/ta.status" && break; sleep 0.1; done
  line=$(last_line "$H/state/ta.status")
  assert_contains "$line" "paused [wait=process:$pid:" "the waiter declares a process wait on itself"
  assert_contains "$line" "live wait on file:$TMP_ROOT/ta-results" "the declared wait names the condition"
  assert_grep "live_wait_when=file:$TMP_ROOT/ta-results" "$H/state/ta.meta" "the waiter records the condition"
  assert_grep "live_wait_until=" "$H/state/ta.meta" "the waiter records its bound"
  assert_grep "pr=https://github.com/example/repo/pull/7" "$H/state/ta.meta" "the task record keeps its other fields"
  : > "$TMP_ROOT/ta-results"
  rc=0; wait "$pid" || rc=$?
  expect_code 0 "$rc" "the waiter exits 0 once the condition holds"
  assert_contains "$(last_line "$H/state/ta.status")" "working [at=" "the waiter ends its declared wait"
  handoff "$H/reuse.md" "file:$TMP_ROOT/ta-results"
  rm -f "$TMP_ROOT/ta-results"
  refused_self_park "$H" ta 4 'a completed same-condition wait grants no exemption' --handoff "$H/reuse.md" --expect +60
  pass "the live waiter declares a process wait on itself and retires permission when the condition holds"
}

case_await_single_owner() {
  local pid rc=0 first_rc=0 i
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  H="$TMP_ROOT/h-single-await"; new_task "$H" ts
  mkfifo "$H/release"
  exec 8<> "$H/release"
  cat > "$H/check" <<'SH'
#!/usr/bin/env bash
home=${0%/*}
printf 'check\n' >> "$home/probes"
: > "$home/started"
IFS= read -r release < "$home/release"
exit 0
SH
  chmod +x "$H/check"
  FM_HOME="$H" FM_PARK_PRECHECK_TIMEOUT=120 FM_PARK_LIVE_WAIT_SECS=180 \
    "$PARK" await ts "cmd:$H/check" > "$H/first.out" 2> "$H/first.err" & pid=$!
  for i in $(seq 1 200); do [ ! -f "$H/started" ] || break; sleep 0.1; done
  assert_present "$H/started" 'first waiter owns a blocked condition probe'
  fm_run_timed 5 env FM_HOME="$H" FM_PARK_PRECHECK_TIMEOUT=120 FM_PARK_LIVE_WAIT_SECS=180 \
    "$PARK" await ts "cmd:$H/check" > "$H/second.out" 2> "$H/second.err" || rc=$?
  printf 'continue\n' >&8
  wait "$pid" || first_rc=$?
  exec 8>&-
  expect_code 1 "$rc" 'second concurrent await refuses'
  assert_grep 'already has a live waiter' "$H/second.err" 'refusal identifies the existing live waiter'
  expect_code 0 "$first_rc" 'refused contender does not overwrite the original wait'
  assert_equals check "$(cat "$H/probes")" 'only the owning waiter starts a condition probe'
  assert_absent "$H/state/.ts.live-wait.lock" 'original waiter releases its lock on completion'
  pass 'one concurrent await owns a task; a refused contender changes nothing'
}

case_await_superseded() {
  local phase replacement dir pid rc event status
  for phase in probe interval; do
    for replacement in cancel park generation; do
      dir="$TMP_ROOT/superseded-$phase-$replacement"; mkdir -p "$dir/bin"
      H="$dir/home"; new_task "$H" ta
      mkfifo "$dir/events" "$dir/release"
      exec 8<> "$dir/release" 9<> "$dir/events"
      cat > "$dir/check" <<'SH'
#!/usr/bin/env bash
if [ -e "$AWAIT_CASE/polled" ]; then
  printf 'extra\n' >> "$AWAIT_CASE/polled"
  exit 0
fi
printf 'first\n' > "$AWAIT_CASE/polled"
if [ "$AWAIT_PHASE" = probe ]; then
  printf 'probe\n' > "$AWAIT_CASE/events"
  IFS= read -r release < "$AWAIT_CASE/release"
  exit 0
fi
exit 1
SH
      cat > "$dir/bin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 0.271 ]; then
  printf 'interval\n' > "$AWAIT_CASE/events"
  IFS= read -r release < "$AWAIT_CASE/release"
else
  exec /bin/sleep "$@"
fi
SH
      chmod +x "$dir/check" "$dir/bin/sleep"
      PATH="$dir/bin:$PATH" AWAIT_CASE="$dir" AWAIT_PHASE="$phase" FM_PARK_INTERVAL=0.271 FM_HOME="$H" \
        "$PARK" await ta "cmd:$dir/check" > "$dir/out" 2> "$dir/err" & pid=$!
      IFS= read -r -t 20 event <&9 || fail 'waiter never reached its forced-order barrier'
      assert_equals "$phase" "$event" 'supersession happens while the waiter is running'
      case "$replacement" in
        cancel) FM_HOME="$H" "$PARK" cancel ta >/dev/null || fail 'could not cancel running wait' ;;
        park)
          handoff "$dir/handoff.md" "file:$dir/result"
          park "$H" ta --handoff "$dir/handoff.md" --requested >/dev/null || fail 'could not replace running wait with park'
          ;;
        generation)
          printf 'spawn_gen=g2\n' >> "$H/state/ta.meta"
          printf 'working [at=2]: replacement worker\n' >> "$H/state/ta.status"
          ;;
      esac
      status=$(last_line "$H/state/ta.status")
      printf 'continue\n' >&8
      rc=0; wait "$pid" || rc=$?
      exec 8>&- 9>&-
      expect_code 2 "$rc" 'the superseded waiter stops without granting expiry or completing newer work'
      assert_equals first "$(cat "$dir/polled")" 'the superseded waiter starts no additional condition check'
      assert_grep 'cancelled or superseded' "$dir/err" 'the stopped waiter names supersession'
      assert_equals "$status" "$(last_line "$H/state/ta.status")" 'superseded probe does not overwrite the current status'
      assert_absent "$H/state/.ta.live-wait.lock" 'supersession releases the live-wait lock'
      assert_no_grep 'live_wait_state=expired' "$H/state/ta.meta" 'supersession grants no expiry exemption'
    done
  done
  pass 'cancel, park and new incarnation stop a running waiter before its next check or result publication'
}

case_await_bound() {
  local rc=0
  H="$TMP_ROOT/h-await-bound"; new_task "$H" tb
  rc=0; FM_PARK_LIVE_WAIT_SECS=2 FM_PARK_INTERVAL=0.2 await "$H" tb "file:$TMP_ROOT/tb-never" > /dev/null || rc=$?
  expect_code 3 "$rc" "a waiter whose condition does not hold within the threshold exits 3"
  assert_grep "park now" "$H/await.err" "the waiter says to park"
  assert_contains "$(last_line "$H/state/tb.status")" "reached the" "the waiter ends its declared wait at the threshold"
  pass "the live waiter exits 3 at the threshold"

  handoff "$TMP_ROOT/tb.md" "file:$TMP_ROOT/tb-never"
  self_park "$H" tb --handoff "$TMP_ROOT/tb.md" > /dev/null || fail "a self-park after a lapsed live wait was refused: $(cat "$H/self.err")"
  assert_grep "park_state=parked" "$H/state/tb.meta" "a live wait that reached the threshold allows the park"
  assert_grep 'live_wait_state=' "$H/state/tb.meta" "park consumes live-wait permission"
  rc=0; self_park "$H" tb --handoff "$TMP_ROOT/tb.md" --expect +60 >/dev/null || rc=$?
  expect_code 4 "$rc" "the consumed expiry cannot exempt another short wait"
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tb >/dev/null 2>&1 || true
  pass "a live wait that reached its threshold lets the same condition park without an expected time"

  H="$TMP_ROOT/h-await-open"; new_task "$H" to
  handoff "$TMP_ROOT/to.md" "file:$TMP_ROOT/to-never"
  fm_write_meta "$H/state/to.meta" "window=fm:fm-to" "worktree=$H/wt-to" "kind=ship" "harness=claude" "spawn_gen=g1" \
    "live_wait_when=file:$TMP_ROOT/to-never" "live_wait_until=$(( $(date +%s) + 600 ))" "pr=https://github.com/example/repo/pull/7"
  refused_self_park "$H" to 1 'a self-park during a live wait still within its bound' --handoff "$TMP_ROOT/to.md"
  fm_write_meta "$H/state/to.meta" "window=fm:fm-to" "worktree=$H/wt-to" "kind=ship" "harness=claude" "spawn_gen=g1" \
    "live_wait_when=file:$TMP_ROOT/other" "live_wait_until=1" "pr=https://github.com/example/repo/pull/7"
  refused_self_park "$H" to 1 'a self-park after a lapsed live wait on another condition' --handoff "$TMP_ROOT/to.md"
  pass "only a lapsed live wait on the same condition allows a park without an expected time"
}

case_await_errors() {
  local rc=0
  H="$TMP_ROOT/h-await-err"; new_task "$H" te
  printf '#!/bin/sh\necho broken source\nexit 5\n' > "$TMP_ROOT/te-check.sh"; chmod +x "$TMP_ROOT/te-check.sh"
  rc=0; FM_PARK_ERROR_BUDGET=2 FM_PARK_INTERVAL=0.1 await "$H" te "cmd:$TMP_ROOT/te-check.sh" > /dev/null || rc=$?
  expect_code 2 "$rc" "a waiter whose check keeps erroring exits 2"
  assert_grep "failed 2 times in a row; last output: broken source" "$H/await.err" "the waiter shows the check's output"
  assert_contains "$(last_line "$H/state/te.status")" "stopped" "the waiter ends its declared wait on errors"
  printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/te-check.sh"
  handoff "$H/reuse.md" "cmd:$TMP_ROOT/te-check.sh"
  refused_self_park "$H" te 4 'an errored same-condition wait grants no exemption' --handoff "$H/reuse.md" --expect +60
  mkdir -p "$H/config"; printf '0\n' > "$H/config/park-live-wait-minutes"
  rc=0; await "$H" te "file:$TMP_ROOT/te-never" > /dev/null || rc=$?
  expect_code 2 "$rc" "a zero threshold has no live waits"
  printf 'x\n' > "$H/config/park-live-wait-minutes"
  rc=0; await "$H" te "file:$TMP_ROOT/te-never" > /dev/null || rc=$?
  expect_code 2 "$rc" "an unreadable threshold refuses the waiter"
  assert_grep "park-live-wait-minutes must hold whole minutes" "$H/await.err" "the waiter names the bad threshold file"
  pass "the live waiter stops on repeated check errors and refuses without a usable threshold"
}

# Every dependency read, including the initial one, runs inside both bounds.
case_await_hanging_checks() {
  local mode pid rc i check_pid check_bound wait_bound child_alive barrier
  for mode in initial later cancel; do
    H="$TMP_ROOT/h-hanging-$mode"; new_task "$H" th
    cat > "$H/check" <<'SH'
#!/usr/bin/env bash
home=${0%/*}
grep -q 'paused.*wait=process:' "$home/state/th.status" || exit 9
if [ "$(cat "$home/mode")" = later ] && [ ! -f "$home/first" ]; then
  : > "$home/first"
  exit 1
fi
printf '%s\n' "$$" > "$home/check-pid"
exec sleep 300
SH
    chmod +x "$H/check"
    printf '%s\n' "$mode" > "$H/mode"
    check_bound=3; wait_bound=5
    [ "$mode" != later ] || check_bound=60
    # Cancellation must finish before either timeout can rescue it: the whole
    # assertion window (startup + exit + child cleanup) is less than 120s.
    if [ "$mode" = cancel ]; then
      check_bound=120; wait_bound=180
      # Hold the owner alive in cleanup: the timeout helper's independent
      # owner-death fallback must not mask a missing explicit child stop.
      mkdir -p "$H/bin"
      mkfifo "$H/cleanup-event" "$H/cleanup-release"
      exec 7<> "$H/cleanup-event" 8<> "$H/cleanup-release"
      cat > "$H/bin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */fm-live-wait.*)
    printf 'cleanup\n' > "$AWAIT_CLEANUP_HOME/cleanup-event"
    IFS= read -r release < "$AWAIT_CLEANUP_HOME/cleanup-release"
    ;;
  esac
done
exec /bin/rm "$@"
SH
      chmod +x "$H/bin/rm"
    fi
    PATH="$H/bin:$PATH" AWAIT_CLEANUP_HOME="$H" FM_HOME="$H" FM_PARK_PRECHECK_TIMEOUT=$check_bound FM_PARK_ERROR_BUDGET=1 FM_PARK_INTERVAL=0.1 FM_PARK_LIVE_WAIT_SECS=$wait_bound \
      "$PARK" await th "cmd:$H/check" >"$H/out" 2>"$H/await.err" & pid=$!
    for i in $(seq 1 200); do [ ! -f "$H/check-pid" ] || break; sleep 0.1; done
    assert_present "$H/check-pid" "$mode dependency started after declaring its wait"
    assert_grep 'paused [wait=process:' "$H/state/th.status" "$mode check is covered by a declared wait"
    if [ "$mode" = cancel ]; then
      check_pid=$(cat "$H/check-pid")
      kill -TERM "$pid"
      IFS= read -r -t 15 barrier <&7 || fail 'cancel never reached its cleanup barrier'
      assert_equals cleanup "$barrier" 'owner is held alive during cancellation cleanup'
      child_alive=0; kill -0 "$check_pid" 2>/dev/null && child_alive=1
      printf 'continue\n' >&8
      exec 7>&- 8>&-
      assert_equals 0 "$child_alive" 'cancel stops its child before publishing cleanup'
    fi
    for i in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; fail "$mode dependency escaped the bound"; fi
    rc=0; wait "$pid" || rc=$?
    expect_code 2 "$rc" "$mode dependency ends with an error, never park permission"
    check_pid=$(cat "$H/check-pid")
    for i in $(seq 1 100); do kill -0 "$check_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$check_pid" 2>/dev/null; then fail "$mode left its check running"; fi
    assert_no_grep 'live_wait_state=expired' "$H/state/th.meta" "$mode grants no expiry waiver"
  done
  pass "initial/later hanging checks and cancellation stop bounded child work"
}

case_live_wait_evidence() {
  local shape until state gen status rc
  for shape in expired waiting completed error huge zero leading-zero future generation superseded cancelled; do
    H="$TMP_ROOT/h-evidence-$shape"; new_task "$H" tv
    handoff "$H/input.md" "file:$H/result"
    until=$(( $(date +%s) - 1 )); state=expired; gen=g1
    status='working [at=1]: threshold reached'
    case "$shape" in
      waiting|completed|error) state=$shape ;;
      huge) until=999999999999999999999999 ;;
      zero) until=0 ;;
      leading-zero) until=01 ;;
      future) until=$(( $(date +%s) + 600 )) ;;
      generation) gen=g0 ;;
    esac
    printf '%s\n' "live_wait_when=file:$H/result" "live_wait_until=$until" "live_wait_state=$state" \
      "live_wait_gen=$gen" "live_wait_status=$status" >> "$H/state/tv.meta"
    printf '%s\n' "$status" > "$H/state/tv.status"
    [ "$shape" != superseded ] || printf 'working [at=2]: other work\n' >> "$H/state/tv.status"
    [ "$shape" != cancelled ] || park "$H" cancel tv >/dev/null
    rc=0; self_park "$H" tv --handoff "$H/input.md" --expect +60 >/dev/null || rc=$?
    if [ "$shape" = expired ]; then
      expect_code 0 "$rc" 'the current continuous wait expiry authorizes parking'
      FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-tv >/dev/null 2>&1 || true
    else
      expect_code 4 "$rc" "$shape evidence cannot waive a new short wait"
      assert_absent "$H/control.log" "$shape evidence stops no session"
    fi
  done
  pass "only validated expiry in the current incarnation and uninterrupted status permits parking"
}

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
    "$AGENT" "$3" "$1/wt-$2" "$PARK" "$2" --handoff "$4" --expect +7200
}

case_claude_background_refusal() {
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
}

# --- other harnesses keep their park behavior ----------------------------------
case_other_harness_background() {
  H="$TMP_ROOT/h-bg-codex"; new_task "$H" t11
  awk '{ sub(/^harness=claude$/, "harness=codex") } 1' "$H/state/t11.meta" > "$H/t11.meta" && mv "$H/t11.meta" "$H/state/t11.meta"
  handoff "$TMP_ROOT/t11.md" "file:$TMP_ROOT/t11-results"
  out=$(self_park_as_agent "$H" t11 1 "$TMP_ROOT/t11.md" 2>&1) || fail "a non-Claude self-park was refused: $out"
  assert_contains "$out" "this session stops in a few seconds" "a non-Claude self-park is unaffected by background shells"
  for _ in $(seq 1 100); do [ -s "$H/control.log" ] && break; sleep 0.1; done
  FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" retire park-t11 >/dev/null 2>&1 || true
  pass "the background-work refusal applies only to Claude workers"
}

# Saved work uses real Git objects, not a stubbed preservation verdict.
case_copy_free_qualification() {
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
  # The file and receipt kinds go through the same evaluator as declared waits.
  rc=0; FM_HOME="$home" "$PARK" check "file:$home/no-result" >/dev/null || rc=$?
  [ "$rc" = 1 ] || fail "an absent file condition did not answer not yet (rc $rc)"
  : > "$home/result"
  FM_HOME="$home" "$PARK" check "receipt:$home/result" >/dev/null || fail 'a present receipt condition was not met'
  printf 'tamper\n' >> "$home/data/$id/suspension.bundle"
  suspend_lib "$dir" fm_suspend_validate "$meta" "$id" "$home" "$home/data" && fail 'bundle corruption validated'
  pass 'copy-free qualification is off by default, uses continuous 24h/immediate policy, refuses dirty/unknown work and proves its saved head'
}

# Re-arm preserves continuous age, but genuine new work resets it.
case_wait_age() {
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
}

# Portable end-to-end release: fake terminals/native leases, real preservation,
# locks and policy checks. No local test run is needed to exercise it in CI.
release_scenario_case() {  # <scenario>
  local scenario=$1
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
}

# Manual/tokenless entry cannot bypass the registered bounded action.
case_release_entrypoint() {
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
}

# A short, relocation-safe wait resolves before the 24-hour release threshold.
# Resuming it must retire the optional release source even if it never fired.
case_resume_before_release() {
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
}

# Timeout belongs to the action, not the cheap condition. An injected slow
# native close occurs after real saved-custody preparation; the standard when
# runner must immediately capture failure and the release must clean its locks.
# The injected close sleeps exactly the release bound, so the release's own
# shorter work deadline (bound minus its two-second headroom), not an outer TERM
# trap or an extra test delay, must provide cleanup. The bound is 15 seconds,
# not the 5-second minimum, so loaded runners still finish the real custody
# preparation inside the 13-second work deadline before the close starts.
case_release_timeout() {
  id=release-timeout; dir=$(suspend_case "$TMP_ROOT" "$id") || fail 'timeout fixture failed'
  home="$dir/home"; meta="$home/state/$id.meta"
  suspend_idle_terminal "$dir" "$id"
  printf 'on\n' > "$home/config/park-release"; printf '15\n' > "$dir/slow-kill"
  FAKE_CONTROL_LOG="$home/control.log" FM_PARK_CONTROL_OVERRIDE="$CONTROL" FM_PARK_RELEASE_TIMEOUT=15 suspend_park "$dir" "$id" --handoff "$home/data/$id/handoff.md" --relocation-safe > "$dir/out" 2>&1 || fail 'timeout park registration failed'
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
}

# Ordinary save refusals are not action failures. Inject only the save step;
# qualification/ownership must still run, and original custody stays retained.
save_refusal_case() {  # <refusal>
  local refusal=$1
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
}

# Every timed preparation step can consume the budget, not only bundle/import.
# Expiry must fail the action, retain custody and clean locks, never masquerade
# as dirty/job/evidence qualification or reach return/endpoint close.
save_timeout_case() {  # <step>
  local step=$1
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
    command -v grep > "$dir/real-grep"
    cat > "$dir/fakebin/grep" <<'SH'
#!/usr/bin/env bash
# Delay the evidence content pass, not unrelated metadata/qualification work.
if [ "${1-}" = -IHF ]; then /bin/sleep 8; fi
exec "$(cat "$SUSPEND_DIR/real-grep")" "$@"
SH
    chmod +x "$dir/fakebin/grep"
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
}

# A hard kill cannot run traps, and a separately grouped child may survive.
# The next listener/restore entry only notifies uncertainty: it must preserve
# every lock/record/lease/copy without cleanup or native retry.
hard_kill_case() {  # <entry>
  local entry=$1
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
}

case_live_attempt_backstop() {
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
}

# A bare live PID is not proof of this release parent. Exercise missing,
# mismatched (PID reuse), and unreadable identity without touching custody.
identity_uncertainty_case() {  # <uncertainty>
  local uncertainty=$1
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
}

pid_uncertainty_case() {  # <uncertainty>
  local uncertainty=$1
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
}

case_notification_failure() {
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
    --stable 1 --interval 0.2 --deadline 20 --error-budget 2 \
    --condition "$PARK" poll "$id" p1 --action /bin/true >/dev/null || fail 'could not arm notification-failure fallback'
  fm_test_track_procevent_home "$home"
  SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "when-notification-$id" \
    > "$dir/fallback" 2>&1 || fail 'notification failure fallback was not durably captured'
  result=$(first_result "$home" "when-notification-$id") || fail 'no owner-visible condition-error result was published'
  assert_equals condition-error "$(FM_HOME="$home" "$WHEN" classify "$result")" 'notification failure did not wake through the existing error-budget outcome'
  suspend_park "$dir" resume "$id" p1 > "$dir/resume" 2>&1 && fail 'notification failure restored work'
  assert_present "${wt%/*}/.fm-slot-owner" 'notification failure returned protected work'
  pass 'failed custody notification uses the existing condition-error outcome without new channels or restore'
}

case_pickup_authority() {
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
}

# pool_param_cases <function> <value>...: fm_run_case_pool runs bare function
# names, so each value of a parameterized case gets its own argument-free
# wrapper, appended to POOL_CASES in value order.
POOL_CASES=()
pool_param_cases() {
  local fn=$1 value wrapper
  shift
  for value in "$@"; do
    wrapper="${fn}_${value//-/_}"
    eval "$wrapper() { $fn $value; }"
    POOL_CASES+=("$wrapper")
  done
}

# Every case builds its own home or saved-task fixture under a name of its own
# (task ids, and so process-event source ids in the shared claim root, are
# unique per case) and acts only on processes it started, so no case depends on
# another or on their order. They run through fm_run_case_pool (tests/lib.sh),
# the ones that sit through real deadlines first. FM_PARK_CASE_JOBS overrides
# the concurrency, which defaults to the host's processor count capped at four;
# 1 runs the cases serially.
POOL_CASES+=(case_release_timeout)
pool_param_cases save_timeout_case bundle import clean quiet evidence
POOL_CASES+=(case_deadline_wakes_supervisor case_resume_and_repark
  case_superseded_resume case_failed_relaunch case_notification_failure)
POOL_CASES+=(case_handoff_validation case_park_refuses_missing_handoff case_queue_adoption_refusal
  case_park_records_and_rearms case_default_cadence case_park_resolves_its_directory
  case_poll_answers_in_the_shell case_inbox_pickup_request case_delivery_resumes_inbox_park
  case_inbox_pickup_race case_inbox_hint_request_shapes
  case_cross_home_conditions
  case_kind_default_deadlines case_park_time_refusal case_self_park_detached_exit
  case_self_park_by_task_id case_self_park_exit_failure case_claude_background_refusal
  case_other_harness_background case_copy_free_qualification case_wait_age
  case_live_wait_rule case_live_wait_clock_boundary case_live_wait_requested case_live_wait_exemptions case_live_wait_threshold_file
  case_await_holds case_await_single_owner case_await_superseded case_await_bound case_await_errors case_await_hanging_checks case_live_wait_evidence)
pool_param_cases release_scenario_case off true nm raw dependency symlink route job bad-endpoint lease kill return reuse park stop poll
POOL_CASES+=(case_release_entrypoint case_resume_before_release)
pool_param_cases save_refusal_case profile branch mktemp jq rev-parse
pool_param_cases hard_kill_case poll resume control
POOL_CASES+=(case_live_attempt_backstop)
pool_param_cases identity_uncertainty_case identity-missing identity-mismatch identity-unreadable stale-receipt
pool_param_cases pid_uncertainty_case missing malformed
POOL_CASES+=(case_pickup_authority)
case_jobs=$(fm_case_pool_jobs "${FM_PARK_CASE_JOBS:-}")
fm_run_case_pool "$case_jobs" "$TMP_ROOT/.case-logs" "${POOL_CASES[@]}" || exit 1
