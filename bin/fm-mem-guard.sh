#!/usr/bin/env bash
# Machine memory guard: sample Windows and Linux memory, grade the machine, and respond.
# Usage: fm-mem-guard.sh sample [--fresh]
#        fm-mem-guard.sh status
#        fm-mem-guard.sh tick [--check]
#        fm-mem-guard.sh level
#        fm-mem-guard.sh admit [--cost-mib <n>]
#        fm-mem-guard.sh auto sync|on|off
#   sample  prints one sample as key=value lines: Windows available memory,
#           pages input and output per second averaged over the span between two
#           Windows readings at least 60s and at most win_stale_max_s apart
#           (win_paging_span_s; empty until two such readings exist), and the
#           non-paged pool (win_*), Linux MemAvailable, page cache, swap, swap-out
#           rate over at least the last 60s of ticks, and memory pressure
#           (linux_*), and win_source, which is `powershell`,
#           `cache <age>s`, or `unavailable: <reason>`. The Windows side comes
#           from one bounded powershell.exe call shared machine-wide through a
#           cache; when powershell.exe is missing, slow, or unreadable the
#           sample degrades to Linux-only and says why. --fresh ignores the cache.
#   status  prints the sample, the graded level with every reason, and the
#           recorded machine level.
#   tick    samples, grades with hysteresis, records the machine level, appends
#           one line to the bounded sample log, and responds for this home:
#             warn     log only;
#             park     also passes over this home's idle workers (ship or scout
#                      tasks not already parked whose current state is a declared
#                      wait), at most once per park_interval_s: one whose
#                      data/<id>/handoff.md passes `fm-park.sh validate` and was
#                      written after the task's last park or resume is parked
#                      with `fm-park.sh <id> --handoff data/<id>/handoff.md`; any
#                      other gets one steer through bin/fm-send.sh asking it to
#                      write that handoff and park itself with bin/fm-park.sh.
#                      The pass ends inside the watcher's FM_CHECK_TIMEOUT
#                      (default 30s), never starts a park with under 15s left,
#                      and the next pass starts where an unfinished one stopped,
#                      past a worker whose park it could not afford;
#                      without bin/fm-park.sh it logs that park acts as warn only;
#             refuse   also makes every new agent spawn (bin/fm-admission.sh) and
#                      heavy-job start (`admit`) refuse, naming the memory guard;
#             critical also asks main to park or finish waiting workers and
#                      stop heavy jobs.
#           Every level at or above one step includes the lower steps' responses.
#           Wake: in a primary home, a level at or above wake_level (default park)
#           or an abnormal Windows non-paged pool prints one wake line when it
#           starts, again after rewake_s while it stays or at once when the level
#           rises or the pool turns abnormal, and one `memory guard cleared` line
#           when neither holds any more. The pool grades warn only, because a
#           leaking Windows driver is its likely cause and no agent response frees
#           it, but it always wakes main. A Windows reading that is unavailable
#           holds the pool notice as it was. Secondmate homes never print a wake.
#           --check is the watcher form: identical, and stdout carries only the
#           wake line, printed before any park work.
#   level   prints `<level> <epoch> <reasons>` from the recorded machine level,
#           or `unknown` when none is recorded within state_max_age_s. It never
#           samples, so admission can call it on every launch.
#   admit   the heavy-job admission hook: exits 0 printing `admit`, or exits 1
#           printing `refuse: memory guard ...` when the recorded level is refuse
#           or critical, or when Linux MemAvailable minus --cost-mib would fall
#           below the Linux refuse threshold. It reads only recorded state and
#           /proc, never powershell.exe.
#   auto    sync makes state/mem-guard.check.sh match config/mem-guard: installed
#           and registered (bin/fm-check-register.sh) unless that file says off,
#           or FM_MEM_GUARD=off, or the host has no /proc/meminfo; retired
#           otherwise. on/off write config/mem-guard first. bin/fm-bootstrap.sh
#           runs sync at every session start.
#
# Levels, lowest first: ok warn park refuse critical. Each signal has four
# thresholds, one per level from warn to critical, except swap, which has three
# (warn park refuse) and grades only on a tick where swap is growing; the
# machine level is the highest any signal reaches. A lower level is recorded
# only after clear_samples consecutive samples grade below the recorded one; a
# higher level is recorded at once.
#
# Thresholds and timings: the optional `memory_guard` object of the machine
# admission rules file ${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json};
# docs/configuration.md "Memory guard" owns its keys and defaults. A malformed
# value warns on stderr and keeps the default.
#
# Machine-wide records (runtime scratch, written only here), in
# ${FM_MEM_GUARD_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fm-mem-guard}:
#   level        `<level> <epoch> <below-count> <reasons>`
#   windows      `<epoch> <total_kib> <free_kib> <avail_mib> <pages_in> <pages_out>
#                <perf_time> <perf_freq> <pool_bytes> <base_in> <base_out> <base_perf>
#                <in/s> <out/s> <span_s>`: the raw Windows counters (pages are
#                cumulative 32-bit counts), the earlier reading the rates are
#                measured from, and the rates; `-` where none
#   swapout      `<epoch> <pswpout> [<epoch> <pswpout>]` from /proc/vmstat, newest
#                first; a tick adds a pair only once the newest is 60s old, so
#                the swap-out rate always spans at least 60s
#   samples.log  one line per tick, trimmed to log_max_lines
#   events.log   one line per level change, park action, or degraded sample, trimmed likewise
#   lock/        mkdir lock around record writes; win.lock/ around the powershell call
# Per-home records, written only here: state/.mem-guard-park (`<last park epoch>
# [<id where the next pass starts after an unfinished one>]`),
# state/.mem-guard-wake (`<last wake epoch> <level index woken for, 0 when only the
# pool> <pool notice 0|1>`, present while main has an open memory notice),
# state/mem-guard.check.sh.
#
# Test seams: FM_PROC_ROOT_OVERRIDE (default /proc), FM_MEM_GUARD_POWERSHELL
# (the powershell executable; default powershell.exe on PATH, then the standard
# /mnt/c path), FM_MEM_GUARD_NOW (epoch), FM_MEM_GUARD=off (tick, admit, and
# level do nothing and admit).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

