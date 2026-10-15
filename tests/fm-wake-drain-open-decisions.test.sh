#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the status
# presentation bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path), each exercising the real drain script over crafted
# status logs and asserting on its printed output, not on any fold's own source
# text. Four groups:
#
# - OPEN DECISIONS single-drain correctness. The section is pure wiring around
#   fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
#   open/resolved statement).
# - The incremental, cursor-backed OPEN DECISIONS scan
#   (fm-classify-lib.sh's status_open_decisions_incremental /
#   scan_open_decisions_incremental). These drive the drain across MANY
#   successive invocations over a status log that keeps growing, and assert
#   both the printed output and a bounded-cost property: the cursor's
#   cross-drain persistence and cost bound.
# - The main-drain STATUS OUTCOME BACKSTOP, which recovers a captain-facing
#   latest status event after its queue row disappeared without a newer
#   supervision-branch outcome.
# - UNREAD STATUS: the drain must surface every still-unread informational
#   status line since the last presentation, not only the newest line. The
#   incident this pins: a `note:` answer immediately followed by a routine
#   `note:` was buried because the annotation kept only the newest line and
#   `note:` never folds into OPEN DECISIONS.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

# The outcome-backstop and unread-status cases exercise status presentation on
# a home that does not run the supervision host, so its BRANCH OUTCOMES section
# stays out of the drain; the explicit off file pins that posture on every
# primary instead of reading the code root's config
# (bin/fm-supervision-engine-lib.sh owns the gate). run_case exports the
# override only while those cases run, so the single-drain and cursor cases
# keep reading the code root's config exactly as before.
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"

# run_case <group> <host-off|host-default> <test-fn>: run one absorbed case
# with its fixtures under its group's own subdirectory of TMP_ROOT (make_case
# reads TMP_ROOT dynamically), optionally with the supervision host pinned off.
run_case() {
  local group=$1 posture=$2 fn=$3 config="$TMP_ROOT/config"
  local TMP_ROOT="$TMP_ROOT/$group"
  mkdir -p "$TMP_ROOT"
  if [ "$posture" = host-off ]; then
    local -x FM_CONFIG_OVERRIDE="$config"
  fi
  "$fn"
}

# --- OPEN DECISIONS: single-drain fold ---------------------------------------

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 159 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

# Past the section's global budget an item's text is dropped, but its task and
# key still print on the omitted line, so recovery can find every open decision.
test_omitted_decisions_stay_named() {
  local dir state out i shown omitted n=120
  dir=$(make_case global-cap)
  state="$dir/state"
  out="$dir/drain.out"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    {
      printf 'needs-decision [key=k%s]: decide item %s' "$i" "$i"
      awk 'BEGIN { while (j++ < 30) printf " padding" }'
      printf '\n'
    } > "$state/task-cap-$i.status"
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with many open decisions"

  shown=$(grep -c '^task-cap-[0-9]* \[key=k[0-9]*\] needs-decision:' "$out")
  omitted=$(grep -F 'OPEN DECISIONS: ' "$out" | grep -F 'more omitted (byte cap): ')
  [ -n "$omitted" ] || fail "$n long decisions fit the global budget, so the cap was never exercised: $(cat "$out")"
  [ "$shown" -lt "$n" ] || fail "every decision printed in full despite the global budget"
  [ "$(printf '%s\n' "$omitted" | grep -o 'task-cap-[0-9]* \[key=k[0-9]*\]' | wc -l | tr -d ' ')" -eq $((n - shown)) ] \
    || fail "the omitted line did not name every omitted decision by task and key: $omitted"
  # Enough omitted names to pass any line cap, so a cut tail would be caught.
  [ "${#omitted}" -gt 2000 ] || fail "too few omitted names to prove the line is never cut: ${#omitted} chars"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    grep -F "task-cap-$i [key=k$i]" "$out" >/dev/null || fail "open decision task-cap-$i [key=k$i] is not findable in the drain output"
  done
  grep -F "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'" "$out" >/dev/null \
    || fail "the capped section lost the answerer-closes hint"
  pass "decisions past the global budget are still named by task and key on the omitted line"
}

# --- OPEN DECISIONS: incremental cursor ------------------------------------

# Append <count> harmless filler lines (routine working: notes, never a
# needs-decision/blocked/resolved verb) to <file> and print the exact number of
# bytes appended, so a test can assert the read-probe's byte count against a
# known ground truth rather than an approximation.
append_filler() {  # <file> <count>
  local file=$1 count=$2 i=0 before after
  before=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$before" ] || before=0
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler padding line %04d of growing status log\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  printf '%s\n' "$((after - before))"
}

# The byte count the read-probe recorded for <file> on its MOST RECENT
# incremental fold call (last matching line in the probe log).
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

