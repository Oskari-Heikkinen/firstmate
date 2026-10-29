#!/usr/bin/env bash
# tests/fm-startup-network.test.sh - behavior tests for bin/fm-startup-network.sh,
# the deferred startup stage a session start launches instead of running its
# network work or inactive-outcome scan on the blocking path.
#
# The session-start suite proves the digest no longer waits and that the deferred
# sweeps still land. This suite pins the stage's own contract, whose whole job is
# to make deferral safe:
#   - `start` returns immediately and does not hold the caller's stdout open,
#     which is what would strand a session-open hook behind the worker
#   - a durable acknowledgement after harvest prints a finished result suppresses
#     the wake, while an unacknowledged result always produces one
#   - mutating sweeps are refused when the fleet lock no longer names the session
#     that requested them, and the refusal is reported rather than silent
#   - the aggregate bound turns a wedged sweep into an actionable line
#   - an abandoned `running` record is reported as needing a rerun rather than
#     staying "in progress" forever
#   - phase-aware single-flight: a covering worker is reused, while a later
#     locked request supersedes an in-flight probe-only worker
#   - a publish lock a live process holds past the budget ends the worker with a
#     failed-rerun record instead of an unbounded wait
#   - the delivery wait looks once a second within a birth bound, and each of its
#     exits (delivered, newer generation, dead claimant, deadline, held lock)
#     keeps its wake outcome
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-startup-network-tests)
DRAIN="$ROOT/bin/fm-wake-drain.sh"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

# build_template_bin: the fake code root's bin/, built once before the case pool
# and copied per world (one cp instead of one ln per bin/ script per case). It is
# a real firstmate bin/ except for fm-bootstrap.sh, which is replaced by a
# scriptable stand-in. The stage's contract is about WHEN and WHETHER the network
# half runs and how its result is published; bin/fm-bootstrap.sh's own behavior
# is owned by tests/fm-bootstrap.test.sh, so pinning it here would duplicate that
# owner and make these assertions depend on unrelated tool detection.
TEMPLATE_BIN="$TMP_ROOT/.template-bin"
build_template_bin() {
  local bin=$TEMPLATE_BIN f
  mkdir -p "$bin"
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$bin/$(basename "$f")"
  done
  rm -f "$bin/fm-bootstrap.sh"
  cat > "$bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
# Scriptable stand-in: records how it was invoked, then behaves as the test asks.
set -u
printf 'network=%s detect_only=%s\n' \
  "${FM_BOOTSTRAP_NETWORK:-all}" "${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
  >> "${FM_FAKE_BOOTSTRAP_LOG:?}"
# The real sweeps record their elapsed times through fm-timing-lib.sh, which
# reaches them as an exported FM_TIMING_LOG. Recording the same way here proves
# the stage actually hands that channel to its child and publishes what the child
# wrote - the part of the contract this suite owns. What the real sweeps measure
# is owned by tests/fm-bootstrap.test.sh.
if [ -n "${FM_TIMING_LOG:-}" ]; then
  . "$(dirname "$0")/fm-timing-lib.sh"
  fm_timing_record phase "${FM_FAKE_TIMING_PHASE:-gh-auth}" \
    "$(( $(fm_timing_now_ms) - 1500 ))" "${FM_FAKE_TIMING_DETAIL:-}"
fi
[ -z "${FM_FAKE_BOOTSTRAP_SLEEP:-}" ] || sleep "$FM_FAKE_BOOTSTRAP_SLEEP"
[ -z "${FM_FAKE_BOOTSTRAP_OUT:-}" ] || printf '%s\n' "$FM_FAKE_BOOTSTRAP_OUT"
exit "${FM_FAKE_BOOTSTRAP_RC:-0}"
SH
  chmod +x "$bin/fm-bootstrap.sh"
  cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then
  case "$*" in
    *comm=*) printf '/usr/local/bin/claude\n' ;;
    *args=*) printf 'claude\n' ;;
    *ppid=*) /bin/ps -o ppid= -p "$pid" ;;
  esac
else
  /bin/ps "$@"
fi
SH
  chmod +x "$bin/ps"
}

# new_world <name>: an FM_HOME plus a fake code root holding a private copy of
# the template bin/ (symlinks stay symlinks), so a case may replace a script in
# its own copy without touching any other case.
new_world() {
  local name=$1 w home root
  w="$TMP_ROOT/$name"
  home="$w/home"
  root="$w/root"
  mkdir -p "$home/state" "$root"
  cp -PRp "$TEMPLATE_BIN" "$root/bin"
  printf '%s|%s|%s\n' "$home" "$root" "$w/bootstrap.log"
}