PROC=${FM_PROC_ROOT_OVERRIDE:-/proc}
RULES_FILE=${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json}
GUARD_DIR=${FM_MEM_GUARD_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fm-mem-guard}
LEVEL_FILE="$GUARD_DIR/level"
WIN_FILE="$GUARD_DIR/windows"
SWAPOUT_FILE="$GUARD_DIR/swapout"
SAMPLES_LOG="$GUARD_DIR/samples.log"
EVENTS_LOG="$GUARD_DIR/events.log"
LOCK="$GUARD_DIR/lock"
WIN_LOCK="$GUARD_DIR/win.lock"
CHECK_ID=mem-guard
LEVELS="ok warn park refuse critical"

# Built-in defaults; thresholds are "warn park refuse critical" (swap: "warn park refuse").
# Windows available memory is sampled and logged but graded only when the rules
# file sets win_available_mib: with WSL capped, its memory is resident and low
# Windows available memory is expected, so host paging is the Windows signal.
T_win_available_mib=""                         # Windows available memory at or below
T_win_pages_in_ps="100 250 500 1000"           # Windows pages input/s, sustained, at or above
T_linux_available_mib="4096 3584 3072 1536"    # Linux MemAvailable at or below
T_linux_swap_used_mib="4096 5120 6144"         # Linux swap in use at or above, while swap grows
T_linux_psi_full_avg10="2 5 10 25"             # Linux memory pressure full avg10 at or above
R_win_timeout_s=20
R_win_cache_s=60
R_win_stale_max_s=600
R_state_max_age_s=900
R_clear_samples=2
R_park_interval_s=900
R_rewake_s=1800
R_log_max_lines=5000
R_linux_swapout_mibps_min=1
R_win_nonpaged_pool_mib=2048                   # abnormal Windows non-paged pool at or above; 0 grades none
R_wake_level=park
RATE_WINDOW_S=60
PAGE_COUNTER_WRAP=4294967296

THRESHOLD_KEYS="win_available_mib win_pages_in_ps linux_available_mib linux_swap_used_mib linux_psi_full_avg10"
RULE_KEYS="win_timeout_s win_cache_s win_stale_max_s state_max_age_s clear_samples park_interval_s rewake_s log_max_lines linux_swapout_mibps_min win_nonpaged_pool_mib"

now() { printf '%s' "${FM_MEM_GUARD_NOW:-$(date +%s)}"; }

load_rules() {
  local key val n names
  [ -f "$RULES_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e '.memory_guard | type == "object"' "$RULES_FILE" >/dev/null 2>&1 || return 0
  for key in $THRESHOLD_KEYS; do
    jq -e --arg k "$key" '.memory_guard | has($k)' "$RULES_FILE" >/dev/null 2>&1 || continue
    n=4 names="four numbers (warn park refuse critical)"
    [ "$key" != linux_swap_used_mib ] || n=3 names="three numbers (warn park refuse)"
    val=$(jq -r --arg k "$key" --argjson n "$n" '.memory_guard[$k] | select(type == "array" and length == $n and all(type == "number")) | map(tostring) | join(" ")' "$RULES_FILE" 2>/dev/null) || val=
    if [ -z "$val" ]; then
      echo "warning: fm-mem-guard: memory_guard.$key in $RULES_FILE is not $names; using the default" >&2
      continue
    fi
    printf -v "T_$key" '%s' "$val"
  done
  for key in $RULE_KEYS; do
    jq -e --arg k "$key" '.memory_guard | has($k)' "$RULES_FILE" >/dev/null 2>&1 || continue
    val=$(jq -r --arg k "$key" '.memory_guard[$k] | select(type == "number" and . >= 0) | floor | tostring' "$RULES_FILE" 2>/dev/null) || val=
    if [ -z "$val" ]; then
      echo "warning: fm-mem-guard: memory_guard.$key in $RULES_FILE is not a non-negative number; using the default" >&2
      continue
    fi
    printf -v "R_$key" '%s' "$val"
  done
  if jq -e '.memory_guard | has("wake_level")' "$RULES_FILE" >/dev/null 2>&1; then
    val=$(jq -r '.memory_guard.wake_level | select(type == "string")' "$RULES_FILE" 2>/dev/null) || val=
    case "$val" in
    warn | park | refuse | critical) R_wake_level=$val ;;
    *) echo "warning: fm-mem-guard: memory_guard.wake_level in $RULES_FILE is not one of warn, park, refuse, critical; using the default" >&2 ;;
    esac
  fi
  names=$(jq -r '.memory_guard | keys[] | select(. == "win_paging_mibps" or . == "critical_rewake_s")' "$RULES_FILE" 2>/dev/null) || names=
  for key in $names; do
    case "$key" in win_paging_mibps) val=win_pages_in_ps ;; *) val=rewake_s ;; esac
    echo "warning: fm-mem-guard: memory_guard.$key in $RULES_FILE is retired and ignored; set memory_guard.$val instead" >&2
  done
}