test_buried_decision_survives_many_growing_drains_and_resolution_clears_it() {
  local dir state out probe status bootstrap_bytes total_size round increment_bytes probe_bytes
  dir=$(make_case cursor-lifecycle)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"

  # Open a keyed decision, buried under an initial filler round big enough to
  # make a full-file rescan cost visibly more than a small incremental one.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$status"
  append_filler "$status" 400 >/dev/null

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "first drain over a large buried decision failed"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the buried decision did not surface on the bootstrap drain"
  bootstrap_bytes=$(last_probe_bytes "$probe" "$status")
  [ -n "$bootstrap_bytes" ] && [ "$bootstrap_bytes" -gt 0 ] \
    || fail "the bootstrap drain recorded no incremental read at all"

  # Many further drains, each appending only a SMALL increment while the total
  # log keeps growing large. The buried decision must resurface on EVERY one of
  # them (never dropped just because it is old or buried under more appends),
  # and each drain's read-probe byte count must match ONLY that round's small
  # increment - never the ever-growing total file size - proving the read cost
  # is bounded by new appends, not by total log size.
  for round in 1 2 3 4 5; do
    increment_bytes=$(append_filler "$status" 20)
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "drain $round over a growing log failed"
    grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
      || fail "the buried decision was dropped on growth round $round"
    probe_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$probe_bytes" = "$increment_bytes" ] \
      || fail "round $round read $probe_bytes bytes, expected exactly this round's $increment_bytes-byte increment (cost is not bounded)"
  done
  total_size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  [ "$total_size" -gt "$bootstrap_bytes" ] \
    || fail "test setup error: the log never grew past its bootstrap size"

  # Now resolve it. The very next drain's own read (a small increment) must
  # clear it - not by rescanning the whole now-large file, but by folding the
  # small resolved line into the still-persisted open set.
  increment_bytes=$(printf 'resolved [key=api-shape]: went with REST\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "resolution drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the resolved decision still printed as open right after resolution: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte resolved line (cost is not bounded)"

  # Grow the log again after resolution: the decision must stay cleared (a
  # closed decision is not resurrected by unrelated later growth), and the read
  # cost for this final round must still be bounded to that round's increment.
  increment_bytes=$(append_filler "$status" 20)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-resolution growth drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a resolved decision reappeared after later unrelated growth: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the post-resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte increment (cost is not bounded)"

  pass "a buried decision survives many growing drains with bounded read cost, and resolution durably clears it at bounded cost too"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision() {
  local dir state out probe status rewritten_bytes probe_bytes
  dir=$(make_case cursor-truncation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task2.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before truncation failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before truncation"

  # Simulate a rewritten/truncated log (shrunk below the persisted cursor
  # offset): the decision is re-opened by a fresh needs-decision line in the
  # rewritten content, and the incremental scan must fall back to a full
  # re-fold of the new, smaller file rather than trusting a now-invalid cursor.
  printf 'needs-decision [key=migration]: rewritten after truncation\n' > "$status"
  rewritten_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-truncation drain failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' | grep -F 'rewritten after truncation' >/dev/null \
    || fail "the rewritten decision after truncation did not surface"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$rewritten_bytes" ] \
    || fail "post-truncation drain read $probe_bytes bytes, expected a full re-fold of the $rewritten_bytes-byte rewritten file"

  pass "a truncated/rewritten log falls back to a full re-fold instead of dropping or misreading the decision"
}

test_same_size_rewrite_is_detected_via_inode_identity() {
  local dir state out probe status new_bytes probe_bytes
  dir=$(make_case cursor-rotation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task3.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before rotation failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before rotation"

  # Replace the file at the same path with a DIFFERENT file of the SAME byte
  # size (mv gives the destination path a new inode) - a same-size rewrite,
  # which a plain offset>size shrink check alone would NOT catch. The buried
  # decision must still surface: the device+inode identity check must detect
  # this as a rotation/recreation and fall back to a full re-fold.
  new_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'needs-decision [key=migration]: rewritten via rotation\n' > "$dir/replacement"
  padded=$(LC_ALL=C wc -c < "$dir/replacement" | tr -d '[:space:]')
  pad=$((new_bytes - padded))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' 'x' >> "$dir/replacement"
  mv "$dir/replacement" "$status"
  [ "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')" = "$new_bytes" ] \
    || fail "test setup error: the rotated replacement is not the same size as the original"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-rotation drain failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' | grep -F 'rewritten via rotation' >/dev/null \
    || fail "the same-size rotated file's decision did not surface (inode-identity check did not fire)"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$new_bytes" ] \
    || fail "post-rotation drain read $probe_bytes bytes, expected a full re-fold of the $new_bytes-byte replacement"

  pass "a same-size file rotation (new inode) is detected and falls back to a full re-fold"
}

test_read_failure_preserves_state_for_retry() {
  local dir state reader statusfile cursor out before_cursor after_cursor
  dir=$(make_case cursor-read-failure)
  state="$dir/state"
  reader="$dir/fail-reader"
  statusfile="$state/task4.status"
  cursor="$state/.task4.open-decisions-cursor"
  out="$dir/drain.out"

  printf 'needs-decision [key=x]: something important\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected read failure failed"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the decision did not surface on the bootstrap drain"
  [ -s "$cursor" ] || fail "no cursor was persisted after the bootstrap drain"
  before_cursor=$(LC_ALL=C cksum "$cursor")

  printf 'working: more routine content\n' >> "$statusfile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of preserving state after the injected read failure"
  [ ! -s "$out" ] \
    || fail "the failed presentation read emitted a partial status presentation: $(command cat "$out")"
  after_cursor=$(LC_ALL=C cksum "$cursor")
  [ "$after_cursor" = "$before_cursor" ] \
    || fail "the failed read advanced or rewrote the persisted cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected read failure"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the open decision disappeared when presentation reads recovered: $(command cat "$out")"

  pass "a failed presentation read preserves status state for retry"
}

test_cursor_cache_read_failure_refolds_without_replaying_unread_status() {
  local dir state fakebin statusfile cursor out probe real_cat status_bytes probe_bytes
  dir=$(make_case cursor-cache-read-failure)
  state="$dir/state"
  fakebin="$dir/failbin"
  mkdir -p "$fakebin"
  statusfile="$state/task5.status"
  cursor="$state/.task5.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  real_cat=$(command -v cat)

  {
    printf 'needs-decision [key=cache]: recover from authoritative status\n'
    printf 'note: already handled informational status\n'
  } > "$statusfile"
  append_filler "$statusfile" 40 >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the cursor-cache read failure failed"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the decision did not surface before the cursor-cache read failure"
  grep -F 'task5 note: already handled informational status' "$out" >/dev/null \
    || fail "the bootstrap drain did not surface the informational status"
  [ -s "$cursor" ] || fail "no cursor was persisted before the cursor-cache read failure"

  printf 'working: appended before cache failure\n' >> "$statusfile"
  status_bytes=$(LC_ALL=C wc -c < "$statusfile" | tr -d '[:space:]')
  : > "$probe"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "$cursor" ]; then
  exit 1
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" PATH="$fakebin:$PATH" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of refolding after the cursor-cache read failure"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the cursor-cache read failure hid the recurring open decision: $(command cat "$out")"
  if grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || grep -F 'already handled informational status' "$out" >/dev/null; then
    fail "the cursor-cache read failure replayed handled informational status as new: $(command cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$statusfile")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the cursor-cache read failure read $probe_bytes bytes, expected a full $status_bytes-byte authoritative refold"

  pass "a cursor-cache read failure refolds decisions without replaying handled unread status"
}

test_pre_fix_cursor_refolds_corr_tagged_decision() {
  local dir state status cursor out probe status_bytes ident probe_bytes
  dir=$(make_case cursor-corr-tag-migration)
  state="$dir/state"
  status="$state/task7.status"
  cursor="$state/.task7.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the corr-tag cursor migration failed"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  [ -n "$ident" ] || fail "bootstrap drain did not persist a file identity"
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'version=3\n'
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while migrating the pre-fix corr-tag cursor"
  grep -F 'task7 [key=loan-installment-cadence-amount] needs-decision: pick the cadence' "$out" >/dev/null \
    || fail "the pre-fix cursor hid the corr-tagged decision after migration: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the pre-fix cursor read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  pass "a pre-fix cursor is rebuilt so a previously skipped corr-tagged decision surfaces"
}

test_previous_fold_cache_is_refolded_under_current_semantics() {
  local dir state status cursor out probe status_bytes ident appended_bytes probe_bytes
  dir=$(make_case cursor-fold-version)
  state="$dir/state"
  status="$state/task6.status"
  cursor="$state/.task6.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'blocked [key=pending-reply-abcdef0123456789]: forged decision\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the fold-version migration failed"
  [ ! -s "$out" ] || fail "the current whole-file semantics accepted the foreign reserved-key decision: $(cat "$out")"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
    printf 'pending-reply-abcdef0123456789\tblocked\tforged decision'
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while upgrading the previous fold cache"
  [ ! -s "$out" ] || fail "the previous fold cache kept surfacing a foreign reserved-key decision: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the previous fold cache read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  appended_bytes=$(printf 'needs-decision [key=current]: choose the current path\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "same-version incremental drain failed after cache migration"
  grep -F 'task6 [key=current] needs-decision: choose the current path' "$out" >/dev/null \
    || fail "the same-version append did not fold into the migrated open set"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$appended_bytes" ] \
    || fail "the same-version fold read $probe_bytes bytes instead of only the $appended_bytes-byte append"

  pass "an old fold cache is rebuilt once before same-version incremental reads resume"
}

test_terminal_supersession_reaches_cached_drains() {
  local dir state status cursor out kind terminal expected closing ident size span pass_number
  for kind in scout ship secondmate; do
    for terminal in 'done' failed; do
      dir=$(make_case "terminal-$kind-$terminal")
      state="$dir/state"; status="$state/task.status"; cursor="$state/.task.open-decisions-cursor"; out="$dir/drain.out"
      printf 'kind=%s\n' "$kind" > "$state/task.meta"
      printf 'blocked [key=access]: waiting\n' > "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "initial blocked drain failed"
      assert_contains "$(cat "$out")" 'task [key=access] blocked: waiting' "initial blocker must surface"
      printf '%s: report saved\nnote: cleanup complete\n' "$terminal" >> "$status"
      expected=''; closing=$terminal
      if [ "$kind" = secondmate ]; then expected=$'access\tblocked\twaiting'; closing=blocked; fi
      for pass_number in 1 2; do
        if [ "$pass_number" = 2 ]; then
          ident=$(sed -n 's/^ident=//p' "$cursor")
          size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
          printf 'version=5\noffset=%s\nident=%s\naccess\tblocked\twaiting' "$size" "$ident" > "$cursor"
        fi
        FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "$kind terminal drain failed"
        if [ "$kind" = secondmate ]; then
          assert_contains "$(cat "$out")" 'task [key=access] blocked: waiting' "secondmate blocker must survive $terminal and cache migration"
        else
          assert_not_contains "$(cat "$out")" 'OPEN DECISIONS' "$kind pre-terminal blocker resurfaced after $terminal or cache migration"
        fi
        bash -c '. "$1"; [ "$(status_open_decisions "$2")" = "$3" ] && [ "$(status_open_decisions_incremental "$2")" = "$3" ] && [ "$(status_key_closing_verb "$2" access)" = "$4" ]' \
          _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$expected" "$closing" \
          || fail "$kind whole-file, incremental, and key-history reads disagree with terminal supersession"
      done
      span=$(bash -c '. "$1"; status_span_first_actionable "$2" 0' _ "$ROOT/bin/fm-classify-lib.sh" "$status")
      if [ "$kind" = secondmate ]; then
        assert_contains "$span" 'blocked [key=access]: waiting' "secondmate opening must remain actionable"
      else
        assert_not_contains "$span" 'waiting' "$kind superseded opening remained actionable in a captured span"
      fi
      printf 'blocked [key=access]: reopened\nneeds-decision [key=new]: a new decision\nnote: more cleanup\n' >> "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "reopened drain failed"
      assert_contains "$(cat "$out")" 'task [key=access] blocked: reopened' "post-terminal reopening must surface"
      assert_contains "$(cat "$out")" 'task [key=new] needs-decision: a new decision' "post-terminal new key must surface"
      printf 'resolved [key=access]: answered\nresolved [key=new]: answered\nnote: final cleanup\n' >> "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "resolved drain failed"
      assert_not_contains "$(cat "$out")" 'OPEN DECISIONS' "matching resolutions must close reopened decisions"
    done
  done
  pass "terminal supersession reaches whole-file reads, incremental drains, old caches, and captured spans"
}

test_kind_changes_invalidate_folded_decisions() {
  local dir state status kind expected
  dir=$(make_case cursor-kind-change); state="$dir/state"; status="$state/task.status"
  printf 'blocked [key=access]: waiting\ndone: report saved\nnote: cleanup complete\n' > "$status"
  for kind in unknown ship secondmate scout; do
    [ "$kind" = unknown ] || printf 'kind=%s\n' "$kind" >> "$state/task.meta"
    case "$kind" in unknown|secondmate) expected=$'access\tblocked\twaiting' ;; *) expected='' ;; esac
    bash -c '. "$1"; [ "$(status_open_decisions_incremental "$2")" = "$3" ] && [ "$(status_open_decisions "$2")" = "$3" ]' \
      _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$expected" \
      || fail "cached decisions did not follow the current $kind metadata without a status append"
  done
  pass "folded decisions are rebuilt when task-kind evidence changes"
}

