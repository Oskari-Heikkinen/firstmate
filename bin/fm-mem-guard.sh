#!/usr/bin/env bash
# Machine memory guard: sample Windows and Linux memory, grade the machine, and respond.
# Usage: fm-mem-guard.sh sample [--fresh]
#        fm-mem-guard.sh status
#        fm-mem-guard.sh tick [--check]
#        fm-mem-guard.sh level
#        fm-mem-guard.sh admit [--cost-mib <n>]
#        fm-mem-guard.sh auto sync|on|off
#   sample  prints one sample as key=value lines: Windows available memory and
#           paging rate (win_*), Linux MemAvailable, page cache, swap, and
#           memory pressure (linux_*), and win_source, which is `powershell`,
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
#                      and the next pass starts where an unfinished one stopped;
#                      without bin/fm-park.sh it logs that park acts as warn only;
#             refuse   also makes every new agent spawn (bin/fm-admission.sh) and
#                      heavy-job start (`admit`) refuse, naming the memory guard;
#             critical also prints one wake line in a primary home, again after
#                      critical_rewake_s while still critical. Secondmate homes
#                      never print it, so only main is woken.
#           --check is the watcher form: identical, and stdout carries only the
#           wake line, printed before any park work. Every level at or above one
#           step includes the lower steps' responses.
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
# thresholds, one per level from warn to critical, and the machine level is the
# highest any signal reaches. A lower level is recorded only after clear_samples
# consecutive samples grade below the recorded one; a higher level is recorded
# at once.
#
# Thresholds and timings: the optional `memory_guard` object of the machine
# admission rules file ${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json};
# docs/configuration.md "Memory guard" owns its keys and defaults. A malformed
# value warns on stderr and keeps the default.
#
# Machine-wide records (runtime scratch, written only here), in
# ${FM_MEM_GUARD_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fm-mem-guard}:
#   level        `<level> <epoch> <below-count> <reasons>`
#   windows      `<epoch> <total_kib> <free_kib> <avail_mib> <pages_in/s> <pages_out/s>`
#   samples.log  one line per tick, trimmed to log_max_lines
#   events.log   one line per level change, park action, or degraded sample, trimmed likewise
#   lock/        mkdir lock around record writes; win.lock/ around the powershell call
# Per-home records, written only here: state/.mem-guard-park (`<last park epoch>
# [<id where an unfinished pass stopped>]`),
# state/.mem-guard-wake (last critical wake epoch), state/mem-guard.check.sh.
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
SAMPLES_LOG="$GUARD_DIR/samples.log"
EVENTS_LOG="$GUARD_DIR/events.log"
LOCK="$GUARD_DIR/lock"
WIN_LOCK="$GUARD_DIR/win.lock"
CHECK_ID=mem-guard
LEVELS="ok warn park refuse critical"

# Built-in defaults; thresholds are "warn park refuse critical".
T_win_available_mib="4096 3072 2048 1024"      # Windows available memory at or below
T_win_paging_mibps="30 60 90 120"              # Windows paging (pages in + out) at or above
T_linux_available_mib="6144 4096 3072 1536"    # Linux MemAvailable at or below
T_linux_psi_full_avg10="2 5 10 25"             # Linux memory pressure full avg10 at or above
R_win_timeout_s=20
R_win_cache_s=60
R_win_stale_max_s=600
R_state_max_age_s=900
R_clear_samples=2
R_park_interval_s=900
R_critical_rewake_s=1800
R_log_max_lines=5000

THRESHOLD_KEYS="win_available_mib win_paging_mibps linux_available_mib linux_psi_full_avg10"
RULE_KEYS="win_timeout_s win_cache_s win_stale_max_s state_max_age_s clear_samples park_interval_s critical_rewake_s log_max_lines"

now() { printf '%s' "${FM_MEM_GUARD_NOW:-$(date +%s)}"; }

