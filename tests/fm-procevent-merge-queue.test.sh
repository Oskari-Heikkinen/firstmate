#!/usr/bin/env bash
# Behavior tests for the merge-queue owner-side glue
# (bin/fm-procevent-merge-queue.sh).
#
# Every scenario drives a fake queue directory (queue.log, handoff.sh, and an
# optional result.sh) through the adapter's public commands and the generic
# process-event runner. The lifecycle owners settle delegates to - teardown,
# relaunch, and the clone refresh - are replaced by recording stubs through the
# adapter's documented override variables, so each call and its arguments are
# observable without a live worker. Nothing here asserts implementation bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-merge-queue-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_MERGE_QUEUE_INTERVAL=0.1
CALLS="$TMP_ROOT/calls"
export FM_MERGE_QUEUE_TEARDOWN_BIN="$TMP_ROOT/stub-teardown"
export FM_MERGE_QUEUE_CONTROL_BIN="$TMP_ROOT/stub-control"
export FM_PARK_CONTROL_OVERRIDE="$TMP_ROOT/stub-control"
export FM_MERGE_QUEUE_FLEET_SYNC_BIN="$TMP_ROOT/stub-fleet-sync"
export FM_MERGE_QUEUE_SEND_BIN="$TMP_ROOT/stub-send"

cat > "$FM_MERGE_QUEUE_TEARDOWN_BIN" <<SH
#!/usr/bin/env bash
echo "teardown \$*" >> "$CALLS"
"$ROOT/bin/fm-tasks-axi.sh" show "\$1" --full > "$TMP_ROOT/body-at-cleanup"
if ! grep -q '^done' "\$FM_HOME/state/\$1.status"; then
  echo "error: cleanup needs the task completion line" >&2
  exit 1
fi
if [ -e "$TMP_ROOT/refuse-teardown" ]; then
  echo "error: teardown refused: worktree has uncommitted changes" >&2
  exit 1
fi
# The runner must prove the park incarnation and retire before cleanup,
# including when its classifier has not been loaded by any status presenter.
sid=\$(sed -n 's/^park_source=//p' "\$FM_HOME/state/\$1.meta" | tail -1)
if [ -e "\$FM_HOME/state/procevent/\$sid.source" ]; then
  echo "error: adopted queue source was still registered at cleanup" >&2
  exit 1
fi
# Production cleanup retires directly under its existing metadata lock, never
# re-entering park cancel (and now also the outer transition lock).
"$ROOT/bin/fm-procevent.sh" retire "\$sid" >/dev/null || exit 1
cp "\$FM_HOME/state/\$1.status" "$TMP_ROOT/status-at-cleanup"
rm -f "\$FM_HOME/state/\$1.status"
echo "cleanup-returned \$1" >> "$CALLS"
SH
cat > "$FM_MERGE_QUEUE_CONTROL_BIN" <<SH
#!/usr/bin/env bash
echo "control \$1 \$2 \${3-}" >> "$CALLS"
if [ "\$2" = relaunch ]; then
  [ ! -e "$TMP_ROOT/refuse-control" ] || exit 1
  cat "\$4" > "$TMP_ROOT/relaunch-note"
  gen=\$(awk -F= '\$1 == "spawn_gen" {g=\$2} END {print g}' "\$FM_HOME/state/\$1.meta")
  printf 'spawn_gen=%s.resumed\n' "\$gen" >> "\$FM_HOME/state/\$1.meta"
  # Fixture-only replacement at the relaunch/retirement boundary.
  [ ! -f "\$FM_HOME/relaunch-owner" ] || cat "\$FM_HOME/relaunch-owner" >> "\$FM_HOME/state/\$1.meta"
  [ ! -e "\$FM_HOME/unconfirmed-control" ] || exit 1
fi
SH
cat > "$FM_MERGE_QUEUE_FLEET_SYNC_BIN" <<SH
#!/usr/bin/env bash
echo "fleet-sync \$*" >> "$CALLS"
SH
cat > "$FM_MERGE_QUEUE_SEND_BIN" <<SH
#!/usr/bin/env bash
printf 'send %s\\n' "\$*" >> "$CALLS"
if [ -e "$TMP_ROOT/fail-live-status" ]; then
  mv "\$FM_HOME/state/\$1.status" "\$FM_HOME/status-before-failure"
  mkdir "\$FM_HOME/state/\$1.status"
fi
SH
chmod +x "$FM_MERGE_QUEUE_SEND_BIN" "$FM_MERGE_QUEUE_TEARDOWN_BIN" "$FM_MERGE_QUEUE_CONTROL_BIN" "$FM_MERGE_QUEUE_FLEET_SYNC_BIN"

mq() { FM_HOME="$1" "$ROOT/bin/fm-procevent-merge-queue.sh" "${@:2}"; }
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
# The key that ends a home's receipt names, read from its one owner.
rkey() { python3 "$ROOT/bin/fm-handoff-firstmate.py" watch-target --home "$1" | sed -n 2p; }

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MAIN=cccccccccccccccccccccccccccccccccccccccc

# A queue directory whose handoff.sh appends the documented HANDOFF line, or
# refuses when the refuse flag exists.
new_queue() {  # <dir>
  mkdir -p "$1"
  : > "$1/queue.log"
  cat > "$1/handoff.sh" <<'SH'
#!/usr/bin/env bash
q=$(dirname "$0")
[ ! -e "$q/refuse" ] || { echo "origin branch is absent: push first" >&2; exit 1; }
printf 'HANDOFF 2026-09-27T18:00:00Z home=%s task=%s branch=%s head=%s note=%s\n' "$1" "$2" "$3" "$4" "$5" >> "$q/queue.log"
SH
  chmod +x "$1/handoff.sh"
}

# A home holding one ship task record and a merge-queue config.
new_home() {  # <home> <queue> <task>
  mkdir -p "$1/state" "$1/config" "$1/project" "$1/data"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$1/data/backlog.md"
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" add "$3" 'queue task' --body 'Keep the existing task note.' >/dev/null || fail "could not seed the queue task"
  FM_HOME="$1" "$ROOT/bin/fm-tasks-axi.sh" start "$3" >/dev/null || fail "could not start the queue task"
  printf 'dir=%s\nhome=test-home\n' "$2" > "$1/config/merge-queue"
  printf 'kind=ship\nspawn_gen=g1\nmode=direct-push\nproject=%s\n' "$1/project" > "$1/state/$3.meta"
  fm_test_track_procevent_home "$1" "$FM_PROCEVENT_CLAIM_ROOT"
}

# Make <home> a secondmate home reporting into <parent>'s status channel.
make_secondmate() {  # <home> <parent> <mate-id>
  mkdir -p "$2/state"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.fm-secondmate-parent"
  printf '%s\n' "$3" > "$1/.fm-secondmate-home"
}

wait_for() {  # <command...>: poll up to 15s
  local _
  for _ in $(seq 1 150); do "$@" && return 0; sleep 0.1; done
  return 1
}
source_gone() { [ ! -e "$1/state/procevent/$2.source" ]; }
path_gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }
handled_count() { find "$1/state/procevent-inbox" -name '*.handled' 2>/dev/null | wc -l | tr -d ' '; }
handled_is() { [ "$(handled_count "$1")" = "$2" ]; }

# --- handoff: hands over, arms, records the wait -----------------------------
Q="$TMP_ROOT/q-handoff"; new_queue "$Q"
H="$TMP_ROOT/h-handoff"; new_home "$H" "$Q" t1
out=$(mq "$H" handoff t1 fm/t1 "$HEAD_A" --resume-note "rebase onto main and rerun the gate" -- first try)
assert_contains "$out" "handed: t1 $HEAD_A" "handoff reports the handed head"
assert_grep "HANDOFF 2026-09-27T18:00:00Z home=test-home task=t1 branch=fm/t1 head=$HEAD_A note=first try" "$Q/queue.log" \
  "handoff runs the queue's handoff.sh with the configured home name"
sid=$(mq "$H" source-id t1 "$HEAD_A")
assert_equals "merge-queue-t1-aaaaaaaa" "$sid" "the source id names the task and head"
assert_present "$H/state/procevent/$sid.source" "handoff arms the watch"
key=$(rkey "$H")
assert_equals main "${key%-*}" "an unmarked home's key starts with main, not its configured queue name"
assert_present "$Q/watches/$HEAD_A.$sid.$key.json" "handoff leaves the watch receipt, named by this home's key"
assert_grep "paused [key=merge-queue] [wait=merge-result:$HEAD_A] [at=" "$H/state/t1.status" "handoff declares the existing wait tag"
assert_grep "result-ready $HEAD_A" "$H/state/t1.status" "the paused wait names the configured result check"
assert_grep "park_state=parked" "$H/state/t1.meta" "handoff parks through the existing mechanism"
assert_grep "park_source=$sid" "$H/state/t1.meta" "park adopts the queue watch"
assert_absent "$H/state/procevent/when-park-t1.source" "adoption creates no duplicate resume watch"
assert_grep "control t1 exit" "$CALLS" "park stops the worker"
if FM_HOME="$H" "$ROOT/bin/fm-park.sh" resume t1 2>"$TMP_ROOT/adopt-resume.err"; then
  fail "park resume must not relaunch a task owned by its adopted queue source"
fi
assert_grep "adopted queue source owns" "$TMP_ROOT/adopt-resume.err" "resume names the queue action owner"
assert_no_grep "relaunch" "$CALLS" "adopted park resume never invokes the control relaunch"
assert_present "$H/state/procevent/$sid.source" "refused resume preserves the owning queue source"
FM_HOME="$H" "$ROOT/bin/fm-park.sh" cancel t1 >/dev/null
assert_absent "$H/state/procevent/$sid.source" "ordinary cancel retires the adopted source"
assert_absent "$Q/watches/$HEAD_A.$sid.$key.json" "park cancel's retirement removes the watch receipt"
pass "handoff hands the head over, arms its watch, and declares the wait"

touch "$Q/refuse"
if mq "$H" handoff t1 fm/t1 "$HEAD_B" --resume-note 'must not replace earlier instructions' -- again 2>"$TMP_ROOT/refused.err"; then
  fail "a refused queue handoff must fail"
fi
assert_grep "refused the handoff" "$TMP_ROOT/refused.err" "the refusal is reported"
assert_absent "$H/state/procevent/merge-queue-t1-bbbbbbbb.source" "a refused handoff arms nothing"
assert_absent "$Q/watches/$HEAD_B.merge-queue-t1-bbbbbbbb.$key.json" "a refused handoff writes no watch receipt"
assert_no_grep "$HEAD_B" "$H/state/t1.status" "a refused handoff declares no wait"
assert_equals 'rebase onto main and rerun the gate' "$(cat "$H/state/merge-queue/t1.resume")" 'queue refusal preserves the previous head continuation'
assert_grep "$HEAD_A" "$H/data/t1/handoff.md" 'queue refusal preserves the previous handoff'
assert_no_grep "$HEAD_B" "$H/data/t1/handoff.md" 'queue refusal never installs the rejected handoff'
rm -f "$Q/refuse"
if mq "$H" handoff nosuch fm/x "$HEAD_A" -- x 2>/dev/null; then
  fail "handoff for a task this home does not hold must be refused"
fi
pass "a refused or foreign handoff arms and records nothing"

