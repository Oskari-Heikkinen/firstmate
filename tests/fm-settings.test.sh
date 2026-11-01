#!/usr/bin/env bash
# Tests for bin/fm-settings.sh and bin/fm-settings-lib.sh, the settings owner.
#
# Each case builds its own home and machine HOME and drives the CLI or the
# library's fm_setting_to; the key table is the tracked one unless a case
# replaces it through FM_SETTINGS_TABLE_OVERRIDE.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="$ROOT/bin/fm-settings.sh"
TMP_ROOT=$(fm_test_tmproot fm-settings-tests)
HOME_KEY=settings.probe.home-seconds
ALARM_KEY=settings.probe.alarm-seconds
MACHINE_KEY=settings.probe.machine-bytes

# make_world <name>: a home and a machine HOME; prints the world directory.
make_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/config" "$w/machine"
  printf '%s\n' "$w"
}

# run_in <world> <command...>: run with only the world's settings environment.
run_in() {
  local w=$1
  shift
  env -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_ROOT_OVERRIDE -u FM_SETTINGS_PROBE_HOME_SECONDS -u FM_SETTINGS_NO_ALARM \
    HOME="$w/machine" FM_HOME="$w/home" "$@"
}

cli() {  # <world> <args...>
  local w=$1
  shift
  run_in "$w" "$SETTINGS" "$@"
}

home_file() { printf '%s/home/config/settings\n' "$1"; }
machine_file() { printf '%s/machine/.config/firstmate/settings\n' "$1"; }

# active_alarms <world>: the store's active keys, one per line, or nothing.
active_alarms() {
  local store="$1/home/state/settings-alerts.json"
  [ -f "$store" ] || return 0
  jq -r '.active | keys[]' "$store"
}

# bad_get <world> <key> <expected-exit> <expected-stderr> <label>
bad_get() {
  local w=$1 key=$2 want=$3 needle=$4 label=$5 out rc=0
  out=$(cli "$w" get "$key" 2>"$w/get.err") || rc=$?
  expect_code "$want" "$rc" "$label: get exit"
  [ "$want" != 1 ] || assert_equals '' "$out" "$label: a refused key printed a value"
  assert_grep "$needle" "$w/get.err" "$label: stderr did not name the failure"
}

test_absent_files_take_defaults_and_raise_nothing() {
  local w out rc=0
  w=$(make_world absent)
  out=$(cli "$w" get "$HOME_KEY") || fail "get with no files failed"
  assert_equals 60 "$out" "absent home file did not give the default"
  out=$(cli "$w" get "$MACHINE_KEY") || fail "get machine key with no files failed"
  assert_equals 1073741824 "$out" "absent machine file did not give the default in bytes"
  out=$(cli "$w" check) || rc=$?
  expect_code 0 "$rc" "check with no files"
  assert_contains "$out" "is absent; every home key takes its default" "check did not report the absent home file"
  assert_absent "$w/home/state/settings-alerts.json" "check with no files created an alert store"
  pass "absent settings files take the defaults and raise nothing"
}

test_set_writes_validates_and_logs() {
  local w out log
  w=$(make_world set)
  out=$(cli "$w" set "$ALARM_KEY" 10m --reason 'slow machine' 2>&1) || fail "set failed: $out"
  out=$(run_in "$w" env FM_TASK_ID=t1 "$SETTINGS" set "$HOME_KEY" 5m --reason 'longer probe' 2>&1) || fail "set failed: $out"
  assert_grep "$HOME_KEY = 5m" "$(home_file "$w")" "set did not write the value line"
  out=$(cli "$w" get "$HOME_KEY") || fail "get after set failed"
  assert_equals 300 "$out" "get did not read the set value in seconds"
  log="$(home_file "$w").log"
  assert_grep "set $ALARM_KEY: default (120) -> 10m by main session on " "$log" "the log missed the first change"
  assert_grep "set $HOME_KEY: default (60) -> 5m by task t1 on " "$log" "the log missed the actor or the old and new values"
  assert_grep "why: longer probe; reread: every-run" "$log" "the log missed the reason or the reread mode"
  out=$(cli "$w" explain "$HOME_KEY") || fail "explain failed"
  assert_contains "$out" "value: 300 (from $(home_file "$w"):3)" "explain did not name the file line"
  assert_contains "$out" "why: longer probe" "explain did not show the last change"
  out=$(cli "$w" log "$HOME_KEY")
  assert_contains "$out" "[home] set $HOME_KEY" "log did not show the key's change"
  assert_not_contains "$out" "$ALARM_KEY" "log <key> showed another key's change"
  cli "$w" set "$HOME_KEY" --default --reason 'back to normal' >/dev/null 2>&1 || fail "set --default failed"
  assert_no_grep "$HOME_KEY" "$(home_file "$w")" "set --default left the key line"
  assert_grep "set $HOME_KEY: 5m -> default (60)" "$log" "set --default was not logged"
  pass "set validates, writes, logs who, when, old, new and why, and --default removes the line"
}

