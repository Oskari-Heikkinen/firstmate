#!/usr/bin/env bash
# fm-send typed-plane settle pauses: the post-submit FM_SEND_SETTLE pause and
# the pre-submit popup-settle selection (the codex `$<skill>` fix).
#
# Post-submit pause (FM_SEND_SETTLE):
# A typed-plane fm-send success only proves the composer cleared - the Enter
# landed and the text was submitted. The harness then takes a beat to spin up the
# turn before its busy footer appears, so an immediate peek after fm-send returns
# would see the stale idle pane. fm-send therefore pauses FM_SEND_SETTLE seconds
# (default 1, 0 disables) after a successful typed submit, so the receiving turn
# has time to visibly start. These tests use an explicit backend target to stay on
# that plane and pin the behavior hermetically (stubbed tmux + sleep, no real
# agent):
#   1. A successful typed text send pauses for the FM_SEND_SETTLE value (default 1).
#   2. FM_SEND_SETTLE=0 produces no pause at all (sleep is never invoked for it).
#   3. The pause is tunable (FM_SEND_SETTLE=7 pauses 7).
#   4. The --key path never pauses (it bypasses the submit/settle path entirely).
#
# Pre-submit popup-settle selection:
# Some TUIs open a completion popup when the composer's first character triggers
# it: codex (and others) for a leading `/` slash command, and codex specifically
# for a leading `$<skill>` invocation (e.g. `$no-mistakes`). Submitting before the
# popup settles lets it swallow the Enter, so the line never submits. fm-send
# absorbs this by pausing `settle` seconds AFTER typing and BEFORE the (retried)
# Enter - the first sleep fm_tmux_submit_core makes. These cases pin the
# settle-SELECTION matrix hermetically (stubbed tmux + sleep, no real agent):
#
# The settle matrix governs the TYPED plane (harness-native invocations and
# explicit backend targets); a task-selector message that is not an invocation
# rides the durable inbox instead, where only the constant doorbell (fixed
# fast settle) touches the terminal:
#   /...            -> 1.2  (universal; `/` only starts a command, never plain text)
#   $... to codex   -> 1.2  (scoped: codex opens a `$<skill>` popup)
#   $... to claude  -> inbox plane (NOT codex: `$` commonly starts plain text)
#   $... explicit   -> 0.3  (session:window target has no meta -> harness unknown
#                            -> non-codex safe default, still typed)
#   plain text      -> inbox plane for a selector, 0.3 typed for an explicit target
#
# The popup-settle is the FIRST sleep recorded: fm_tmux_submit_core types the text,
# then `sleep "$settle"`, then the Enter-retry loop (sleep 0.4 each) and finally
# fm-send's own post-submit FM_SEND_SETTLE pause. So tail-vs-head matters: the
# popup cases assert on the HEAD sleep, distinct from the post-submit cases above
# which pin the TAIL pause. The retried Enter in fm_tmux_submit_core remains the
# real safety net; this settle is only the optimization that lets the popup clear so
# the first Enter lands.
#
# Every popup case passes a LITERAL `$<skill>` / `$price` message in single quotes
# on purpose - the whole point is to send an unexpanded `$...` line to the agent -
# so SC2016 (which flags single-quoted `$` as a probably-forgotten expansion) is a
# false positive there and is disabled for test_popup_settle_matrix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-settle)

# A fake tmux that lets fm-send's submit path reach a clean "empty" verdict, plus a
# fake sleep that records every requested duration (one per line) instead of
# sleeping. send-keys always succeeds; display-message yields a numeric cursor_y;
# capture-pane returns an empty bordered composer so fm_tmux_composer_state reads
# "empty" (submit landed) on the first Enter; list-windows prints FM_FAKE_WINDOWS
# when set. The sleep log path comes from FM_SLEEP_LOG.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -z "${FM_FAKE_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_WINDOWS"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <sleep-log> [env-assignments...] -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH. FM_ROOT_OVERRIDE points at a non-repo
# temp dir so fm-guard's tangle check stays silent, and FM_HOME at an empty home so
# no in-flight task is seen; guard noise goes to stderr (discarded). Echoes nothing;
# returns fm-send's exit code.
run_send() {
  local fb=$1 log=$2 home; shift 2
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  : > "$log"
  env "$@" PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" "hello captain" 2>/dev/null
}

test_default_send_pauses_one_second() {
  local dir fb log rc last
  dir="$TMP_ROOT/default"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log"; rc=$?
  expect_code 0 "$rc" "default send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 1 ] || fail "default send: expected a trailing 1s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: a successful text send pauses the default 1s after submit"
}

test_zero_disables_pause() {
  local dir fb log rc
  dir="$TMP_ROOT/zero"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=0; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=0 send should succeed"
  # The disable path must not invoke sleep with 0 at all - the only sleeps left are
  # the submit core's own settle/enter waits, none of which is "0".
  if grep -qx '0' "$log"; then
    fail "FM_SEND_SETTLE=0 still paused (a sleep 0 was recorded)"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: FM_SEND_SETTLE=0 produces no settle pause"
}

test_pause_is_tunable() {
  local dir fb log rc last
  dir="$TMP_ROOT/tunable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=7; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=7 send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 7 ] || fail "FM_SEND_SETTLE=7: expected a trailing 7s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the settle pause is tunable via FM_SEND_SETTLE"
}

test_key_path_never_pauses() {
  local dir fb log rc home
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "--key send should succeed"
  [ ! -s "$log" ] || fail "--key path paused but must not"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the --key path never pauses (settle scoped to text submit)"
}

