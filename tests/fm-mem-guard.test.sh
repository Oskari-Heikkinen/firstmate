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

# write_proc <avail-kib> <full-avg10> [swap-free-kib] [swap-cached-kib] [pswpout-pages]
write_proc() {
  mkdir -p "$C/proc/pressure"
  printf 'MemTotal:       24000000 kB\nMemFree:          100000 kB\nMemAvailable:   %s kB\nBuffers:          524288 kB\nCached:          2097152 kB\nSwapCached:     %s kB\nSwapTotal:       8388608 kB\nSwapFree:        %s kB\n' "$1" "${4:-0}" "${3:-7340032}" > "$C/proc/meminfo"
  printf 'pswpin 0\npswpout %s\n' "${5:-0}" > "$C/proc/vmstat"
  printf 'some avg10=1.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$2" > "$C/proc/pressure/memory"
}

# fake_ps <available-mib> <pages-in/s> [delay-seconds] [non-paged-pool-mib] [vm-faults/s] [vm-pid] [vm-clock-offset-ms]:
# a powershell.exe stub that counts its calls and prints raw counters on
# FM_MEM_GUARD_NOW's clock: a cumulative page-in count that grows at the given rate
# since the previous call and starts just below the 32-bit wrap, a 2 pages/s page-out
# count, a 10 MHz perf clock, the non-paged pool (default 600 MiB), and the vmmemWSL
# process (default pid 4242) with a cumulative fault count growing at vm-faults/s
# (default the page-in rate, so all paging is the VM's) from just below the wrap.
# vm-faults/s `-` prints no vmmemWSL process.
fake_ps() {
  cat > "$C/powershell.exe" <<SH
#!/usr/bin/env bash
echo call >> "$C/ps-calls"
sleep ${3:-0}
now=\${FM_MEM_GUARD_NOW:-0}
{ read -r last total vm < "$C/ps-pages"; } 2>/dev/null || { last=\$now; total=4294967000; vm=4294966000; }
total=\$(( (total + (now - last) * $2) % 4294967296 ))
case "${5:-$2}" in - | legacy | bad) ;; *) vm=\$(( (vm + (now - last) * ${5:-$2}) % 4294967296 )) ;; esac
printf '%s %s %s\n' "\$now" "\$total" "\$vm" > "$C/ps-pages"
case "${5:-$2}" in
  -) w='- - - -' ;;
  legacy) w= ;;
  bad) w="${6:-4242} 12x 1 10000000" ;;
  *) w="${6:-4242} \$vm \$(( now * 10000000 + ${7:-0} * 10000 )) 10000000" ;;
esac
printf '32817692 %s %s %s %s %s 10000000 %s %s\r\n' "\$(( $1 * 1024 ))" "$1" "\$total" "\$(( now * 2 % 4294967296 ))" "\$(( now * 10000000 ))" "\$(( ${4:-600} * 1048576 ))" "\$w"
SH
  chmod +x "$C/powershell.exe"
}

# WIN_LADDER opts a case into grading Windows available memory, which the
# defaults only sample, so Windows readings can drive a case's level.
WIN_LADDER='{"memory_guard": {"win_available_mib": [4096, 3072, 2048, 1024]}}'

# new_case <name>: a primary home with a copy of bin/ so fakes can sit beside the guard.
new_case() {
  C="$TMP_ROOT/$1"
  mkdir -p "$C/home/state" "$C/home/data" "$C/home/config"
  cp -R "$ROOT/bin" "$C/home/bin"
  export FM_PROC_ROOT_OVERRIDE="$C/proc" FM_MEM_GUARD_POWERSHELL="$C/powershell.exe"
  export FM_ADMISSION_RULES="$C/rules.json" FM_MEM_GUARD_DIR="$C/guard" FM_HOME="$C/home"
  export FM_MEM_GUARD_NOW=1000000
  unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
  printf '%s\n' "$WIN_LADDER" > "$C/rules.json"
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
  assert_contains "$out" "win_pages_in_ps="$'\n' "one reading has no paging rate yet"
  assert_contains "$out" "win_nonpaged_pool_mib=600" "the non-paged pool is read"
  assert_contains "$out" "win_source=powershell" "a fresh reading names powershell"
  assert_contains "$out" "linux_available_mib=15625" "Linux MemAvailable is read"
  assert_contains "$out" "linux_cache_mib=2560" "page cache counts Cached plus Buffers"
  assert_contains "$out" "linux_swap_used_mib=1024" "swap use is read"
  assert_contains "$out" "linux_psi_full_avg10=0.00" "memory pressure is read"
  FM_MEM_GUARD_NOW=1000030 guard sample > "$C/out2"
  assert_grep "win_source=cache 30s" "$C/out2" "a reading inside win_cache_s comes from the cache"
  assert_equals 1 "$(wc -l < "$C/ps-calls" | tr -d ' ')" "the cache saves a second powershell call"
  out=$(FM_MEM_GUARD_NOW=1000040 guard sample --fresh)
  assert_contains "$out" "win_paging_span_s="$'\n' "readings under 60s apart give no rate"
  out=$(FM_MEM_GUARD_NOW=1000090 guard sample --fresh)
  assert_contains "$out" "win_pages_in_ps=10"$'\n' "pages input is averaged across the 32-bit counter wrap"
  assert_contains "$out" "win_pages_out_ps=2"$'\n' "pages output is read for the log"
  assert_contains "$out" "win_paging_span_s=90"$'\n' "a reading under 60s after the last keeps measuring from the older baseline"
  assert_contains "$out" "win_vm_faults_ps=10"$'\n' "the VM's faults are averaged across the 32-bit counter wrap"
  assert_contains "$out" "win_vm_paging_span_s=90"$'\n' "the VM's faults are measured from the same baseline"
  assert_contains "$out" "win_vm_source=vmmemWSL pid 4242"$'\n' "the VM process is named"
  pass "sample reads Windows and Linux memory, averages paging between readings, and shares one cached powershell reading"
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
  fake_ps 1800 300
  FM_MEM_GUARD_NOW=1000100 guard sample --fresh >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000100 guard tick)
  assert_contains "$out" "level=refuse" "Windows available 1800 MiB grades refuse"
  assert_contains "$out" "WSL VM paging upper bound 300/s (the lower of vmmemWSL faults 300/s and Windows pages input 300/s over the same 100s) (park)" "paging is graded on its own ladder"
  assert_equals "refuse 1000100 Windows available 1800 MiB (refuse); WSL VM paging upper bound 300/s (the lower of vmmemWSL faults 300/s and Windows pages input 300/s over the same 100s) (park)" "$(FM_MEM_GUARD_NOW=1000100 guard level)" "level prints the recorded level"
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

test_defaults_grade_linux_and_only_sample_windows_available() {
  local out
  new_case defaults
  printf '{}\n' > "$C/rules.json"
  fake_ps 900 10
  out=$(guard tick)
  assert_contains "$out" "level=ok" "low Windows available memory alone does not grade by default"
  assert_grep "win_avail_mib=900" "$C/guard/samples.log" "Windows available memory is still logged"
  write_proc 3600000 0.00
  out=$(FM_MEM_GUARD_NOW=1000100 guard tick)
  assert_contains "$out" "Linux available 3515 MiB (park)" "Linux MemAvailable grades on its default ladder"
  pass "defaults grade Linux memory and only sample Windows available memory"
}

