#!/usr/bin/env bash
# tests/fm-watch-quiet-waits.test.sh - quiet waits and superseded blockers.
# A `paused:` line may declare a machine-checkable wait condition
# ([wait=heavy:<id>], [wait=until:<UTC>], [wait=merge-result:<sha>],
# [wait=receipt:<path>]; status_declared_wait_check in bin/fm-classify-lib.sh
# owns the vocabulary). While it holds, the watcher acknowledges a bare turn-end
# or a stale pane for that task itself, recording it in state/.quiet-wait-acks;
# a condition that stops holding or an endpoint with no agent still wakes. A
# typed `note [supersedes=<kind>]:` evidence line closes every open blocker in
# the shared OPEN DECISIONS fold, never a needs-decision.
# Heavy-slot job records here are fixtures only.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-quiet-waits-tests)

HEAVY_SLOT_STATE_DIR="$TMP_ROOT/heavy-slot"
export HEAVY_SLOT_STATE_DIR
mkdir -p "$HEAVY_SLOT_STATE_DIR/jobs"

heavy_record() {  # <id> <state> [pid]
  printf '{"schema":"heavy-slot-job/v1","id":"%s","state":"%s","pid":%s,"label":"fixture"}\n' \
    "$1" "$2" "${3:-null}" > "$HEAVY_SLOT_STATE_DIR/jobs/$1.json"
}

utc_at() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

wait_rc() {  # <line> [now]
  local rc=0
  status_declared_wait_check "$@" || rc=$?
  printf '%s' "$rc"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]; sets WATCH_PID
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
  WATCH_PID=$!
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

