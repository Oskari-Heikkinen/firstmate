# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched at every step of
# each poll cycle, within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.
# P0 capability/fence readers below are opt-in and write nothing.
# The separate tick APIs are opt-in instrumentation for an already singly owned
# loop. fm_supervision_tick_init <stem> <family> <unit> [4096..65536 byte-cap]
# begins one writer generation; fm_supervision_tick_append appends one tick.
# Both use builtins only, return 2 on instrumentation failure, and never alter
# supervision ownership. The loop/entry wrappers keep supervision running and
# invalidate recording through its error marker and the existing watcher wake.
# FM_SUPERVISION_TICKS=1|0 overrides config/supervision-tick-logging presence.
# Recording needs Linux + Bash EPOCHREALTIME; it is disabled by default.
# FM_SUPERVISION_ENTRY_MAX_BYTES controls watcher rename threshold (4 KiB..16 MiB,
# default 4 MiB). Only the existing watcher rotates shared entries, using its
# existing summary stat plus one rename. A failed stream is never zero ticks.
# docs/supervision-accounting.md owns these protocols and activation refusal.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or a registered custom check
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

fm_supervision_tick_boot_to() { # <out-variable>, no subprocess
  local _fm_tick_boot='' LC_ALL=C
  IFS= read -r -n 64 _fm_tick_boot < /proc/sys/kernel/random/boot_id || return 2
  [[ "$_fm_tick_boot" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 2
  printf -v "$1" '%s' "$_fm_tick_boot"
}

# Tick slots are not shared-writer logs. The existing actor's singleton/source
# ownership MUST serialize generations before init; these functions acquire no
# new lock and do not grant that ownership. Every record is ASCII, so Bash's
# character count is also the exact byte count without a wc/stat subprocess.
fm_supervision_tick_init() {
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] || return 2
  local LC_ALL=C
  FM_SUP_TICK_STEM=$1
  FM_SUP_TICK_FAMILY=$2
  FM_SUP_TICK_UNIT=$3
  FM_SUP_TICK_CAP=${4:-65536}
  FM_SUP_TICK_BYTES=0
  FM_SUP_TICK_SEQ=0
  FM_SUP_TICK_SLOT=0
  FM_SUP_TICK_PID=${BASHPID:-$$}
  FM_SUP_TICK_GENERATION=${EPOCHREALTIME-}
  FM_SUP_TICK_BOOT=''
  FM_SUP_TICK_FAILED=1
  [[ "$FM_SUP_TICK_FAMILY" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] && \
    [[ "$FM_SUP_TICK_UNIT" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || return 2
  case "$FM_SUP_TICK_CAP" in ''|0*|*[!0-9]*) return 2 ;; esac
  [ "${#FM_SUP_TICK_CAP}" -le 5 ] && [ "$FM_SUP_TICK_CAP" -ge 4096 ] && [ "$FM_SUP_TICK_CAP" -le 65536 ] || return 2
  [[ "$FM_SUP_TICK_GENERATION" =~ ^[0-9]{1,12}\.[0-9]{6}$ ]] || return 2
  [ -r /proc/uptime ] || return 2
  fm_supervision_tick_boot_to FM_SUP_TICK_BOOT || return 2
  [ -d "${FM_SUP_TICK_STEM%/*}" ] && [ ! -L "${FM_SUP_TICK_STEM%/*}" ] || return 2
  local path old_slot=''
  for path in "$FM_SUP_TICK_STEM.0.tsv" "$FM_SUP_TICK_STEM.1.tsv" "$FM_SUP_TICK_STEM.cursor"; do
    [ ! -L "$path" ] && { [ ! -e "$path" ] || [ -f "$path" ]; } || return 2
  done
  if [ -f "$FM_SUP_TICK_STEM.cursor" ]; then
    if IFS= read -r -d '' -n 4 old_slot < "$FM_SUP_TICK_STEM.cursor"; then return 2; fi
    case "$old_slot" in $'0\n') FM_SUP_TICK_SLOT=1 ;; $'1\n') FM_SUP_TICK_SLOT=0 ;; *) return 2 ;; esac
  fi
  # A new generation starts in the other slot, retaining the predecessor's
  # last complete slot. No mv/rm/stat/date, command substitution or subshell.
  : > "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" || return 2
  printf '%s\n' "$FM_SUP_TICK_SLOT" > "$FM_SUP_TICK_STEM.cursor" || return 2
  FM_SUP_TICK_FAILED=0
  fm_supervision_tick_write start
}