test_swap_grades_only_while_growing() {
  local out
  new_case swap
  printf '{}\n' > "$C/rules.json"
  # 1 GiB free and 1 GiB swap-cached of 8 GiB: 6144 MiB counts as used.
  write_proc 12582912 0.00 1048576 1048576 0
  out=$(guard tick)
  assert_contains "$out" "level=ok" "swap without a previous tick's swap-out reading grades ok"
  write_proc 12582912 0.00 1048576 1048576 128000
  out=$(FM_MEM_GUARD_NOW=1000100 guard tick)
  assert_contains "$out" "level=refuse" "swap past the refuse line while swapping out grades refuse"
  assert_contains "$out" "Linux swap used 6144 MiB, growing 5.0 MiB/s (refuse)" "swap-cached pages are not counted and the growth is named"
  out=$(FM_MEM_GUARD_NOW=1000200 guard tick)
  assert_contains "$out" "reasons=all signals within limits" "the same swap with no swap-out grades ok"
  assert_contains "$out" "level=refuse" "one quiet tick holds the level"
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick)
  assert_contains "$out" "level=ok" "residual swap after swapping stops clears the level"
  assert_grep "level refuse -> ok" "$C/guard/events.log" "the fall is logged"
  write_proc 12582912 0.00 1048576 1048576 128768
  out=$(FM_MEM_GUARD_NOW=1000302 guard tick)
  assert_contains "$out" "level=ok" "a small swap-out batch two seconds after another home's tick is measured over at least 60s"
  write_proc 12582912 0.00 0 0 1000000
  out=$(FM_MEM_GUARD_NOW=1000400 guard tick)
  assert_contains "$out" "level=refuse" "swap alone never grades critical"
  pass "swap grades only on a tick where it grows, never past refuse, and residual swap clears"
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

# The starved laptop's readings: page-ins sustained in the hundreds and a 4.4 GiB
# non-paged pool, while Windows available memory (1.6 GiB) is left ungraded.
test_starved_windows_host_tells_main_start_repeat_and_clear() {
  local out t
  new_case starved
  printf '{}\n' > "$C/rules.json"
  fake_ps 1600 700 0 4506
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick --check)
  assert_contains "$out" "memory guard refuse: WSL VM paging upper bound 700/s (the lower of vmmemWSL faults 700/s and Windows pages input 700/s over the same 300s) (refuse)" "sustained page-ins grade above ok and name the rate"
  assert_contains "$out" "Windows non-paged pool 4506 MiB, normal is under 1024 MiB (warn: a leaking Windows driver is the likely cause" "the abnormal pool is named with its likely cause"
  assert_contains "$out" "new agents and heavy jobs are refused" "the wake names the response"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the state's start is told in one line"
  fake_ps 1600 1250 0 4506
  out=$(FM_MEM_GUARD_NOW=1000600 guard tick --check)
  assert_contains "$out" "memory guard critical: WSL VM paging upper bound 1250/s" "a rise inside the repeat window is told at once"
  fake_ps 1600 600 0 4506
  for t in 1000900 1001200 1001500 1001800 1002100; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "a steady or falling state inside rewake_s stays silent at $t"
  done
  out=$(FM_MEM_GUARD_NOW=1002400 guard tick --check)
  assert_contains "$out" "memory guard refuse: WSL VM paging upper bound 600/s (the lower of vmmemWSL faults 600/s and Windows pages input 600/s over the same 300s) (refuse)" "the state is told again after rewake_s"
  fake_ps 6000 50 0 600
  out=$(FM_MEM_GUARD_NOW=1002700 guard tick --check)
  assert_equals "" "$out" "one healthy sample holds the level without a notice"
  for t in 1003000 1003300; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "a clear younger than 600 seconds is not told yet at $t"
  done
  out=$(FM_MEM_GUARD_NOW=1003600 guard tick --check)
  assert_equals "memory guard cleared: level ok: all signals within limits (bin/fm-mem-guard.sh status)" "$out" "the clear is told once it has lasted 600 seconds"
  out=$(FM_MEM_GUARD_NOW=1003900 guard tick --check)
  assert_equals "" "$out" "a healthy machine after the clear stays silent"
  pass "a starved Windows host grades above ok naming paging and the pool, and main is told at the start, on a rise, on the repeat cadence and once after a sustained clear"
}

# Paging alone (normal pool) drives these cases: refuse at 700 pages/s, critical
# at 1250, ok at 50; a fall to ok takes two healthy ticks.
flap_case() {  # <name>
  new_case "$1"
  printf '{}\n' > "$C/rules.json"
  fake_ps 1600 700
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick --check)
  assert_contains "$out" "memory guard refuse: WSL VM paging upper bound 700/s" "$1: the state's start wakes main"
}

test_flapping_state_folds_into_one_clear() {
  local out t
  flap_case flapfold
  fake_ps 6000 50
  for t in 1000600 1000900; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "a fresh clear is not told at $t"
  done
  fake_ps 1600 700
  out=$(FM_MEM_GUARD_NOW=1001200 guard tick --check)
  assert_equals "" "$out" "a return at the told level inside the hold folds into the open notice"
  fake_ps 6000 50
  for t in 1001500 1001800 1002100; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "the second clear is not told before 600 seconds at $t"
  done
  out=$(FM_MEM_GUARD_NOW=1002400 guard tick --check)
  assert_equals "memory guard cleared: level ok: all signals within limits (bin/fm-mem-guard.sh status)" "$out" "the flapping state ends in one clear notice"
  assert_absent "$C/home/state/.mem-guard-wake" "a clear told past rewake_s drops the record"
  pass "a state that clears and returns inside 600 seconds folds into its open notice and one clear"
}

test_return_after_a_told_clear_wakes_only_higher() {
  local out t
  flap_case flaphold
  fake_ps 6000 50
  for t in 1000600 1000900 1001200; do
    FM_MEM_GUARD_NOW=$t guard tick --check >/dev/null
  done
  out=$(FM_MEM_GUARD_NOW=1001500 guard tick --check)
  assert_contains "$out" "memory guard cleared" "the sustained clear is told"
  assert_present "$C/home/state/.mem-guard-wake" "the record outlives a told clear inside rewake_s"
  fake_ps 1600 700
  out=$(FM_MEM_GUARD_NOW=1001800 guard tick --check)
  assert_equals "" "$out" "a return at the told level inside rewake_s stays quiet"
  fake_ps 1600 1250
  out=$(FM_MEM_GUARD_NOW=1002100 guard tick --check)
  assert_contains "$out" "memory guard critical: WSL VM paging upper bound 1250/s" "a return above the told level wakes at once"
  pass "after a told clear, a return inside rewake_s wakes only above the level last told"
}

