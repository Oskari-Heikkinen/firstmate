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
# Real park cancellation inside cleanup must not kill this runner mid-action.
"$ROOT/bin/fm-park.sh" cancel "\$1" >/dev/null || exit 1
cp "\$FM_HOME/state/\$1.status" "$TMP_ROOT/status-at-cleanup"
rm -f "\$FM_HOME/state/\$1.status"
echo "cleanup-returned \$1" >> "$CALLS"
SH
cat > "$FM_MERGE_QUEUE_CONTROL_BIN" <<SH
#!/usr/bin/env bash
echo "control \$1 \$2 \${3-}" >> "$CALLS"
if [ "\$2" = relaunch ]; then cat "\$4" > "$TMP_ROOT/relaunch-note"; fi
SH
cat > "$FM_MERGE_QUEUE_FLEET_SYNC_BIN" <<SH
#!/usr/bin/env bash
echo "fleet-sync \$*" >> "$CALLS"
SH
chmod +x "$FM_MERGE_QUEUE_TEARDOWN_BIN" "$FM_MERGE_QUEUE_CONTROL_BIN" "$FM_MERGE_QUEUE_FLEET_SYNC_BIN"

mq() { FM_HOME="$1" "$ROOT/bin/fm-procevent-merge-queue.sh" "${@:2}"; }
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

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
pass "handoff hands the head over, arms its watch, and declares the wait"

touch "$Q/refuse"
if mq "$H" handoff t1 fm/t1 "$HEAD_B" -- again 2>"$TMP_ROOT/refused.err"; then
  fail "a refused queue handoff must fail"
fi
assert_grep "refused the handoff" "$TMP_ROOT/refused.err" "the refusal is reported"
assert_absent "$H/state/procevent/merge-queue-t1-bbbbbbbb.source" "a refused handoff arms nothing"
assert_no_grep "$HEAD_B" "$H/state/t1.status" "a refused handoff declares no wait"
rm -f "$Q/refuse"
if mq "$H" handoff nosuch fm/x "$HEAD_A" -- x 2>/dev/null; then
  fail "handoff for a task this home does not hold must be refused"
fi
pass "a refused or foreign handoff arms and records nothing"

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
pe "$H" reconcile >/dev/null
printf 'RESULT 2026-09-27T18:02:00Z head=%s outcome=taken main=- note=car-9\n' "$HEAD_A" >> "$Q/queue.log"
printf 'RESULT 2026-09-27T18:05:00Z head=%s outcome=landed main=%s files=15 identical=15 differ=- dropped=- note=car-9; gate green; evidence .merge-agent/evidence/fbd6f77b\n' "$HEAD_A" "$MAIN" >> "$Q/queue.log"
wait_for source_gone "$H" "$sid" || {
  pe "$H" list >&2
  fail "the landed watch did not end"
}
wait_for handled_is "$H" 1 || fail "cleanup killed its runner before acknowledgement"
assert_grep "cleanup-returned t1" "$CALLS" "cancelling the adopted watch during cleanup returns without killing its own runner"
assert_present "$(compgen -G "$H/state/procevent-inbox/$sid.*.result" | head -1)" "terminal retirement preserves captured evidence"
wait_for grep -q "^teardown t1" "$CALLS" || fail "cleanup was not run"
assert_grep "fleet-sync $H/project" "$CALLS" "the project clone is refreshed"
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