# --- policy validation precedes every external submission/registration -------
for refusal in estimate empty-estimate threshold custody generation release-bound deadline check-error; do
  Q="$TMP_ROOT/q-policy-$refusal"; new_queue "$Q"
  H="$TMP_ROOT/h-policy-$refusal"; new_home "$H" "$Q" t1
  mkdir -p "$H/state/merge-queue" "$H/data/t1"
  printf 'earlier handoff\n' > "$H/data/t1/handoff.md"
  printf 'earlier head continuation\n' > "$H/state/merge-queue/t1.resume"
  estimate=+60; release_bound=1800; deadline=10800
  case "$refusal" in
    estimate) estimate=not-a-time ;;
    empty-estimate) estimate='' ;;
    threshold) printf 'broken\n' > "$H/config/park-live-wait-minutes" ;;
    custody) printf 'copy_state=saved\n' >> "$H/state/t1.meta" ;;
    generation) grep -v '^spawn_gen=' "$H/state/t1.meta" > "$H/meta"; mv "$H/meta" "$H/state/t1.meta" ;;
    release-bound) release_bound=bad ;;
    deadline) deadline=bad ;;
    check-error) rm "$Q/queue.log" ;;
  esac
  : > "$CALLS"
  if FM_TASK_ID=t1 FM_PARK_RELEASE_TIMEOUT="$release_bound" FM_PARK_DEADLINE_SECS="$deadline" \
      mq "$H" handoff t1 fm/t1 "$HEAD_A" --priority pipeline --expect "$estimate" --resume-note 'new head continuation' -- policy > "$H/out" 2>&1; then
    fail "$refusal policy was accepted"
  fi
  if [ -f "$Q/queue.log" ]; then
    assert_no_grep HANDOFF "$Q/queue.log" "$refusal must refuse before queue submission"
  fi
  assert_absent "$H/state/procevent/merge-queue-t1-aaaaaaaa.source" "$refusal must refuse before source arming"
  assert_no_grep 'park_state=' "$H/state/t1.meta" "$refusal adopts no wait"
  assert_equals '' "$(cat "$CALLS")" "$refusal stops no worker"
  assert_equals 'earlier head continuation' "$(cat "$H/state/merge-queue/t1.resume")" "$refusal preserves the previous head continuation"
  assert_equals 'earlier handoff' "$(cat "$H/data/t1/handoff.md")" "$refusal preserves the previous handoff"
done
pass 'all refusing park policies run before queue submission and source registration'

Q="$TMP_ROOT/q-legacy"; new_queue "$Q"
H="$TMP_ROOT/h-legacy"; new_home "$H" "$Q" t1
FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" -- legacy >/dev/null || fail 'old worker handoff was refused'
assert_grep 'park_state=parked' "$H/state/t1.meta" 'omitted estimate preserves legacy queue parking'
assert_grep HANDOFF "$Q/queue.log" 'legacy command submits the head'
assert_present "$H/state/procevent/merge-queue-t1-aaaaaaaa.source" 'legacy command adopts its source'
pass 'old worker briefs without an estimate still park at queue handoff'

# --- priority: exact argv and refusal ownership -----------------------------
Q="$TMP_ROOT/q-priority"; new_queue "$Q"
H="$TMP_ROOT/h-priority"; new_home "$H" "$Q" t1
cat > "$Q/handoff.sh" <<'SH'
#!/usr/bin/env bash
q=$(dirname "$0")
printf '%s\n' "$@" > "$q/argv"
if [ "${1-}" = --priority ]; then
  if [ -e "$q/old-adapter" ]; then
    echo 'refused: unknown argument --priority' >&2
    exit 2
  fi
  [ "$2" = pipeline ] || { printf "refused: unknown priority '%s'; one of: pipeline\n" "$2" >&2; exit 2; }
  shift 2
fi
printf 'HANDOFF 2026-09-27T18:00:00Z home=%s task=%s branch=%s head=%s note=%s\n' "$1" "$2" "$3" "$4" "$5" >> "$q/queue.log"
SH
chmod +x "$Q/handoff.sh"
FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 --priority pipeline --resume-note 'keep context' -- 'blocks other work' >/dev/null
assert_grep 'park_state=live' "$H/state/t1.meta" 'priority preserves expected-time live waiting'
assert_equals 1 "$(grep -c '^HANDOFF ' "$Q/queue.log")" 'priority submits exactly once after policy validation'
expected=$(printf '%s\n' --priority pipeline test-home t1 fm/t1 "$HEAD_A" 'blocks other work')
assert_equals "$expected" "$(cat "$Q/argv")" "priority is two words before all five positionals"
assert_grep 'keep context' "$H/state/merge-queue/t1.resume" "priority composes with resume notes"
FM_HOME="$H" "$ROOT/bin/fm-park.sh" cancel t1 >/dev/null
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- normal note >/dev/null
expected=$(printf '%s\n' test-home t1 fm/t1 "$HEAD_A" 'normal note')
assert_equals "$expected" "$(cat "$Q/argv")" "no option preserves the original five argv words"
FM_HOME="$H" "$ROOT/bin/fm-park.sh" cancel t1 >/dev/null
for value in urgent '' 'pipeline urgent'; do
  rc=0
  mq "$H" handoff t1 fm/t1 "$HEAD_B" --priority "$value" -- refused >"$Q/out" 2>"$Q/err" || rc=$?
  assert_equals 2 "$rc" "unknown priority keeps the queue exit status"
  expected=$(printf '%s\n' --priority "$value" test-home t1 fm/t1 "$HEAD_B" refused)
  assert_equals "$expected" "$(cat "$Q/argv")" "unknown priority is forwarded without rewriting"
  assert_grep "refused: unknown priority '$value'; one of: pipeline" "$Q/err" "queue refusal stderr survives"
  assert_absent "$H/state/procevent/merge-queue-t1-bbbbbbbb.source" "unknown priority arms nothing"
done
touch "$Q/old-adapter"
rc=0
mq "$H" handoff t1 fm/t1 "$HEAD_B" --priority pipeline -- old >"$Q/out" 2>"$Q/err" || rc=$?
assert_equals 2 "$rc" "old adapter status survives"
assert_grep 'refused: unknown argument --priority' "$Q/err" "old adapter refusal survives"
assert_grep 'needs republishing' "$Q/err" "old adapter refusal explains installation requirement"
assert_no_grep "$HEAD_B" "$Q/queue.log" "no silent normal-handoff fallback"
assert_absent "$H/state/procevent/merge-queue-t1-bbbbbbbb.source" "old adapter refusal arms nothing"
# Both option orders must refuse before calling the queue, even a permissive one.
rm -f "$Q/old-adapter"
for order in before after; do
  rm -f "$Q/argv"
  rc=0
  if [ "$order" = before ]; then
    mq "$H" handoff t1 fm/t1 "$HEAD_B" --test-only --priority pipeline -- rehearsal >"$Q/out" 2>"$Q/err" || rc=$?
  else
    mq "$H" handoff t1 fm/t1 "$HEAD_B" --priority pipeline --test-only -- rehearsal >"$Q/out" 2>"$Q/err" || rc=$?
  fi
  assert_equals 1 "$rc" "test-only plus priority refuses locally"
  assert_grep 'this adapter waits for landing results' "$Q/err" "test-only refusal names the lifecycle mismatch"
  assert_absent "$Q/argv" "test-only never reaches the queue"
done
for malformed in --priority --priority=pipeline; do
  rc=0
  mq "$H" handoff t1 fm/t1 "$HEAD_B" "$malformed" >"$Q/out" 2>"$Q/err" || rc=$?
  assert_equals 1 "$rc" "malformed priority option refuses"
  if [ "$malformed" = --priority ]; then
    assert_grep '--priority needs a value' "$Q/err" "missing value is a deliberate refusal, not an unbound-variable crash"
  else
    assert_grep 'use --priority <value>' "$Q/err" "equals syntax names the supported form"
  fi
  assert_absent "$Q/argv" "malformed priority never reaches the queue"
done
# The internal park/submit seam has deliberate argument refusals too.
rc=0
mq "$H" submit --priority >"$Q/out" 2>"$Q/err" || rc=$?
assert_equals 1 "$rc" 'submit missing priority value refuses'
assert_grep '--priority needs a value' "$Q/err" 'submit names its missing value'
rc=0
FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --queue-priority >"$Q/out" 2>"$Q/err" || rc=$?
assert_equals 1 "$rc" 'park missing priority value refuses'
assert_grep '--queue-priority needs a value' "$Q/err" 'park names its missing value'
rc=0
FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --queue-priority pipeline >"$Q/out" 2>"$Q/err" || rc=$?
assert_equals 1 "$rc" 'priority without submission refuses'
assert_grep 'queue priority requires submission' "$Q/err" 'park never silently ignores priority'
assert_absent "$Q/argv" 'internal argument refusals never call the queue'
pass "priority preserves argv, refusal ownership, and landing-only lifecycle"

# --- result: pending, taken, final, and the train's read helper ---------------
Q="$TMP_ROOT/q-result"; new_queue "$Q"
H="$TMP_ROOT/h-result"; new_home "$H" "$Q" t1
printf 'HANDOFF 2026-09-27T18:00:00Z home=h task=t1 branch=b head=%s note=x\n' "$HEAD_A" >> "$Q/queue.log"
assert_equals "" "$(mq "$H" result "$HEAD_A")" "a pending head has no result"
printf 'RESULT 2026-09-27T18:01:00Z head=%s outcome=taken main=- note=car-1\n' "$HEAD_A" >> "$Q/queue.log"
assert_equals "" "$(mq "$H" result "$HEAD_A")" "taken is progress, never final"
printf 'RESULT 2026-09-27T18:02:00Z head=%s outcome=landed main=%s files=2 identical=2 differ=- dropped=- note=car-1\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
assert_contains "$(mq "$H" result "$HEAD_A")" "outcome=landed main=$MAIN" "the final result is read from queue.log"
cat > "$Q/result.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "$HEAD_A" ] || exit 0
echo "RESULT t head=\$1 outcome=taken main=- note=claimed"
SH
chmod +x "$Q/result.sh"
assert_equals "" "$(mq "$H" result "$HEAD_A")" "helper taken RESULT is pending, not unreadable"
mq "$H" result-ready "$HEAD_A" >/dev/null; rc=$?
expect_code 1 "$rc" "helper taken RESULT keeps the declared wait pending"
cat > "$Q/result.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "$HEAD_A" ] || exit 0
echo "RESULT 2026-09-27T18:03:00Z head=\$1 outcome=culprit main=- home=h task=t1 note=from helper"
SH
assert_contains "$(mq "$H" result "$HEAD_A")" "note=from helper" "the train's result.sh is preferred when it exists"
rm -f "$Q/queue.log"
assert_contains "$(mq "$H" result "$HEAD_A")" "note=from helper" "result.sh alone is enough to read results"
rm -f "$Q/result.sh"
mq "$H" result "$HEAD_A" >/dev/null 2>&1; rc=$?
expect_code 2 "$rc" "an unreadable queue is an error, not a pending head"
pass "result reads pending, progress, and final lines through either source"

# --- landed with every file identical: settled with no firstmate wake ----------
Q="$TMP_ROOT/q-clean"; new_queue "$Q"
H="$TMP_ROOT/h-clean"; new_home "$H" "$Q" t1
P="$TMP_ROOT/p-clean"; make_secondmate "$H" "$P" mate1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- clean >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
key=$(rkey "$H")
assert_equals mate1 "${key%-*}" "a secondmate home's key starts with its own id"
assert_present "$Q/watches/$HEAD_A.$sid.$key.json" "a secondmate home names its watch receipt by its own key"
pe "$H" reconcile >/dev/null
printf 'RESULT 2026-09-27T18:02:00Z head=%s outcome=taken main=- note=car-9\n' "$HEAD_A" >> "$Q/queue.log"
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=landed main=%s files=15 identical=15 differ=- dropped=- note=car-9; gate green; evidence .merge-agent/evidence/fbd6f77b\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
wait_for source_gone "$H" "$sid" || {
  pe "$H" list >&2
  fail "the landed watch did not end"
}
wait_for path_gone "$Q/watches/$HEAD_A.$sid.$key.json" || fail "a watch that ends on its result removes its receipt"
wait_for handled_is "$H" 1 || fail "cleanup killed its runner before acknowledgement"
assert_grep "cleanup-returned t1" "$CALLS" "cancelling the adopted watch during cleanup returns without killing its own runner"
assert_present "$(compgen -G "$H/state/procevent-inbox/$sid.*.result" | head -1)" "terminal retirement preserves captured evidence"
wait_for grep -q "^teardown t1" "$CALLS" || fail "cleanup was not run"
assert_no_grep "fleet-sync" "$CALLS" "a clean landing leaves the clone refresh to cleanup, so the clone is fetched once"
assert_absent "$H/state/t1.status" "successful cleanup never recreates an orphan status log"
assert_grep "done [at=" "$TMP_ROOT/status-at-cleanup" "cleanup reads the task's completion line"
assert_grep "landed $MAIN on main through the merge queue" "$TMP_ROOT/status-at-cleanup" "the done line names the main commit"
assert_grep "files=15 identical=15, evidence .merge-agent/evidence/fbd6f77b" "$TMP_ROOT/status-at-cleanup" \
  "the done line records the per-file counts and the evidence path taken from the note"
