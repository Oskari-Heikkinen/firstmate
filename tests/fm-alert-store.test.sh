#!/usr/bin/env bash
# Tests for fm-alert-store.sh and the alert-store protection in the decision fold.
#
# On 2026-10-20 a relaunch note closed tetjet-mate's
# `blocked [key=tj-capacity-unread]` six minutes after it was raised, and the
# tool that raised it posts each alarm only once, so the alarm stayed muted.
# test_relaunch_never_closes_a_store_alarm is that drill (V-d): the alarm is
# raised in a registered store, a relaunch note arrives, the blocker stays open
# in both folds, and when something else does close it one tick puts it back.
# A key that is not a reserved prefix is protected only because a registration
# names a store holding it, which is the point: ownership comes from
# registration, not from how the key is spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

STORE_BIN="$ROOT/bin/fm-alert-store.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-alert-store-tests)

# make_home <name>: a home with a ship task `t` and an empty status file.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/tool"
  printf 'kind=ship\n' > "$home/state/t.meta"
  printf 'working: started\n' > "$home/state/t.status"
  printf '%s\n' "$home"
}

store_cli() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$STORE_BIN" "$@"
}

supersede_blockers() {  # <state> <status> <kind> <evidence>
  (. "$ROOT/bin/fm-wake-lib.sh"; fm_status_supersede_blockers "$@")
}

open_keys() {  # <status-file>: the keys the whole-file fold holds open
  status_open_decisions "$1" | cut -f1
}

open_keys_incremental() {  # <status-file>
  (status_open_decisions_incremental "$1") | cut -f1
}

line_count() {
  wc -l < "$1" | tr -d ' '
}

test_relaunch_never_closes_a_store_alarm() {
  local home f store before out
  home=$(make_home vd)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  store_cli "$home" assert "$store" tj-capacity tj-capacity-unread "fresh filler status cannot be read" >/dev/null \
    || fail "assert failed"
  store_cli "$home" register "$store" tj-capacity t.status tetjet-mate >/dev/null || fail "register failed"
  printf 'blocked [key=tj-capacity-unread]: fresh filler status cannot be read\n' >> "$f"
  printf 'blocked [key=net]: network down\n' >> "$f"

  supersede_blockers "$home/state" "$f" relaunch "relaunched after reboot" || fail "the relaunch writer failed"
  assert_contains "$(grep supersedes "$f")" "superseded open blockers: net" "the relaunch note did not name the ordinary blocker"
  assert_not_contains "$(grep supersedes "$f")" "tj-capacity-unread" "the relaunch note named a store-held blocker"
  printf 'note [supersedes=resume]: resumed from the relaunch note\n' >> "$f"
  assert_contains "$(open_keys "$f")" "tj-capacity-unread" "a supersede note closed a store-held blocker (whole-file fold)"
  assert_contains "$(open_keys_incremental "$f")" "tj-capacity-unread" "a supersede note closed a store-held blocker (incremental fold)"
  assert_not_contains "$(open_keys "$f")" "net" "the supersede note did not close the ordinary blocker"
  assert_contains "$(status_own_open_decisions "$f")" "tj-capacity-unread" "a store-held alarm stopped counting as an open decision of the task"

  before=$(line_count "$f")
  out=$(store_cli "$home" tick) || fail "a quiet tick failed"
  assert_equals "" "$out" "a quiet tick printed something"
  assert_equals "$before" "$(line_count "$f")" "a tick re-posted an alarm that was still open"

  printf 'resolved [key=tj-capacity-unread]: closed by hand\n' >> "$f"
  assert_not_contains "$(open_keys "$f")" "tj-capacity-unread" "the hand close did not close the blocker"
  store_cli "$home" tick >/dev/null || fail "the re-posting tick failed"
  assert_contains "$(tail -n 1 "$f")" "blocked [key=tj-capacity-unread] [at=" "one tick did not re-post the muted alarm"
  assert_contains "$(tail -n 1 "$f")" "(alert store tj-capacity)" "the re-posted line does not name its store"
  assert_contains "$(open_keys "$f")" "tj-capacity-unread" "the re-posted alarm is not open"
  assert_contains "$(cat "$home/state/alert-stores.log")" "re-posted alert tj-capacity-unread from store tj-capacity" \
    "the log does not record the re-post"
  before=$(line_count "$f")
  store_cli "$home" tick >/dev/null || fail "the second tick failed"
  assert_equals "$before" "$(line_count "$f")" "a second tick posted the alarm again"
  pass "a relaunch never closes a store alarm, and one tick restores it after any other close"
}