test_silent_downgrade_keeps_the_last_notified_level() {
  local out t
  new_case flaphighwater
  printf '{}\n' > "$C/rules.json"
  fake_ps 1600 1250
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick --check)
  assert_contains "$out" 'memory guard critical' 'the initial critical alarm still wakes'
  fake_ps 6000 50
  for t in 1000600 1000900 1001200; do
    FM_MEM_GUARD_NOW=$t guard tick --check >/dev/null
  done
  out=$(FM_MEM_GUARD_NOW=1001500 guard tick --check)
  assert_contains "$out" 'memory guard cleared' 'sustained clear is still told'
  fake_ps 1600 700
  out=$(FM_MEM_GUARD_NOW=1001800 guard tick --check)
  assert_equals '' "$out" 'lower re-entry does not wake'
  fake_ps 1600 1250
  out=$(FM_MEM_GUARD_NOW=1002000 guard tick --check)
  assert_equals '' "$out" 'return to the last notified level is not a new escalation'
  out=$(FM_MEM_GUARD_NOW=1002100 guard tick --check)
  assert_contains "$out" 'memory guard critical' 'the repeat still wakes at rewake_s'
  pass 'silent downgrade preserves the last notified level without suppressing its repeat'
}

test_silent_reentry_does_not_reopen_a_told_clear() {
  local out t initial actual
  for initial in 700 1250; do
    new_case "told-clear-$initial"
    printf '{"memory_guard":{"rewake_s":7200}}\n' > "$C/rules.json"
    fake_ps 1600 "$initial"
    guard sample >/dev/null
    out=$(FM_MEM_GUARD_NOW=1000300 guard tick --check)
    assert_contains "$out" 'memory guard ' 'the initial alarm is delivered'
    fake_ps 6000 50
    for t in 1000600 1000900 1001200; do
      out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
      assert_equals '' "$out" 'the initial clear still waits for sustained recovery'
    done
    out=$(FM_MEM_GUARD_NOW=1001500 guard tick --check)
    assert_contains "$out" 'memory guard cleared' 'the first clear is delivered'
    fake_ps 1600 700
    out=$(FM_MEM_GUARD_NOW=1001800 guard tick --check)
    assert_equals '' "$out" 'same or lower re-entry is unannounced'
    fake_ps 6000 50
    for t in 1002100 1002400 1002700 1003000; do
      out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
      assert_equals '' "$out" "unannounced re-entry must not produce another clear at $t"
    done
    # Both a higher-level notice and a scheduled repeat reopen a clear.
    actual=1003300
    [ "$initial" != 1250 ] || actual=1007500
    fake_ps 1600 1250
    out=$(FM_MEM_GUARD_NOW=$actual guard tick --check)
    assert_contains "$out" 'memory guard critical' 'a real escalation or repeat still wakes'
    fake_ps 6000 50
    for t in $((actual + 300)) $((actual + 600)) $((actual + 900)); do
      out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
      assert_equals '' "$out" 'the newly opened clear still waits for sustained recovery'
    done
    out=$(FM_MEM_GUARD_NOW=$((actual + 1200)) guard tick --check)
    assert_contains "$out" 'memory guard cleared' 'a real new wake permits its own clear notice'
  done
  pass 'same/lower silent re-entry keeps a told clear closed until an actual wake'
}

test_told_clear_record_expires_after_rewake() {
  local out t
  flap_case flapexpire
  fake_ps 6000 50
  for t in 1000600 1000900 1001200; do
    FM_MEM_GUARD_NOW=$t guard tick --check >/dev/null
  done
  out=$(FM_MEM_GUARD_NOW=1001500 guard tick --check)
  assert_contains "$out" "memory guard cleared" "the sustained clear is told"
  out=$(FM_MEM_GUARD_NOW=1002100 guard tick --check)
  assert_equals "" "$out" "the told clear's record expires silently"
  assert_absent "$C/home/state/.mem-guard-wake" "the record is gone rewake_s after the last wake"
  fake_ps 1600 700
  out=$(FM_MEM_GUARD_NOW=1002400 guard tick --check)
  assert_contains "$out" "memory guard refuse: WSL VM paging upper bound 700/s" "a return after rewake_s wakes at the same level"
  pass "a told clear's record expires rewake_s after the last wake, and a later return wakes again"
}

test_healthy_windows_host_stays_ok_and_silent() {
  local out t
  new_case healthy
  printf '{}\n' > "$C/rules.json"
  fake_ps 1600 90 0 600
  for t in 1000000 1000300 1000600; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "a healthy host prints nothing at $t"
  done
  out=$(FM_MEM_GUARD_NOW=1000600 guard status)
  assert_contains "$out" "win_pages_in_ps=90"$'\n' "the healthy rate was measured"
  assert_contains "$out" "graded=ok" "paging under 100/s and a 600 MiB pool grade ok"
  assert_absent "$C/home/state/.mem-guard-wake" "no notice is held open"
  pass "paging under 100/s and a normal non-paged pool stay ok and silent"
}

# The native Windows build case: system-wide page-ins in the thousands while the
# VM's own faults stay low, and the reverse, VM faults (demand-zero churn) far above
# the system's page-ins, which bound the VM's hard faults from above.
test_windows_side_paging_grades_at_most_warn_and_admits() {
  local out rc
  new_case winside
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 3000 0 600 90
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick)
  assert_contains "$out" "level=warn" "system-wide paging with a quiet VM grades warn"
  assert_contains "$out" "Windows pages input 3000/s averaged over 300s, WSL VM paging upper bound 90/s (warn: Windows-side paging only grades warn)" "the reason separates Windows-side paging from the VM's"
  out=$(FM_MEM_GUARD_NOW=1000300 guard admit --cost-mib 1024); rc=$?
  expect_code 0 "$rc" "admit while Windows-side paging is high"$'\n'"$out"
  assert_equals admit "$out" "Windows-side paging does not refuse"
  assert_absent "$C/home/state/.mem-guard-park" "Windows-side paging starts no park pass"
  fake_ps 12000 120 0 600 5000
  out=$(FM_MEM_GUARD_NOW=1000600 guard tick)
  assert_contains "$out" "WSL VM paging upper bound 120/s (the lower of vmmemWSL faults 5000/s and Windows pages input 120/s over the same 300s) (warn)" "VM faults above the system's page-ins are bounded by them"
  assert_contains "$out" "level=warn" "VM soft faults alone do not park"
  pass "system-wide Windows paging grades at most warn and admits, and VM faults count only up to the system's page-ins"
}

test_vm_paging_parks_and_refuses() {
  local out rc
  new_case vmpaging
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 300 0 600 300
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick)
  assert_contains "$out" "level=park" "VM paging of 300/s parks"
  fake_ps 12000 700 0 600 650
  out=$(FM_MEM_GUARD_NOW=1000600 guard tick)
  assert_contains "$out" "level=refuse" "VM paging of 650/s refuses"
  assert_contains "$out" "WSL VM paging upper bound 650/s (the lower of vmmemWSL faults 650/s and Windows pages input 700/s over the same 300s) (refuse)" "the VM's bound is the lower rate"
  out=$(FM_MEM_GUARD_NOW=1000600 guard admit); rc=$?
  expect_code 1 "$rc" "admit while the VM pages"
  assert_contains "$out" "refuse: memory guard is at refuse: WSL VM paging upper bound 650/s" "the recorded level refuses and names the VM's paging"
  pass "the WSL VM paging upper bound parks and refuses on the win_pages_in_ps ladder"
}

