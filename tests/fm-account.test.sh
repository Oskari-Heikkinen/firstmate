#!/usr/bin/env bash
# Behavior tests for bin/fm-account.sh and the account choice bin/fm-spawn.sh
# makes through bin/fm-account-lib.sh.
#
# Every case runs against its own throwaway home and login folders. quota-axi,
# tmux, and herdr are PATH fakes: the fake quota tool answers from a small
# fixture file inside the login folder it was pointed at, so no case ever reads
# a real login, a real credential, or a real Herdr session.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ACCOUNT="$ROOT/bin/fm-account.sh"
TMP_ROOT=$(fm_test_tmproot fm-account)
unset FM_ACCOUNT_USAGE_TTL FM_ACCOUNT_QUOTA_TIMEOUT FM_ACCOUNT_PANEL_RATIO FM_SPAWN_ACCOUNT

# write_fake_quota <fakebin>: quota-axi that reads
# "<percent-left> <status> [<auth-status> [<full-status> <full-auth-status>]]"
# from <login-folder>/fake-quota (default "50 fresh") and logs each read to
# FM_FAKE_QUOTA_LOG as "<provider> <dir> <profile|full> <refresh|no-refresh>
# <token|no-token>". A --profile-only read answers <status> and <auth-status>;
# any other read is the classifier and answers <full-status> and
# <full-auth-status> (default: the same two), and writes the quota cache under
# XDG_CACHE_HOME the way the real tool does. "-" is an absent auth status.
# Status "garbage" prints unparseable output; any status other than fresh
# prints a row with no usage and exits nonzero, the way the real tool reports a
# login that needs sign-in.
write_fake_quota() {
  cat > "$1/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
provider= mode=full refresh=refresh
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider=$2; shift ;;
    --profile-only) mode=profile ;;
    --no-credential-refresh) refresh=no-refresh ;;
  esac
  shift
done
if [ "$provider" = codex ]; then dir=${CODEX_HOME:-}; else dir=${CLAUDE_CONFIG_DIR:-}; fi
[ -z "${FM_FAKE_QUOTA_LOG:-}" ] || printf '%s %s %s %s %s\n' "$provider" "$dir" "$mode" "$refresh" \
  "$([ -n "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] && echo token || echo no-token)" >> "$FM_FAKE_QUOTA_LOG"
left=50 status=fresh auth=- fstatus= fauth=
[ ! -f "$dir/fake-quota" ] || read -r left status auth fstatus fauth < "$dir/fake-quota"
if [ "$mode" = full ]; then
  status=${fstatus:-$status} auth=${fauth:-${auth:--}}
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/quota-axi"
  : > "${XDG_CACHE_HOME:-$HOME/.cache}/quota-axi/quotas.json"
fi
case "$status" in
  garbage) echo 'not json'; exit 0 ;;
  fresh)
    printf '{"providers":[{"provider":"%s","plan":"max","state":{"status":"fresh"},"windows":[{"id":"weekly","resetsAt":"2030-01-01T00:00:00.000+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":%s,"limitingWindowIds":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":7200}}]}}]}\n' "$provider" "$left"
    ;;
  *)
    if [ "${auth:--}" = - ]; then
      printf '{"providers":[{"provider":"%s","state":{"status":"%s"}}]}\n' "$provider" "$status"
    else
      printf '{"providers":[{"provider":"%s","state":{"status":"%s","authStatus":"%s"}}]}\n' "$provider" "$status" "$auth"
    fi
    exit 1
    ;;
esac
SH
  chmod +x "$1/quota-axi"
}

# write_dead_tmux <fakebin>: every endpoint this home recorded is gone.
write_dead_tmux() {
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/tmux"
}

# new_case <name>: a home with gmail (4% left), work (98%), and a codex login
# that needs sign-in. Sets C (case dir) and H (home).
new_case() {
  C="$TMP_ROOT/$1"
  H="$C/home"
  mkdir -p "$H/state" "$H/config" "$H/data" "$C/gmail" "$C/work" "$C/codex" "$C/user-home"
  fm_fakebin "$C" >/dev/null
  write_fake_quota "$C/fakebin"
  write_dead_tmux "$C/fakebin"
  printf '4 fresh\n' > "$C/gmail/fake-quota"
  printf '98 fresh\n' > "$C/work/fake-quota"
  printf '0 auth_required\n' > "$C/codex/fake-quota"
  {
    echo "# name provider login-folder priority"
    echo "gmail claude $C/gmail 1"
    echo "work claude $C/work 2"
    echo "codex codex $C/codex"
  } > "$H/config/accounts"
}