# --- STATUS OUTCOME BACKSTOP -----------------------------------------------

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

append_outcome() {  # <state> <task> <summary>
  FM_STATE_OVERRIDE="$1" "$OUTCOMES" append \
    --task "$2" --verdict captain --summary "$3" >/dev/null
}

backstop_body() {  # <drain-output>
  awk '
    /^STATUS OUTCOME BACKSTOP \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

test_uncovered_keyless_captain_events_surface_on_the_next_main_drain() {
  local dir state out body old
  dir=$(make_case uncovered-keyless)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: PR https://example.test/3346 checks green\n' > "$state/done-task.status"
  printf 'blocked: release credential unavailable\n' > "$state/blocked-task.status"
  printf 'needs-decision: choose REST or RPC\n' > "$state/decision-task.status"
  set_mtime "$old" "$state/done-task.status"
  set_mtime "$old" "$state/blocked-task.status"
  set_mtime "$old" "$state/decision-task.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for uncovered keyless captain events"
  grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null \
    || fail "uncovered keyless events produced no outcome backstop: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'done-task done: PR https://example.test/3346 checks green'*) ;; *) fail "keyless done event did not surface in the backstop: $body" ;; esac
  grep -F 'blocked-task blocked: release credential unavailable' "$out" >/dev/null \
    || fail "keyless blocked event did not surface through OPEN DECISIONS: $(cat "$out")"
  grep -F 'decision-task needs-decision: choose REST or RPC' "$out" >/dev/null \
    || fail "keyless needs-decision event did not surface through OPEN DECISIONS: $(cat "$out")"
  pass "a newest keyless done, blocked, or needs-decision event with no newer branch outcome surfaces on the next main drain"
}

test_newer_task_outcome_and_routine_latest_events_stay_silent() {
  local dir state out old
  dir=$(make_case covered-and-routine)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: already delivered completion\n' > "$state/covered.status"
  set_mtime "$old" "$state/covered.status"
  append_outcome "$state" covered 'covered completion reached main'
  printf 'working: rebased onto merged #76\n' > "$state/working.status"
  printf 'paused: waiting for the scheduled release window\n' > "$state/paused.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for covered and routine latest events"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null; then
    fail "a newer branch outcome or routine latest event was re-presented: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "covered and routine latest events broke the silent drain contract: $(cat "$out")"
  pass "a newer task-matching branch outcome suppresses the backstop and routine latest events stay silent"
}

test_older_or_other_task_outcome_cannot_hide_a_new_captain_event() {
  local dir state out body future
  dir=$(make_case stale-outcomes)
  state="$dir/state"
  out="$dir/drain.out"

  append_outcome "$state" same-task 'older completion'
  append_outcome "$state" unrelated-task 'newer but unrelated completion'
  future=$(( $(date +%s) + 20 ))
  printf 'failed: a later attempt failed\n' > "$state/same-task.status"
  printf 'PR ready for review\n' > "$state/no-task-outcome.status"
  set_mtime "$future" "$state/same-task.status"
  set_mtime "$future" "$state/no-task-outcome.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for stale branch outcomes"
  body=$(backstop_body "$out")
  case "$body" in *'same-task failed: a later attempt failed'*) ;; *) fail "an older same-task outcome hid a later failure: $body" ;; esac
  case "$body" in *'no-task-outcome PR ready for review'*) ;; *) fail "another task's newer outcome hid a captain-facing event: $body" ;; esac
  pass "only a strictly newer outcome for the same task can suppress its latest captain event"
}

