#!/usr/bin/env bash
# Behavior tests for bin/fm-admission.sh and the admission gate bin/fm-spawn.sh
# runs before every local launch.
#
# Every case reads a fake /proc (meminfo, pressure, loadavg, and per-process
# stat/comm/cmdline) through FM_PROC_ROOT_OVERRIDE, its own rules file, and its
# own ledger directory, so no case depends on the test host's real memory,
# load, or live agents, and waits never sleep for real.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ADMISSION="$ROOT/bin/fm-admission.sh"
TMP_ROOT=$(fm_test_tmproot fm-admission)
# tests/lib.sh disables the gate for every other suite; this one exercises it.
unset FM_ADMISSION FM_ADMISSION_SLEEP

# write_proc <proc> <mem-available-kib> <mem-full-avg10> <cpu-some-avg10> <load1>
write_proc() {
  local proc=$1
  mkdir -p "$proc/pressure"
  printf 'MemTotal:       24000000 kB\nMemFree:          100000 kB\nMemAvailable:   %s kB\n' "$2" > "$proc/meminfo"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$3" > "$proc/pressure/memory"
  printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "$4" > "$proc/pressure/cpu"
  printf '%s 1.00 1.00 2/300 12345\n' "$5" > "$proc/loadavg"
}

# add_proc <proc> <pid> <ppid> <comm> [argv...]
add_proc() {
  local proc=$1 pid=$2 ppid=$3 comm=$4
  shift 4
  mkdir -p "$proc/$pid"
  printf '%s (%s) S %s 1 1 0 -1\n' "$pid" "$comm" "$ppid" > "$proc/$pid/stat"
  printf '%s\n' "$comm" > "$proc/$pid/comm"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" > "$proc/$pid/cmdline"; else : > "$proc/$pid/cmdline"; fi
}

new_case() {
  C="$TMP_ROOT/$1"
  mkdir -p "$C/home/state"
  export FM_PROC_ROOT_OVERRIDE="$C/proc" FM_ADMISSION_NPROC=16
  export FM_ADMISSION_RULES="$C/rules.json" FM_ADMISSION_RUN_DIR="$C/run" FM_HOME="$C/home"
  write_proc "$C/proc" 16000000 0.00 1.00 4.00
  printf '{}\n' > "$C/rules.json"
}

adm() { "$ADMISSION" "$@" 2>&1; }

test_healthy_host_admits_and_records() {
  local out rc
  new_case healthy
  add_proc "$C/proc" 100 1 bash
  add_proc "$C/proc" 101 100 claude claude --model x
  out=$(adm check); rc=$?
  expect_code 0 "$rc" "check on a healthy host"$'\n'"$out"
  assert_equals admit "$out" "check says admit"
  assert_absent "$C/run/admitted" "check records nothing"
  out=$(adm acquire --label "task t1"); rc=$?
  expect_code 0 "$rc" "acquire on a healthy host"$'\n'"$out"
  assert_grep " fresh $C/home" "$C/run/admitted" "acquire records a fresh admission for this home"
  pass "a healthy host admits at once and records the admission"
}

test_each_signal_holds_admission() {
  local out
  new_case signals
  write_proc "$C/proc" 6000000 0.00 1.00 4.00
  out=$(adm check) && fail "low memory admitted"
  assert_contains "$out" "free memory" "low memory is named"
  write_proc "$C/proc" 16000000 9.50 1.00 4.00
  out=$(adm check) && fail "memory pressure admitted"
  assert_contains "$out" "memory pressure full avg10 9.50%" "memory pressure is named"
  write_proc "$C/proc" 16000000 0.00 55.00 4.00
  out=$(adm check) && fail "cpu pressure admitted"
  assert_contains "$out" "cpu pressure some avg10 55.00%" "cpu pressure is named"
  write_proc "$C/proc" 16000000 0.00 1.00 40.00
  out=$(adm check) && fail "high load admitted"
  assert_contains "$out" "1-minute load 2.50 per core" "load is named"
  printf '{"load1_per_core_max": 3}\n' > "$C/rules.json"
  out=$(adm check) || fail "a raised load rule still held admission: $out"
  pass "memory, memory pressure, cpu pressure, and load each hold admission and a rule raises the bar"
}

test_fleet_cap_counts_agent_trees_machine_wide() {
  local out
  new_case cap
  printf '{"max_agents": 3}\n' > "$C/rules.json"
  add_proc "$C/proc" 10 1 tmux
  add_proc "$C/proc" 20 10 claude claude
  add_proc "$C/proc" 21 20 claude claude --resume helper
  add_proc "$C/proc" 30 10 node node /usr/lib/node_modules/codex/bin/codex
  add_proc "$C/proc" 40 10 node node /srv/app/server.js
  out=$(adm check) || fail "two agent trees under a cap of 3 held admission: $out"
  add_proc "$C/proc" 50 10 opencode opencode
  out=$(adm check) && fail "three agents under a cap of 3 admitted another"
  assert_contains "$out" "3 live agents plus 0 just admitted would exceed the fleet cap of 3" "the cap is named with the live count"
  rm -rf "${C:?}/proc/50"
  out=$(adm acquire) || fail "acquire under the cap failed: $out"
  out=$(adm check) && fail "a just-admitted agent was not charged against the cap"
  assert_contains "$out" "2 live agents plus 1 just admitted" "recent admissions count toward the cap"
  pass "the cap counts one per agent tree, recognizes node-hosted agents, and charges recent admissions"
}