# run_account <args...>: the command as this case's main session, which runs on
# the gmail login unless FM_TEST_SESSION_DIR says otherwise.
run_account() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_BIN_PATH \
    -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_SPAWN_ACCOUNT \
    PATH="$C/fakebin:$PATH" FM_HOME="$H" HOME="$C/user-home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_SESSION_DIR-$C/gmail}" \
    FM_FAKE_QUOTA_LOG="$C/quota.log" \
    "$ACCOUNT" "$@" 2>&1
}

add_ship() {  # <id> [key=value...]
  local id=$1
  shift
  fm_write_meta "$H/state/$id.meta" "window=gone:fm-$id" "endpoint_task_id=$id" \
    "worktree=$C/wt-$id" "harness=claude" "kind=ship" "backend=tmux" "$@"
}

add_mate() {  # <id> <pinned-account-or-empty> [harness]
  local home="$C/mate-$1"
  mkdir -p "$home/state" "$home/config"
  fm_write_secondmate_meta "$H/state/$1.meta" "$home" "" alpha "${3:-claude}"
  [ -z "$2" ] || printf '%s\n' "$2" > "$home/config/account"
}

json_get() {  # <json> <jq filter>
  printf '%s' "$1" | jq -r "$2"
}

test_malformed_registry_refuses_and_the_check_says_so() {
  local out rc bad
  for bad in "gmail claude relative/dir" "gmail openai /tmp/x" "Gmail claude /tmp/x" \
    "gmail claude /tmp/x 1 extra" "gmail claude /tmp/x high"; do
    new_case malformed
    printf '%s\n' "$bad" > "$H/config/accounts"
    out=$(run_account status); rc=$?
    expect_code 1 "$rc" "status with registry line '$bad'"
    assert_contains "$out" "config/accounts" "the refusal should name the registry for '$bad'"
    out=$(run_account rebalance --check); rc=$?
    expect_code 0 "$rc" "the watcher form must not fail on '$bad'"
    assert_contains "$out" "accounts: config/accounts is malformed" "the watcher form should wake on '$bad'"
  done
  new_case duplicate
  printf 'work claude %s\n' "$C/gmail" >> "$H/config/accounts"
  out=$(run_account status); rc=$?
  expect_code 1 "$rc" "a duplicate name must refuse"
  assert_contains "$out" "names 'work' twice" "the duplicate should be named"
  pass "a malformed account registry refuses every command and wakes the watcher form"
}