backdate() {  # <seconds-ago> <file>
  local back
  back=$(( $(date +%s) - $1 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$2"
  else touch -m -d "@$back" "$2"; fi
}

# 0 once <pid>'s watcher completed a whole poll cycle while alive, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A heartbeat may be written during signal coalescing, before classification.
# Wait for the observable acknowledgement before stopping a quiet watcher.
wait_quiet_ack() {  # <state> <pid> <task> <turn-ended|stale> <condition>
  local state=$1 pid=$2 row i=0
  row=$(printf '\t%s\t%s\t%s' "$3" "$4" "$5")
  while [ "$i" -lt 300 ]; do
    grep -F "$row" "$state/.quiet-wait-acks" >/dev/null 2>&1 && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

# Acknowledge the intentional stop of a reaped watcher, so the next watcher in
# the same state starts clean instead of re-surfacing the earlier cycle.
ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

prime_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

# --- the wait-tag vocabulary as pure functions ------------------------------

test_wait_conditions_hold_only_while_checkable() {
  local now line cond="" log receipt_dir
  now=$(date +%s)

  heavy_record q1 queued "$$"
  line="paused [key=heavy-q1] [wait=heavy:q1]: heavy job q1 queued until $(utc_at $((now - 60)))"
  [ "$(wait_rc "$line" "$now")" = 0 ] || fail "a queued heavy job with a live pid did not hold"
  status_declared_wait_check "$line" "$now" cond
  [ "$cond" = heavy:q1 ] || fail "the holding condition was not reported: $cond"
  heavy_record q2 running
  [ "$(wait_rc "paused [wait=heavy:q2]: running" "$now")" = 0 ] || fail "a running heavy job without a pid did not hold"
  heavy_record q3 finished
  [ "$(wait_rc "paused [wait=heavy:q3]: done soon" "$now")" = 1 ] || fail "a finished heavy job still held"
  heavy_record q4 running 999999999
  [ "$(wait_rc "paused [wait=heavy:q4]: stale pid" "$now")" = 1 ] || fail "a heavy job whose pid is gone still held"
  [ "$(wait_rc "paused [wait=heavy:absent]: no record" "$now")" = 1 ] || fail "a missing heavy record held"
  printf 'not json\n' > "$HEAVY_SLOT_STATE_DIR/jobs/bad.json"
  [ "$(wait_rc "paused [wait=heavy:bad]: unreadable" "$now")" = 1 ] || fail "an unreadable heavy record held"
  [ "$(wait_rc "paused [wait=heavy:-bad]: bad id" "$now")" = 1 ] || fail "an invalid heavy job id held"

  [ "$(wait_rc "paused [wait=until:$(utc_at $((now + 600)))]: later" "$now")" = 0 ] || fail "a future until did not hold"
  [ "$(wait_rc "paused [wait=until:$(utc_at $((now - 1)))]: earlier" "$now")" = 1 ] || fail "a passed until held"
  [ "$(wait_rc "paused: waiting until $(utc_at $((now + 600)))" "$now")" = 0 ] || fail "the prose until clause stopped counting"
  [ "$(wait_rc "paused: waiting on upstream" "$now")" = 2 ] || fail "a plain pause claimed a condition"
  [ "$(wait_rc "blocked [wait=heavy:q1]: not a pause" "$now")" = 2 ] || fail "a non-pause line was treated as a wait"
  [ "$(wait_rc "paused [wait=bogus:x]: unknown kind" "$now")" = 1 ] || fail "an unknown wait kind held"

  log="$TMP_ROOT/queue.log"
  printf 'RESULT 2026-09-27T00:00:00Z head=%s outcome=taken main=x note=-\n' "$(printf 'a%.0s' $(seq 1 40))" > "$log"
  [ "$(FM_MERGE_QUEUE_LOG="$log" wait_rc "paused [wait=merge-result:aaaaaaa]: queued" "$now")" = 0 ] \
    || fail "a merge-queue head with only a taken result did not hold"
  printf 'RESULT 2026-09-27T00:01:00Z head=%s outcome=landed main=y note=-\n' "$(printf 'a%.0s' $(seq 1 40))" >> "$log"
  [ "$(FM_MERGE_QUEUE_LOG="$log" wait_rc "paused [wait=merge-result:aaaaaaa]: queued" "$now")" = 1 ] \
    || fail "a merge-queue head with a final result still held"
  [ "$(FM_MERGE_QUEUE_LOG="$TMP_ROOT/absent.log" wait_rc "paused [wait=merge-result:bbbbbbb]: queued" "$now")" = 1 ] \
    || fail "an unreadable merge-queue log held"

  receipt_dir="$TMP_ROOT/receipts"
  mkdir -p "$receipt_dir"
  [ "$(wait_rc "paused [wait=receipt:$receipt_dir/r1]: awaiting" "$now")" = 0 ] || fail "an absent receipt did not hold"
  : > "$receipt_dir/r1"
  [ "$(wait_rc "paused [wait=receipt:$receipt_dir/r1]: awaiting" "$now")" = 1 ] || fail "a written receipt still held"
  [ "$(wait_rc "paused [wait=receipt:$TMP_ROOT/nowhere/r]: awaiting" "$now")" = 1 ] || fail "a receipt in a missing dir held"

  # An explicit tag governs over a prose ETA that already passed.
  line="paused [wait=heavy:q1]: heavy job q1 queued until $(utc_at $((now - 600)))"
  [ "$(wait_rc "$line" "$now")" = 0 ] || fail "a passed prose ETA overrode a holding wait tag"
  [ "$(wait_rc "paused [wait=heavy:q1] [wait=heavy:q2]: two" "$now")" = 1 ] || fail "two wait tags were accepted"
  pass "wait tags hold only while their condition is checkable and true, and an explicit tag governs the prose ETA"
}

test_configured_merge_result_checker() {
  local dir head line now
  dir="$TMP_ROOT/configured-result"
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$dir/config" "$dir/queue"
  printf 'dir=%s\n' "$dir/queue" > "$dir/config/merge-queue"
  printf 'RESULT t head=%s outcome=taken\n' "$head" > "$dir/queue/queue.log"
  now=$(date +%s)
  line="paused [wait=merge-result:$head]: queued"
  assert_equals 0 "$(FM_HOME="$dir" wait_rc "$line" "$now")" "configured log pending head holds"
  cat > "$dir/queue/result.sh" <<'SH'
#!/usr/bin/env bash
printf 'RESULT t head=%s outcome=conflict main=- note=helper\n' "$1"
SH
  chmod +x "$dir/queue/result.sh"
  assert_equals 1 "$(FM_HOME="$dir" wait_rc "$line" "$now")" "configured helper final result overrides pending log"
  rm -f "$dir/queue/result.sh" "$dir/queue/queue.log"
  assert_equals 1 "$(FM_HOME="$dir" wait_rc "$line" "$now")" "unreadable configured source cannot hold a wait"
  pass "merge-result checks reuse the configured queue helper and log"
}

test_wait_tag_survives_stamping() {
  local line stamped
  line='paused [key=heavy-q1] [wait=heavy:q1]: heavy job q1 queued'
  stamped=$(status_stamp_line "$line")
  case "$stamped" in
    'paused [key=heavy-q1] [wait=heavy:q1] [at='*']: heavy job q1 queued') ;;
    *) fail "stamping split the wait tag from the head: $stamped" ;;
  esac
  [ "$(wait_rc "$stamped")" = 0 ] || fail "a stamped heavy wait stopped holding"
  [ "$(_fm_decision_key "$stamped")" = heavy-q1 ] || fail "a stamped wait lost its key"
  pass "a wait tag stays part of the status head through emission-time stamping"
}

# --- superseded blockers ----------------------------------------------------

test_supersedes_note_closes_blockers_not_decisions() {
  local dir f open
  dir="$TMP_ROOT/supersede-fold"; mkdir -p "$dir"
  f="$dir/t.status"
  printf 'kind=ship\n' > "$dir/t.meta"
  {
    printf 'blocked: the pipeline died under me\n'
    printf 'blocked [key=disk]: disk full\n'
    printf 'needs-decision [key=api]: which API version?\n'
    printf 'note [supersedes=relaunch] [at=1790000000]: relaunched on codex (from claude); superseded open blockers: unkeyed disk\n'
    printf 'blocked [key=later]: a fresh blocker after the relaunch\n'
  } > "$f"
  open=$(status_open_decisions "$f")
  assert_contains "$open" "api" "the supersedes note closed a needs-decision"
  assert_contains "$open" "later" "the supersedes note closed a later blocker"
  assert_not_contains "$open" "disk" "the supersedes note left a keyed blocker open"
  assert_not_contains "$open" "pipeline died" "the supersedes note left an unkeyed blocker open"

  printf 'note [supersedes=whatever]: not a known kind\n' >> "$f"
  assert_contains "$(status_open_decisions "$f")" "later" "an unknown supersedes kind closed a blocker"
  printf 'note: ordinary progress mentioning supersedes=relaunch\n' >> "$f"
  assert_contains "$(status_open_decisions "$f")" "later" "an untyped note closed a blocker"
  pass "a typed supersedes note closes every earlier open blocker and never a needs-decision"
}

test_supersede_writer_records_evidence_once() {
  local dir state f rc
  dir="$TMP_ROOT/supersede-writer"; state="$dir/state"; mkdir -p "$state"
  f="$state/t.status"
  printf 'kind=ship\n' > "$state/t.meta"
  printf 'working: started\n' > "$f"
  rc=0
  supersede_blockers "$state" "$f" relaunch "relaunched" || rc=$?
  [ "$rc" -eq 0 ] || fail "superseding with nothing open failed"
  assert_not_contains "$(cat "$f")" "supersedes" "a supersedes note was written with nothing open"

  printf 'blocked [key=net]: network down\nneeds-decision [key=api]: which API?\n' >> "$f"
  supersede_blockers "$state" "$f" validation-run "validation run requested" \
    || fail "superseding an open blocker failed"
  assert_contains "$(cat "$f")" "note [supersedes=validation-run] [at=" "the evidence note was not stamped and typed"
  assert_contains "$(cat "$f")" "superseded open blockers: net" "the evidence note did not name the closed blocker"
  assert_not_contains "$(status_open_decisions "$f")" "net" "the written evidence did not close the blocker"
  assert_contains "$(status_open_decisions "$f")" "api" "the written evidence closed a needs-decision"
  pass "the supersede writer appends typed evidence only when a blocker is open"
}

# --- watcher: turn-end under a holding wait is acknowledged quietly ----------

test_turn_end_under_holding_wait_is_acknowledged() {
  local dir state fakebin out pid statusf
  dir=$(make_case quiet-turn-end); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  statusf="$state/task.status"
  printf 'window=test:fm-task\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/task.meta"
  heavy_record tj1 queued "$$"
  printf 'paused [key=heavy-tj1] [wait=heavy:tj1] [at=%s]: heavy job tj1 queued\n' "$(date +%s)" > "$statusf"
  prime_seen "$statusf"
  : > "$state/task.turn-ended"
  # Not provably working: without the quiet wait this turn-end would surface.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out" env FM_FAKE_TMUX_WINDOW=test:fm-task FM_FAKE_TMUX_CURRENT_COMMAND=grok
  pid=$WATCH_PID
  if ! wait_quiet_ack "$state" "$pid" task turn-ended heavy:tj1 \
    || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a turn-end under a holding heavy wait was not quietly acknowledged: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$state/.wake-queue" ] || fail "a turn-end under a holding wait was queued"
  grep -F "$(printf '\ttask\tturn-ended\theavy:tj1')" "$state/.quiet-wait-acks" >/dev/null \
    || fail "the quiet acknowledgement was not recorded: $(cat "$state/.quiet-wait-acks" 2>/dev/null)"
  ack_stopped_cycle "$state" >/dev/null || fail "could not acknowledge the intentional quiet-phase stop"

  # The job finished: the same kind of turn-end now surfaces.
  heavy_record tj1 finished
  : > "$out"
  printf 'x' >> "$state/task.turn-ended"
  watch_bg "$state" "$fakebin" "$out"
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "a turn-end after the heavy job finished did not surface"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "the surfaced turn-end was not printed: $(cat "$out")"
  pass "a bare turn-end is acknowledged quietly while the declared wait holds and surfaces once it lapses"
}

test_turn_end_with_prose_until_still_wakes() {
  local dir state pid future
  future=$(utc_at $(( $(date +%s) + 600 )))
  dir=$(stale_case quiet-turnend-prose-until "paused: waiting until $future")
  state="$dir/state"
  backdate 60 "$state/held.status"
  : > "$state/held.turn-ended"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting'
  stale_watch_bg "$dir" grok
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "a turn-end under prose until was silently acknowledged"
  assert_contains "$(cat "$dir/watch.out")" "signal: $state/held.turn-ended" \
    "a prose until did not surface its bare turn-end"
  [ ! -s "$state/.quiet-wait-acks" ] || fail "a prose-until turn-end was quietly acknowledged"
  pass "untagged prose until cannot quietly acknowledge a bare turn-end"
}

test_new_status_line_under_holding_wait_still_wakes() {
  local dir state fakebin out pid statusf
  dir=$(make_case quiet-new-status); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  statusf="$state/task.status"
  heavy_record tj2 running "$$"
  printf 'paused [wait=heavy:tj2]: heavy job tj2 running\n' > "$statusf"
  prime_seen "$statusf"
  printf 'failed: the build broke\n' >> "$statusf"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · none'
  watch_bg "$state" "$fakebin" "$out"
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "a new failed line under a holding wait did not wake"
  grep -F "signal: $statusf" "$out" >/dev/null || fail "the new status line was not surfaced: $(cat "$out")"
  [ ! -s "$state/.quiet-wait-acks" ] || fail "a new status line was quietly acknowledged"
  pass "a new status line still wakes the supervisor while a declared wait holds"
}

# --- watcher: stale pane under a holding wait --------------------------------

stale_case() {  # <name> <status-line> -> dir
  local dir state window key
  dir=$(make_case "$1"); state="$dir/state"
  window="test:fm-held"
  printf 'idle, waiting on the heavy slot' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf '%s\n' "$2" > "$state/held.status"
  backdate 500 "$state/held.status"
  prime_seen "$state/held.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle, waiting on the heavy slot')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

stale_watch_bg() {  # <dir> <current-command>; sets WATCH_PID
  local dir=$1 state="$1/state" command=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="test:fm-held" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND="$command" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$dir/watch.out" &
  WATCH_PID=$!
}

supersede_blockers() {  # <state> <status> <kind> <evidence>
  (. "$ROOT/bin/fm-wake-lib.sh"; fm_status_supersede_blockers "$@")
}

test_stale_under_holding_wait_is_acknowledged() {
  local dir state pid
  heavy_record sj1 queued "$$"
  dir=$(stale_case quiet-stale 'paused [wait=heavy:sj1]: heavy job sj1 queued')
  state="$dir/state"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · heavy job sj1 queued'
  stale_watch_bg "$dir" grok
  pid=$WATCH_PID
  if ! wait_quiet_ack "$state" "$pid" held stale heavy:sj1 \
    || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a stale pane under a holding heavy wait was not quietly acknowledged: $(cat "$dir/watch.out")"
  fi
  reap "$pid"
  [ ! -s "$state/.wake-queue" ] || fail "a stale pane under a holding wait was queued"
  [ "$(grep -c "$(printf '\theld\tstale\theavy:sj1')" "$state/.quiet-wait-acks")" = 1 ] \
    || fail "the quiet stale acknowledgement was not recorded exactly once: $(cat "$state/.quiet-wait-acks" 2>/dev/null)"
  pass "a stale pane whose declared wait holds is acknowledged once without a wake, past the ordinary recheck cadence"
}

test_stale_after_wait_lapses_wakes() {
  local dir state pid
  heavy_record sj2 failed
  dir=$(stale_case quiet-stale-lapsed 'paused [wait=heavy:sj2]: heavy job sj2 queued')
  state="$dir/state"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · heavy job sj2 queued'
  stale_watch_bg "$dir" grok
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "a stale pane whose declared wait lapsed did not wake"
  grep -F "stale: test:fm-held" "$dir/watch.out" >/dev/null || fail "the lapsed wait did not print a stale wake"
  grep -F "no longer holds" "$dir/watch.out" >/dev/null || fail "the wake did not say the condition stopped holding: $(cat "$dir/watch.out")"
  [ ! -s "$state/.quiet-wait-acks" ] || fail "a lapsed wait was quietly acknowledged"
  pass "a stale pane whose declared wait stopped holding wakes at once"
}

test_stale_with_dead_endpoint_wakes() {
  local dir state pid
  heavy_record sj3 running "$$"
  dir=$(stale_case quiet-stale-dead 'paused [wait=heavy:sj3]: heavy job sj3 running')
  state="$dir/state"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · heavy job sj3 running'
  stale_watch_bg "$dir" zsh
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "a holding wait whose endpoint has no agent did not wake"
  grep -F "stale: test:fm-held" "$dir/watch.out" >/dev/null || fail "the dead endpoint did not print a stale wake"
  grep -F "no running agent" "$dir/watch.out" >/dev/null || fail "the wake did not name the missing agent: $(cat "$dir/watch.out")"
  pass "a holding wait whose endpoint has no running agent still wakes"
}

test_hanging_queue_helper_cannot_stall_supervision() {
  local dir state pid head started elapsed
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  dir=$(stale_case hanging-queue-helper "paused [wait=merge-result:$head]: queued")
  state="$dir/state"
  mkdir -p "$dir/config" "$dir/queue"
  printf 'dir=%s\n' "$dir/queue" > "$dir/config/merge-queue"
  cat > "$dir/queue/result.sh" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "$FM_TEST_HELPER_STARTED"
sleep 60
SH
  chmod +x "$dir/queue/result.sh"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · queued'
  started=$(date +%s)
  stale_watch_bg "$dir" grok FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_TEST_HELPER_STARTED="$dir/helper-started"
  pid=$WATCH_PID
  if ! wait_for_exit "$pid" 250; then
    reap "$pid"; fail "hanging result helper stalled supervision beyond its five-second read bound"
  fi
  elapsed=$(( $(date +%s) - started ))
  assert_present "$dir/helper-started" "supervision actually entered the hanging queue helper"
  [ "$elapsed" -lt 25 ] || fail "supervision took ${elapsed}s with the hanging helper"
  assert_contains "$(cat "$dir/watch.out")" "no longer holds" "helper timeout uses existing unreadable-wait notification"
  [ ! -s "$state/.quiet-wait-acks" ] || fail "timed-out queue helper was treated as a holding wait"
  pass "a hung external result helper cannot stall supervision and uses the existing unreadable-result notification"
}

test_stopped_queue_wait_requires_exact_park_proof() {
  local dir state pid head mode
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  # wake-helpers uses an empty code-root fixture to avoid host tangle checks.
  # This scenario registers a real adapter, so expose it and its libraries.
  ln -s "$ROOT/bin" "$FM_ROOT_OVERRIDE/bin"
  for mode in valid generation source tag; do
    dir=$(stale_case "queue-park-$mode" "paused: preparing queue")
    state="$dir/state"
    mkdir -p "$dir/config" "$dir/queue"
    printf 'spawn_gen=g1\n' >> "$state/held.meta"
    printf 'dir=%s\n' "$dir/queue" > "$dir/config/merge-queue"
    : > "$dir/queue/queue.log"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/queue/handoff.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/control"
    chmod +x "$dir/queue/handoff.sh" "$dir/control"
    fm_test_track_procevent_home "$dir"
    FM_HOME="$dir" FM_PARK_CONTROL_OVERRIDE="$dir/control" \
      "$ROOT/bin/fm-procevent-merge-queue.sh" handoff held fm/held "$head" -- test >/dev/null \
      || fail "queue handoff could not park"
    case "$mode" in
      generation) sed 's/^spawn_gen=g1/spawn_gen=g2/' "$state/held.meta" > "$dir/new-meta"; mv "$dir/new-meta" "$state/held.meta" ;;
      source) FM_HOME="$dir" "$ROOT/bin/fm-procevent-merge-queue.sh" retire held "$head" >/dev/null ;;
      tag) printf 'paused [wait=until:2099-01-01T00:00Z]: not the queue wait\n' >> "$state/held.status" ;;
    esac
    prime_seen "$state/held.status"
    backdate 500 "$state/held.status"
    export FM_FAKE_CREW_STATE='state: paused · source: status-log · queued'
    stale_watch_bg "$dir" zsh FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config"
    pid=$WATCH_PID
    if [ "$mode" = valid ]; then
      if ! wait_quiet_ack "$state" "$pid" held stale "merge-result:$head" || ! wait_poll_cycle "$state" "$pid"; then
        reap "$pid"; fail "a proven stopped queue worker raised a stuck alarm: $(cat "$dir/watch.out")"
      fi
      reap "$pid"
      [ ! -s "$state/.wake-queue" ] || fail "proven queue park queued a wake"
    else
      wait_for_exit "$pid" 100 || fail "mismatched $mode proof silenced the dead endpoint"
      assert_contains "$(cat "$dir/watch.out")" "no running agent" "invalid $mode proof must still report missing agent"
    fi
  done
  pass "only the matching queue park incarnation, wait tag and adopted source silence a stopped worker alarm"
}

