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
unset FM_ACCOUNT_USAGE_TTL FM_ACCOUNT_QUOTA_TIMEOUT FM_ACCOUNT_QUOTA_ATTEMPTS FM_ACCOUNT_PANEL_RATIO FM_SPAWN_ACCOUNT
# Failed reads retry with no backoff here so the cases stay fast.
export FM_ACCOUNT_QUOTA_RETRY_DELAY=0

# write_fake_quota <fakebin>: quota-axi that reads
# "<percent-left> <status> [<auth-status> [<full-status> <full-auth-status>]]"
# from <login-folder>/fake-quota (default "50 fresh") and logs each read to
# FM_FAKE_QUOTA_LOG as "<provider> <dir> <profile|full> <refresh|no-refresh>
# <token|no-token>", and leaves the NODE_OPTIONS it ran with in
# <login-folder>/node-options. A --profile-only read answers <status> and <auth-status>;
# any other read is the classifier and answers <full-status> and
# <full-auth-status> (default: the same two), and writes the quota cache under
# XDG_CACHE_HOME the way the real tool does. "-" is an absent auth status.
# A <login-folder>/fake-fail holding N makes the next N --profile-only reads
# answer quota-axi's network failure (status error, "fetch failed") first.
# A <login-folder>/fake-windows holding "<id> <percent-left> <seconds-to-reset>"
# lines makes a fresh read report those windows, as the
# ones bounding all-models use, instead of its one weekly window with no usage;
# "-" seconds reports no reset time.
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
printf '%s\n' "${NODE_OPTIONS-<unset>}" > "$dir/node-options" 2>/dev/null || true
[ -z "${FM_FAKE_QUOTA_LOG:-}" ] || printf '%s %s %s %s %s\n' "$provider" "$dir" "$mode" "$refresh" \
  "$([ -n "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] && echo token || echo no-token)" >> "$FM_FAKE_QUOTA_LOG"
left=50 status=fresh auth=- fstatus= fauth=
[ ! -f "$dir/fake-quota" ] || read -r left status auth fstatus fauth < "$dir/fake-quota"
if [ "$mode" = profile ] && [ -f "$dir/fake-fail" ] && read -r fails < "$dir/fake-fail" && [ "${fails:-0}" -gt 0 ]; then
  printf '%s\n' "$((fails - 1))" > "$dir/fake-fail"
  printf '{"providers":[{"provider":"%s","state":{"status":"error","error":"fetch failed"}}]}\n' "$provider"
  exit 1
fi
if [ "$mode" = full ]; then
  status=${fstatus:-$status} auth=${fauth:-${auth:--}}
  mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/quota-axi"
  : > "${XDG_CACHE_HOME:-$HOME/.cache}/quota-axi/quotas.json"
fi
case "$status" in
  garbage) echo 'not json'; exit 0 ;;
  fresh)
    if [ -f "$dir/fake-windows" ]; then
      now=$(date +%s)
      jq -cn --arg p "$provider" --argjson left "$left" --arg now "$now" --rawfile w "$dir/fake-windows" '
        [ $w | split("\n")[] | select(. != "") | split(" ") |
          { id: .[0], percentRemaining: (.[1] | tonumber) } +
          (if .[2] == "-" then {} else { resetsAt: (($now | tonumber) + (.[2] | tonumber) | todate) } end) ] as $ws |
        { providers: [ { provider: $p, plan: "max", state: { status: "fresh" }, windows: $ws,
          quotaSemantics: { effectiveAvailability: [ { scope: "all_models", effectivePercentRemaining: $left,
            boundedBy: [ $ws[].id ], limitingWindowIds: [ $ws[0].id ] } ] } } ] }'
      exit 0
    fi
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
  mkdir -p "$H/state" "$H/config" "$H/data" "$C/gmail" "$C/work" "$C/codex" "$C/user-home" "$C/proc"
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
# the gmail login unless FM_TEST_SESSION_DIR says otherwise. Live logins are
# read from the case's own fake process table, empty unless a case adds to it.
run_account() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_BIN_PATH \
    -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_SPAWN_ACCOUNT \
    PATH="$C/fakebin:$PATH" FM_HOME="$H" HOME="$C/user-home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_SESSION_DIR-$C/gmail}" \
    FM_FAKE_QUOTA_LOG="$C/quota.log" FM_PROC_ROOT_OVERRIDE="$C/proc" \
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