fm_supervision_tick_write() { # <start|rotate|tick>, called only after init
  [ "${FM_SUP_TICK_FAILED:-1}" -eq 0 ] || return 2
  # Bash 3.2/non-Linux callers get an explicit init refusal, not a date fork.
  local wall=${EPOCHREALTIME-} uptime='' rest='' line='' phase=$1 LC_ALL=C
  [[ "$wall" =~ ^[0-9]{1,12}\.[0-9]{6}$ ]] || { FM_SUP_TICK_FAILED=1; return 2; }
  IFS=' ' read -r uptime rest < /proc/uptime || { FM_SUP_TICK_FAILED=1; return 2; }
  [[ "$uptime" =~ ^[0-9]{1,12}\.[0-9]{2}$ ]] || { FM_SUP_TICK_FAILED=1; return 2; }
  printf -v line 'fm-supervision-tick.v2\t%s\t%s\t%s\t%s:%s\t%s\t%s\t%s\t%s\n' \
    "$FM_SUP_TICK_FAMILY" "$FM_SUP_TICK_UNIT" "$FM_SUP_TICK_BOOT" "$FM_SUP_TICK_PID" "$FM_SUP_TICK_GENERATION" \
    "$FM_SUP_TICK_SEQ" "$wall" "$uptime" "$phase"
  if [ $((FM_SUP_TICK_BYTES + ${#line})) -gt "$FM_SUP_TICK_CAP" ]; then
    FM_SUP_TICK_SLOT=$((1 - FM_SUP_TICK_SLOT))
    FM_SUP_TICK_BYTES=0
    if [ -L "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" ] \
      || { [ -e "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" ] && [ ! -f "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" ]; }; then
      FM_SUP_TICK_FAILED=1; return 2
    fi
    : > "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" || { FM_SUP_TICK_FAILED=1; return 2; }
    printf '%s\n' "$FM_SUP_TICK_SLOT" > "$FM_SUP_TICK_STEM.cursor" || { FM_SUP_TICK_FAILED=1; return 2; }
    # The first retained tick carries its generation and absolute sequence.
    # An offline reader can detect a missing prefix and refuse window coverage.
    phase=rotate
    printf -v line 'fm-supervision-tick.v2\t%s\t%s\t%s\t%s:%s\t%s\t%s\t%s\t%s\n' \
      "$FM_SUP_TICK_FAMILY" "$FM_SUP_TICK_UNIT" "$FM_SUP_TICK_BOOT" "$FM_SUP_TICK_PID" "$FM_SUP_TICK_GENERATION" \
      "$FM_SUP_TICK_SEQ" "$wall" "$uptime" "$phase"
  fi
  [ -f "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" ] && [ ! -L "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" ] \
    || { FM_SUP_TICK_FAILED=1; return 2; }
  printf '%s' "$line" >> "$FM_SUP_TICK_STEM.$FM_SUP_TICK_SLOT.tsv" || { FM_SUP_TICK_FAILED=1; return 2; }
  FM_SUP_TICK_BYTES=$((FM_SUP_TICK_BYTES + ${#line}))
}

fm_supervision_tick_append() {
  [ "${FM_SUP_TICK_FAILED:-1}" -eq 0 ] || return 2
  [ "${BASHPID:-$$}" = "$FM_SUP_TICK_PID" ] || return 2
  FM_SUP_TICK_SEQ=$((FM_SUP_TICK_SEQ + 1))
  fm_supervision_tick_write tick
}

# Instrumentation is opt-in per process start or invocation, never a new reader.
fm_supervision_ticks_enabled() { # <home-state> <home-config>
  case "${FM_SUPERVISION_TICKS:-}" in 1) return 0 ;; 0) return 1 ;; '') ;; *) return 1 ;; esac
  [ -f "$2/supervision-tick-logging" ] && [ ! -L "$2/supervision-tick-logging" ]
}

fm_supervision_tick_error() { # <state> <context>
  # A cohort is permanently invalid once this object exists, even if a write
  # was interrupted. Preserve its first evidence and do not churn timestamps.
  if [ -e "$1/.supervision-ticks.error" ] || [ -L "$1/.supervision-ticks.error" ]; then return 0; fi
  printf 'supervision-accounting: tick recording invalid: %s\n' "$2" >&2
  # Permanent invalidation of this recording cohort, not a supervision-health
  # verdict. The existing watcher presents it; an owner must preserve it with
  # the recording, repair the cause and explicitly begin a new cohort.
  if [ -d "$1" ] && [ ! -L "$1/.supervision-ticks.error" ]; then
    printf 'fm-supervision-tick-error.v1\t%s\t%s\t%s\n' \
      "${EPOCHREALTIME:-unavailable}" "${BASHPID:-$$}" "$2" > "$1/.supervision-ticks.error" || true
  fi
}

fm_supervision_tick_loop_init() { # <state> <config> <stem> <family> <unit>
  FM_SUP_TICK_ENABLED=0
  FM_SUP_TICK_STATE=$1
  fm_supervision_ticks_enabled "$1" "$2" || return 0
  if fm_supervision_tick_init "$3" "$4" "$5"; then
    FM_SUP_TICK_ENABLED=1
  else
    FM_SUP_TICK_ENABLED=2
    fm_supervision_tick_error "$1" "loop-init-$4"
  fi
}

fm_supervision_tick_loop() {
  case "${FM_SUP_TICK_ENABLED:-0}" in
    0) return 0 ;;
    2) fm_supervision_tick_error "$FM_SUP_TICK_STATE" "loop-invalid-$FM_SUP_TICK_FAMILY"; return 0 ;;
  esac
  if ! fm_supervision_tick_append; then
    FM_SUP_TICK_ENABLED=2
    fm_supervision_tick_error "$FM_SUP_TICK_STATE" "loop-append-$FM_SUP_TICK_FAMILY"
  fi
}

fm_supervision_tick_entry() { # <state> <config> <family> [unit]
  fm_supervision_ticks_enabled "$1" "$2" || return 0
  local wall=${EPOCHREALTIME-} uptime='' boot_id='' rest='' line='' path="$1/.supervision-entries.tsv" unit=${4:-invocation-v1} LC_ALL=C
  if ! [[ "$3" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || ! [[ "$unit" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    fm_supervision_tick_error "$1" entry-label; return 0
  fi
  if ! [[ "$wall" =~ ^[0-9]{1,12}\.[0-9]{6}$ ]] || [ ! -r /proc/uptime ]; then
    fm_supervision_tick_error "$1" "entry-clock-$3"; return 0
  fi
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    fm_supervision_tick_error "$1" "entry-file-$3"; return 0
  fi
  IFS=' ' read -r uptime rest < /proc/uptime || { fm_supervision_tick_error "$1" "entry-uptime-$3"; return 0; }
  [[ "$uptime" =~ ^[0-9]{1,12}\.[0-9]{2}$ ]] || { fm_supervision_tick_error "$1" "entry-uptime-format-$3"; return 0; }
  fm_supervision_tick_boot_to boot_id || { fm_supervision_tick_error "$1" "entry-boot-$3"; return 0; }
  printf -v line 'fm-supervision-tick.v2\t%s\t%s\t%s\t%s:%s\t1\t%s\t%s\tentry\n' \
    "$3" "$unit" "$boot_id" "${BASHPID:-$$}" "$wall" "$wall" "$uptime"
  # One small O_APPEND write; no per-entry stat, lock, helper, timer or poll.
  printf '%s' "$line" >> "$path" || fm_supervision_tick_error "$1" "entry-append-$3"
}

# Called only from the existing slow-check step, with fm_wake_append supplied
# by that owner. Receipt follows durable queue publication; failure retries on
# the next existing check without stopping monitoring. Beginning a new recording
# cohort archives BOTH the error object and its queued receipt.
fm_supervision_tick_check_notice() { # <state>; sets FM_SUP_TICK_CHECK_REASON
  local state=$1 seen='' reason
  FM_SUP_TICK_CHECK_REASON=''
  [ -e "$state/.supervision-ticks.error" ] || [ -L "$state/.supervision-ticks.error" ] || return 0
  if [ -f "$state/.supervision-ticks.error-seen" ] && [ ! -L "$state/.supervision-ticks.error-seen" ]; then
    if IFS= read -r -d '' -n 16 seen < "$state/.supervision-ticks.error-seen"; then seen=invalid; fi
  fi
  [ "$seen" != $'queued\n' ] || return 0
  reason='check: supervision tick recording invalid; preserve .supervision-ticks.error and repair before beginning another measurement cohort'
  if fm_wake_append check supervision-tick-recording "$reason"; then
    if [ ! -L "$state/.supervision-ticks.error-seen" ] \
      && { [ ! -e "$state/.supervision-ticks.error-seen" ] || [ -f "$state/.supervision-ticks.error-seen" ]; }; then
      printf 'queued\n' > "$state/.supervision-ticks.error-seen" || true
    fi
    # shellcheck disable=SC2034 # Public output consumed by the watcher check step.
    FM_SUP_TICK_CHECK_REASON=$reason
  else
    printf 'supervision-accounting: recording invalidation notice was not queued; retry on the next existing check pass\n' >&2
  fi
}

# Called ONLY by the existing watcher pass, with the size from its already
# needed summary stat. At most one rename when due; never truncates a shared
# inode. Frozen writers across TWO rotations can lose a line silently.
fm_supervision_tick_rotate_entries() { # <state> <observed-size> [byte-cap]
  local state=$1 size=$2 cap=${3:-4194304}
  case "$size:$cap" in *[!0-9:]*|:|*:|:*) return 2 ;; esac
  [ "${#size}" -le 18 ] && [ "${#cap}" -le 8 ] && [ "$cap" -ge 4096 ] && [ "$cap" -le 16777216 ] || return 2
  [ "$size" -ge "$cap" ] || return 0
  [ -f "$state/.supervision-entries.tsv" ] && [ ! -L "$state/.supervision-entries.tsv" ] \
    && [ ! -L "$state/.supervision-entries.previous.tsv" ] \
    && { [ ! -e "$state/.supervision-entries.previous.tsv" ] || [ -f "$state/.supervision-entries.previous.tsv" ]; } || return 2
  mv -f -- "$state/.supervision-entries.tsv" "$state/.supervision-entries.previous.tsv"
}

# fm_supervision_reader_capabilities
# Reader-first inventory, not a claim that existing callbacks are all fenced.
fm_supervision_reader_capabilities() {
  printf '%s\n' 'fm-supervision-readers.v1' 'legacy-pid-cycle.v1' 'legacy-epoch-check.v1'
}

# fm_supervision_activation_supported <protocol> <mode> <required-capability>...
# P0 has no resident activation path. Missing/unknown requirements fail closed.
fm_supervision_activation_supported() {
  [ "$#" -ge 3 ] || return 1
  [ "$1" = fm-supervision-readers.v1 ] && [ "$2" = legacy ] || return 1
  shift 2
  local capability
  for capability in "$@"; do
    case "$capability" in
      legacy-pid-cycle.v1|legacy-epoch-check.v1) ;;
      *) return 1 ;;
    esac
  done
}

# fm_supervision_fence_check <enabled:0|1> <expected-epoch> <owner-record>
# Call only inside the caller's EXISTING short commit boundary. This reader
# neither acquires a lock nor makes check-then-callback atomic by itself.
# Disabled means no record access at all; no legacy producer enables it in P0.
fm_supervision_fence_check() {
  [ "$#" -eq 3 ] || return 1
  case "$1" in 0) return 0 ;; 1) ;; *) return 1 ;; esac
  local expected=$2 record=$3 line='' LC_ALL=C
  case "$expected" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#expected}" -le 18 ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  # A NUL delimiter makes read succeed on binary input instead of silently
  # discarding it. Hitting the size bound also refuses; valid records fit in
  # fewer than 64 bytes. Only EOF without a NUL can reach the exact byte check.
  if IFS= read -r -d '' -n 64 line < "$record"; then return 1; fi
  [ "$line" = "fm-supervision-owner.v1"$'\t'"legacy"$'\t'"$expected"$'\n' ]
}