test_reserved_prefix_alarm_is_reposted_in_its_vocabulary() {
  local home f store
  home=$(make_home reserved)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  store_cli "$home" assert "$store" tj handoff-tj-idle "queue dry" >/dev/null || fail "assert failed"
  store_cli "$home" register "$store" tj t.status >/dev/null || fail "register failed"
  store_cli "$home" tick >/dev/null || fail "tick failed"
  assert_contains "$(open_keys "$f")" "handoff-tj-idle" "a reserved-prefix alarm posted by the tick did not open"
  pass "a re-posted reserved-prefix alarm speaks that prefix's vocabulary"
}

test_clear_closes_the_blocker_on_the_next_tick() {
  local home f store before
  home=$(make_home clear)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  store_cli "$home" assert "$store" s lane-down "lane refused" >/dev/null || fail "assert failed"
  store_cli "$home" register "$store" s t.status >/dev/null || fail "register failed"
  store_cli "$home" tick >/dev/null || fail "the raising tick failed"
  assert_contains "$(open_keys "$f")" "lane-down" "the tick did not raise the alarm"
  store_cli "$home" assert "$store" s lane-down "lane refused again" >/dev/null || fail "a repeat assert failed"
  assert_equals 1 "$(jq '[.events[] | select(.action == "raised")] | length' "$store")" "a repeat assert wrote a second raise"

  store_cli "$home" clear "$store" s lane-down "lane healthy" >/dev/null || fail "clear failed"
  store_cli "$home" tick >/dev/null || fail "the closing tick failed"
  assert_contains "$(tail -n 1 "$f")" "resolved [key=lane-down] [at=" "the tick did not close the cleared alarm"
  assert_contains "$(tail -n 1 "$f")" "cleared in alert store s" "the close does not say the store cleared it"
  assert_not_contains "$(open_keys "$f")" "lane-down" "the cleared alarm is still open"
  before=$(line_count "$f")
  store_cli "$home" tick >/dev/null || fail "the quiet tick failed"
  assert_equals "$before" "$(line_count "$f")" "a tick wrote again after the alarm was closed"
  store_cli "$home" clear "$store" s lane-down "still healthy" >/dev/null || fail "clearing an inactive key failed"
  pass "clearing the store closes the blocker on the next tick, once"
}

test_sync_makes_the_active_set_equal_the_wanted_set() {
  local home f store want revision
  home=$(make_home sync)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  want="$home/tool/want.json"
  store_cli "$home" assert "$store" s old-alarm "gone soon" >/dev/null || fail "assert failed"
  store_cli "$home" register "$store" s t.status >/dev/null || fail "register failed"
  store_cli "$home" tick >/dev/null || fail "the raising tick failed"
  printf '{"new-alarm":{"kind":"no-receipt","subject":"p/s/r1","reason":"no receipt","since":"2026-10-20T10:00:00Z","evidence":{"path":"/x"}}}\n' > "$want"
  store_cli "$home" sync "$store" s "$want" "no longer wanted" >/dev/null || fail "sync failed"
  assert_equals '["new-alarm"]' "$(jq -c '.active | keys' "$store")" "sync did not make the active set equal the wanted set"
  assert_equals "no-receipt p/s/r1 2026-10-20T10:00:00Z /x" \
    "$(jq -r '.active["new-alarm"] | "\(.kind) \(.subject) \(.since) \(.evidence.path)"' "$store")" "sync lost a wanted field"
  assert_equals "no longer wanted" "$(jq -r '[.events[] | select(.action == "cleared")][0].reason' "$store")" "the clear does not carry the reason"
  store_cli "$home" tick >/dev/null || fail "the projecting tick failed"
  assert_contains "$(open_keys "$f")" "new-alarm" "the tick did not raise the synced alarm"
  assert_not_contains "$(open_keys "$f")" "old-alarm" "the tick did not close the alarm sync cleared"
  revision=$(jq '.revision' "$store")
  store_cli "$home" sync "$store" s "$want" "no longer wanted" >/dev/null || fail "a repeat sync failed"
  assert_equals "$revision" "$(jq '.revision' "$store")" "a repeat sync raised or cleared again"
  printf '{"Bad Key":{"reason":"x"}}\n' > "$want"
  if store_cli "$home" sync "$store" s "$want" "x" >/dev/null 2>&1; then fail "sync accepted a key that is not a slug"; fi
  assert_equals '["new-alarm"]' "$(jq -c '.active | keys' "$store")" "a refused sync changed the store"
  pass "sync raises, refreshes and clears in one write, and a refused wanted set changes nothing"
}