test_status_attributes_every_agent_and_plans_moves() {
  local out rc
  new_case status
  add_ship a1 account=work
  add_ship a2
  add_ship c1 harness=codex
  add_mate sm1 work
  add_mate sm2 ''
  add_ship inner
  mv "$H/state/inner.meta" "$C/mate-sm1/state/inner.meta"
  out=$(run_account status --json); rc=$?
  expect_code 0 "$rc" "status --json"$'\n'"$out"
  assert_equals 10 "$(json_get "$out" .floor)" "the default floor"
  assert_equals "4|true|max" "$(json_get "$out" '.accounts[] | select(.name == "gmail") | "\(.percent_left)|\(.low)|\(.plan)"')" "gmail usage"
  assert_equals "98|false" "$(json_get "$out" '.accounts[] | select(.name == "work") | "\(.percent_left)|\(.low)"')" "work usage"
  assert_equals "auth_required|false" "$(json_get "$out" '.accounts[] | select(.name == "codex") | "\(.status)|\(.low)"')" "codex needs sign-in and is never low"
  assert_equals "main|gmail|session" "$(json_get "$out" '.agents[] | select(.kind == "session") | "\(.id)|\(.account)|\(.basis)"')" "this session runs on its own login"
  assert_equals "work|recorded" "$(json_get "$out" '.agents[] | select(.id == "a1") | "\(.account)|\(.basis)"')" "a recorded worker"
  assert_equals "gmail|inferred" "$(json_get "$out" '.agents[] | select(.id == "a2") | "\(.account)|\(.basis)"')" "an unrecorded worker follows its launcher"
  assert_equals "other" "$(json_get "$out" '.agents[] | select(.id == "c1") | .basis')" "a non-Claude worker"
  assert_equals "work|pinned" "$(json_get "$out" '.agents[] | select(.id == "sm1") | "\(.account)|\(.basis)"')" "a pinned second mate"
  assert_equals "gmail|inferred" "$(json_get "$out" '.agents[] | select(.id == "sm2") | "\(.account)|\(.basis)"')" "an unpinned second mate"
  assert_equals "sm1|work|false" "$(json_get "$out" '.agents[] | select(.id == "inner") | "\(.home)|\(.account)|\(.direct)"')" "a second mate's worker follows that mate"
  assert_equals "a2:gmail>work sm2:gmail>work" "$(json_get "$out" '[.moves[] | "\(.id):\(.from)>\(.to)"] | sort | join(" ")')" "every direct report on the low login moves to the one with room"
  assert_equals "gmail|work" "$(json_get "$out" '"\(.new_spawns.preferred)|\(.new_spawns.account)"')" "new spawns leave the low login"
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "restart this main session on work: exit it, then start it again with CLAUDE_CONFIG_DIR=$C/work" "the session's own restart is advice"
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "sign in to account codex" "a login needing sign-in is advice"
  out=$(run_account status)
  assert_contains "$out" "LOW" "the table should flag the low login"
  assert_contains "$out" "New spawns: work (gmail is below the floor)" "the table should say where new spawns go"
  assert_contains "$out" "Needs the captain: sign in to account codex" "the table should carry the sign-in"
  out=$(run_account watch --once)
  assert_contains "$out" "Moving automatically:" "one panel frame should show the planned moves"
  pass "status shows usage per login, who runs where, new-spawn routing, planned moves, and advice"
}

test_usage_is_cached_and_unknown_usage_never_moves_work() {
  local out
  new_case cache
  add_ship a2
  run_account status >/dev/null
  run_account status >/dev/null
  assert_equals 1 "$(grep -c "claude $C/gmail" "$C/quota.log")" "a second read inside the cache window should not ask again"
  run_account status --refresh >/dev/null
  assert_equals 2 "$(grep -c "claude $C/gmail" "$C/quota.log")" "--refresh should ask again"
  printf '0 garbage\n' > "$C/gmail/fake-quota"
  out=$(run_account status --json --refresh)
  assert_equals "unreadable|null|false" "$(json_get "$out" '.accounts[] | select(.name == "gmail") | "\(.status)|\(.percent_left)|\(.low)"')" "unreadable usage"
  assert_equals 0 "$(json_get "$out" '.moves | length')" "unknown usage must never move work"
  assert_equals gmail "$(json_get "$out" .new_spawns.account)" "unknown usage keeps new spawns where they are"
  pass "usage reads are cached, and unknown usage is never treated as low"
}

test_floor_and_priority_choose_the_account() {
  local out
  new_case floor
  printf '3\n' > "$H/config/account-floor"
  out=$(run_account status --json)
  assert_equals "false|gmail" "$(json_get "$out" '"\(.accounts[] | select(.name == "gmail") | .low)|\(.new_spawns.account)"')" "4% is above a 3% floor"
  printf '99\n' > "$H/config/account-floor"
  out=$(run_account status --json --refresh)
  assert_equals gmail "$(json_get "$out" .new_spawns.account)" "with no login above the floor nothing moves"
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "no Claude account has room above the 99% floor" "the captain hears that every login is low"
  printf '50\n' > "$H/config/account-floor"
  mkdir -p "$C/work2"
  printf '70 fresh\n' > "$C/work2/fake-quota"
  printf 'work2 claude %s 0\n' "$C/work2" >> "$H/config/accounts"
  out=$(run_account status --json --refresh)
  assert_equals "gmail|work2" "$(json_get "$out" '"\(.new_spawns.preferred)|\(.new_spawns.account)"')" "the lowest priority number with room wins"
  out=$(FM_TEST_SESSION_DIR='' run_account status --json)
  assert_equals "null|null" "$(json_get "$out" '"\(.new_spawns.preferred)|\(.new_spawns.account)"')" "a session on no registered login names no preference"
  pass "the floor file and registry priority decide which login has room"
}