test_waits_then_admits_when_the_host_recovers() {
  local out rc
  new_case wait-admit
  write_proc "$C/proc" 6000000 0.00 1.00 4.00
  cat > "$C/recover.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$C/sleeps.log"
printf 'MemTotal: 24000000 kB\nMemAvailable: 16000000 kB\n' > "$C/proc/meminfo"
SH
  chmod +x "$C/recover.sh"
  out=$(FM_ADMISSION_SLEEP="$C/recover.sh" adm acquire --label "task t2"); rc=$?
  expect_code 0 "$rc" "acquire after recovery"$'\n'"$out"
  assert_contains "$out" "task t2 waiting (up to 300s): free memory" "the wait names the unmet condition"
  assert_contains "$out" "task t2 admitted after" "admission after waiting is reported"
  assert_equals 1 "$(wc -l < "$C/sleeps.log" | tr -d ' ')" "exactly one backoff sleep"
  pass "a held launch waits with backoff and is admitted once the host recovers"
}

test_refuses_after_the_bound_and_override_skips() {
  local out rc
  new_case refuse
  write_proc "$C/proc" 6000000 0.00 1.00 4.00
  printf '{"wait_max_s": 0}\n' > "$C/rules.json"
  out=$(adm acquire --label "task t3"); rc=$?
  expect_code 3 "$rc" "acquire past the bound"
  assert_contains "$out" "error: admission refused for task t3 after 0s: free memory" "the refusal names the unmet condition"
  assert_absent "$C/run/admitted" "a refusal records nothing"
  out=$(adm acquire --label "task t3" --override); rc=$?
  expect_code 0 "$rc" "override"
  assert_contains "$out" "notice: admission override for task t3 - skipped: free memory" "the override says what it skipped"
  assert_present "$C/run/admitted" "an override is still recorded"
  pass "a launch refuses loudly after its bound, and an override starts it with a notice"
}

test_relaunches_are_paced_per_home_and_secondmates_never_refused() {
  local out rc
  new_case pace
  out=$(adm acquire --relaunch) || fail "first relaunch: $out"
  out=$(adm acquire --relaunch) || fail "second relaunch: $out"
  out=$(adm check --relaunch) && fail "a third relaunch in a minute was admitted"
  assert_contains "$out" "2 relaunches in this home in the last minute" "pacing is named"
  out=$(adm check --relaunch --home "$C/other-home") || fail "pacing leaked across homes: $out"
  out=$(adm check) || fail "pacing held a fresh spawn: $out"
  printf '{"secondmate_wait_max_s": 0}\n' > "$C/rules.json"
  out=$(adm acquire --secondmate --label "task sm"); rc=$?
  expect_code 0 "$rc" "a paced secondmate still starts"
  assert_contains "$out" "warning: admission: secondmate task sm starting after 0s despite: 2 relaunches" "the secondmate start warns"
  pass "restart-shaped launches are paced per home and a secondmate is delayed, never refused"
}

test_malformed_rules_and_disabled_gate() {
  local out
  new_case rules
  printf 'not json\n' > "$C/rules.json"
  out=$(adm rules)
  assert_contains "$out" "is not a JSON object, so the built-in defaults apply" "a malformed file warns"
  assert_contains "$out" "max_agents=24" "defaults apply"
  write_proc "$C/proc" 1000 99 99 99
  out=$(FM_ADMISSION=off adm check) || fail "FM_ADMISSION=off still held admission: $out"
  pass "a malformed rules file warns and falls back, and FM_ADMISSION=off admits"
}

test_spawn_refuses_before_creating_anything() {
  local out rc fakebin
  new_case spawn
  fakebin=$(fm_test_make_spawn_fakebin "$C/spawnfake")
  fm_git_worktree "$C/project" "$C/wt" wt-adm
  fm_test_spawn_home "$C/home" claude
  fm_test_spawn_brief "$C/home" adm-s1
  write_proc "$C/proc" 6000000 0.00 1.00 4.00
  printf '{"wait_max_s": 0}\n' > "$C/rules.json"
  out=$(fm_test_run_spawn "$C/home" "$C/wt" "$fakebin" adm-s1 "$C/project" --mode no-mistakes --yolo off); rc=$?
  expect_code 1 "$rc" "spawn under memory pressure"$'\n'"$out"
  assert_contains "$out" "admission refused for task adm-s1" "the spawn surfaces the refusal"
  assert_absent "$C/home/state/adm-s1.meta" "a refused spawn leaves no record"
  out=$(fm_test_run_spawn "$C/home" "$C/wt" "$fakebin" adm-s1 "$C/project" --mode no-mistakes --yolo off --admission-override); rc=$?
  expect_code 0 "$rc" "spawn with override"$'\n'"$out"
  assert_contains "$out" "notice: admission override for task adm-s1" "the override is announced"
  assert_present "$C/home/state/adm-s1.meta" "the overridden spawn launches"
  pass "fm-spawn refuses before creating anything, and --admission-override launches"
}

test_healthy_host_admits_and_records
test_each_signal_holds_admission
test_fleet_cap_counts_agent_trees_machine_wide
test_waits_then_admits_when_the_host_recovers
test_refuses_after_the_bound_and_override_skips
test_relaunches_are_paced_per_home_and_secondmates_never_refused
test_malformed_rules_and_disabled_gate
test_spawn_refuses_before_creating_anything

echo "# all fm-admission tests passed"