# add_proc <pid> <comm> <cwd> [<environ-entry>...]: a fake process. With no
# entries its environ cannot be read.
add_proc() {
  local p="$C/proc/$1"
  mkdir -p "$p"
  printf '%s\n' "$2" > "$p/comm"
  ln -s "$3" "$p/cwd"
  shift 3
  [ $# -eq 0 ] || printf '%s\0' "$@" > "$p/environ"
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

test_spawn_honors_the_home_login_pin_over_the_registry() {
  local out rc
  spawn_case spawn-pin acct-s3
  mkdir -p "$C/pinned"
  # The pin's sign-in check runs `claude auth status`; this fake says signed in.
  fm_fake_exit0 "$SPAWN_FAKEBIN" claude
  printf '%s\n' "$C/pinned" > "$H/config/claude-account"
  out=$(FM_SPAWN_ACCOUNT=work FM_FAKE_LAUNCH_LOG="$C/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$C/gmail" \
    fm_test_run_spawn "$H" "$C/wt" "$SPAWN_FAKEBIN" acct-s3 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 1 "$rc" "a registry account under a home pin"
  assert_contains "$out" "config/claude-account pins this home's Claude login, so account 'work' cannot be honored" "the refusal names the pin"
  assert_absent "$H/state/acct-s3.meta" "a refused spawn leaves no record"
  out=$(FM_FAKE_LAUNCH_LOG="$C/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$C/gmail" \
    fm_test_run_spawn "$H" "$C/wt" "$SPAWN_FAKEBIN" acct-s3 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "spawn under a pin"$'\n'"$out"
  assert_not_contains "$out" "below the 10% floor" "the registry does not move a pinned home"
  assert_contains "$(cat "$C/launch.log")" "CLAUDE_CONFIG_DIR='$C/pinned' " "the worker launches on the pinned login"
  assert_grep "account=$C/pinned" "$H/state/acct-s3.meta" "the record carries the pin"
  pass "a home login pin outranks the account registry"
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

test_failed_reads_retry_and_never_count_as_exhausted() {
  local out
  new_case fetch-retry
  printf '80 fresh\n' > "$C/codex/fake-quota"
  printf '2\n' > "$C/work/fake-fail"
  out=$(run_account status --json)
  assert_equals "fresh|98" "$(json_get "$out" '.accounts[] | select(.name == "work") | "\(.status)|\(.percent_left)"')" "a read that fails twice then answers reads the answer"
  assert_equals 3 "$(grep -c "claude $C/work profile" "$C/quota.log")" "two failed reads are retried within the bound"

  new_case fetch-down
  printf '80 fresh\n' > "$C/codex/fake-quota"
  printf '99\n' > "$H/config/account-floor"
  printf '0 error\n' > "$C/work/fake-quota"
  out=$(run_account status --json)
  assert_equals "error|null|false" "$(json_get "$out" '.accounts[] | select(.name == "work") | "\(.status)|\(.percent_left)|\(.low)"')" "a read that keeps failing reports unknown usage"
  assert_equals 3 "$(grep -c "claude $C/work profile" "$C/quota.log")" "a read that keeps failing stops after the bound"
  assert_not_contains "$(json_get "$out" '.advice | join("\n")')" "no Claude account has room" "a failed read is not proof that a login is exhausted"
  out=$(sweep)
  assert_not_contains "$out" "no Claude account has room" "the watcher never wakes on no room while a read failed"
  printf '1 fresh\n' > "$C/work/fake-quota"
  out=$(sweep)
  assert_contains "$out" "needs the captain: no Claude account has room above the 99% floor" "every login proven below the floor wakes the captain"
  pass "failed usage reads retry within a bound, read as unknown, and never count as exhausted"
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

# window_case <name> <gmail-left> <window-lines...>: the usual case with gmail's
# reading reported per window, a worker and a second mate on gmail beside this
# session, and codex readable so no sign-in advice muddies the output.
window_case() {
  local name=$1 left=$2
  shift 2
  new_case "$name"
  printf '%s fresh\n' "$left" > "$C/gmail/fake-quota"
  printf '%s\n' "$@" > "$C/gmail/fake-windows"
  printf '80 fresh\n' > "$C/codex/fake-quota"
  add_ship a2
  add_mate sm2 ''
}

test_a_window_that_resets_before_running_out_moves_nothing() {
  local out
  window_case resets-first 10 "five_hour 10 600" "seven_day 49 259200"
  # A 15% floor puts the 10% reading below it, so only the projection keeps it.
  printf '15\n' > "$H/config/account-floor"
  out=$(run_account status --json)
  assert_equals "10|resets|false" "$(json_get "$out" '.accounts[] | select(.name == "gmail") | "\(.percent_left)|\(.outlook)|\(.low)"')" "10% left with 10 minutes to the 5-hour reset resets first"
  assert_equals 0 "$(json_get "$out" '.moves | length')" "no agent moves off a login that resets first"
  assert_equals gmail "$(json_get "$out" .new_spawns.account)" "new spawns stay on a login that resets first"
  out=$(run_account rebalance --dry-run)
  assert_contains "$out" "balanced: no agent needs to move" "rebalance plans no move"
  assert_not_contains "$out" "restart this main session" "nothing asks for a restart"
  assert_equals "" "$(run_account rebalance --check)" "the watcher form stays silent"
  assert_contains "$(run_account status)" "low, resets first" "the table says why it is left alone"
  pass "a login below the floor that resets before running out moves nothing and restarts nothing"
}

test_a_fast_burning_5_hour_window_steers_new_spawns_away() {
  local out rc
  spawn_case burn-5h acct-s2
  printf '35 fresh\n' > "$C/gmail/fake-quota"
  printf '%s\n' "five_hour 35 7200" "seven_day 80 259200" > "$C/gmail/fake-windows"
  out=$(run_account status --json)
  assert_equals "draining|false" "$(json_get "$out" '.accounts[] | select(.name == "gmail") | "\(.outlook)|\(.low)"')" "65% used in 3 of 5 hours runs out before the reset"
  assert_equals "gmail|work" "$(json_get "$out" '"\(.new_spawns.preferred)|\(.new_spawns.account)"')" "new spawns go to the login with room"
  assert_equals 0 "$(json_get "$out" '.moves | length')" "live agents stay while the login is above the floor"
  assert_not_contains "$(json_get "$out" '.advice | join("\n")')" "restart this main session" "no restart while steering spawns is enough"
  out=$(FM_FAKE_LAUNCH_LOG="$C/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$C/gmail" \
    fm_test_run_spawn "$H" "$C/wt" "$SPAWN_FAKEBIN" acct-s2 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "spawn"$'\n'"$out"
  assert_contains "$out" "account: gmail is on pace to run out before its usage window resets; this spawn uses work" "the spawn says why it left"
  assert_grep "account=work" "$H/state/acct-s2.meta" "the spawn launched on the login with room"
  pass "a 5-hour window burning fast enough to run out before its reset steers new spawns elsewhere"
}

test_a_weekly_allowance_running_out_before_its_reset_will_exhaust() {
  local out
  window_case burn-week 40 "five_hour 90 9000" "seven_day 40 302400"
  out=$(run_account status --json)
  assert_equals draining "$(json_get "$out" '.accounts[] | select(.name == "gmail") | .outlook')" "60% of the week used in half of it runs out before the reset"
  assert_equals work "$(json_get "$out" .new_spawns.account)" "new spawns leave it"
  assert_equals 0 "$(json_get "$out" '.moves | length')" "above the floor, live agents stay"
  window_case burn-week-low 5 "five_hour 90 9000" "seven_day 5 86400"
  out=$(run_account status --json)
  assert_equals "low|true" "$(json_get "$out" '.accounts[] | select(.name == "gmail") | "\(.outlook)|\(.low)"')" "below the floor and running out first"
  assert_equals "a2:gmail>work sm2:gmail>work" "$(json_get "$out" '[.moves[] | "\(.id):\(.from)>\(.to)"] | sort | join(" ")')" "live agents move once steering spawns is not enough"
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "restart this main session on work" "the session restart is asked for"
  pass "a weekly allowance projected to run out before its reset counts as running out"
}

test_an_unknown_reset_falls_back_to_the_floor() {
  local out
  window_case no-reset 4 "five_hour 4 -" "seven_day 60 259200"
  out=$(run_account status --json)
  assert_equals "low|true" "$(json_get "$out" '.accounts[] | select(.name == "gmail") | "\(.outlook)|\(.low)"')" "a window below the floor with no reset time is low"
  assert_equals "a2:gmail>work sm2:gmail>work" "$(json_get "$out" '[.moves[] | "\(.id):\(.from)>\(.to)"] | sort | join(" ")')" "the floor rule moves live agents"
  assert_equals work "$(json_get "$out" .new_spawns.account)" "and new spawns"
  window_case no-reset-room 60 "five_hour 60 -" "seven_day 70 259200"
  out=$(run_account status --json)
  assert_equals ok "$(json_get "$out" '.accounts[] | select(.name == "gmail") | .outlook')" "above the floor with no reset time is room, as before"
  assert_equals gmail "$(json_get "$out" .new_spawns.account)" "new spawns stay"
  pass "a window whose reset time is unknown falls back to the floor rule"
}

test_low_login_moves_work_to_a_draining_login_above_the_floor() {
  local out
  window_case low-to-draining 4 "five_hour 4 3600" "seven_day 60 259200"
  printf '50 fresh\n' > "$C/work/fake-quota"
  printf '%s\n' "five_hour 50 10800" "seven_day 70 259200" > "$C/work/fake-windows"
  out=$(run_account status --json)
  assert_equals "low|draining" "$(json_get "$out" '[.accounts[] | select(.name == "gmail" or .name == "work") | .outlook] | join("|")')" "gmail runs out first, work is on pace to run out"
  assert_equals work "$(json_get "$out" .new_spawns.account)" "new spawns go to the draining login above the floor"
  assert_equals "a2:gmail>work sm2:gmail>work" "$(json_get "$out" '[.moves[] | "\(.id):\(.from)>\(.to)"] | sort | join(" ")')" "live agents move to it"
  assert_contains "$(json_get "$out" '.advice | join("\n")')" "restart this main session on work" "the session restart is asked for"
  assert_not_contains "$(json_get "$out" '.advice | join("\n")')" "no Claude account has room" "no no-room advice while work has room"
  window_case draining-stays 40 "five_hour 90 9000" "seven_day 40 302400"
  printf '50 fresh\n' > "$C/work/fake-quota"
  printf '%s\n' "five_hour 50 10800" "seven_day 70 259200" > "$C/work/fake-windows"
  out=$(run_account status --json)
  assert_equals gmail "$(json_get "$out" .new_spawns.account)" "a draining login keeps its spawns when the other is draining too"
  pass "a low login moves work to a draining login still above the floor when none is ok"
}

test_quota_reads_carry_the_node_connect_timeout() {
  new_case nodeopts
  NODE_OPTIONS='--max-old-space-size=100' run_account status --refresh >/dev/null
  assert_equals "--max-old-space-size=100 --network-family-autoselection-attempt-timeout=2000" \
    "$(cat "$C/gmail/node-options")" "an existing NODE_OPTIONS is kept and the connect timeout added"
  assert_equals "--max-old-space-size=100 --network-family-autoselection-attempt-timeout=2000" \
    "$(cat "$C/codex/node-options")" "a Codex read and the sign-in classifier get it too"
  FM_ACCOUNT_QUOTA_CONNECT_MS=5000 run_account status --refresh >/dev/null
  assert_equals "--network-family-autoselection-attempt-timeout=5000" "$(cat "$C/work/node-options")" "the timeout is overridable"
  NODE_OPTIONS='--max-old-space-size=100' FM_ACCOUNT_QUOTA_CONNECT_MS=0 run_account status --refresh >/dev/null
  assert_equals "--max-old-space-size=100" "$(cat "$C/work/node-options")" "0 leaves NODE_OPTIONS alone"
  pass "every usage read gives Node a connect attempt long enough for a slow link"
}

test_readings_blind_when_every_read_fails_never_balanced() {
  local out
  new_case blind
  printf '0 garbage\n' > "$C/gmail/fake-quota"
  printf '0 garbage\n' > "$C/work/fake-quota"
  printf '3\n' > "$C/codex/fake-fail"
  out=$(run_account rebalance)
  assert_not_contains "$out" "balanced" "no reading must never read as balanced"
  assert_contains "$out" "needs the captain: account readings blind: every account usage read failed (gmail unreadable, work unreadable, codex error)" "rebalance says the readings are blind"
  out=$(run_account rebalance --check)
  assert_contains "$out" "accounts: needs the captain: account readings blind" "the watcher wakes with the blind readings"
  out=$(run_account rebalance --check)
  assert_equals "" "$out" "an unchanged blind check stays silent"
  out=$(run_account watch --once)
  assert_contains "$out" "Needs the captain: account readings blind" "the panel shows the blind readings"
  printf '1\n' > "$H/.fm-secondmate-home"
  rm -f "$H/state/.account-check"
  out=$(run_account rebalance --check)
  assert_equals "" "$out" "a second mate's watcher leaves the captain line to the main home"
  rm -f "$H/.fm-secondmate-home"
  printf '98 fresh\n' > "$C/work/fake-quota"
  out=$(FM_ACCOUNT_USAGE_TTL=0 run_account rebalance)
  assert_contains "$out" "balanced: no agent needs to move" "one readable account keeps today's behavior"
  assert_not_contains "$out" "blind" "a partial failure is not blind"
  pass "a usage read that fails for every account says the readings are blind instead of balanced"
}

test_status_shows_each_agents_live_login_beside_its_record() {
  local out rc wt1 wt2 wt3 mate
  new_case live
  add_ship a1 account=work
  add_ship a2 account=work
  add_ship a3 account=gmail
  add_ship a4 account=gmail
  add_mate sm1 work
  mkdir -p "$C/wt-a1" "$C/wt-a2" "$C/wt-a3" "$C/wt-a4"
  wt1=$(cd -P "$C/wt-a1" && pwd) wt2=$(cd -P "$C/wt-a2" && pwd)
  wt3=$(cd -P "$C/wt-a3" && pwd) mate=$(cd -P "$C/mate-sm1" && pwd)
  add_proc 101 claude "$wt1" "SECRET_TOKEN=do-not-print" "CLAUDE_CONFIG_DIR=$C/gmail" "OTHER=also-hidden"
  add_proc 102 claude "$wt1/" "CLAUDE_CONFIG_DIR=$C/gmail/"
  add_proc 103 bash "$wt2" "CLAUDE_CONFIG_DIR=$C/gmail"
  add_proc 104 claude "$mate" "CLAUDE_CONFIG_DIR=$C/work"
  add_proc 105 claude "$wt3" "CLAUDE_CONFIG_DIR=/nowhere/registered"
  add_proc 106 claude "$(cd -P "$C/wt-a4" && pwd)"
  out=$(run_account status --json)
  assert_equals "gmail|true" "$(json_get "$out" '.agents[] | select(.id == "a1") | "\(.live_account)|\(.live_mismatch)"')" "a worker running on another login than its record"
  assert_equals "null|false" "$(json_get "$out" '.agents[] | select(.id == "a2") | "\(.live_account)|\(.live_mismatch)"')" "only a claude process speaks for an agent"
  assert_equals "work|false" "$(json_get "$out" '.agents[] | select(.id == "sm1") | "\(.live_account)|\(.live_mismatch)"')" "a second mate is read from its home"
  assert_equals "unregistered|true" "$(json_get "$out" '.agents[] | select(.id == "a3") | "\(.live_account)|\(.live_mismatch)"')" "a login no account registers"
  assert_equals "null|false" "$(json_get "$out" '.agents[] | select(.id == "a4") | "\(.live_account)|\(.live_mismatch)"')" "an unreadable process is unknown"
  assert_equals "null" "$(json_get "$out" '.agents[] | select(.kind == "session") | .live_account')" "no process for this session is unknown"
  out=$(run_account status); rc=$?
  expect_code 0 "$rc" "status with unreadable processes"
  assert_contains "$out" "a1                     recorded work       live gmail  MISMATCH" "the table marks the mismatch"
  assert_contains "$out" "sm1                    recorded work       live work"$'\n' "a match is not marked"
  assert_contains "$out" "live unknown" "an unreadable agent shows as unknown"
  assert_not_contains "$out$(run_account status --json)" "do-not-print" "no other environment value is printed"
  assert_not_contains "$out" "also-hidden" "no other environment value is printed"
  pass "status shows each agent's live login beside its recorded account and marks a mismatch"
}

test_malformed_registry_refuses_and_the_check_says_so
test_failed_reads_retry_and_never_count_as_exhausted
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
test_spawn_honors_the_home_login_pin_over_the_registry
test_a_window_that_resets_before_running_out_moves_nothing
test_a_fast_burning_5_hour_window_steers_new_spawns_away
test_a_weekly_allowance_running_out_before_its_reset_will_exhaust
test_an_unknown_reset_falls_back_to_the_floor
test_low_login_moves_work_to_a_draining_login_above_the_floor
test_quota_reads_carry_the_node_connect_timeout
test_readings_blind_when_every_read_fails_never_balanced
test_status_shows_each_agents_live_login_beside_its_record

echo "# all fm-account tests passed"