# The detached worker records itself a moment after `start` returns - that gap is
# the whole point of not blocking - so a test that wants to observe the worker
# waits for its record rather than assuming instant publication.
await_worker_record() {  # <home>
  local home=$1 waited=0
  while [ ! -s "$home/state/.startup-network.status" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$home/state/.startup-network.status" ] || fail "the detached worker never recorded itself"
}

test_wait_fails_without_a_published_stage() {
  local rec home root log
  rec=$(new_world wait-without-stage)
  IFS='|' read -r home root log <<EOF
$rec
EOF

  if run_stage "$home" "$root" wait 1 >/dev/null; then
    fail "wait reported success even though no deferred stage had published"
  fi

  pass "fm-startup-network: wait fails when no deferred stage publishes before its deadline"
}

# Cases that pin the delivery window set FM_SESSION_START_TIMEOUT themselves.
# Every other case gets a short delivery bound, so a detached worker whose claim
# names this still-live suite shell settles seconds after it publishes instead of
# polling its publish lock for the 120s default while later cases run.
run_stage() {  # <home> <root> <args...>
  local home=$1 root=$2
  shift 2
  PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="${FM_FAKE_HARNESS_PID_OVERRIDE:-$$}" \
    FM_SESSION_START_TIMEOUT="${FM_SESSION_START_TIMEOUT:-5}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-startup-network.sh" "$@"
}

wait_for_startup_network_wake() {  # <home> [tenths]
  local home=$1 limit=${2:-50} waited=0
  while ! grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt "$limit" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null
}

# hold_publish_lock <home>: take the stage's publish lock from a separate live
# process, the way a harvest wedged on a stalled stdout holds it, and print that
# holder's pid. The holder keeps the pid the lock records, so the lock's
# stale-owner recovery never reclaims it while the test runs. A worker waiting
# on delivery holds the lock for a moment each look, so the holder retries.
hold_publish_lock() {  # <home>
  local lock="$1/state/.startup-network.lock" holder waited=0
  FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/fm-wake-lib.sh"
    tries=0
    until fm_lock_try_acquire "$2"; do
      tries=$((tries + 1))
      [ "$tries" -lt 50 ] || exit 1
      sleep 0.1
    done
    exec sleep 120' _ "$ROOT/bin" "$lock" >/dev/null 2>&1 </dev/null &
  holder=$!
  while [ "$(cat "$lock/pid" 2>/dev/null || true)" != "$holder" ] && kill -0 "$holder" 2>/dev/null \
    && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] \
    || fail "could not hold the publish lock from a second process"
  printf '%s' "$holder"
}