test_rebalance_dry_run_and_check_wake_only_on_change() {
  local out rc
  new_case check
  add_ship a2
  out=$(run_account rebalance --dry-run); rc=$?
  expect_code 0 "$rc" "dry run"
  assert_contains "$out" "would move: a2 gmail -> work" "the dry run names the move"
  assert_contains "$out" "needs the captain: restart this main session on work" "the dry run carries the advice"
  out=$(run_account rebalance --check)
  assert_not_contains "$out" "a2 gmail->work" "a worker whose endpoint is gone is not between steps"
  assert_contains "$out" "needs the captain: restart this main session on work" "the first check wakes with the advice"
  out=$(run_account rebalance --check)
  assert_equals "" "$out" "an unchanged check must stay silent"
  add_mate sm2 ''
  out=$(run_account rebalance --check)
  assert_contains "$out" "accounts: sm2 gmail->work - run bin/fm-account.sh rebalance (automatic, no captain approval);" "a second mate on the low login wakes firstmate to move it"
  out=$(run_account rebalance --check)
  assert_equals "" "$out" "the same pending move stays quiet inside its repeat window"
  rm -f "$H/state/sm2.meta" "$H/state/a2.meta"
  printf '80 fresh\n' > "$C/gmail/fake-quota"
  printf '80 fresh\n' > "$C/codex/fake-quota"
  out=$(FM_ACCOUNT_USAGE_TTL=0 run_account rebalance --check)
  assert_equals "" "$out" "nothing to do stays silent"
  assert_present "$H/state/.account-check" "quiet advice keeps its fingerprint"
  rm -f "$H/config/accounts"
  out=$(run_account rebalance --check); rc=$?
  expect_code 0 "$rc" "no registry"
  assert_equals "" "$out" "a home without a registry never wakes"
  pass "rebalance --dry-run plans, and the watcher form wakes only when a move or advice changes"
}

test_use_pins_a_second_mate_and_refuses_what_it_cannot_move() {
  local out rc
  new_case use
  add_mate sm1 ''
  add_ship a2
  add_ship c1 harness=codex
  mkdir -p "$C/mate-remote"
  fm_write_secondmate_meta "$H/state/rm1.meta" "$C/mate-remote" "" alpha claude
  printf 'remote_host=far\n' >> "$H/state/rm1.meta"
  printf 'spare claude %s/never-signed-in\n' "$C" >> "$H/config/accounts"
  out=$(run_account use sm1 work --no-relaunch); rc=$?
  expect_code 0 "$rc" "pin"$'\n'"$out"
  assert_equals work "$(cat "$C/mate-sm1/config/account")" "the pin is recorded in the mate's home"
  assert_grep "|sm1|-|work|pinned" "$H/state/account-moves.log" "the pin is logged as a move"
  out=$(run_account status --json)
  assert_equals "work|pinned" "$(json_get "$out" '.agents[] | select(.id == "sm1") | "\(.account)|\(.basis)"')" "status reads the pin"
  out=$(run_account use main work); rc=$?
  expect_code 1 "$rc" "the session itself"
  assert_contains "$out" "cannot relaunch itself; exit it, then start it again with CLAUDE_CONFIG_DIR=$C/work" "the session gets a restart instruction"
  out=$(run_account use c1 work); rc=$?
  expect_code 1 "$rc" "non-Claude worker"
  assert_contains "$out" "runs on codex" "a non-Claude worker is refused"
  out=$(run_account use a2 codex); rc=$?
  expect_code 1 "$rc" "codex account"
  assert_contains "$out" "only Claude accounts can be switched" "a non-Claude login is refused"
  out=$(run_account use a2 nosuch); rc=$?
  expect_code 1 "$rc" "unknown account"
  assert_contains "$out" "account 'nosuch' is not registered" "an unknown account is refused"
  out=$(run_account use sm1 spare); rc=$?
  expect_code 1 "$rc" "missing login"
  assert_contains "$out" "sign in to account spare first" "a login that does not exist yet asks for sign-in"
  out=$(run_account use rm1 work); rc=$?
  expect_code 1 "$rc" "remote mate"
  assert_contains "$out" "remote second mate" "a remote mate is refused"
  out=$(run_account use a2 work); rc=$?
  expect_code 2 "$rc" "a worker that is not between steps"
  assert_contains "$out" "waiting: a2 is not between steps" "the worker waits for a later run"
  assert_no_grep "account=" "$H/state/a2.meta" "a waiting worker's record is untouched"
  out=$(run_account use a2 work --no-relaunch); rc=$?
  expect_code 1 "$rc" "--no-relaunch on a worker"
  pass "use pins a second mate durably and refuses the session, other providers, missing logins, and busy workers"
}