test_stale_with_unreadable_liveness_wakes() {
  local dir pid
  heavy_record unreadable running "$$"
  dir=$(stale_case quiet-stale-unreadable 'paused [wait=heavy:unreadable]: still running')
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · still running'
  stale_watch_bg "$dir" ''
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "an unreadable endpoint was silently acknowledged"
  assert_contains "$(cat "$dir/watch.out")" "unreadable" "the wake did not name unreadable liveness"
  [ ! -s "$dir/state/.quiet-wait-acks" ] || fail "unreadable liveness was quietly acknowledged"
  pass "a holding condition cannot silence unverifiable endpoint liveness"
}

test_prose_until_keeps_the_periodic_bound() {
  local dir pid future
  future=$(utc_at $(( $(date +%s) + 600 )))
  dir=$(stale_case quiet-prose-until "paused: waiting until $future")
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting'
  stale_watch_bg "$dir" grok
  pid=$WATCH_PID
  wait_for_exit "$pid" 100 || fail "a future prose until extended the periodic recheck bound"
  assert_contains "$(cat "$dir/watch.out")" "beyond the recheck cadence" "the prose-until recheck lost its reason"
  [ ! -s "$dir/state/.quiet-wait-acks" ] || fail "an untagged prose until was quietly acknowledged"
  pass "a future prose until retains the ordinary periodic recheck bound"
}