# await_pid_exit <pid> <tenths>: true when the process exits inside the bound.
await_pid_exit() {  # <pid> <tenths>
  local waited=0
  while kill -0 "$1" 2>/dev/null && [ "$waited" -lt "$2" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

# --- tests -------------------------------------------------------------------

# `start` is called from inside a session-open hook whose stdout the harness
# reads to EOF. A worker that inherited that pipe would hold the session open for
# exactly as long as the network work it was supposed to get off the critical
# path, so this asserts both halves: start returns fast, AND the pipe closes
# while the worker is still running.
test_start_returns_without_holding_the_callers_stdout() {
  local rec home root log started elapsed pending
  rec=$(new_world start-nonblocking)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  started=$(date +%s)
  # Command substitution reads to EOF, exactly like a hook harvesting hook output.
  # The worker sleeps longer than the 4s bound below, so a start that waited
  # for it could not pass.
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$ >/dev/null
  elapsed=$(( $(date +%s) - started ))

  [ "$elapsed" -lt 4 ] || fail "start blocked for ${elapsed}s behind a 6s worker"
  await_worker_record "$home"
  pending=$(run_stage "$home" "$root" report)
  [ "$(printf '%s\n' "$pending" | head -1)" = "IN PROGRESS - the deferred network checks have not finished yet." ] \
    || fail "the worker was not actually still running: $pending"
  assert_contains "$pending" "Only a FAILED or otherwise actionable result arrives as a \`check: startup-network\` wake; a clean success stays silent." \
    "the pending guidance still promised a wake for clean success"
  assert_contains "$pending" "$root/bin/fm-startup-network.sh report" \
    "the pending guidance omitted the durable on-demand report path"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the worker never published"
  assert_grep 'network=only' "$log" "the worker did not run bootstrap's network-only phase"
  pass "fm-startup-network: start returns immediately and never holds the caller's stdout open"
}

test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it() {
  local rec home root log claimant output waited=0 worker_pid
  rec=$(new_world claim-handshake)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=15 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='acknowledged result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the claimed worker never published"
  worker_pid=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "acknowledged result" \
    "harvest did not print the finished result it acknowledged"
  [ -s "$home/state/.startup-network.delivered" ] \
    || fail "harvest did not durably acknowledge the result it printed"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  while kill -0 "$worker_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$worker_pid" 2>/dev/null \
    || fail "the worker did not settle after harvest acknowledged its result"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a result harvest acknowledged also queued a wake: $(cat "$home/state/.wake-queue")"

  # Harvest releases that claim, so the NEXT publication has nobody to print it.
  # An actionable result (not a clean success) is used here so the assertion
  # stays about the claim mechanism; test_a_successful_result_never_queues_a_wake
  # below owns the separate "a clean success never wakes" contract.
  assert_absent "$home/state/.startup-network.claim" "harvest did not release its own claim"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" run --locked 0
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an unclaimed actionable result never reached the wake queue"

  : > "$home/state/.wake-queue"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the dead-claim worker never published"
  wait_for_startup_network_wake "$home" || fail "the dead-claim worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a dead session's stale claim swallowed the result"
  assert_absent "$home/state/.startup-network.claim" "a dead claim was not reaped"
  pass "fm-startup-network: exactly one of the digest and the wake reports each actionable result"
}

test_a_claimant_crash_after_publish_still_queues_the_wake() {
  local rec home root log claimant
  rec=$(new_world claimant-crash)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  # Actionable output: a clean success in this same crash window must stay
  # silent (test_a_successful_result_never_queues_a_wake owns that case).
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the crash-window worker never published"
  kill -0 "$claimant" 2>/dev/null \
    || fail "the claimant died before the worker published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  wait_for_startup_network_wake "$home" || fail "the crash-window worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a claimant crash after publication silently lost the result"
  assert_absent "$home/state/.startup-network.delivered" \
    "an unharvested result was recorded as delivered"
  pass "fm-startup-network: a claimant crash after publication still surfaces the result"
}

# The delivery wait after publication looks once a second, not ten times. Each
# case below gives the claimant a long delivery budget unless the deadline is the
# point, so every exit can only come from the path the case names.

# install_birth_counter <root> <log>: a counting stand-in for each common
# external command in the world's bin/, ahead of the real one on PATH, so every
# exec the stage makes of them appends that command's name to <log>.
install_birth_counter() {  # <root> <log>
  local tool real
  for tool in sleep date sed tail head cat mktemp ln readlink rm rmdir mv awk grep stat; do
    real=$(command -v "$tool") || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$2" "$real" > "$1/bin/$tool"
    chmod +x "$1/bin/$tool"
  done
}

# A live claimant that never harvests keeps the worker waiting for the whole
# delivery budget. At a tenth-second poll that wait cost about 370 counted
# births and 24 pauses over 5s; at one look a second it costs about 70-100
# births, and at most six pauses fit in the budget.
test_the_delivery_wait_stays_within_its_birth_bound() {
  local rec home root log births claimant worker offset total window pauses
  rec=$(new_world delivery-wait-births)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  births="${home%/home}/births.log"
  install_birth_counter "$root" "$births"
  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=5 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the claimed worker never published"
  offset=$(wc -l < "$births")
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  await_pid_exit "$worker" 150 || fail "the worker outlived its 5s delivery budget"
  window=$(tail -n +"$((offset + 1))" "$births")
  total=$(printf '%s\n' "$window" | grep -c .)
  pauses=$(printf '%s\n' "$window" | grep -cx sleep)
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  [ "$pauses" -le 6 ] && [ "$total" -le 150 ] \
    || fail "the 5s delivery wait made $total counted births (bound 150) and $pauses pauses (bound 6): $(printf '%s\n' "$window" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a clean result whose claimant outlived the budget queued a wake: $(cat "$home/state/.wake-queue")"
  pass "fm-startup-network: the delivery wait looks once a second ($total counted births, $pauses pauses in a 5s wait)"
}

# The allowed slower worst case: a claimant that dies without harvesting is
# noticed within a second, so its wake lands within 1s plus slack, long before
# the 60s budget could explain it.
test_a_dropped_delivery_wakes_within_a_second() {
  local rec home root log claimant worker began took
  rec=$(new_world dropped-delivery)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=60 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the dropped-delivery worker never published"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  [ ! -s "$home/state/.wake-queue" ] || fail "the worker woke while its claimant was still alive"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  began=$(date +%s)
  wait_for_startup_network_wake "$home" 100 || fail "a dropped delivery never queued its wake"
  took=$(( $(date +%s) - began ))
  [ "$took" -le 3 ] || fail "a dropped delivery took ${took}s to wake (1s plus slack)"
  await_pid_exit "$worker" 50 || fail "the worker did not exit after waking for a dropped delivery"
  assert_absent "$home/state/.startup-network.claim" "the dead claimant's claim was not reaped"
  assert_absent "$home/state/.startup-network.delivered" "an unharvested result was recorded as delivered"
  pass "fm-startup-network: a claimant that dies without harvesting wakes within a second"
}

# A newer start replaces the generation the worker publishes for, so the older
# worker stops waiting at once and leaves the wake decision to the newer one.
test_a_newer_generation_ends_the_older_delivery_wait() {
  local rec home root log first second old_worker new_worker
  rec=$(new_world generation-bump)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 30 &
  first=$!
  FM_SESSION_START_TIMEOUT=60 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$first"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the first worker never published"
  old_worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")

  sleep 30 &
  second=$!
  FM_SESSION_START_TIMEOUT=60 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$second"
  await_pid_exit "$old_worker" 50 \
    || fail "the older worker kept waiting on delivery after a newer generation replaced it"
  kill -0 "$first" 2>/dev/null || fail "the first claimant died before the generation changed"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a superseded result queued a wake: $(cat "$home/state/.wake-queue")"

  run_stage "$home" "$root" wait 30 >/dev/null || fail "the second worker never published"
  new_worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  kill "$first" "$second" 2>/dev/null || true
  wait "$first" "$second" 2>/dev/null || true
  await_pid_exit "$new_worker" 50 || fail "the second worker did not exit after its claimant died"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "the clean newer result queued a wake: $(cat "$home/state/.wake-queue")"
  pass "fm-startup-network: a newer generation ends the older worker's delivery wait without a wake"
}

# A claimant still alive at the delivery deadline is no longer waited for: the
# wake decision is made as if it were gone, and its claim stays in place.
test_the_delivery_deadline_wakes_while_the_claimant_lives() {
  local rec home root log claimant worker began took
  rec=$(new_world delivery-deadline)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=6 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the deadline worker never published"
  began=$(date +%s)
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  wait_for_startup_network_wake "$home" 150 || fail "the delivery deadline passed without a wake"
  took=$(( $(date +%s) - began ))
  kill -0 "$claimant" 2>/dev/null || fail "the claimant died, so the deadline path was not the one taken"
  [ "$took" -ge 3 ] || fail "the wake came ${took}s after publication, before the 6s delivery deadline"
  await_pid_exit "$worker" 50 || fail "the worker did not exit at its delivery deadline"
  [ -s "$home/state/.startup-network.claim" ] \
    || fail "the deadline path removed a live claimant's claim"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  pass "fm-startup-network: the delivery deadline wakes for an actionable result while the claimant lives"
}

# A publish lock held through the rest of the delivery budget ends the wait
# with a wake, because the claim can no longer be judged under the lock.
test_a_lock_held_through_the_delivery_wait_still_wakes() {
  local rec home root log claimant worker holder
  rec=$(new_world delivery-lock-held)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=6 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the lock-held worker never published"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  holder=$(hold_publish_lock "$home")
  kill -0 "$worker" 2>/dev/null || fail "the worker left its delivery wait before the lock was held"
  [ ! -s "$home/state/.wake-queue" ] || fail "the worker woke before the lock was held"
  await_pid_exit "$worker" 150 || fail "the worker outlived its delivery budget behind a held lock"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a delivery wait that lost the lock did not wake"
  kill -0 "$claimant" 2>/dev/null || fail "the claimant died, so the held-lock path was not the one taken"
  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = 'done' ] \
    || fail "the held lock changed the published state"
  kill "$holder" "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  pass "fm-startup-network: a publish lock held through the delivery wait still wakes"
}

test_a_report_publication_failure_is_failed_and_still_wakes() {
  local rec home root log claimant output state
  rec=$(new_world report-publication-failure)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  mkdir "$home/state/.startup-network.report"
  chmod 500 "$home/state/.startup-network.report"
  sleep 10 &
  claimant=$!

  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='unpublishable result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the report-publication failure never settled"
  state=$(sed -n 's/^state=//p' "$home/state/.startup-network.status")
  [ "$state" = failed ] || fail "a report-publication failure was published as $state"

  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" "NETWORK_CHECKS: could not publish the deferred check report" \
    "report did not surface the report-publication failure: $output"
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "NETWORK_CHECKS: could not publish the deferred check report" \
    "harvest did not surface the report-publication failure: $output"
  assert_absent "$home/state/.startup-network.delivered" \
    "harvest acknowledged a result whose report was not published"
  wait_for_startup_network_wake "$home" || fail "the report-publication failure suppressed the wake"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "the report-publication failure did not reach the wake queue"

  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  chmod 700 "$home/state/.startup-network.report"
  pass "fm-startup-network: a report-publication failure is failed, diagnosed, and still wakes"
}

# A clean success is not captain-facing progress (AGENTS.md section 8): it must
# never become a main-blocking wake row, whether or not a session was there to
# claim and harvest it inline. The result stays durable and readable through
# `report` either way.
test_a_successful_result_never_queues_a_wake() {
  local rec home root log claimant report
  rec=$(new_world successful-result-silent)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the unclaimed successful worker never published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true

  # Give the same settling window the crash-window test uses, then confirm no
  # wake ever lands - not a race that just hasn't finished yet.
  sleep 1
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a clean successful network-checks result queued a main-blocking wake: $(cat "$home/state/.wake-queue")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "(silent - no problems found)" \
    "a successful result was not durably readable through report: $report"

  # Bootstrap itself explicitly types completed benign work as BOOTSTRAP_INFO.
  # That producer-owned no-action record is durable but must remain just as
  # quiet as a fully silent success.
  FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='BOOTSTRAP_INFO: fixture completed benign work' \
    run_stage "$home" "$root" run --locked 0
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a BOOTSTRAP_INFO-only success queued a main-blocking wake: $(cat "$home/state/.wake-queue")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "BOOTSTRAP_INFO: fixture completed benign work" \
    "the completed no-action fact was not retained in the durable report"

  pass "fm-startup-network: silent and explicitly informational successes never queue a main-blocking wake"
}

# The FAILED/actionable half of the same contract, paired with the success
# test above: an actionable report (here, a MISSING: line bootstrap-diagnostics
# would load a skill for) still reaches the wake queue even when unclaimed.
test_an_actionable_successful_result_still_queues_a_wake() {
  local rec home root log claimant
  rec=$(new_world actionable-result-wakes)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the unclaimed actionable worker never published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true

  wait_for_startup_network_wake "$home" \
    || fail "an actionable successful (state=done) result never queued a wake"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an actionable result did not reach the wake queue"

  pass "fm-startup-network: an actionable state=done report still queues a wake"
}

test_deferred_invalid_secondmate_markers_queue_durable_findings() {
  local kind rec home root log target report err seq generation
  for kind in malformed symlink; do
    rec=$(new_world "deferred-invalid-marker-$kind")
    IFS='|' read -r home root log <<EOF
$rec
EOF
    printf '%s\n' $$ > "$home/state/.lock"
    if [ "$kind" = malformed ]; then
      printf '../other-home\n' > "$home/.fm-secondmate-home"
    else
      target="$TMP_ROOT/deferred-invalid-marker-$kind/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$home/.fm-secondmate-home"
    fi

    FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 1
    assert_grep $'check\tinactive-reconcile-diagnostic:invalid-secondmate-home\t' "$home/state/.wake-queue" \
      "$kind marker finding was swallowed by the deferred startup stage"
    report=$(run_stage "$home" "$root" report)
    assert_contains "$report" "(silent - no problems found)" \
      "$kind marker fixture unexpectedly depended on the network report"

    err="$home/drain.err"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
    generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -n "$seq" ] && [ -n "$generation" ] \
      || fail "$kind marker wake did not issue a durable acknowledgement"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" \
      --ack-through "$seq" --recovery-generation "$generation" >/dev/null
    assert_no_grep 'inactive-reconcile-diagnostic:invalid-secondmate-home' "$home/state/.wake-queue" \
      "$kind marker wake could not be acknowledged"
  done
  pass "fm-startup-network: deferred invalid secondmate markers produce durable wakes"
}

