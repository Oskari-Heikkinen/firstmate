#!/usr/bin/env bash
# Behavior tests for bin/fm-mem-guard.sh and bin/fm-job-cap.sh.
#
# Every case reads a fake /proc (meminfo and pressure/memory) through
# FM_PROC_ROOT_OVERRIDE, a fake powershell through FM_MEM_GUARD_POWERSHELL, its
# own rules file, guard directory, and home, and a fixed clock through
# FM_MEM_GUARD_NOW, so no case depends on the test host's real memory or on
# Windows interop.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-mem-guard)
# tests/lib.sh disables the guard for every other suite; this one exercises it.
unset FM_MEM_GUARD

# write_proc <avail-kib> <full-avg10>
write_proc() {
  mkdir -p "$C/proc/pressure"
  printf 'MemTotal:       24000000 kB\nMemFree:          100000 kB\nMemAvailable:   %s kB\nBuffers:          524288 kB\nCached:          2097152 kB\nSwapTotal:       8388608 kB\nSwapFree:        4194304 kB\n' "$1" > "$C/proc/meminfo"
  printf 'some avg10=1.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$2" > "$C/proc/pressure/memory"
}

# fake_ps <available-mib> <pages-in/s> [delay-seconds]: a powershell.exe stub that counts its calls.
fake_ps() {
  cat > "$C/powershell.exe" <<SH
#!/usr/bin/env bash
echo call >> "$C/ps-calls"
sleep ${3:-0}
printf '32817692 %s %s %s 0\r\n' "\$(( $1 * 1024 ))" "$1" "$2"
SH
  chmod +x "$C/powershell.exe"
}

# new_case <name>: a primary home with a copy of bin/ so fakes can sit beside the guard.
new_case() {
  C="$TMP_ROOT/$1"
  mkdir -p "$C/home/state" "$C/home/data" "$C/home/config"
  cp -R "$ROOT/bin" "$C/home/bin"
  export FM_PROC_ROOT_OVERRIDE="$C/proc" FM_MEM_GUARD_POWERSHELL="$C/powershell.exe"
  export FM_ADMISSION_RULES="$C/rules.json" FM_MEM_GUARD_DIR="$C/guard" FM_HOME="$C/home"
  export FM_MEM_GUARD_NOW=1000000
  unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
  printf '{}\n' > "$C/rules.json"
  write_proc 16000000 0.00
  fake_ps 12000 10
  GUARD="$C/home/bin/fm-mem-guard.sh"
}

guard() { "$GUARD" "$@" 2>&1; }

test_sample_reads_both_sides_and_caches_windows() {
  local out
  new_case sample
  out=$(guard sample)
  assert_contains "$out" "win_available_mib=12000" "Windows available memory is read"
  assert_contains "$out" "win_paging_mibps=0.0" "Windows paging is read in MiB/s"
  assert_contains "$out" "win_source=powershell" "a fresh reading names powershell"
  assert_contains "$out" "linux_available_mib=15625" "Linux MemAvailable is read"
  assert_contains "$out" "linux_cache_mib=2560" "page cache counts Cached plus Buffers"
  assert_contains "$out" "linux_swap_used_mib=4096" "swap use is read"
  assert_contains "$out" "linux_psi_full_avg10=0.00" "memory pressure is read"
  FM_MEM_GUARD_NOW=1000030 guard sample > "$C/out2"
  assert_grep "win_source=cache 30s" "$C/out2" "a reading inside win_cache_s comes from the cache"
  assert_equals 1 "$(wc -l < "$C/ps-calls" | tr -d ' ')" "the cache saves a second powershell call"
  pass "sample reads Windows and Linux memory and shares one cached powershell reading"
}

test_sample_degrades_to_linux_only() {
  local out
  new_case degrade
  export FM_MEM_GUARD_POWERSHELL="$C/absent/powershell.exe"
  out=$(guard sample)
  assert_contains "$out" "win_source=unavailable: powershell.exe not found" "a missing powershell is named"
  assert_contains "$out" "linux_available_mib=15625" "Linux signals still sample"
  export FM_MEM_GUARD_POWERSHELL="$C/powershell.exe"
  fake_ps 12000 10 5
  printf '{"memory_guard": {"win_timeout_s": 1}}\n' > "$C/rules.json"
  write_proc 3000000 0.00
  out=$(guard tick)
  assert_contains "$out" "level=refuse" "Linux signals alone still grade the machine"
  assert_contains "$out" "Linux-only (Windows unavailable: powershell.exe timed out after 1s)" "a slow powershell is named"
  assert_grep "sample degraded to Linux-only: Windows unavailable: powershell.exe timed out after 1s" "$C/guard/events.log" "the degraded sample is logged with its reason"
  pass "a missing or slow powershell degrades the sample to Linux-only and says why"
}