test_unknown_vm_share_grades_system_paging_on_the_full_ladder() {
  local out rc
  new_case vmunknown
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 600 0 600 -
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick)
  assert_contains "$out" "level=refuse" "no vmmemWSL process leaves the VM's share unknown, graded on the full ladder"
  assert_contains "$out" "Windows pages input 600/s averaged over 300s, graded as WSL VM paging because the VM's share is unknown: no single vmmemWSL process in the Windows reading (refuse)" "the reason says the VM share is unknown and why"
  assert_grep "WSL VM paging share unknown: no single vmmemWSL process in the Windows reading; system-wide Windows paging grades as WSL VM paging until it is measured again" "$C/guard/events.log" "the unknown share is logged"
  out=$(FM_MEM_GUARD_NOW=1000300 guard admit); rc=$?
  expect_code 1 "$rc" "admit with an unknown VM share and high paging"
  out=$(FM_MEM_GUARD_NOW=1000300 guard status)
  assert_contains "$out" "win_vm_source=unknown: no single vmmemWSL process in the Windows reading"$'\n' "status names the unknown VM share"
  fake_ps 12000 600 0 600 10
  FM_MEM_GUARD_NOW=1000600 guard tick >/dev/null
  fake_ps 12000 600 0 600 10 5555
  out=$(FM_MEM_GUARD_NOW=1000900 guard tick)
  assert_contains "$out" "the VM's share is unknown: vmmemWSL pid 5555 has no fault rate yet (needs two of its readings 60-600s apart) (refuse)" "a restarted VM process is not measured from the old process's baseline, and is not read as quiet"
  out=$(FM_MEM_GUARD_NOW=1001200 guard tick)
  assert_contains "$out" "WSL VM paging upper bound 10/s (warn" "the new VM process is measured from its own baseline"
  printf '%s\n' "999999 $(cut -d' ' -f2- "$C/guard/vm")" > "$C/guard/vm"
  out=$(FM_MEM_GUARD_NOW=1001210 guard tick)
  assert_contains "$out" "the VM's share is unknown: no vmmemWSL reading taken with this Windows reading (refuse)" "a VM record from another reading is not used, and is not read as quiet"
  out=$(FM_MEM_GUARD_NOW=1001500 guard tick)
  assert_contains "$out" "WSL VM paging upper bound 10/s (warn" "the VM rate holds before its baseline's perf frequency changes"
  printf '%s\n' "$(cut -d' ' -f1-5 "$C/guard/vm") 5000000 $(cut -d' ' -f7- "$C/guard/vm")" > "$C/guard/vm"
  out=$(FM_MEM_GUARD_NOW=1001800 guard tick)
  assert_contains "$out" "the VM's share is unknown: vmmemWSL pid 5555 has no fault rate yet (needs two of its readings 60-600s apart) (refuse)" "a VM baseline taken at another perf frequency is not used"
  fake_ps 12000 600 0 600 bad
  out=$(FM_MEM_GUARD_NOW=1002100 guard tick)
  assert_contains "$out" "Windows pages input 600/s averaged over 300s, graded as WSL VM paging because the VM's share is unknown: the Windows reading's vmmemWSL fields were missing or not numbers (refuse)" "unreadable vmmemWSL fields keep the Windows reading and leave the VM's share unknown"
  fake_ps 12000 600 0 600 legacy
  out=$(FM_MEM_GUARD_NOW=1002400 guard tick)
  assert_contains "$out" "Windows pages input 600/s averaged over 300s, graded as WSL VM paging because the VM's share is unknown: the Windows reading's vmmemWSL fields were missing or not numbers (refuse)" "a reading without the vmmemWSL fields keeps the Windows reading and leaves the VM's share unknown"
  pass "an unknown VM share grades system-wide paging on the full ladder, names why, and refuses rather than admits"
}

# The known over-grade of the upper bound: heavy native paging while the VM churns its
# memory with soft faults bounds the VM at the VM's fault rate, which can refuse with
# no VM disk paging. No unprivileged counter separates the two; this pins the contract.
test_native_paging_with_vm_soft_churn_grades_on_the_bound() {
  local out
  new_case overgrade
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 3000 0 600 650
  guard sample >/dev/null
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick)
  assert_contains "$out" "level=refuse" "the bound grades the full ladder when both rates are high"
  assert_contains "$out" "WSL VM paging upper bound 650/s (the lower of vmmemWSL faults 650/s and Windows pages input 3000/s over the same 300s) (refuse)" "the reason names the bound and both rates it comes from"
  pass "concurrent native paging and VM fault churn grade on the VM paging upper bound (the documented over-grade)"
}

# An older checkout refreshes only the windows record, moving its baseline while the
# vm record keeps an older one: the two rates then describe different intervals, and
# the VM's diluted rate must not cap the system-wide rate's recent burst at warn.
test_vm_and_system_rates_pair_one_interval() {
  local out
  new_case pairing
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 10 0 600 10
  guard sample >/dev/null
  cp "$C/guard/vm" "$C/vm-before"
  FM_MEM_GUARD_NOW=1000500 guard sample --fresh >/dev/null
  cp "$C/vm-before" "$C/guard/vm"
  fake_ps 12000 1000 0 600 1000
  out=$(FM_MEM_GUARD_NOW=1000600 guard tick)
  assert_contains "$out" "the VM's share is unknown: vmmemWSL pid 4242 has no fault rate yet (needs two of its readings 60-600s apart) (critical)" "rates over different intervals leave the VM's share unknown"
  assert_contains "$out" "level=critical" "the recent system-wide burst grades the full ladder"
  out=$(FM_MEM_GUARD_NOW=1000900 guard tick)
  assert_contains "$out" "WSL VM paging upper bound 1000/s (the lower of vmmemWSL faults 1000/s and Windows pages input 1000/s over the same 300s) (critical)" "readings taken together pair again"
  pass "the VM paging bound combines rates only over one shared interval"
}