# The worker outlives the command that launched it. If another session took the
# lock meanwhile, running the mutating sweeps would sweep underneath that
# session, so they are refused - and the refusal is reported, not silent.
test_mutating_sweeps_are_refused_when_the_lock_changed_hands() {
  local rec home root log report
  rec=$(new_world lock-changed)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '222222\n' > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 1 --lock-pid 111111
  assert_grep 'network=only detect_only=1' "$log" \
    "the worker ran mutating sweeps for a lock it no longer held"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: the fleet lock was no longer held" \
    "the downgrade to a read-only probe was not reported"

  # A detached start captures the lock itself and may run the mutating phase.
  : > "$log"
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the lock-authorized worker never published"
  assert_grep 'network=only detect_only=0' "$log" \
    "the worker refused sweeps for the very session that still holds the lock"
  pass "fm-startup-network: manual callers cannot forge mutation authority"
}

# The unbounded per-call network work is exactly what could wedge a startup. The
# stage carries one aggregate bound, and hitting it is an actionable line.
test_the_stage_bound_is_reported_not_swallowed() {
  local rec home root log report
  rec=$(new_world stage-bound)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 FM_STARTUP_NETWORK_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" harvest --pid $$ >/dev/null
  FM_STARTUP_NETWORK_TIMEOUT=2 run_stage "$home" "$root" wait 10 >/dev/null \
    || fail "the bounded worker never settled"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: hit the 2s bound before finishing" \
    "a wedged deferred stage was not reported: $report"
  assert_contains "$report" "fm-startup-network.sh run --locked 1" \
    "the timeout line did not say how to rerun the stage"
  wait_for_startup_network_wake "$home" || fail "the timed-out worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a timed-out stage did not surface to the agent"
  pass "fm-startup-network: an aggregate bound turns a wedged sweep into an actionable line"
}