test_branch_annotation_cannot_consume_the_main_resurfacing_backstop() {
  local dir state branch_out branch_err main_out sequence generation old
  dir=$(make_case branch-then-main)
  state="$dir/state"
  branch_out="$dir/branch.out"
  branch_err="$dir/branch.err"
  main_out="$dir/main.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: branch intake never produced an outcome\n' > "$state/lost-task.status"
  set_mtime "$old" "$state/lost-task.status"
  append_wake "$state" signal lost-task.status 'signal: lost-task.status' \
    || fail "could not queue the branch-owned status signal"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" mode5-backstop \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish mode5-backstop 1 \
    || fail "branch grant publication failed"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$branch_out" 2> "$branch_err" \
    || fail "branch drain failed: $(cat "$branch_err")"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$branch_out" >/dev/null; then
    fail "the branch actor presented the main-only outcome backstop"
  fi
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$branch_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$branch_err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "branch acknowledgement did not consume its queue row"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$main_out" \
    || fail "main drain failed after the branch lost its wake"
  grep -F 'lost-task done: branch intake never produced an outcome' "$main_out" >/dev/null \
    || fail "the next main drain did not recover the branch-acknowledged keyless done event: $(cat "$main_out")"
  pass "a branch annotation and queue acknowledgement cannot consume the main drain's loss backstop"
}

test_same_second_outcome_uses_status_causal_position() {
  local dir state first_out second_out epoch
  dir=$(make_case same-second-causal-order)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"
  epoch=$(date +%s)

  printf 'done: first completion\n' > "$state/same-second.status"
  set_mtime "$epoch" "$state/same-second.status"
  append_outcome "$state" same-second 'first completion handled'
  set_mtime "$epoch" "$state/same-second.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "main drain failed for same-second covered status"
  [ ! -s "$first_out" ] \
    || fail "a same-second handled status was re-presented: $(cat "$first_out")"

  printf 'failed: genuinely later same-second event\n' >> "$state/same-second.status"
  set_mtime "$epoch" "$state/same-second.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "main drain failed for later same-second status"
  grep -F 'same-second failed: genuinely later same-second event' "$second_out" >/dev/null \
    || fail "a later same-second status was hidden by the older outcome: $(cat "$second_out")"
  pass "status byte position distinguishes handled and later same-second events"
}

test_drain_does_not_scan_append_only_outcome_history() {
  local dir state out i
  dir=$(make_case bounded-history)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: covered before large history\n' > "$state/bounded-task.status"
  append_outcome "$state" bounded-task 'covered before large history'
  i=1
  while [ "$i" -le 20000 ]; do
    printf 'historical payload that the bounded drain must not parse %06d\n' "$i"
    i=$((i + 1))
  done >> "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed with large append-only outcome history"
  [ ! -s "$out" ] \
    || fail "drain consulted malformed lifetime history instead of the bounded task index: $(cat "$out")"
  pass "drain cost and suppression are independent of append-only outcome history"
}

test_successful_backstop_is_idempotent_without_consuming_delayed_annotation() {
  local dir state first_out second_out signal_out
  dir=$(make_case idempotent-receipt)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"
  signal_out="$dir/signal.out"

  printf 'done: keyless completion awaiting recovery\n' > "$state/receipt-task.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "first keyless backstop drain failed"
  grep -F 'receipt-task done: keyless completion awaiting recovery' "$first_out" >/dev/null \
    || fail "first drain did not surface the keyless completion: $(cat "$first_out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "second keyless backstop drain failed"
  [ ! -s "$second_out" ] \
    || fail "a successful backstop presentation repeated unchanged: $(cat "$second_out")"

  append_wake "$state" signal receipt-task.status 'signal: receipt-task.status' \
    || fail "could not publish the delayed signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$signal_out" 2>/dev/null \
    || fail "delayed-signal drain failed"
  grep -F 'latest wake-EVENT observed at drain, not current state: receipt-task.status: done: keyless completion awaiting recovery' "$signal_out" >/dev/null \
    || fail "the backstop receipt consumed the delayed signal annotation: $(cat "$signal_out")"
  pass "backstop receipts prevent repeats without consuming delayed signal annotations"
}

test_output_failure_does_not_commit_the_backstop_receipt() {
  local dir state fakebin out retry_out real_cat
  dir=$(make_case output-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/failed.out"
  retry_out="$dir/retry.out"
  real_cat=$(command -v cat)
  mkdir -p "$fakebin"

  printf 'done: retry after the output consumer fails\n' > "$state/output-task.status"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  "$state"/.status-presentation.prepared.*) exit 1 ;;
esac
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the top-level empty-queue drain changed its compatibility exit on an output failure"
  [ ! -s "$out" ] || fail "the failed output consumer received unexpected bytes: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$retry_out" \
    || fail "backstop retry failed after the output consumer recovered"
  grep -F 'output-task done: retry after the output consumer fails' "$retry_out" >/dev/null \
    || fail "the output failure consumed the backstop receipt: $(cat "$retry_out")"
  pass "a failed output consumer leaves the backstop unacknowledged for retry"
}