test_acknowledgement_hides_until_expiry() {
  local home f store rc tmp
  home=$(make_home ack)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  store_cli "$home" assert "$store" s disk-low "disk below 10 GiB" >/dev/null || fail "assert failed"
  store_cli "$home" register "$store" s t.status >/dev/null || fail "register failed"
  store_cli "$home" tick >/dev/null || fail "the raising tick failed"

  for rc in 0 604801 soon; do
    if store_cli "$home" ack "$store" s disk-low "$rc" firstmate "quiet" >/dev/null 2>&1; then
      fail "an acknowledgement of $rc seconds was accepted"
    fi
  done
  if store_cli "$home" ack "$store" s no-such-key 600 firstmate "quiet" >/dev/null 2>&1; then
    fail "an acknowledgement of an inactive key was accepted"
  fi
  store_cli "$home" ack "$store" s disk-low 600 firstmate "cleanup scheduled" >/dev/null || fail "ack failed"
  store_cli "$home" tick >/dev/null || fail "the acknowledging tick failed"
  assert_contains "$(tail -n 1 "$f")" "acknowledged by firstmate until " "the tick did not close the acknowledged alarm"
  assert_not_contains "$(open_keys "$f")" "disk-low" "the acknowledged alarm is still open"
  assert_equals true "$(jq '.active | has("disk-low")' "$store")" "the acknowledgement cleared the alarm"

  # Let the acknowledgement lapse without waiting for it.
  tmp="$store.tmp"
  jq '.acks["disk-low"].until = "2000-01-01T00:00:00Z"' "$store" > "$tmp" && mv "$tmp" "$store"
  store_cli "$home" tick >/dev/null || fail "the post-expiry tick failed"
  assert_contains "$(tail -n 1 "$f")" "blocked [key=disk-low] [at=" "the alarm did not come back after its acknowledgement expired"
  assert_contains "$(open_keys "$f")" "disk-low" "the expired acknowledgement still hides the alarm"
  pass "an acknowledgement hides an active alarm only until its expiry"
}

# A tool writing its own store cannot hide an alarm for longer than the ack
# command allows: an over-long, future-dated or unparseable ack hides nothing.
test_invalid_acknowledgement_hides_nothing() {
  local home f store out bad
  home=$(make_home badack)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  store_cli "$home" register "$store" s t.status >/dev/null || fail "register failed"
  for bad in \
    '{"by":"tool","at":"2026-10-20T08:00:00Z","until":"2099-01-01T00:00:00Z"}' \
    '{"by":"tool","at":"2099-01-01T00:00:00Z","until":"2099-01-02T00:00:00Z"}' \
    '{"by":"tool","at":"soon","until":"2099-01-01T00:00:00Z"}' \
    '"forever"'; do
    printf '{"schema":"fm-alert-store/v1","store":"s","revision":1,"active":{"disk-low":{"key":"disk-low","reason":"disk below 10 GiB"}},"acks":{"disk-low":%s},"events":[]}\n' "$bad" > "$store"
    out=$(store_cli "$home" tick) || fail "the tick failed on ack $bad"
    assert_contains "$out" "the acknowledgement of disk-low is ignored" "an invalid ack was not reported: $bad"
    assert_contains "$(open_keys "$f")" "disk-low" "an invalid ack hid the alarm: $bad"
  done
  printf '{"schema":"fm-alert-store/v1","store":"s","revision":1,"active":{"disk-low":{"key":"disk-low","reason":"disk below 10 GiB"}},"acks":{"disk-low":{"by":"tool","at":"2000-01-01T00:00:00Z","until":"2000-03-01T00:00:00Z"}},"events":[]}\n' > "$store"
  out=$(store_cli "$home" tick) || fail "the tick failed on a lapsed ack"
  assert_equals "" "$out" "an over-long ack that already lapsed was reported"
  pass "an acknowledgement outside the format's limits hides nothing and is reported"
}