# R2: near-threshold histories that the old five-second duration tolerance accepted.
# Every other signal stays healthy, and admission (not only prose) is asserted.
test_vm_baseline_identity_controls_admission() {
  local out rc lag mode
  for lag in 1 5 540; do
    new_case "identity-$lag"
    printf '{}\n' > "$C/rules.json"
    fake_ps 12000 0 0 600 0
    guard sample >/dev/null
    cp "$C/guard/vm" "$C/vm-before"
    FM_MEM_GUARD_NOW=$((1000000 + lag)) guard sample --fresh >/dev/null
    # An older writer (or a failed VM publication) advanced only Windows.
    cp "$C/vm-before" "$C/guard/vm"
    fake_ps 12000 500 0 600 500
    out=$(FM_MEM_GUARD_NOW=$((1000060 + lag)) guard tick)
    assert_contains "$out" "level=refuse" "a diluted VM baseline cannot admit a 500/s recent burst (lag $lag)"
    assert_contains "$out" "has no fault rate yet" "a missing selected baseline leaves the VM rate unknown"
    out=$(FM_MEM_GUARD_NOW=$((1000060 + lag)) guard admit); rc=$?
    expect_code 1 "$rc" "mixed baseline admission with lag $lag"$'\n'"$out"
  done

  # Missing, legacy and failed publication siblings must be conservative too.
  for mode in missing legacy failed; do
    new_case "identity-$mode"
    printf '{}\n' > "$C/rules.json"
    fake_ps 12000 0 0 600 0
    guard sample >/dev/null
    case "$mode" in
      missing) rm "$C/guard/vm" ;;
      legacy) cut -d' ' -f1-12 "$C/guard/vm" > "$C/legacy"; cp "$C/legacy" "$C/guard/vm" ;;
      failed)
        # An unwritable temporary destination fails the real VM publisher, not
        # Windows publication. A PATH stub affects mv only for that destination.
        mkdir "$C/tools"
        # shellcheck disable=SC2016 # evaluated by the fixture's mv stub
        printf '#!/usr/bin/env bash\ncase "${!#}" in */vm) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v mv)" > "$C/tools/mv"
        chmod +x "$C/tools/mv"
        ;;
    esac
    fake_ps 12000 500 0 600 500
    out=$(PATH="$C/tools:$PATH" FM_MEM_GUARD_NOW=1000060 guard tick)
    assert_contains "$out" "level=refuse" "$mode VM provenance never caps a recent 500/s burst"
    out=$(FM_MEM_GUARD_NOW=1000060 guard admit); rc=$?
    expect_code 1 "$rc" "$mode VM provenance admission"$'\n'"$out"
  done

  new_case identity-boundary
  printf '{"memory_guard":{"clear_samples":1}}\n' > "$C/rules.json"
  fake_ps 12000 0 0 600 0
  guard sample >/dev/null
  FM_MEM_GUARD_NOW=1000005 guard sample --fresh >/dev/null
  # At 65s Windows selects the 5s reading. The VM's 59.9s since that
  # reading must not independently select the 0s baseline.
  fake_ps 12000 500 0 600 500 4242 -100
  out=$(FM_MEM_GUARD_NOW=1000065 guard tick)
  assert_contains "$out" "level=refuse" "VM paging at the refuse line still refuses across provider skew"
  out=$(FM_MEM_GUARD_NOW=1000065 guard admit); rc=$?
  expect_code 1 "$rc" "60s boundary admission"$'\n'"$out"
  fake_ps 12000 500 0 600 10 4242 -100
  out=$(FM_MEM_GUARD_NOW=1000365 guard status)
  assert_contains "$out" "graded=warn" "genuine shared observations recover despite different provider timestamps"
  assert_contains "$out" "win_vm_source=vmmemWSL pid 4242" "the next common baseline restores VM provenance"

  # A cached row's claimed baseline must match exactly, even if its rates and
  # rounded duration look plausible. Other guards pass in this fixture.
  cp "$C/guard/vm" "$C/vm-before"
  awk '{$14 = sprintf("%.0f", $14 + 1); print}' "$C/vm-before" > "$C/guard/vm"
  out=$(FM_MEM_GUARD_NOW=1000365 guard tick)
  assert_contains "$out" "current or baseline Windows observation differs" "the reader rejects a different baseline even when both spans are 300s"
  out=$(FM_MEM_GUARD_NOW=1000365 guard admit); rc=$?
  expect_code 1 "$rc" "different baseline observation admission"$'\n'"$out"
  cp "$C/vm-before" "$C/guard/vm"

  # A same-second replacement must match the exact current observation too.
  cp "$C/guard/windows" "$C/windows-before"
  awk '{$7 = sprintf("%.0f", $7 + 1); print}' "$C/windows-before" > "$C/guard/windows"
  out=$(FM_MEM_GUARD_NOW=1000365 guard tick)
  assert_contains "$out" "level=refuse" "equal wall epochs do not prove the current perf observation matches"
  out=$(FM_MEM_GUARD_NOW=1000365 guard admit); rc=$?
  expect_code 1 "$rc" "same epoch, different current observation admission"$'\n'"$out"
  pass "VM bound admission requires exact current and baseline observation identity across mixed writers and publication gaps"
}

test_vm_baseline_selection_uses_windows_clock() {
  local out rc t offset
  new_case identity-selection
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 3000 0 600 10
  guard sample >/dev/null
  FM_MEM_GUARD_NOW=1000005 guard sample --fresh >/dev/null
  # Both rates must use Windows' 60s span, even though the VM provider's
  # timestamp interval straddles that boundary on each successive sample.
  offset=-100
  for t in 1000065 1000125 1000185 1000245; do
    fake_ps 12000 3000 0 600 10 4242 "$offset"
    out=$(FM_MEM_GUARD_NOW=$t guard tick)
    assert_contains "$out" "level=warn" "provider skew must not turn native paging into a refusal at $t"
    assert_contains "$out" "WSL VM paging upper bound 10/s" "Windows selects one common observation and rate clock"
    out=$(FM_MEM_GUARD_NOW=$t guard admit); rc=$?
    expect_code 0 "$rc" "provider skew native paging admission"$'\n'"$out"
    offset=$((-offset))
  done
  pass "one Windows baseline selection and rate clock keeps native paging warn-only across the 60s provider-skew boundary"
}

# Install synthetic current cache rows for multi-home occurrence tests. No sampling
# query is needed; both valid rates share exact current and baseline observations.
vm_notice_sample() {
  local t=$1 kind=$2 perf=$(( $1 * 10000000 )) base=$(( ($1 - 300) * 10000000 ))
  printf '%s 32817692 12288000 12000 15000 0 %s 10000000 629145600 0 0 %s 50 0 300\n' "$t" "$perf" "$base" > "$C/guard/windows"
  if [ "$kind" = known ]; then
    printf '%s 4242 15000 15000 %s 10000000 0 0 %s 50 50 300 %s %s\n' "$t" "$perf" "$base" "$perf" "$base" > "$C/guard/vm"
  else
    printf '%s - - - - - - - - - - - %s -\n' "$t" "$perf" > "$C/guard/vm"
  fi
}