test_receipt_commit_failure_repeats_the_already_presented_backstop() {
  local dir state fakebin out retry_out final_out real_mv
  dir=$(make_case receipt-commit-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/failed.out"
  retry_out="$dir/retry.out"
  final_out="$dir/final.out"
  real_mv=$(command -v mv)
  mkdir -p "$fakebin"

  printf 'done: presentation precedes its durable receipt\n' > "$state/atomic-task.status"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do last=\$arg; done
if [ "\${last:-}" = "$state/.status-presentation-cursor" ]; then exit 1; fi
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the top-level empty-queue drain changed its compatibility exit on a receipt failure"
  grep -F 'atomic-task done: presentation precedes its durable receipt' "$out" >/dev/null \
    || fail "receipt failure prevented the prepared backstop presentation: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$retry_out" \
    || fail "backstop retry failed after receipt storage recovered"
  grep -F 'atomic-task done: presentation precedes its durable receipt' "$retry_out" >/dev/null \
    || fail "the uncommitted backstop did not retry after storage recovered: $(cat "$retry_out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$final_out" \
    || fail "post-recovery idempotence drain failed"
  [ ! -s "$final_out" ] \
    || fail "the successfully committed retry repeated: $(cat "$final_out")"
  pass "receipt failure may repeat a presented backstop but cannot lose it"
}

test_rejected_decision_line_surfaces_once_through_backstop() {
  local dir state first_out second_out
  dir=$(make_case rejected-decision)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"

  printf 'blocked [key=bad/value]: credential missing\n' > "$state/rejected.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "rejected-decision drain failed"
  grep -F 'rejected blocked [key=bad/value]: credential missing' "$first_out" >/dev/null \
    || fail "captain-facing rejected decision was lost: $(cat "$first_out")"
  if grep -F 'OPEN DECISIONS' "$first_out" >/dev/null; then
    fail "malformed decision key entered the open-decision fold: $(cat "$first_out")"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "second rejected-decision drain failed"
  [ ! -s "$second_out" ] \
    || fail "rejected decision backstop repeated unchanged: $(cat "$second_out")"
  pass "captain-facing decisions rejected by the fold surface once"
}

test_missing_index_self_heals_on_first_drain() {
  local dir state out old
  dir=$(make_case index-selfheal-covered)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: handled before cache interruption\n' > "$state/recovered.status"
  old=$(( $(date +%s) - 20 ))
  set_mtime "$old" "$state/recovered.status"
  printf '%s\n' '{"seq":1,"epoch":'"$((old + 10))"',"task":"recovered","wake":"","verdict":"captain","summary":"legacy handled outcome"}' \
    > "$state/branch-outcomes.jsonl"
  printf '1\n' > "$state/.branch-outcomes-cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first drain failed while self-healing a missing outcome index"
  [ ! -s "$out" ] \
    || fail "self-healed index re-presented a handled outcome: $(cat "$out")"
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "first drain did not publish the outcome-index ready marker"
  if grep -F 'Pi supervision' "$out" >/dev/null; then
    fail "self-heal drain still mentioned Pi supervision: $(cat "$out")"
  fi
  pass "a missing outcome index self-heals on the first drain and suppresses its handled status"
}

test_uncovered_event_surfaces_on_first_drain_without_index() {
  local dir state out body
  dir=$(make_case index-selfheal-uncovered)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: uncovered completion with no index\n' > "$state/fresh.status"
  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first drain failed for an uncovered status with no outcome index"
  grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null \
    || fail "first drain skipped the backstop instead of self-healing: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'fresh done: uncovered completion with no index'*) ;; *)
    fail "uncovered status did not surface after index self-heal: $body"
    ;;
  esac
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "first drain did not publish the outcome-index ready marker"
  if grep -F 'Pi supervision' "$out" >/dev/null; then
    fail "uncovered self-heal drain mentioned Pi supervision: $(cat "$out")"
  fi
  pass "a fresh home with a status log and no index surfaces the backstop on its first drain"
}

test_malformed_outcome_store_fails_closed_without_pi_advice() {
  local dir state out
  dir=$(make_case index-selfheal-store-fault)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: must not surface over a corrupt outcome store\n' > "$state/unsafe.status"
  printf 'not-json\n' > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed closed incorrectly on a malformed outcome store"
  grep -F 'STATUS OUTCOME BACKSTOP SKIPPED:' "$out" >/dev/null \
    || fail "malformed store did not fail closed: $(cat "$out")"
  grep -F 'outcome store is unsafe' "$out" >/dev/null \
    || fail "store-fault skip lost its repair wording: $(cat "$out")"
  if grep -F 'Pi supervision' "$out" >/dev/null; then
    fail "store-fault skip still advised restarting Pi supervision: $(cat "$out")"
  fi
  grep -F 'unsafe done:' "$out" >/dev/null \
    && fail "malformed store still presented a backstop event: $(cat "$out")"
  [ ! -f "$state/.branch-outcome-index-ready" ] \
    || fail "a store fault published a ready marker"
  pass "a genuine outcome-store fault fails closed without Pi-specific restart advice"
}

test_held_lock_mode_rejects_an_unlocked_caller() {
  local dir state out
  dir=$(make_case index-selfheal-held-lock-guard)
  state="$dir/state"
  out="$dir/processed-init.out"

  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  if FM_STATE_OVERRIDE="$state" "$OUTCOMES" processed-init --held-lock > "$out" 2>&1; then
    fail "processed-init accepted --held-lock without parent lock ownership"
  fi
  [ ! -e "$state/.branch-outcomes-processed" ] \
    || fail "unowned held-lock mode mutated the processed marker"
  [ ! -e "$state/.branch-outcome-index-ready" ] \
    || fail "unowned held-lock mode published the outcome index"
  pass "held-lock initialization rejects callers outside the lock owner's process tree"
}

test_held_lock_mode_accepts_a_lock_owner_descendant() {
  local dir state
  dir=$(make_case index-selfheal-held-lock-descendant)
  state="$dir/state"

  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_lock_acquire_wait "$STATE/.branch-outcomes.lock" || exit 1
    trap "fm_lock_release \"$STATE/.branch-outcomes.lock\"" EXIT
    sh -c '"'"'$1 processed-init --held-lock'"'"' _ "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$OUTCOMES" \
    || fail "processed-init rejected a descendant of the outcome lock owner"
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "descendant held-lock initialization did not publish the outcome index"
  pass "held-lock initialization accepts a descendant of the outcome lock owner"
}

test_index_self_heal_runs_under_the_outcome_lock() {
  local dir state busy_out healed_out holder i
  dir=$(make_case index-selfheal-lock)
  state="$dir/state"
  busy_out="$dir/busy.out"
  healed_out="$dir/healed.out"

  printf 'done: uncovered while the outcome lock is contested\n' > "$state/locked.status"
  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_lock_try_acquire "$STATE/.branch-outcomes.lock" || exit 1
    trap "fm_lock_release \"$STATE/.branch-outcomes.lock\"" EXIT
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ -e "$state/.branch-outcomes.lock" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.branch-outcomes.lock" ] \
    || { kill "$holder" 2>/dev/null || true; fail "test lock holder did not publish the outcome lock"; }

  FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$busy_out" \
    || fail "drain failed while the outcome lock was held"
  grep -F 'branch outcome history is busy' "$busy_out" >/dev/null \
    || fail "contested lock did not skip the backstop: $(cat "$busy_out")"
  [ ! -f "$state/.branch-outcome-index-ready" ] \
    || fail "self-heal published a ready marker without holding the outcome lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$healed_out" \
    || fail "drain failed after the outcome lock was released"
  grep -F 'locked done: uncovered while the outcome lock is contested' "$healed_out" >/dev/null \
    || fail "self-heal under the lock did not surface the uncovered event: $(cat "$healed_out")"
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "self-heal under the lock did not publish the ready marker"
  pass "index self-heal runs only while the outcome lock is held"
}

test_overbound_routine_event_stays_silent() {
  local dir state out
  dir=$(make_case overbound-routine-event)
  state="$dir/state"
  out="$dir/drain.out"

  perl -e 'print "working: ", "x" x 70000, "\n"' > "$state/oversized.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for an over-bound routine event"
  [ ! -s "$out" ] \
    || fail "unclassifiable over-bound routine event was presented: $(cat "$out")"
  pass "an over-bound unclassifiable routine event stays silent"
}

test_backstop_output_is_bounded() {
  local dir state out old i payload count longest
  dir=$(make_case bounded-output)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))
  payload=$(printf '%0300d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'done: completion-%02d %s\n' "$i" "$payload" > "$state/task-$i.status"
    set_mtime "$old" "$state/task-$i.status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for bounded output"
  grep -F 'STATUS OUTCOME BACKSTOP:' "$out" | grep -F 'more omitted (byte cap)' >/dev/null \
    || fail "an over-budget backstop did not report bounded omission: $(cat "$out")"
  count=$(backstop_body "$out" | grep -c '^task-' || true)
  [ "$count" -gt 0 ] && [ "$count" -lt 30 ] \
    || fail "backstop byte cap presented an unexpected task count: $count"
  longest=$(backstop_body "$out" | awk '{ if (length > max) max=length } END { print max + 0 }')
  [ "$longest" -le 219 ] || fail "a backstop item exceeded its 219-character budget: $longest"
  pass "the outcome backstop caps each item and its total task output deterministically"
}

