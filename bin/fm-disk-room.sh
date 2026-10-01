#!/usr/bin/env bash
# fm-disk-room.sh - real free room on a WSL laptop, and the admission check that
# keeps big writers from running it out.
#
# On WSL the Linux root lives in a non-sparse ext4.vhdx on the Windows drive, so
# `df /` shows the virtual disk's own (huge) size and space Linux frees stays
# reserved on C: until the file is compacted. Real room is therefore the Windows
# drive's free space, taken together with Linux free space, minus the writes
# that running jobs have declared. Slack inside the disk file is NOT room (ext4
# happily grows the file while slack exists); it is reported separately as what
# the next compaction would reclaim. The Windows restore-point shadow storage's
# headroom (its cap minus what it already uses) is reserved too, because
# copy-on-write after each restore point fills it from host free space while
# Linux df and the disk file stay flat. docs/disk-room.md owns the contract and
# the one-time Windows install (bin/fm-wsl-reclaim.ps1).
#
# Usage:
#   fm-disk-room.sh status [--json]
#       Print host free, Linux free, reservations, the shadow storage
#       reservation and any cycling warning, real room, the disk file's
#       slack and its reclaimable estimate, the last compaction result, and
#       the external SSD's room with the active fetched-results root (read
#       from the results-root file bin/fm-storage.sh publishes).
#   fm-disk-room.sh check --expect-write SIZE [--exclude NAME]
#       Admission: exit 0 when real room minus SIZE stays at or above the
#       margin, 1 when it would fall below, 2 when a reading fails or on misuse.
#       Prints one line either way. --exclude drops the caller's own reservation.
#   fm-disk-room.sh run --name NAME --expect-write SIZE -- COMMAND [ARG...]
#       check, then hold a reservation for the command's lifetime and exec it.
#       Refused (low room or unreadable) exits 75 with one line on stderr.
#   fm-disk-room.sh reserve NAME SIZE [--pid PID] [--ttl SECONDS]
#       Declare an in-flight write. With --pid it lapses when that process
#       exits; otherwise after --ttl (default 43200 s).
#   fm-disk-room.sh release NAME
#   fm-disk-room.sh watch-line
#       For a firstmate custom watcher check: print one line only when real
#       room is under the margin (repeated only after a further 5 GiB drop or
#       6 hours), or when a reading fails (at most every 6 hours); else nothing.
#   fm-disk-room.sh arm | disarm
#       Write FM_HOME's state/disk-room.check.sh shim (running watch-line with
#       this script's environment settings) and bind it with
#       fm-check-register.sh, or retire it with fm-check-unregister.sh.
#
# SIZE is bytes or a number with K, M, G or T (binary: G = GiB, matching what
# Windows Explorer shows as GB).
#
# Environment (all optional):
#   FM_DISK_ROOM_MARGIN   margin kept after the expected write (default 20G)
#   FM_DISK_ROOM_HOST     Windows drive mount (default /mnt/c; absent => Linux-only)
#   FM_DISK_ROOM_ROOT     Linux path whose filesystem is measured (default /)
#   FM_DISK_ROOM_VHDX     the distro's ext4.vhdx as a Linux path (default: the
#                         single match of /mnt/c/Users/*/AppData/Local/wsl/*/ext4.vhdx
#                         or .../Packages/*/LocalState/ext4.vhdx)
#   FM_DISK_ROOM_MB_GROUPS  ext4 mb_groups file (default /proc/fs/ext4/<dev>/mb_groups)
#   FM_DISK_ROOM_COMPACT_RESULT  last-result file written by fm-wsl-reclaim.ps1
#                         (default <host>/ProgramData/firstmate/wsl-compact-last.txt)
#   FM_DISK_ROOM_SHADOW_RECORD  shadow storage max/used written by the elevated
#                         fm-wsl-reclaim.ps1 task (default
#                         <host>/ProgramData/firstmate/shadow-storage.txt). A record
#                         older than 7 days keeps only its max: used is then unknown.
#   FM_DISK_ROOM_SHADOW_MAX  shadow storage cap (SIZE) used when no fresh record
#                         gives one, e.g. 10G. With used unknown the whole cap is
#                         reserved, the conservative choice. Unset and no record:
#                         nothing is reserved.
#   FM_DISK_ROOM_WEVTUTIL  wevtutil command used, only when no fresh record exists,
#                         to count volsnap System events 25/33/36 of the last 7 days
#                         (cached for an hour) for the cycling warning
#                         (default wevtutil.exe on PATH, else the drive's
#                         Windows/System32/wevtutil.exe; empty disables the count)
#   FM_DISK_ROOM_RESULTS_ROOT  results-root file from bin/fm-storage.sh
#                         (default ${XDG_CONFIG_HOME:-~/.config}/lattice-storage/results-root)
#   FM_DISK_ROOM_STATE    reservations and alert record
#                         (default ${XDG_STATE_HOME:-~/.local/state}/fm-disk-room)
#   FM_DISK_ROOM_NOW      epoch override for tests
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIB=1073741824
REALERT_DROP=$((5 * GIB))
REALERT_SECS=21600
DEFAULT_TTL=43200
SHADOW_STALE_SECS=604800
SHADOW_EVENTS_CACHE_SECS=3600