test_unreadable_store_raises_and_holds() {
  local home f store out log_lines
  home=$(make_home unreadable)
  f="$home/state/t.status"
  store="$home/tool/alerts.json"
  printf '{"schema":"fm-alert-store/v1","active":' > "$store"
  store_cli "$home" register "$store" broken t.status >/dev/null || fail "register failed"
  printf 'blocked [key=tool-alarm]: something the store may hold\n' >> "$f"

  supersede_blockers "$home/state" "$f" relaunch "relaunched" || fail "the relaunch writer failed"
  printf 'note [supersedes=relaunch]: relaunched by hand\n' >> "$f"
  assert_contains "$(open_keys "$f")" "tool-alarm" "a supersede note closed a blocker while its store was unreadable"
  assert_contains "$(status_own_open_decisions "$f")" "tool-alarm" "an unreadable store hid a blocker from the task's own decisions"

  out=$(store_cli "$home" tick) || fail "the tick failed on an unreadable store"
  assert_contains "$out" "alert store broken:" "the tick did not report the unreadable store"
  assert_contains "$out" "is not a valid" "the problem line does not say why"
  out=$(store_cli "$home" tick) || fail "the second tick failed"
  assert_contains "$out" "alert store broken:" "the problem was reported only once"
  log_lines=$(grep -c 'problem: alert store broken' "$home/state/alert-stores.log")
  assert_equals 1 "$log_lines" "the log repeated an unchanged problem"

  printf '{"schema":"fm-alert-store/v1","store":"broken","revision":0,"active":{},"events":[]}\n' > "$store"
  out=$(store_cli "$home" tick) || fail "the recovered tick failed"
  assert_equals "" "$out" "a readable store still reports a problem"
  assert_contains "$(cat "$home/state/alert-stores.log")" "reads cleanly again" "the log does not record the recovery"
  pass "an unreadable store is a problem on every tick and holds its blockers open"
}

test_invalid_registration_raises() {
  local home out
  home=$(make_home badreg)
  mkdir -p "$home/state/alert-stores"
  printf 'schema=fm-alert-registration/v1\nstore=other\npath=relative.json\nstatus=t.status\n' \
    > "$home/state/alert-stores/mine.reg"
  out=$(store_cli "$home" tick) || fail "the tick failed"
  assert_contains "$out" "registration $home/state/alert-stores/mine.reg" "an invalid registration was skipped silently"
  printf 'blocked [key=tool-alarm]: something the registration may own\n' >> "$home/state/t.status"
  printf 'note [supersedes=relaunch]: relaunched\n' >> "$home/state/t.status"
  assert_contains "$(open_keys "$home/state/t.status")" "tool-alarm" "a supersede note closed a blocker an invalid registration may own"
  assert_contains "$(status_own_open_decisions "$home/state/t.status")" "tool-alarm" "an invalid registration hid a blocker from the task's own decisions"
  printf 'kind=ship\n' > "$home/state/u.meta"
  printf 'blocked [key=other]: unrelated\nnote [supersedes=relaunch]: relaunched\n' > "$home/state/u.status"
  assert_not_contains "$(open_keys "$home/state/u.status")" "other" "an invalid registration for t.status protected another status file"
  rm -f "$home/state/alert-stores/mine.reg"
  ln -s "$home/no-such.reg" "$home/state/alert-stores/mine.reg"
  printf 'blocked [key=link-alarm]: something a dangling registration may own\n' >> "$home/state/t.status"
  printf 'note [supersedes=relaunch]: relaunched again\n' >> "$home/state/t.status"
  assert_contains "$(open_keys "$home/state/t.status")" "link-alarm" "a dangling registration link protected nothing"
  out=$(store_cli "$home" tick) || fail "the tick failed"
  assert_contains "$out" "registration $home/state/alert-stores/mine.reg cannot be read" "a dangling registration link was not reported"
  printf 'schema=fm-alert-registration/v1\nstore=gone\npath=%s\nstatus=missing.status\n' "$home/tool/alerts.json" \
    > "$home/state/alert-stores/gone.reg"
  out=$(store_cli "$home" tick) || fail "the tick failed"
  assert_contains "$out" "missing.status, which does not exist" "a missing status file was not reported"
  pass "an invalid registration holds its status file's blockers and is reported, as is a missing status file"
}