assert_grep "Keep the existing task note." "$TMP_ROOT/body-at-cleanup" "the previous task note is preserved"
assert_grep "files=15 identical=15, evidence .merge-agent/evidence/fbd6f77b" "$TMP_ROOT/body-at-cleanup" \
  "the per-file receipt is in the task note before cleanup"
assert_grep "done [key=merge-queue-landed-t1-aaaaaaaa]" "$P/state/mate1.status" \
  "a successful cleanup publishes the landed parent outcome"
wait_for handled_is "$H" 1 || fail "the settled result was not acknowledged"
assert_not_contains "$(wake_payloads "$H")" "procevent merge-queue" "a settled landing wakes no firstmate turn"
pass "a clean landing refreshes the clone, writes done, and cleans up without a wake"

# --- a resolved blocker after the queue wait: cleanup still keeps its runner ---
# Park could not stop the worker, so the status log gained a blocked line and its
# resolution after the merge-result pause. The runner must still retire its own
# source before cleanup, or cleanup's park retirement kills the runner after the
# copy's return and before the task record closes.
Q="$TMP_ROOT/q-masked"; new_queue "$Q"
H="$TMP_ROOT/h-masked"; new_home "$H" "$Q" t1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- masked >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'blocked [at=%s]: parked and its resume watch armed, but this session could not be stopped\n' "$(date +%s)" >> "$H/state/t1.status"
printf 'resolved [at=%s]: the session was stopped; the merge-queue watch owns the result\n' "$(date +%s)" >> "$H/state/t1.status"
pe "$H" reconcile >/dev/null
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=landed main=%s files=2 identical=2 differ=- dropped=- note=car-3\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
wait_for source_gone "$H" "$sid" || fail "the landed watch did not end behind a resolved blocker"
wait_for handled_is "$H" 1 || fail "cleanup behind a resolved blocker was not acknowledged"
assert_grep "cleanup-returned t1" "$CALLS" "a resolved blocker after the queue wait still retires the source before cleanup"
assert_equals 1 "$(compgen -G "$H/state/procevent-inbox/$sid.*.result" | wc -l | tr -d ' ')" "the landed result is captured and settled once"
pass "a resolved blocker after the queue wait does not let cleanup kill its own runner"

# --- cleanup refusal: stop, report why, and wake firstmate ---------------------
Q="$TMP_ROOT/q-refuse"; new_queue "$Q"
H="$TMP_ROOT/h-refuse"; new_home "$H" "$Q" t1
P="$TMP_ROOT/p-refuse"; make_secondmate "$H" "$P" mate1
: > "$CALLS"; touch "$TMP_ROOT/refuse-teardown"
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- refuse >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=landed main=%s home=test-home task=t1 files=3 identical=3 differ=- dropped=- evidence=/ev/1 note=car\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for grep -qs "procevent merge-queue $sid" "$H/state/.wake-queue" || fail "a refused cleanup did not wake firstmate"
assert_grep "blocked [key=merge-queue-cleanup]" "$H/state/t1.status" "the refusal is recorded on the task"
assert_grep "uncommitted changes" "$H/state/t1.status" "the refusal names why"
assert_grep "fleet-sync $H/project" "$CALLS" "a refused cleanup never reached its own refresh, so settle refreshes the landed clone"
assert_grep "task t1 head $HEAD_A landed on main at $MAIN but cleanup refused" "$P/state/mate1.status" \
  "the refusal reaches the parent channel with the actual landing commit"
assert_contains "$(tail -1 "$H/state/t1.status")" "blocked [key=merge-queue-cleanup]" "cleanup refusal overrides the pre-cleanup completion line"
assert_no_grep "done" "$P/state/mate1.status" "a cleanup refusal publishes no parent completion"
assert_grep "files=3 identical=3, evidence /ev/1" "$TMP_ROOT/body-at-cleanup" \
  "the landing proof survives in the task note even when cleanup refuses"
assert_grep "evidence /ev/1" "$TMP_ROOT/body-at-cleanup" "the evidence= field is used when present"
assert_equals 0 "$(handled_count "$H")" "a refused cleanup is left for firstmate"
rm -f "$TMP_ROOT/refuse-teardown"
pass "a cleanup refusal is never bypassed: it is reported and left for firstmate"

# --- landed with a differing file: one parent decision, nothing cleaned --------
Q="$TMP_ROOT/q-differ"; new_queue "$Q"
H="$TMP_ROOT/h-differ"; new_home "$H" "$Q" t1
P="$TMP_ROOT/p-differ"; make_secondmate "$H" "$P" mate1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- differ >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=landed main=%s files=8 identical=6 differ=docs/a.md,web/b.css dropped=- note=car\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for handled_is "$H" 1 || fail "the unproven landing was not settled"
assert_grep "needs-decision [key=merge-queue-t1-aaaaaaaa]" "$P/state/mate1.status" "one parent decision is posted"
assert_grep "differ=docs/a.md,web/b.css" "$P/state/mate1.status" "the decision names the files"
assert_no_grep "teardown" "$CALLS" "nothing is cleaned up"
pass "a landing with a differing file posts one parent decision and cleans nothing"

# The same outcome in a main home has no parent channel, so it wakes firstmate.
Q="$TMP_ROOT/q-differ-main"; new_queue "$Q"
H="$TMP_ROOT/h-differ-main"; new_home "$H" "$Q" t1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- differ >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=landed main=%s note=old format without the per-file check\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for grep -qs "procevent merge-queue $sid" "$H/state/.wake-queue" || fail "an unproven landing in a main home did not wake firstmate"
f=$(compgen -G "$H/state/procevent-inbox/$sid.*.result" | head -1)
assert_equals landed-unproven "$(mq "$H" classify "$f")" "a landing without per-file fields is unproven"
assert_no_grep "teardown" "$CALLS" "nothing is cleaned up in a main home either"
pass "an unproven landing in a main home wakes firstmate instead"

# --- culprit: relaunch in the existing copy with the result and resume note ----
Q="$TMP_ROOT/q-culprit"; new_queue "$Q"
H="$TMP_ROOT/h-culprit"; new_home "$H" "$Q" t1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" --resume-note "gate runs through the heavy slot" -- culprit >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=conflict main=- note=clashes with car-81\n' "$HEAD_A" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for grep -q "^control t1 relaunch --note-file" "$CALLS" || fail "the worker was not relaunched"
wait_for handled_is "$H" 1 || fail "the relaunch outcome was not acknowledged"
assert_grep "outcome=conflict main=- note=clashes with car-81" "$TMP_ROOT/relaunch-note" "the relaunch note carries the RESULT line"
assert_grep "gate runs through the heavy slot" "$TMP_ROOT/relaunch-note" "the relaunch note carries the resume note"
assert_grep "handoff t1" "$TMP_ROOT/relaunch-note" "the relaunch note says how to hand over again"
assert_no_grep "teardown" "$CALLS" "a conflict cleans nothing"
pass "a conflict relaunches the worker with the result and its resume note"

# --- short queue waits retain the session and the single settlement owner ----
for outcome in conflict precheck-unavailable landed; do
  Q="$TMP_ROOT/q-live-$outcome"; new_queue "$Q"
  H="$TMP_ROOT/h-live-$outcome"; new_home "$H" "$Q" t1
  : > "$CALLS"
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 --resume-note 'keep live context' -- short >/dev/null
  assert_grep 'park_state=live' "$H/state/t1.meta" "short $outcome wait stays live"
  assert_grep "[wait=merge-result:$HEAD_A]" "$H/state/t1.status" 'live wait is declared'
  assert_equals '' "$(cat "$CALLS")" 'short handoff never stops the worker'
  assert_absent "$H/state/procevent/when-park-t1.source" 'no competing live resume listener'
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=%s main=%s files=1 identical=1 note=fixture\n' "$HEAD_A" "$outcome" "$MAIN" >> "$Q/queue.log"
  pe "$H" reconcile >/dev/null
  wait_for handled_is "$H" 1 || fail "live $outcome result was not settled"
  wait_for source_gone "$H" "$sid" || fail 'live source was not retired'
  assert_no_grep 'control t1 relaunch' "$CALLS" 'a live worker is never relaunched for a queue result'
  assert_absent "$H/state/.park-churn/t1" 'a live result is not a parked resume'
  if [ "$outcome" != landed ]; then
    assert_grep 'send t1 --no-resume' "$CALLS" 'the result goes to the live inbox'
    assert_no_grep '--fire-and-forget' "$CALLS" 'live queue instructions retain the unread-message ladder'
    assert_grep 'keep live context' "$CALLS" 'the live continuation includes the handoff note'
    assert_grep 'park_state=completed' "$H/state/t1.meta" 'delivered live wait is completed'
    assert_grep 'park_source=' "$H/state/t1.meta" 'delivered live wait releases the retired owner'
    for mode in requested supervisor; do
      before_meta=$(cat "$H/state/t1.meta"); before_calls=$(cat "$CALLS")
      rc=0
      if [ "$mode" = requested ]; then
        FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested > "$H/stale.out" 2>&1 || rc=$?
      else
        FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" > "$H/stale.out" 2>&1 || rc=$?
      fi
      assert_equals 1 "$rc" "$mode completed queue handoff refuses nonzero"
      assert_grep "stale queue condition already completed: cmd:$ROOT/bin/fm-procevent-merge-queue.sh result-ready $HEAD_A" "$H/stale.out" 'refusal names the stale condition'
      assert_grep 'provide a current handoff' "$H/stale.out" 'refusal asks for a current handoff'
      assert_equals "$before_meta" "$(cat "$H/state/t1.meta")" 'stale refusal preserves completed ownership'
      assert_equals "$before_calls" "$(cat "$CALLS")" 'stale refusal stops or launches no worker'
      assert_absent "$H/state/procevent/when-park-t1.source" 'stale refusal creates no generic listener'
    done
    printf '## Goal\ng\n## Done\nd\n## Waiting for\nfile:%s/next\n## Next steps\nn\n' "$H" > "$H/next.md"
    FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/next.md" --requested >/dev/null || fail 'park after live delivery inherited a retired queue owner'
    assert_present "$H/state/procevent/when-park-t1.source" 'a later independent wait can use an ordinary park listener'
    FM_HOME="$H" "$ROOT/bin/fm-park.sh" cancel t1 >/dev/null
  else
    assert_grep 'cleanup-returned t1' "$CALLS" 'live landing cleanup is not killed by its own source'
  fi
  pass "short queue wait settles $outcome without a restart"
done

# Successful terminal dispositions retire live ownership even when the result
# goes to supervision rather than back to the worker. No new outcome may leave
# a dead queue registration attached to an otherwise live task.
for disposition in dropped unexpected superseded unproven; do
  Q="$TMP_ROOT/q-live-terminal-$disposition"; new_queue "$Q"
  H="$TMP_ROOT/h-live-terminal-$disposition"; new_home "$H" "$Q" t1
  P="$TMP_ROOT/p-live-terminal-$disposition"; make_secondmate "$H" "$P" mate1
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- terminal >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  : > "$CALLS"
  case "$disposition" in
    dropped) detail='outcome=dropped main=- note=cancelled by operator' ;;
    unexpected) detail='outcome=daemon-new-outcome main=- note=unknown' ;;
    superseded) detail="outcome=dropped main=- note=superseded by $HEAD_B" ;;
    unproven) detail="outcome=landed main=$MAIN files=2 identical=1 differ=1 note=needs decision" ;;
  esac
  printf 'RESULT now head=%s %s\n' "$HEAD_A" "$detail" >> "$Q/queue.log"
  pe "$H" reconcile >/dev/null
  wait_for handled_is "$H" 1 || fail "$disposition live result was not settled"
  wait_for source_gone "$H" "$sid" || fail "$disposition terminal source remains registered"
  assert_grep 'park_state=completed' "$H/state/t1.meta" "$disposition live ownership is retired"
  assert_equals '' "$(cat "$CALLS")" "$disposition invokes no worker lifecycle action"
  handoff_file="$H/next.md"
  printf '## Goal\ng\n## Done\nd\n## Waiting for\nfile:%s/next\n## Next steps\nn\n' "$H" > "$handoff_file"
  FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$handoff_file" --requested >/dev/null \
    || fail "$disposition left a stale queue owner blocking the next park"
  assert_present "$H/state/procevent/when-park-t1.source" "$disposition allows a later independent wait"
  FM_HOME="$H" "$ROOT/bin/fm-park.sh" cancel t1 >/dev/null
