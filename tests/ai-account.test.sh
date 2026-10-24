#!/usr/bin/env bash
# ai-account's recorded fleet move, refusal paths, and unchanged login commands.
# Every login, process table, home, and lifecycle helper is a private fixture.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot ai-account)

new_case() {
  C="$TMP_ROOT/$1" H="$TMP_ROOT/$1/fleet" U="$TMP_ROOT/$1/user"
  mkdir -p "$H/state" "$H/config" "$H/data" "$C/bin" "$C/proc" \
    "$U/.pi/agent" "$U/.claude" "$U/.claude-work" "$U/.codex" "$U/.codex-work" \
    "$U/.config/ai-accounts/pi/anthropic" "$U/.config/ai-accounts/pi/openai-codex"
  local f
  for f in "$ROOT"/bin/*; do ln -s "$f" "$C/bin/${f##*/}"; done
  # Mutation runs select only a private copy, never rewrite the checkout.
  if [ -n "${FM_AI_ACCOUNT_TEST_SOURCE:-}" ]; then
    rm "$C/bin/fm-account.sh"
    cp "$FM_AI_ACCOUNT_TEST_SOURCE" "$C/bin/fm-account.sh"
  fi
  ln -s "$C/bin" "$H/bin"
  printf '{"anthropic":{"token":"old"},"openai-codex":{"token":"oa-old"},"other":{"keep":true}}\n' > "$U/.pi/agent/auth.json"
  printf '{"token":"new"}\n' > "$U/.config/ai-accounts/pi/anthropic/work.json"
  printf '{"token":"oa-new"}\n' > "$U/.config/ai-accounts/pi/openai-codex/work.json"
  printf 'old claude %s/.claude\nnew claude %s/.claude-work\n' "$U" "$U" > "$H/config/accounts"
  rm "$C/bin/fm-secondmate-restart.sh" "$C/bin/fm-control.sh" "$C/bin/fm-crew-state.sh"
  cat > "$C/bin/fm-secondmate-restart.sh" <<'SH'
#!/usr/bin/env bash
printf 'restart %s\n' "$*" >> "$FM_TEST_CALLS"
[ "${FM_TEST_RESTART_FAIL:-0}" = 0 ] || exit 1
for id in "$@"; do
  meta="$FM_HOME/state/$id.meta"
  home=$(awk -F= '$1 == "home" { print $2; exit }' "$meta")
  acct=$(cat "$home/config/account")
  for proc in "$FM_PROC_ROOT_OVERRIDE"/[0-9]*; do
    [ "$(readlink "$proc/cwd")" = "$home" ] || continue
    printf 'CLAUDE_CONFIG_DIR=%s/.claude-work\0FM_TASK_ID=%s\0' "$HOME" "$id" > "$proc/environ"
  done
  awk -F= '$1 != "account" && $1 != "claude_config_dir"' "$meta" > "$meta.tmp"
  printf 'account=%s\n' "$acct" >> "$meta.tmp"
  mv "$meta.tmp" "$meta"
done
SH
  cat > "$C/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s %s %s\n' "$FM_HOME" "$1" "$FM_SPAWN_ACCOUNT" >> "$FM_TEST_CALLS"
[ "${FM_TEST_CONTROL_FAIL:-0}" = 0 ] && [ "${FM_TEST_CONTROL_FAIL_ID:-}" != "$1" ] || exit 1
for proc in "$FM_PROC_ROOT_OVERRIDE"/[0-9]*; do
  [ "$(readlink "$proc/cwd")" = "${FM_TEST_CASE}/wt-$1" ] || continue
  printf 'CLAUDE_CONFIG_DIR=%s/.claude-work\0FM_TASK_ID=%s\0' "$HOME" "$1" > "$proc/environ"
done
meta="$FM_HOME/state/$1.meta"
awk -F= '$1 != "account" && $1 != "claude_config_dir"' "$meta" > "$meta.tmp"
printf 'account=%s\n' "$FM_SPAWN_ACCOUNT" >> "$meta.tmp"
mv "$meta.tmp" "$meta"
SH
  cat > "$C/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/$1.ready" ]; then
  echo 'state: working · source: status-log'