level_index() { # <level>
  local i=0 l
  for l in $LEVELS; do
    [ "$l" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  printf 0
}

level_name() { # <index>
  local -a names
  read -ra names <<<"$LEVELS"
  printf '%s' "${names[$1]:-ok}"
}

guard_dir_ready() {
  mkdir -p "$GUARD_DIR" 2>/dev/null && chmod 700 "$GUARD_DIR" 2>/dev/null
  [ -d "$GUARD_DIR" ]
}

lock_acquire() { # <dir>
  local tries=0
  until mkdir "$1" 2>/dev/null; do
    tries=$((tries + 1))
    # Holders write a few short lines; a lock this old was abandoned by a crash.
    if [ "$tries" -ge 50 ]; then
      rmdir "$1" 2>/dev/null
      tries=0
    fi
    sleep 0.1
  done
}

lock_release() { rmdir "$1" 2>/dev/null || true; }

# append_bounded <file> <line>: append and keep the last log_max_lines lines.
append_bounded() {
  local file=$1 line=$2 n
  printf '%s\n' "$line" >>"$file" 2>/dev/null || return 0
  n=$(wc -l <"$file" 2>/dev/null) || return 0
  if [ "${n:-0}" -gt $((R_log_max_lines + R_log_max_lines / 10)) ]; then
    tail -n "$R_log_max_lines" "$file" >"$file.tmp.$$" 2>/dev/null && mv -f "$file.tmp.$$" "$file"
    rm -f "$file.tmp.$$"
  fi
}

event() { # <text>
  append_bounded "$EVENTS_LOG" "$(date -u -d "@$(now)" +%FT%TZ 2>/dev/null || now) $1"
}

powershell_bin() {
  if [ -n "${FM_MEM_GUARD_POWERSHELL:-}" ]; then
    [ -x "$FM_MEM_GUARD_POWERSHELL" ] || return 1
    printf '%s' "$FM_MEM_GUARD_POWERSHELL"
    return 0
  fi
  command -v powershell.exe 2>/dev/null && return 0
  local p=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  return 1
}

# Windows reading: one line "<total_kib> <free_kib> <avail_mib> <pages_in> <pages_out>
# <perf_time> <perf_freq> <pool_bytes>". The raw class gives cumulative page counts, so
# a rate is an average between two readings rather than the last second's spike.
# shellcheck disable=SC2016 # PowerShell variables, expanded by powershell.exe
PS_QUERY='$o = Get-CimInstance Win32_OperatingSystem; $p = Get-CimInstance Win32_PerfRawData_PerfOS_Memory; "{0} {1} {2} {3} {4} {5} {6} {7}" -f $o.TotalVisibleMemorySize, $o.FreePhysicalMemory, $p.AvailableMBytes, $p.PagesInputPersec, $p.PagesOutputPersec, $p.Timestamp_PerfTime, $p.Frequency_PerfTime, $p.PoolNonpagedBytes'

is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }

# win_cache_line <epoch> <reading>: prints the cache line for a new reading, measuring
# its rates from the previous cache line's reading once that is at least
# RATE_WINDOW_S old, else from the previous line's own baseline while that is
# within win_stale_max_s. A perf clock that went back (a Windows restart) or a
# changed frequency leaves no baseline; a page count that went back wrapped.
win_cache_line() {
  local epoch=$1 b_in=- b_out=- b_perf=- in_ps=- out_ps=- span=- d_in d_out d_perf
  local -a cur prev=()
  read -ra cur <<<"$2"
  { read -ra prev <"$WIN_FILE"; } 2>/dev/null
  if [ "${#prev[@]}" = 15 ] && [ "${prev[7]}" = "${cur[6]}" ] && is_uint "${prev[4]}" && is_uint "${prev[5]}" && is_uint "${prev[6]}"; then
    b_in=${prev[4]} b_out=${prev[5]} b_perf=${prev[6]}
    if [ $((cur[5] - prev[6])) -lt $((RATE_WINDOW_S * cur[6])) ] && is_uint "${prev[9]}" && is_uint "${prev[10]}" && is_uint "${prev[11]}" \
      && [ $((cur[5] - prev[11])) -le $((R_win_stale_max_s * cur[6])) ]; then
      b_in=${prev[9]} b_out=${prev[10]} b_perf=${prev[11]}
    fi
    if [ "${cur[5]}" -le "$b_perf" ]; then
      b_in=- b_out=- b_perf=-
    else
      d_perf=$((cur[5] - b_perf))
      span=$((d_perf / cur[6]))
      if [ "$span" -ge "$RATE_WINDOW_S" ] && [ "$span" -le "$R_win_stale_max_s" ]; then
        d_in=$((cur[3] - b_in)) d_out=$((cur[4] - b_out))
        [ "$d_in" -ge 0 ] || d_in=$((d_in + PAGE_COUNTER_WRAP))
        [ "$d_out" -ge 0 ] || d_out=$((d_out + PAGE_COUNTER_WRAP))
        # Milliseconds, so a perf frequency in GHz cannot overflow the product.
        d_perf=$((d_perf / (cur[6] / 1000)))
        in_ps=$((d_in * 1000 / d_perf)) out_ps=$((d_out * 1000 / d_perf))
      else
        span=-
      fi
    fi
  fi
  printf '%s %s %s %s %s %s %s %s\n' "$epoch" "$2" "$b_in" "$b_out" "$b_perf" "$in_ps" "$out_ps" "$span"
}

