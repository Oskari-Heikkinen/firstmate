#!/usr/bin/env bash
# tests/fm-watch-reminder-group.test.sh - grouped declared-wait reminders.
# The periodic reminder of an untagged wait whose declared time lies beyond
# FM_PAUSE_RESURFACE_SECS only repeats an unchanged state, so bin/fm-watch.sh
# delivers every such reminder that is not yet due with any recheck it delivers
# and restarts its cadence there (recheck_flush). This drives real watcher runs
# over parked lanes with random phases, aging every clock the recheck schedule
# reads by one fixed step between runs, and checks the delivery contract: no
# reminder arrives later than its own due time, the reminders share at most one
# wake per cadence, and a wait that stops holding still wakes in the run it
# lapses. Further cases check that a reminder carried by an unrelated wake
# restarts its cadence, that an out-of-date reminder is dropped rather than
# delivered, and that nothing is grouped while the away-mode daemon owns
# triage. The single-recheck schedule itself is covered by
# tests/fm-watch-triage.test.sh and the quiet-wait lapse by
# tests/fm-watch-quiet-waits.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-reminder-group-tests)

# No case here reads the home summary or the inactive-outcome scan
# (tests/fm-home-summary-refresh.test.sh and tests/fm-inactive-reconcile.test.sh
# own them), so neither competes with the triage under test.
export FM_HOME_SUMMARY_INTERVAL=1000000
export FM_INACTIVE_RECONCILE_BIN=true

HEAVY_SLOT_STATE_DIR="$TMP_ROOT/heavy-slot"
export HEAVY_SLOT_STATE_DIR
mkdir -p "$HEAVY_SLOT_STATE_DIR/jobs"

# The cadence is long against the few seconds each run takes, so the real time
# that passes during a trial cannot move a reminder across a step.
CADENCE=3600
STEP=600
STEPS=20

SEED=${FM_TEST_REMINDER_SEED:-$(date +%s)}
RANDOM=$SEED

heavy_record() {  # <id> <state> [pid]
  printf '{"schema":"heavy-slot-job/v1","id":"%s","state":"%s","pid":%s,"label":"fixture"}\n' \
    "$1" "$2" "${3:-null}" > "$HEAVY_SLOT_STATE_DIR/jobs/$1.json"
}

iso_utc_at() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

set_mtime() {  # <epoch> <file>
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$1" '+%Y%m%d%H%M.%S')" "$2"
  else touch -m -d "@$1" "$2"; fi
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on a pre-existing status (mirrors fm-watch.sh's stat_sig).
seen_sig() {
  local reported size ident
  reported=$(status_observed_signature "$1")
  size=$(size_of "$1")
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null
}

# 0 once <pid>'s watcher completed a whole poll cycle while alive, 1 if it
# exited first: it waits for a positive cycle stamp on the beacon, then for
# that stamp to advance.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(head -n 1 "$beat" 2>/dev/null)
    case "$first" in
      ''|*[!0-9]*|0) ;;
      *) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(head -n 1 "$beat" 2>/dev/null)
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
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

# One idle lane under <line>, whose status is <age> seconds old, stably stale at
# the shared pane text.
group_lane() {  # <dir> <task> <age> <line> <meta>
  local dir=$1 task=$2 state="$1/state" statusf
  statusf="$state/$task.status"
  printf '%s' "$5" > "$state/$task.meta"
  printf '%s\n' "$4" > "$statusf"
  set_mtime "$(( $(date +%s) - $3 ))" "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-${task}_status"
  printf '%s' "$(hash_text 'idle, waiting')" > "$state/.hash-test_fm-$task"
  printf '1\n' > "$state/.count-test_fm-$task"
}