else
  echo 'state: busy · source: harness'
fi
SH
  chmod +x "$C/bin/fm-secondmate-restart.sh" "$C/bin/fm-control.sh" "$C/bin/fm-crew-state.sh"
}

run_ai() {
  env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_SPAWN_ACCOUNT \
    FM_HOME="$H" HOME="$U" FM_PROC_ROOT_OVERRIDE="$C/proc" FM_TEST_CALLS="$C/calls" FM_TEST_CASE="$C" \
    "$H/bin/ai-account.sh" "$@" 2>&1
}

add_ship() { # <home> <id> [harness]
  mkdir -p "$C/wt-$2"
  fm_write_meta "$1/state/$2.meta" "kind=ship" "harness=${3:-claude}" \
    "worktree=$C/wt-$2" "account=old"
}

add_mate() {
  M="$C/mate"
  mkdir -p "$M/state" "$M/config"
  fm_write_secondmate_meta "$H/state/mate.meta" "$M" '' alpha claude
  printf 'account=old\n' >> "$H/state/mate.meta"
  printf 'old\n' > "$M/config/account"
  cp "$H/config/accounts" "$M/config/accounts"
}

add_proc() { # <id> <login-dir> [cwd]
  local pid=101
  while [ -d "$C/proc/$pid" ]; do pid=$((pid + 1)); done
  mkdir -p "$C/proc/$pid"
  echo claude > "$C/proc/$pid/comm"
  ln -s "$(cd -P "${3:-$C/wt-$1}" && pwd)" "$C/proc/$pid/cwd"
  printf 'CLAUDE_CONFIG_DIR=%s\0FM_TASK_ID=%s\0' "$2" "$1" > "$C/proc/$pid/environ"
}

assert_old_login() {
  assert_equals old "$(jq -r '.anthropic.token' "$U/.pi/agent/auth.json")" "a refusal must not switch Pi's login"
  assert_absent "$C/calls" "a preflight refusal must not relaunch reports"
}

test_move_records_login_mates_and_both_homes_workers() {
  local out rc
  new_case recorded
  add_mate
  add_ship "$H" stopped
  add_ship "$M" child
  add_ship "$H" codex codex
  out=$(run_ai move claude work); rc=$?
  expect_code 0 "$rc" "$out"
  assert_equals work "$(cat "$U/.config/ai-accounts/active-claude")" "the machine login changes"
  assert_equals new "$(jq -r '.anthropic.token' "$U/.pi/agent/auth.json")" "Pi's Claude login changes"
  assert_equals oa-old "$(jq -r '.["openai-codex"].token' "$U/.pi/agent/auth.json")" "the other provider is preserved"
  assert_equals new "$(cat "$M/config/account")" "the mate pin uses the root registry name"
  assert_grep 'account=new' "$H/state/mate.meta" "the restarted mate has a launch record"
  assert_grep 'account=new' "$H/state/stopped.meta" "a stopped direct worker is recorded"
  assert_grep 'account=new' "$M/state/child.meta" "a child uses the registered account"
  assert_grep '|login:claude|old|new|switched' "$H/state/account-moves.log" "the login switch is logged"
  assert_grep '|mate|old|new|moved' "$H/state/account-moves.log" "the mate move is logged"
  assert_grep '|stopped|old|new|recorded' "$H/state/account-moves.log" "the worker move is logged"
  assert_grep '|child|old|new|recorded' "$M/state/account-moves.log" "the child's move is logged in its home"
  assert_grep 'account=old' "$H/state/codex.meta" "non-Claude workers are untouched"
  assert_contains "$out" 'keeps its old Claude login' "the current session is never claimed moved"
  out=$(run_ai move claude work); rc=$?
  expect_code 0 "$rc" "repeat: $out"
  assert_equals 1 "$(wc -l < "$C/calls" | tr -d ' ')" "a repeated move does not restart the mate again"
  pass 'move records the machine switch, secondmate launch, and both homes workers; reruns converge'
}