# win_refresh: run powershell once (bounded) and write the cache. Sets WIN_ERR on failure.
win_refresh() {
  local ps out
  WIN_ERR=
  if ! ps=$(powershell_bin); then
    WIN_ERR="powershell.exe not found"
    return 1
  fi
  local rc=0
  out=$(timeout "$R_win_timeout_s" "$ps" -NoProfile -NonInteractive -Command "$PS_QUERY" 2>/dev/null) || rc=$?
  out=$(printf '%s' "$out" | tr -d '\r')
  if [ "$rc" = 124 ]; then
    WIN_ERR="powershell.exe timed out after ${R_win_timeout_s}s"
    return 1
  fi
  out=$(printf '%s\n' "$out" | awk 'NF == 8 { for (i = 1; i <= 8; i++) if ($i !~ /^[0-9]+$/ || length($i) > 18) next; if ($7 + 0 >= 1000) { print; exit } }')
  if [ -z "$out" ]; then
    WIN_ERR="powershell.exe gave no memory reading (exit $rc)"
    return 1
  fi
  win_cache_line "$(now)" "$out" >"$WIN_FILE.tmp.$$" && mv -f "$WIN_FILE.tmp.$$" "$WIN_FILE"
}

# win_line_epoch <line>: the line's epoch, or 0 unless it is a complete cache line.
win_line_epoch() {
  local -a f
  read -ra f <<<"$1"
  if [ "${#f[@]}" = 15 ] && is_uint "${f[0]}"; then printf '%s' "${f[0]}"; else printf 0; fi
}

# win_read <fresh>: sets WIN_* values and WIN_SOURCE.
win_read() {
  local fresh=$1 line epoch age t
  WIN_TOTAL_KIB='' WIN_FREE_KIB='' WIN_AVAIL_MIB='' WIN_PAGES_IN_PS='' WIN_PAGES_OUT_PS='' WIN_RATE_SPAN_S='' WIN_POOL_MIB='' WIN_SOURCE=''
  t=$(now)
  line=$(cat "$WIN_FILE" 2>/dev/null) || line=
  epoch=$(win_line_epoch "$line")
  age=$((t - epoch))
  if [ "$fresh" = 1 ] || [ "$age" -ge "$R_win_cache_s" ]; then
    # One powershell call machine-wide at a time; others read the cache.
    if mkdir "$WIN_LOCK" 2>/dev/null; then
      if win_refresh; then
        WIN_SOURCE=powershell
      else
        WIN_SOURCE="unavailable: $WIN_ERR"
      fi
      rmdir "$WIN_LOCK" 2>/dev/null
    elif [ -n "$(find "$WIN_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      rmdir "$WIN_LOCK" 2>/dev/null
    fi
    line=$(cat "$WIN_FILE" 2>/dev/null) || line=
    epoch=$(win_line_epoch "$line")
    age=$((t - epoch))
  fi
  if [ "$epoch" -gt 0 ] && [ "$age" -le "$R_win_stale_max_s" ]; then
    # shellcheck disable=SC2086 # the cache line is fifteen space-separated fields
    set -- $line
    WIN_TOTAL_KIB=$2 WIN_FREE_KIB=$3 WIN_AVAIL_MIB=$4 WIN_POOL_MIB=$(($9 / 1048576))
    if [ "${15}" != - ]; then WIN_PAGES_IN_PS=${13} WIN_PAGES_OUT_PS=${14} WIN_RATE_SPAN_S=${15}; fi
    case "$WIN_SOURCE" in
    powershell) ;;
    unavailable:*) WIN_SOURCE="cache ${age}s (refresh failed: ${WIN_SOURCE#unavailable: })" ;;
    *) WIN_SOURCE="cache ${age}s" ;;
    esac
  else
    [ -n "$WIN_SOURCE" ] && [ "$WIN_SOURCE" != powershell ] || WIN_SOURCE="unavailable: no Windows reading within ${R_win_stale_max_s}s"
  fi
}

meminfo_kib() { # <field>
  awk -v f="$1:" '$1 == f { print $2; found = 1; exit } END { exit !found }' "$PROC/meminfo" 2>/dev/null
}

# linux_read: sets LINUX_* values; LINUX_SWAPOUT_MIBPS is the swap-out rate since
# the newest swapout pair at least RATE_WINDOW_S old, empty without one.
# SWAPOUT_NEWEST is the record's newest pair, for the tick to rotate.
linux_read() {
  local v c b st sf sc t e1 o1 e0 o0 base_e='' base_o=''
  LINUX_AVAIL_MIB='' LINUX_TOTAL_MIB='' LINUX_CACHE_MIB='' LINUX_SWAP_USED_MIB='' LINUX_PSI_SOME='' LINUX_PSI_FULL=''
  LINUX_PSWPOUT='' LINUX_SWAPOUT_MIBPS='' SWAPOUT_NEWEST=''
  v=$(meminfo_kib MemAvailable) && LINUX_AVAIL_MIB=$((v / 1024))
  v=$(meminfo_kib MemTotal) && LINUX_TOTAL_MIB=$((v / 1024))
  if c=$(meminfo_kib Cached) && b=$(meminfo_kib Buffers); then LINUX_CACHE_MIB=$(((c + b) / 1024)); fi
  if st=$(meminfo_kib SwapTotal) && sf=$(meminfo_kib SwapFree); then
    sc=$(meminfo_kib SwapCached) || sc=0
    LINUX_SWAP_USED_MIB=$(((st - sf - sc) / 1024))
  fi
  LINUX_PSWPOUT=$(awk '$1 == "pswpout" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$PROC/vmstat" 2>/dev/null)
  if [ -n "$LINUX_PSWPOUT" ] && read -r e1 o1 e0 o0 2>/dev/null <"$SWAPOUT_FILE"; then
    t=$(now)
    case "$e1$o1" in
    '' | *[!0-9]*) ;;
    *)
      SWAPOUT_NEWEST="$e1 $o1"
      if [ $((t - e1)) -ge "$RATE_WINDOW_S" ]; then
        base_e=$e1 base_o=$o1
      else
        case "$e0$o0" in '' | *[!0-9]*) ;; *) [ $((t - e0)) -lt "$RATE_WINDOW_S" ] || base_e=$e0 base_o=$o0 ;; esac
      fi
      ;;
    esac
    if [ -n "$base_e" ] && [ "$LINUX_PSWPOUT" -ge "$base_o" ]; then
      LINUX_SWAPOUT_MIBPS=$(awk -v d="$((LINUX_PSWPOUT - base_o))" -v s="$((t - base_e))" 'BEGIN { printf "%.1f", d * 4 / 1024 / s }')
    fi
  fi
  LINUX_PSI_SOME=$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i } }' "$PROC/pressure/memory" 2>/dev/null)
  LINUX_PSI_FULL=$(awk '$1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i } }' "$PROC/pressure/memory" 2>/dev/null)
}