die() { printf 'fm-disk-room: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }

# to_bytes SIZE -> bytes on stdout, or fail.
to_bytes() {
  local v=$1 n unit mult
  case "$v" in
    ''|*[!0-9.KMGTkmgtiIbB]*) return 1 ;;
  esac
  n=${v%%[KMGTkmgt]*}
  unit=${v#"$n"}
  unit=${unit%%[iI][bB]}; unit=${unit%%[bB]}
  case "$unit" in
    '') mult=1 ;;
    [Kk]) mult=1024 ;;
    [Mm]) mult=1048576 ;;
    [Gg]) mult=$GIB ;;
    [Tt]) mult=1099511627776 ;;
    *) return 1 ;;
  esac
  case "$n" in ''|.|*.*.*) return 1 ;; esac
  awk -v n="$n" -v m="$mult" 'BEGIN { printf "%.0f\n", n * m }'
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

now() { printf '%s\n' "${FM_DISK_ROOM_NOW:-$(date +%s)}"; }

state_dir() {
  printf '%s\n' "${FM_DISK_ROOM_STATE:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/fm-disk-room}"
}

valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*) return 1 ;;
  esac
}

# df_field PATH FIELD -> bytes
df_field() { df -B1 --output="$2" -- "$1" 2>/dev/null | awk 'NR == 2 { gsub(/ /, ""); print }'; }

host_mount() { printf '%s\n' "${FM_DISK_ROOM_HOST-/mnt/c}"; }

discover_vhdx() {
  local host m found=() f cache
  if [ -n "${FM_DISK_ROOM_VHDX:-}" ]; then
    printf '%s\n' "$FM_DISK_ROOM_VHDX"
    return 0
  fi
  host=$(host_mount)
  [ -n "$host" ] && [ -d "$host/Users" ] || return 1
  # The Packages glob costs seconds on drvfs, so the single match is cached.
  cache="$(state_dir)/vhdx-path"
  if [ -r "$cache" ]; then
    read -r m <"$cache" || m=''
    case "$m" in
      "$host"/*) [ -f "$m" ] && { printf '%s\n' "$m"; return 0; } ;;
    esac
  fi
  for f in "$host"/Users/*/AppData/Local/wsl/*/ext4.vhdx "$host"/Users/*/AppData/Local/Packages/*/LocalState/ext4.vhdx; do
    [ -f "$f" ] && found+=("$f")
  done
  [ "${#found[@]}" -eq 1 ] || return 1
  m=${found[0]}
  mkdir -p "$(state_dir)" 2>/dev/null && printf '%s\n' "$m" >"$cache" 2>/dev/null
  printf '%s\n' "$m"
}

mb_groups_path() {
  local src dev
  if [ -n "${FM_DISK_ROOM_MB_GROUPS:-}" ]; then
    printf '%s\n' "$FM_DISK_ROOM_MB_GROUPS"
    return 0
  fi
  src=$(findmnt -no SOURCE --target "${FM_DISK_ROOM_ROOT:-/}" 2>/dev/null | head -1) || return 1
  dev=${src##*/}
  [ -n "$dev" ] && printf '/proc/fs/ext4/%s/mb_groups\n' "$dev"
}