test_changed_lane_wakes_before_the_periodic_bound() {  # <stale|turn-end>
  local trigger=$1 mode dir state pid json command ack_kind
  ack_kind=stale
  [ "$trigger" != turn-end ] || ack_kind=turn-ended
  for mode in head inbox pr liveness; do
    heavy_record "change-$mode" queued "$$"
    dir=$(stale_case "quiet-change-$trigger-$mode" "paused [wait=heavy:change-$mode]: queued")
    state="$dir/state"
    fm_git_init_commit "$dir/wt"
    printf 'worktree=%s\n' "$dir/wt" >> "$state/held.meta"
    json="$dir/pr.json"
    if [ "$mode" = pr ]; then
      cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_GH_PR_JSON"
SH
      chmod +x "$dir/fakebin/gh"
      printf 'pr=https://github.com/o/r/pull/7\n' >> "$state/held.meta"
      printf '{"state":"OPEN","headRefOid":"aaa","statusCheckRollup":[{"conclusion":"SUCCESS"}]}' > "$json"
    fi
    # Below the periodic bound, take the baseline while the lane is unchanged.
    backdate 60 "$state/held.status"
    export FM_FAKE_CREW_STATE='state: paused · source: status-log · queued'
    [ "$trigger" != turn-end ] || : > "$state/held.turn-ended"
    stale_watch_bg "$dir" grok FM_FAKE_GH_PR_JSON="$json"
    pid=$WATCH_PID
    if ! wait_quiet_ack "$state" "$pid" held "$ack_kind" "heavy:change-$mode" \
      || ! wait_poll_cycle "$state" "$pid"; then
      reap "$pid"; fail "[$mode] unchanged holding wait was not quietly acknowledged: $(cat "$dir/watch.out")"
    fi
    reap "$pid"
    ack_stopped_cycle "$state" >/dev/null || fail "[$mode] could not acknowledge baseline stop"
    command=grok
    case "$mode" in
      liveness) command='' ;;
      head) git -C "$dir/wt" -c user.name=Tests -c user.email=tests@example.invalid commit --allow-empty -qm next ;;
      inbox) mkdir -p "$state/held.inbox"; printf 'new instruction\n' > "$state/held.inbox/001.msg" ;;
      pr) printf '{"state":"OPEN","headRefOid":"aaa","statusCheckRollup":[{"conclusion":"FAILURE"}]}' > "$json" ;;
    esac
    [ "$trigger" != turn-end ] || printf 'x' >> "$state/held.turn-ended"
    stale_watch_bg "$dir" "$command" FM_FAKE_GH_PR_JSON="$json"
    pid=$WATCH_PID
    wait_for_exit "$pid" 100 || fail "[$trigger/$mode] changed lane stayed quiet until the periodic bound"
    if [ "$trigger" = turn-end ]; then
      assert_contains "$(cat "$dir/watch.out")" "signal: $state/held.turn-ended" \
        "[$mode] the changed-lane turn-end was not surfaced immediately"
    elif [ "$mode" = liveness ]; then
      assert_contains "$(cat "$dir/watch.out")" "unreadable" "the stale wake did not name unreadable liveness"
    else
      assert_contains "$(cat "$dir/watch.out")" "changed since its wait was last shown ($mode)" \
        "[$mode] the urgent recheck did not name the lane change"
    fi
  done
  pass "$trigger: changed HEAD, unread steers, red PR checks and unreadable liveness wake immediately while a tagged wait holds"
}