test_vm_notice_tracks_cross_home_occurrences() {
  local out home token
  new_case vmnotice-homes
  printf '{}\n' > "$C/rules.json"
  mkdir -p "$C/guard" "$C/second/state" "$C/other-primary/state"
  touch "$C/second/.fm-secondmate-home"
  vm_notice_sample 1000000 unknown
  out=$(guard tick --check)
  assert_equals "" "$out" "main starts the first occurrence inside grace"
  vm_notice_sample 1000600 unknown
  for home in "$C/home" "$C/other-primary"; do
    out=$(FM_HOME="$home" FM_MEM_GUARD_NOW=1000600 guard tick --check)
    assert_contains "$out" "has been unknown for 600s" "each primary independently receives the first occurrence"
    out=$(FM_HOME="$home" FM_MEM_GUARD_NOW=1000600 guard tick --check)
    assert_equals "" "$out" "each primary deduplicates its own first occurrence"
  done
  token=$(cat "$C/home/state/.mem-guard-vm-notice")
  vm_notice_sample 1000601 known
  out=$(FM_HOME="$C/second" FM_MEM_GUARD_NOW=1000601 guard tick --check)
  assert_equals "" "$out" "secondmate alone sees recovery without waking"
  vm_notice_sample 1000602 unknown
  out=$(FM_HOME="$C/second" FM_MEM_GUARD_NOW=1000602 guard tick --check)
  assert_equals "" "$out" "secondmate starts a distinct occurrence without waking"
  # Main misses the recovery and remains inactive throughout the new grace.
  vm_notice_sample 1001202 unknown
  for home in "$C/home" "$C/other-primary"; do
    out=$(FM_HOME="$home" FM_MEM_GUARD_NOW=1001202 guard tick --check)
    assert_contains "$out" "has been unknown for 600s" "a primary's old acknowledgement cannot suppress the new occurrence"
    out=$(FM_HOME="$home" FM_MEM_GUARD_NOW=1001202 guard tick --check)
    assert_equals "" "$out" "a new occurrence is still delivered once per primary"
  done
  assert_not_contains "$(cat "$C/home/state/.mem-guard-vm-notice")" "$token" "delivery binds a new machine occurrence"

  # Complete Windows outage is neither recovery nor recurrence.
  out=$(FM_MEM_GUARD_POWERSHELL="$C/absent" FM_MEM_GUARD_NOW=1001903 guard tick --check)
  assert_equals "" "$out" "Windows-unavailable gap neither repeats nor clears VM delivery"
  vm_notice_sample 1002000 unknown
  out=$(FM_MEM_GUARD_NOW=1002000 guard tick --check)
  assert_equals "" "$out" "the same occurrence survives a Windows gap and process restarts"
  vm_notice_sample 1002001 known
  out=$(FM_MEM_GUARD_NOW=1002001 guard tick --check)
  assert_contains "$out" "share is measured again" "main can close its delivered occurrence on a known reading"
  out=$(FM_MEM_GUARD_NOW=1002001 guard tick --check)
  assert_equals "" "$out" "recovery is told only once"

  # An onset epoch alone is not unique: recovery and recurrence may share a second.
  printf '{"memory_guard":{"win_stale_max_s":0}}\n' > "$C/rules.json"
  vm_notice_sample 1002002 unknown
  out=$(FM_MEM_GUARD_NOW=1002002 guard tick --check)
  assert_contains "$out" "has been unknown for 0s" "zero configured grace delivers the occurrence"
  vm_notice_sample 1002002 known
  FM_HOME="$C/second" FM_MEM_GUARD_NOW=1002002 guard tick --check >/dev/null
  vm_notice_sample 1002002 unknown
  FM_HOME="$C/second" FM_MEM_GUARD_NOW=1002002 guard tick --check >/dev/null
  out=$(FM_MEM_GUARD_NOW=1002002 guard tick --check)
  assert_contains "$out" "has been unknown for 0s" "same-second recurrence has its own identity"
  out=$(FM_MEM_GUARD_NOW=1002002 guard tick --check)
  assert_equals "" "$out" "same-second recurrence deduplicates after delivery"

  # Older writers left onset-only and delivery-time-only records. They cannot be
  # interpreted as an acknowledgement of the new identity or reset the grace.
  printf '{}\n' > "$C/rules.json"
  printf '1002000\n' > "$C/guard/vm-unknown"
  printf '1002600\n' > "$C/home/state/.mem-guard-vm-notice"
  vm_notice_sample 1002600 unknown
  out=$(FM_MEM_GUARD_NOW=1002600 guard tick --check)
  assert_contains "$out" "has been unknown for 600s" "legacy onset is preserved but legacy delivery cannot suppress a token"
  out=$(FM_MEM_GUARD_NOW=1002600 guard tick --check)
  assert_equals "" "$out" "migrated occurrence deduplicates after delivery"
  pass "machine occurrence identity survives missed cross-home recovery, gaps, restart, legacy records and same-second recurrence"
}

test_vm_occurrence_storage_failure_notifies_once() {
  local out tool t
  for tool in mktemp mv; do
    new_case "vmnotice-storage-$tool"
    printf '{}\n' > "$C/rules.json"
    mkdir -p "$C/guard" "$C/tools"
    # Fail only publication of the machine occurrence; home delivery and all
    # other guard writes remain writable. No live paths are touched.
    # shellcheck disable=SC2016 # evaluated by the fixture tool
    printf '#!/usr/bin/env bash\ncase "${!#}" in */vm-unknown|*/vm-unknown.*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v "$tool")" > "$C/tools/$tool"
    chmod +x "$C/tools/$tool"
    vm_notice_sample 1000000 unknown
    out=$(PATH="$C/tools:$PATH" guard tick --check)
    assert_contains "$out" "cannot publish the VM paging occurrence" "$tool failure alarms immediately"
    assert_contains "$out" "restore writable occurrence storage" "the alarm names the recovery action"
    for t in 1000001 1000600; do
      vm_notice_sample "$t" unknown
      out=$(PATH="$C/tools:$PATH" FM_MEM_GUARD_NOW=$t guard tick --check)
      assert_equals "" "$out" "persistent $tool failure does not notify every tick"
    done
    assert_equals 1 "$(grep -c 'cannot publish the VM paging occurrence' "$C/guard/events.log")" "publication failure logs once per delivered episode"
    vm_notice_sample 1000601 unknown
    out=$(FM_MEM_GUARD_NOW=1000601 guard tick --check)
    assert_contains "$out" "occurrence storage is available again" "$tool recovery is reported even while VM telemetry remains unknown"
    vm_notice_sample 1001201 unknown
    out=$(FM_MEM_GUARD_NOW=1001201 guard tick --check)
    assert_equals "" "$out" "storage recovery binds delivery to the now-persisted occurrence"
    vm_notice_sample 1001202 known
    out=$(FM_MEM_GUARD_NOW=1001202 guard tick --check)
    assert_contains "$out" "share is measured again" "VM recovery closes the notice"
    vm_notice_sample 1001203 unknown
    out=$(PATH="$C/tools:$PATH" FM_MEM_GUARD_NOW=1001203 guard tick --check)
    assert_contains "$out" "cannot publish the VM paging occurrence" "a new storage failure after recovery alarms again"
    out=$(PATH="$C/tools:$PATH" FM_MEM_GUARD_NOW=1001203 guard tick --check)
    assert_equals "" "$out" "the new storage failure still deduplicates"
  done
  pass "mktemp and rename failures have a stable per-home storage episode with one alarm and explicit recovery"
}