done
pass 'all successfully handled terminal dispositions release the live queue owner'

# Initial handoff compatibility does not exempt a worker's later self-repark.
for adoption in implicit explicit; do
  Q="$TMP_ROOT/q-self-repark-$adoption"; new_queue "$Q"
  H="$TMP_ROOT/h-self-repark-$adoption"; new_home "$H" "$Q" t1
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- self-repark >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  cp "$H/state/t1.meta" "$H/meta-before"
  cp "$H/state/procevent/$sid.source" "$H/source-before"
  cp "$Q/queue.log" "$H/queue-before"
  : > "$CALLS"
  args=()
  [ "$adoption" != explicit ] || args=(--adopt-merge-queue "$HEAD_A")
  if FM_TASK_ID=t1 FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" ${args[@]+"${args[@]}"} > "$H/out" 2>&1; then
    fail 'an unrequested self-repark without an estimate bypassed the live-wait policy'
  fi
  assert_grep 'with --expect' "$H/out" 'missing-estimate refusal explains how to state the wait'
  cmp -s "$H/meta-before" "$H/state/t1.meta" || fail 'missing-estimate refusal changed the current live wait'
  cmp -s "$H/source-before" "$H/state/procevent/$sid.source" || fail 'missing-estimate refusal changed the queue owner'
  cmp -s "$H/queue-before" "$Q/queue.log" || fail 'missing-estimate refusal submitted a queue head'
  assert_equals '' "$(cat "$CALLS")" 'unrequested missing-estimate self-repark stops no worker'
  assert_absent "$H/state/procevent/when-park-t1.source" 'missing-estimate self-repark arms no generic watch'
  FM_TASK_ID=t1 FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" \
    --expect +60 ${args[@]+"${args[@]}"} > "$H/out" 2>&1 || fail 'estimated short self-repark should remain live'
  assert_grep 'park_state=live' "$H/state/t1.meta" 'a supplied short estimate retains the live queue wait'
  assert_equals '' "$(cat "$CALLS")" 'estimated short self-repark still stops no worker'
done
pass 'legacy no-estimate handoff never exempts implicit or explicit self-reparking'

# Requested and supervisor session stops preserve the existing queue owner.
for conversion in requested supervisor repeated; do
  for outcome in conflict landed; do
    Q="$TMP_ROOT/q-convert-$conversion-$outcome"; new_queue "$Q"
    H="$TMP_ROOT/h-convert-$conversion-$outcome"; new_home "$H" "$Q" t1
    FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- conversion >/dev/null
    sid=$(mq "$H" source-id t1 "$HEAD_A")
    cp "$H/state/procevent/$sid.source" "$H/owner-before"
    : > "$CALLS"
    if [ "$conversion" = requested ]; then
      FM_HOME="$H" FM_TASK_ID=t1 FM_PARK_SELF_EXIT_DELAY=0.1 "$ROOT/bin/fm-park.sh" t1 \
        --handoff "$H/data/t1/handoff.md" --requested --expect malformed >/dev/null || fail 'requested conversion refused'
    else
      FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" >/dev/null || fail 'supervisor conversion refused'
      if [ "$conversion" = repeated ]; then
        FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" >/dev/null || fail 'repeated conversion refused'
      fi
    fi
    wait_for grep -q 'control t1 exit' "$CALLS" || fail 'converted session was not stopped'
    assert_grep 'park_state=parked' "$H/state/t1.meta" 'requested stop wins over the short estimate'
    assert_grep "park_source=$sid" "$H/state/t1.meta" 'conversion keeps the exact result owner'
    cmp -s "$H/owner-before" "$H/state/procevent/$sid.source" || fail 'conversion replaced the queue source'
    assert_absent "$H/state/procevent/when-park-t1.source" 'conversion arms no competing resume listener'
    printf 'RESULT now head=%s outcome=%s main=%s files=1 identical=1 note=fixture\n' "$HEAD_A" "$outcome" "$MAIN" >> "$Q/queue.log"
    pe "$H" reconcile >/dev/null
    wait_for handled_is "$H" 1 || fail 'converted queue wait did not settle'
    wait_for source_gone "$H" "$sid" || fail 'converted source was not retired after settlement'
    if [ "$outcome" = conflict ]; then
      assert_equals 1 "$(grep -c 'control t1 relaunch' "$CALLS")" 'queue glue relaunches the stopped worker once'
    else
      assert_grep 'cleanup-returned t1' "$CALLS" 'queue glue still owns landed cleanup'
      assert_no_grep 'control t1 relaunch' "$CALLS" 'landed conversion never generically resumes'
    fi
  done
done
pass 'requested, supervisor and repeated parks retain queue settlement ownership'

for invalid in generation registration condition; do
  Q="$TMP_ROOT/q-convert-invalid-$invalid"; new_queue "$Q"
  H="$TMP_ROOT/h-convert-invalid-$invalid"; new_home "$H" "$Q" t1
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- conversion >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  case "$invalid" in
    generation) printf 'spawn_gen=new\n' >> "$H/state/t1.meta" ;;
    registration) printf 'foreign\n' > "$H/state/procevent/$sid.source" ;;
    condition) printf '## Goal\ng\n## Done\nd\n## Waiting for\nfile:/tmp/unrelated\n## Next steps\nn\n' > "$H/data/t1/handoff.md" ;;
  esac
  : > "$CALLS"
  if FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested > "$H/out" 2>&1; then
    fail "$invalid conversion accepted invalid queue custody"
  fi
  assert_present "$H/state/procevent/$sid.source" 'invalid conversion never retires queue evidence'
  assert_absent "$H/state/procevent/when-park-t1.source" 'invalid conversion never substitutes a generic listener'
  assert_equals '' "$(cat "$CALLS")" 'invalid conversion stops no worker'
done
pass 'unproven conversion ownership or a different condition refuses without replacing the queue owner'

# Force both lock orders with FIFO rendezvous, never scheduling sleeps. Each
# contender reports whether its actual lock attempt acquired or was blocked.
cat > "$TMP_ROOT/transition-hook" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$3" > "$TRANSITION_EVENTS"
if [ "$1:$3" = "acquired:$TRANSITION_GATE" ]; then
  IFS= read -r release < "$TRANSITION_RELEASE"
fi
SH
chmod +x "$TMP_ROOT/transition-hook"
for first in park settle; do
  Q="$TMP_ROOT/q-order-$first"; new_queue "$Q"
  H="$TMP_ROOT/h-order-$first"; new_home "$H" "$Q" t1
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- interleaving >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=ordered\n' "$sid" "$HEAD_A" "$HEAD_A" > "$H/result"
  mkfifo "$H/events" "$H/release"
  exec 8<> "$H/release" 9<> "$H/events"
  export FM_PARK_TRANSITION_HOOK="$TMP_ROOT/transition-hook" TRANSITION_EVENTS="$H/events" TRANSITION_RELEASE="$H/release" TRANSITION_GATE="$first"
  : > "$CALLS"
  if [ "$first" = park ]; then
    FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested > "$H/park.out" 2>&1 & first_pid=$!
  else
    mq "$H" settle "$H/result" > "$H/settle.out" 2>&1 & first_pid=$!
  fi
  IFS= read -r -t 15 event <&9 || fail 'first transition never reached its lock barrier'
  assert_equals "acquired $first" "$event" 'first transition owns the outer lock'
  if [ "$first" = park ]; then
    mq "$H" settle "$H/result" > "$H/settle.out" 2>&1 & second_pid=$!
    second=settle
  else
    FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested > "$H/park.out" 2>&1 & second_pid=$!
    second=park
  fi
  IFS= read -r -t 15 event <&9 || fail 'second transition never attempted the lock'
  assert_equals "contended $second" "$event" 'the second transition cannot observe or act through the first'
  printf 'continue\n' >&8
  IFS= read -r -t 15 event <&9 || fail 'second transition never acquired the released lock'
  assert_equals "acquired $second" "$event" 'second transition rechecks state after serialization'
  wait "$first_pid" || fail "first $first transition failed"
  rc=0; wait "$second_pid" || rc=$?
  if [ "$first" = settle ]; then
    assert_equals 1 "$rc" 'serialized conversion refuses the now-completed handoff'
  else
    assert_equals 0 "$rc" "second $second transition failed"
  fi
  unset FM_PARK_TRANSITION_HOOK TRANSITION_EVENTS TRANSITION_RELEASE TRANSITION_GATE
  exec 8>&- 9>&-
  if [ "$first" = park ]; then
    assert_equals 1 "$(grep -c 'control t1 relaunch' "$CALLS")" 'settlement re-reads parked state and relaunches with RESULT'
    assert_no_grep 'send t1' "$CALLS" 'no result is delivered to the stopped session'
    assert_grep 'outcome=conflict' "$TMP_ROOT/relaunch-note" 'relaunch receives the RESULT'
  else
    assert_equals 1 "$(grep -c '^send ' "$CALLS")" 'live delivery is confirmed once before conversion can proceed'
    assert_no_grep 'control t1' "$CALLS" 'conversion cannot stop or restart the completed live waiter'
    assert_grep 'already completed' "$H/park.out" 'conversion rechecks completion instead of parking over the result'
  fi
  assert_absent "$H/state/procevent/when-park-t1.source" 'neither ordering arms generic resume'
done
pass 'live-to-parked conversion and queue settlement serialize in both forced orders'

# A captured result can outlive its registration. Conversion delegates exactly
# that pending result; failed delivery must leave it unacknowledged and live.
for delivery in success failure; do
  Q="$TMP_ROOT/q-captured-$delivery"; new_queue "$Q"
  H="$TMP_ROOT/h-captured-$delivery"; new_home "$H" "$Q" t1
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- captured >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  mkdir -p "$H/state/procevent-inbox"
  result="$H/state/procevent-inbox/$sid.1.result"
  printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=captured\n' "$sid" "$HEAD_A" "$HEAD_A" > "$result"
  printf 'merge-queue\n' > "$H/state/procevent-inbox/$sid.1.adapter"
  pe "$H" retire "$sid" >/dev/null
  : > "$CALLS"
  if [ "$delivery" = failure ]; then
    FM_MERGE_QUEUE_SEND_BIN=/bin/false FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested > "$H/out" 2>&1 && fail 'failed capture delivery succeeded'
    assert_absent "$H/state/procevent-inbox/$sid.1.handled" 'failed delivery is never acknowledged'
    assert_grep 'park_state=live' "$H/state/t1.meta" 'failed delivery leaves the live waiter available'
  else
    rc=0
    mq "$H" autohandle "$sid" 2 "$result" > "$H/wrong-sequence.out" 2>&1 || rc=$?
    assert_equals 1 "$rc" 'capture acknowledgement refuses a different sequence'
    assert_equals '' "$(cat "$CALLS")" 'capture identity refusal has no delivery or lifecycle effect'
    assert_absent "$H/state/procevent-inbox/$sid.1.handled" 'identity refusal leaves the real capture pending'
    assert_absent "$H/state/procevent-inbox/$sid.2.handled" 'identity refusal never acknowledges another capture'
    rc=0
    FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested > "$H/out" 2>&1 || rc=$?
    assert_equals 1 "$rc" 'captured-result delivery is not a successful park'
    assert_present "$H/state/procevent-inbox/$sid.1.handled" 'confirmed delegated delivery is acknowledged'
    assert_grep 'queue condition settled instead of parking:' "$H/out" 'captured-result refusal names why no park occurred'
    assert_grep 'provide a current handoff' "$H/out" 'captured-result refusal requires a current handoff'
    mq "$H" autohandle "$sid" 1 "$result" >/dev/null || fail 'serialized repeat acknowledgement failed'
    assert_equals 1 "$(grep -c '^send ' "$CALLS")" 'racing original handler never repeats confirmed delivery'
  fi
  assert_no_grep 'control t1' "$CALLS" 'captured result conversion never stops the live session'
  assert_absent "$H/state/procevent/when-park-t1.source" 'captured result never gets a generic listener'