test_move_preflight_refusals_leave_login_and_launches_untouched() {
  local reason out rc
  for reason in arity provider name registry saved folder remote child-registry child-account pin child-pin dangling-pin dangling-child-pin malformed-pin malformed-child-pin history root-history; do
    new_case "refuse-$reason"
    add_mate
    add_ship "$M" child
    case "$reason" in
      registry) echo 'broken' > "$H/config/accounts" ;;
      saved) rm "$U/.config/ai-accounts/pi/anthropic/work.json" ;;
      folder) rmdir "$U/.claude-work" ;;
      remote) echo 'remote_host=elsewhere' >> "$H/state/mate.meta" ;;
      child-registry) rm "$M/config/accounts" ;;
      child-account) printf 'new claude %s/.claude\n' "$U" > "$M/config/accounts" ;;
      pin) echo main > "$H/config/claude-account" ;;
      child-pin) echo main > "$M/config/claude-account" ;;
      dangling-pin) ln -s "$C/missing" "$H/config/claude-account" ;;
      dangling-child-pin) ln -s "$C/missing" "$M/config/claude-account" ;;
      malformed-pin) printf 'not a valid pin\n' > "$H/config/claude-account" ;;
      malformed-child-pin) printf 'not a valid pin\n' > "$M/config/claude-account" ;;
      history) mkdir "$M/state/account-moves.log" ;;
      root-history) mkdir "$H/state/account-moves.log" ;;
    esac
    case "$reason" in
      arity) out=$(run_ai move claude) ;;
      provider) out=$(run_ai move openai work) ;;
      name) out=$(run_ai move claude '../work') ;;
      *) out=$(run_ai move claude work) ;;
    esac
    rc=$?
    expect_code 1 "$rc" "$reason: $out"
    assert_old_login
    assert_equals old "$(cat "$M/config/account")" "$reason: the mate pin is unchanged"
    assert_grep 'account=old' "$M/state/child.meta" "$reason: the worker record is unchanged"
    assert_grep 'outcome=refused; reason=' "$H/state/account-move-events.status" "$reason: refusal is durable even with an unreadable history"
    assert_grep 'next=inspect' "$H/state/account-move-events.status" "$reason: refusal names recovery"
    assert_equals true "$(jq '.active | has("account-move-incomplete")' "$H/state/account-move-alerts.json")" "$reason: refusal holds a registered alarm"
    assert_grep 'status=account-move-events.status' "$H/state/alert-stores/account-move.reg" "$reason: the reader is registered"
    case "$reason" in
      dangling-pin) assert_equals "$C/missing" "$(readlink "$H/config/claude-account")" 'root pin is not removed' ;;
      dangling-child-pin) assert_equals "$C/missing" "$(readlink "$M/config/claude-account")" 'child pin is not removed' ;;
    esac
  done
  new_case no-helper
  rm "$C/bin/fm-account.sh"
  out=$(run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_contains "$out" 'missing' "a missing helper fails closed"
  assert_old_login
  pass 'invalid requests, missing registries/logins/helper, remote mates, pins and unwritable history refuse before switching'
}