# Unknown VM telemetry is its own occurrence: one notice once it has held for
# win_stale_max_s, whatever the level, one line when it is measured again, and a new
# notice for a new failure; never one per tick, and never a reason that says healthy.
test_unknown_vm_share_notifies_once_per_occurrence() {
  local out
  new_case vmnotice
  printf '{}\n' > "$C/rules.json"
  fake_ps 12000 50 0 600 -
  out=$(guard tick --check)
  assert_equals "" "$out" "a fresh unknown share does not notify at once"
  assert_contains "$(guard level)" "the WSL VM's paging share is unknown: no single vmmemWSL process in the Windows reading; no Windows pages input rate yet (ungraded)" "with no rate yet the reason still names the unknown share"
  out=$(FM_MEM_GUARD_NOW=1000300 guard tick --check)
  assert_equals "" "$out" "an unknown share inside win_stale_max_s does not notify"
  assert_contains "$(FM_MEM_GUARD_NOW=1000300 guard level)" "ok 1000300 Windows pages input 50/s averaged over 300s, graded as WSL VM paging because the VM's share is unknown: no single vmmemWSL process in the Windows reading (ok)" "a low system-wide rate grades ok but the reason names the unknown share"
  out=$(FM_MEM_GUARD_NOW=1000600 guard tick --check)
  assert_equals "memory guard: the WSL VM's paging share has been unknown for 600s (unknown: no single vmmemWSL process in the Windows reading), so system-wide Windows paging grades park and above as WSL VM paging until it is measured again (bin/fm-mem-guard.sh status)" "$out" "an unknown share held for win_stale_max_s notifies though the level is ok"
  out=$(FM_MEM_GUARD_NOW=1000900 guard tick --check)
  assert_equals "" "$out" "the same occurrence notifies once"
  fake_ps 12000 50 0 600 50
  out=$(FM_MEM_GUARD_NOW=1001200 guard tick --check)
  assert_equals "" "$out" "a VM process without its rate yet is still the same occurrence"
  out=$(FM_MEM_GUARD_NOW=1001500 guard tick --check)
  assert_equals "memory guard: the WSL VM's paging share is measured again (vmmemWSL pid 4242)" "$out" "recovery is told once"
  assert_absent "$C/home/state/.mem-guard-vm-notice" "recovery closes the notice"
  assert_absent "$C/guard/vm-unknown" "recovery clears the machine-wide record"
  out=$(FM_MEM_GUARD_NOW=1001800 guard tick --check)
  assert_equals "" "$out" "a measured share stays quiet"
  fake_ps 12000 50 0 600 -
  out=$(FM_MEM_GUARD_NOW=1002100 guard tick --check)
  assert_equals "" "$out" "a new failure starts a new occurrence without notifying at once"
  out=$(FM_MEM_GUARD_NOW=1002700 guard tick --check)
  assert_contains "$out" "memory guard: the WSL VM's paging share has been unknown for 600s" "a new occurrence notifies again"
  assert_equals 2 "$(grep -c "WSL VM paging share unknown: " "$C/guard/events.log")" "the events log gets one line per occurrence, not per tick"
  assert_equals 1 "$(grep -c "WSL VM paging share measured again: " "$C/guard/events.log")" "the events log gets one line per recovery"
  touch "$C/home/.fm-secondmate-home"
  out=$(FM_MEM_GUARD_NOW=1002800 guard tick --check)
  assert_equals "" "$out" "a secondmate home never prints the unknown-share notice"
  assert_absent "$C/home/state/.mem-guard-vm-notice" "a secondmate home holds no unknown-share notice"
  pass "an unknown VM paging share notifies once per occurrence, independent of the level, and once on recovery"
}

test_pool_notice_holds_through_an_unavailable_reading() {
  local out
  new_case poolhold
  printf '{}\n' > "$C/rules.json"
  fake_ps 6000 10 0 4506
  out=$(guard tick --check)
  assert_contains "$out" "memory guard warn: Windows non-paged pool 4506 MiB" "the pool alone wakes main though it grades only warn"
  assert_contains "$out" "no agent action frees the non-paged pool; it needs the operator" "the wake says no agent response helps"
  assert_absent "$C/home/state/.mem-guard-park" "the pool alone starts no park pass"
  export FM_MEM_GUARD_POWERSHELL="$C/absent/powershell.exe"
  out=$(FM_MEM_GUARD_NOW=1000700 guard tick --check)
  assert_equals "" "$out" "an unavailable Windows reading neither clears nor repeats the pool notice"
  assert_contains "$(FM_MEM_GUARD_NOW=1000700 guard level)" "Linux-only (Windows unavailable: powershell.exe not found)" "the degraded sample says so"
  export FM_MEM_GUARD_POWERSHELL="$C/powershell.exe"
  fake_ps 6000 10 0 600
  out=$(FM_MEM_GUARD_NOW=1001000 guard tick --check)
  assert_equals "" "$out" "a readable normal pool starts the clear without telling it"
  out=$(FM_MEM_GUARD_NOW=1001600 guard tick --check)
  assert_contains "$out" "memory guard cleared" "a readable normal pool clears the notice once the clear lasts 600 seconds"
  pass "the non-paged pool wakes main with no agent response and its notice holds through an unavailable reading"
}

test_critical_wakes_only_main_once_per_window() {
  local out t
  new_case critical
  fake_ps 900 10
  out=$(guard tick --check)
  assert_contains "$out" "memory guard critical: Windows available 900 MiB (critical)" "critical prints one wake line"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the watcher form prints only the wake line"
  out=$(FM_MEM_GUARD_NOW=1000100 guard tick --check)
  assert_equals "" "$out" "no repeat wake inside rewake_s"
  out=$(FM_MEM_GUARD_NOW=1002000 guard tick --check)
  assert_contains "$out" "memory guard critical" "the wake repeats after rewake_s"
  touch "$C/home/.fm-secondmate-home"
  rm -f "$C/home/state/.mem-guard-wake"
  out=$(FM_MEM_GUARD_NOW=1004000 guard tick --check)
  assert_equals "" "$out" "a secondmate home never prints the critical wake"
  printf '{}\n' > "$C/rules.json"
  fake_ps 1600 700 0 4506
  for t in 1004300 1004600; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "a secondmate home never prints the starved-host wake at $t"
  done
  fake_ps 12000 10
  for t in 1004900 1005200 1005500; do
    out=$(FM_MEM_GUARD_NOW=$t guard tick --check)
    assert_equals "" "$out" "a secondmate home never prints a clear at $t"
  done
  pass "critical wakes a primary home once per rewake_s and no guard notice ever reaches a secondmate home"
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
  assert_contains "$(cat "$C/send-text")" "handoff.md --requested so your session is released" "the steer marks the park as requested, so it parks whatever the wait's expected time"
  assert_grep "park: $C/home w-paused parked" "$C/guard/events.log" "the park is logged"
  assert_grep "park: $C/home w-invalid steered to write its handoff and park itself" "$C/guard/events.log" "the steer is logged"
  FM_MEM_GUARD_NOW=1001100 guard tick >/dev/null
  assert_equals 2 "$(wc -l < "$C/send-calls" | tr -d ' ')" "a worker is steered at most once per park_interval_s"
  pass "the park level parks idle workers with a valid handoff, steers the rest once per interval, or logs warn-only without fm-park.sh"
}