# Each refusal has its own fixture in which only that check fails.
test_set_refusals_write_nothing() {
  local w before rc
  w=$(make_world refuse)
  cli "$w" set "$ALARM_KEY" 200 --reason seed >/dev/null 2>&1 || fail "seed set failed"
  before=$(cat "$(home_file "$w")" "$(home_file "$w").log")
  rc=0; cli "$w" set "$HOME_KEY" 2h --reason x 2>"$w/err" || rc=$?
  expect_code 1 "$rc" "out-of-range set"
  assert_grep "outside the reviewed range 1..3600" "$w/err" "out-of-range set did not name the range"
  rc=0; cli "$w" set "$HOME_KEY" soon --reason x 2>"$w/err" || rc=$?
  expect_code 1 "$rc" "wrong-type set"
  assert_grep "is not a whole number of seconds" "$w/err" "wrong-type set did not name the type"
  rc=0; cli "$w" set "$HOME_KEY" 190 --reason x 2>"$w/err" || rc=$?
  expect_code 0 "$rc" "a set that keeps the rule"
  before=$(cat "$(home_file "$w")" "$(home_file "$w").log")
  rc=0; cli "$w" set "$HOME_KEY" 250 --reason x 2>"$w/err" || rc=$?
  expect_code 1 "$rc" "rule-breaking set"
  assert_grep "rule $ALARM_KEY > $HOME_KEY is broken" "$w/err" "rule-breaking set did not name the rule"
  assert_no_grep ".tmp." "$w/err" "the refusal named the temporary file"
  rc=0; cli "$w" set nope.key 1 --reason x 2>"$w/err" || rc=$?
  expect_code 2 "$rc" "unknown-key set"
  rc=0; cli "$w" set "$HOME_KEY" 30 2>"$w/err" || rc=$?
  expect_code 2 "$rc" "set without a reason"
  rc=0; cli "$w" set "$HOME_KEY" 30 --reason '   ' 2>"$w/err" || rc=$?
  expect_code 2 "$rc" "set with a blank reason"
  assert_equals "$before" "$(cat "$(home_file "$w")" "$(home_file "$w").log")" "a refused set changed the file or the log"
  assert_equals '' "$(find "$w/home/config" -name '*.tmp.*')" "a refused set left a temporary file"
  assert_absent "$(home_file "$w").lock" "a refused set left its lock"
  cli "$w" set "$HOME_KEY" 30 --reason 'after refusal' >/dev/null 2>&1 || fail "a refusal blocked the next writer"
  pass "set refuses an out-of-range, wrong-type, rule-breaking, unknown or unexplained change and writes nothing"
}

test_concurrent_sets_all_land() {
  local w i writer_pids='' out
  w=$(make_world concurrent)
  for i in 1 2 3 4 5; do
    cli "$w" set "$ALARM_KEY" "$((200 + i))" --reason "writer $i" >/dev/null 2>&1 &
    writer_pids="$writer_pids $!"
  done
  cli "$w" set "$MACHINE_KEY" 2G --reason 'machine writer' >/dev/null 2>&1 || fail "machine set failed"
  for i in $writer_pids; do wait "$i" || fail "a concurrent set failed"; done
  assert_equals 5 "$(grep -c " set $ALARM_KEY: " "$(home_file "$w").log")" "a concurrent set was not logged"
  assert_equals 1 "$(grep -c "^$ALARM_KEY = " "$(home_file "$w")")" "concurrent sets left a duplicate line"
  out=$(cli "$w" check) || fail "check after concurrent sets failed: $out"
  pass "concurrent sets serialize under the lock and each is logged"
}