# A worker killed before publication leaves a `running` record behind.
# That record must read as work to redo, not as work still in flight.
test_an_abandoned_run_reads_as_needing_a_rerun() {
  local rec home root log report
  rec=$(new_world abandoned)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  cat > "$home/state/.startup-network.status" <<EOF
state=running
pid=999999999
started=$(date +%s)
locked=1
phases=probe,sweeps
EOF

  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: the deferred check worker stopped before publishing" \
    "an abandoned run still read as in progress: $report"
  assert_contains "$report" "dead-secondmate relaunch" \
    "the abandoned run did not name the checks that never completed"

  # A record older than the whole aggregate bound is abandoned even when its pid
  # happens to be alive again, so "in progress" can never become permanent.
  cat > "$home/state/.startup-network.status" <<EOF
state=running
pid=$$
started=$(( $(date +%s) - 400 ))
locked=1
phases=probe,sweeps
EOF
  assert_contains "$(FM_STARTUP_NETWORK_TIMEOUT=10 run_stage "$home" "$root" report)" \
    "NETWORK_CHECKS: the deferred check worker stopped before publishing" \
    "a record that outlived the stage bound still read as in progress"
  pass "fm-startup-network: an abandoned run reports as needing a rerun, never as in progress forever"
}

test_locked_start_is_not_satisfied_by_an_inflight_probe() {
  local rec home root log waited=0
  rec=$(new_world probe-then-locked)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  printf '../other-home\n' > "$home/.fm-secondmate-home"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid $$
  while ! grep -Fq 'detect_only=1' "$log" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'network=only detect_only=1' "$log" \
    "the probe-only worker was not in flight before the locked request"

  FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 30 >/dev/null \
    || fail "the locked request never published"
  assert_grep 'network=only detect_only=0' "$log" \
    "the in-flight probe-only worker suppressed the locked sweeps"
  assert_grep $'check\tinactive-reconcile-diagnostic:invalid-secondmate-home\t' "$home/state/.wake-queue" \
    "the in-flight probe-only worker suppressed the locked inactive scan"
  pass "fm-startup-network: locked requests supersede in-flight probe-only workers"
}

# Two session opens in quick succession must not run the same mutating sweeps
# concurrently against each other.
test_start_is_single_flight() {
  local rec home root log runs
  rec=$(new_world single-flight)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=4 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  await_worker_record "$home"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=4 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 40 >/dev/null || fail "the worker never published"

  runs=$(grep -c 'network=only' "$log" || true)
  [ "$runs" -eq 1 ] || fail "a second start launched a competing worker ($runs runs): $(cat "$log")"
  pass "fm-startup-network: a second start never launches a competing worker"
}

test_start_reserves_its_generation_before_returning() {
  local rec home root log report
  rec=$(new_world generation-reservation)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  cat > "$home/state/.startup-network.status" <<EOF
state=done
pid=999999999
started=1
finished=2
rc=0
locked=0
phases=probe
generation=old
lock_pid=
EOF
  printf 'old result\n' > "$home/state/.startup-network.report"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=3 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid $$
  report=$(run_stage "$home" "$root" harvest --pid $$)
  assert_contains "$report" "IN PROGRESS" \
    "harvest exposed the previous generation after a new start returned: $report"
  assert_not_contains "$report" "old result" \
    "harvest printed a stale generation's report"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the reserved generation never published"
  pass "fm-startup-network: start atomically reserves the generation harvest observes"
}

test_new_lock_owner_does_not_reuse_the_previous_owners_worker() {
  local rec home root log generation_one generation_two next_owner
  rec=$(new_world owner-handoff)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=4 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  generation_one=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")

  next_owner=$(/bin/ps -o ppid= -p $$ | tr -d ' ')
  printf '%s\n' "$next_owner" > "$home/state/.lock"
  FM_FAKE_HARNESS_PID_OVERRIDE="$next_owner" FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=1 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  generation_two=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  [ "$generation_one" != "$generation_two" ] \
    || fail "the new lock owner reused the previous owner's generation"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the new owner's generation never published"
  pass "fm-startup-network: a new lock owner gets a distinct worker generation"
}

