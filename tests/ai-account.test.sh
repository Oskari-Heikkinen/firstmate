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
  awk -F= '$1 != "account" && $1 != "claude_config_dir"' "$meta" > "$meta.tmp"
  printf 'account=%s\n' "$acct" >> "$meta.tmp"
  mv "$meta.tmp" "$meta"
done
SH
  cat > "$C/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf 'control %s %s %s\n' "$FM_HOME" "$1" "$FM_SPAWN_ACCOUNT" >> "$FM_TEST_CALLS"
[ "${FM_TEST_CONTROL_FAIL:-0}" = 0 ] || exit 1
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
    FM_HOME="$H" HOME="$U" FM_PROC_ROOT_OVERRIDE="$C/proc" FM_TEST_CALLS="$C/calls" \
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

add_proc() { # <id> <login-dir>
  mkdir -p "$C/proc/101"
  echo claude > "$C/proc/101/comm"
  ln -s "$(cd -P "$C/wt-$1" && pwd)" "$C/proc/101/cwd"
  printf 'CLAUDE_CONFIG_DIR=%s\0FM_TASK_ID=%s\0' "$2" "$1" > "$C/proc/101/environ"
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
  for reason in provider name registry saved folder remote child-registry child-account pin child-pin history; do
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
      history) mkdir "$M/state/account-moves.log" ;;
    esac
    case "$reason" in
      provider) out=$(run_ai move openai work) ;;
      name) out=$(run_ai move claude '../work') ;;
      *) out=$(run_ai move claude work) ;;
    esac
    rc=$?
    expect_code 1 "$rc" "$reason: $out"
    assert_old_login
    assert_equals old "$(cat "$M/config/account")" "$reason: the mate pin is unchanged"
    assert_grep 'account=old' "$M/state/child.meta" "$reason: the worker record is unchanged"
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
  touch "$H/state/busy.ready"
  out=$(run_ai move claude work); rc=$?
  expect_code 0 "$rc" "$out"
  assert_grep 'account=new' "$H/state/busy.meta" "retry moves an eligible worker"
  assert_grep '|busy|old|new|moved' "$H/state/account-moves.log" "retry logs a verified launch"

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
test_other_subcommands_keep_machine_login_behavior
test_add_quota_and_overview_keep_their_interfaces
printf '# all ai-account tests passed\n'