test_hand_edit_is_logged_as_actor_unknown() {
  local w out
  w=$(make_world handedit)
  cli "$w" set "$ALARM_KEY" 300 --reason seed >/dev/null 2>&1 || fail "seed set failed"
  printf '# edited\n%s = 400\n%s = 90\n' "$ALARM_KEY" "$HOME_KEY" > "$(home_file "$w")"
  out=$(cli "$w" check) || fail "check after a valid hand edit failed: $out"
  assert_grep "changed outside set: $ALARM_KEY: 300 -> 400, actor unknown" "$(home_file "$w").log" \
    "check did not log the hand-edited value"
  assert_grep "changed outside set: $HOME_KEY: default (60) -> 90, actor unknown" "$(home_file "$w").log" \
    "check did not log the hand-added key"
  cli "$w" check >/dev/null || fail "second check failed"
  assert_equals 2 "$(grep -c 'changed outside set' "$(home_file "$w").log")" "a second check logged the same hand edit again"
  rm "$(home_file "$w")"
  cli "$w" check >/dev/null || fail "check after removal failed"
  assert_grep "changed outside set: $ALARM_KEY: 400 -> default (120), actor unknown" "$(home_file "$w").log" \
    "check did not log a hand-removed file"
  pass "check logs each hand-edited key once as actor unknown"
}

# bad_home_case <label> <stderr-needle> <writer...>: the writer makes the home
# file bad; get refuses naming it, check raises one alarm, and a fix clears it.
bad_home_case() {
  local label=$1 needle=$2 w f rc
  shift 2
  w=$(make_world "bad-$label")
  f=$(home_file "$w")
  "$@" "$f"
  bad_get "$w" "$HOME_KEY" 1 "$needle" "$label"
  rc=0; cli "$w" check >"$w/check.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "$label: check exit"
  assert_grep "home settings: INVALID: " "$w/check.out" "$label: check did not report the home file"
  assert_no_grep "home settings: $f reads without a problem" "$w/check.out" "$label: check also reported the invalid scope as healthy"
  assert_equals settings-invalid-home "$(active_alarms "$w")" "$label: check did not raise exactly the home alarm"
  jq -e --arg n "$needle" '.active["settings-invalid-home"].reason | contains($n)' \
    "$w/home/state/settings-alerts.json" >/dev/null || fail "$label: the alarm did not name the failure"
  cli "$w" check >/dev/null 2>&1
  assert_equals settings-invalid-home "$(active_alarms "$w")" "$label: a second check changed the alarm"
  chmod 644 "$f" 2>/dev/null
  rm -rf "$f"
  printf '%s = 30\n' "$HOME_KEY" > "$f"
  cli "$w" check >/dev/null 2>&1 || fail "$label: check after the fix failed"
  assert_equals '' "$(active_alarms "$w")" "$label: check did not clear the alarm after the fix"
}

w_empty() { : > "$1"; }
w_blank() { printf '  \n\t\n' > "$1"; }
w_nul() { printf '%s = 30\0\n' "$HOME_KEY" > "$1"; }
w_noparse() { printf '# ok\n%s 30\n' "$HOME_KEY" > "$1"; }
w_unknown() { printf 'settings.nope = 1\n' > "$1"; }
w_scope() { printf '%s = 2G\n' "$MACHINE_KEY" > "$1"; }
w_dupe() { printf '%s = 30\n%s = 40\n' "$HOME_KEY" "$HOME_KEY" > "$1"; }
w_range() { printf '%s = 0\n' "$HOME_KEY" > "$1"; }
w_type() { printf '%s = 1.5\n' "$HOME_KEY" > "$1"; }
w_symlink() { printf '%s = 30\n' "$HOME_KEY" > "$1.real"; ln -s "$1.real" "$1"; }
w_dangling() { ln -s "$1.missing" "$1"; }
w_dir() { mkdir "$1"; }
w_fifo() { mkfifo "$1"; }
w_huge() { { printf '%s = 30\n' "$HOME_KEY"; head -c 70000 /dev/zero | tr '\0' '#'; printf '\n'; } > "$1"; }
w_rule() { printf '%s = 100\n%s = 100\n' "$ALARM_KEY" "$HOME_KEY" > "$1"; }
w_unreadable() { printf '%s = 30\n' "$HOME_KEY" > "$1"; chmod 000 "$1"; }

