#!/usr/bin/env bash
# Machine-wide admission gate: may one more heavy unit (an agent spawn) start now?
# Usage: fm-admission.sh check   [--relaunch|--secondmate] [--home <dir>]
#        fm-admission.sh acquire [--relaunch|--secondmate] [--home <dir>] [--label <text>] [--override]
#        fm-admission.sh rules
#   check   evaluates the rules once, prints `admit` or `wait: <unmet conditions>`,
#           and exits 0 when admitted or 1 when not. It records nothing.
#   acquire evaluates, and while not admitted waits with jittered exponential
#           backoff (5 s doubling to a 30 s cap, plus up to 4 s jitter) until
#           wait_max_s has elapsed. On admission it appends one line to the
#           machine-wide admission ledger and exits 0. When the bound runs out
#           it prints `error: admission refused after <n>s: <unmet conditions>`
#           and exits 3 - never a silent refusal.
#           --override admits at once, prints a notice naming what it skipped,
#           and still records the ledger line so later admissions see it.
#           --secondmate never refuses: after secondmate_wait_max_s it admits
#           with a warning naming the unmet conditions, so a home's own
#           recovery cannot deadlock behind the fleet it is part of.
#   rules   prints the effective rules as key=value lines.
#   --relaunch and --secondmate mark a restart-shaped launch, which is also
#   paced by relaunch_per_minute_per_home. --home names the firstmate home the
#   launch belongs to (default $FM_HOME); it keys that pacing.
#
# Rules: ${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json}, one JSON
# object whose keys docs/configuration.md "Machine admission" owns. Absent keys
# and an absent file use the built-in defaults below; a malformed file warns on
# stderr and uses the defaults. FM_ADMISSION=off disables the gate entirely
# (every call admits at once and records nothing); the behavior suite sets it
# through tests/lib.sh so fixture spawns never depend on the test host's load.
#
# Signals (Linux): MemAvailable from <proc>/meminfo, `full avg10` from
# <proc>/pressure/memory, `some avg10` from <proc>/pressure/cpu, the 1-minute
# load from <proc>/loadavg divided by the online CPU count, the live agent
# count, and the memory guard's recorded level (`fm-mem-guard.sh level`), which
# holds every launch while it is refuse or critical. A signal that cannot be read is skipped rather than blocking (macOS has
# none of them), and `check` names each skipped signal on stderr.
# Live agents are processes on this machine whose comm, or whose script name
# under a node or bun interpreter, is in agent_process_names, excluding any
# process whose ancestor is itself counted, so one agent's helper processes
# never count twice. Admissions granted in the last 60 s are charged against the
# cap and against free memory as if already running, because a just-admitted
# agent takes seconds to appear.
#
# Ledger: ${FM_ADMISSION_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/fm-admission-<uid>}/admitted,
# lines `<epoch> <relaunch|fresh> <home>`, pruned to the last hour on every
# write and guarded by a mkdir lock beside it. It is runtime scratch only.
#
# Test seams: FM_PROC_ROOT_OVERRIDE (default /proc), FM_ADMISSION_NPROC (CPU
# count), FM_ADMISSION_SLEEP (command run with the wait seconds; default sleep).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROC=${FM_PROC_ROOT_OVERRIDE:-/proc}
RULES_FILE=${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json}
RUN_DIR=${FM_ADMISSION_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/fm-admission-$(id -u)}
LEDGER="$RUN_DIR/admitted"
LOCK="$RUN_DIR/admitted.lock"
RECENT_S=60

# Built-in defaults (the budget design the rules file overrides key by key).
R_mem_floor_mib=6144           # MemAvailable that must remain after the new agent
R_agent_cost_mib=400           # memory one new agent is expected to take
R_mem_full_avg10_max=5         # PSI memory `full avg10` ceiling, percent
R_cpu_some_avg10_max=40        # PSI cpu `some avg10` ceiling, percent
R_load1_per_core_max=1.5       # 1-minute load per online CPU ceiling
R_max_agents=24                # live agent processes machine-wide, new one included
R_relaunch_per_minute_per_home=2
R_wait_max_s=300               # acquire's bound before refusing
R_secondmate_wait_max_s=60     # acquire's bound before a secondmate admits with a warning
R_agent_process_names="claude codex opencode pi pi-signed grok kimi cursor-agent omp gemini devin agy muse"