test_grading_levels_and_hysteresis() {
  local out
  new_case grade
  out=$(guard tick)
  assert_contains "$out" "level=ok" "a healthy machine is ok"
  fake_ps 1800 12000
  FM_MEM_GUARD_NOW=1000100 guard sample --fresh >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000100 guard tick)
  assert_contains "$out" "level=refuse" "Windows available 1800 MiB grades refuse"
  assert_contains "$out" "Windows paging 46.9 MiB/s (warn)" "paging is graded on its own ladder"
  assert_equals "refuse 1000100 Windows available 1800 MiB (refuse); Windows paging 46.9 MiB/s (warn)" "$(FM_MEM_GUARD_NOW=1000100 guard level)" "level prints the recorded level"
  fake_ps 12000 10
  FM_MEM_GUARD_NOW=1000200 guard sample --fresh >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000200 guard tick)
  assert_contains "$out" "level=refuse" "one better sample does not clear the level"
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick)
  assert_contains "$out" "level=ok" "clear_samples better samples clear it"
  assert_grep "level ok -> refuse" "$C/guard/events.log" "the rise is logged"
  assert_grep "level refuse -> ok" "$C/guard/events.log" "the fall is logged"
  assert_equals 4 "$(wc -l < "$C/guard/samples.log" | tr -d ' ')" "each tick appends one sample line"
  assert_equals unknown "$(FM_MEM_GUARD_NOW=1009999 guard level)" "an old record reads unknown"
  pass "signals grade on their ladders, the level rises at once and falls after clear_samples"
}

test_admit_refuses_heavy_jobs() {
  local out rc
  new_case admit
  guard tick >/dev/null
  out=$(guard admit --cost-mib 4096); rc=$?
  expect_code 0 "$rc" "admit on a healthy machine"$'\n'"$out"
  assert_equals admit "$out" "a healthy machine admits"
  out=$(guard admit --cost-mib 13000); rc=$?
  expect_code 1 "$rc" "admit for a job that would cross the refuse line"
  assert_contains "$out" "refuse: memory guard: Linux available 15625 MiB minus this job's 13000 MiB is below the 3072 MiB refuse line" "the job's own cost is charged"
  fake_ps 900 10
  guard sample --fresh >/dev/null
  guard tick >/dev/null
  out=$(guard admit); rc=$?
  expect_code 1 "$rc" "admit while critical"
  assert_contains "$out" "refuse: memory guard is at critical: Windows available 900 MiB (critical)" "the recorded level refuses"
  out=$(FM_MEM_GUARD=off guard admit) || fail "FM_MEM_GUARD=off refused: $out"
  pass "admit refuses heavy jobs at refuse or critical and charges the job's memory"
}

test_critical_wakes_only_main_once_per_window() {
  local out
  new_case critical
  fake_ps 900 10
  out=$(guard tick --check)
  assert_contains "$out" "memory guard critical: Windows available 900 MiB (critical)" "critical prints one wake line"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the watcher form prints only the wake line"
  out=$(FM_MEM_GUARD_NOW=1000100 guard tick --check)
  assert_equals "" "$out" "no repeat wake inside critical_rewake_s"
  out=$(FM_MEM_GUARD_NOW=1002000 guard tick --check)
  assert_contains "$out" "memory guard critical" "the wake repeats after critical_rewake_s"
  touch "$C/home/.fm-secondmate-home"
  rm -f "$C/home/state/.mem-guard-wake"
  out=$(FM_MEM_GUARD_NOW=1004000 guard tick --check)
  assert_equals "" "$out" "a secondmate home never prints the critical wake"
  pass "critical wakes a primary home once per critical_rewake_s and never a secondmate home"
}

test_park_level_parks_idle_workers_with_a_handoff() {
  local out
  new_case park
  fake_ps 2500 10
  rm -f "$C/home/bin/fm-park.sh"
  guard tick >/dev/null
  assert_grep "park: bin/fm-park.sh is not installed in $C/home, so the park level acts as warn only" "$C/guard/events.log" "without fm-park.sh park is warn only and says so"
  cat > "$C/home/bin/fm-park.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$C/park-calls"
SH
  cat > "$C/home/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  w-paused) echo "state: paused · source: status-log · waiting on a run" ;;
  *) echo "state: working · source: pane · busy" ;;
esac
SH
  chmod +x "$C/home/bin/fm-park.sh" "$C/home/bin/fm-crew-state.sh"
  for id in w-paused w-busy w-nohandoff; do printf 'kind=ship\n' > "$C/home/state/$id.meta"; done
  printf 'kind=secondmate\n' > "$C/home/state/mate.meta"
  mkdir -p "$C/home/data/w-paused" "$C/home/data/w-busy" "$C/home/data/mate"
  printf '# Handoff\n\n## Goal\nx\n\n## Waiting for\n\npr-merged https://example.test/pr/1\n\n## Next steps\ny\n' > "$C/home/data/w-paused/handoff.md"
  cp "$C/home/data/w-paused/handoff.md" "$C/home/data/w-busy/handoff.md"
  cp "$C/home/data/w-paused/handoff.md" "$C/home/data/mate/handoff.md"
  FM_MEM_GUARD_NOW=1000100 guard tick >/dev/null
  assert_absent "$C/park-calls" "a second park inside park_interval_s does nothing"
  FM_MEM_GUARD_NOW=1001000 guard tick >/dev/null
  assert_equals "w-paused --handoff $C/home/data/w-paused/handoff.md --when pr-merged https://example.test/pr/1" "$(cat "$C/park-calls")" "only the declared-wait worker with a handoff is parked, with its wait condition"
  assert_grep "park: $C/home w-paused parked" "$C/guard/events.log" "the park is logged"
  pass "the park level parks this home's idle workers through fm-park.sh, or logs warn-only without it"
}