done
pass 'captured but unsettled results retain settlement priority and failed deliveries stay pending'

# A stale live result belongs to neither a replacement source nor incarnation.
for stale in source generation token; do
  Q="$TMP_ROOT/q-stale-$stale"; new_queue "$Q"
  H="$TMP_ROOT/h-stale-$stale"; new_home "$H" "$Q" t1
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  source=$sid; generation=g1; park_token=old-live-token
  [ "$stale" != source ] || source=merge-queue-t1-bbbbbbbb
  [ "$stale" != generation ] || generation=g0
  [ "$stale" != token ] || park_token=''
  printf 'park_state=live\npark_source=%s\npark_spawn_gen=%s\npark_token=%s\n' "$source" "$generation" "$park_token" >> "$H/state/t1.meta"
  printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=fixture\n' "$sid" "$HEAD_A" "$HEAD_A" > "$H/result"
  : > "$CALLS"
  if mq "$H" settle "$H/result" > "$H/out" 2>&1; then fail "$stale stale live result was delivered"; fi
  assert_grep 'was superseded' "$H/out" "$stale refusal names changed ownership"
  assert_equals '' "$(cat "$CALLS")" "$stale sends nothing to the replacement worker"
done
pass 'superseded live queue sources and incarnations refuse stale delivery'

# The token guard is checked under the metadata lock: a late acknowledgement
# cannot clear another wait or change a replacement worker's record.
for replacement in token generation; do
  Q="$TMP_ROOT/q-complete-$replacement"; new_queue "$Q"
  H="$TMP_ROOT/h-complete-$replacement"; new_home "$H" "$Q" t1
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- completion >/dev/null
  old_token=$(awk -F= '$1=="park_token"{v=$2}END{print v}' "$H/state/t1.meta")
  if [ "$replacement" = token ]; then
    printf 'park_token=new-token\n' >> "$H/state/t1.meta"
  else
    printf 'spawn_gen=new-generation\n' >> "$H/state/t1.meta"
  fi
  cp "$H/state/t1.meta" "$H/before"
  rc=0; FM_HOME="$H" "$ROOT/bin/fm-park.sh" complete-live-queue t1 "$old_token" || rc=$?
  assert_equals 3 "$rc" 'stale completion identifies a newer owner'
  cmp -s "$H/before" "$H/state/t1.meta" || fail 'stale completion changed a replacement wait'
done
pass 'late live-delivery completion preserves superseding waits and incarnations'

Q="$TMP_ROOT/q-live-status"; new_queue "$Q"
H="$TMP_ROOT/h-live-status"; new_home "$H" "$Q" t1
FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- status-failure >/dev/null
: > "$CALLS"; : > "$TMP_ROOT/fail-live-status"
printf 'RESULT now head=%s outcome=conflict main=- note=fixture\n' "$HEAD_A" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for handled_is "$H" 1 || fail 'post-delivery status failure left the queue result retryable'
sid=$(mq "$H" source-id t1 "$HEAD_A")
wait_for source_gone "$H" "$sid" || fail 'delivered queue source was not retired'
pe "$H" reconcile >/dev/null
assert_equals 1 "$(grep -c '^send ' "$CALLS")" 'status failure never repeats durable delivery'
assert_grep 'do not resend' "$H/state/.wake-queue" 'status failure reaches supervision despite handled delivery'
rm "$TMP_ROOT/fail-live-status"
pass 'status failure after live delivery alarms without resending'

# A confirmed queue relaunch ends only its exact parked incarnation. Drive
# the real park owner after every resumable outcome, with the stub changing
# spawn_gen just as fm-control's confirmed launch does.
for outcome in conflict culprit precheck-unavailable; do
  for mode in self requested; do
    Q="$TMP_ROOT/q-resumed-$outcome-$mode"; new_queue "$Q"
    H="$TMP_ROOT/h-resumed-$outcome-$mode"; new_home "$H" "$Q" t1
    mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +7200 -- resume >/dev/null
    sid=$(mq "$H" source-id t1 "$HEAD_A")
    printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=%s main=- note=fixture\n' "$sid" "$HEAD_A" "$HEAD_A" "$outcome" > "$H/result"
    mq "$H" settle "$H/result" || fail 'confirmed queue relaunch failed'
    mq "$H" retire t1 "$HEAD_A" >/dev/null
    assert_grep 'spawn_gen=g1.resumed' "$H/state/t1.meta" 'fixture confirmed launch changes generation'
    printf '## Goal\ng\n## Done\nd\n## Waiting for\nfile:%s/next\n## Next steps\nn\n' "$H" > "$H/next.md"
    if [ "$mode" = self ]; then
      FM_HOME="$H" FM_TASK_ID=t1 "$ROOT/bin/fm-park.sh" t1 --handoff "$H/next.md" --expect +7200 >/dev/null || fail 'self re-park after confirmed queue resume refused'
    else
      FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/next.md" --requested >/dev/null || fail 'requested re-park after confirmed queue resume refused'
    fi
    assert_present "$H/state/procevent/when-park-t1.source" 'fresh re-park installs its own ordinary listener'
    FM_HOME="$H" "$ROOT/bin/fm-park.sh" cancel t1 >/dev/null
  done
done
pass 'confirmed conflict/culprit/precheck-unavailable resumes permit fresh ordinary and requested parks'

for replacement in token generation source state; do
  Q="$TMP_ROOT/q-resumed-new-$replacement"; new_queue "$Q"
  H="$TMP_ROOT/h-resumed-new-$replacement"; new_home "$H" "$Q" t1
  mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +7200 -- replacement >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  case "$replacement" in
    token) field='park_token=new-owner' ;;
    generation) field='park_spawn_gen=new-owner' ;;
    source) field='park_source=new-owner' ;;
    state) field='park_state=live' ;;
  esac
  printf '%s\n' "$field" > "$H/relaunch-owner"
  printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=fixture\n' "$sid" "$HEAD_A" "$HEAD_A" > "$H/result"
  cp "$H/state/t1.meta" "$H/expected"
  printf 'spawn_gen=g1.resumed\n%s\n' "$field" >> "$H/expected"
  mq "$H" settle "$H/result" || fail 'replacement-owner settlement failed'
  cmp -s "$H/expected" "$H/state/t1.meta" || fail "$replacement newer owner was changed by old queue resume retirement"
done
pass 'each replacement incarnation field prevents old queue completion from touching newer custody'

for failure in refused unconfirmed; do
  Q="$TMP_ROOT/q-resumed-failed-$failure"; new_queue "$Q"
  H="$TMP_ROOT/h-resumed-failed-$failure"; new_home "$H" "$Q" t1
  mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +7200 -- failure >/dev/null
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=fixture\n' "$sid" "$HEAD_A" "$HEAD_A" > "$H/result"
  cp "$H/state/t1.meta" "$H/expected"
  if [ "$failure" = refused ]; then
    : > "$TMP_ROOT/refuse-control"
  else
    : > "$H/unconfirmed-control"
    printf 'spawn_gen=g1.resumed\n' >> "$H/expected"
  fi
  rc=0; mq "$H" settle "$H/result" || rc=$?
  cmp -s "$H/expected" "$H/state/t1.meta" || fail "$failure launch lost adopted custody before confirmation"
  assert_equals 1 "$rc" 'unconfirmed/failed launch remains a failed settlement'
  assert_absent "$H/state/.park-churn/t1" 'unconfirmed/failed resume is not counted'
  assert_present "$H/state/procevent/$sid.source" 'unconfirmed/failed launch retains its queue source'
  rm -f "$TMP_ROOT/refuse-control"
done
pass 'failed and unconfirmed launches preserve the exact adopted park record'

# Every successful adopted parked resume contributes, including failed-launch
# retries; duplicate reports of a token cannot count it twice.
Q="$TMP_ROOT/q-count"; new_queue "$Q"
H="$TMP_ROOT/h-count"; new_home "$H" "$Q" t1
for head in "$HEAD_A" "$HEAD_B" "$MAIN"; do
  mq "$H" handoff t1 fm/t1 "$head" --expect +7200 -- count >/dev/null
  sid=$(mq "$H" source-id t1 "$head")
  f="$H/result"
  printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=fixture\n' "$sid" "$head" "$head" > "$f"
  if [ "$head" = "$HEAD_A" ]; then
    : > "$TMP_ROOT/refuse-control"
    if mq "$H" settle "$f"; then fail 'failed launch was accepted'; fi
    assert_absent "$H/state/.park-churn/t1" 'failed queue launch is not counted'
    rm -f "$TMP_ROOT/refuse-control"
  fi
  mq "$H" settle "$f" || fail 'queue resume failed'
  mq "$H" retire t1 "$head" >/dev/null
 done
assert_contains "$(FM_HOME="$H" "$ROOT/bin/fm-park-churn.sh" check)" 'task t1 resumed from park 3 times' 'queue resumes reach the churn alarm'
pass 'queue parked resumes count; failed launches do not'

# A successful launch remains handled even when its secondary accounting fails.
Q="$TMP_ROOT/q-corrupt-count"; new_queue "$Q"
H="$TMP_ROOT/h-corrupt-count"; new_home "$H" "$Q" t1
mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +7200 -- corrupt-counter >/dev/null
mkdir -p "$H/state/.park-churn"
printf 'corrupt\n' > "$H/state/.park-churn/t1"
: > "$CALLS"
printf 'RESULT now head=%s outcome=conflict main=- note=fixture\n' "$HEAD_A" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for handled_is "$H" 1 || fail 'counter failure left a successful queue resume unhandled'
sid=$(mq "$H" source-id t1 "$HEAD_A")
wait_for source_gone "$H" "$sid" || fail 'settled source was not retired'
pe "$H" reconcile >/dev/null
assert_equals 1 "$(grep -c 'control t1 relaunch' "$CALLS")" 'counter failure must not retry a successful launch'
assert_equals corrupt "$(cat "$H/state/.park-churn/t1")" 'corrupt counter evidence survives'
assert_contains "$(FM_HOME="$H" "$ROOT/bin/fm-park-churn.sh" check)" 'park-churn:' 'counter failure reaches supervision'
pass 'queue accounting failure alarms without repeating a successful resume'

# --- precheck-unavailable: final, no code verdict, owner hands over a new head --
RECEIPT=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
PU_NOTE="head $HEAD_A: 3 consecutive incomplete prechecks; receipt /q/cars/c7/receipt.json (may be absent); diagnostics /q/cars/c7; execution unavailable, not contract red; diagnose and hand over a new head"
f="$TMP_ROOT/precheck-unavailable.result"
for tail in "by=merge-train protocol=lattice-merge-precheck/v1 rule=precheck-unavailable" "protocol=lattice-merge-precheck/v1"; do
  printf 'status: result\nline: RESULT 2026-10-22T09:00:00Z head=%s outcome=precheck-unavailable main=- home=h task=t1 car=c7 receipt=%s %s note=%s\n' \
    "$HEAD_A" "$RECEIPT" "$tail" "$PU_NOTE" > "$f"
  assert_equals precheck-unavailable "$(mq "$TMP_ROOT/h-culprit" classify "$f")" "precheck-unavailable is its own class ($tail)"
  mq "$TMP_ROOT/h-culprit" terminal "$f" || fail "precheck-unavailable must be terminal ($tail)"