test_bad_readings_refuse_and_alarm() {
  local f
  f='config/settings'
  bad_home_case empty "$f: is empty" w_empty
  bad_home_case blank "$f: is empty" w_blank
  bad_home_case nul "$f" w_nul
  bad_home_case noparse "$f:2: does not parse" w_noparse
  bad_home_case unknown "$f:1: unknown key 'settings.nope'" w_unknown
  bad_home_case scope "$f:1: " w_scope
  bad_home_case dupe "$f:2: " w_dupe
  bad_home_case range "$f:1: $HOME_KEY = 0: it is outside the reviewed range 1..3600" w_range
  bad_home_case type "$f:1: " w_type
  bad_home_case symlink "$f: is a symlink" w_symlink
  bad_home_case dangling "$f: is a symlink" w_dangling
  bad_home_case dir "$f: is not a regular file" w_dir
  bad_home_case fifo "$f: is not a regular file" w_fifo
  bad_home_case huge "$f: " w_huge
  bad_home_case rule "is broken" w_rule
  if [ "$(id -u)" != 0 ]; then
    bad_home_case unreadable "$f: " w_unreadable
  fi
  pass "every bad home file refuses its key, names the file, and raises one alarm that a fix clears"
}

test_comment_only_file_reads_as_defaults() {
  local w out
  w=$(make_world comments)
  printf '# nothing set yet\n\n' > "$(home_file "$w")"
  out=$(cli "$w" get "$HOME_KEY") || fail "a comment-only file failed"
  assert_equals 60 "$out" "a comment-only file did not give the default"
  pass "a file with only comments reads as all defaults"
}