test_rules_override_and_malformed_values_warn() {
  local out
  new_case rules
  printf '{"memory_guard": {"win_available_mib": [20000, 15000, 13000, 100], "clear_samples": "x"}}\n' > "$C/rules.json"
  out=$(guard tick)
  assert_contains "$out" "level=refuse" "configured thresholds apply"
  assert_contains "$out" "clear_samples" "a malformed key is named"
  printf '{"memory_guard": {"linux_available_mib": [1, 2]}}\n' > "$C/rules.json"
  out=$(guard status)
  assert_contains "$out" "is not four numbers" "a short threshold list warns"
  pass "rules override thresholds and malformed values warn and keep defaults"
}

test_auto_sync_arms_and_retires_the_check() {
  local out
  new_case auto
  out=$(FM_HOME="$C/home" "$GUARD" auto sync 2>&1) || fail "auto sync failed: $out"
  assert_present "$C/home/state/mem-guard.check.sh" "sync arms the check"
  assert_present "$C/home/state/mem-guard.check-trust" "sync registers the check"
  assert_grep "tick --check" "$C/home/state/mem-guard.check.sh" "the check runs the watcher form"
  out=$("$GUARD" auto off 2>&1) || fail "auto off failed: $out"
  assert_absent "$C/home/state/mem-guard.check.sh" "off retires the check"
  assert_equals off "$(cat "$C/home/config/mem-guard")" "off is recorded"
  "$GUARD" auto sync >/dev/null 2>&1
  assert_absent "$C/home/state/mem-guard.check.sh" "sync respects off"
  pass "auto sync arms and registers the watcher check, and off retires it"
}

test_job_cap_scopes_and_refuses() {
  local out rc fakebin dev
  new_case jobcap
  fakebin=$(fm_fakebin "$C")
  cat > "$fakebin/systemd-run" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$C/run-args"
SH
  chmod +x "$fakebin/systemd-run"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/systemctl"
  export FM_JOB_CAP_SYSTEMD_RUN="$fakebin/systemd-run" FM_JOB_CAP_SYSTEMCTL="$fakebin/systemctl"
  dev=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [ -b "$dev" ]; then
    printf '{"job_cap": {"mem_max": "3G"}}\n' > "$C/rules.json"
    out=$("$C/home/bin/fm-job-cap.sh" --mem-high 2G -- true 2>&1) || fail "job cap failed: $out"
    assert_grep "MemoryHigh=2G" "$C/run-args" "a flag sets MemoryHigh"
    assert_grep "MemoryMax=3G" "$C/run-args" "the rules file sets MemoryMax"
    assert_grep "MemorySwapMax=2G" "$C/run-args" "the default swap cap applies"
    assert_grep "IOReadBandwidthMax=$dev 40M" "$C/run-args" "the disk-speed cap applies to the root disk"
  else
    echo "# skip: no block device backs / here, so the scope-property case cannot run"
  fi
  out=$("$C/home/bin/fm-job-cap.sh" --mem-max 1Q -- true 2>&1); rc=$?
  expect_code 2 "$rc" "a bad size"
  guard tick >/dev/null
  out=$("$C/home/bin/fm-job-cap.sh" --admit --mem-max 14G -- true 2>&1); rc=$?
  expect_code 75 "$rc" "an admitted job that would cross the refuse line"
  assert_contains "$out" "fm-job-cap: refuse: memory guard" "the refusal names the memory guard"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  out=$("$C/home/bin/fm-job-cap.sh" --no-nice -- echo ran 2>&1) || fail "uncapped fallback failed: $out"
  assert_contains "$out" "no user systemd manager" "the missing manager is named"
  assert_contains "$out" "ran" "the job still runs"
  out=$("$C/home/bin/fm-job-cap.sh" --strict -- echo ran 2>&1); rc=$?
  expect_code 3 "$rc" "--strict without a manager"
  unset FM_JOB_CAP_SYSTEMD_RUN FM_JOB_CAP_SYSTEMCTL
  pass "fm-job-cap scopes memory and disk caps, refuses through the guard, and says when it cannot cap"
}

test_sample_reads_both_sides_and_caches_windows
test_sample_degrades_to_linux_only
test_grading_levels_and_hysteresis
test_admit_refuses_heavy_jobs
test_critical_wakes_only_main_once_per_window
test_park_level_parks_idle_workers_with_a_handoff
test_rules_override_and_malformed_values_warn
test_auto_sync_arms_and_retires_the_check
test_job_cap_scopes_and_refuses

echo "# all fm-mem-guard tests passed"