# fragmented_free BLOCKSIZE -> bytes of ext4 free space in buddies smaller than
# 1 MiB (the VHDX block), i.e. free space that shares a disk-file block with
# live data and so cannot be reclaimed by compaction.
fragmented_free() {
  local bs=$1 file max_order
  file=$(mb_groups_path) || return 1
  [ -r "$file" ] || return 1
  max_order=$(awk -v bs="$bs" 'BEGIN { o = 0; while (bs * 2 ^ (o + 1) <= 1048576) o++; print o - 1 }')
  sed 's/[#:]/ /g; s/\[/ /; s/\]/ /' "$file" | awk -v bs="$bs" -v top="$max_order" '
    $1 ~ /^[0-9]+$/ { for (i = 0; i <= top; i++) s += $(i + 5) * 2 ^ i; seen = 1 }
    END { if (!seen) exit 1; printf "%.0f\n", s * bs }'
}

# Shadow storage ---------------------------------------------------------------

# wevtutil_cmd -> the wevtutil command to run, or fails when there is none.
# PATH often lacks the Windows directories, so fall back to the drive's copy.
wevtutil_cmd() {
  if [ -n "${FM_DISK_ROOM_WEVTUTIL+set}" ]; then
    [ -n "$FM_DISK_ROOM_WEVTUTIL" ] && command -v -- "$FM_DISK_ROOM_WEVTUTIL" 2>/dev/null
    return
  fi
  command -v wevtutil.exe 2>/dev/null && return 0
  [ -x "$HOST/Windows/System32/wevtutil.exe" ] && printf '%s\n' "$HOST/Windows/System32/wevtutil.exe"
}

# shadow_events -> count of volsnap 25/33/36 System events in the last 7 days,
# or nothing when unknown. Cached for an hour, failures included, because it
# starts a Windows process.
shadow_events() {
  local cache t when='' n='' out cmd
  cmd=$(wevtutil_cmd) && [ -n "$cmd" ] || return 0
  cache="$(state_dir)/shadow-events"
  t=$(now)
  [ -r "$cache" ] && read -r when n <"$cache"
  case "$when" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$t" -ge "$when" ] && [ $(( t - when )) -lt "$SHADOW_EVENTS_CACHE_SECS" ]; then
        case "$n" in ''|*[!0-9]*) ;; *) printf '%s\n' "$n" ;; esac
        return 0
      fi ;;
  esac
  if out=$(timeout 20 "$cmd" qe System /f:xml \
    "/q:*[System[Provider[@Name='volsnap'] and (EventID=25 or EventID=33 or EventID=36) and TimeCreated[timediff(@SystemTime) <= 604800000]]]" \
    2>/dev/null); then
    n=$(printf '%s' "$out" | tr -d '\r' | grep -oE '<EventID[^>]*>(25|33|36)</EventID>' | wc -l | tr -d ' ')
  else
    n=-
  fi
  mkdir -p "$(state_dir)" 2>/dev/null && printf '%s %s\n' "$t" "$n" >"$cache" 2>/dev/null
  [ "$n" = - ] || printf '%s\n' "$n"
}

