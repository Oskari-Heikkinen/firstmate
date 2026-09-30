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

# fake_park_tools: an fm-park.sh whose validate accepts a handoff with a "Waiting for"
# section and whose park form records its arguments, and an fm-send.sh recording each steer.
fake_park_tools() {
  cat > "$C/home/bin/fm-park.sh" <<SH
#!/usr/bin/env bash
if [ "\$1" = validate ]; then grep -q '^## Waiting for' "\$2"; exit; fi
printf '%s\n' "\$*" >> "$C/park-calls"
SH
  cat > "$C/home/bin/fm-send.sh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$FM_HOME" "\$1" >> "$C/send-calls"
printf '%s\n' "\$2" > "$C/send-text"
SH
  chmod +x "$C/home/bin/fm-park.sh" "$C/home/bin/fm-send.sh"
}

# fake_crew_state <paused-ids> [delay-seconds]: listed ids read as a declared wait, others as working.
fake_crew_state() {
  cat > "$C/home/bin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
sleep ${2:-0}
case " $1 " in
  *" \$1 "*) echo "state: paused · source: status-log · waiting on a run" ;;
  *) echo "state: working · source: pane · busy" ;;
esac
SH
  chmod +x "$C/home/bin/fm-crew-state.sh"
}

HANDOFF='# Handoff\n\n## Goal\nx\n\n## Done\nd\n\n## Waiting for\n\npr-merged:https://example.test/pr/1\n\n## Next steps\ny\n'

test_park_level_parks_or_steers_idle_workers() {
  local id
  new_case park
  fake_ps 2500 10
  rm -f "$C/home/bin/fm-park.sh"
  guard tick >/dev/null
  assert_grep "park: bin/fm-park.sh is not installed in $C/home, so the park level acts as warn only" "$C/guard/events.log" "without fm-park.sh park is warn only and says so"
  fake_park_tools
  fake_crew_state "w-paused w-invalid w-nohandoff w-parked mate"
  for id in w-paused w-busy w-invalid w-nohandoff w-parked; do printf 'kind=ship\n' > "$C/home/state/$id.meta"; done
  printf 'park_state=parked\n' >> "$C/home/state/w-parked.meta"
  printf 'kind=secondmate\n' > "$C/home/state/mate.meta"
  for id in w-paused w-busy w-invalid w-parked mate; do mkdir -p "$C/home/data/$id"; done
  for id in w-paused w-busy w-parked mate; do printf '%b' "$HANDOFF" > "$C/home/data/$id/handoff.md"; done
  printf '# Handoff\n\n## Goal\nx\n' > "$C/home/data/w-invalid/handoff.md"
  FM_MEM_GUARD_NOW=1000100 guard tick >/dev/null
  assert_absent "$C/park-calls" "a second pass inside park_interval_s does nothing"
  assert_absent "$C/send-calls" "a second pass inside park_interval_s steers nobody"
  FM_MEM_GUARD_NOW=1001000 guard tick >/dev/null
  assert_equals "w-paused --handoff $C/home/data/w-paused/handoff.md" "$(cat "$C/park-calls")" "only the idle worker with a valid handoff is parked, with no guessed condition"
  assert_equals "$C/home w-invalid"$'\n'"$C/home w-nohandoff" "$(sort "$C/send-calls")" "idle workers without a valid handoff are steered once each through this home"
  assert_contains "$(cat "$C/send-text")" "park yourself with $C/home/bin/fm-park.sh w-nohandoff --handoff $C/home/data/w-nohandoff/handoff.md" "the steer names the handoff and the park command"
  assert_grep "park: $C/home w-paused parked" "$C/guard/events.log" "the park is logged"
  assert_grep "park: $C/home w-invalid steered to write its handoff and park itself" "$C/guard/events.log" "the steer is logged"
  FM_MEM_GUARD_NOW=1001100 guard tick >/dev/null
  assert_equals 2 "$(wc -l < "$C/send-calls" | tr -d ' ')" "a worker is steered at most once per park_interval_s"
  pass "the park level parks idle workers with a valid handoff, steers the rest once per interval, or logs warn-only without fm-park.sh"
}