# --- UNREAD STATUS --------------------------------------------------------

# Establish the durable last-presentation cursor by draining once over a
# bootstrap line so later appends are "new since last drain".
prime_cursor() {  # <state> <status-file>
  local state=$1 status=$2
  printf 'note: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the unread cursor"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both() {
  local dir state out status
  dir=$(make_case incident-buried-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task1.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the incident shape"

  grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || fail "the incident shape produced no UNREAD STATUS section: $(cat "$out")"
  grep -F 'task1 note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the buried answer note was not surfaced: $(cat "$out")"
  grep -F 'task1 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the newest routine note was dropped while surfacing the answer: $(cat "$out")"
  pass "a note: answer buried under a later routine note: is surfaced with both lines"
}

test_already_presented_notes_are_not_replayed() {
  local dir state out status
  dir=$(make_case no-replay)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task2.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain of unread notes failed"
  grep -F 'captain said use REST not RPC' "$out" >/dev/null \
    || fail "setup error: first drain did not surface the answer note"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after presentation failed"
  if grep -F 'captain said use REST not RPC' "$out" >/dev/null; then
    fail "an already-presented answer note was replayed as new: $(cat "$out")"
  fi
  if grep -F 're-read acknowledgement' "$out" >/dev/null; then
    fail "an already-presented routine note was replayed as new: $(cat "$out")"
  fi
  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "the second drain reprinted an UNREAD STATUS section with no new lines: $(cat "$out")"
  fi
  pass "already-presented note: lines are not re-surfaced on the next drain"
}

test_brand_new_note_after_presentation_is_surfaced() {
  local dir state out status
  dir=$(make_case brand-new-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task3.status"
  prime_cursor "$state" "$status"

  printf 'note: first answer\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the first note failed"
  grep -F 'task3 note: first answer' "$out" >/dev/null \
    || fail "setup error: first note was not presented"

  printf 'note: follow-up after ack\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the brand-new note failed"
  grep -F 'task3 note: follow-up after ack' "$out" >/dev/null \
    || fail "a brand-new note after presentation was not surfaced: $(cat "$out")"
  if grep -F 'task3 note: first answer' "$out" >/dev/null; then
    fail "the already-presented first note was replayed next to the new one: $(cat "$out")"
  fi
  pass "a brand-new note: after presentation is surfaced without replaying handled lines"
}

test_signal_annotation_surfaces_every_unread_note_not_only_the_newest() {
  local dir state out err status
  dir=$(make_case signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  status="$state/task4.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  append_wake "$state" signal task4.status "signal: task4.status" \
    || fail "queueing the incident-shape status signal failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "signal drain failed on the incident shape"

  grep -F 'unread wake-EVENT since last drain, not current state: task4.status: note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the signal annotation dropped the buried answer note: $(cat "$out")"
  grep -F 'latest wake-EVENT observed at drain, not current state: task4.status: note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the signal annotation dropped the newest routine note: $(cat "$out")"
  grep "$(printf '\tsignal\ttask4.status\t')" "$out" >/dev/null \
    || fail "surfacing unread notes hid the authoritative raw wake row"
  pass "a queued status signal annotates every unread note, not only the newest"
}

test_pending_reply_resolution_surfaces_once() {
  local dir state out status
  dir=$(make_case pending-reply-resolution)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task5.status"
  prime_cursor "$state" "$status"

  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=task5 pending-reply-id=abcdef0123456789 request=ship it\n' >> "$status"
  append_wake "$state" signal task5.status "signal: task5.status" \
    || fail "queueing the pending-reply request signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging the pending-reply request"
  {
    printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status\n'
    printf 'note: re-read acknowledgement\n'
  } >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a pending-reply resolution"

  grep -F 'pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status' "$out" >/dev/null \
    || fail "the pending-reply resolution was buried under the later note: $(cat "$out")"
  grep -F 'task5 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the trailing note was not surfaced with the pending-reply resolution: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the pending-reply resolution did not close its open decision: $(cat "$out")"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after pending-reply presentation failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented pending-reply resolution was replayed: $(cat "$out")"
  fi
  pass "a pending-reply resolution buried under a later note surfaces once and closes OPEN DECISIONS"
}

# The watcher's pending-reply close goes through the self-announced append, so
# it records its bytes as this home's own and never wakes. The drain must still
# present that reserved-key resolution in UNREAD STATUS, its only guaranteed
# presentation.
test_self_announced_pending_reply_close_still_surfaces() {
  local dir state out status corr
  dir=$(make_case self-announced-pending-reply)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task6.status"

  run_pending_reply() {
    FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_NOW=5000 bash -c '
      . "$1"; . "$2"; shift 2; "$@"
    ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  corr=$(run_pending_reply fm_pending_reply_create "$dir" "$state" task6 "ship it") \
    || fail "could not create the pending-reply record"
  run_pending_reply fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "could not mark the pending-reply request delivered"
  FM_STATE_OVERRIDE="$state" FM_PENDING_REPLY_NOW=5000 bash -c '
    . "$1"; rec=$(fm_pending_reply_path "$2" "$3")
    fm_pending_reply_set "$rec" phase escalated && fm_pending_reply_set "$rec" escalated_epoch 4950
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$state" "$corr" \
    || fail "could not mark the pending-reply request escalated"

  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=task6 pending-reply-id=%s request=ship it\n' \
    "$corr" "$corr" > "$status"
  prime_status_seen "$state" "$status" || fail "could not mark the status file surfaced"
  append_wake "$state" signal task6.status "signal: task6.status" \
    || fail "queueing the pending-reply escalation signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain of the escalation failed"
  printf 'done [corr=%s]: shipped after all\n' "$corr" >> "$status"
  prime_status_seen "$state" "$status" || fail "could not mark the status file surfaced"
  append_wake "$state" signal task6.status "signal: task6.status" \
    || fail "queueing the delayed reply signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null || fail "drain of the delayed reply failed"

  run_pending_reply fm_pending_reply_try_resolve "$state" "$corr" \
    || fail "the delayed reply did not resolve the pending-reply record"
  sed -E 's/ \[at=[0-9]+\]//' "$status" \
    | grep -F "resolved [key=pending-reply-$corr]: pending-reply-resolved:" >/dev/null \
    || fail "the resolve did not append the escalation close: $(cat "$status")"
  [ -s "$state/.task6.home-appends" ] \
    || fail "the escalation close did not go through the self-announced append"
  run_pending_reply fm_wake_signal_seen_current "$state" "$status" \
    || fail "the self-announced escalation close was left to re-wake this home"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after the escalation close failed"
  sed -E 's/ \[at=[0-9]+\]//' "$out" \
    | grep -F "task6 resolved [key=pending-reply-$corr]: pending-reply-resolved: task=task6 pending-reply-id=$corr" >/dev/null \
    || fail "the self-announced pending-reply resolution was hidden from UNREAD STATUS: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after the escalation close failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented self-announced resolution was replayed: $(cat "$out")"
  fi
  pass "a self-announced pending-reply close does not wake yet still surfaces once in UNREAD STATUS"
}

test_unread_output_over_cap_remains_recoverable() {
  local dir state out status i payload
  dir=$(make_case unread-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-cap.status"
  prime_cursor "$state" "$status"
  payload=$(printf '%0180d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'note: overflow-%02d %s\n' "$i" "$payload" >> "$status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed for unread output over the former cap"
  grep -F 'task-cap note: overflow-01' "$out" >/dev/null \
    || fail "the first over-cap note was not surfaced"
  grep -F 'task-cap note: overflow-30' "$out" >/dev/null \
    || fail "a later note vanished behind the unread byte cap: $(cat "$out")"
  if grep -F 'more omitted' "$out" >/dev/null; then
    fail "the unread section still omitted complete lines: $(cat "$out")"
  fi
  pass "unread status over the former byte cap preserves every line"
}

test_snapshot_does_not_ack_a_later_append() {
  local dir state status first second
  dir=$(make_case snapshot-append)
  state="$dir/state"
  status="$state/task-race.status"
  prime_cursor "$state" "$status"
  printf 'note: included in presentation snapshot\n' >> "$status"

  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    snapshot=$(status_presentation_snapshot "$STATE")
    scan_unread_surface_snapshot "$STATE" "$snapshot" > "$2"
    printf "note: appended after presentation snapshot\n" >> "$STATE/task-race.status"
    scan_open_decisions_snapshot "$STATE" "$snapshot" >/dev/null
    status_commit_presentation_snapshot "$STATE" "$snapshot"
    scan_unread_surface_lines "$STATE" > "$3"
  ' _ "$ROOT" "$dir/first" "$dir/second" || fail "snapshot race exercise failed"
  first=$(cat "$dir/first")
  second=$(cat "$dir/second")
  case "$first" in *'included in presentation snapshot'*) ;; *) fail "snapshot omitted the line it captured: $first" ;; esac
  case "$first" in *'appended after presentation snapshot'*) fail "snapshot read beyond its endpoint: $first" ;; esac
  case "$second" in *'appended after presentation snapshot'*) ;; *) fail "fold advancement swallowed a post-snapshot append: $second" ;; esac
  case "$second" in *'included in presentation snapshot'*) fail "the next scan replayed a presented line: $second" ;; esac
  pass "presentation cursor advances only through its captured endpoint"
}