RULE_KEYS="mem_floor_mib agent_cost_mib mem_full_avg10_max cpu_some_avg10_max load1_per_core_max max_agents relaunch_per_minute_per_home wait_max_s secondmate_wait_max_s"

load_rules() {
  local key val
  [ -f "$RULES_FILE" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "warning: fm-admission: jq is not installed, so $RULES_FILE is ignored and the built-in defaults apply" >&2
    return 0
  fi
  if ! jq -e 'type == "object"' "$RULES_FILE" >/dev/null 2>&1; then
    echo "warning: fm-admission: $RULES_FILE is not a JSON object, so the built-in defaults apply" >&2
    return 0
  fi
  for key in $RULE_KEYS; do
    val=$(jq -r --arg k "$key" '.[$k] // empty | select(type == "number") | tostring' "$RULES_FILE" 2>/dev/null) || val=
    if [ -z "$val" ]; then
      jq -e --arg k "$key" 'has($k)' "$RULES_FILE" >/dev/null 2>&1 &&
        echo "warning: fm-admission: $key in $RULES_FILE is not a number; using the default" >&2
      continue
    fi
    printf -v "R_$key" '%s' "$val"
  done
  val=$(jq -r '.agent_process_names // empty | select(type == "array") | map(select(type == "string")) | join(" ")' "$RULES_FILE" 2>/dev/null) || val=
  [ -z "$val" ] || R_agent_process_names=$val
}

# num_gt <a> <b>: true when decimal a > b.
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

mem_available_mib() {
  awk '$1 == "MemAvailable:" { printf "%d", $2 / 1024; found = 1 } END { exit !found }' "$PROC/meminfo" 2>/dev/null
}

psi_avg10() { # <resource> <some|full>
  awk -v kind="$2" '$1 == kind { for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) { sub(/^avg10=/, "", $i); print $i; found = 1 } } END { exit !found }' "$PROC/pressure/$1" 2>/dev/null
}

load_per_core() {
  local cpus load
  cpus=${FM_ADMISSION_NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo)}
  case "$cpus" in '' | *[!0-9]* | 0) return 1 ;; esac
  load=$(awk '{ print $1; exit }' "$PROC/loadavg" 2>/dev/null) || return 1
  [ -n "$load" ] || return 1
  awk -v l="$load" -v c="$cpus" 'BEGIN { printf "%.2f", l / c }'
}

# live_agents: count agent processes, one per agent tree. One awk pass over
# every <proc>/<pid>/stat keeps this cheap on a host with thousands of tasks.
live_agents() {
  local rows pid comm ppid arg1 name
  local names=" $R_agent_process_names "
  local -A is_agent=() parent=()
  [ -d "$PROC" ] || return 1
  # shellcheck disable=SC2016 # the single-quoted text is an awk program
  rows=$(find "$PROC" -mindepth 2 -maxdepth 2 -name stat -path "$PROC/[0-9]*/stat" -print0 2>/dev/null |
    xargs -0 awk '{
      line = $0
      o = index(line, "("); c = 0
      for (i = length(line); i > o; i--) if (substr(line, i, 1) == ")") { c = i; break }
      if (!o || !c) next
      comm = substr(line, o + 1, c - o - 1); gsub(/[ \t]/, "_", comm)
      split(substr(line, c + 2), rest, " ")
      print substr(line, 1, o - 2), comm, rest[2]
    }' 2>/dev/null) || true
  [ -n "$rows" ] || return 1
  while read -r pid comm ppid; do
    parent[$pid]=$ppid
    name=$comm
    case "$comm" in
    node | bun)
      arg1=
      { IFS= read -r -d '' _ && IFS= read -r -d '' arg1; } <"$PROC/$pid/cmdline" 2>/dev/null
      name=${arg1##*/}
      ;;
    esac
    case "$names" in *" $name "*) is_agent[$pid]=1 ;; esac
  done <<<"$rows"
  local count=0 p hops
  for pid in "${!is_agent[@]}"; do
    p=${parent[$pid]:-0}
    hops=0
    while [ "$p" != 0 ] && [ "$p" != 1 ] && [ "$hops" -lt 64 ]; do
      [ -z "${is_agent[$p]:-}" ] || continue 2
      p=${parent[$p]:-0}
      hops=$((hops + 1))
    done
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# recent_admissions <since-epoch> [<home>]: ledger lines newer than since; with
# a home, only that home's restart-shaped (relaunch) lines.
recent_admissions() {
  [ -f "$LEDGER" ] || { printf 0; return 0; }
  awk -v since="$1" -v home="${2:-}" '
    $1 >= since { line = $0; sub(/^[^ ]+ [^ ]+ /, "", line); if (home == "" || ($2 == "relaunch" && line == home)) n++ }
    END { printf "%d", n }' "$LEDGER" 2>/dev/null || printf 0
}