test_unregistered_keys_keep_todays_behaviour() {
  local home f store out
  home=$(make_home unregistered)
  f="$home/state/t.status"
  printf 'blocked [key=tj-capacity-unread]: no store here\n' >> "$f"
  printf 'note [supersedes=relaunch]: relaunched\n' >> "$f"
  assert_not_contains "$(open_keys "$f")" "tj-capacity-unread" "a key with no registration was protected by its spelling"

  store="$home/tool/alerts.json"
  store_cli "$home" assert "$store" s other-alarm "held" >/dev/null || fail "assert failed"
  store_cli "$home" register "$store" s t.status >/dev/null || fail "register failed"
  printf 'blocked [key=worker-key]: the worker raised this\n' >> "$f"
  store_cli "$home" tick >/dev/null || fail "tick failed"
  printf 'note [supersedes=relaunch]: relaunched again\n' >> "$f"
  assert_not_contains "$(open_keys "$f")" "worker-key" "a key the store never named was protected"
  assert_contains "$(open_keys "$f")" "other-alarm" "the store's own key was not protected"

  printf 'blocked [key=worker-key]: raised again\n' >> "$f"
  printf 'resolved [key=worker-key]: fixed\n' >> "$f"
  store_cli "$home" tick >/dev/null || fail "tick failed"
  assert_not_contains "$(open_keys "$f")" "worker-key" "the tick reopened a key its store never named"

  printf 'blocked [key=worker-key]: raised a third time\n' >> "$f"
  out=$(store_cli "$home" unregister s) || fail "unregister failed"
  assert_contains "$out" "closed 1 open alert(s)" "unregister did not report what it closed"
  assert_contains "$(tail -n 1 "$f")" "other-alarm: alert store s unregistered" "unregister did not close its store's blocker"
  assert_not_contains "$(open_keys "$f")" "other-alarm" "the store's blocker outlived its registration (whole-file fold)"
  assert_not_contains "$(open_keys_incremental "$f")" "other-alarm" "the store's blocker outlived its registration (incremental fold)"
  assert_contains "$(open_keys "$f")" "worker-key" "unregister closed a key its store never named"
  [ ! -e "$home/state/alert-stores/s.reg" ] || fail "unregister left the registration"
  out=$(store_cli "$home" unregister s) || fail "a repeat unregister failed"
  assert_contains "$out" "is not registered" "a repeat unregister did not say so"
  pass "keys no registered store holds open and close as before, and unregister closes its own"
}

test_tj_capacity_store_registers_unchanged() {
  local home f store
  home=$(make_home tjshape)
  f="$home/state/t.status"
  store="$home/tool/capacity-state.json"
  printf '%s\n' '{"schema":"tj-capacity-alerts/v1","at":"2026-10-20T08:14:00Z","revision":1,"active":{"tj-idle":{"key":"tj-idle","kind":"tj-idle","subject":"tetjet","reason":"no running-count rise for 60 min","since":"2026-10-20T08:14:00Z","detected_at":"2026-10-20T08:14:00Z","evidence":{}}},"events":[{"seq":1,"at":"2026-10-20T08:14:00Z","action":"raised","key":"tj-idle","alert":{}}]}' > "$store"
  mkdir -p "$home/state/alert-stores"
  printf 'schema=fm-alert-registration/v1\nstore=tj-capacity\npath=%s\nstatus=t.status\nowner=tetjet-mate\n' "$store" \
    > "$home/state/alert-stores/tj-capacity.reg"
  store_cli "$home" tick >/dev/null || fail "tick failed"
  assert_contains "$(tail -n 1 "$f")" "blocked [key=tj-idle] [at=" "a tj-capacity-alerts/v1 store was not projected"
  assert_contains "$(tail -n 1 "$f")" "no running-count rise for 60 min" "the projection lost the store's reason"
  if store_cli "$home" clear "$store" tj-capacity tj-idle "not mine" >/dev/null 2>&1; then
    fail "the library wrote a store another tool owns"
  fi
  pass "a tj-capacity-alerts/v1 store registers and projects unchanged"
}