test_busy_and_failed_moves_are_reported_and_retryable() {
  local out rc
  new_case busy
  add_ship "$H" busy
  add_proc busy "$U/.claude"
  out=$(run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_contains "$out" 'waiting: busy' "a running busy worker is not interrupted"
  assert_grep 'account=old' "$H/state/busy.meta" "a busy worker keeps its launch record"
  assert_grep '|busy|old|new|waiting' "$H/state/account-moves.log" "the wait is recorded"
  assert_grep 'outcome=waiting; reason=' "$H/state/account-move-events.status" 'a waiting outcome is delivered'
  assert_equals true "$(jq '.active | has("account-move-incomplete")' "$H/state/account-move-alerts.json")" 'waiting holds an alarm'
  touch "$H/state/busy.ready"
  out=$(run_ai move claude work); rc=$?
  expect_code 0 "$rc" "$out"
  assert_grep 'account=new' "$H/state/busy.meta" "retry moves an eligible worker"
  assert_grep '|busy|old|new|moved' "$H/state/account-moves.log" "retry logs a verified launch"
  assert_equals 0 "$(jq '.active | length' "$H/state/account-move-alerts.json")" 'successful retry clears the alarm'
  assert_grep 'outcome=done; reason=machine login' "$H/state/account-move-events.status" 'success has a durable outcome'

  new_case restart-fail
  add_mate
  out=$(FM_TEST_RESTART_FAIL=1 run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_grep 'account=old' "$H/state/mate.meta" "failed restart never falsifies the launch record"
  assert_grep '|mate|old|new|failed' "$H/state/account-moves.log" "failed restart is logged"

  new_case login-fail
  printf 'not json\n' > "$U/.config/ai-accounts/pi/anthropic/work.json"
  add_mate
  out=$(run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_old_login
  assert_grep '|login:claude|old|new|failed' "$H/state/account-moves.log" "a failed login swap is logged"
  pass 'busy workers wait, failed restarts remain honest, failed login swaps move no reports, and retries work'
}

test_live_identity_overrides_target_valued_records() {
  local out rc kind
  for kind in ship mate; do
    new_case "mismatch-$kind"
    if [ "$kind" = mate ]; then
      add_mate
      printf 'account=new\n' > "$C/target"
      awk '$0 != "account=old"' "$H/state/mate.meta" >> "$C/target"
      mv "$C/target" "$H/state/mate.meta"
      add_proc mate "$U/.claude" "$M"
      out=$(FM_TEST_RESTART_FAIL=1 run_ai move claude work); rc=$?
    else
      add_ship "$H" mismatch
      printf 'account=new\n' > "$C/target"
      awk '$0 != "account=old"' "$H/state/mismatch.meta" >> "$C/target"
      mv "$C/target" "$H/state/mismatch.meta"
      add_proc mismatch "$U/.claude"
      touch "$H/state/mismatch.ready"
      out=$(FM_TEST_CONTROL_FAIL=1 run_ai move claude work); rc=$?
    fi
    expect_code 1 "$rc" "$kind stale target record must not hide a failed live move: $out"
    assert_grep 'outcome=failed; reason=' "$H/state/account-move-events.status" 'live mismatch failure is delivered'
    out=$(run_ai move claude work); rc=$?
    expect_code 0 "$rc" "$kind retry: $out"
    assert_equals 2 "$(wc -l < "$C/calls" | tr -d ' ')" 'retry really invokes the guarded relaunch again'
    out=$(run_ai move claude work); rc=$?
    expect_code 0 "$rc" "$kind repeat after convergence: $out"
    assert_equals 2 "$(wc -l < "$C/calls" | tr -d ' ')" 'a proven target live login is idempotent'
  done
  pass 'live old-login workers and mates are retried despite target-valued metadata; failed restarts cannot claim success'
}

test_failed_direct_moves_preserve_completed_work_in_both_scopes() {
  local out rc owner
  for owner in root child; do
    new_case "mixed-$owner"
    if [ "$owner" = child ]; then add_mate; owner=$M; else owner=$H; fi
    add_ship "$owner" complete
    add_ship "$owner" broken
    add_ship "$owner" busy
    add_proc broken "$U/.claude"
    add_proc busy "$U/.claude"
    touch "$owner/state/broken.ready"
    out=$(FM_TEST_CONTROL_FAIL=1 run_ai move claude work); rc=$?
    expect_code 1 "$rc" "ready live control failure: $out"
    assert_grep 'account=old' "$owner/state/broken.meta" 'failed direct relaunch keeps its old record'
    assert_grep '|broken|old|new|failed' "$owner/state/account-moves.log" 'direct-worker failure is recorded'
    assert_grep 'account=new' "$owner/state/complete.meta" 'completed work survives partial failure'
    assert_grep '|busy|old|new|waiting' "$owner/state/account-moves.log" 'mixed waits are retained'
    assert_grep 'outcome=partial; reason=' "$H/state/account-move-events.status" 'partial completion is delivered'
    assert_grep 'outcome=failed; reason=error: broken' "$H/state/account-move-events.status" 'the direct failure itself is delivered'
    touch "$owner/state/busy.ready"
    out=$(run_ai move claude work); rc=$?
    expect_code 0 "$rc" "mixed retry: $out"
    assert_grep 'account=new' "$owner/state/broken.meta" 'retry moves the failed worker'
    assert_grep 'account=new' "$owner/state/busy.meta" 'retry moves the waiting worker'
    assert_no_grep 'control .* complete ' "$C/calls" 'completed work is never relaunched by retry'
    assert_equals 0 "$(jq '.active | length' "$H/state/account-move-alerts.json")" 'the final success clears only the move alarm'
  done
  pass 'failed ready direct-worker relaunches propagate nonzero and retry both ownership scopes without undoing completed work'
}

run_store() {
  env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
    "$H/bin/fm-alert-store.sh" "$@" 2>&1
}

assert_event_wake() {
  local out rc
  # No real endpoint or lifecycle operation: only fixture status delivery.
  rm -f "$H/state/"*.meta
  out=$(env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
    FM_BACKEND=tmux FM_PROC_ROOT_OVERRIDE="$C/proc" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$H/bin/fm-watch-checkpoint.sh" --seconds 15 2>&1); rc=$?
  expect_code 0 "$rc" "automatic outcome wake: $out"
  assert_contains "$out" 'account-move-events' 'the builtin watcher reader wakes without manual status polling'
}

test_outcome_delivery_and_projection_retry() {
  local out rc
  new_case delivery-done
  out=$(run_ai move claude work); rc=$?
  expect_code 0 "$rc" "$out"
  assert_grep 'next=manually restart' "$H/state/account-move-events.status" 'success names the remaining action'
  assert_event_wake

  new_case delivery-refused
  add_mate
  printf 'remote_host=elsewhere\n' >> "$H/state/mate.meta"
  out=$(run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_grep 'remote second mate' "$H/state/account-move-events.status" 'remote refusal reason is durable'
  assert_event_wake

  new_case delivery-history
  mkdir "$H/state/account-moves.log"
  out=$(run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_grep 'cannot write .*account-moves.log' "$H/state/account-move-events.status" 'history failure does not suppress its alarm'
  assert_event_wake

  new_case delivery-retry
  mkdir "$H/state/account-move-events.status"
  out=$(run_ai move claude work); rc=$?
  expect_code 1 "$rc" "$out"
  assert_old_login
  assert_equals true "$(jq '.active | has("account-move-incomplete")' "$H/state/account-move-alerts.json")" 'failed event append leaves the alarm active'
  rmdir "$H/state/account-move-events.status"
  touch "$H/state/account-move-events.status"
  out=$(run_store tick); rc=$?
  expect_code 0 "$rc" "$out"
  assert_grep 'blocked .*account-move-incomplete.*outcome delivery failed' "$H/state/account-move-events.status" 'the registered tick retries failed delivery'
  assert_event_wake
  out=$(run_ai move claude work); rc=$?
  expect_code 0 "$rc" "$out"
  out=$(run_store tick); rc=$?
  expect_code 0 "$rc" "$out"
  assert_grep 'resolved .*account-move-incomplete' "$H/state/account-move-events.status" 'only successful completion closes the projected alarm'
  pass 'success, refusals and unreadable-history failures wake automatically; a failed append is retried through the registered alert store'
}

test_other_subcommands_keep_machine_login_behavior() {
  local out rc
  new_case other
  out=$(run_ai status); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" 'claude  active: main' "status still lists the active Claude login"
  out=$(run_ai use openai work); rc=$?
  expect_code 0 "$rc" "$out"
  assert_equals oa-new "$(jq -r '.["openai-codex"].token' "$U/.pi/agent/auth.json")" "use still switches OpenAI"
  assert_equals old "$(jq -r '.anthropic.token' "$U/.pi/agent/auth.json")" "use preserves Claude"
  out=$(run_ai use claude work); rc=$?
  expect_code 0 "$rc" "$out"
  assert_equals new "$(jq -r '.anthropic.token' "$U/.pi/agent/auth.json")" "use still switches Claude directly"
  out=$(run_ai use claude work)
  assert_contains "$out" 'already on work' "use remains idempotent"
  out=$(run_ai use claude missing); rc=$?
  expect_code 1 "$rc" "$out"
  assert_absent "$H/state/account-moves.log" "plain use and status do not invoke the fleet move"
  out=$(run_ai --help)
  assert_contains "$out" 'ai-account add' "help keeps the other command entries"
  pass 'status, use for both providers, saved-login refusal, and help retain their behavior'
}

test_add_quota_and_overview_keep_their_interfaces() {
  local out rc
  new_case add-quota
  mkdir -p "$U/.local/npm/bin" "$C/fakebin"
  cat > "$U/.local/npm/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '{"fake":true}\n' > "$CLAUDE_CONFIG_DIR/.credentials.json"
SH
  cat > "$U/.local/npm/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '{"fake":true}\n' > "$CODEX_HOME/auth.json"
SH
  cat > "$U/.local/npm/bin/pi" <<'SH'
#!/usr/bin/env bash
printf '{"anthropic":{"token":"added"},"openai-codex":{"token":"oa-added"}}\n' > "$PI_CODING_AGENT_DIR/auth.json"
SH
  cat > "$C/fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"fake":true}\n'
SH
  cat > "$C/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$C/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
echo active
SH
  printf 'import sys\nprint("  " + sys.argv[1] + ": quota fixture")\n' > "$U/.config/ai-accounts/quota-line.py"
  chmod +x "$U/.local/npm/bin/claude" "$U/.local/npm/bin/codex" "$U/.local/npm/bin/pi" \
    "$C/fakebin/quota-axi" "$C/fakebin/ps" "$C/fakebin/systemctl"
  out=$(run_ai add claude extra); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" 'Saved account extra for claude' "add still completes Claude's two logins"
  assert_equals added "$(jq -r .token "$U/.config/ai-accounts/pi/anthropic/extra.json")" "add saves Claude's private Pi login"
  out=$(run_ai add openai extra); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" 'Saved account extra for openai' "add still completes OpenAI's two logins"
  assert_equals oa-added "$(jq -r .token "$U/.config/ai-accounts/pi/openai-codex/extra.json")" "add saves OpenAI's private Pi login"
  out=$(PATH="$C/fakebin:$PATH" run_ai quota); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" 'extra: quota fixture' "quota visits saved Claude logins"
  assert_contains "$out" 'OpenAI:' "quota still includes OpenAI"
  out=$(PATH="$C/fakebin:$PATH" run_ai); rc=$?
  expect_code 0 "$rc" "$out"
  assert_contains "$out" 'Running now:' "no argument still shows the overview"
  assert_contains "$out" 'Automatic watch' "overview retains its timer status"
  assert_old_login
  assert_absent "$H/state/account-moves.log" "add, quota and overview do not move fleet records"
  pass 'add for both providers, quota and the default overview retain their behavior'
}

test_move_records_login_mates_and_both_homes_workers
test_move_preflight_refusals_leave_login_and_launches_untouched
test_busy_and_failed_moves_are_reported_and_retryable
test_live_identity_overrides_target_valued_records
test_failed_direct_moves_preserve_completed_work_in_both_scopes
test_outcome_delivery_and_projection_retry
test_other_subcommands_keep_machine_login_behavior
test_add_quota_and_overview_keep_their_interfaces
printf '# all ai-account tests passed\n'