test_default_sets_and_clears_the_new_spawn_account() {
  local out rc
  new_case default
  printf '1 fresh\n' > "$C/work/fake-quota"
  out=$(run_account default work); rc=$?
  expect_code 0 "$rc" "default work"
  assert_equals work "$(cat "$H/config/spawn-account")" "the default is recorded"
  out=$(run_account status --json)
  assert_equals "work|work" "$(json_get "$out" '"\(.new_spawns.preferred)|\(.new_spawns.account)"')" "with every login low, new spawns stay on the default"
  out=$(run_account default codex); rc=$?
  expect_code 1 "$rc" "a codex default"
  out=$(run_account default --clear); rc=$?
  expect_code 0 "$rc" "clear"
  assert_absent "$H/config/spawn-account" "clear removes the default"
  pass "default records and clears the account new spawns start from"
}

test_auto_arms_and_retires_the_watcher_check() {
  local out rc
  new_case auto
  out=$(run_account auto sync); rc=$?
  expect_code 0 "$rc" "sync"$'\n'"$out"
  [ -x "$H/state/accounts.check.sh" ] || fail "sync should install an executable check"
  assert_present "$H/state/accounts.check-trust" "sync should register the check"
  out=$(env PATH="$C/fakebin:$PATH" HOME="$C/user-home" CLAUDE_CONFIG_DIR="$C/gmail" "$H/state/accounts.check.sh")
  assert_contains "$out" "needs the captain: restart this main session on work" "the installed check runs the watcher form for this home"
  out=$(run_account auto off); rc=$?
  expect_code 0 "$rc" "off"
  assert_absent "$H/state/accounts.check.sh" "off retires the check"
  assert_absent "$H/state/accounts.check-trust" "off retires its registration"
  run_account auto sync >/dev/null
  assert_absent "$H/state/accounts.check.sh" "sync honors off"
  run_account auto on >/dev/null
  assert_present "$H/state/accounts.check-trust" "on re-arms the check"
  rm -f "$H/config/accounts"
  run_account auto sync >/dev/null
  assert_absent "$H/state/accounts.check.sh" "a home without a registry has no check"
  pass "auto keeps the watcher check in step with the registry and the on/off setting"
}

test_panel_toggles_a_herdr_side_pane() {
  local out rc pid
  new_case panel
  out=$(run_account panel); rc=$?
  expect_code 0 "$rc" "outside Herdr"
  assert_contains "$out" "not inside a Herdr pane" "outside Herdr the panel explains itself"
  assert_contains "$out" "fm-account.sh watch" "and says what to run instead"
  cat > "$C/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
case "$1 $2" in
  'pane split') echo '{"result":{"pane":{"pane_id":"p9"}}}' ;;