# shadow_reservation: sets SHADOW_RES (bytes reserved), SHADOW_SRC (record,
# stale-record, config, unbounded or none), SHADOW_MAX, SHADOW_USED, SHADOW_AT and
# SHADOW_EVENTS. A reading only ever adds a reservation, so a stale or
# unreadable record can never make room look larger than plain df.
shadow_reservation() {
  local f kv max='' used='' at='' cfg=''
  SHADOW_RES=0; SHADOW_SRC=none; SHADOW_MAX=''; SHADOW_USED=''; SHADOW_AT=''; SHADOW_EVENTS=''
  [ -n "$HOST" ] || return 0
  if [ -n "${FM_DISK_ROOM_SHADOW_MAX:-}" ]; then
    cfg=$(to_bytes "$FM_DISK_ROOM_SHADOW_MAX") || { ERR="bad FM_DISK_ROOM_SHADOW_MAX"; return 1; }
  fi
  f=${FM_DISK_ROOM_SHADOW_RECORD:-$HOST/ProgramData/firstmate/shadow-storage.txt}
  if [ -r "$f" ]; then
    kv=$(tr -d '\r' <"$f" 2>/dev/null)
    max=$(printf '%s\n' "$kv" | sed -n 's/^max_bytes=//p' | head -n 1)
    used=$(printf '%s\n' "$kv" | sed -n 's/^used_bytes=//p' | head -n 1)
    at=$(printf '%s\n' "$kv" | sed -n 's/^recorded_epoch=//p' | head -n 1)
    case "$max" in unbounded) SHADOW_SRC=unbounded; max='' ;; ''|*[!0-9]*) max='' ;; esac
    case "$used" in ''|*[!0-9]*) used='' ;; esac
    case "$at" in ''|*[!0-9]*) at='' ;; esac
  fi
  if [ -n "$max" ] && [ -n "$used" ] && [ -n "$at" ] && [ $(( $(now) - at )) -lt "$SHADOW_STALE_SECS" ]; then
    SHADOW_SRC=record; SHADOW_MAX=$max; SHADOW_USED=$used; SHADOW_AT=$at
    SHADOW_RES=$(( max - used )); [ "$SHADOW_RES" -lt 0 ] && SHADOW_RES=0
    return 0
  fi
  # No fresh record: used is unknown, so reserve the whole cap.
  if [ -n "$max" ] && [ -n "$at" ]; then
    SHADOW_SRC=stale-record; SHADOW_MAX=$max; SHADOW_AT=$at
    [ -n "$cfg" ] && [ "$cfg" -gt "$max" ] && SHADOW_MAX=$cfg
  elif [ -n "$cfg" ]; then
    SHADOW_SRC=config; SHADOW_MAX=$cfg
  fi
  [ -n "$SHADOW_MAX" ] && SHADOW_RES=$SHADOW_MAX
  SHADOW_EVENTS=$(shadow_events)
  return 0
}

shadow_line() {
  case "$SHADOW_SRC" in
    record) printf 'shadow storage: %s GiB headroom reserved (cap %s GiB, used %s GiB, recorded %s)\n' \
      "$(gib "$SHADOW_RES")" "$(gib "$SHADOW_MAX")" "$(gib "$SHADOW_USED")" "$(date -u -d "@$SHADOW_AT" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$SHADOW_AT")" ;;
    stale-record) printf 'shadow storage: %s GiB reserved (whole cap; the record from %s is over 7 days old, so used is unknown)\n' \
      "$(gib "$SHADOW_RES")" "$(date -u -d "@$SHADOW_AT" '+%Y-%m-%d' 2>/dev/null || echo "$SHADOW_AT")" ;;
    config) printf 'shadow storage: %s GiB reserved (whole FM_DISK_ROOM_SHADOW_MAX cap; used is unknown without the elevated record)\n' "$(gib "$SHADOW_RES")" ;;
    unbounded) printf 'shadow storage: not reserved (the recorded shadow storage has no cap; set FM_DISK_ROOM_SHADOW_MAX to bound it)\n' ;;
    *) printf 'shadow storage: not reserved (no record from the elevated task, so run or re-run fm-wsl-reclaim.ps1 -Install elevated, and FM_DISK_ROOM_SHADOW_MAX unset)\n' ;;
  esac
}

# shadow_warning -> the cycling warning, or nothing.
shadow_warning() {
  case "$SHADOW_EVENTS" in ''|0) return 0 ;; esac
  printf 'shadow storage cycling: %s volsnap event(s) 25/33/36 in the last 7 days, so restore points are hitting the cap' "$SHADOW_EVENTS"
}

# Reservations ---------------------------------------------------------------

pid_alive() {
  local pid=$1 start=$2 cur
  [ -n "$pid" ] || return 1
  [ -r "/proc/$pid/stat" ] || return 1
  [ -n "$start" ] || return 0
  cur=$(proc_start "$pid") || return 1
  [ "$cur" = "$start" ]
}

proc_start() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }

# live_reservations [EXCLUDE] -> "name bytes" lines; prunes lapsed ones.
live_reservations() {
  local dir exclude=${1:-} f name bytes pid start expires t
  dir="$(state_dir)/reservations"
  [ -d "$dir" ] || return 0
  t=$(now)
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    bytes=$(sed -n 's/^bytes=//p' "$f"); pid=$(sed -n 's/^pid=//p' "$f")
    start=$(sed -n 's/^start=//p' "$f"); expires=$(sed -n 's/^expires=//p' "$f")
    if [ -n "$pid" ]; then
      pid_alive "$pid" "$start" || { rm -f -- "$f"; continue; }
    elif [ -n "$expires" ] && [ "$t" -ge "$expires" ]; then
      rm -f -- "$f"; continue
    fi
    [ "$name" = "$exclude" ] && continue
    case "$bytes" in ''|*[!0-9]*) continue ;; esac
    printf '%s %s\n' "$name" "$bytes"
  done
}