# Move every clock the recheck schedule reads <secs> into the past: the status
# writes it anchors on and the last recheck it throttles on. Status signatures
# carry no mtime, so this is not a new status line.
age_clocks() {  # <state> <secs>
  local f m
  for f in "$1"/*.status "$1"/.paused-resurfaced-* "$1"/.recheck-surfaced-*; do
    [ -f "$f" ] || continue
    m=$(file_mtime "$f")
    set_mtime "$((m - $2))" "$f"
  done
}

# A cold supervisor and no wake batch, so a reminder wakes only when it is due
# and nothing but the cadence decides when.
group_watch() {  # <dir> <windows>
  env PATH="$1/fakebin:$PATH" FM_FAKE_TMUX_WINDOWS="$2" FM_FAKE_TMUX_CAPTURE="$1/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_FAKE_CREW_STATE_u='state: paused · source: status-log · heavy job queued' \
    FM_STATE_OVERRIDE="$1/state" FM_CREW_STATE_BIN="$1/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS="$CADENCE" FM_STANDING_WAITS_CEILING_SECS=100000000 \
    FM_TEST_RECHECK_WARM_SECS=0 FM_WAKE_BATCH_SECS=0 FM_POLL=0.2 FM_SIGNAL_GRACE=0.2 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$1/watch.out" 2>&1 &
  GROUP_PID=$!
}

# One trial: <lanes> parked lanes whose park lines name a deadline weeks away,
# each status a random age within one cadence, plus lane u on a heavy-job wait
# that holds until run <lapse-step>, where the job fails. Simulated time is the
# real clock plus every step aged so far.
group_trial() {  # <name> <lanes> <lapse-step>
  local name=$1 lanes=$2 lapse=$3 dir state windows='' i step now offset=0 woke last_seq=0
  local rows due due_at last sm tm wake_at sim prev_sim='' wakes=0 pulled=0 delivered=0 why
  dir=$(make_case "$name"); state="$dir/state"
  printf 'idle, waiting' > "$dir/pane.txt"
  now=$(date +%s)
  for i in $(seq 1 "$lanes"); do
    group_lane "$dir" "r$i" "$((RANDOM % CADENCE))" \
      "paused: parked until $(iso_utc_at "$((now + 30 * 86400))") - waiting for the vendor reply r$i; resume on reply" \
      "$(printf 'window=test:fm-r%s\nkind=secondmate\n' "$i")"
    windows="${windows}fm-r$i"$'\n'
  done
  heavy_record "$name-u" queued "$$"
  group_lane "$dir" u "$((RANDOM % CADENCE))" "paused [wait=heavy:$name-u]: heavy job $name-u queued" \
    "$(printf 'window=test:fm-u\nkind=ship\nharness=grok\nbackend=tmux\n')"
  windows="${windows}fm-u"
  why="[seed $SEED, $name]"
  for step in $(seq 0 $((STEPS - 1))); do
    if [ "$step" -gt 0 ]; then
      age_clocks "$state" "$STEP"
      offset=$((offset + STEP))
    fi
    [ "$step" -ne "$lapse" ] || heavy_record "$name-u" failed
    # Each reminder's due time as the watcher's schedule reads it: a cadence
    # after the later of its status write and its last recheck.
    now=$(date +%s); due='' due_at=''
    for i in $(seq 1 "$lanes"); do
      sm=$(file_mtime "$state/r$i.status")
      tm=$(file_mtime "$state/.paused-resurfaced-test_fm-r$i") || tm=0
      last=$sm; [ "$tm" -le "$last" ] || last=$tm
      due_at="$due_at $last"
      [ "$((now - last))" -lt "$CADENCE" ] || due="$due test:fm-r$i"
    done
    group_watch "$dir" "$windows"
    woke=1
    if wait_poll_cycle "$state" "$GROUP_PID" && wait_poll_cycle "$state" "$GROUP_PID"; then
      reap "$GROUP_PID"
      woke=0
    elif ! wait_for_exit "$GROUP_PID" 100; then
      reap "$GROUP_PID"; fail "$why step $step: the watcher neither completed a cycle nor exited: $(cat "$dir/watch.out")"
    fi
    rows=$(awk -F '\t' -v s="$last_seq" '$2 > s && $3 == "stale"' "$state/.wake-queue" 2>/dev/null)
    last_seq=$(awk -F '\t' -v s="$last_seq" '$2 > s { s = $2 } END { print s }' "$state/.wake-queue" 2>/dev/null)
    ack_stopped_cycle "$state" || fail "$why step $step: could not acknowledge the stopped run"
    if [ "$woke" -eq 0 ]; then
      [ -z "$rows" ] || fail "$why step $step: rows were queued by a run that never woke: $rows"
      [ -z "$due" ] || fail "$why step $step: reminder(s) due without a wake:$due"
      [ "$step" -ne "$lapse" ] || fail "$why step $step: the lapsed heavy-job wait did not wake in the run it lapsed: $(cat "$dir/watch.out")"
      continue
    fi
    grep -F 'stale: test:fm-' "$dir/watch.out" >/dev/null \
      || fail "$why step $step: the run exited without a declared-wait wake: $(cat "$dir/watch.out")"
    wakes=$((wakes + 1))
    # Never later: every reminder already due is in this wake. Grouped: every
    # other reminder joins it, exactly once.
    for i in $(seq 1 "$lanes"); do
      [ "$(printf '%s\n' "$rows" | awk -F '\t' -v w="test:fm-r$i" '$4 == w { n++ } END { print n + 0 }')" -eq 1 ] \
        || fail "$why step $step: reminder r$i was not delivered exactly once with the wake (due:${due:- none}): $rows"
    done
    delivered=$((delivered + lanes))
    pulled=$((pulled + $(printf '%s\n' "$rows" | grep -c 'brought forward to group with this wake')))
    wake_at=$(printf '%s\n' "$rows" | awk -F '\t' 'NR == 1 || $1 < m { m = $1 } END { print m }')
    sim=$((wake_at + offset))
    if [ "$step" -eq "$lapse" ]; then
      printf '%s\n' "$rows" | awk -F '\t' '$4 == "test:fm-u"' | grep -F 'no longer holds' >/dev/null \
        || fail "$why step $step: the lapsed heavy-job wait was not in the wake of the run it lapsed: $rows"
    else
      # A wake no lapse raised is a reminder that was due: the oldest clock is
      # a cadence old. The due reminder's timer restarts when it is queued, a
      # moment before its row, so the gap to the previous wake may fall short
      # of a cadence by up to one poll.
      last=''
      for tm in $due_at; do [ -n "$last" ] && [ "$tm" -ge "$last" ] || last=$tm; done
      [ "$((wake_at - last))" -ge "$CADENCE" ] \
        || fail "$why step $step: a reminder wake arrived before any reminder was due: $rows"
      [ -z "$prev_sim" ] || [ "$((sim - prev_sim))" -ge "$((CADENCE - 10))" ] \
        || fail "$why step $step: two reminder wakes $((sim - prev_sim))s apart, within one ${CADENCE}s cadence"
    fi
    prev_sim=$sim
  done
  [ "$wakes" -ge 3 ] || fail "$why: only $wakes wake(s) over $((STEPS * STEP))s; the trial checked too little"
  [ "$pulled" -gt 0 ] || fail "$why: no reminder was brought forward; the trial checked nothing grouped"
  GROUP_SUMMARY="$delivered reminders over $((STEPS * STEP))s in $wakes wakes, $pulled brought forward"
}

test_reminders_group_without_delay() {
  local lapse
  lapse=$((3 + RANDOM % (STEPS - 6)))
  group_trial reminder-group-4 4 "$lapse"
  pass "4 parked lanes with random phases share one reminder wake per cadence, none late, and a lapse wakes at once ($GROUP_SUMMARY; seed $SEED)"
  lapse=$((3 + RANDOM % (STEPS - 6)))
  group_trial reminder-group-7 7 "$lapse"
  pass "7 parked lanes with random phases share one reminder wake per cadence, none late, and a lapse wakes at once ($GROUP_SUMMARY; seed $SEED)"
}

# A reminder that rides along with an unrelated wake counts as delivered: it is
# not sent again at its old due time, and its next one comes a cadence after
# the wake that carried it.
test_ride_along_restarts_the_reminder_cadence() {
  local dir state seq why="ride-along"
  dir=$(make_case reminder-ride-along); state="$dir/state"
  printf 'idle, waiting' > "$dir/pane.txt"
  group_lane "$dir" a "$((CADENCE - 900))" \
    "paused: parked until $(iso_utc_at "$(( $(date +%s) + 30 * 86400 ))") - waiting for the vendor reply; resume on reply" \
    "$(printf 'window=test:fm-a\nkind=secondmate\n')"
  group_watch "$dir" fm-a
  if ! wait_poll_cycle "$state" "$GROUP_PID" || ! wait_poll_cycle "$state" "$GROUP_PID"; then
    reap "$GROUP_PID"; fail "$why: a reminder not yet due woke the supervisor: $(cat "$dir/watch.out")"
  fi
  # Lane c, which has no window here, raises a real wake 900s before a's
  # reminder is due.
  printf 'window=test:fm-c\nkind=ship\n' > "$state/c.meta"
  printf 'needs-decision: pick a release channel\n' > "$state/c.status"
  wait_for_exit "$GROUP_PID" 100 || { reap "$GROUP_PID"; fail "$why: the unrelated wake never fired"; }
  grep -F 'signal: ' "$dir/watch.out" >/dev/null || fail "$why: the watcher did not exit on the unrelated signal: $(cat "$dir/watch.out")"
  [ "$(queued_rows "$state" 0 test:fm-a 'brought forward to group with this wake')" -eq 1 ] \
    || fail "$why: the reminder did not ride along with the unrelated wake: $(cat "$state/.wake-queue")"
  seq=$(awk -F '\t' '$2 > s { s = $2 } END { print s + 0 }' "$state/.wake-queue")
  ack_stopped_cycle "$state" || fail "$why: could not acknowledge the unrelated wake"
  rm -f "$state/c.meta" "$state/c.status"
  # Past the old due time, inside the cadence restarted by the ride-along.
  age_clocks "$state" 1200
  group_watch "$dir" fm-a
  if ! wait_poll_cycle "$state" "$GROUP_PID" || ! wait_poll_cycle "$state" "$GROUP_PID"; then
    reap "$GROUP_PID"; fail "$why: the carried reminder was sent again at its old due time: $(cat "$dir/watch.out")"
  fi
  reap "$GROUP_PID"
  [ "$(queued_rows "$state" "$seq" test:fm-a '')" -eq 0 ] \
    || fail "$why: the carried reminder was queued again: $(cat "$state/.wake-queue")"
  ack_stopped_cycle "$state" || fail "$why: could not acknowledge the quiet run"
  # A cadence after the ride-along the reminder is due again and wakes.
  age_clocks "$state" "$((CADENCE - 1200 + 60))"
  group_watch "$dir" fm-a
  wait_for_exit "$GROUP_PID" 100 || { reap "$GROUP_PID"; fail "$why: the reminder a cadence after the ride-along never woke"; }
  grep -F 'stale: test:fm-a' "$dir/watch.out" >/dev/null \
    || fail "$why: the wake a cadence after the ride-along was not the reminder: $(cat "$dir/watch.out")"
  ack_stopped_cycle "$state" || fail "$why: could not acknowledge the next reminder"
  pass "a reminder carried by an unrelated wake is not re-sent at its old due time, and is due again a cadence later"
}

# A reminder recorded while its wait still held is not delivered once the wait
# changed, its task was torn down, or its declared time came. A torn-down task
# leaves no status log; deleting only its .meta would not do, because
# window_to_task still maps an fm-<id> window to <id> by name. The
# records are left by one watcher run and an unrelated wake opens the next one,
# before that run polls any window, so only the delivery-time check stands
# between each out-of-date reminder and the supervisor.
test_out_of_date_reminders_are_dropped() {
  local dir state until t why="out-of-date"
  dir=$(make_case reminder-out-of-date); state="$dir/state"
  printf 'idle, waiting' > "$dir/pane.txt"
  until=$(( $(date +%s) + 20 ))
  for t in a b g; do
    group_lane "$dir" "$t" "$((CADENCE - 900))" \
      "paused: parked until $(iso_utc_at "$(( $(date +%s) + 30 * 86400 ))") - waiting for the vendor reply $t; resume on reply" \
      "$(printf 'window=test:fm-%s\nkind=secondmate\n' "$t")"
  done
  group_lane "$dir" d "$((CADENCE - 900))" \
    "paused: parked until $(iso_utc_at "$until") - waiting for the vendor reply d; resume on reply" \
    "$(printf 'window=test:fm-d\nkind=secondmate\n')"
  group_watch "$dir" "$(printf 'fm-a\nfm-b\nfm-g\nfm-d')"
  if ! wait_poll_cycle "$state" "$GROUP_PID" || ! wait_poll_cycle "$state" "$GROUP_PID"; then
    reap "$GROUP_PID"; fail "$why: a reminder not yet due woke the supervisor: $(cat "$dir/watch.out")"
  fi
  reap "$GROUP_PID"
  ack_stopped_cycle "$state" || fail "$why: could not acknowledge the quiet run"
  for t in a b g d; do
    [ -f "$state/.recheck-upcoming-test_fm-$t" ] || fail "$why: lane $t recorded no upcoming reminder, so the case checks nothing"
  done
  # b's wait changes, g's task is torn down, and d's time comes.
  printf 'paused: parked until %s - waiting for the second vendor reply; resume on reply\n' \
    "$(iso_utc_at "$(( $(date +%s) + 30 * 86400 ))")" >> "$state/b.status"
  printf '%s' "$(seen_sig "$state/b.status")" > "$state/.seen-b_status"
  rm -f "$state/g.meta" "$state/g.status" "$state/.seen-g_status"
  t=0
  while [ "$(date +%s)" -le "$until" ]; do
    [ "$t" -lt 300 ] || fail "$why: the clock never passed lane d's declared time"
    sleep 0.1; t=$((t + 1))
  done
  printf 'window=test:fm-c\nkind=ship\n' > "$state/c.meta"
  printf 'needs-decision: pick a release channel\n' > "$state/c.status"
  group_watch "$dir" "$(printf 'fm-a\nfm-b\nfm-d')"
  wait_for_exit "$GROUP_PID" 100 || { reap "$GROUP_PID"; fail "$why: the unrelated wake never fired"; }
  grep -F 'signal: ' "$dir/watch.out" >/dev/null || fail "$why: the watcher did not exit on the unrelated signal: $(cat "$dir/watch.out")"
  [ "$(queued_rows "$state" 0 test:fm-a 'brought forward to group with this wake')" -eq 1 ] \
    || fail "$why: the reminder still holding did not ride along: $(cat "$state/.wake-queue")"
  for t in b g d; do
    [ "$(queued_rows "$state" 0 "test:fm-$t" '')" -eq 0 ] \
      || fail "$why: lane $t's out-of-date reminder was delivered: $(cat "$state/.wake-queue")"
    grep -F "dropped upcoming declared-wait reminder (wait changed or no longer declared): test:fm-$t" \
      "$state/.watch-triage.log" >/dev/null \
      || fail "$why: lane $t's out-of-date reminder was not dropped at delivery: $(cat "$state/.watch-triage.log")"
  done
  ack_stopped_cycle "$state" || fail "$why: could not acknowledge the unrelated wake"
  pass "a reminder whose wait changed, whose task was torn down, or whose declared time came is dropped, not delivered"
}

# While the away-mode daemon owns triage it owns the whole recheck schedule, so
# no reminder is recorded or brought forward into the wakes it receives.
test_no_grouping_while_away() {
  local dir state why="away"
  dir=$(make_case reminder-away); state="$dir/state"
  printf 'idle, waiting' > "$dir/pane.txt"
  group_lane "$dir" a "$((CADENCE - 900))" \
    "paused: parked until $(iso_utc_at "$(( $(date +%s) + 30 * 86400 ))") - waiting for the vendor reply; resume on reply" \
    "$(printf 'window=test:fm-a\nkind=secondmate\n')"
  group_watch "$dir" fm-a
  if ! wait_poll_cycle "$state" "$GROUP_PID" || ! wait_poll_cycle "$state" "$GROUP_PID"; then
    reap "$GROUP_PID"; fail "$why: a reminder not yet due woke the supervisor: $(cat "$dir/watch.out")"
  fi
  reap "$GROUP_PID"
  ack_stopped_cycle "$state" || fail "$why: could not acknowledge the quiet run"
  [ -f "$state/.recheck-upcoming-test_fm-a" ] || fail "$why: lane a recorded no upcoming reminder, so the case checks nothing"
  date '+%s' > "$state/.afk"
  printf 'window=test:fm-c\nkind=ship\n' > "$state/c.meta"
  printf 'needs-decision: pick a release channel\n' > "$state/c.status"
  group_watch "$dir" fm-a
  wait_for_exit "$GROUP_PID" 100 || { reap "$GROUP_PID"; fail "$why: the unrelated wake never fired"; }
  grep -F 'signal: ' "$dir/watch.out" >/dev/null || fail "$why: the watcher did not exit on the unrelated signal: $(cat "$dir/watch.out")"
  [ "$(queued_rows "$state" 0 test:fm-a 'brought forward')" -eq 0 ] \
    || fail "$why: a reminder was brought forward while the away-mode daemon owns triage: $(cat "$state/.wake-queue")"
  pass "no reminder is brought forward while the away-mode daemon owns triage"
}

# Stale rows queued for <window> after sequence <seq> whose payload holds <text>.
queued_rows() {  # <state> <seq> <window> <text>
  awk -F '\t' -v s="$2" -v w="$3" -v t="$4" '$2 > s && $3 == "stale" && $4 == w && (t == "" || index($5, t)) { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

test_reminders_group_without_delay
test_ride_along_restarts_the_reminder_cadence
test_out_of_date_reminders_are_dropped
test_no_grouping_while_away