test_park_pass_resumes_where_it_stopped_and_needs_time_to_park() {
  local id
  new_case parkresume
  fake_ps 2500 10
  fake_park_tools
  fake_crew_state "w-a w-b w-c"
  for id in w-a w-b w-c; do printf 'kind=ship\n' > "$C/home/state/$id.meta"; done
  mkdir -p "$C/home/data/w-b"
  printf '%b' "$HANDOFF" > "$C/home/data/w-b/handoff.md"
  FM_CHECK_TIMEOUT=19 guard tick >/dev/null
  assert_absent "$C/park-calls" "no park starts with under 15s of the check timeout left"
  assert_equals "$C/home w-a" "$(cat "$C/send-calls")" "the pass handled the workers before its stop"
  assert_grep "park: $C/home pass reached its time budget; the next pass starts at w-c" "$C/guard/events.log" "the stop is logged with where the next pass starts"
  FM_MEM_GUARD_NOW=1001000 FM_CHECK_TIMEOUT=19 guard tick >/dev/null
  assert_absent "$C/park-calls" "a pass that again cannot afford the park still starts none"
  assert_equals "$C/home w-a"$'\n'"$C/home w-c"$'\n'"$C/home w-a" "$(cat "$C/send-calls")" "the next pass starts past the unaffordable park, so later workers still progress"
  FM_MEM_GUARD_NOW=1002000 guard tick >/dev/null
  assert_equals "w-b --handoff $C/home/data/w-b/handoff.md" "$(cat "$C/park-calls")" "a pass with time for it parks the skipped worker"
  pass "a park pass never starts a park it cannot finish, and each pass progresses past where the last one stopped"
}

test_park_ignores_a_handoff_older_than_the_last_resume() {
  local now
  new_case parkstale
  fake_ps 2500 10
  fake_park_tools
  fake_crew_state "w-old w-new"
  now=$(date +%s)
  for id in w-old w-new; do
    printf 'kind=ship\npark_state=resumed\npark_at=%s\npark_resumed_at=%s\n' "$((now - 300))" "$((now - 100))" > "$C/home/state/$id.meta"
    mkdir -p "$C/home/data/$id"
    printf '%b' "$HANDOFF" > "$C/home/data/$id/handoff.md"
  done
  touch -d "@$((now - 400))" "$C/home/data/w-old/handoff.md"
  guard tick >/dev/null
  assert_equals "w-new --handoff $C/home/data/w-new/handoff.md" "$(cat "$C/park-calls")" "a handoff written after the resume is parked"
  assert_equals "$C/home w-old" "$(cat "$C/send-calls")" "a handoff from before the resume is not reused; the worker is steered to write a fresh one"
  pass "the park level never re-parks from a handoff that predates the task's last park or resume"
}

test_critical_wake_precedes_park_work() {
  local out rc
  new_case wakefirst
  fake_ps 900 10
  fake_park_tools
  fake_crew_state "w-a w-b" 30
  for id in w-a w-b; do printf 'kind=ship\n' > "$C/home/state/$id.meta"; done
  out=$(timeout 2 "$GUARD" tick --check 2>/dev/null)
  assert_equals "memory guard critical: Windows available 900 MiB (critical); new agents and heavy jobs are refused; park or finish waiting workers and stop heavy jobs (bin/fm-mem-guard.sh status)" "$out" "a check killed during park work still delivered the wake"
  assert_present "$C/home/state/.mem-guard-wake" "the wake epoch is recorded before park work"
  rm -f "$C/home/state/.mem-guard-wake" "$C/home/state/.mem-guard-park"
  out=$(FM_CHECK_TIMEOUT=9 timeout 15 "$GUARD" tick --check 2>/dev/null); rc=$?
  expect_code 0 "$rc" "a park pass bounded by the check timeout"
  assert_contains "$out" "memory guard critical" "the bounded tick still wakes"
  pass "the critical wake is printed and recorded before park work, and the park pass ends inside the check timeout"
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
  out=$("$C/home/state/mem-guard.check.sh" 2>&1) || fail "the generated check failed: $out"
  assert_equals "" "$out" "the generated check prints nothing on a healthy machine"
  fake_ps 900 10
  guard sample --fresh >/dev/null
  out=$("$C/home/state/mem-guard.check.sh" 2>&1) || fail "the generated check failed: $out"
  assert_equals "memory guard critical: Windows available 900 MiB (critical); new agents and heavy jobs are refused; park or finish waiting workers and stop heavy jobs (bin/fm-mem-guard.sh status)" "$out" "the generated check prints exactly the wake line when critical"
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
test_park_level_parks_or_steers_idle_workers
test_park_pass_resumes_where_it_stopped_and_needs_time_to_park
test_park_ignores_a_handoff_older_than_the_last_resume
test_critical_wake_precedes_park_work
test_rules_override_and_malformed_values_warn
test_auto_sync_arms_and_retires_the_check
test_job_cap_scopes_and_refuses

echo "# all fm-mem-guard tests passed"