take_sample() { # <fresh>
  win_read "$1"
  linux_read
}

print_sample() {
  printf 'win_total_mib=%s\n' "${WIN_TOTAL_KIB:+$((WIN_TOTAL_KIB / 1024))}"
  printf 'win_free_mib=%s\n' "${WIN_FREE_KIB:+$((WIN_FREE_KIB / 1024))}"
  printf 'win_available_mib=%s\n' "$WIN_AVAIL_MIB"
  printf 'win_pages_in_ps=%s\n' "$WIN_PAGES_IN_PS"
  printf 'win_pages_out_ps=%s\n' "$WIN_PAGES_OUT_PS"
  printf 'win_paging_span_s=%s\n' "$WIN_RATE_SPAN_S"
  printf 'win_nonpaged_pool_mib=%s\n' "$WIN_POOL_MIB"
  printf 'win_source=%s\n' "$WIN_SOURCE"
  printf 'linux_total_mib=%s\n' "$LINUX_TOTAL_MIB"
  printf 'linux_available_mib=%s\n' "$LINUX_AVAIL_MIB"
  printf 'linux_cache_mib=%s\n' "$LINUX_CACHE_MIB"
  printf 'linux_swap_used_mib=%s\n' "$LINUX_SWAP_USED_MIB"
  printf 'linux_swapout_mibps=%s\n' "$LINUX_SWAPOUT_MIBPS"
  printf 'linux_psi_some_avg10=%s\n' "$LINUX_PSI_SOME"
  printf 'linux_psi_full_avg10=%s\n' "$LINUX_PSI_FULL"
}

# grade_signal <value> <below|above> <thresholds> -> level index (0 when value or thresholds empty)
grade_signal() {
  [ -n "$1" ] || { printf 0; return; }
  # shellcheck disable=SC2086 # thresholds are four space-separated numbers
  awk -v v="$1" -v dir="$2" -v t="$3" 'BEGIN {
    n = split(t, a, " "); lvl = 0
    for (i = 1; i <= n; i++) if ((dir == "below" && v + 0 <= a[i] + 0) || (dir == "above" && v + 0 >= a[i] + 0)) lvl = i
    printf "%d", lvl }'
}

# grade: sets GRADE (index), GRADE_REASONS, and POOL_ABNORMAL (1 when the Windows
# non-paged pool is at or above win_nonpaged_pool_mib) from the current sample.
grade() {
  local g
  GRADE=0 GRADE_REASONS='' POOL_ABNORMAL=0
  g=$(grade_signal "$WIN_AVAIL_MIB" below "$T_win_available_mib")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Windows available ${WIN_AVAIL_MIB} MiB ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  g=$(grade_signal "$WIN_PAGES_IN_PS" above "$T_win_pages_in_ps")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Windows pages input ${WIN_PAGES_IN_PS}/s averaged over ${WIN_RATE_SPAN_S}s ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  if [ -n "$WIN_POOL_MIB" ] && [ "$R_win_nonpaged_pool_mib" -gt 0 ] && [ "$WIN_POOL_MIB" -ge "$R_win_nonpaged_pool_mib" ]; then
    POOL_ABNORMAL=1
    GRADE_REASONS="$GRADE_REASONS; Windows non-paged pool ${WIN_POOL_MIB} MiB, normal is under 1024 MiB (warn: a leaking Windows driver is the likely cause, which no agent response frees; a Windows restart frees it and poolmon names the driver's pool tag)"
    [ "$GRADE" -ge 1 ] || GRADE=1
  fi
  g=$(grade_signal "$LINUX_AVAIL_MIB" below "$T_linux_available_mib")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Linux available ${LINUX_AVAIL_MIB} MiB ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  g=0
  if [ -n "$LINUX_SWAPOUT_MIBPS" ] && awk -v r="$LINUX_SWAPOUT_MIBPS" -v m="$R_linux_swapout_mibps_min" 'BEGIN { exit !(r + 0 > m + 0) }'; then
    g=$(grade_signal "$LINUX_SWAP_USED_MIB" above "$T_linux_swap_used_mib")
  fi
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Linux swap used ${LINUX_SWAP_USED_MIB} MiB, growing ${LINUX_SWAPOUT_MIBPS} MiB/s ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  g=$(grade_signal "$LINUX_PSI_FULL" above "$T_linux_psi_full_avg10")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Linux memory pressure full avg10 ${LINUX_PSI_FULL}% ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  GRADE_REASONS=${GRADE_REASONS#; }
  case "$WIN_SOURCE" in unavailable:*) GRADE_REASONS="${GRADE_REASONS:+$GRADE_REASONS; }Linux-only (Windows ${WIN_SOURCE})" ;; esac
}