test_last_good_keeps_the_last_good_value() {
  local w mf out rc=0
  w=$(make_world lastgood)
  mf=$(machine_file "$w")
  mkdir -p "${mf%/*}"
  printf '%s = 1\n' "$MACHINE_KEY" > "$mf"
  out=$(cli "$w" get "$MACHINE_KEY" 2>"$w/err") || rc=$?
  expect_code 3 "$rc" "a bad last-good key"
  assert_equals 1073741824 "$out" "a bad last-good key with no good reading did not give the default"
  assert_grep "$mf:1: " "$w/err" "a bad last-good key did not name the file line"
  assert_equals settings-invalid-machine "$(active_alarms "$w")" "the first failed reading did not raise the machine alarm"
  # shellcheck disable=SC2016 # The script expands in the child shell.
  out=$(run_in "$w" bash -c '
    . "$1/bin/fm-settings-lib.sh"
    printf "%s = 3G\n" "$2" > "$3"; fm_setting_to v "$2"; printf "%s %s\n" "$?" "$v"
    printf "%s = 0\n" "$2" > "$3"; fm_setting_to v "$2"; printf "%s %s %s\n" "$?" "$v" "$FM_SETTING_SOURCE"
  ' _ "$ROOT" "$MACHINE_KEY" "$mf" 2>"$w/err")
  assert_contains "$out" "0 3221225472" "a good reading was not used"
  assert_contains "$out" "3 3221225472 last-good" "a loop did not keep its last good value"
  pass "a last-good key keeps its last good value, or the default, and alarms"
}

test_env_overrides_and_bad_env_refuses() {
  local w out rc=0
  w=$(make_world env)
  printf '%s = 30\n%s = 300\n' "$HOME_KEY" "$ALARM_KEY" > "$(home_file "$w")"
  out=$(run_in "$w" env FM_SETTINGS_PROBE_HOME_SECONDS=2m "$SETTINGS" get "$HOME_KEY") || fail "env override failed"
  assert_equals 120 "$out" "the env variable did not win over the file"
  out=$(run_in "$w" env FM_SETTINGS_PROBE_HOME_SECONDS=2m "$SETTINGS" explain "$HOME_KEY")
  assert_contains "$out" "(from env FM_SETTINGS_PROBE_HOME_SECONDS)" "explain did not name the env source"
  out=$(run_in "$w" env FM_SETTINGS_PROBE_HOME_SECONDS=9999 "$SETTINGS" get "$HOME_KEY" 2>"$w/err") || rc=$?
  expect_code 1 "$rc" "an out-of-range env value"
  assert_grep "env FM_SETTINGS_PROBE_HOME_SECONDS = 9999" "$w/err" "a bad env value was not named"
  pass "the env variable overrides the file, and a bad env value refuses"
}

test_bad_tables_refuse() {
  local w t rc
  w=$(make_world tables)
  t="$w/table"
  for body in \
    "x.a | seconds | 1 | 10 | 20 | home | every-run | refuse | - | bin/x | -" \
    "x.a | seconds | 1 | 10 | 5 | both | every-run | refuse | - | bin/x | -" \
    "x.a | seconds | 1 | 10 | 5 | home | install | refuse | - | bin/x | -" \
    "x.a | seconds | 1 | 10 | 5 | home | every-run | refuse | PATH | bin/x | -" \
    "x.a | seconds | 1 | 10 | 5 | home | every-run | refuse | - | bin/x | -
x.b | seconds | 1 | 10 | 6 | home | every-run | refuse | - | bin/x | -
rule | x.a | > | x.b" \
    "x.a | seconds | 1 | 10 | 5 | home | every-run | refuse | - | bin/x"; do
    printf '%s\n' "$body" > "$t"
    rc=0; FM_SETTINGS_TABLE_OVERRIDE="$t" cli "$w" get x.a >/dev/null 2>"$w/err" || rc=$?
    expect_code 2 "$rc" "a bad table ($body)"
    assert_grep "$t" "$w/err" "a bad table refusal did not name the table"
  done
  pass "a bad key table refuses every reading"
}

test_install_key_runs_its_apply_command() {
  local w t out rc=0
  w=$(make_world install)
  t="$w/table"
  printf '%s\n' \
    "x.ok | count | 1 | 10 | 5 | home | install | refuse | - | bin/x | bin/fm-settings.sh get x.ok" \
    "x.bad | count | 1 | 10 | 5 | home | install | refuse | - | bin/x | bin/fm-settings.sh get x.none" > "$t"
  out=$(FM_SETTINGS_TABLE_OVERRIDE="$t" cli "$w" set x.ok 7 --reason 'apply works' 2>&1) || fail "install set failed: $out"
  assert_grep "set x.ok: default (5) -> 7" "$(home_file "$w").log" "the install set was not logged"
  assert_grep "reread: install; apply: ok" "$(home_file "$w").log" "the apply result was not logged"
  out=$(FM_SETTINGS_TABLE_OVERRIDE="$t" cli "$w" set x.bad 7 --reason 'apply fails' 2>&1) || rc=$?
  expect_code 1 "$rc" "a set whose apply fails"
  assert_grep "apply: failed (exit 2), rerun bin/fm-settings.sh get x.none" "$(home_file "$w").log" \
    "a failed apply was not logged with its rerun command"
  pass "set runs an install key's apply command and logs its result"
}

test_generated_doc_section_is_current() {
  local w doc rc=0
  "$SETTINGS" doc --check "$ROOT/docs/configuration.md" || fail "docs/configuration.md settings section is stale"
  w=$(make_world doc)
  doc="$w/doc.md"
  printf '# Doc\n<!-- fm-settings.sh doc: begin -->\nold\n<!-- fm-settings.sh doc: end -->\ntail\n' > "$doc"
  "$SETTINGS" doc --check "$doc" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "a stale doc section"
  "$SETTINGS" doc --write "$doc" || fail "doc --write failed"
  "$SETTINGS" doc --check "$doc" || fail "doc --write did not make the section current"
  assert_grep "| \`$HOME_KEY\` | seconds | 1..3600 | 60 | home |" "$doc" "the generated table missed a key"
  assert_grep "tail" "$doc" "doc --write dropped text after the section"
  pass "the generated settings section in docs/configuration.md matches the key table"
}

test_absent_files_take_defaults_and_raise_nothing
test_set_writes_validates_and_logs
test_set_refusals_write_nothing
test_concurrent_sets_all_land
test_hand_edit_is_logged_as_actor_unknown
test_bad_readings_refuse_and_alarm
test_comment_only_file_reads_as_defaults
test_last_good_keeps_the_last_good_value
test_env_overrides_and_bad_env_refuses
test_bad_tables_refuse
test_install_key_runs_its_apply_command
test_generated_doc_section_is_current