load_rules() {
  local key val
  [ -f "$RULES_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e '.memory_guard | type == "object"' "$RULES_FILE" >/dev/null 2>&1 || return 0
  for key in $THRESHOLD_KEYS; do
    jq -e --arg k "$key" '.memory_guard | has($k)' "$RULES_FILE" >/dev/null 2>&1 || continue
    val=$(jq -r --arg k "$key" '.memory_guard[$k] | select(type == "array" and length == 4 and all(type == "number")) | map(tostring) | join(" ")' "$RULES_FILE" 2>/dev/null) || val=
    if [ -z "$val" ]; then
      echo "warning: fm-mem-guard: memory_guard.$key in $RULES_FILE is not four numbers (warn park refuse critical); using the default" >&2
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

# Windows reading: one line "<total_kib> <free_kib> <avail_mib> <pages_in/s> <pages_out/s>".
# shellcheck disable=SC2016 # PowerShell variables, expanded by powershell.exe
PS_QUERY='$o = Get-CimInstance Win32_OperatingSystem; $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; "{0} {1} {2} {3} {4}" -f $o.TotalVisibleMemorySize, $o.FreePhysicalMemory, $p.AvailableMBytes, $p.PagesInputPersec, $p.PagesOutputPersec'

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
  out=$(printf '%s\n' "$out" | awk 'NF == 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9.]+$/ && $5 ~ /^[0-9.]+$/ { print; exit }')
  if [ -z "$out" ]; then
    WIN_ERR="powershell.exe gave no memory reading (exit $rc)"
    return 1
  fi
  printf '%s %s\n' "$(now)" "$out" >"$WIN_FILE.tmp.$$" && mv -f "$WIN_FILE.tmp.$$" "$WIN_FILE"
}

# win_read <fresh>: sets WIN_* values and WIN_SOURCE.
win_read() {
  local fresh=$1 line epoch age t
  WIN_TOTAL_KIB='' WIN_FREE_KIB='' WIN_AVAIL_MIB='' WIN_PAGING_MIBPS='' WIN_SOURCE=''
  t=$(now)
  line=$(cat "$WIN_FILE" 2>/dev/null) || line=
  epoch=${line%% *}
  case "$epoch" in '' | *[!0-9]*) epoch=0 ;; esac
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
    epoch=${line%% *}
    case "$epoch" in '' | *[!0-9]*) epoch=0 ;; esac
    age=$((t - epoch))
  fi
  if [ "$epoch" -gt 0 ] && [ "$age" -le "$R_win_stale_max_s" ]; then
    # shellcheck disable=SC2086 # the cache line is five space-separated numbers
    set -- $line
    WIN_TOTAL_KIB=$2 WIN_FREE_KIB=$3 WIN_AVAIL_MIB=$4
    WIN_PAGING_MIBPS=$(awk -v i="$5" -v o="$6" 'BEGIN { printf "%.1f", (i + o) * 4 / 1024 }')
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

linux_read() {
  local v c b st sf
  LINUX_AVAIL_MIB='' LINUX_TOTAL_MIB='' LINUX_CACHE_MIB='' LINUX_SWAP_USED_MIB='' LINUX_PSI_SOME='' LINUX_PSI_FULL=''
  v=$(meminfo_kib MemAvailable) && LINUX_AVAIL_MIB=$((v / 1024))
  v=$(meminfo_kib MemTotal) && LINUX_TOTAL_MIB=$((v / 1024))
  if c=$(meminfo_kib Cached) && b=$(meminfo_kib Buffers); then LINUX_CACHE_MIB=$(((c + b) / 1024)); fi
  if st=$(meminfo_kib SwapTotal) && sf=$(meminfo_kib SwapFree); then LINUX_SWAP_USED_MIB=$(((st - sf) / 1024)); fi
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
  printf 'win_paging_mibps=%s\n' "$WIN_PAGING_MIBPS"
  printf 'win_source=%s\n' "$WIN_SOURCE"
  printf 'linux_total_mib=%s\n' "$LINUX_TOTAL_MIB"
  printf 'linux_available_mib=%s\n' "$LINUX_AVAIL_MIB"
  printf 'linux_cache_mib=%s\n' "$LINUX_CACHE_MIB"
  printf 'linux_swap_used_mib=%s\n' "$LINUX_SWAP_USED_MIB"
  printf 'linux_psi_some_avg10=%s\n' "$LINUX_PSI_SOME"
  printf 'linux_psi_full_avg10=%s\n' "$LINUX_PSI_FULL"
}