write_reservation() {
  local name=$1 bytes=$2 pid=$3 ttl=$4 dir tmp start=''
  dir="$(state_dir)/reservations"
  mkdir -p "$dir" || die "cannot create $dir"
  [ -n "$pid" ] && start=$(proc_start "$pid")
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || die "cannot write a reservation"
  {
    printf 'bytes=%s\n' "$bytes"
    if [ -n "$pid" ]; then printf 'pid=%s\nstart=%s\n' "$pid" "$start"
    else printf 'expires=%s\n' "$(( $(now) + ttl ))"; fi
  } >"$tmp"
  mv -f -- "$tmp" "$dir/$name"
}

with_lock() {
  local dir
  dir=$(state_dir)
  mkdir -p "$dir" || die "cannot create $dir"
  exec 9>"$dir/.lock"
  flock -w 30 9 || die "state lock busy"
}

# Measurement ----------------------------------------------------------------

# measure [EXCLUDE]: sets globals; returns 1 when a required reading fails.
measure() {
  local host root line bs vhdx result
  ERR=''
  root=${FM_DISK_ROOM_ROOT:-/}
  host=$(host_mount)
  MARGIN=$(to_bytes "${FM_DISK_ROOM_MARGIN:-20G}") || { ERR="bad FM_DISK_ROOM_MARGIN"; return 1; }
  LINUX_FREE=$(df_field "$root" avail); LINUX_USED=$(df_field "$root" used)
  [ -n "$LINUX_FREE" ] && [ -n "$LINUX_USED" ] || { ERR="cannot read Linux free space on $root"; return 1; }
  HOST=''; HOST_FREE=''
  if [ -n "$host" ] && [ -d "$host" ]; then
    HOST=$host
    HOST_FREE=$(df_field "$host" avail)
    [ -n "$HOST_FREE" ] || { ERR="cannot read free space on $host"; return 1; }
  elif [ -n "${FM_DISK_ROOM_HOST:-}" ]; then
    ERR="host drive $host is not mounted"; return 1
  fi
  RESERVED=0; RES_LIST=''
  while read -r line; do
    [ -n "$line" ] || continue
    RESERVED=$(( RESERVED + ${line##* } ))
    RES_LIST="$RES_LIST${RES_LIST:+, }${line% *} $(gib "${line##* }") GiB"
  done < <(live_reservations "${1:-}")
  shadow_reservation || return 1
  ROOM=$(( LINUX_FREE - RESERVED ))
  if [ -n "$HOST_FREE" ] && [ $(( HOST_FREE - SHADOW_RES - RESERVED )) -lt "$ROOM" ]; then
    ROOM=$(( HOST_FREE - SHADOW_RES - RESERVED ))
  fi
  VHDX=''; VHDX_SIZE=''; FRAG=''; SLACK=''; RECLAIM=''
  if [ -n "$HOST" ] && vhdx=$(discover_vhdx); then
    VHDX=$vhdx
    VHDX_SIZE=$(stat -c %s -- "$vhdx" 2>/dev/null) || VHDX_SIZE=''
  fi
  bs=$(stat -f -c %S -- "$root" 2>/dev/null)
  [ -n "$bs" ] && FRAG=$(fragmented_free "$bs") || FRAG=''
  if [ -n "$VHDX_SIZE" ]; then
    SLACK=$(( VHDX_SIZE - LINUX_USED )); [ "$SLACK" -lt 0 ] && SLACK=0
    if [ -n "$FRAG" ]; then RECLAIM=$(( SLACK - FRAG )); [ "$RECLAIM" -lt 0 ] && RECLAIM=0; fi
  fi
  COMPACT=''
  result=${FM_DISK_ROOM_COMPACT_RESULT:-${HOST:+$HOST/ProgramData/firstmate/wsl-compact-last.txt}}
  if [ -n "$result" ] && [ -r "$result" ]; then
    COMPACT=$(tr -d '\r' <"$result" | awk -F= '
      $1 == "finished" { f = $2 } $1 == "mode" { m = $2 } $1 == "reclaimed_bytes" { r = $2 } $1 == "result" { s = $2 }
      END { if (f != "") printf "%s %s %s reclaimed %.1f GiB", f, m, s, r / 1073741824 }')
  fi
  return 0
}

limit_name() { if [ -n "$HOST_FREE" ] && [ $(( HOST_FREE - SHADOW_RES )) -le "$LINUX_FREE" ]; then printf '%s\n' "$HOST"; else printf 'Linux\n'; fi; }

# advice -> the next step when room is low.
advice() {
  local w
  w=$(shadow_warning)
  [ -n "$w" ] && printf '%s; ' "$w"
  if [ -n "$RECLAIM" ] && [ "$RECLAIM" -ge $((5 * GIB)) ]; then
    printf 'a compaction would reclaim about %s GiB (disk-room skill: reclaim now)' "$(gib "$RECLAIM")"
  elif [ -n "$RECLAIM" ]; then
    printf 'compaction would reclaim under 5 GiB; data must be freed or moved'
  elif [ -n "$HOST" ]; then
    printf 'reclaimable by compaction unknown (%s); run fm-disk-room.sh status' \
      "$([ -n "$VHDX_SIZE" ] && echo 'fragmented free space unreadable' || echo 'disk file not found')"
  else
    printf 'data must be freed or moved'
  fi
}

# results_root: sets RR_ACTIVE (ssd, c, or empty when no file), RR_STATE,
# RR_LETTER, RR_FS, RR_FREE and RR_TOTAL from fm-storage.sh's results-root file.
results_root() {
  local f v
  f=${FM_DISK_ROOM_RESULTS_ROOT:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/lattice-storage/results-root}
  RR_ACTIVE='' RR_STATE='' RR_LETTER='' RR_FS='' RR_FREE='' RR_TOTAL=''
  [ -r "$f" ] || return 0
  rr() { sed -n "2,\${s/^$1=//p}" "$f" | head -n 1 | tr -cd 'A-Za-z0-9._ -'; }
  RR_ACTIVE=$(rr active); RR_STATE=$(rr state); RR_LETTER=$(rr ssd_letter); RR_FS=$(rr ssd_fs)
  v=$(rr ssd_free_bytes); case "$v" in ''|*[!0-9]*) ;; *) RR_FREE=$v ;; esac
  v=$(rr ssd_total_bytes); case "$v" in ''|*[!0-9]*) ;; *) RR_TOTAL=$v ;; esac
}

cmd_status() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  measure || die "$ERR"
  results_root
  if [ "$json" = 1 ]; then
    printf '{"margin":%s,"host":"%s","host_free":%s,"linux_free":%s,"linux_used":%s,"reserved":%s,"room":%s,"low":%s,"vhdx":"%s","vhdx_size":%s,"fragmented_free":%s,"slack":%s,"reclaimable":%s,"results_active":"%s","results_state":"%s","ssd_free":%s,"ssd_total":%s,"shadow_reserved":%s,"shadow_source":"%s","shadow_max":%s,"shadow_used":%s,"shadow_events":%s}\n' \
      "$MARGIN" "$HOST" "${HOST_FREE:-null}" "$LINUX_FREE" "$LINUX_USED" "$RESERVED" "$ROOM" \
      "$([ "$ROOM" -lt "$MARGIN" ] && echo true || echo false)" "$VHDX" "${VHDX_SIZE:-null}" \
      "${FRAG:-null}" "${SLACK:-null}" "${RECLAIM:-null}" "$RR_ACTIVE" "$RR_STATE" "${RR_FREE:-null}" "${RR_TOTAL:-null}" \
      "$SHADOW_RES" "$SHADOW_SRC" "${SHADOW_MAX:-null}" "${SHADOW_USED:-null}" "${SHADOW_EVENTS:-null}"
    return 0
  fi
  printf 'real room: %s GiB (limited by %s; margin %s GiB)%s\n' "$(gib "$ROOM")" "$(limit_name)" "$(gib "$MARGIN")" \
    "$([ "$ROOM" -lt "$MARGIN" ] && printf ' - LOW: %s' "$(advice)")"
  [ -n "$HOST_FREE" ] && printf '%s free: %s GiB\n' "$HOST" "$(gib "$HOST_FREE")"
  printf 'Linux free: %s GiB, used %s GiB\n' "$(gib "$LINUX_FREE")" "$(gib "$LINUX_USED")"
  printf 'reserved writes: %s GiB%s\n' "$(gib "$RESERVED")" "${RES_LIST:+ ($RES_LIST)}"
  if [ -n "$HOST" ]; then
    shadow_line
    [ -n "$(shadow_warning)" ] && printf '%s\n' "$(shadow_warning)"
  fi
  if [ -n "$VHDX_SIZE" ]; then
    if [ -n "$RECLAIM" ]; then
      printf 'disk file: %s GiB (%s); slack %s GiB, of which fragmented %s GiB; reclaimable by compaction about %s GiB\n' \
        "$(gib "$VHDX_SIZE")" "$VHDX" "$(gib "$SLACK")" "$(gib "$FRAG")" "$(gib "$RECLAIM")"
    else
      printf 'disk file: %s GiB (%s); slack %s GiB, fragmented unknown; reclaimable by compaction unknown\n' \
        "$(gib "$VHDX_SIZE")" "$VHDX" "$(gib "$SLACK")"
    fi
  elif [ -n "$HOST" ]; then
    printf 'disk file: not found (set FM_DISK_ROOM_VHDX)\n'
  fi
  [ -n "$COMPACT" ] && printf 'last compaction: %s\n' "$COMPACT"
  if [ -n "$RR_LETTER" ] && [ -n "$RR_FREE" ] && [ -n "$RR_TOTAL" ]; then
    printf 'SSD %s: %s GiB free of %s GiB (%s)\n' "$RR_LETTER" "$(gib "$RR_FREE")" "$(gib "$RR_TOTAL")" "${RR_FS:-unknown filesystem}"
  fi
  case "$RR_ACTIVE" in
    ssd) printf 'fetched results root: SSD %s:\n' "$RR_LETTER" ;;
    c) printf 'fetched results root: C: fallback (SSD %s)\n' "$RR_STATE" ;;
  esac
  return 0
}