# read_level: sets REC_LEVEL REC_EPOCH REC_BELOW REC_REASONS (REC_LEVEL empty when none).
read_level() {
  local line
  REC_LEVEL='' REC_EPOCH=0 REC_BELOW=0 REC_REASONS=''
  line=$(cat "$LEVEL_FILE" 2>/dev/null) || return 1
  read -r REC_LEVEL REC_EPOCH REC_BELOW REC_REASONS <<<"$line"
  case "$REC_EPOCH" in '' | *[!0-9]*) REC_LEVEL= ; return 1 ;; esac
  case "$REC_BELOW" in '' | *[!0-9]*) REC_BELOW=0 ;; esac
  case " $LEVELS " in *" $REC_LEVEL "*) ;; *) REC_LEVEL= ; return 1 ;; esac
}

# recorded_fresh: true when a level was recorded within state_max_age_s.
recorded_fresh() {
  read_level || return 1
  [ $(($(now) - REC_EPOCH)) -le "$R_state_max_age_s" ]
}

cmd_level() {
  if recorded_fresh; then
    printf '%s %s %s\n' "$REC_LEVEL" "$REC_EPOCH" "$REC_REASONS"
  else
    echo unknown
  fi
}

cmd_admit() {
  local cost=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --cost-mib)
      [ $# -ge 2 ] || { echo "error: --cost-mib requires a value" >&2; exit 2; }
      cost=$2
      shift
      ;;
    *) echo "error: unknown argument '$1' for admit" >&2; exit 2 ;;
    esac
    shift
  done
  case "$cost" in '' | *[!0-9]*) echo "error: --cost-mib must be a whole number" >&2; exit 2 ;; esac
  if recorded_fresh && [ "$(level_index "$REC_LEVEL")" -ge 3 ]; then
    echo "refuse: memory guard is at $REC_LEVEL: $REC_REASONS"
    exit 1
  fi
  linux_read
  if [ -n "$LINUX_AVAIL_MIB" ]; then
    local floor
    floor=$(awk -v t="$T_linux_available_mib" 'BEGIN { split(t, a, " "); print a[3] }')
    if [ $((LINUX_AVAIL_MIB - cost)) -lt "$floor" ]; then
      echo "refuse: memory guard: Linux available ${LINUX_AVAIL_MIB} MiB minus this job's ${cost} MiB is below the ${floor} MiB refuse line"
      exit 1
    fi
  fi
  echo admit
}

# bounded <cmd...>: run cmd under the time left before PARK_STOP (epoch seconds).
bounded() {
  local left=$((PARK_STOP - $(date +%s)))
  [ "$left" -ge 1 ] || return 124
  [ "$left" -le 20 ] || left=20
  timeout "$left" "$@"
}

# handoff_current <meta> <handoff>: the handoff was written after the task's last park or resume.
handoff_current() {
  local since
  since=$(awk -F= '($1 == "park_at" || $1 == "park_resumed_at") && $2 + 0 > m { m = $2 + 0 } END { print m + 0 }' "$1" 2>/dev/null)
  [ "${since:-0}" = 0 ] || [ "$(date -r "$2" +%s 2>/dev/null || echo 0)" -gt "$since" ]
}