test_claude_escape_records_interrupt_idle() {
  local dir fb log rc home gen out
  dir="$TMP_ROOT/claude-interrupt"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/task.meta" \
    "window=sess:win" "worktree=$home/wt" "project=$home/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" task)
  printf 'busy_gen=%s\n' "$gen" >> "$home/state/task.meta"
  : > "$log"

  env PATH="$fb:$PATH" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" task --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "Claude Escape send should succeed"
  out=$(fm_busy_classify tmux sess:win claude task "$home/state")
  [ "$out" = "idle fm-interrupt" ] \
    || fail "Claude Escape must classify idle/fm-interrupt, got '$out'"
  pass "fm-send: a successful Claude Escape records the interrupt lifecycle edge"
}

# first_settle <expected> <label> <harness|--explicit> <message> [selector-form]: build a fresh
# home, send <message> to a target whose meta records <harness> (or to a bare
# session:window with NO meta when --explicit), and assert the FIRST recorded sleep
# (the popup-settle) equals <expected>. FM_SEND_SETTLE=0 strips the trailing
# post-submit pause so the log holds only the popup-settle plus the 0.4 Enter wait,
# keeping the head assertion crisp. FM_ROOT_OVERRIDE points at a non-repo dir so
# fm-guard's tangle check stays silent; its watcher-liveness note goes to stderr
# (discarded).
first_settle() {  # <expected> <label> <harness|--explicit> <message> [selector-form]
  local expected=$1 label=$2 harness=$3 msg=$4
  local selector_form=${5:-legacy}
  local dir fb log home target rc first meta_id
  dir="$TMP_ROOT/popup-case-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"; home="$dir"
  if [ "$harness" = --explicit ]; then
    target="sess:win"
  else
    case "$selector_form" in
      exact)
        target="popupcase"
        meta_id=popupcase
        ;;
      legacy)
        target="fm-popupcase"
        meta_id=popupcase
        ;;
      *)
        fail "$label: unknown selector form '$selector_form'"
        ;;
    esac
    fm_write_meta "$home/state/$meta_id.meta" "window=sess:win" "harness=$harness"
  fi
  : > "$log"
  env FM_SEND_SETTLE=0 FM_FAKE_WINDOWS=win PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "$target" "$msg" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  first=$(head -1 "$log")
  [ "$first" = "$expected" ] || fail "$label: expected popup-settle $expected, got '$first'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send popup-settle: $label -> ${expected}s"
}

# rides_inbox <label> <harness> <message>: a task-selector message that is NOT
# a harness-native invocation no longer types its payload at all - it rides
# the durable inbox, so no popup-settle question exists for it. Assert the
# routing (record enqueued, payload never typed) and that the doorbell's own
# fixed fast settle (0.3) is the first sleep, so the codex-scoped `$` rule can
# never regress into slowing plain text again.
rides_inbox() {  # <label> <harness> <message>
  local label=$1 harness=$2 msg=$3
  local dir fb log home rc first
  dir="$TMP_ROOT/popup-case-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"; home="$dir"
  fm_write_meta "$home/state/popupcase.meta" "window=sess:win" "harness=$harness"
  : > "$log"
  env FM_SEND_SETTLE=0 FM_FAKE_WINDOWS=win PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" fm-popupcase "$msg" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  grep -qF -- "$msg" "$home/state/popupcase.inbox/001.msg" \
    || fail "$label: the steer should be enqueued in the task inbox"
  first=$(head -1 "$log")
  [ "$first" = "0.3" ] || fail "$label: the doorbell ring should keep the fast settle, got '$first'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send popup-settle: $label -> inbox plane, fast doorbell"
}

# The popup-settle selection matrix. Each case passes a literal `$...` message.
# shellcheck disable=SC2016
test_popup_settle_matrix() {
  # Codex `$<skill>` gets the long settle so its `$` popup clears (the fix).
  first_settle 1.2 'codex $skill -> long settle' codex '$no-mistakes'

  # The same Codex `$<skill>` path must work when the target is addressed by exact
  # task id, not only by the legacy `fm-<id>` window label.
  first_settle 1.2 'codex $skill exact task id -> long settle' codex '$no-mistakes' exact

  # Same `$` message to claude is ordinary text there: it rides the inbox and
  # only the fast doorbell touches the terminal.
  rides_inbox 'claude $-message' claude '$no-mistakes'

  # `$`-prefixed plain text to claude (a price) is likewise ordinary text - the
  # regression the codex scoping exists to prevent can no longer slow it.
  rides_inbox 'claude "$5/month"' claude '$5/month is cheap'

  # An explicit session:window target has no meta, so the harness is unknown and
  # treated as non-codex: the safe default keeps the fast path even for a `$` message.
  first_settle 0.3 'explicit target $message -> fast path (unknown harness)' --explicit '$no-mistakes'

  # The `/` slash case stays universal and unchanged: long settle regardless of
  # harness (here a non-codex claude target).
  first_settle 1.2 'claude /command -> long settle (slash unchanged)' claude '/no-mistakes'

  # A `/` to codex is likewise still the long settle (slash path untouched).
  first_settle 1.2 'codex /command -> long settle (slash unchanged)' codex '/help'

  # Plain text to codex rides the inbox - the codex scope is `$`-prefixed only.
  rides_inbox 'codex plain text' codex 'just a normal steer'
}

test_default_send_pauses_one_second
test_zero_disables_pause
test_pause_is_tunable
test_key_path_never_pauses
test_claude_escape_records_interrupt_idle
test_popup_settle_matrix