# admit EXPECT EXCLUDE -> 0 ok, 1 low, 2 unreadable; sets LINE.
admit() {
  local expect=$1 after
  if ! measure "$2"; then LINE="cannot measure disk room: $ERR"; return 2; fi
  after=$(( ROOM - expect ))
  if [ "$after" -ge "$MARGIN" ]; then
    LINE="ok: $(gib "$after") GiB left after a $(gib "$expect") GiB write (margin $(gib "$MARGIN") GiB)"
    return 0
  fi
  LINE="low: only $(gib "$after") GiB would be left on $(limit_name) after a $(gib "$expect") GiB write (margin $(gib "$MARGIN") GiB); $(advice)"
  return 1
}

cmd_check() {
  local expect='' exclude='' rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect-write) [ "$#" -ge 2 ] || die "--expect-write needs a size"; expect=$(to_bytes "$2") || die "bad size: $2"; shift 2 ;;
      --exclude) { [ "$#" -ge 2 ] && valid_name "$2"; } || die "--exclude needs a name"; exclude=$2; shift 2 ;;
      *) die "unknown check argument: $1" ;;
    esac
  done
  [ -n "$expect" ] || die "check needs --expect-write SIZE"
  admit "$expect" "$exclude"; rc=$?
  printf '%s\n' "$LINE"
  return "$rc"
}