esac
exit 0
SH
  chmod +x "$C/fakebin/herdr"
  out=$(env PATH="$C/fakebin:$PATH" FM_HOME="$H" HOME="$C/user-home" CLAUDE_CONFIG_DIR="$C/gmail" \
    HERDR_ENV=1 HERDR_PANE_ID=p1 HERDR_SESSION=lab-x HERDR_BIN_PATH="$C/fakebin/herdr" \
    FM_FAKE_HERDR_LOG="$C/herdr.log" FM_ACCOUNT_PANEL_RATIO=0.3 "$ACCOUNT" panel 2>&1); rc=$?
  expect_code 0 "$rc" "inside Herdr"$'\n'"$out"
  assert_contains "$out" "panel: open in pane p9" "the panel names its pane"
  assert_grep "pane split --pane p1 --direction right --no-focus" "$C/herdr.log" "the panel splits the caller's pane"
  assert_grep "--env FM_HOME=$H" "$C/herdr.log" "the panel pane serves this home"
  assert_grep "--env CLAUDE_CONFIG_DIR=$C/gmail" "$C/herdr.log" "the panel pane keeps the session's login"
  assert_grep "--ratio 0.3" "$C/herdr.log" "the ratio knob reaches the split"
  assert_grep "pane run p9" "$C/herdr.log" "the panel starts the watch loop in the new pane"
  assert_grep "fm-account.sh watch" "$C/herdr.log" "the new pane runs the watch loop"
  [ "$(grep -c -- '--session lab-x' "$C/herdr.log")" = 2 ] || fail "every Herdr call must name the caller's session"
  bash -c "exec -a 'fm-account.sh watch' sleep 30" &
  pid=$!
  printf '%s\n' "$pid" > "$H/state/.account-panel"
  out=$(run_account panel)
  assert_contains "$out" "panel: closed" "a second toggle closes the running panel"
  wait "$pid" 2>/dev/null
  kill -0 "$pid" 2>/dev/null && { kill "$pid"; fail "the running panel should have been stopped"; }
  pass "panel opens a Herdr side pane on the caller's session and a second toggle closes it"
}

# --- fm-spawn chooses the login -------------------------------------------

spawn_case() {  # <name> <id>
  local fakebin
  new_case "$1"
  fakebin=$(fm_test_make_spawn_fakebin "$C/spawnfake")
  write_fake_quota "$fakebin"
  SPAWN_FAKEBIN=$fakebin
  fm_git_worktree "$C/project" "$C/wt" "wt-$1"
  fm_test_spawn_home "$H" claude
  fm_test_spawn_brief "$H" "$2"
}