test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease() {
  local rec home root log next_owner new_owner out rc started elapsed waited=0
  rec=$(new_world sweep-lease)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  while [ ! -s "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$log" ] || fail "the mutating sweep never started"

  next_owner=$(/bin/ps -o ppid= -p $$ | tr -d ' ')
  started=$(date +%s)
  rc=0
  out=$(PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="$next_owner" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-lock.sh" 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 0 ] || fail "lock takeover succeeded while the prior sweep was mutating"
  [ "$elapsed" -lt 4 ] || fail "lock takeover blocked ${elapsed}s behind deferred network work"
  assert_contains "$out" "operate read-only" \
    "a lease-blocked takeover did not fail closed to read-only: $out"
  [ "$(cat "$home/state/.lock")" = "$$" ] \
    || fail "the lease-blocked takeover replaced the prior owner"

  run_stage "$home" "$root" wait 30 >/dev/null || fail "the leased sweep never settled"
  out=$(PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="$next_owner" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-lock.sh" 2>&1) \
    || fail "lock takeover still failed after the sweep released its lease"
  new_owner=$(cat "$home/state/.lock")
  assert_contains "$out" "lock acquired: harness pid $new_owner" \
    "the fleet lock did not record the harness owner reported by acquisition"
  [ "$new_owner" != "$$" ] || fail "the prior harness still owned the lock after takeover"
  pass "fm-startup-network: fleet-lock takeover cannot overlap a mutating sweep"
}

# Every record carries a start offset from ONE origin, so the artifact reads as a
# timeline and not just a bag of durations. The origin is normally exported by the
# stage, but a process that starts recording without one has to adopt an origin
# and KEEP it: recomputing it per record would silently flatten every offset to
# zero and lose the ordering the artifact exists to show. Driven with explicit
# start stamps so the assertion does not depend on the host clock's resolution.
test_records_share_one_origin_so_offsets_form_a_timeline() {
  local dir log offsets count second third
  dir="$TMP_ROOT/timing-origin"
  mkdir -p "$dir"
  log="$dir/timings.tsv"

  (
    # shellcheck source=bin/fm-timing-lib.sh
    . "$ROOT/bin/fm-timing-lib.sh"
    unset FM_TIMING_EPOCH_MS
    FM_TIMING_LOG=$log
    export FM_TIMING_LOG
    base=$(fm_timing_now_ms)
    fm_timing_record phase first "$base"
    fm_timing_record phase second "$(( base + 5000 ))"
    fm_timing_record phase third "$(( base + 9000 ))"
  )

  # The origin lands within the first record, so that record's own offset rounds
  # to zero; what proves the origin was KEPT is that the later records are spaced
  # by exactly the interval they were given. Recomputing the origin per record
  # would report every one of them as zero.
  offsets=$(awk -F'\t' '$1 == "v1" { print $4 }' "$log")
  count=$(printf '%s\n' "$offsets" | grep -c .)
  second=$(printf '%s\n' "$offsets" | sed -n 2p)
  third=$(printf '%s\n' "$offsets" | sed -n 3p)
  [ "$count" -eq 3 ] || fail "expected three records, got: $offsets"
  [ "$second" -gt 0 ] && [ "$third" -gt "$second" ] \
    || fail "records did not share one origin - offsets were: $offsets"
  [ "$(( third - second ))" -eq 4000 ] \
    || fail "offsets did not preserve the interval between records: $offsets"
  pass "fm-startup-network: timing records share one origin so their offsets form a timeline"
}

# The whole point of the artifact is that it is FREE until someone asks for it.
# `harvest` is what composes a session start's NETWORK CHECKS section, so a
# timing line leaking into it would be a change to every startup's output; only
# the on-demand `report` may print them.
test_timings_are_published_and_only_the_on_demand_report_prints_them() {
  local rec home root log report_out harvest_out
  rec=$(new_world timings-published)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='sweep finding' \
    FM_FAKE_TIMING_PHASE=fleet-sync FM_FAKE_TIMING_DETAIL=dotfiles-private \
    run_stage "$home" "$root" run --locked 1

  assert_present "$home/state/.startup-network.timings" \
    "a finished run published no timing record"
  assert_grep 'fleet-sync' "$home/state/.startup-network.timings" \
    "the stage did not publish what the sweep recorded"
  assert_grep 'stage	network-checks' "$home/state/.startup-network.timings" \
    "the stage did not record its own bounded total"

  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "sweep finding" "report stopped printing the sweep result"
  assert_contains "$report_out" "TIMINGS" "report did not print the per-step timings"
  assert_contains "$report_out" "fleet-sync dotfiles-private" \
    "report did not attribute the elapsed time to the clone that spent it"
  assert_contains "$report_out" "slowest:" "report did not surface the slowest steps"

  harvest_out=$(run_stage "$home" "$root" harvest --pid $$)
  assert_contains "$harvest_out" "sweep finding" "harvest stopped printing the sweep result"
  assert_not_contains "$harvest_out" "TIMINGS" \
    "the timings leaked into the session-start digest section"
  assert_not_contains "$harvest_out" "slowest:" \
    "the timings leaked into the session-start digest section"
  pass "fm-startup-network: timings are durable and printed only on demand"
}

# A run that hit the bound is exactly the run worth attributing, so whatever the
# killed sweeps managed to record must survive rather than being discarded with
# them.
test_a_bounded_run_still_publishes_the_timings_it_managed_to_record() {
  local rec home root log report_out
  rec=$(new_world timings-partial)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_STARTUP_NETWORK_TIMEOUT=1 FM_SESSION_START_TIMEOUT=2 \
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 \
    FM_FAKE_TIMING_PHASE=secondmate-liveness FM_FAKE_TIMING_DETAIL='mate-a@host-one' \
    run_stage "$home" "$root" run --locked 1

  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = timeout ] \
    || fail "the bounded run did not record itself as timed out"
  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "hit the 1s bound" "the bound stopped being reported"
  assert_contains "$report_out" "secondmate-liveness mate-a@host-one" \
    "a timed-out run discarded the partial timings its sweeps had already recorded"
  pass "fm-startup-network: a timed-out run still publishes the partial timings it recorded"
}

# The artifact is read by a human looking at a slow startup, so it must be
# incapable of carrying an argv or a credential out of a sweep, and incapable of
# being broken by one either: a detail with tabs or newlines would otherwise
# forge extra records.
test_the_timing_artifact_cannot_carry_a_command_line_or_forge_records() {
  local rec home root log lines report_out
  rec=$(new_world timings-sanitized)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_TIMING_PHASE=secondmate-sync \
    FM_FAKE_TIMING_DETAIL="ssh -i /key host	v1	forged	0	9999
GITHUB_TOKEN=ghp_supersecretvalue" \
    run_stage "$home" "$root" run --locked 1

  assert_no_grep 'ghp_supersecretvalue' "$home/state/.startup-network.timings" \
    "the timing artifact carried a credential-shaped value through"
  assert_no_grep 'forged' "$home/state/.startup-network.timings" \
    "a detail containing tabs forged an extra timing record"
  assert_no_grep 'ssh' "$home/state/.startup-network.timings" \
    "the timing artifact carried a command line through"
  assert_grep 'unrecordable' "$home/state/.startup-network.timings" \
    "free text was silently dropped instead of being marked unrecordable"
  lines=$(grep -c . "$home/state/.startup-network.timings")
  [ "$lines" -eq 3 ] \
    || fail "one sweep record, the dead-worker relaunch step, and the stage total should be 3 lines, got $lines"

  # The step itself is still measured - only its untrustworthy label is refused,
  # so a sweep that mislabels itself still shows up as time spent.
  assert_grep 'secondmate-sync' "$home/state/.startup-network.timings" \
    "refusing the label also discarded the measurement"

  report_out=$(run_stage "$home" "$root" report)
  assert_not_contains "$report_out" "ghp_supersecretvalue" \
    "the rendered report printed a credential-shaped value"
  pass "fm-startup-network: the timing artifact cannot carry a command line or forge records"
}

# A live holder of the publish lock used to keep the worker spinning for as long
# as the lock stayed held - hours, when a harvest wedged on a stalled stdout -
# with every result discarded at the end. Both the wait before the sweeps and
# the publication wait after them must give up inside the worker's own budget,
# record the failure the way `report` already reads a failed stage, and wake.
test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget() {
  local rec home root log holder began took rc report worker waited
  rec=$(new_world held-lock)
  IFS='|' read -r home root log <<EOF
$rec
EOF

  # Before the sweeps: the lock is held before the worker even registers.
  holder=$(hold_publish_lock "$home")
  began=$(date +%s)
  rc=0
  fm_run_timed 15 env PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_STARTUP_NETWORK_TIMEOUT=2 FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    "$root/bin/fm-startup-network.sh" run --locked 0 >/dev/null 2>&1 || rc=$?
  took=$(( $(date +%s) - began ))
  [ "$rc" -ne 124 ] || fail "the worker was still waiting on the held publish lock 15s past a 2s budget"
  [ "$rc" -ne 0 ] || fail "the worker reported success without ever taking the publish lock"
  [ "$took" -le 6 ] || fail "the worker took ${took}s to give up on a 2s budget"
  [ ! -f "$log" ] || fail "the sweeps ran even though the worker could not register itself"
  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = failed ] \
    || fail "a worker that gave up on the lock did not record a failed stage"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "still held by pid $holder" \
    "the failed record did not name the process holding the lock: $report"
  assert_contains "$report" "fm-startup-network.sh run --locked 0" \
    "the failed record did not say how to rerun the stage"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a worker that gave up on the lock did not surface to the agent"
  kill "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the first lock holder"

  # After the sweeps: the worker registers and sweeps freely, then finds the
  # lock held when it comes to publish. What the sweeps produced must survive.
  rm -f "$home/state/.wake-queue" "$log"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT='PROBE_RAN' \
    FM_STARTUP_NETWORK_TIMEOUT=10 FM_SESSION_START_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  waited=0
  while [ ! -f "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$log" ] || fail "the detached worker never started its sweep"
  holder=$(hold_publish_lock "$home")
  await_pid_exit "$worker" 100 \
    || fail "the worker was still alive 10s after its sweep finished against a held publish lock (2s delivery budget)"
  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = failed ] \
    || fail "a worker that could not publish did not record a failed stage"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "PROBE_RAN" \
    "the sweep output was discarded when publication found the lock held: $report"
  assert_contains "$report" "still held by pid $holder" \
    "the unpublished result did not name the process holding the lock"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a result that could not be published under the lock did not surface to the agent"
  kill "$holder" 2>/dev/null || true
  pass "fm-startup-network: a held publish lock ends the worker inside its budget with a failed-rerun record"
}