queue_refusal_guard_case() {
  local mode=$1 condition t sid state=completed
  [ "$mode" != captured ] || state=live
  new_case "${mode}queue"
  fake_ps 2500 10
  fake_crew_state 'w-done'
  # Real guard, park, captured-result settlement and acknowledgement. Only
  # sampling, idle classification and successful message transport are fixtures.
  condition="cmd:$C/home/bin/fm-procevent-merge-queue.sh result-ready aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  printf 'kind=ship\npark_state=%s\npark_when=%s\n' "$state" "$condition" > "$C/home/state/w-done.meta"
  if [ "$mode" = captured ]; then
    sid=merge-queue-w-done-aaaaaaaa
    printf 'spawn_gen=g1\npark_spawn_gen=g1\npark_source=%s\npark_token=live-token\n' "$sid" >> "$C/home/state/w-done.meta"
    mkdir -p "$C/home/state/procevent-inbox"
    printf 'merge-queue: %s\ntask: w-done\nhead: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nstatus: result\nline: RESULT now head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa outcome=conflict main=- note=captured\n' "$sid" > "$C/home/state/procevent-inbox/$sid.1.result"
    printf 'merge-queue\n' > "$C/home/state/procevent-inbox/$sid.1.adapter"
  fi
  mkdir -p "$C/home/data/w-done"
  printf '## Goal\ng\n## Done\nd\n## Waiting for\n%s\n## Next steps\nn\n' "$condition" > "$C/home/data/w-done/handoff.md"
  for t in 1000000 1001000; do
    FM_MERGE_QUEUE_SEND_BIN=/bin/true FM_MEM_GUARD_NOW=$t guard tick >/dev/null || fail 'memory guard could not record a park refusal'
    assert_grep "park: $C/home w-done not parked (exit 1):" "$C/guard/events.log" "guard records $mode-condition refusal as not parked"
    if [ "$mode" = captured ]; then
      assert_present "$C/home/state/procevent-inbox/$sid.1.handled" 'captured result delivered and acknowledged before park refusal'
    fi
    assert_no_grep "park: $C/home w-done parked" "$C/guard/events.log" 'guard never reports a refused park as successful'
    assert_no_grep 'idle worker(s)' "$C/guard/events.log" 'refused parks do not increment the successful park total'
    assert_grep 'park_state=completed' "$C/home/state/w-done.meta" 'guard failure path preserves completed ownership'
    assert_absent "$C/home/state/procevent/when-park-w-done.source" 'guard failure path arms no listener'
  done
  assert_equals 2 "$(grep -c 'w-done not parked (exit 1)' "$C/guard/events.log")" 'guard retries refused completed-condition parks on the next eligible pass'
  pass "memory guard records real $mode-condition refusals as not parked and retries them"
}
test_completed_queue_refusal_is_not_a_park() { queue_refusal_guard_case completed; }
test_captured_queue_refusal_is_not_a_park() { queue_refusal_guard_case captured; }

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
  printf '{"memory_guard": {"win_paging_mibps": [1, 2, 3, 4], "critical_rewake_s": 5, "wake_level": "loud"}}\n' > "$C/rules.json"
  out=$(guard status)
  assert_contains "$out" "memory_guard.win_paging_mibps in $C/rules.json is retired and ignored; set memory_guard.win_pages_in_ps instead" "a retired paging key is named with its replacement"
  assert_contains "$out" "memory_guard.critical_rewake_s in $C/rules.json is retired and ignored; set memory_guard.rewake_s instead" "a retired repeat key is named with its replacement"
  assert_contains "$out" "memory_guard.wake_level in $C/rules.json is not one of warn, park, refuse, critical" "a bad wake level warns"
  printf '{"memory_guard": {"wake_level": "critical", "win_pages_in_ps": [10, 20, 30, 40], "win_nonpaged_pool_mib": 0}}\n' > "$C/rules.json"
  fake_ps 12000 35 0 4506
  FM_MEM_GUARD_NOW=1000100 guard tick >/dev/null
  rm -f "$C/home/state/.mem-guard-wake"
  out=$(FM_MEM_GUARD_NOW=1000200 guard tick --check)
  assert_equals "" "$out" "a raised wake level and a disabled pool signal keep a refuse level from main"
  assert_contains "$(FM_MEM_GUARD_NOW=1000200 guard level)" "WSL VM paging upper bound 35/s (the lower of vmmemWSL faults 35/s and Windows pages input 35/s over the same 100s) (refuse)" "configured page-in thresholds apply"
  pass "rules override thresholds and malformed or retired values warn and keep defaults"
}

test_auto_sync_arms_and_retires_the_check() {
  local out obs
  new_case auto
  obs=$(fm_check_rename_observer "$C/observer")
  out=$(PATH="$obs:$PATH" FM_TEST_MV_LOG="$C/mv.log" FM_TEST_CHECK="$C/home/state/mem-guard.check.sh" \
    FM_HOME="$C/home" "$GUARD" auto sync 2>&1) || fail "auto sync failed: $out"
  assert_present "$C/home/state/mem-guard.check.sh" "sync arms the check"
  assert_present "$C/home/state/mem-guard.check-trust" "sync registers the check"
  assert_equals "trust absent|check bound" "$(paste -sd'|' "$C/mv.log")" "sync binds the check before it appears"
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
test_defaults_grade_linux_and_only_sample_windows_available
test_swap_grades_only_while_growing
test_admit_refuses_heavy_jobs
test_starved_windows_host_tells_main_start_repeat_and_clear
test_flapping_state_folds_into_one_clear
test_return_after_a_told_clear_wakes_only_higher
test_silent_downgrade_keeps_the_last_notified_level
test_silent_reentry_does_not_reopen_a_told_clear
test_told_clear_record_expires_after_rewake
test_healthy_windows_host_stays_ok_and_silent
test_windows_side_paging_grades_at_most_warn_and_admits
test_vm_paging_parks_and_refuses
test_unknown_vm_share_grades_system_paging_on_the_full_ladder
test_native_paging_with_vm_soft_churn_grades_on_the_bound
test_vm_and_system_rates_pair_one_interval
test_vm_baseline_identity_controls_admission
test_vm_baseline_selection_uses_windows_clock
test_vm_notice_tracks_cross_home_occurrences
test_vm_occurrence_storage_failure_notifies_once
test_unknown_vm_share_notifies_once_per_occurrence
test_pool_notice_holds_through_an_unavailable_reading
test_critical_wakes_only_main_once_per_window
test_park_level_parks_or_steers_idle_workers
test_completed_queue_refusal_is_not_a_park
test_captured_queue_refusal_is_not_a_park
test_park_pass_resumes_where_it_stopped_and_needs_time_to_park
test_park_ignores_a_handoff_older_than_the_last_resume
test_critical_wake_precedes_park_work
test_rules_override_and_malformed_values_warn
test_auto_sync_arms_and_retires_the_check
test_job_cap_scopes_and_refuses

echo "# all fm-mem-guard tests passed"