# grade_signal <value> <below|above> <thresholds> -> level index (0 when value empty)
grade_signal() {
  [ -n "$1" ] || { printf 0; return; }
  # shellcheck disable=SC2086 # thresholds are four space-separated numbers
  awk -v v="$1" -v dir="$2" -v t="$3" 'BEGIN {
    n = split(t, a, " "); lvl = 0
    for (i = 1; i <= n; i++) if ((dir == "below" && v + 0 <= a[i] + 0) || (dir == "above" && v + 0 >= a[i] + 0)) lvl = i
    printf "%d", lvl }'
}

# grade: sets GRADE (index) and GRADE_REASONS from the current sample.
grade() {
  local g
  GRADE=0 GRADE_REASONS=
  g=$(grade_signal "$WIN_AVAIL_MIB" below "$T_win_available_mib")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Windows available ${WIN_AVAIL_MIB} MiB ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  g=$(grade_signal "$WIN_PAGING_MIBPS" above "$T_win_paging_mibps")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Windows paging ${WIN_PAGING_MIBPS} MiB/s ($(level_name "$g"))"
  [ "$g" -le "$GRADE" ] || GRADE=$g
  g=$(grade_signal "$LINUX_AVAIL_MIB" below "$T_linux_available_mib")
  [ "$g" -eq 0 ] || GRADE_REASONS="$GRADE_REASONS; Linux available ${LINUX_AVAIL_MIB} MiB ($(level_name "$g"))"
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
        stopped=$id
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
    event "park: $FM_HOME pass reached its time budget at $stopped; the next pass starts there"
  fi
  [ "$parked" = 0 ] || event "park: $FM_HOME parked $parked idle worker(s)"
  [ "$steered" = 0 ] || event "park: $FM_HOME steered $steered idle worker(s) to park themselves"
}

is_secondmate_home() {
  [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]
}

cmd_tick() {
  local check=0 t prev_i new_i below reasons wake last
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
  append_bounded "$SAMPLES_LOG" "$t level=$(level_name "$new_i") graded=$(level_name "$GRADE") win_avail_mib=${WIN_AVAIL_MIB:--} win_paging_mibps=${WIN_PAGING_MIBPS:--} linux_avail_mib=${LINUX_AVAIL_MIB:--} linux_cache_mib=${LINUX_CACHE_MIB:--} linux_swap_used_mib=${LINUX_SWAP_USED_MIB:--} psi_full=${LINUX_PSI_FULL:--} win_source=${WIN_SOURCE// /_}"
  [ "$new_i" = "$prev_i" ] || event "level $(level_name "$prev_i") -> $(level_name "$new_i"): $reasons"
  case "$WIN_SOURCE" in unavailable:*) event "sample degraded to Linux-only: Windows ${WIN_SOURCE}" ;; esac
  lock_release "$LOCK"

  wake=
  if [ "$new_i" -ge 4 ] && [ -d "$STATE" ] && ! is_secondmate_home; then
    last=$(cat "$STATE/.mem-guard-wake" 2>/dev/null) || last=0
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
    if [ $((t - last)) -ge "$R_critical_rewake_s" ]; then
      printf '%s\n' "$t" >"$STATE/.mem-guard-wake" 2>/dev/null
      wake="memory guard critical: $reasons; new agents and heavy jobs are refused; park or finish waiting workers and stop heavy jobs (bin/fm-mem-guard.sh status)"
    fi
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
  local mode=${1:-} want=1 check="$STATE/$CHECK_ID.check.sh" body
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
  if ! { (umask 077 && printf '%s\n' "$body" >"$check.tmp.$$") && chmod 0700 "$check.tmp.$$" && mv -f "$check.tmp.$$" "$check"; }; then
    rm -f "$check.tmp.$$"
    echo "error: could not write state/$CHECK_ID.check.sh" >&2
    exit 1
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || { echo "error: could not register state/$CHECK_ID.check.sh" >&2; exit 1; }
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