cmd_run() {
  local name='' expect=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) { [ "$#" -ge 2 ] && valid_name "$2"; } || die "--name needs a name"; name=$2; shift 2 ;;
      --expect-write) [ "$#" -ge 2 ] || die "--expect-write needs a size"; expect=$(to_bytes "$2") || die "bad size: $2"; shift 2 ;;
      --) shift; break ;;
      *) die "unknown run argument: $1" ;;
    esac
  done
  [ -n "$name" ] && [ -n "$expect" ] && [ "$#" -gt 0 ] || die "run needs --name, --expect-write and -- COMMAND"
  with_lock
  if ! admit "$expect" "$name"; then
    printf 'fm-disk-room: refused %s: %s\n' "$name" "$LINE" >&2
    exit 75
  fi
  write_reservation "$name" "$expect" "$$" 0
  exec 9>&-
  exec "$@"
}

cmd_reserve() {
  local name=${1:-} size=${2:-} bytes pid='' ttl=$DEFAULT_TTL
  valid_name "$name" || die "reserve needs a NAME of letters, digits, . _ -"
  bytes=$(to_bytes "$size") || die "bad size: $size"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid) [ "$#" -ge 2 ] && [ -r "/proc/${2}/stat" ] || die "--pid needs a live pid"; pid=$2; shift 2 ;;
      --ttl) case "${2:-}" in ''|*[!0-9]*) die "--ttl needs seconds" ;; esac; ttl=$2; shift 2 ;;
      *) die "unknown reserve argument: $1" ;;
    esac
  done
  with_lock
  write_reservation "$name" "$bytes" "$pid" "$ttl"
  printf 'reserved %s: %s GiB\n' "$name" "$(gib "$bytes")"
}