# park_idle <level>: park this home's idle workers, or steer them to park themselves.
park_idle() {
  local level=$1 t last='' resume='' meta id handoff st out rc parked=0 steered=0 budget i n start=0 stopped=''
  local -a metas
  t=$(now)
  { read -r last resume <"$STATE/.mem-guard-park"; } 2>/dev/null
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((t - last)) -ge "$R_park_interval_s" ] || return 0
  printf '%s\n' "$t" >"$STATE/.mem-guard-park" 2>/dev/null
  if [ ! -x "$SCRIPT_DIR/fm-park.sh" ]; then
    event "park: bin/fm-park.sh is not installed in $FM_HOME, so the park level acts as warn only"
    return 0
  fi
  budget=${FM_CHECK_TIMEOUT:-30}
  case "$budget" in '' | *[!0-9]*) budget=30 ;; esac
  PARK_STOP=$((TICK_START + budget - 5))
  metas=("$STATE"/*.meta)
  n=${#metas[@]}
  if [ -n "$resume" ]; then
    for ((i = 0; i < n; i++)); do
      [[ "$(basename "${metas[i]}" .meta)" < "$resume" ]] || { start=$i; break; }
    done
  fi
  for ((i = 0; i < n; i++)); do
    meta=${metas[(start + i) % n]}
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    ! grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    [ "$(sed -n 's/^park_state=//p' "$meta" 2>/dev/null | tail -1)" != parked ] || continue
    if [ $((PARK_STOP - $(date +%s))) -lt 2 ]; then
      stopped=$id
      break
    fi
    st=$(FM_CREW_STATE_NO_FORGE=1 bounded "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
    case "$st" in 'state: paused'*) ;; *) continue ;; esac
    handoff="$DATA/$id/handoff.md"
    if [ -f "$handoff" ] && handoff_current "$meta" "$handoff" && bounded "$SCRIPT_DIR/fm-park.sh" validate "$handoff" >/dev/null 2>&1; then
      if [ $((PARK_STOP - $(date +%s))) -lt 15 ]; then
        stopped=$(basename "${metas[(start + i + 1) % n]}" .meta)
        break
      fi
      out=$(bounded "$SCRIPT_DIR/fm-park.sh" "$id" --handoff "$handoff" 2>&1)
      rc=$?
      if [ "$rc" = 0 ]; then
        parked=$((parked + 1))
        event "park: $FM_HOME $id parked"
      else
        event "park: $FM_HOME $id not parked (exit $rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      fi
    else
      out=$(FM_HOME="$FM_HOME" bounded "$SCRIPT_DIR/fm-send.sh" "$id" "memory guard: the machine is at $level and your session is idle on a declared wait. Write $handoff (Goal, Done, Waiting for, Next steps), then park yourself with $SCRIPT_DIR/fm-park.sh $id --handoff $handoff so your session is released until the result arrives." 2>&1)
      rc=$?
      if [ "$rc" = 0 ]; then
        steered=$((steered + 1))
        event "park: $FM_HOME $id steered to write its handoff and park itself"
      else
        event "park: $FM_HOME $id steer failed (exit $rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      fi
    fi
  done
  if [ -n "$stopped" ]; then
    printf '%s %s\n' "$t" "$stopped" >"$STATE/.mem-guard-park" 2>/dev/null
    event "park: $FM_HOME pass reached its time budget; the next pass starts at $stopped"
  fi
  [ "$parked" = 0 ] || event "park: $FM_HOME parked $parked idle worker(s)"
  [ "$steered" = 0 ] || event "park: $FM_HOME steered $steered idle worker(s) to park themselves"
}

is_secondmate_home() {
  [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]
}

# wake_decide <level-index> <epoch> <reasons>: sets wake to the line main gets now, or
# empty, and keeps state/.mem-guard-wake as the notice main holds open.
wake_decide() {
  local i=$1 t=$2 reasons=$3 rec=0 last=0 last_i=0 last_pool=0 pool=$POOL_ABNORMAL wake_i lvl=0 response
  { read -r last last_i last_pool <"$STATE/.mem-guard-wake"; } 2>/dev/null && rec=1
  is_uint "$last" || last=0
  # A record with only an epoch predates the wake level and was written at critical.
  is_uint "$last_i" || last_i=4
  [ "$last_pool" = 1 ] || last_pool=0
  # An unavailable Windows reading is not a healthy pool: hold the notice as it was.
  [ -n "$WIN_POOL_MIB" ] || pool=$last_pool
  wake_i=$(level_index "$R_wake_level")
  [ "$i" -lt "$wake_i" ] || lvl=$i
  if [ "$lvl" -gt 0 ] || [ "$pool" = 1 ]; then
    if [ "$rec" = 0 ] || [ $((t - last)) -ge "$R_rewake_s" ] || [ "$lvl" -gt "$last_i" ] || [ "$pool" -gt "$last_pool" ]; then
      printf '%s %s %s\n' "$t" "$lvl" "$pool" >"$STATE/.mem-guard-wake" 2>/dev/null
      case "$lvl" in
      4) response="new agents and heavy jobs are refused; park or finish waiting workers and stop heavy jobs" ;;
      3) response="new agents and heavy jobs are refused and idle workers on a declared wait are parked" ;;
      2) response="idle workers on a declared wait are parked" ;;
      1) response="this level takes no agent action" ;;
      *) response="no agent action frees the non-paged pool; it needs the operator" ;;
      esac
      wake="memory guard $(level_name "$i"): $reasons; $response (bin/fm-mem-guard.sh status)"
    elif [ "$lvl" != "$last_i" ] || [ "$pool" != "$last_pool" ]; then
      # A fall that still needs a notice is told at the next repeat; a later rise wakes again.
      printf '%s %s %s\n' "$last" "$lvl" "$pool" >"$STATE/.mem-guard-wake" 2>/dev/null
    fi
  elif [ "$rec" = 1 ]; then
    rm -f "$STATE/.mem-guard-wake"
    wake="memory guard cleared: level $(level_name "$i"): $reasons (bin/fm-mem-guard.sh status)"
  fi
}

cmd_tick() {
  local check=0 t prev_i new_i below reasons wake
  [ "${1:-}" = --check ] && check=1
  TICK_START=$(date +%s)
  guard_dir_ready || { echo "error: cannot create $GUARD_DIR" >&2; exit 1; }
  take_sample 0
  grade
  t=$(now)
  lock_acquire "$LOCK"
  prev_i=0
  if read_level && [ $((t - REC_EPOCH)) -le "$R_state_max_age_s" ]; then prev_i=$(level_index "$REC_LEVEL"); else REC_BELOW=0; fi
  new_i=$GRADE
  below=0
  if [ "$GRADE" -lt "$prev_i" ]; then
    below=$((REC_BELOW + 1))
    if [ "$below" -lt "$R_clear_samples" ]; then
      new_i=$prev_i
    else
      below=0
    fi
  fi
  reasons=${GRADE_REASONS:-all signals within limits}
  printf '%s %s %s %s\n' "$(level_name "$new_i")" "$t" "$below" "$reasons" >"$LEVEL_FILE.tmp.$$" && mv -f "$LEVEL_FILE.tmp.$$" "$LEVEL_FILE"
  append_bounded "$SAMPLES_LOG" "$t level=$(level_name "$new_i") graded=$(level_name "$GRADE") win_avail_mib=${WIN_AVAIL_MIB:--} win_pages_in_ps=${WIN_PAGES_IN_PS:--} win_pages_out_ps=${WIN_PAGES_OUT_PS:--} win_paging_span_s=${WIN_RATE_SPAN_S:--} win_pool_mib=${WIN_POOL_MIB:--} linux_avail_mib=${LINUX_AVAIL_MIB:--} linux_cache_mib=${LINUX_CACHE_MIB:--} linux_swap_used_mib=${LINUX_SWAP_USED_MIB:--} swapout_mibps=${LINUX_SWAPOUT_MIBPS:--} psi_full=${LINUX_PSI_FULL:--} win_source=${WIN_SOURCE// /_}"
  [ "$new_i" = "$prev_i" ] || event "level $(level_name "$prev_i") -> $(level_name "$new_i"): $reasons"
  if [ -n "$LINUX_PSWPOUT" ] && { [ -z "$SWAPOUT_NEWEST" ] || [ $((t - ${SWAPOUT_NEWEST%% *})) -ge "$RATE_WINDOW_S" ] || [ "$t" -lt "${SWAPOUT_NEWEST%% *}" ]; }; then
    printf '%s %s %s\n' "$t" "$LINUX_PSWPOUT" "$SWAPOUT_NEWEST" >"$SWAPOUT_FILE.tmp.$$" && mv -f "$SWAPOUT_FILE.tmp.$$" "$SWAPOUT_FILE"
  fi
  case "$WIN_SOURCE" in unavailable:*) event "sample degraded to Linux-only: Windows ${WIN_SOURCE}" ;; esac
  lock_release "$LOCK"

  wake=
  if [ -d "$STATE" ] && ! is_secondmate_home; then
    wake_decide "$new_i" "$t" "$reasons"
  elif [ -d "$STATE" ] && [ -e "$STATE/.mem-guard-wake" ]; then
    rm -f "$STATE/.mem-guard-wake"
  fi
  if [ "$check" = 1 ]; then
    [ -z "$wake" ] || printf '%s\n' "$wake"
  else
    printf 'level=%s\nreasons=%s\n' "$(level_name "$new_i")" "$reasons"
    [ -z "$wake" ] || printf 'wake=%s\n' "$wake"
  fi
  if [ "$new_i" -ge 2 ] && [ -d "$STATE" ]; then
    park_idle "$(level_name "$new_i")"
  fi
}

cmd_status() {
  take_sample 0
  grade
  print_sample
  printf 'graded=%s\n' "$(level_name "$GRADE")"
  printf 'graded_reasons=%s\n' "${GRADE_REASONS:-all signals within limits}"
  if recorded_fresh; then
    printf 'recorded=%s at %s\n' "$REC_LEVEL" "$REC_EPOCH"
  else
    printf 'recorded=unknown (no tick within %ss)\n' "$R_state_max_age_s"
  fi
}

check_body() {
  printf '#!/bin/sh\n# Generated by bin/fm-mem-guard.sh auto: machine memory guard tick.\nexec env FM_HOME=%s %s tick --check\n' \
    "$(printf '%q' "$FM_HOME")" "$(printf '%q' "$FM_ROOT/bin/fm-mem-guard.sh")"
}

cmd_auto() {
  local mode=${1:-} want=1 check="$STATE/$CHECK_ID.check.sh" body tmp
  case "$mode" in
  on | off)
    if ! { mkdir -p "$CONFIG" && printf '%s\n' "$mode" >"$CONFIG/mem-guard"; }; then
      echo "error: could not write config/mem-guard" >&2
      exit 1
    fi
    ;;
  sync) ;;
  *) echo "error: usage: fm-mem-guard.sh auto on|off|sync" >&2; exit 2 ;;
  esac
  [ "$(head -1 "$CONFIG/mem-guard" 2>/dev/null)" != off ] || want=0
  [ "${FM_MEM_GUARD:-}" != off ] || want=0
  [ -r "$PROC/meminfo" ] || want=0
  if [ "$want" = 0 ]; then
    if [ -e "$check" ]; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || { echo "error: could not retire state/$CHECK_ID.check.sh" >&2; exit 1; }
    fi
    [ "$mode" = sync ] || echo "auto: memory guard off"
    return 0
  fi
  [ -d "$STATE" ] || { echo "error: state directory $STATE is missing" >&2; exit 1; }
  body=$(check_body)
  if [ -f "$check" ] && [ "$(cat "$check")" = "$body" ] && [ -f "$STATE/$CHECK_ID.check-trust" ]; then
    [ "$mode" = sync ] || echo "auto: memory guard on"
    return 0
  fi
  # The register binds the staged bytes before renaming them onto the check, so
  # a watcher sweep never finds the new check unbound.
  if ! tmp=$(umask 077 && mktemp "$STATE/.fm-mem-guard-check.XXXXXX"); then
    echo "error: could not write state/$CHECK_ID.check.sh" >&2
    exit 1
  fi
  if ! { printf '%s\n' "$body" >"$tmp" && chmod 0700 "$tmp"; }; then
    rm -f -- "$tmp"
    echo "error: could not write state/$CHECK_ID.check.sh" >&2
    exit 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" --from "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    echo "error: could not register state/$CHECK_ID.check.sh" >&2
    exit 1
  fi
  [ "$mode" = sync ] || echo "auto: memory guard on"
}

CMD=${1:-}
[ $# -eq 0 ] || shift
case "$CMD" in
-h | --help)
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
sample | status | tick | level | admit | auto) ;;
*)
  echo "error: usage: fm-mem-guard.sh sample|status|tick|level|admit|auto (see --help)" >&2
  exit 2
  ;;
esac

if [ "${FM_MEM_GUARD:-}" = off ]; then
  case "$CMD" in
  level) echo unknown; exit 0 ;;
  admit) echo admit; exit 0 ;;
  tick) exit 0 ;;
  esac
fi

load_rules

case "$CMD" in
sample)
  guard_dir_ready || true
  take_sample "$([ "${1:-}" = --fresh ] && echo 1 || echo 0)"
  print_sample
  ;;
status)
  guard_dir_ready || true
  cmd_status
  ;;
tick) cmd_tick "$@" ;;
level) cmd_level ;;
admit) cmd_admit "$@" ;;
auto) cmd_auto "$@" ;;
esac