# evaluate: sets UNMET (empty when admitted) and SKIPPED.
evaluate() {
  local now avail need psi load agents recent paced guard
  UNMET=
  SKIPPED=
  now=$(date +%s)
  recent=$(recent_admissions $((now - RECENT_S)))
  if avail=$(mem_available_mib) && [ -n "$avail" ]; then
    need=$((R_mem_floor_mib + R_agent_cost_mib * (1 + recent)))
    [ "$avail" -ge "$need" ] || UNMET="$UNMET; free memory ${avail} MiB is below the ${need} MiB needed (floor ${R_mem_floor_mib} + ${R_agent_cost_mib} per new agent, ${recent} admitted in the last ${RECENT_S}s)"
  else
    SKIPPED="$SKIPPED meminfo"
  fi
  if psi=$(psi_avg10 memory full) && [ -n "$psi" ]; then
    ! num_gt "$psi" "$R_mem_full_avg10_max" || UNMET="$UNMET; memory pressure full avg10 ${psi}% exceeds ${R_mem_full_avg10_max}%"
  else
    SKIPPED="$SKIPPED memory-pressure"
  fi
  if psi=$(psi_avg10 cpu some) && [ -n "$psi" ]; then
    ! num_gt "$psi" "$R_cpu_some_avg10_max" || UNMET="$UNMET; cpu pressure some avg10 ${psi}% exceeds ${R_cpu_some_avg10_max}%"
  else
    SKIPPED="$SKIPPED cpu-pressure"
  fi
  if load=$(load_per_core) && [ -n "$load" ]; then
    ! num_gt "$load" "$R_load1_per_core_max" || UNMET="$UNMET; 1-minute load ${load} per core exceeds ${R_load1_per_core_max}"
  else
    SKIPPED="$SKIPPED loadavg"
  fi
  if agents=$(live_agents) && [ -n "$agents" ]; then
    [ $((agents + recent + 1)) -le "$R_max_agents" ] || UNMET="$UNMET; ${agents} live agents plus ${recent} just admitted would exceed the fleet cap of ${R_max_agents}"
  else
    SKIPPED="$SKIPPED agent-count"
  fi
  # The memory guard (bin/fm-mem-guard.sh) also watches the Windows host; its
  # recorded refuse or critical level holds every launch.
  if guard=$("$SCRIPT_DIR/fm-mem-guard.sh" level 2>/dev/null); then
    case "$guard" in
    refuse\ * | critical\ *)
      UNMET="$UNMET; memory guard is at ${guard%% *}: $(printf '%s' "$guard" | cut -d' ' -f3-)"
      ;;
    esac
  fi
  if [ "$RESTART" = 1 ]; then
    paced=$(recent_admissions $((now - 60)) "$HOME_DIR")
    [ "$paced" -lt "$R_relaunch_per_minute_per_home" ] || UNMET="$UNMET; ${paced} relaunches in this home in the last minute reach the pace of ${R_relaunch_per_minute_per_home} per minute"
  fi
  UNMET=${UNMET#; }
}

lock_acquire() {
  local tries=0
  mkdir -p "$RUN_DIR" 2>/dev/null && chmod 700 "$RUN_DIR" 2>/dev/null
  until mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    # A holder only appends one line; a lock this old was abandoned by a crash.
    if [ "$tries" -ge 50 ]; then
      rmdir "$LOCK" 2>/dev/null
      tries=0
    fi
    sleep 0.1
  done
}

lock_release() { rmdir "$LOCK" 2>/dev/null || true; }

record_admission() {
  local now kind=fresh
  [ "$RESTART" = 1 ] && kind=relaunch
  now=$(date +%s)
  if [ -f "$LEDGER" ] && awk -v since=$((now - 3600)) '$1 >= since' "$LEDGER" >"$LEDGER.tmp" 2>/dev/null; then
    mv -f "$LEDGER.tmp" "$LEDGER"
  fi
  printf '%s %s %s\n' "$now" "$kind" "$HOME_DIR" >>"$LEDGER"
}