# The dead-worker relaunch (bin/fm-reboot-relaunch.sh owns its gate) runs only
# in locked work, ahead of the sweeps, under its own bound, and its lines and
# failures land in the same report.
fake_reboot_relaunch() {  # <root> <log>
  rm -f "$1/bin/fm-reboot-relaunch.sh"
  cat > "$1/bin/fm-reboot-relaunch.sh" <<SH
#!/usr/bin/env bash
printf 'relaunch %s\n' "\$*" >> '$2'
[ -z "\${FM_FAKE_RELAUNCH_SLEEP:-}" ] || sleep "\$FM_FAKE_RELAUNCH_SLEEP"
[ -z "\${FM_FAKE_RELAUNCH_OUT:-}" ] || printf '%s\n' "\$FM_FAKE_RELAUNCH_OUT"
exit "\${FM_FAKE_RELAUNCH_RC:-0}"
SH
  chmod +x "$1/bin/fm-reboot-relaunch.sh"
}

test_dead_worker_relaunch_runs_only_in_locked_work_and_reports_its_failures() {
  local rec home root log report
  rec=$(new_world reboot-relaunch)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  fake_reboot_relaunch "$root" "$log"
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 0
  assert_no_grep 'relaunch ' "$log" "an unlocked run started the dead-worker relaunch"

  : > "$log"
  FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_RELAUNCH_OUT='BOOTSTRAP_INFO: reboot relaunch: relaunched t1 (fixture)' \
    run_stage "$home" "$root" run --locked 1 --lock-pid $$
  assert_grep "relaunch run --lock-pid $$ --deadline " "$log" \
    "a locked run did not hand the relaunch its lock owner and deadline"
  [ "$(head -1 "$log" | cut -c1-9)" = 'relaunch ' ] \
    || fail "the relaunch did not run ahead of the sweeps: $(cat "$log")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "BOOTSTRAP_INFO: reboot relaunch: relaunched t1 (fixture)" \
    "the relaunch's own lines did not reach the report"
  assert_grep 'network=only detect_only=0' "$log" "the sweeps did not still run after the relaunch"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_RELAUNCH_RC=7 \
    run_stage "$home" "$root" run --locked 1 --lock-pid $$
  assert_contains "$(run_stage "$home" "$root" report)" \
    "REBOOT_RELAUNCH: the dead-worker relaunch exited 7" "a failed relaunch step was swallowed"

  # Time the relaunch spends extends the stage deadline rather than eating the
  # sweeps' budget, so a slow relaunch never times the network checks out.
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=1 FM_FAKE_RELAUNCH_SLEEP=4 \
    FM_STARTUP_NETWORK_TIMEOUT=3 run_stage "$home" "$root" run --locked 1 --lock-pid $$
  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = 'done' ] \
    || fail "a relaunch longer than the stage budget starved the sweeps: $(run_stage "$home" "$root" report)"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_RELAUNCH_SLEEP=10 FM_REBOOT_RELAUNCH_TIMEOUT=1 \
    run_stage "$home" "$root" run --locked 1 --lock-pid $$
  assert_contains "$(run_stage "$home" "$root" report)" \
    "REBOOT_RELAUNCH: the dead-worker relaunch hit its 1s bound" "a wedged relaunch step was not reported"
  pass "fm-startup-network: the dead-worker relaunch runs first in locked work only, and its failures are reported"
}