cmd_release() {
  valid_name "${1:-}" || die "release needs a NAME"
  rm -f -- "$(state_dir)/reservations/$1"
}

cmd_watch_line() {
  local rec t last_kind last_t last_room msg kind
  rec="$(state_dir)/alert"
  t=$(now)
  mkdir -p "$(state_dir)" 2>/dev/null || return 0
  if ! measure; then
    kind=error; msg="disk room: cannot measure ($ERR)"; ROOM=0
  elif [ "$ROOM" -lt "$MARGIN" ]; then
    kind=low
    msg="disk room low: $(gib "$ROOM") GiB real room on $(limit_name) after $(gib "$RESERVED") GiB of declared writes and $(gib "$SHADOW_RES") GiB of shadow storage headroom (margin $(gib "$MARGIN") GiB); $(advice)"
  else
    rm -f -- "$rec"
    return 0
  fi
  if [ -r "$rec" ]; then
    read -r last_kind last_t last_room <"$rec" || true
    if [ "${last_kind:-}" = "$kind" ] && [ $(( t - ${last_t:-0} )) -lt "$REALERT_SECS" ] \
      && { [ "$kind" = error ] || [ "$ROOM" -gt $(( ${last_room:-0} - REALERT_DROP )) ]; }; then
      return 0
    fi
  fi
  printf '%s %s %s\n' "$kind" "$t" "$ROOM" >"$rec" 2>/dev/null || true
  printf '%s\n' "$msg"
}

# The shim embeds the resolved home and every FM_DISK_ROOM_* setting in force
# at arm time, because the watcher runs it with its own environment.
cmd_arm() {
  local home state shim tmp v name
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  state=${FM_STATE_OVERRIDE:-$home/state}
  shim="$state/disk-room.check.sh"
  [ -d "$state" ] && [ ! -L "$state" ] || die "state directory $state is unavailable"
  [ ! -L "$shim" ] || die "refusing a symlinked $shim"
  tmp=$(umask 077; mktemp "$state/.fm-disk-room-check.XXXXXX") || die "cannot write in $state"
  {
    printf '%s\n' '#!/usr/bin/env bash' '# Auto-generated by fm-disk-room.sh arm - real disk room watcher check.'
    for v in MARGIN HOST ROOT VHDX MB_GROUPS COMPACT_RESULT SHADOW_RECORD SHADOW_MAX WEVTUTIL STATE; do
      name=FM_DISK_ROOM_$v
      [ -z "${!name+x}" ] || printf 'export %s=%q\n' "$name" "${!name}"
    done
    printf 'exec %q watch-line\n' "$SCRIPT_DIR/fm-disk-room.sh"
  } >"$tmp"
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    die "cannot write $shim"
  fi
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" disk-room >/dev/null; then
    rm -f -- "$shim"
    die "cannot register $shim"
  fi
  printf 'armed: %s\n' "$shim"
}

cmd_disarm() {
  local home
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-unregister.sh" disk-room
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  check) shift; cmd_check "$@" ;;
  run) shift; cmd_run "$@" ;;
  reserve) shift; cmd_reserve "$@" ;;
  release) shift; cmd_release "$@" ;;
  watch-line) shift; cmd_watch_line ;;
  arm) cmd_arm ;;
  disarm) cmd_disarm ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