test_tick_that_cannot_lock_says_so() {
  local home store out holder
  home=$(make_home lockheld)
  store="$home/tool/alerts.json"
  store_cli "$home" assert "$store" s lane-down "lane refused" >/dev/null || fail "assert failed"
  store_cli "$home" register "$store" s t.status >/dev/null || fail "register failed"
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" && exec sleep 30' _ \
    "$ROOT" "$home/state/alert-stores/.tick.lock" &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  holder=$!
  for _ in $(seq 1 50); do
    [ -d "$home/state/alert-stores/.tick.lock" ] && break
    sleep 0.1
  done
  out=$(store_cli "$home" tick) || fail "a tick that could not lock failed"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  assert_contains "$out" "alert-store tick could not take" "a tick that could not lock was silent"
  assert_not_contains "$(open_keys "$home/state/t.status")" "lane-down" "a tick that could not lock still posted"
  pass "a tick that cannot take its lock checks nothing and says so"
}

test_watcher_wakes_on_a_store_problem() {
  local home store out status
  # No task here, so the only thing that can wake the watcher is the tick.
  home="$TMP_ROOT/watcher"
  mkdir -p "$home/state" "$home/config" "$home/tool"
  store="$home/tool/alerts.json"
  printf 'not json\n' > "$store"
  store_cli "$home" register "$store" broken t.status >/dev/null || fail "register failed"
  out="$home/checkpoint.out"
  status=0
  env FM_HOME="$home" FM_CHECK_TIMEOUT=30 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 > "$out" 2>"$home/checkpoint.err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check: alert-stores: alert store broken " "the watcher did not wake on the store problem"
  pass "the watcher runs the tick in its slow-check step and wakes on a problem"
}

# A tick the check timeout kills prints no problem line of its own; the watcher
# must still wake, because an unchecked store is unknown, not quiet. A jq shim
# that hangs only on this store's path stands in for a slow fold or jq.
test_watcher_wakes_on_a_tick_that_never_finishes() {
  local home store out status shim real_jq
  home="$TMP_ROOT/watcher-hang"
  mkdir -p "$home/state" "$home/config" "$home/tool" "$home/shim"
  store="$home/tool/alerts.json"
  printf '{"schema":"fm-alert-store/v1","store":"slow","revision":0,"active":{},"events":[]}\n' > "$store"
  store_cli "$home" register "$store" slow t.status >/dev/null || fail "register failed"
  printf 'working: started\n' > "$home/state/t.status"
  real_jq=$(command -v jq) || fail "jq is required"
  shim="$home/shim/jq"
  # shellcheck disable=SC2016  # the shim expands its own "$@" and $a.
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = %q ] && exec sleep 60; done\nexec %q "$@"\n' "$store" "$real_jq" > "$shim"
  chmod +x "$shim"
  out="$home/checkpoint.out"
  status=0
  env PATH="$home/shim:$PATH" FM_HOME="$home" FM_CHECK_TIMEOUT=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 15 > "$out" 2>"$home/checkpoint.err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check: alert-stores: alert-store tick did not finish within 2s" \
    "the watcher stayed quiet when the tick was killed"
  pass "the watcher wakes when the tick does not finish"
}

test_relaunch_never_closes_a_store_alarm
test_reserved_prefix_alarm_is_reposted_in_its_vocabulary
test_clear_closes_the_blocker_on_the_next_tick
test_sync_makes_the_active_set_equal_the_wanted_set
test_acknowledgement_hides_until_expiry
test_invalid_acknowledgement_hides_nothing
test_unreadable_store_raises_and_holds
test_invalid_registration_raises
test_unregistered_keys_keep_todays_behaviour
test_tj_capacity_store_registers_unchanged
test_tick_that_cannot_lock_says_so
test_watcher_wakes_on_a_store_problem
test_watcher_wakes_on_a_tick_that_never_finishes
