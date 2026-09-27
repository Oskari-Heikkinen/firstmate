#!/usr/bin/env bash
# fm-reboot-relaunch.sh: the session-start relaunch of recorded workers whose
# agent died while their local copy and record survived.
#
# Hermetic: a stateful tmux fake (the pane's current command decides whether an
# agent is alive) and a stateful herdr fake modelling a restarted server whose
# panes survived as bare shells - the machine-reboot shape. The relaunch itself
# runs through the real bin/fm-control.sh and bin/fm-spawn.sh.
#   1. A proven-dead worker is relaunched once, with a note that says the
#      machine restarted and points at its resume note or quotes its status.
#   2. A second run in the same boot does not relaunch again.
#   3. Declared waiters, finished work, deliberate stops, and anything whose
#      proof is ambiguous stay stopped and are listed.
#   4. Only a lock holder relaunches, the opt-out holds, and plan never acts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAUNCH="$ROOT/bin/fm-reboot-relaunch.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-reboot-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

reboot_cleanup() {
  local d home token
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] || continue
    fm_test_remove_tree "$d"
    # The spawn also stages each launch under /tmp/fm-<id>+<home token>, the
    # token being the sha256 of the case home's physical path.
    for home in "$TMP_ROOT"/*/home; do
      [ -d "$home" ] || continue
      token=$(printf '%s' "$(cd "$home" && pwd -P)" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
      fm_test_remove_tree "$d+$token"
    done
  done
  fm_test_remove_tree "$TMP_ROOT"
}
trap reboot_cleanup EXIT

# The lifecycle-modelling tmux fake from tests/fm-control-relaunch.test.sh,
# trimmed to what a relaunch touches: the exit command leaves a bare shell, and
# a delivered launch brief starts the harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: fmses" >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> <id> [kind]: a home with one tmux-recorded worker whose pane
# survived as a bare shell - the agent is gone. Echoes the case dir.
new_case() {
  local id=$2 kind=${3:-ship} dir="$TMP_ROOT/$1-$RANDOM"
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$dir/fake" "$dir/user-home"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  fm_git_worktree "$proj" "$wt" "task-$id" >/dev/null 2>&1
  printf '%s' "$wt" > "$dir/fake/cwd"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the session-start relaunch for $id.

## Firstmate spec
Resume the work after a restart.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=$kind"
    if [ "$kind" = ship ]; then
      echo "mode=no-mistakes"
      echo "yolo=off"
    fi
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$dir"
}

status() {  # <case-dir> <id> <line>
  printf '%s\n' "$3" >> "$1/home/state/$2.status"
}

run_tool() {  # <case-dir> <args...>
  local dir=$1; shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_REBOOT_RELAUNCH_BOOT_ID="${BOOT:-boot-a}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.5 \
    "$@" 2>&1
}

run_relaunch() {  # <case-dir> [extra args...]
  local dir=$1; shift
  run_tool "$dir" "$RELAUNCH" run --lock-pid "$$" "$@"
}

launches() {  # <case-dir>
  grep -cE 'encode launch-brief|Firstmate operational input waiting: read' "$1/fake/literal" 2>/dev/null || true
}

track() {  # <id>
  TASK_TMPS+=("/tmp/fm-$1")
}

# --- 1. relaunch ---------------------------------------------------------------

test_dead_worker_relaunches_from_its_resume_note() {
  local dir out rc=0 brief
  track rr1
  dir=$(new_case resume rr1)
  status "$dir" rr1 "paused [key=reboot] [at=1790000000]: reboot-safe; resume note written"
  printf 'Step 3 of 5 done; next: wire the parser.\n' > "$dir/home/data/rr1/resume.md"

  out=$(run_relaunch "$dir") || rc=$?

  expect_code 0 "$rc" "the relaunch step should succeed"$'\n'"$out"
  assert_contains "$out" "BOOTSTRAP_INFO: reboot relaunch: relaunched rr1" "the relaunch should be reported"
  assert_contains "$out" "resume from $dir/home/data/rr1/resume.md" "the report should name the resume source"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a replacement agent should be running"
  [ "$(launches "$dir")" = 1 ] || fail "exactly one launch should have been delivered"
  assert_no_grep '/exit' "$dir/fake/literal" "a dead agent must not be sent an exit command"
  brief=$(cat "$dir/home/data/rr1/brief.md")
  assert_contains "$brief" "The machine restarted" "the note should say the machine restarted"
  assert_contains "$brief" "Read your resume note first and continue from it: $dir/home/data/rr1/resume.md" \
    "the note should point at the resume note"
  assert_contains "$brief" "paused [key=reboot]" "the note should quote the newest status line"
  assert_grep 'result=relaunched' "$dir/home/state/rr1.reboot-relaunch" "the attempt should be recorded"
  pass "reboot relaunch: a dead worker with a reboot-safe pause and resume note is relaunched from that note"
}

test_second_run_in_the_same_boot_does_not_relaunch_again() {
  local dir out
  track rr2
  dir=$(new_case idem rr2)
  status "$dir" rr2 "working [at=1790000000]: implementing the parser"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "relaunched rr2" "the first run should relaunch"$'\n'"$out"
  assert_contains "$(cat "$dir/home/data/rr2/brief.md")" "working [at=1790000000]: implementing the parser" \
    "without a resume note the note should quote the last status"

  # The replacement dies too, in the same boot.
  printf 'zsh' > "$dir/fake/command"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "BOOTSTRAP_INFO: reboot relaunch: left rr2 stopped: an automatic relaunch was already attempted since this machine started" \
    "a second run in the same boot must not relaunch again"$'\n'"$out"
  [ "$(launches "$dir")" = 1 ] || fail "the second run must not deliver another launch"

  # After another reboot the task is eligible again.
  out=$(BOOT=boot-b run_relaunch "$dir")
  assert_contains "$out" "relaunched rr2" "a new boot should allow one more relaunch"$'\n'"$out"
  [ "$(launches "$dir")" = 2 ] || fail "the new boot should deliver exactly one more launch"
  pass "reboot relaunch: idempotent within a boot, eligible again after the next one"
}

test_alive_worker_is_untouched_and_silent() {
  local dir out
  track rr3
  dir=$(new_case alive rr3)
  printf 'claude' > "$dir/fake/command"
  status "$dir" rr3 "working: busy"
  out=$(run_relaunch "$dir")
  [ -z "$out" ] || fail "a running worker should produce no output, got: $out"
  out=$(run_tool "$dir" "$RELAUNCH" plan)
  [ -z "$out" ] || fail "plan should print nothing when every worker runs, got: $out"
  [ ! -s "$dir/fake/literal" ] || fail "nothing may be typed into a running worker"
  assert_absent "$dir/home/state/rr3.reboot-relaunch" "no attempt is recorded for a running worker"
  pass "reboot relaunch: a running (even idle) worker is left alone"
}

test_handoff_done_relaunches_but_ready_done_stays_stopped() {
  local dir out
  track rr4
  dir=$(new_case handoff rr4)
  status "$dir" rr4 "done [at=1790000000]: implemented the parser"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "relaunched rr4" "a no-mistakes handoff done still needs its worker"$'\n'"$out"

  track rr5
  dir=$(new_case ready rr5)
  status "$dir" rr5 "done [at=1790000000]: PR https://example.test/pr/5 checks green"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "BOOTSTRAP_INFO: reboot relaunch: left rr5 stopped: it reported its finished work" \
    "a ready PR needs no live worker"$'\n'"$out"
  [ "$(launches "$dir")" = 0 ] || fail "a ready ship must not be relaunched"
  pass "reboot relaunch: a handoff done is relaunched, a ready PR stays stopped"
}

# --- 2. left stopped -------------------------------------------------------------

test_declared_waits_and_finished_scouts_stay_stopped() {
  local dir out past future
  track rr6
  dir=$(new_case wait rr6)
  status "$dir" rr6 "paused [at=1790000000]: waiting for the upstream release"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "left rr6 stopped: it declared a wait: waiting for the upstream release" \
    "a declared wait stays stopped"$'\n'"$out"
  [ "$(launches "$dir")" = 0 ] || fail "a declared waiter must not be relaunched"
  assert_absent "$dir/home/state/rr6.reboot-relaunch" "a deliberate stop records no attempt"

  future=$(date -u -d "@$(( $(date +%s) + 86400 ))" +%Y-%m-%dT%H:%MZ 2>/dev/null \
    || date -u -r "$(( $(date +%s) + 86400 ))" +%Y-%m-%dT%H:%MZ)
  track rr7
  dir=$(new_case until-future rr7)
  status "$dir" rr7 "paused: rate limit resets until $future"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "left rr7 stopped: it declared a wait until $future" \
    "a wait with a future until stays stopped"$'\n'"$out"

  past=2020-01-01T00:00Z
  track rr8
  dir=$(new_case until-past rr8)
  status "$dir" rr8 "paused: rate limit resets until $past"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "relaunched rr8" "a wait whose until has passed needs its worker back"$'\n'"$out"

  track rr9
  dir=$(new_case scout rr9 scout)
  status "$dir" rr9 "done: report written"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "left rr9 stopped: a done scout awaiting cleanup" \
    "a done scout stays stopped"$'\n'"$out"

  track rr10
  dir=$(new_case failed rr10)
  status "$dir" rr10 "failed: tests cannot run here"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "left rr10 stopped: it reported failure" "a failed worker stays stopped"$'\n'"$out"
  pass "reboot relaunch: declared waits, done scouts, and failures stay stopped and are listed"
}

test_ambiguous_or_broken_records_are_left_for_recovery() {
  local dir out
  track rr11
  dir=$(new_case no-wt rr11)
  status "$dir" rr11 "working: x"
  rm -rf "$dir/wt"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "REBOOT_RELAUNCH: rr11: left stopped: its recorded local copy $dir/wt is missing" \
    "a missing local copy is actionable"$'\n'"$out"

  track rr12
  dir=$(new_case no-source rr12)
  out=$(run_relaunch "$dir")
  assert_contains "$out" "REBOOT_RELAUNCH: rr12: left stopped: it has neither a resume note" \
    "nothing to resume from is actionable"$'\n'"$out"

  track rr13
  dir=$(new_case tmux-missing rr13)
  status "$dir" rr13 "working: x"
  : > "$dir/fake/session-missing"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "REBOOT_RELAUNCH: rr13: left stopped: its tmux endpoint is missing" \
    "a tmux endpoint that vanished cannot be proven gone"$'\n'"$out"

  track rr14
  dir=$(new_case half-done rr14)
  status "$dir" rr14 "working: x"
  printf 'v1\ntask=rr14\nphase=launching\n' > "$dir/home/state/rr14.control-relaunch"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "REBOOT_RELAUNCH: rr14: left stopped: an earlier relaunch stopped part-way (phase launching)" \
    "an interrupted relaunch transaction is actionable"$'\n'"$out"

  [ "$(launches "$dir")" = 0 ] || fail "nothing ambiguous may be relaunched"
  pass "reboot relaunch: missing copies, missing resume sources, unprovable endpoints, and interrupted relaunches are listed for recovery"
}

test_deliberate_exit_stays_stopped_until_relaunched_by_hand() {
  local dir out
  track rr15
  dir=$(new_case exited rr15)
  status "$dir" rr15 "working: x"
  printf 'claude' > "$dir/fake/command"
  out=$(run_tool "$dir" "$CONTROL" rr15 exit)
  assert_contains "$out" "stopped rr15" "the exit should stop the agent"$'\n'"$out"
  assert_present "$dir/home/state/rr15.control-exit" "exit should record the deliberate stop"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "left rr15 stopped: firstmate stopped this worker deliberately" \
    "a deliberate exit must not be revived"$'\n'"$out"

  out=$(run_tool "$dir" "$CONTROL" rr15 relaunch --note "resume")
  assert_contains "$out" "relaunched rr15" "a hand relaunch should still work"$'\n'"$out"
  assert_absent "$dir/home/state/rr15.control-exit" "a completed relaunch clears the deliberate stop"
  pass "reboot relaunch: a deliberate exit is honored, and a hand relaunch clears it"
}

test_secondmates_and_remote_records_are_never_touched() {
  local dir out
  track rr16
  dir=$(new_case secondmate rr16)
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/home/state/rr16.meta"
  status "$dir" rr16 "working: x"
  out=$(run_relaunch "$dir")
  [ -z "$out" ] || fail "a secondmate belongs to its own liveness sweep, got: $out"

  track rr17
  dir=$(new_case remote rr17)
  printf 'remote_host=elsewhere\n' >> "$dir/home/state/rr17.meta"
  status "$dir" rr17 "working: x"
  out=$(run_relaunch "$dir")
  [ -z "$out" ] || fail "a remotely placed record is never read here, got: $out"
  pass "reboot relaunch: only this home's own local ship and scout records are considered"
}

# --- 3. authority, opt-out, plan -------------------------------------------------

test_only_the_lock_holder_relaunches() {
  local dir out rc=0
  track rr18
  dir=$(new_case unlocked rr18)
  status "$dir" rr18 "working: x"
  printf '1\n' > "$dir/home/state/.lock"
  out=$(run_relaunch "$dir") || rc=$?
  expect_code 1 "$rc" "a caller whose lock owner is gone must be refused"
  assert_contains "$out" "does not hold the fleet lock" "the refusal should say why"
  [ "$(launches "$dir")" = 0 ] || fail "a refused caller must not relaunch anything"
  pass "reboot relaunch: a session that does not hold the lock relaunches nothing"
}

test_opt_out_and_unknown_switch_values_relaunch_nothing() {
  local dir out
  track rr19
  dir=$(new_case off rr19)
  status "$dir" rr19 "working: x"
  printf 'off\n' > "$dir/home/config/reboot-relaunch"
  out=$(run_relaunch "$dir")
  [ -z "$out" ] || fail "an opted-out home relaunches nothing and says nothing, got: $out"
  out=$(run_tool "$dir" "$RELAUNCH" plan)
  assert_contains "$out" "relaunch rr19:" "plan still shows what it would do"
  assert_contains "$out" "config/reboot-relaunch is off" "plan names the opt-out"

  printf 'of\n' > "$dir/home/config/reboot-relaunch"
  out=$(run_relaunch "$dir")
  assert_contains "$out" "REBOOT_RELAUNCH: config/reboot-relaunch holds 'of'" \
    "a mistyped switch disables relaunch and says so"$'\n'"$out"
  [ "$(launches "$dir")" = 0 ] || fail "an opted-out home must not relaunch"
  pass "reboot relaunch: the opt-out holds, and a mistyped switch never relaunches"
}

test_plan_is_read_only_and_the_deadline_defers_starts() {
  local dir out
  track rr20
  dir=$(new_case plan rr20)
  status "$dir" rr20 "working: x"
  out=$(run_tool "$dir" "$RELAUNCH" plan)
  assert_contains "$out" "relaunch rr20: agent gone from its surviving tmux endpoint; resume from its newest status line" \
    "plan should name the relaunch"$'\n'"$out"
  [ ! -s "$dir/fake/literal" ] || fail "plan must never type into an endpoint"
  assert_absent "$dir/home/state/rr20.reboot-relaunch" "plan must record nothing"

  out=$(run_relaunch "$dir" --deadline 1)
  assert_contains "$out" "REBOOT_RELAUNCH: rr20: not attempted: the startup time bound was reached first" \
    "a passed deadline starts nothing"$'\n'"$out"
  assert_absent "$dir/home/state/rr20.reboot-relaunch" "an unattempted task stays eligible"
  [ "$(launches "$dir")" = 0 ] || fail "a passed deadline must not launch"
  pass "reboot relaunch: plan changes nothing, and a passed deadline leaves tasks for the next start"
}

# --- 4. herdr: the reboot shape --------------------------------------------------

# A restarted herdr server keeps its panes, which come back as bare shells.
make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  rm -f "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
  exit 0
fi
if [ "${1:-}" = server ]; then
  rm -f "$D/herdr-stopped"
  exit 0
fi
if [ -f "$D/herdr-stopped" ]; then
  echo 'error: could not connect to the herdr server' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pane get')
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${3:-}" "$(cat "$D/cwd")"
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%%7","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n'
    exit 0 ;;
  'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    printf '%s\n' "$payload" >> "$D/literal"
    case "$payload" in
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
}

test_herdr_pane_that_survived_a_server_restart_is_relaunched_in_place() {
  local dir out rc=0 meta
  command -v jq >/dev/null 2>&1 || { echo "skip - the herdr adapter needs jq"; return 0; }
  track rr21
  dir=$(new_case herdr rr21)
  meta="$dir/home/state/rr21.meta"
  sed -i.bak 's/^window=.*$/window=fmlab:%7/' "$meta"
  {
    echo "backend=herdr"
    echo "herdr_session=fmlab"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } >> "$meta"
  make_herdr_stub "$dir"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
  status "$dir" rr21 "paused [key=reboot]: reboot-safe"

  out=$(run_tool "$dir" "$RELAUNCH" plan)
  assert_contains "$out" "relaunch rr21: herdr endpoint missing, pending the relaunch's absence proof" \
    "plan must not start the server to prove anything"$'\n'"$out"
  assert_present "$dir/fake/herdr-stopped" "plan must leave the stopped server alone"

  out=$(run_relaunch "$dir") || rc=$?
  expect_code 0 "$rc" "the relaunch step should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rr21 (agent gone from its surviving herdr endpoint" \
    "the surviving pane's missing agent is the proof"$'\n'"$out"$'\n'"$(cat "$dir/fake/herdr-log")"
  assert_present "$dir/fake/herdr-agent-live" "the replacement should be running"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "tab create" "the surviving pane is reused, not replaced"
  [ "$(grep '^window=' "$meta" | tail -1)" = 'window=fmlab:%7' ] || fail "the endpoint record must not move"
  pass "reboot relaunch: a herdr pane that survived a server restart as a bare shell is relaunched in place"
}

test_dead_worker_relaunches_from_its_resume_note
test_second_run_in_the_same_boot_does_not_relaunch_again
test_alive_worker_is_untouched_and_silent
test_handoff_done_relaunches_but_ready_done_stays_stopped
test_declared_waits_and_finished_scouts_stay_stopped
test_ambiguous_or_broken_records_are_left_for_recovery
test_deliberate_exit_stays_stopped_until_relaunched_by_hand
test_secondmates_and_remote_records_are_never_touched
test_only_the_lock_holder_relaunches
test_opt_out_and_unknown_switch_values_relaunch_nothing
test_plan_is_read_only_and_the_deadline_defers_starts
test_herdr_pane_that_survived_a_server_restart_is_relaunched_in_place