# The cases are independent: each builds its own world under a unique name, and
# every background process it starts is bound to that world's home. Most of the
# suite is spent waiting on real worker sleeps and the stage's one-second `wait`
# poll, so the cases run in a bounded pool, the longest first.
# FM_STARTUP_NETWORK_CASE_JOBS overrides the concurrency (1 runs them serially).
build_template_bin
POOL_CASES=(
  test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget
  test_a_newer_generation_ends_the_older_delivery_wait
  test_the_delivery_wait_stays_within_its_birth_bound
  test_the_delivery_deadline_wakes_while_the_claimant_lives
  test_a_lock_held_through_the_delivery_wait_still_wakes
  test_a_dropped_delivery_wakes_within_a_second
  test_dead_worker_relaunch_runs_only_in_locked_work_and_reports_its_failures
  test_start_returns_without_holding_the_callers_stdout
  test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease
  test_locked_start_is_not_satisfied_by_an_inflight_probe
  test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it
  test_deferred_invalid_secondmate_markers_queue_durable_findings
  test_start_is_single_flight
  test_new_lock_owner_does_not_reuse_the_previous_owners_worker
  test_the_stage_bound_is_reported_not_swallowed
  test_a_report_publication_failure_is_failed_and_still_wakes
  test_start_reserves_its_generation_before_returning
  test_a_successful_result_never_queues_a_wake
  test_an_actionable_successful_result_still_queues_a_wake
  test_a_claimant_crash_after_publish_still_queues_the_wake
  test_mutating_sweeps_are_refused_when_the_lock_changed_hands
  test_a_bounded_run_still_publishes_the_timings_it_managed_to_record
  test_timings_are_published_and_only_the_on_demand_report_prints_them
  test_the_timing_artifact_cannot_carry_a_command_line_or_forge_records
  test_an_abandoned_run_reads_as_needing_a_rerun
  test_wait_fails_without_a_published_stage
  test_records_share_one_origin_so_offsets_form_a_timeline
)
case_jobs=$(fm_case_pool_jobs "${FM_STARTUP_NETWORK_CASE_JOBS:-}")
fm_run_case_pool "$case_jobs" "$TMP_ROOT/.case-logs" "${POOL_CASES[@]}" || exit 1
echo "# fm-startup-network.test.sh: all assertions passed"