done
Q="$TMP_ROOT/q-precheck"; new_queue "$Q"
H="$TMP_ROOT/h-precheck"; new_home "$H" "$Q" t1
P="$TMP_ROOT/p-precheck"; make_secondmate "$H" "$P" mate1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" --resume-note "gate runs through the heavy slot" -- precheck >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'RESULT 2026-10-22T09:00:00Z head=%s outcome=precheck-unavailable main=- home=test-home task=t1 car=c7 receipt=%s by=merge-train protocol=lattice-merge-precheck/v1 rule=precheck-unavailable note=%s\n' \
  "$HEAD_A" "$RECEIPT" "$PU_NOTE" >> "$Q/queue.log"
FM_HOME="$H" "$ROOT/bin/fm-park.sh" check "cmd:$ROOT/bin/fm-procevent-merge-queue.sh result-ready $HEAD_A" \
  || fail "precheck-unavailable must end the declared wait"
pe "$H" reconcile >/dev/null
wait_for grep -q "^control t1 relaunch --note-file" "$CALLS" || fail "precheck-unavailable did not relaunch the owner"
wait_for handled_is "$H" 1 || fail "the precheck-unavailable outcome was not acknowledged"
wait_for source_gone "$H" "$sid" || fail "precheck-unavailable did not end the watch"
assert_grep "outcome=precheck-unavailable main=- " "$TMP_ROOT/relaunch-note" "the relaunch note carries the RESULT line"
assert_grep "execution was unavailable: this is not a code verdict" "$TMP_ROOT/relaunch-note" "the owner is told it is no code verdict"
assert_grep "will not retry that head" "$TMP_ROOT/relaunch-note" "the owner is told the head is not retried"
assert_grep "Diagnose why the precheck could not run" "$TMP_ROOT/relaunch-note" "the owner is asked to diagnose"
assert_grep "handoff t1" "$TMP_ROOT/relaunch-note" "the relaunch note says how to hand over a new head"
assert_grep "gate runs through the heavy slot" "$TMP_ROOT/relaunch-note" "the relaunch note carries the resume note"
assert_no_grep "Fix what the result names" "$TMP_ROOT/relaunch-note" "no code verdict is implied"
assert_no_grep "teardown" "$CALLS" "precheck-unavailable cleans nothing"
assert_no_grep "fleet-sync" "$CALLS" "precheck-unavailable is not a landing"
assert_no_grep "failed" "$H/state/t1.status" "precheck-unavailable is not a drop"
assert_no_grep "unexpected" "$P/state/mate1.status" "precheck-unavailable is not reported as unexpected"
pass "precheck-unavailable relaunches the owner to diagnose and hand over a new head"

# --- dropped: superseded is silent, anything else fails the task --------------
Q="$TMP_ROOT/q-dropped"; new_queue "$Q"
H="$TMP_ROOT/h-dropped"; new_home "$H" "$Q" t1
: > "$CALLS"
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- one >/dev/null
mq "$H" handoff t1 fm/t1 "$HEAD_B" -- two >/dev/null
assert_absent "$H/state/procevent/merge-queue-t1-aaaaaaaa.source" "re-park retires the prior adopted source"
assert_present "$H/state/procevent/merge-queue-t1-bbbbbbbb.source" "re-park adopts only the newer head's watch"
assert_grep "park_source=merge-queue-t1-bbbbbbbb" "$H/state/t1.meta" "re-park records the new adopted source"
# Re-park retires the old adopted watch; explicitly arm it to exercise its
# silent supersede capture alongside the newer head's ordinary drop.
mq "$H" arm t1 "$HEAD_A" >/dev/null
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=dropped main=- note=superseded by bbbbbbbb\n' "$HEAD_A" >> "$Q/queue.log"
printf 'RESULT 2026-09-27T18:06:00Z head=%s outcome=dropped main=- note=branch deleted upstream\n' "$HEAD_B" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for handled_is "$H" 2 || fail "the dropped outcomes were not settled"
assert_no_grep "dropped head aaaaaaaa" "$H/state/t1.status" "a superseded head writes nothing"
assert_grep "failed [at=" "$H/state/t1.status" "a dropped head fails the task"
assert_grep "dropped head bbbbbbbb: branch deleted upstream" "$H/state/t1.status" "the failure carries the queue's reason"
assert_no_grep "relaunch" "$CALLS" "a dropped head relaunches nothing"
assert_no_grep "teardown" "$CALLS" "a dropped head cleans nothing"
pass "a superseded head is silent and any other drop fails the task"

# Similar free text must never be mistaken for the train's exact supersede.
Q="$TMP_ROOT/q-not-superseded"; new_queue "$Q"
H="$TMP_ROOT/h-not-superseded"; new_home "$H" "$Q" t1
P="$TMP_ROOT/p-not-superseded"; make_secondmate "$H" "$P" mate1
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- negative >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=dropped main=- note=not superseded\n' "$HEAD_A" >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for handled_is "$H" 1 || fail "a non-superseded drop was not settled"
assert_grep "failed [at=" "$H/state/t1.status" "not superseded is an ordinary failure"
assert_grep "not superseded" "$P/state/mate1.status" "the ordinary drop reaches the parent"
assert_equals 1 "$(grep -c 'not superseded' "$P/state/mate1.status")" "the drop is published once"
# Classify through the public command as well for malformed and suffixed notes.
for note in 'superseded by nonsense' 'superseded by bbbbbbbb extra'; do
  f="$TMP_ROOT/invalid-supersede.result"
  printf 'status: result\nline: RESULT t head=%s outcome=dropped note=%s\n' "$HEAD_A" "$note" > "$f"
  assert_equals dropped "$(mq "$H" classify "$f")" "only the exact supersede form is silent"
done
pass "only the train's exact superseded by sha form suppresses a dropped outcome"

# --- unexpected RESULT: end wait, report once, never relaunch or clean --------
Q="$TMP_ROOT/q-unexpected"; new_queue "$Q"
H="$TMP_ROOT/h-unexpected"; new_home "$H" "$Q" t1
P="$TMP_ROOT/p-unexpected"; make_secondmate "$H" "$P" mate1
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- unexpected >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
: > "$CALLS"
printf 'RESULT t head=%s outcome=daemon-new-outcome main=- note=unknown\n' "$HEAD_A" >> "$Q/queue.log"
assert_contains "$(mq "$H" result "$HEAD_A")" "outcome=daemon-new-outcome" "unexpected RESULT is not silently pending"
FM_HOME="$H" "$ROOT/bin/fm-park.sh" check "cmd:$ROOT/bin/fm-procevent-merge-queue.sh result-ready $HEAD_A" \
  || fail "unknown outcome must end the declared wait"
pe "$H" reconcile >/dev/null
wait_for handled_is "$H" 1 || fail "unknown outcome was not reported and acknowledged"
assert_absent "$H/state/procevent/$sid.source" "unexpected RESULT ends its watch"
assert_equals 1 "$(grep -c 'outcome=daemon-new-outcome' "$P/state/mate1.status")" "one parent line names the raw outcome"
assert_equals "" "$(cat "$CALLS")" "unknown outcome relaunches and cleans nothing"
pass "an unexpected RESULT ends the wait and reports the raw outcome once without cleanup or relaunch"

# --- stall: one parent line per STALL, and the watch keeps going ---------------
Q="$TMP_ROOT/q-stall"; new_queue "$Q"
H="$TMP_ROOT/h-stall"; new_home "$H" "$Q" t1
printf 'kind=ship\nspawn_gen=g1\n' > "$H/state/t2.meta"
P="$TMP_ROOT/p-stall"; make_secondmate "$H" "$P" mate1
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- one >/dev/null
mq "$H" handoff t2 fm/t2 "$HEAD_B" -- two >/dev/null
printf 'STALL 2026-09-27T20:00:00Z since=2026-09-27T19:00:00Z waiting=2 note=gate host unreachable\n' >> "$Q/queue.log"
pe "$H" reconcile >/dev/null
wait_for grep -qs "merge queue is stalled" "$P/state/mate1.status" || fail "the stall did not reach the parent"
sleep 1
assert_equals 1 "$(grep -c "merge queue is stalled" "$P/state/mate1.status")" "two watches in one home post one line per STALL"
assert_grep "waiting=2 note=gate host unreachable" "$P/state/mate1.status" "the parent line carries the stall"
assert_present "$H/state/procevent/merge-queue-t1-aaaaaaaa.source" "a stall does not end the watch"
assert_present "$H/state/procevent/merge-queue-t2-bbbbbbbb.source" "a stall does not end the other watch"
mq "$H" retire t1 "$HEAD_A" >/dev/null; mq "$H" retire t2 "$HEAD_B" >/dev/null
pass "a STALL posts one parent line and the watches keep going"

# --- an unreadable queue stops the watch and wakes firstmate -------------------
Q="$TMP_ROOT/q-error"; new_queue "$Q"
H="$TMP_ROOT/h-error"; new_home "$H" "$Q" t1
mq "$H" handoff t1 fm/t1 "$HEAD_A" -- x >/dev/null
sid=$(mq "$H" source-id t1 "$HEAD_A")
rm -rf "$Q"
FM_MERGE_QUEUE_ERROR_BUDGET=2 pe "$H" reconcile >/dev/null
wait_for grep -qs "procevent merge-queue $sid" "$H/state/.wake-queue" || fail "an unreadable queue did not wake firstmate"
f=$(compgen -G "$H/state/procevent-inbox/$sid.*.result" | head -1)
assert_equals error "$(mq "$H" classify "$f")" "the outcome is an error"
assert_grep "re-arm with" "$f" "the error says how to re-arm"
wait_for source_gone "$H" "$sid" || fail "an error ends the watch"
pass "an unreadable queue stops the watch and wakes firstmate"