do_sleep() {
  if [ -n "${FM_ADMISSION_SLEEP:-}" ]; then
    $FM_ADMISSION_SLEEP "$1"
  else
    sleep "$1"
  fi
}

CMD=${1:-}
[ $# -eq 0 ] || shift
RESTART=0
SECONDMATE=0
OVERRIDE=0
HOME_DIR=${FM_HOME:-}
LABEL=
while [ $# -gt 0 ]; do
  case "$1" in
  --relaunch) RESTART=1 ;;
  --secondmate)
    RESTART=1
    SECONDMATE=1
    ;;
  --override) OVERRIDE=1 ;;
  --home)
    [ $# -ge 2 ] || { echo "error: --home requires a value" >&2; exit 2; }
    HOME_DIR=$2
    shift
    ;;
  --label)
    [ $# -ge 2 ] || { echo "error: --label requires a value" >&2; exit 2; }
    LABEL=$2
    shift
    ;;
  *)
    echo "error: unknown argument '$1' (see fm-admission.sh --help)" >&2
    exit 2
    ;;
  esac
  shift
done
[ -n "$HOME_DIR" ] || HOME_DIR=$(pwd -P)
LABEL=${LABEL:-this launch}

case "$CMD" in
-h | --help)
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
check | acquire | rules) ;;
*)
  echo "error: usage: fm-admission.sh check|acquire|rules [--relaunch|--secondmate] [--home <dir>] [--override]" >&2
  exit 2
  ;;
esac

if [ "${FM_ADMISSION:-}" = off ]; then
  case "$CMD" in
  rules) echo "disabled=FM_ADMISSION=off" ;;
  check) echo admit ;;
  esac
  exit 0
fi

load_rules

case "$CMD" in
rules)
  for key in $RULE_KEYS agent_process_names; do
    var="R_$key"
    printf '%s=%s\n' "$key" "${!var}"
  done
  printf 'rules_file=%s\n' "$RULES_FILE"
  exit 0
  ;;
check)
  evaluate
  [ -z "$SKIPPED" ] || echo "note: fm-admission: unreadable signals skipped:$SKIPPED" >&2
  if [ -z "$UNMET" ]; then
    echo admit
    exit 0
  fi
  echo "wait: $UNMET"
  exit 1
  ;;
esac

# acquire
if [ "$OVERRIDE" = 1 ]; then
  lock_acquire
  evaluate
  record_admission
  lock_release
  echo "notice: admission override for $LABEL${UNMET:+ - skipped: $UNMET}" >&2
  exit 0
fi

bound=$R_wait_max_s
[ "$SECONDMATE" = 1 ] && bound=$R_secondmate_wait_max_s
case "$bound" in *.*) bound=${bound%%.*} ;; esac
case "$bound" in '' | *[!0-9]*) bound=300 ;; esac
start=$(date +%s)
delay=5
announced=0
while :; do
  lock_acquire
  evaluate
  if [ -z "$UNMET" ]; then
    record_admission
    lock_release
    [ "$announced" = 0 ] || echo "admission: $LABEL admitted after $(($(date +%s) - start))s" >&2
    exit 0
  fi
  lock_release
  elapsed=$(($(date +%s) - start))
  if [ "$elapsed" -ge "$bound" ]; then
    if [ "$SECONDMATE" = 1 ]; then
      lock_acquire
      record_admission
      lock_release
      echo "warning: admission: secondmate $LABEL starting after ${elapsed}s despite: $UNMET (a home's own recovery is never refused)" >&2
      exit 0
    fi
    echo "error: admission refused for $LABEL after ${elapsed}s: $UNMET; retry later; only a spawn firstmate directs because a landing depends on it may pass --admission-override" >&2
    exit 3
  fi
  if [ "$announced" = 0 ]; then
    echo "admission: $LABEL waiting (up to ${bound}s): $UNMET" >&2
    announced=1
  fi
  step=$((delay + RANDOM % 5))
  [ $((elapsed + step)) -le "$bound" ] || step=$((bound - elapsed))
  [ "$step" -gt 0 ] || step=1
  do_sleep "$step"
  delay=$((delay * 2))
  [ "$delay" -le 30 ] || delay=30
done