test_spawn_leaves_a_low_login_and_records_the_account() {
  local out rc
  spawn_case spawn-failover acct-s1
  out=$(FM_FAKE_LAUNCH_LOG="$C/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$C/gmail" \
    fm_test_run_spawn "$H" "$C/wt" "$SPAWN_FAKEBIN" acct-s1 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "spawn"$'\n'"$out"
  assert_contains "$out" "account: gmail has 4% left, below the 10% floor; this spawn uses work" "the spawn says it left the low login"
  assert_contains "$(cat "$C/launch.log")" "CLAUDE_CONFIG_DIR='$C/work' " "the worker launches on the login with room"
  assert_grep "account=work" "$H/state/acct-s1.meta" "the record carries the account"
  assert_grep "claude_config_dir=$C/work" "$H/state/acct-s1.meta" "the record carries the login folder"
  pass "a fresh spawn leaves a login below the floor and records the one it used"
}

test_spawn_refuses_an_unregistered_or_missing_login() {
  local out rc
  spawn_case spawn-refuse acct-s2
  printf 'nosuch\n' > "$H/config/spawn-account"
  out=$(FM_FAKE_LAUNCH_LOG="$C/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$C/gmail" \
    fm_test_run_spawn "$H" "$C/wt" "$SPAWN_FAKEBIN" acct-s2 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 1 "$rc" "an unregistered default"
  assert_contains "$out" "account 'nosuch' named by this home is not registered" "the refusal names the account"
  assert_absent "$H/state/acct-s2.meta" "a refused spawn leaves no record"
  printf 'spare claude %s/never-signed-in\n' "$C" >> "$H/config/accounts"
  out=$(FM_SPAWN_ACCOUNT=spare FM_FAKE_LAUNCH_LOG="$C/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$C/gmail" \
    fm_test_run_spawn "$H" "$C/wt" "$SPAWN_FAKEBIN" acct-s2 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 1 "$rc" "a login that does not exist"
  assert_contains "$out" "sign in to it first" "the refusal asks for sign-in"
  assert_absent "$H/state/acct-s2.meta" "a refused spawn leaves no record"
  pass "a spawn refuses rather than launching on a login other than the one named"
}

# classify_case <name> <gmail-fixture>: a case whose gmail login answers
# <gmail-fixture>, read once through status --json with an ambient env token.
# Sets OUT to that JSON.
classify_case() {
  new_case "$1"
  printf '%s\n' "$2" > "$C/gmail/fake-quota"
  mkdir -p "$C/tmp"
  OUT=$(CLAUDE_CODE_OAUTH_TOKEN=not-a-real-token XDG_CACHE_HOME="$C/user-home/.cache" TMPDIR="$C/tmp" run_account status --json)
}

gmail_status() {
  json_get "$OUT" '.accounts[] | select(.name == "gmail") | .status'
}

test_a_lapsed_login_reads_expired_not_signed_out() {
  local out
  classify_case lapsed-401 "0 auth_required - unavailable expired_refreshable"
  assert_equals expired "$(gmail_status)" "a 401 on a lapsed token that still renews is expired"
  assert_not_contains "$(json_get "$OUT" '.advice | join("\n")')" "sign in to account gmail" "an expired login is not a sign-in"
  assert_contains "$(cat "$C/quota.log")" "claude $C/gmail full no-refresh no-token" "the classifier read never refreshes and never sees an env token"
  assert_not_contains "$(cat "$C/quota.log")" "codex $C/codex full" "only Claude logins are classified"
  assert_absent "$C/user-home/.cache/quota-axi/quotas.json" "the classifier read never writes the shared quota cache"
  assert_equals "" "$(ls -A "$C/tmp")" "the classifier's throwaway cache is removed"
  out=$(run_account status)
  assert_contains "$out" "[expired: renews on next use]" "the table says an expired login renews on next use"
  classify_case lapsed-429 "0 rate_limited - unavailable expired_refreshable"
  assert_equals expired "$(gmail_status)" "a 429 on a lapsed token that still renews is expired too"
  classify_case no-refresh "0 auth_required - unavailable -"
  assert_equals auth_required "$(gmail_status)" "a lapsed login with no refresh token still needs sign-in"
  classify_case classifier-limited "0 auth_required - rate_limited -"
  assert_equals auth_required "$(gmail_status)" "a rate-limited classifier read leaves the sign-in reading alone"
  classify_case limited "0 rate_limited - rate_limited -"
  assert_equals rate_limited "$(gmail_status)" "a genuine rate limit stays rate limited"
  classify_case signed-out "0 auth_required - auth_required -"
  assert_equals auth_required "$(gmail_status)" "a login the classifier also finds signed out still needs sign-in"
  classify_case unclassified "0 auth_required - garbage -"
  assert_equals auth_required "$(gmail_status)" "an unreadable classifier leaves the sign-in reading alone"
  pass "a lapsed Claude login that still holds a refresh token reads expired, not signed out"
}

# sweep: one watcher sweep after the usage cache has aged out, so each login
# is read exactly once, as a real sweep 5 minutes after the last one is.
sweep() {
  rm -f "$H"/state/.account-usage-*
  run_account rebalance --check
}

test_b_signin_lines_wait_for_confirmation_and_come_from_main() {
  local out i now
  new_case signin
  printf '80 fresh\n' > "$C/codex/fake-quota"
  printf '0 auth_required - auth_required -\n' > "$C/gmail/fake-quota"
  for i in 1 2 3; do
    out=$(sweep)
    assert_equals "" "$out" "read $i inside the confirmation window stays silent"
  done
  out=$(run_account status)
  assert_contains "$out" "Needs the captain: sign in to account gmail" "status shows the current reading at once"
  out=$(FM_ACCOUNT_SIGNIN_CONFIRM_SECS=0 sweep)
  assert_contains "$out" "needs the captain: sign in to account gmail" "three reads across the window confirm the sign-in"
  printf '0 rate_limited - rate_limited -\n' > "$C/gmail/fake-quota"
  out=$(FM_ACCOUNT_SIGNIN_CONFIRM_SECS=0 sweep)
  assert_equals "" "$out" "a rate-limited reading between sign-in readings changes nothing"
  printf '0 auth_required - auth_required -\n' > "$C/gmail/fake-quota"
  out=$(FM_ACCOUNT_SIGNIN_CONFIRM_SECS=0 sweep)
  assert_equals "" "$out" "the confirmed sign-in does not wake twice"
  printf '0 auth_required - unavailable expired_refreshable\n' > "$C/gmail/fake-quota"
  out=$(sweep)
  assert_equals "" "$out" "clearing the sign-in is silent"
  printf '0 auth_required - auth_required -\n' > "$C/gmail/fake-quota"
  out=$(FM_ACCOUNT_SIGNIN_CONFIRM_SECS=0 sweep)
  assert_equals "" "$out" "a cleared login needs three new reads before it is confirmed again"

  new_case signin-mate
  printf 'mate1\n' > "$H/.fm-secondmate-home"
  printf '80 fresh\n' > "$C/codex/fake-quota"
  printf '0 auth_required - auth_required -\n' > "$C/gmail/fake-quota"
  printf '99\n' > "$H/config/account-floor"
  for i in 1 2 3 4; do
    out=$(FM_ACCOUNT_SIGNIN_CONFIRM_SECS=0 sweep)
    assert_equals "" "$out" "a second mate's check never carries a sign-in or no-room line (read $i)"
  done
  out=$(run_account rebalance --dry-run)
  assert_not_contains "$out" "needs the captain" "a second mate's rebalance has nothing for the captain"
  out=$(run_account status --json)
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "sign in to account gmail" "a second mate's status still shows the sign-in"
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "no Claude account has room" "and the no-room line"
  new_case signin-span
  printf '80 fresh\n' > "$C/codex/fake-quota"
  printf '0 rate_limited - rate_limited -\n' > "$C/gmail/fake-quota"
  now=$(date +%s)
  printf '%s|%s|3\n' "$((now - 1000))" "$((now - 760))" > "$H/state/.account-signin-gmail"
  out=$(sweep)
  assert_equals "" "$out" "three reads spanning less than the window stay unconfirmed however long ago they began"
  printf '%s|%s|3\n' "$((now - 1000))" "$((now - 100))" > "$H/state/.account-signin-gmail"
  out=$(sweep)
  assert_contains "$out" "needs the captain: sign in to account gmail" "three reads spanning the window confirm the sign-in"
  pass "sign-in lines reach the captain only from main, once three reads over the window confirm them"
}

test_b_quiet_advice_returning_unchanged_does_not_wake_again() {
  local out
  new_case quiet
  printf '80 fresh\n' > "$C/codex/fake-quota"
  out=$(sweep)
  assert_contains "$out" "restart this main session on work" "the first check wakes"
  printf '0 garbage\n' > "$C/gmail/fake-quota"
  out=$(sweep)
  assert_equals "" "$out" "a failed read that empties the advice is silent"
  printf '4 fresh\n' > "$C/gmail/fake-quota"
  out=$(sweep)
  assert_equals "" "$out" "the same advice back inside the window does not wake again"
  printf '0 garbage\n' > "$C/gmail/fake-quota"
  sweep >/dev/null
  printf '4 fresh\n' > "$C/gmail/fake-quota"
  out=$(FM_ACCOUNT_SIGNIN_CONFIRM_SECS=0 sweep)
  assert_contains "$out" "restart this main session on work" "advice back after a quiet spell past the window wakes again"

  new_case quiet-move
  printf '80 fresh\n' > "$C/codex/fake-quota"
  add_mate sm2 ''
  out=$(sweep)
  assert_contains "$out" "sm2 gmail->work" "the first check wakes with the move"
  printf '0 garbage\n' > "$C/gmail/fake-quota"
  out=$(sweep)
  assert_equals "" "$out" "a failed read that empties the move and advice is silent"
  printf '4 fresh\n' > "$C/gmail/fake-quota"
  out=$(sweep)
  assert_contains "$out" "sm2 gmail->work" "a move returning after a quiet spell wakes at once"
  pass "advice that goes quiet and returns unchanged wakes again only after the confirmation window"
}

test_malformed_registry_refuses_and_the_check_says_so
test_status_attributes_every_agent_and_plans_moves
test_usage_is_cached_and_unknown_usage_never_moves_work
test_floor_and_priority_choose_the_account
test_rebalance_dry_run_and_check_wake_only_on_change
test_a_lapsed_login_reads_expired_not_signed_out
test_b_signin_lines_wait_for_confirmation_and_come_from_main
test_b_quiet_advice_returning_unchanged_does_not_wake_again
test_use_pins_a_second_mate_and_refuses_what_it_cannot_move
test_default_sets_and_clears_the_new_spawn_account
test_auto_arms_and_retires_the_watcher_check
test_panel_toggles_a_herdr_side_pane
test_spawn_leaves_a_low_login_and_records_the_account
test_spawn_refuses_an_unregistered_or_missing_login

echo "# all fm-account tests passed"