# The existing runner ends short live waits; the fixture clock pins the boundary.
queue_expiry_regressions() (
  local clockbin clock real_date start variant before rc result
  clockbin="$TMP_ROOT/expiry-clock-bin"; mkdir -p "$clockbin"
  clock="$TMP_ROOT/expiry-clock"; real_date=$(command -v date)
  start=$(date +%s)
  cat > "$clockbin/date" <<SH
#!/usr/bin/env bash
if [ "\$#" = 1 ] && [ "\$1" = +%s ]; then cat "$clock"; else exec "$real_date" "\$@"; fi
SH
  chmod +x "$clockbin/date"
  printf '%s\n' "$start" > "$clock"
  export PATH="$clockbin:$PATH"
  Q="$TMP_ROOT/q-expiry-boundary"; new_queue "$Q"
  H="$TMP_ROOT/h-expiry-boundary"; new_home "$H" "$Q" t1
  printf '%s\n' "$start" > "$clock"
  FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- short >/dev/null || fail 'short expiry handoff failed'
  sid=$(mq "$H" source-id t1 "$HEAD_A")
  : > "$CALLS"
  printf '%s\n' "$((start + 3599))" > "$clock"
  FM_HOME="$H" "$ROOT/bin/fm-park.sh" expire-queue t1 "$HEAD_A" || fail 'under-bound expiry check failed'
  assert_grep 'park_state=live' "$H/state/t1.meta" 'queue stays live just below the threshold'
  assert_equals '' "$(cat "$CALLS")" 'under-bound check stops nothing'
  printf '%s\n' "$((start + 3600))" > "$clock"
  pe "$H" ensure-listening "$sid" > "$H/start.out" 2>&1 || { cat "$H/start.out"; fail 'expiry runner failed to start'; }
  wait_for grep -q '^park_exit_confirmed=park\.' "$H/state/t1.meta" || fail 'queue watcher expires its live wait at threshold'
  assert_grep 'park_state=parked' "$H/state/t1.meta" 'expiry records a real park'
  assert_grep "park_source=$sid" "$H/state/t1.meta" 'expiry retains the sole queue owner'
  assert_present "$H/state/procevent/$sid.source" 'expiry leaves the queue runner registered'
  assert_absent "$H/state/procevent/when-park-t1.source" 'expiry creates no generic resume listener'
  FM_HOME="$H" "$ROOT/bin/fm-park.sh" expire-queue t1 "$HEAD_A" || fail 'repeated expiry refused'
  assert_equals 1 "$(grep -c '^control t1 exit' "$CALLS")" 'expiry stops only once'
  printf 'RESULT now head=%s outcome=conflict main=- note=after-expiry\n' "$HEAD_A" >> "$Q/queue.log"
  wait_for handled_is "$H" 1 || fail 'expired queue result did not settle'
  wait_for source_gone "$H" "$sid" || fail 'expired queue result did not retire'
  assert_equals 1 "$(grep -c '^control t1 relaunch' "$CALLS")" 'expired queue result relaunches once'
  assert_equals 1 "$(grep -c '^[0-9]' "$H/state/.park-churn/t1")" 'expired queue resume is counted once'

  for variant in newer completed captured ready requested working empty-status generation invalid-start invalid-config; do
    Q="$TMP_ROOT/q-expiry-$variant"; new_queue "$Q"
    H="$TMP_ROOT/h-expiry-$variant"; new_home "$H" "$Q" t1
    printf '%s\n' "$start" > "$clock"
    FM_TASK_ID=t1 mq "$H" handoff t1 fm/t1 "$HEAD_A" --expect +60 -- short >/dev/null || fail 'expiry sibling handoff failed'
    sid=$(mq "$H" source-id t1 "$HEAD_A")
    case "$variant" in
      newer) printf 'park_when=cmd:%s/bin/fm-procevent-merge-queue.sh result-ready %s\n' "$ROOT" "$HEAD_B" >> "$H/state/t1.meta" ;;
      completed) printf 'park_state=completed\npark_source=\npark_token=\n' >> "$H/state/t1.meta" ;;
      captured)
        mkdir -p "$H/state/procevent-inbox"
        result="$H/state/procevent-inbox/$sid.1.result"
        printf 'merge-queue: %s\ntask: t1\nhead: %s\nstatus: result\nline: RESULT now head=%s outcome=conflict main=- note=captured\n' "$sid" "$HEAD_A" "$HEAD_A" > "$result"
        printf 'merge-queue\n' > "$H/state/procevent-inbox/$sid.1.adapter" ;;
      ready) printf 'RESULT now head=%s outcome=conflict main=- note=ready\n' "$HEAD_A" >> "$Q/queue.log" ;;
      requested) FM_HOME="$H" "$ROOT/bin/fm-park.sh" t1 --handoff "$H/data/t1/handoff.md" --requested >/dev/null || fail 'requested park must win before expiry' ;;
      working) printf 'working: a steer started other work\n' >> "$H/state/t1.status" ;;
      empty-status) : > "$H/state/t1.status" ;;
      generation) printf 'spawn_gen=newer\n' >> "$H/state/t1.meta" ;;
      invalid-start) printf 'park_at=0001\n' >> "$H/state/t1.meta" ;;
      invalid-config) : > "$H/config/park-live-wait-minutes" ;;
    esac
    before=$(cat "$H/state/t1.meta"); : > "$CALLS"
    printf '%s\n' "$((start + 3600))" > "$clock"
    rc=0; FM_HOME="$H" "$ROOT/bin/fm-park.sh" expire-queue t1 "$HEAD_A" > "$H/expiry.out" 2>&1 || rc=$?
    case "$variant" in
      empty-status|generation|invalid-start|invalid-config) assert_equals 1 "$rc" "$variant expiry refuses unknown or superseded custody" ;;
      *) assert_equals 0 "$rc" "$variant expiry is safely inapplicable" ;;
    esac
    assert_equals "$before" "$(cat "$H/state/t1.meta")" "$variant expiry preserves custody"
    assert_equals '' "$(cat "$CALLS")" "$variant expiry has no lifecycle effect"
    if [ "$variant" = captured ]; then
      assert_absent "$H/state/procevent-inbox/$sid.1.handled" 'expiry never acknowledges a capture'
      mq "$H" autohandle "$sid" 1 "$result" >/dev/null || fail 'captured result must still settle'
      assert_grep 'send t1 ' "$CALLS" 'capture keeps live delivery precedence'
    fi
    if [ "$variant" = invalid-config ]; then
      mq "$H" watch t1 "$HEAD_A" > "$H/expiry-event"
      assert_grep 'status: error' "$H/expiry-event" 'expiry refusal emits the existing supervised error outcome'
      assert_grep 'queue live-wait expiry failed:' "$H/expiry-event" 'expiry error names the failed stage'
    fi
    pe "$H" retire "$sid" >/dev/null || fail 'expiry fixture could not retire its source'
  done
  pass 'queue live expiry is bounded, single-owner and subordinate to results and requested parks'
)
queue_expiry_regressions

# --- watch receipts: arm writes, re-arm rewrites, retire removes ---------------
Q="$TMP_ROOT/q-receipt"; new_queue "$Q"
H="$TMP_ROOT/h-receipt"; new_home "$H" "$Q" t1
sid=merge-queue-t1-aaaaaaaa
key=$(rkey "$H")
receipt="$Q/watches/$HEAD_A.$sid.$key.json"
ledger="$H/state/merge-queue/receipts"
mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-arm.err" || fail "arm with a writable queue must succeed"
assert_equals "" "$(cat "$TMP_ROOT/receipt-arm.err")" "a receipt that was written prints no warning"
assert_present "$receipt" "arm writes the receipt named by head, source id and home key"
assert_equals "$receipt" "$(cat "$ledger/$sid")" "the home's ledger records where the receipt was written"
home_phys=$(cd -P "$H" && pwd -P)
assert_equals "lattice.merge-queue.watch.v1" "$(jq -r .schema "$receipt")" "the receipt carries its version"
assert_equals "$HEAD_A" "$(jq -r .head "$receipt")" "the receipt names the head"
assert_equals t1 "$(jq -r .task "$receipt")" "the receipt names the task"
assert_equals "$sid" "$(jq -r .source_id "$receipt")" "the receipt names the watch's source id"
assert_equals "$home_phys" "$(jq -r .home "$receipt")" "the receipt names the home by its absolute physical path"
assert_equals "$home_phys/state/procevent/$sid.source" "$(jq -r .registration "$receipt")" \
  "the receipt names the registration that proves the watch"