# --- drain: the evidence note is shown as the closing record -----------------

test_drain_presents_supersede_evidence() {
  local dir state f out
  dir="$TMP_ROOT/supersede-drain"; state="$dir/state"; mkdir -p "$state"
  f="$state/t.status"
  printf 'kind=ship\n' > "$state/t.meta"
  printf 'blocked [key=net]: network down\n' > "$f"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null) || fail "first drain failed"
  assert_contains "$out" "net" "the open blocker was not presented"
  supersede_blockers "$state" "$f" resume "resumed from the reboot note" \
    || fail "superseding the blocker failed"
  out=$(FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null) || fail "second drain failed"
  assert_contains "$out" "supersedes=resume" "the drain did not show the closing evidence"
  assert_contains "$out" "resumed from the reboot note" "the drain did not show the evidence text"
  pass "the drain shows a superseded blocker closed with its evidence"
}

test_wait_conditions_hold_only_while_checkable
test_wait_tag_survives_stamping
test_configured_merge_result_checker
test_supersedes_note_closes_blockers_not_decisions
test_supersede_writer_records_evidence_once
test_turn_end_under_holding_wait_is_acknowledged
test_new_status_line_under_holding_wait_still_wakes
test_turn_end_with_prose_until_still_wakes
test_stale_under_holding_wait_is_acknowledged
test_stale_after_wait_lapses_wakes
test_stale_with_dead_endpoint_wakes
test_stale_with_unreadable_liveness_wakes
test_stopped_queue_wait_requires_exact_park_proof
test_hanging_queue_helper_cannot_stall_supervision
test_prose_until_keeps_the_periodic_bound
test_changed_lane_wakes_before_the_periodic_bound stale
test_changed_lane_wakes_before_the_periodic_bound turn-end
test_drain_presents_supersede_evidence