test_retired_task_id_starts_new_status_unread() {
  local dir state out offset event old_ident
  dir=$(make_case retired-task-reuse)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: old reused-task history\n' > "$state/reused.status"
  printf 'note: stable neighboring history\n' > "$state/neighbor.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "drain failed while acknowledging pre-retirement histories"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    _fm_open_decisions_file_ident "$STATE/reused.status" > "$2"
    printf "40@$(cat "$2")" > "$(status_signal_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_heartbeat_seen_marker_path "$STATE" reused)"
    printf "40@$(cat "$2")" > "$(status_daemon_seen_marker_path "$STATE" reused)"
    ledger=$(status_home_appends_path "$STATE/reused.status")
    status_home_appends_record "$STATE/reused.status" 0 12 || exit 1
    [ -f "$ledger" ] || exit 1
    mkdir -p "$ledger.lock" || exit 1
    printf "%s\n" 2147483646 > "$ledger.lock/pid" || exit 1
    status_retire_presentation_task "$STATE" reused || exit 1
    for marker in \
      "$(status_signal_seen_marker_path "$STATE" reused)" \
      "$(status_heartbeat_seen_marker_path "$STATE" reused)" \
      "$(status_daemon_seen_marker_path "$STATE" reused)" \
      "$ledger" "$ledger.lock"; do
      [ ! -e "$marker" ] && [ ! -L "$marker" ] || exit 1
    done
  ' _ "$ROOT" "$dir/old-ident" || fail "retiring the reused task presentation state failed"
  printf 'blocked: release host unavailable\nworking: routine padding after the reused task started again\nnote: first event from reused task id\n' \
    > "$state/reused.status"
  old_ident=$(cat "$dir/old-ident")
  printf '40@%s' "$old_ident" > "$state/.seen-reused_status"
  offset=$(bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    fm_wake_signal_seen_size "$2" "$2/reused.status"
  ' _ "$ROOT" "$state")
  [ "$offset" = 0 ] || fail "a retired file identity restored a stale offset after task reuse"
  event=$(bash -c '
    . "$1/bin/fm-classify-lib.sh"
    status_span_first_actionable "$2/reused.status" "$3"
  ' _ "$ROOT" "$state" "$offset")
  [ "$event" = 'blocked: release host unavailable' ] \
    || fail "retired supervision offsets hid the replacement task blocker: $event"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after reusing a retired task id"
  grep -F 'reused note: first event from reused task id' "$out" >/dev/null \
    || fail "the retired manifest row skipped the new task prefix: $(cat "$out")"
  if grep -F 'stable neighboring history' "$out" >/dev/null; then
    fail "retiring one task replayed a neighboring task's handled history: $(cat "$out")"
  fi
  pass "a reused task id starts its replacement status log unread at byte zero"
}

test_weak_identity_still_presents_and_advances() {
  local dir state out second reader
  dir=$(make_case weak-identity); state="$dir/state"
  out="$dir/first.out"; second="$dir/second.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nprintf "weak:7:8"\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision [key=release]: choose target\nnote: release context attached\n' > "$state/weak.status"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed with the platform-strength fallback identity"
  grep -F 'weak [key=release] needs-decision: choose target' "$out" >/dev/null \
    || fail "weak identity omitted OPEN DECISIONS: $(cat "$out")"
  grep -F 'weak note: release context attached' "$out" >/dev/null \
    || fail "weak identity omitted unread status: $(cat "$out")"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" \
    || fail "second drain failed with the platform-strength fallback identity"
  grep -F 'release context attached' "$second" >/dev/null \
    && fail "weak identity did not advance the presented-status cursor"
  pass "fallback identity still presents and advances status state"
}

test_snapshot_failure_is_visible() {
  local dir state out reader
  dir=$(make_case snapshot-failure); state="$dir/state"; out="$dir/drain.out"; reader="$dir/identity-reader"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"; chmod +x "$reader"
  printf 'needs-decision: choose target\n' > "$state/fail.status"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain aborted instead of reporting its incomplete status surface"
  grep -F 'STATUS PRESENTATION INCOMPLETE:' "$out" >/dev/null \
    || fail "snapshot failure produced a silently incomplete drain: $(cat "$out")"
  pass "snapshot failures are reported visibly"
}

test_open_decisions_fold_is_unchanged() {
  local dir state out
  dir=$(make_case open-decisions-regression)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task6.status"
  printf 'working: continuing other work\n' >> "$state/task6.status"
  printf 'note: re-read acknowledgement\n' >> "$state/task6.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried needs-decision plus a note"

  grep -F 'task6 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "OPEN DECISIONS no longer surfaces a buried needs-decision: $(cat "$out")"
  grep -F 'task6 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the unread note was not surfaced alongside the still-open decision: $(cat "$out")"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "OPEN DECISIONS lost its answerer-closes hint"

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task6.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving the keyed decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "a resolved decision leaked back through the unread surface: $(cat "$out")"
  fi
  pass "OPEN DECISIONS still folds needs-decision/blocked independently of unread notes"
}

test_empty_queue_does_not_swallow_later_signal_annotation() {
  local dir state out status
  dir=$(make_case delayed-signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task-delayed.status"
  printf 'done: shipped before watcher published signal\n' > "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "empty-queue drain failed before delayed signal publication"
  grep -F 'task-delayed done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the main-drain loss backstop did not surface the terminal event before its delayed signal: $(cat "$out")"

  append_wake "$state" signal task-delayed.status "signal: task-delayed.status" \
    || fail "publishing the delayed status signal failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed after delayed signal publication"
  grep -F 'latest wake-EVENT observed at drain, not current state: task-delayed.status: done: shipped before watcher published signal' "$out" >/dev/null \
    || fail "the empty-queue drain acknowledged an event before its signal annotation: $(cat "$out")"
  pass "an empty-queue backstop presentation still preserves the status for its later signal annotation"
}

test_routine_working_and_covered_done_stay_silent_on_the_empty_queue() {
  local dir state out old
  dir=$(make_case silent-working)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task7.status"
  printf 'done: shipped clean\n' > "$state/task8.status"
  old=$(( $(date +%s) - 20 ))
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$old" "$state/task8.status" \
    || fail "could not age the covered done fixture"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task8 --verdict captain --summary 'shipped clean was handled' >/dev/null \
    || fail "could not record the newer branch outcome fixture"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with routine working and covered done lines"

  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed an UNREAD STATUS section: $(cat "$out")"
  fi
  if grep -F 'STATUS OUTCOME BACKSTOP' "$out" >/dev/null; then
    fail "a covered done line printed the outcome backstop: $(cat "$out")"
  fi
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "routine working/covered done lines printed OPEN DECISIONS: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty-queue covered routine case was not silent: $(cat "$out")"
  pass "routine working and branch-covered done lines print nothing on an empty-queue drain"
}

test_secondmate_working_line_rides_along_once() {
  local dir state out
  dir=$(make_case mate-working)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  prime_cursor "$state" "$state/mate.status"
  prime_cursor "$state" "$state/crew.status"

  # The watcher absorbs a second mate's progress line, so the next drain is
  # where main reads it; a crewmate's progress line stays silent as before.
  printf 'working: auditing the release notes\n' >> "$state/mate.status"
  prime_status_seen "$state" "$state/mate.status" || fail "could not mark the working line absorbed"
  printf 'working: compiling step 2\n' >> "$state/crew.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain over routine working lines failed"
  grep -F 'mate working: auditing the release notes' "$out" >/dev/null \
    || fail "a second mate's absorbed working line was not surfaced: $(cat "$out")"
  if grep -F 'compiling step 2' "$out" >/dev/null; then
    fail "a crewmate's routine working line was surfaced: $(cat "$out")"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  if grep -F 'auditing the release notes' "$out" >/dev/null; then
    fail "an already-presented second-mate working line was replayed: $(cat "$out")"
  fi
  pass "a second mate's working line rides along once in UNREAD STATUS; a crewmate's does not"
}

test_buried_decision_still_surfaces
test_omitted_decisions_stay_named
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
run_case cursor host-default test_terminal_supersession_reaches_cached_drains
run_case cursor host-default test_kind_changes_invalidate_folded_decisions
run_case cursor host-default test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision
run_case cursor host-default test_same_size_rewrite_is_detected_via_inode_identity
run_case cursor host-default test_read_failure_preserves_state_for_retry
run_case cursor host-default test_cursor_cache_read_failure_refolds_without_replaying_unread_status
run_case cursor host-default test_pre_fix_cursor_refolds_corr_tagged_decision
run_case cursor host-default test_previous_fold_cache_is_refolded_under_current_semantics
run_case cursor host-default test_buried_decision_survives_many_growing_drains_and_resolution_clears_it
run_case outcome-backstop host-off test_uncovered_keyless_captain_events_surface_on_the_next_main_drain
run_case outcome-backstop host-off test_newer_task_outcome_and_routine_latest_events_stay_silent
run_case outcome-backstop host-off test_older_or_other_task_outcome_cannot_hide_a_new_captain_event
run_case outcome-backstop host-off test_branch_annotation_cannot_consume_the_main_resurfacing_backstop
run_case outcome-backstop host-off test_same_second_outcome_uses_status_causal_position
run_case outcome-backstop host-off test_drain_does_not_scan_append_only_outcome_history
run_case outcome-backstop host-off test_successful_backstop_is_idempotent_without_consuming_delayed_annotation
run_case outcome-backstop host-off test_output_failure_does_not_commit_the_backstop_receipt
run_case outcome-backstop host-off test_receipt_commit_failure_repeats_the_already_presented_backstop
run_case outcome-backstop host-off test_rejected_decision_line_surfaces_once_through_backstop
run_case outcome-backstop host-off test_missing_index_self_heals_on_first_drain
run_case outcome-backstop host-off test_uncovered_event_surfaces_on_first_drain_without_index
run_case outcome-backstop host-off test_malformed_outcome_store_fails_closed_without_pi_advice
run_case outcome-backstop host-off test_held_lock_mode_rejects_an_unlocked_caller
run_case outcome-backstop host-off test_held_lock_mode_accepts_a_lock_owner_descendant
run_case outcome-backstop host-off test_index_self_heal_runs_under_the_outcome_lock
run_case outcome-backstop host-off test_overbound_routine_event_stays_silent
run_case outcome-backstop host-off test_backstop_output_is_bounded
run_case unread-status host-off test_incident_note_answer_buried_under_routine_note_surfaces_both
run_case unread-status host-off test_already_presented_notes_are_not_replayed
run_case unread-status host-off test_brand_new_note_after_presentation_is_surfaced
run_case unread-status host-off test_signal_annotation_surfaces_every_unread_note_not_only_the_newest
run_case unread-status host-off test_pending_reply_resolution_surfaces_once
run_case unread-status host-off test_self_announced_pending_reply_close_still_surfaces
run_case unread-status host-off test_unread_output_over_cap_remains_recoverable
run_case unread-status host-off test_snapshot_does_not_ack_a_later_append
run_case unread-status host-off test_retired_task_id_starts_new_status_unread
run_case unread-status host-off test_weak_identity_still_presents_and_advances
run_case unread-status host-off test_snapshot_failure_is_visible
run_case unread-status host-off test_open_decisions_fold_is_unchanged
run_case unread-status host-off test_empty_queue_does_not_swallow_later_signal_annotation
run_case unread-status host-off test_routine_working_and_covered_done_stay_silent_on_the_empty_queue
run_case unread-status host-off test_secondmate_working_line_rides_along_once