[[ "$(jq -r .armed_at "$receipt")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "armed_at must be a UTC time, got $(jq -r .armed_at "$receipt")"
assert_present "$(jq -r .registration "$receipt")" "the named registration exists while the watch is armed"
receipt_mode=$(stat -c %a "$receipt" 2>/dev/null || stat -f %Lp "$receipt")
assert_equals 644 "$receipt_mode" "the train's home can read the receipt"
mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "re-arm must succeed"
assert_equals "$HEAD_A.$sid.$key.json" "$(ls -A "$Q/watches")" "a re-arm keeps exactly one receipt and leaves no temporary file"
assert_equals "$sid" "$(ls -A "$ledger")" "a re-arm keeps one ledger entry and leaves no temporary file"
mq "$H" retire t1 "$HEAD_A" >/dev/null
assert_absent "$receipt" "retire removes the receipt"
assert_absent "$ledger/$sid" "retire removes the ledger entry"
assert_absent "$H/state/procevent/$sid.source" "retire stops the watch"
pass "arm writes the versioned watch receipt atomically, re-arm rewrites it, and retire removes it"

mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "arm must succeed before the failed re-arm"
assert_present "$receipt" "the receipt exists before the failed re-arm"
rm -rf "${H:?}/state/procevent"; : > "$H/state/procevent"
if mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-refused.err"; then
  fail "an arm whose watch cannot be registered must fail"
fi
assert_grep "cannot register the watch $sid" "$TMP_ROOT/receipt-refused.err" "the failed arm says why"
assert_absent "$receipt" "a failed re-arm removes the earlier receipt, so no receipt outlives its watch"
rm -f "$H/state/procevent"
pass "an arm that cannot register leaves no receipt"

rm -rf "${Q:?}/watches"; : > "$Q/watches"
mq "$H" arm t1 "$HEAD_A" >"$TMP_ROOT/receipt-unwritable.out" 2>"$TMP_ROOT/receipt-unwritable.err" \
  || fail "a receipt that cannot be written must not fail the arm"
assert_grep "armed: $sid" "$TMP_ROOT/receipt-unwritable.out" "the watch is armed without its receipt"
assert_grep "could not write its watch receipt" "$TMP_ROOT/receipt-unwritable.err" "the missing receipt is warned about"
assert_present "$H/state/procevent/$sid.source" "the watch stays armed"
rm -f "$Q/watches"
mq "$H" retire t1 "$HEAD_A" >/dev/null
pass "a receipt that cannot be written warns and keeps the watch"

mkdir -p "$receipt/inner"
mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-dir.err" || fail "a directory in the receipt's place must not fail the arm"
assert_grep "could not write its watch receipt" "$TMP_ROOT/receipt-dir.err" "a directory in the receipt's place is warned about"
assert_equals "inner" "$(ls -A "$receipt")" "no receipt is moved into the directory"
mq "$H" retire t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-dir-retire.err"
assert_equals "inner" "$(ls -A "$receipt")" "retire never removes a directory standing in the receipt's place"
assert_grep "does not read as this home's receipt" "$TMP_ROOT/receipt-dir-retire.err" \
  "retire warns about what it left in the receipt's place"
rm -rf "${receipt:?}"; rm -f "${ledger:?}/${sid:?}"
pass "a directory in the receipt's place is never written into"

JQ_FAIL_BIN=$(fm_fakebin "$TMP_ROOT/jq-fail-bin")
printf '#!/bin/sh\nexit 1\n' > "$JQ_FAIL_BIN/jq"; chmod +x "$JQ_FAIL_BIN/jq"
PATH="$JQ_FAIL_BIN:$PATH" mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-jq.err" \
  || fail "a receipt whose JSON cannot be built must not fail the arm"
assert_grep "could not write its watch receipt" "$TMP_ROOT/receipt-jq.err" "a failed receipt write is warned about"
assert_equals "" "$(ls -A "$Q/watches")" "a failed receipt write leaves neither a receipt nor its temporary file"
mq "$H" retire t1 "$HEAD_A" >/dev/null
assert_absent "$ledger/$sid" "retire clears the ledger entry of a receipt that was never written"
pass "a receipt write that fails part way leaves nothing behind"

mkdir -p "$ledger/$sid"
mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-ledger.err" || fail "an unreadable ledger entry must not fail the arm"
assert_grep "cannot be read or names no receipt" "$TMP_ROOT/receipt-ledger.err" "an unreadable ledger entry is warned about"
assert_grep "wrote no new watch receipt" "$TMP_ROOT/receipt-ledger.err" "the arm says it wrote no new receipt"
assert_absent "$receipt" "no receipt is written that the ledger could not record"
rmdir "$ledger/$sid"
mq "$H" retire t1 "$HEAD_A" >/dev/null
pass "an arm writes no receipt its ledger cannot track"

# --- watch receipts: cleanup follows the ledger, wherever the queue dir points now
Q2="$TMP_ROOT/q-receipt-2"; new_queue "$Q2"
FM_MERGE_QUEUE_DIR="$Q2" mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "arm with an overriding queue dir must succeed"
assert_present "$Q2/watches/$HEAD_A.$sid.$key.json" "FM_MERGE_QUEUE_DIR places the receipt, as the fragment declares"
mq "$H" retire t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-moved.err"
assert_absent "$Q2/watches/$HEAD_A.$sid.$key.json" "retire without the override removes the receipt where it was written"
assert_equals "" "$(cat "$TMP_ROOT/receipt-moved.err")" "that removal prints no warning"
FM_MERGE_QUEUE_DIR="$Q2" mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "arm in the overriding queue must succeed"
mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "re-arm in the configured queue must succeed"
assert_absent "$Q2/watches/$HEAD_A.$sid.$key.json" "a re-arm to a new place removes the receipt from the old one"
assert_present "$receipt" "the re-arm writes its receipt in the new place"
mq "$H" retire t1 "$HEAD_A" >/dev/null
pass "a receipt is removed from where it was written, wherever the queue dir points now"

printf 'Mate.One\n' > "$H/.fm-secondmate-home"
mq "$H" arm t1 "$HEAD_A" >"$TMP_ROOT/receipt-noid.out" 2>"$TMP_ROOT/receipt-noid.err" \
  || fail "a home id unusable in a receipt name must not fail the arm"
rm -f "$H/.fm-secondmate-home"
assert_grep "armed: $sid" "$TMP_ROOT/receipt-noid.out" "the watch is armed without its receipt"
assert_grep "does not hold a home id" "$TMP_ROOT/receipt-noid.err" "a home id unusable in a receipt name is warned about"
assert_grep "wrote no watch receipt" "$TMP_ROOT/receipt-noid.err" "the arm says it wrote no receipt"
assert_equals "" "$(compgen -G "$Q/watches/*$sid*")" "no receipt is written under a name the fragment cannot match"
mq "$H" retire t1 "$HEAD_A" >/dev/null
(cd "$H" && FM_MERGE_QUEUE_DIR=relative/queue mq "$H" arm t1 "$HEAD_A") >/dev/null 2>"$TMP_ROOT/receipt-rel.err" \
  || fail "a relative queue dir must not fail the arm"
assert_grep "is not an absolute path" "$TMP_ROOT/receipt-rel.err" "a relative queue dir is warned about"
assert_grep "wrote no watch receipt" "$TMP_ROOT/receipt-rel.err" "the arm says it wrote no receipt"
assert_present "$H/state/procevent/$sid.source" "the watch is armed under a relative queue dir"
assert_absent "$H/relative" "no receipt is written relative to the working directory"
FM_MERGE_QUEUE_DIR=relative/queue mq "$H" retire t1 "$HEAD_A" >/dev/null
FM_MERGE_QUEUE_DIR="$Q"$'\r' mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/receipt-cr.err" \
  || fail "a queue dir with a control character must not fail the arm"
assert_grep "without control characters" "$TMP_ROOT/receipt-cr.err" "a queue dir with a control character is warned about"
assert_absent "$Q"$'\r' "no receipt folder is created under a name with a control character"
FM_MERGE_QUEUE_DIR="$Q"$'\r' mq "$H" retire t1 "$HEAD_A" >/dev/null
pass "a receipt the fragment could not declare is never written"

# --- watch receipts: homes sharing one queue never touch each other's ---------
# Every unmarked home is main, and two fleets can each have a secondmate of one
# name, so these homes share ids; their keys still differ.
Q="$TMP_ROOT/q-shared"; new_queue "$Q"
HA="$TMP_ROOT/h-shared-a"; new_home "$HA" "$Q" t1
HB="$TMP_ROOT/h-shared-b"; new_home "$HB" "$Q" t1
printf 'kind=ship\nspawn_gen=g1\nmode=direct-push\nproject=%s\n' "$HB/project" > "$HB/state/t9.meta"
sid=merge-queue-t1-aaaaaaaa
s9=merge-queue-t9-bbbbbbbb
ka=$(rkey "$HA"); kb=$(rkey "$HB")
[ "$ka" != "$kb" ] || fail "two unmarked homes must get distinct keys, both got $ka"
mq "$HA" arm t1 "$HEAD_A" >/dev/null || fail "home A must arm"
mq "$HB" arm t1 "$HEAD_A" >/dev/null || fail "home B must arm the same task and head"
assert_present "$Q/watches/$HEAD_A.$sid.$ka.json" "home A's receipt is written"
assert_present "$Q/watches/$HEAD_A.$sid.$kb.json" "home B's receipt for the same task and head is a separate file"
assert_equals "$(cd -P "$HA" && pwd -P)" "$(jq -r .home "$Q/watches/$HEAD_A.$sid.$ka.json")" \
  "home B's arm leaves home A's receipt naming home A"
mq "$HA" retire t1 "$HEAD_A" >/dev/null
assert_absent "$Q/watches/$HEAD_A.$sid.$ka.json" "home A's retire removes its own receipt"
assert_present "$Q/watches/$HEAD_A.$sid.$kb.json" "home A's retire leaves home B's receipt"
mq "$HB" arm t9 "$HEAD_B" >/dev/null || fail "home B must arm a second task"
mq "$HA" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/shared-arm.err" || fail "home A must re-arm"
assert_equals "" "$(cat "$TMP_ROOT/shared-arm.err")" "home A's arm sweep finds nothing of its own to remove"
assert_present "$Q/watches/$HEAD_B.$s9.$kb.json" \
  "home A's arm sweep never removes another home's receipt for a watch home A does not hold"
assert_present "$Q/watches/$HEAD_A.$sid.$kb.json" "home A's arm sweep leaves home B's receipt for the same task"
make_secondmate "$HA" "$TMP_ROOT/p-shared-a" mate1
make_secondmate "$HB" "$TMP_ROOT/p-shared-b" mate1
ka=$(rkey "$HA"); kb=$(rkey "$HB")
[ "$ka" != "$kb" ] && [ "${ka%-*}" = mate1 ] || fail "two secondmates named mate1 must get distinct keys, got $ka and $kb"
mq "$HA" arm t1 "$HEAD_A" >/dev/null || fail "the first mate1 must arm"
mq "$HB" arm t1 "$HEAD_A" >/dev/null || fail "the second mate1 must arm"
assert_present "$Q/watches/$HEAD_A.$sid.$ka.json" "the first mate1's receipt is written"
assert_present "$Q/watches/$HEAD_A.$sid.$kb.json" "the second mate1's receipt is a separate file"
mq "$HA" retire t1 "$HEAD_A" >/dev/null
assert_present "$Q/watches/$HEAD_A.$sid.$kb.json" "the first mate1's retire leaves the second mate1's receipt"
mq "$HB" retire t1 "$HEAD_A" >/dev/null
mq "$HB" retire t9 "$HEAD_B" >/dev/null
assert_equals "" "$(ls -A "$Q/watches")" "each home's retire removed what it wrote, under whichever key it wrote it"
pass "homes sharing a queue, even under one id, never overwrite or remove each other's receipts"

# --- watch receipts: the arm sweep and each cleanup guard ---------------------
Q="$TMP_ROOT/q-sweep"; new_queue "$Q"
H="$TMP_ROOT/h-sweep"; new_home "$H" "$Q" t1
sid=merge-queue-t1-aaaaaaaa
key=$(rkey "$H")
home_phys=$(cd -P "$H" && pwd -P)
receipt="$Q/watches/$HEAD_A.$sid.$key.json"
stale="$Q/watches/$HEAD_B.$s9.$key.json"
ledger="$H/state/merge-queue/receipts"
# A ledger entry and the receipt it names, as an arm writes them; <named> and
# <owner> are the source id and home the receipt's content claims.
plant() {  # <path> <ledger-sid> <named> <owner>
  mkdir -p "${1%/*}" "$ledger"
  jq -cn --arg sid "$3" --arg home "$4" '{schema: "lattice.merge-queue.watch.v1", source_id: $sid, home: $home}' > "$1"
  printf '%s\n' "$1" > "$ledger/$2"
}
# A watch that ended while its retirement cleanup could not finish.
plant "$stale" "$s9" "$s9" "$home_phys"
mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/sweep-arm.err" || fail "arm must succeed beside a stale receipt"
assert_equals "" "$(cat "$TMP_ROOT/sweep-arm.err")" "a sweep that removed what it should prints no warning"
assert_absent "$stale" "arm removes this home's receipt whose watch is no longer registered"
assert_absent "$ledger/$s9" "arm removes the stale receipt's ledger entry"
assert_present "$receipt" "arm keeps the receipt of a registered watch"
mq "$H" retired "$sid" || fail "retired must succeed"
assert_present "$receipt" "retired keeps the receipt of a watch registered again since"
pe "$H" retire "$sid" >/dev/null
assert_absent "$receipt" "retiring the source, as teardown and park cancel do, removes its receipt"
pass "each home sweeps only the receipts its ledger holds for watches that are gone"

# Each retired guard alone: a path-unsafe id with this adapter's prefix, and a
# safe id of another adapter whose planted receipt would otherwise be removed.
other="$Q/watches/$HEAD_B.unrelated-safe-id.$key.json"
plant "$other" unrelated-safe-id unrelated-safe-id "$home_phys"
for bad in "merge-queue-../escape" unrelated-safe-id; do
  rc=0; mq "$H" retired "$bad" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "retired refuses the source id $bad"
done
assert_present "$other" "a refused retired leaves the receipt its id names"
assert_present "$ledger/unrelated-safe-id" "a refused retired leaves the ledger entry its id names"
mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "arm must succeed beside another adapter's ledger entry"
assert_present "$other" "the arm sweep leaves an entry whose id is not this adapter's"
mq "$H" retire t1 "$HEAD_A" >/dev/null
rm -f "${other:?}" "${ledger:?}/unrelated-safe-id"
pass "retired refuses a source id that is not this adapter's, guard by guard"

# Each cleanup guard alone, on a ledger entry for an unregistered watch: every
# fixture is right in all but one way, so the receipt stays with a warning.
for case in path home source; do
  target=$stale owner=$home_phys named=$s9
  case "$case" in
    path) target="$TMP_ROOT/not-watches/$HEAD_B.$s9.$key.json" ;;
    home) owner=$(cd -P "$TMP_ROOT/h-shared-b" && pwd -P) ;;
    source) named=merge-queue-t9-cccccccc ;;
  esac
  plant "$target" "$s9" "$named" "$owner"
  mq "$H" retired "$s9" 2>"$TMP_ROOT/guard-$case.err" || fail "retired must not fail on the $case guard"
  assert_present "$target" "cleanup leaves a receipt whose $case is not this home's"
  assert_grep "left in place" "$TMP_ROOT/guard-$case.err" "cleanup warns about the receipt its $case guard kept"
  assert_present "$ledger/$s9" "cleanup keeps the ledger entry of a receipt it left"
  rm -f "${target:?}" "${ledger:?}/${s9:?}"
done
plant "$stale" "$s9" "$s9" "$home_phys"
mq "$H" retired "$s9" 2>"$TMP_ROOT/guard-none.err" || fail "retired must succeed"
assert_equals "" "$(cat "$TMP_ROOT/guard-none.err")" "a receipt that passes every guard is removed without a warning"
assert_absent "$stale" "cleanup removes a receipt that passes every guard"
assert_absent "$ledger/$s9" "cleanup then removes its ledger entry"
pass "receipt cleanup removes only this home's file for that watch, guard by guard"

if [ "$(id -u)" -ne 0 ]; then
  mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "arm must succeed before the unremovable retire"
  plant "$stale" "$s9" "$s9" "$home_phys"
  chmod 555 "$Q/watches"
  mq "$H" retire t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/retire-stuck.err"; rc=$?
  stuck_source_left=0; [ -e "$H/state/procevent/$sid.source" ] && stuck_source_left=1
  mq "$H" arm t1 "$HEAD_A" >/dev/null 2>"$TMP_ROOT/sweep-stuck.err" || rc=1
  pe "$H" retire "$sid" >/dev/null 2>"$TMP_ROOT/pe-retire-stuck.err" || rc=1
  chmod 755 "$Q/watches"
  assert_equals 0 "$rc" "an unremovable receipt fails neither retire nor arm"
  assert_grep "could not remove the watch receipt $receipt" "$TMP_ROOT/retire-stuck.err" \
    "retire warns about a receipt it could not remove"
  assert_equals 0 "$stuck_source_left" "the watch still retires behind an unremovable receipt"
  assert_grep "could not remove the watch receipt $stale" "$TMP_ROOT/sweep-stuck.err" \
    "the arm sweep warns about a stale receipt it could not remove"
  assert_grep "could not remove the watch receipt $receipt" "$TMP_ROOT/pe-retire-stuck.err" \
    "the generic retire passes on the adapter's warning"
  assert_present "$ledger/$sid" "an unremovable receipt keeps its ledger entry for the next sweep"
  mq "$H" arm t1 "$HEAD_A" >/dev/null || fail "arm must succeed once the folder is writable"
  mq "$H" retire t1 "$HEAD_A" >/dev/null
  assert_absent "$stale" "the next arm's sweep removes the stale receipt once it can"
  assert_absent "$receipt" "the next retire removes the receipt once it can"
  pass "a receipt that cannot be removed is warned about and never blocks the watch"
fi
