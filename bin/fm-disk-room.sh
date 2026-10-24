#!/usr/bin/env bash
# fm-disk-room.sh - real free room on a WSL laptop, and the admission check that
# keeps big writers from running it out.
#
# On WSL the Linux root lives in a non-sparse ext4.vhdx on the Windows drive, so
# `df /` shows the virtual disk's own (huge) size and space Linux frees stays
# reserved on C: until the file is compacted. Real room is therefore the Windows
# drive's free space, taken together with Linux free space, minus the writes
# that running jobs have declared. Slack inside the disk file is NOT room (ext4
# happily grows the file while slack exists). What the next compaction would
# reclaim is reported separately, read from the disk file's own block table
# (bin/fm-vhdx-bat.py), never guessed from Linux's view. The Windows
# restore-point shadow storage's headroom (its cap minus what it already
# allocated) is reserved too, because copy-on-write after each restore point
# fills it from host free space while Linux df and the disk file stay flat; so
# is the WSL swap file's remaining growth up to its configured size.
# docs/disk-room.md owns the contract and the one-time Windows install
# (bin/fm-wsl-reclaim.ps1).
#
# Usage:
#   fm-disk-room.sh status [--json]
#       Print host free, Linux free, reservations, the shadow storage
#       reservation and any cycling warning, the swap file's growth
#       reservation, real room, the disk file's slack, what compaction
#       can reclaim and what a trim would add, the last compaction result, and
#       the external SSD's room with the active fetched-results root (read
#       from the results-root file bin/fm-storage.sh publishes).
#   fm-disk-room.sh check [--expect-write SIZE] [--kind KIND] [--exclude NAME]
#       Admission: exit 0 when real room minus SIZE stays at or above the
#       margin, 1 when it would fall below, 2 when a reading fails or on misuse.
#       Prints one line either way. --exclude drops the caller's own reservation.
#   fm-disk-room.sh run --name NAME [--expect-write SIZE] [--kind KIND]
#                       -- COMMAND [ARG...]
#       check, then hold a reservation for the command's lifetime. Without
#       --kind, exec it unchanged (v1). With --kind, wait for it and record
#       kernel-accounted storage write bytes, including failed commands.
#       Refused (low room or unreadable) exits 75 with one line on stderr.
#   fm-disk-room.sh write-history KIND
#       Print one JSON object: kind (string), samples and high_bytes (integers).
#       Exit 0 (missing history: both integers 0), 2 on corruption or misuse.
#   fm-disk-room.sh reserve NAME SIZE [--pid PID] [--ttl SECONDS]
#       Declare an in-flight write. With --pid it lapses when that process
#       exits; otherwise after --ttl (default 43200 s).
#   fm-disk-room.sh reserve-bulk NAME --task TASK --download SIZE
#                               --expanded SIZE --packaging SIZE
#                               [--pid PID] [--ttl SECONDS]
#       Verify mandatory D: storage via fm-storage.sh, then atomically admit
#       download + expanded allocation + packaging duplicate on its actual
#       filesystem. Print only the root; exit 75 with one stderr reason when
#       unavailable or low, 2 on misuse. Refuse an already-live NAME on D:.
#   fm-disk-room.sh release-bulk NAME
#       Release this name from the D: pools without needing the drive present.
#   fm-disk-room.sh release NAME
#   fm-disk-room.sh watch-line
#       For a firstmate custom watcher check: print one line only when real
#       room is under the margin (repeated only after a further 5 GiB drop or
#       6 hours), or when a reading fails (at most every 6 hours); else nothing.
#       Also prints one "storage alert:" line when a growth or runway alert
#       starts or clears (see growth); a standing alert is not repeated.
#   fm-disk-room.sh growth
#       Read-only report: Linux used and C: used change over the last day and
#       week from the data-gate sampler, C: free, the disk file's length and
#       D: free (with their daily and weekly change from the watcher's hourly
#       history), D: and Linux/C: reservations, and each alert's state.
#       Never runs, schedules or triggers a compaction.
#   fm-disk-room.sh arm | disarm
#       Write FM_HOME's state/disk-room.check.sh shim (running watch-line with
#       this script's environment settings) and bind it with
#       fm-check-register.sh, or retire it with fm-check-unregister.sh.
#   fm-disk-room.sh --interface [VERSION]
#       Print the consumer interface this script serves, one line:
#       fm-disk-room-interface/v2. Optional VERSION (v1 or v2) queries an
#       older supported interface explicitly; an unsupported version exits 1.
#   fm-disk-room.sh --self-test VERSION
#       Before trusting a new copy, a consumer runs this with the version it
#       pins (v1 or v2). Exit 0 with one line when this script serves VERSION and a
#       hermetic probe of it passes (temp state, Linux-only, no Windows
#       readings, no reservation outside the temp state); 1 with one line
#       naming what failed or the version served; 2 on misuse.
#
# Interface v1 - what a consumer may rely on; docs/disk-room.md "Consumer
# interface" owns the versioning rule. A change to any command, exit code, or
# listed field's name, unit or meaning takes a new version; additions that v1
# consumers ignore preserve v1 support. Wording not listed here (status and growth text,
# the rest of a line after its listed start) is for people and may change.
#   status --json  exit 0 with one JSON object on one line; 2 when a reading
#       fails. Fields, every size in bytes:
#         integers: margin, linux_free, linux_used, reserved, shadow_reserved,
#           swap_reserved, room (may be negative)
#         integer or null (unknown): host_free, vhdx_size, fragmented_free,
#           fs_overhead, slack, reclaimable, ssd_free, ssd_total, shadow_max,
#           shadow_used, shadow_allocated, shadow_events (an event count),
#           swap_size, swap_file_size, trim_reclaimable; reclaimable is the
#           disk file block table's figure, null when the block table cannot
#           be read; trim_reclaimable is what a trim would add on top of it
#           (ext4's wholly free 1 MiB blocks the table still holds), null
#           when unknown, and never part of reclaimable
#         boolean: low (room is under margin)
#         strings: host (Windows drive mount, "" when Linux-only), vhdx (disk
#           file path or ""), results_active (ssd, c or ""), results_state,
#           shadow_source (live, record, stale-record, config, unbounded or
#           none), shadow_reading (live, record or none), swap_source
#           (wslconfig, default, off, other-drive, disabled, unknown or "")
#   status   exit 0 with text for people; 2 when a reading fails.
#   check    exit 0 with one stdout line starting "ok: ", 1 with "low: ", 2
#       with "cannot measure disk room: " when a reading fails; 2 with a
#       stderr line on misuse.
#   run      the command's own exit status once admitted (it is exec'd); 75
#       with one stderr line starting "fm-disk-room: refused NAME: " when low
#       or unreadable, the command not started; 2 on misuse.
#   reserve  exit 0 with one line starting "reserved NAME: "; 2 on misuse.
#   release  exit 0, also for a name with no reservation; 2 on misuse.
#   reserve-bulk  exit 0 with stdout exactly the admitted root; 75 with one
#       stderr line starting "fm-disk-room: wait: " or "fm-storage: wait: "
#       followed by a reason token; 2 on misuse.
#   release-bulk  exit 0; 2 on misuse.
#   watch-line  exit 0; stdout empty, or one line made of a part starting
#       "disk room low: " or "disk room: cannot measure" and a part starting
#       "storage alert", joined by " | " when both speak.
#   growth   exit 0 with text for people; 2 when a reading fails or on misuse.
#   arm      exit 0 with one line starting "armed: "; 2 on failure.
#   disarm   fm-check-unregister.sh's exit status.
#
# Interface v2 adds --kind KIND to check/run and write-history KIND, while
# retaining every v1 command and --self-test v1. KIND has NAME's syntax and
# identifies comparable jobs, not individual run ids. Without --kind, v1
# still requires --expect-write and does not read or write job history.
# With --kind, an omitted declaration uses the recorded high; a first run
# needs an explicit declaration. Any declaration below the high is refused
# (check: 1 with "low: "; run: 75). Unreadable/corrupt history or no history
# without a declaration is a failed reading (check: 2; run: 75).
# A typed run refuses an already-live reservation NAME; use unique run names.
# The margin and normal disk reading are still checked on every admission.
#
# Measurement: --kind run snapshots /proc/$$/io write_bytes immediately before
# and after waiting for COMMAND. This counts storage bytes charged by Linux
# to this wrapper and its waited-for descendants, not logical file length or
# df growth; overwrites and writes later deleted still count. It excludes
# un-waited/background descendants, other processes/services doing delegated
# work, non-storage I/O, and writes not accounted by that filesystem. It is
# not a peak-space measurement or a promise about future jobs; use a rounded-up
# declaration for known larger inputs. Abrupt wrapper death leaves no sample.
# Unsupported/unreadable counters refuse before starting, not a zero sample.
# A measurement/history failure after COMMAND prints a stderr error and exits
# 74 if COMMAND succeeded, otherwise preserves COMMAND's nonzero status.
# Job samples are append-only under STATE/write-history/KIND, one line:
#   fm-disk-write/v1 EPOCH WRITE_BYTES COMMAND_STATUS
# EPOCH is UTC Unix seconds; sizes are nonnegative integers of <=18 digits.
# The shared state lock serializes admissions and sample appends, but is never
# held across COMMAND. The command caller consumes refusals and recording
# errors through the existing stdout/stderr path and reports holds to its owner.
#
# SIZE is bytes or a number with K, M, G or T (binary: G = GiB, matching what
# Windows Explorer shows as GB).
#
# Environment (all optional):
#   FM_DISK_ROOM_MARGIN   margin kept after the expected write; when unset or
#                         empty, the first line of <home>/config/disk-room-margin
#                         (home: FM_HOME, else this script's checkout; SIZE),
#                         else 20G; an unparsable value or file is a failed reading
#   FM_DISK_ROOM_BULK_MARGIN  D: margin after all peak reservations (default 50G)
#   FM_DISK_ROOM_HOST     Windows drive mount (default /mnt/c; absent => Linux-only)
#   FM_DISK_ROOM_ROOT     Linux path whose filesystem is measured (default /)
#   FM_DISK_ROOM_VHDX     the distro's ext4.vhdx as a Linux path (default: the
#                         single match of /mnt/c/Users/*/AppData/Local/wsl/*/ext4.vhdx
#                         or .../Packages/*/LocalState/ext4.vhdx)
#   FM_DISK_ROOM_MB_GROUPS  ext4 mb_groups file (default /proc/fs/ext4/<dev>/mb_groups)
#   FM_DISK_ROOM_DEV_SIZE  byte size of the root's block device (default: lsblk
#                         on the findmnt source); with df's total it gives the
#                         ext4 metadata size. Not a number: unreadable.
#   FM_DISK_ROOM_COMPACT_RESULT  last-result file written by fm-wsl-reclaim.ps1
#                         (default <host>/ProgramData/firstmate/wsl-compact-last.txt)
#   FM_DISK_ROOM_POWERSHELL  powershell command for the live, non-admin
#                         Win32_ShadowStorage reading of the system drive (cap
#                         minus allocated is reserved), cached for 5 minutes,
#                         failures included, under a 20 second timeout (default
#                         powershell.exe on PATH, else the drive's
#                         Windows/System32/WindowsPowerShell/v1.0/powershell.exe;
#                         empty disables the live reading)
#   FM_DISK_ROOM_SHADOW_RECORD  shadow storage max/used written by the elevated
#                         fm-wsl-reclaim.ps1 task; when the live reading fails the
#                         newer of it and the last good live reading is used
#                         (default <host>/ProgramData/firstmate/shadow-storage.txt).
#                         A record older than 7 days keeps only its max: used is
#                         then unknown.
#   FM_DISK_ROOM_SHADOW_MAX  shadow storage cap (SIZE) used when neither the live
#                         reading nor a fresh record gives one, e.g. 10G. With used
#                         unknown the whole cap is reserved, the conservative
#                         choice. Unset and no record: nothing is reserved.
#   FM_DISK_ROOM_WSLCONFIG  the Windows .wslconfig whose [wsl2] swap= (WSL's
#                         default when unset: a quarter of memory= or of Linux
#                         MemTotal, rounded up to a GiB; swap=0: none) minus the
#                         swap file's length (swapFile=, else the newest
#                         %TEMP%\<guid>\swap.vhdx, cached for the VM boot)
#                         is reserved on the
#                         drive as the swap file's remaining growth (default
#                         <drive>/Users/<user>/.wslconfig beside the disk file;
#                         empty disables the reservation)
#   FM_DISK_ROOM_MEMINFO  meminfo read for that default (default /proc/meminfo)
#   FM_DISK_ROOM_BOOT_ID  boot id keying that swap file cache
#                         (default /proc/sys/kernel/random/boot_id)
#   FM_DISK_ROOM_WEVTUTIL  wevtutil command used on every reading to count
#                         volsnap System events 25/33/36 of the last 7 days
#                         (cached for an hour) for the cycling warning
#                         (default wevtutil.exe on PATH, else the drive's
#                         Windows/System32/wevtutil.exe; empty disables the count)
#   FM_DISK_ROOM_RESULTS_ROOT  results-root file from bin/fm-storage.sh
#                         (default ${XDG_CONFIG_HOME:-~/.config}/lattice-storage/results-root)
#   FM_DISK_ROOM_SAMPLES  data-gate sampler log read for Linux and C: growth
#                         (default ~/.local/state/lattice-data-gate/samples.jsonl;
#                         only its last 3500 lines are read)
#   FM_DISK_ROOM_GROWTH_MAX  alert when Linux used grew faster than this per day
#                         over the last week (SIZE, default 0.5G; off disables)
#   FM_DISK_ROOM_C_FREE_MIN  alert when the Windows drive's actual free space is
#                         under this (SIZE, default 100G; off disables)
#   FM_DISK_ROOM_D_FREE_MIN  alert when D: free space minus live D: reservations
#                         is under this (SIZE, default 50G; off disables)
#   FM_DISK_ROOM_STATE    reservations, alert records and the hourly history
#                         (default ${XDG_STATE_HOME:-~/.local/state}/fm-disk-room)
#   FM_DISK_ROOM_NOW      epoch override for tests
set -u

# Pinned consumers run these bytes as `bash -c TEXT PATH ARG...`, where
# BASH_SOURCE is empty and PATH (the file they hashed) is $0; SELF_TEXT then
# keeps TEXT so the self-test probes the same bytes.
SELF="${BASH_SOURCE[0]:-$0}"
SELF_TEXT=''
[ -n "${BASH_SOURCE[0]:-}" ] || SELF_TEXT=${BASH_EXECUTION_STRING:-}
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
GIB=1073741824
REALERT_DROP=$((5 * GIB))
REALERT_SECS=21600
DEFAULT_TTL=43200
SHADOW_STALE_SECS=604800
SHADOW_EVENTS_CACHE_SECS=3600
SHADOW_LIVE_CACHE_SECS=300
BAT_CACHE_SECS=300
# sha256 of bin/fm-vhdx-bat.py; only a reader with exactly these bytes runs.
VHDX_BAT_SHA256=bc4917f5d8a697c8916671307d6d909219fe16fd45574bb89718ecd92fe69c03
INTERFACE=v2
INTERFACE_V1_FIELDS='margin:int linux_free:int linux_used:int reserved:int shadow_reserved:int swap_reserved:int room:int
  host_free:opt vhdx_size:opt fragmented_free:opt fs_overhead:opt slack:opt reclaimable:opt
  ssd_free:opt ssd_total:opt shadow_max:opt shadow_used:opt shadow_allocated:opt shadow_events:opt
  swap_size:opt swap_file_size:opt trim_reclaimable:opt
  low:bool host:str vhdx:str results_active:str results_state:str shadow_source:str shadow_reading:str swap_source:str'

die() { printf 'fm-disk-room: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }

# to_bytes SIZE -> bytes on stdout, or fail; a result that is not a plain
# integer of at most 18 digits fails so bash arithmetic on it can never wrap.
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
  awk -v n="$n" -v m="$mult" 'BEGIN { b = sprintf("%.0f", n * m); if (b !~ /^[0-9]+$/ || length(b) > 18) exit 1; print b }'
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

# dev_size -> bytes of the block device under the measured root.
dev_size() {
  local src size
  if [ -n "${FM_DISK_ROOM_DEV_SIZE:-}" ]; then
    size=$FM_DISK_ROOM_DEV_SIZE
  else
    src=$(findmnt -no SOURCE --target "${FM_DISK_ROOM_ROOT:-/}" 2>/dev/null | head -1)
    [ -n "$src" ] && [ -b "$src" ] || return 1
    size=$(lsblk -bdno SIZE -- "$src" 2>/dev/null | tr -d ' ')
  fi
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$size"
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

# bat_reclaim FILE SIZE [FS_BLOCK_SIZE] -> "RECLAIM TRIM": bytes a compaction
# of FILE can give back, from its block table (bin/fm-vhdx-bat.py), and bytes
# a trim would add (ext4 free 1 MiB blocks the table still holds, joined with
# mb_groups; "-" when unknown). Fails when the block table cannot be read.
# Cached for 5 minutes per file and size, failures included, because it reads
# megabytes through the Windows drive. The reader runs from the bytes that
# were hashed, and only when they match VHDX_BAT_SHA256, so a pin on this
# script covers it.
bat_reclaim() {
  local cache t when='' size='' r='' trim='' path='' out text mb=()
  cache="$(state_dir)/vhdx-bat"
  t=$(now)
  [ -r "$cache" ] && read -r when size r trim path <"$cache"
  case "$trim" in -) ;; ''|*[!0-9]*|???????????????????*) when='' ;; esac
  case "$when" in
    ''|*[!0-9]*) when='' ;;
    *) { [ "$path" = "$1" ] && [ "$size" = "$2" ] && [ "$t" -ge "$when" ] && [ $(( t - when )) -lt "$BAT_CACHE_SECS" ]; } || when='' ;;
  esac
  if [ -z "$when" ]; then
    r=-; trim=-
    if [ -n "${3:-}" ] && out=$(mb_groups_path) && [ -r "$out" ]; then mb=("$out" "$3"); fi
    text=$(cat -- "$SCRIPT_DIR/fm-vhdx-bat.py" 2>/dev/null && printf x) && text=${text%x}
    # A failed run with mb_groups is retried without it, so the informational
    # trim figure can never cost the reclaimable one.
    if [ -n "$text" ] && [ "$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)" = "$VHDX_BAT_SHA256" ] &&
      { out=$(timeout 60 python3 -I -c "$text" "$1" "${mb[@]}" 2>/dev/null) ||
        { [ "${#mb[@]}" -gt 0 ] && out=$(timeout 60 python3 -I -c "$text" "$1" 2>/dev/null); }; }; then
      r=$(printf '%s\n' "$out" | sed -n 's/^reclaimable=\([0-9]*\) .*/\1/p')
      trim=$(printf '%s\n' "$out" | sed -n 's/.* trim_more=\([0-9]*\)$/\1/p')
    fi
    case "$r" in ''|*[!0-9]*|???????????????????*) r=- ;; esac
    case "$trim" in ''|*[!0-9]*|???????????????????*) trim=- ;; esac
    mkdir -p "$(state_dir)" 2>/dev/null && printf '%s %s %s %s %s\n' "$t" "$2" "$r" "$trim" "$1" >"$cache" 2>/dev/null
  fi
  case "$r" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$r" "$trim"
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

# powershell_cmd -> the powershell command to run, or fails when there is none.
powershell_cmd() {
  if [ -n "${FM_DISK_ROOM_POWERSHELL+set}" ]; then
    [ -n "$FM_DISK_ROOM_POWERSHELL" ] && command -v -- "$FM_DISK_ROOM_POWERSHELL" 2>/dev/null
    return
  fi
  command -v powershell.exe 2>/dev/null && return 0
  [ -x "$HOST/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ] && printf '%s\n' "$HOST/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
}

# shadow_live: sets LIVE_MAX (bytes or unbounded), LIVE_ALLOC, LIVE_USED and
# LIVE_AT from a non-admin Win32_ShadowStorage reading of the system drive's
# diff area, or fails. Cached for 5 minutes, failures included, because it
# starts a Windows process that hangs when Windows is short of memory. Each
# good reading is also kept in shadow-live-good, which a failure never
# overwrites, so the fallback can use the last good reading.
shadow_live() {
  local cache t when='' line='' out cmd m a u
  LIVE_MAX=''; LIVE_ALLOC=''; LIVE_USED=''; LIVE_AT=''
  cmd=$(powershell_cmd) && [ -n "$cmd" ] || return 1
  cache="$(state_dir)/shadow-live"
  t=$(now)
  [ -r "$cache" ] && read -r when line <"$cache"
  case "$when" in
    ''|*[!0-9]*) when='' ;;
    *) { [ "$t" -ge "$when" ] && [ $(( t - when )) -lt "$SHADOW_LIVE_CACHE_SECS" ]; } || when='' ;;
  esac
  if [ -z "$when" ]; then
    when=$t
    # shellcheck disable=SC2016
    out=$(timeout 20 "$cmd" -NoProfile -NonInteractive -Command '$ErrorActionPreference="Stop"; $v = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='\''$env:SystemDrive'\''"; $n = 0; $m = [decimal]0; $a = [decimal]0; $u = [decimal]0; $ub = $false; foreach ($s in @(Get-CimInstance -ClassName Win32_ShadowStorage | Where-Object { $_.DiffVolume.DeviceID -eq $v.DeviceID })) { $n++; if ([decimal]$s.MaxSpace -ge [decimal]9223372036854775808) { $ub = $true } else { $m += [decimal]$s.MaxSpace }; $a += [decimal]$s.AllocatedSpace; $u += [decimal]$s.UsedSpace }; if ($n -gt 0) { "SHADOW|{0}|{1}|{2}" -f $(if ($ub) { "unbounded" } else { $m }), $a, $u }; "END"' 2>/dev/null \
      | tr -d '\r')
    line=-
    if printf '%s\n' "$out" | grep -qx END; then
      line=$(printf '%s\n' "$out" | sed -n 's/^SHADOW|//p' | head -n 1 | tr '|' ' ')
    fi
  fi
  read -r m a u <<<"$line"
  # Past 18 digits a value could wrap signed 64-bit arithmetic, so it is unreadable.
  case "${m:-}" in unbounded) ;; ''|*[!0-9]*|???????????????????*) m='' ;; esac
  case "${a:-}" in ''|*[!0-9]*|???????????????????*) a='' ;; esac
  case "${u:-}" in ''|*[!0-9]*|???????????????????*) u='' ;; esac
  if [ -z "$m" ] || [ -z "$a" ] || [ -z "$u" ]; then
    mkdir -p "$(state_dir)" 2>/dev/null && printf '%s -\n' "$when" >"$cache" 2>/dev/null
    return 1
  fi
  mkdir -p "$(state_dir)" 2>/dev/null && printf '%s %s %s %s\n' "$when" "$m" "$a" "$u" >"$cache" 2>/dev/null
  printf '%s %s %s %s\n' "$when" "$m" "$a" "$u" >"$cache-good" 2>/dev/null
  LIVE_MAX=$m; LIVE_ALLOC=$a; LIVE_USED=$u; LIVE_AT=$when
}

# shadow_last_live: sets LIVE_MAX, LIVE_ALLOC, LIVE_USED and LIVE_AT from the
# last good live reading, or fails when there is none.
shadow_last_live() {
  local when='' m='' a='' u=''
  LIVE_MAX=''; LIVE_ALLOC=''; LIVE_USED=''; LIVE_AT=''
  [ -r "$(state_dir)/shadow-live-good" ] || return 1
  read -r when m a u <"$(state_dir)/shadow-live-good" || [ -n "$when" ] || return 1
  case "$when" in ''|*[!0-9]*|???????????????????*) return 1 ;; esac
  case "$m" in unbounded) ;; ''|*[!0-9]*|???????????????????*) return 1 ;; esac
  case "$a" in ''|*[!0-9]*|???????????????????*) return 1 ;; esac
  case "$u" in ''|*[!0-9]*|???????????????????*) return 1 ;; esac
  LIVE_MAX=$m; LIVE_ALLOC=$a; LIVE_USED=$u; LIVE_AT=$when
}

# shadow_reservation: sets SHADOW_RES (bytes reserved), SHADOW_SRC (live,
# last-live, record, stale-last-live, stale-record, config, unbounded or none),
# SHADOW_READING (live, last-live, record or none: where the numbers came from),
# SHADOW_MAX, SHADOW_ALLOC, SHADOW_USED, SHADOW_AT and SHADOW_EVENTS. The live
# reading reserves the cap minus what is allocated; when it fails the newer of
# the last good live reading and the elevated record is the fallback. A reading
# only ever adds a reservation, so a stale or unreadable one can never make
# room look larger than plain df.
shadow_reservation() {
  local f kv max='' used='' at='' cfg='' rec_unbounded=''
  SHADOW_RES=0; SHADOW_SRC=none; SHADOW_READING=none; SHADOW_MAX=''; SHADOW_ALLOC=''; SHADOW_USED=''; SHADOW_AT=''; SHADOW_EVENTS=''
  [ -n "$HOST" ] || return 0
  if [ -n "${FM_DISK_ROOM_SHADOW_MAX:-}" ]; then
    cfg=$(to_bytes "$FM_DISK_ROOM_SHADOW_MAX") || { ERR="bad FM_DISK_ROOM_SHADOW_MAX"; return 1; }
  fi
  SHADOW_EVENTS=$(shadow_events)
  if shadow_live; then
    shadow_from_live live "$cfg"
    return 0
  fi
  f=${FM_DISK_ROOM_SHADOW_RECORD:-$HOST/ProgramData/firstmate/shadow-storage.txt}
  if [ -r "$f" ]; then
    kv=$(tr -d '\r' <"$f" 2>/dev/null)
    max=$(printf '%s\n' "$kv" | sed -n 's/^max_bytes=//p' | head -n 1)
    used=$(printf '%s\n' "$kv" | sed -n 's/^used_bytes=//p' | head -n 1)
    at=$(printf '%s\n' "$kv" | sed -n 's/^recorded_epoch=//p' | head -n 1)
    # Past 18 digits a value could wrap signed 64-bit arithmetic, so it is unreadable.
    case "$max" in unbounded) rec_unbounded=1; max='' ;; ''|*[!0-9]*|???????????????????*) max='' ;; esac
    case "$used" in ''|*[!0-9]*|???????????????????*) used='' ;; esac
    case "$at" in ''|*[!0-9]*|???????????????????*) at='' ;; esac
  fi
  # A last good live reading newer than the record wins: the record can be
  # days old while the live cap was read minutes before this failure.
  if shadow_last_live && { [ -z "$at" ] || [ "$LIVE_AT" -gt "$at" ]; }; then
    shadow_from_live last-live "$cfg"
    return 0
  fi
  [ -n "$rec_unbounded" ] && { SHADOW_SRC=unbounded; SHADOW_READING=record; }
  if [ -n "$max" ] && [ -n "$used" ] && [ -n "$at" ] && [ $(( $(now) - at )) -lt "$SHADOW_STALE_SECS" ]; then
    SHADOW_SRC=record; SHADOW_READING=record; SHADOW_MAX=$max; SHADOW_USED=$used; SHADOW_AT=$at
    SHADOW_RES=$(( max - used )); [ "$SHADOW_RES" -lt 0 ] && SHADOW_RES=0
    return 0
  fi
  # No fresh record: used is unknown, so reserve the whole cap.
  if [ -n "$max" ] && [ -n "$at" ]; then
    SHADOW_SRC=stale-record; SHADOW_READING=record; SHADOW_MAX=$max; SHADOW_AT=$at
    [ -n "$cfg" ] && [ "$cfg" -gt "$max" ] && SHADOW_MAX=$cfg
  elif [ -n "$cfg" ]; then
    SHADOW_SRC=config; SHADOW_MAX=$cfg
  fi
  [ -n "$SHADOW_MAX" ] && SHADOW_RES=$SHADOW_MAX
  return 0
}

# shadow_from_live READING CFG: the reservation from LIVE_* (a reading taken
# now, or the last good one). A last good reading past 7 days keeps only its
# cap, like a stale record.
shadow_from_live() {
  local cfg=$2
  SHADOW_READING=$1; SHADOW_ALLOC=$LIVE_ALLOC; SHADOW_USED=$LIVE_USED; SHADOW_AT=$LIVE_AT
  if [ "$LIVE_MAX" = unbounded ]; then
    SHADOW_SRC=unbounded
    # With no cap the configured one bounds it; reserve it whole, as without a record.
    [ -n "$cfg" ] && { SHADOW_SRC=config; SHADOW_MAX=$cfg; SHADOW_RES=$cfg; }
    return 0
  fi
  SHADOW_SRC=$1; SHADOW_MAX=$LIVE_MAX
  if [ "$1" = last-live ] && [ $(( $(now) - LIVE_AT )) -ge "$SHADOW_STALE_SECS" ]; then
    SHADOW_SRC=stale-last-live; SHADOW_ALLOC=''; SHADOW_USED=''
    [ -n "$cfg" ] && [ "$cfg" -gt "$LIVE_MAX" ] && SHADOW_MAX=$cfg
    SHADOW_RES=$SHADOW_MAX
    return 0
  fi
  SHADOW_RES=$(( LIVE_MAX - LIVE_ALLOC )); [ "$SHADOW_RES" -lt 0 ] && SHADOW_RES=0
  return 0
}

# shadow_at FORMAT -> SHADOW_AT in UTC.
shadow_at() { date -u -d "@$SHADOW_AT" "$1" 2>/dev/null || echo "$SHADOW_AT"; }

# shadow_line ends each wording with the source of its numbers: live, the last
# live reading (with its time), record or none.
shadow_line() {
  local last
  last="source last live reading at $(shadow_at '+%Y-%m-%d %H:%M UTC'), no live reading now"
  case "$SHADOW_SRC" in
    live) printf 'shadow storage: %s GiB headroom reserved (cap %s GiB, allocated %s GiB, used %s GiB, read %s; source live)\n' \
      "$(gib "$SHADOW_RES")" "$(gib "$SHADOW_MAX")" "$(gib "$SHADOW_ALLOC")" "$(gib "$SHADOW_USED")" "$(shadow_at '+%Y-%m-%d %H:%M UTC')" ;;
    last-live) printf 'shadow storage: %s GiB headroom reserved (cap %s GiB, allocated %s GiB, used %s GiB; %s)\n' \
      "$(gib "$SHADOW_RES")" "$(gib "$SHADOW_MAX")" "$(gib "$SHADOW_ALLOC")" "$(gib "$SHADOW_USED")" "$last" ;;
    record) printf 'shadow storage: %s GiB headroom reserved (cap %s GiB, used %s GiB, recorded %s; source record, no live reading)\n' \
      "$(gib "$SHADOW_RES")" "$(gib "$SHADOW_MAX")" "$(gib "$SHADOW_USED")" "$(shadow_at '+%Y-%m-%d %H:%M UTC')" ;;
    stale-last-live) printf 'shadow storage: %s GiB reserved (whole cap; the last live reading is over 7 days old, so allocated is unknown; %s)\n' \
      "$(gib "$SHADOW_RES")" "$last" ;;
    stale-record) printf 'shadow storage: %s GiB reserved (whole cap; the record from %s is over 7 days old, so used is unknown; source record, no live reading)\n' \
      "$(gib "$SHADOW_RES")" "$(shadow_at '+%Y-%m-%d')" ;;
    config) case "$SHADOW_READING" in
        live) printf 'shadow storage: %s GiB reserved (whole FM_DISK_ROOM_SHADOW_MAX cap; the shadow storage read live has no cap; source live)\n' "$(gib "$SHADOW_RES")" ;;
        last-live) printf 'shadow storage: %s GiB reserved (whole FM_DISK_ROOM_SHADOW_MAX cap; the shadow storage last read live has no cap; %s)\n' "$(gib "$SHADOW_RES")" "$last" ;;
        *) printf 'shadow storage: %s GiB reserved (whole FM_DISK_ROOM_SHADOW_MAX cap; used is unknown without a live reading or the elevated record; source %s)\n' "$(gib "$SHADOW_RES")" "$SHADOW_READING" ;;
      esac ;;
    unbounded) case "$SHADOW_READING" in
        live) printf 'shadow storage: not reserved (the shadow storage read live has no cap; set FM_DISK_ROOM_SHADOW_MAX to bound it; source live)\n' ;;
        last-live) printf 'shadow storage: not reserved (the shadow storage last read live has no cap; set FM_DISK_ROOM_SHADOW_MAX to bound it; %s)\n' "$last" ;;
        *) printf 'shadow storage: not reserved (the recorded shadow storage has no cap; set FM_DISK_ROOM_SHADOW_MAX to bound it; source record, no live reading)\n' ;;
      esac ;;
    *) printf 'shadow storage: not reserved (no live reading and no record from the elevated task, so run or re-run fm-wsl-reclaim.ps1 -Install elevated, and FM_DISK_ROOM_SHADOW_MAX unset; source none)\n' ;;
  esac
}

# shadow_warning -> the cycling warning, or nothing.
shadow_warning() {
  case "$SHADOW_EVENTS" in ''|0) return 0 ;; esac
  printf 'shadow storage cycling: %s volsnap event(s) 25/33/36 in the last 7 days, so restore points are hitting the cap' "$SHADOW_EVENTS"
}

# WSL swap file -----------------------------------------------------------------

# wslconfig_value KEY FILE -> the [wsl2] section's KEY value from .wslconfig
# (key case-insensitive, quotes and a trailing comment dropped), or fails when unset.
wslconfig_value() {
  [ -r "$2" ] || return 1
  sed '1s/^\xEF\xBB\xBF//; s/\r$//' "$2" 2>/dev/null | awk -v key="$1" '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    line ~ /^\[/ { sect = tolower(line); gsub(/[ \t]/, "", sect); next }
    sect == "[wsl2]" && index(line, "=") {
      k = substr(line, 1, index(line, "=") - 1); v = substr(line, index(line, "=") + 1)
      gsub(/[ \t]/, "", k)
      if (tolower(k) != tolower(key)) next
      sub(/[ \t]+[#;].*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
      val = v; found = 1
    }
    END { if (!found) exit 1; print val }'
}

# wsl_size VALUE -> bytes for a .wslconfig size (16GB, 512MB, bytes), or fails.
wsl_size() { to_bytes "$(printf '%s' "$1" | tr -d ' \t')"; }

# swap_vhdx USERDIR -> the newest %TEMP%\<guid>\swap.vhdx WSL made, or fails.
# The Temp glob costs seconds on drvfs, so the match is cached for this VM boot
# while it exists; a new boot looks again, as an unclean exit leaves the old one.
swap_vhdx() {
  local cache boot id m f newest='' t best=0
  cache="$(state_dir)/swap-path"
  boot=$(cat "${FM_DISK_ROOM_BOOT_ID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || boot=''
  boot=${boot:--}
  if [ -r "$cache" ]; then
    read -r id m <"$cache" || m=''
    if [ "$id" = "$boot" ]; then
      case "$m" in "$1"/AppData/Local/Temp/*/swap.vhdx) [ -f "$m" ] && { printf '%s\n' "$m"; return 0; } ;; esac
    fi
  fi
  for f in "$1"/AppData/Local/Temp/*/swap.vhdx; do
    [ -f "$f" ] || continue
    t=$(stat -c %Y -- "$f" 2>/dev/null) || continue
    [ "$t" -ge "$best" ] && { best=$t; newest=$f; }
  done
  [ -n "$newest" ] || return 1
  mkdir -p "$(state_dir)" 2>/dev/null && printf '%s %s\n' "$boot" "$newest" >"$cache" 2>/dev/null
  printf '%s\n' "$newest"
}

# swap_reservation: sets SWAP_RES (bytes the WSL swap file can still grow on
# the Windows drive), SWAP_SRC (wslconfig, default, off, other-drive, disabled
# or unknown), SWAP_SIZE, SWAP_LEN, SWAP_FILE, SWAP_CONF, SWAP_MEM and
# SWAP_WHY. WSL grows the swap file from host free space while Linux df and
# the disk file stay flat. Only files are read, through the drive mount; no
# Windows process starts.
swap_reservation() {
  local conf v mem drive rest h
  SWAP_RES=0; SWAP_SRC=''; SWAP_SIZE=''; SWAP_LEN=''; SWAP_FILE=''; SWAP_CONF=''; SWAP_MEM=''; SWAP_WHY=''
  [ -n "$HOST" ] || return 0
  if [ -n "${FM_DISK_ROOM_WSLCONFIG+set}" ]; then
    conf=$FM_DISK_ROOM_WSLCONFIG
    [ -n "$conf" ] || { SWAP_SRC=disabled; return 0; }
  else
    case "$VHDX" in
      "$HOST"/Users/*/*) v=${VHDX#"$HOST"/Users/}; conf="$HOST/Users/${v%%/*}/.wslconfig" ;;
      *) SWAP_SRC=unknown; SWAP_WHY='the Windows user folder holding .wslconfig was not found; set FM_DISK_ROOM_WSLCONFIG'; return 0 ;;
    esac
  fi
  SWAP_CONF=$conf
  if v=$(wslconfig_value swap "$conf") && SWAP_SIZE=$(wsl_size "$v"); then
    SWAP_SRC=wslconfig
    [ "$SWAP_SIZE" -eq 0 ] && { SWAP_SRC=off; return 0; }
  else
    # WSL's default: a quarter of the VM's memory, rounded up to a whole GiB.
    # The VM's memory is memory= when set, else what Linux sees.
    SWAP_SRC=default
    if v=$(wslconfig_value memory "$conf") && mem=$(wsl_size "$v"); then :
    else
      mem=$(awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024 }' "${FM_DISK_ROOM_MEMINFO:-/proc/meminfo}" 2>/dev/null)
    fi
    case "$mem" in
      ''|*[!0-9]*) SWAP_SRC=unknown; SWAP_SIZE=''; SWAP_WHY="swap= is unset in $conf and the memory size is unreadable"; return 0 ;;
    esac
    SWAP_MEM=$mem
    SWAP_SIZE=$(( (mem / 4 + GIB - 1) / GIB * GIB ))
  fi
  if v=$(wslconfig_value swapFile "$conf") && [ -n "$v" ]; then
    v=${v//\\\\/\\}
    case "$v" in
      [A-Za-z]:[\\/]*)
        drive=${v%%:*}; rest=${v#?:}; h=${HOST##*/}
        if [ "${drive,,}" != "${h,,}" ]; then
          SWAP_SRC=other-drive; SWAP_FILE=$v; return 0
        fi
        SWAP_FILE="$HOST${rest//\\//}" ;;
      *) SWAP_FILE=$v ;;
    esac
  else
    SWAP_FILE=$(swap_vhdx "${conf%/*}") || SWAP_FILE=''
  fi
  # A swap file that cannot be found counts as empty, so its whole size is reserved.
  SWAP_LEN=0
  [ -n "$SWAP_FILE" ] && [ -f "$SWAP_FILE" ] && SWAP_LEN=$(stat -c %s -- "$SWAP_FILE" 2>/dev/null)
  case "$SWAP_LEN" in ''|*[!0-9]*) SWAP_LEN=0 ;; esac
  SWAP_RES=$(( SWAP_SIZE - SWAP_LEN )); [ "$SWAP_RES" -lt 0 ] && SWAP_RES=0
  return 0
}

# swap_line names where the swap file's size and length came from.
swap_line() {
  local size file
  case "$SWAP_SRC" in
    wslconfig) size="size $(gib "$SWAP_SIZE") GiB from swap= in $SWAP_CONF" ;;
    default) size="size $(gib "$SWAP_SIZE") GiB, the WSL default of a quarter of $(gib "$SWAP_MEM") GiB memory rounded up, since swap= is unset in $SWAP_CONF" ;;
    off) printf 'swap file: not reserved (swap=0 in %s, so WSL keeps no swap file)\n' "$SWAP_CONF"; return 0 ;;
    other-drive) printf 'swap file: not reserved (swapFile=%s in %s is not on %s)\n' "$SWAP_FILE" "$SWAP_CONF" "$HOST"; return 0 ;;
    disabled) printf 'swap file: not reserved (FM_DISK_ROOM_WSLCONFIG is empty)\n'; return 0 ;;
    *) printf 'swap file: not reserved (%s)\n' "$SWAP_WHY"; return 0 ;;
  esac
  if [ -n "$SWAP_FILE" ] && [ -f "$SWAP_FILE" ]; then
    file="file now $(gib "$SWAP_LEN") GiB at $SWAP_FILE"
  else
    file="no swap file found${SWAP_FILE:+ at $SWAP_FILE}, so all of it"
  fi
  printf 'swap file: %s GiB growth reserved (%s; %s)\n' "$(gib "$SWAP_RES")" "$size" "$file"
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
  dir=${2:-$(state_dir)/reservations}
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
  dir=${5:-$(state_dir)/reservations}
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

# resolve_margin: sets MARGIN from FM_DISK_ROOM_MARGIN, else the first line of
# the home's config/disk-room-margin, else 20G. The home is FM_HOME, else this
# script's own checkout, as arm resolves it. Sets ERR and returns 1 when the
# chosen value does not parse.
resolve_margin() {
  local f line=''
  if [ -n "${FM_DISK_ROOM_MARGIN:-}" ]; then
    MARGIN=$(to_bytes "$FM_DISK_ROOM_MARGIN") || { ERR="bad FM_DISK_ROOM_MARGIN"; return 1; }
    return 0
  fi
  f=${FM_CONFIG_OVERRIDE:-${FM_HOME:-${SCRIPT_DIR%/*}}/config}/disk-room-margin
  if [ -e "$f" ] || [ -L "$f" ]; then
    IFS= read -r line <"$f" 2>/dev/null
    line=${line//[$' \t\r']/}
    MARGIN=$(to_bytes "$line") || { ERR="bad margin in $f"; return 1; }
    return 0
  fi
  MARGIN=$((20 * GIB))
}

# measure [EXCLUDE]: sets globals; returns 1 when a required reading fails.
measure() {
  local host root line bs vhdx result fs_size dev bat
  ERR=''
  root=${FM_DISK_ROOM_ROOT:-/}
  host=$(host_mount)
  resolve_margin || return 1
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
  VHDX=''; VHDX_SIZE=''; FRAG=''; OVERHEAD=''; SLACK=''; RECLAIM=''; TRIM_MORE=''
  if [ -n "$HOST" ] && vhdx=$(discover_vhdx); then
    VHDX=$vhdx
    VHDX_SIZE=$(stat -c %s -- "$vhdx" 2>/dev/null) || VHDX_SIZE=''
  fi
  swap_reservation
  ROOM=$(( LINUX_FREE - RESERVED ))
  if [ -n "$HOST_FREE" ] && [ $(( HOST_FREE - SHADOW_RES - SWAP_RES - RESERVED )) -lt "$ROOM" ]; then
    ROOM=$(( HOST_FREE - SHADOW_RES - SWAP_RES - RESERVED ))
  fi
  bs=$(stat -f -c %S -- "$root" 2>/dev/null)
  [ -n "$bs" ] && FRAG=$(fragmented_free "$bs") || FRAG=''
  if [ -n "$VHDX_SIZE" ]; then
    SLACK=$(( VHDX_SIZE - LINUX_USED )); [ "$SLACK" -lt 0 ] && SLACK=0
    # ext4's own metadata (inode tables, journal, bitmaps) sits in the disk
    # file's slack but is neither df used nor df total. Slack, fragmented free
    # space and metadata are readings only: compaction drops just the blocks
    # the disk file's block table already holds no data for, so only that
    # table's figure is ever promised.
    fs_size=$(df_field "$root" size)
    if [ -n "$fs_size" ] && dev=$(dev_size) && [ "$dev" -ge "$fs_size" ]; then OVERHEAD=$(( dev - fs_size )); fi
    # After a trim: ext4's wholly free blocks the table still holds. A reading
    # for people only; it never feeds RECLAIM, the advice or the alerts.
    if bat=$(bat_reclaim "$VHDX" "$VHDX_SIZE" "$bs"); then
      RECLAIM=${bat% *}; TRIM_MORE=${bat#* }; [ "$TRIM_MORE" = - ] && TRIM_MORE=''
    fi
  fi
  COMPACT=''
  result=${FM_DISK_ROOM_COMPACT_RESULT:-${HOST:+$HOST/ProgramData/firstmate/wsl-compact-last.txt}}
  if [ -n "$result" ] && [ -r "$result" ]; then
    COMPACT=$(tr -d '\r' <"$result" | awk -F= '
      $1 == "finished" { f = $2 } $1 == "mode" { m = $2 } $1 == "reclaimed_bytes" { r = $2 } $1 == "result" { s = $2 } $1 == "trim" { t = $2 }
      END { if (f != "") printf "%s %s %s reclaimed %.1f GiB%s", f, m, s, r / 1073741824, (t != "" ? ", trim " t : "") }')
  fi
  return 0
}

limit_name() { if [ -n "$HOST_FREE" ] && [ $(( HOST_FREE - SHADOW_RES - SWAP_RES )) -le "$LINUX_FREE" ]; then printf '%s\n' "$HOST"; else printf 'Linux\n'; fi; }

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
      "$(if [ -z "$VHDX_SIZE" ]; then echo 'disk file not found'; else echo 'disk file block table unreadable'; fi)"
  else
    printf 'data must be freed or moved'
  fi
}

# results_root: sets RR_ACTIVE (ssd, c, or empty when no file), RR_STATE,
# RR_LETTER, RR_FS, RR_FREE, RR_TOTAL and RR_DEVICE from fm-storage.sh's
# results-root file.
results_root() {
  local f v
  f=${FM_DISK_ROOM_RESULTS_ROOT:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/lattice-storage/results-root}
  RR_ACTIVE='' RR_STATE='' RR_LETTER='' RR_FS='' RR_FREE='' RR_TOTAL='' RR_DEVICE=''
  [ -r "$f" ] || return 0
  rr() { sed -n "2,\${s/^$1=//p}" "$f" | head -n 1 | tr -cd 'A-Za-z0-9._ -'; }
  RR_ACTIVE=$(rr active); RR_STATE=$(rr state); RR_LETTER=$(rr ssd_letter); RR_FS=$(rr ssd_fs)
  v=$(rr ssd_device); case "$v" in ''|*[!0-9]*) ;; *) RR_DEVICE=$v ;; esac
  v=$(rr ssd_free_bytes); case "$v" in ''|*[!0-9]*) ;; *) RR_FREE=$v ;; esac
  v=$(rr ssd_total_bytes); case "$v" in ''|*[!0-9]*) ;; *) RR_TOTAL=$v ;; esac
}

# Growth and runway ------------------------------------------------------------

# threshold VAR DEFAULT -> bytes, or "off"; fails on a bad value (the caller sets ERR).
threshold() {
  local v=${!1:-$2}
  case "$v" in off) printf 'off\n'; return 0 ;; esac
  to_bytes "$v"
}

# sample_growth: reads the tail of the data-gate sampler (fm-io-sample) and
# sets SAMPLE_AT, SAMPLE_USED and, per window, the span in seconds and the
# change in Linux used bytes and C: used bytes (LG_DAY_SPAN LG_DAY CG_DAY,
# LG_WEEK_SPAN LG_WEEK CG_WEEK); a value it cannot compute stays empty.
sample_growth() {
  local f out
  SAMPLE_AT='' SAMPLE_USED='' LG_DAY_SPAN='' LG_DAY='' CG_DAY='' LG_WEEK_SPAN='' LG_WEEK='' CG_WEEK=''
  f=${FM_DISK_ROOM_SAMPLES:-${HOME:-/tmp}/.local/state/lattice-data-gate/samples.jsonl}
  [ -r "$f" ] || return 0
  # Only the tail is read: 3500 lines cover over 12 days at the 5-minute cadence.
  out=$(tail -n 3500 -- "$f" 2>/dev/null | awk '
    function num(k,  m) {
      if (!match($0, "\"" k "\":[0-9]+")) return ""
      return substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
    }
    function win(w,  i, dc) {
      for (i = 1; i < n && T[i] < T[n] - w; i++) ;
      dc = (C[n] != "" && C[i] != "") ? sprintf("%.0f", C[n] - C[i]) : "-"
      printf " %.0f %.0f %s", T[n] - T[i], U[n] - U[i], dc
    }
    { t = num("ts"); u = num("root_used"); if (t == "" || u == "") next
      if (n && t + 0 < T[n]) next
      n++; T[n] = t + 0; U[n] = u + 0; C[n] = num("mntc_used") }
    END { if (!n) exit; printf "%.0f %.0f", T[n], U[n]; win(86400); win(604800); print "" }')
  [ -n "$out" ] || return 0
  read -r SAMPLE_AT SAMPLE_USED LG_DAY_SPAN LG_DAY CG_DAY LG_WEEK_SPAN LG_WEEK CG_WEEK <<<"$out"
  [ "$CG_DAY" = - ] && CG_DAY=''
  [ "$CG_WEEK" = - ] && CG_WEEK=''
  return 0
}

# history_record: append "epoch disk-file-bytes host-free-bytes D-free-bytes
# D-reserved-bytes" to the small history at most once an hour, keeping the
# last 200 entries, so disk-file and D: changes have daily and weekly values.
history_record() {
  local f t last=''
  f="$(state_dir)/history"
  t=$(now)
  [ -r "$f" ] && last=$(tail -n 1 -- "$f" | awk '{ print $1 }')
  case "$last" in ''|*[!0-9]*) ;; *) [ $(( t - last )) -lt 3600 ] && [ "$t" -ge "$last" ] && return 0 ;; esac
  printf '%s %s %s %s %s\n' "$t" "${VHDX_SIZE:--}" "${HOST_FREE:--}" "${D_FREE:--}" "${D_RES:--}" >>"$f" 2>/dev/null || return 0
  if [ "$(wc -l <"$f")" -gt 200 ]; then
    tail -n 200 -- "$f" >"$f.tmp" 2>/dev/null && mv -f -- "$f.tmp" "$f"
  fi
  return 0
}

# history_change COLUMN WINDOW -> "span change" between the newest entry and the
# oldest within WINDOW seconds of it that both have the column, or nothing.
history_change() {
  local f
  f="$(state_dir)/history"
  [ -r "$f" ] || return 0
  awk -v c="$1" -v w="$2" '$c ~ /^[0-9]+$/ { n++; T[n] = $1; V[n] = $c }
    END { if (n < 2) exit; for (i = 1; i < n && T[i] < T[n] - w; i++) ;
      if (i < n) printf "%.0f %.0f\n", T[n] - T[i], V[n] - V[i] }' "$f"
}

# d_runway: sets D_FREE (live df of the verified D: results directory, else the
# publication's last ssd_free_bytes), D_SRC (live, published or empty), D_RES
# (live D: reservations) and D_AFTER.
d_runway() {
  local mp dev rootdev line dir
  D_FREE='' D_SRC='' D_RES=0 D_AFTER=''
  results_root
  mp="${FM_STORAGE_MNT:-/mnt}/d/lattice-data/tetjet-results"
  rootdev=$(stat -c %d -- "${FM_DISK_ROOM_ROOT:-/}" 2>/dev/null)
  if [ "$RR_ACTIVE" = ssd ] && [ "$RR_LETTER" = D ] && [ -n "$RR_DEVICE" ] &&
    dev=$(stat -c %d -- "$mp" 2>/dev/null) && [ "$dev" = "$RR_DEVICE" ] && [ "$dev" != "$rootdev" ]; then
    D_FREE=$(df_field "$mp" avail)
    case "$D_FREE" in ''|*[!0-9]*|???????????????????*) D_FREE='' ;; *) D_SRC=live ;; esac
  fi
  if [ -z "$D_FREE" ] && [ "$RR_LETTER" = D ] && [ -n "$RR_FREE" ]; then
    D_FREE=$RR_FREE; D_SRC=published
  fi
  for dir in "$(state_dir)/reservations-d/"*; do
    [ -d "$dir" ] || continue
    while read -r line; do
      [ -n "$line" ] && D_RES=$(( D_RES + ${line##* } ))
    done < <(live_reservations '' "$dir")
  done
  [ -n "$D_FREE" ] && D_AFTER=$(( D_FREE - D_RES ))
  return 0
}

# substitution: sets SUBST to why mandatory D: bulk is landing on Linux
# storage, or empty. Two signs: a D: reservation pool whose filesystem is the
# Linux root or C:, or a lattice-data folder under the D: mount path that sits
# on the Linux root, which is where writes to a pinned D: root go once D: is
# not mounted there.
substitution() {
  local rootdev hostdev='' dir dev mp
  SUBST=''
  rootdev=$(stat -c %d -- "${FM_DISK_ROOM_ROOT:-/}" 2>/dev/null) || return 0
  [ -n "$HOST" ] && hostdev=$(stat -c %d -- "$HOST" 2>/dev/null)
  for dir in "$(state_dir)/reservations-d/"*; do
    [ -d "$dir" ] || continue
    dev=${dir##*/}
    if [ "$dev" = "$rootdev" ] || { [ -n "$hostdev" ] && [ "$dev" = "$hostdev" ]; }; then
      [ -n "$(live_reservations '' "$dir")" ] &&
        SUBST="live D: reservations are charged to filesystem $dev, which is $([ "$dev" = "$rootdev" ] && echo the Linux disk || echo C:)"
    fi
  done
  mp="${FM_STORAGE_MNT:-/mnt}/d/lattice-data"
  if [ -z "$SUBST" ] && [ -e "$mp" ] && [ "$(stat -c %d -- "$mp" 2>/dev/null)" = "$rootdev" ]; then
    SUBST="$mp is on the Linux disk, so writes to the D: results path land on Linux"
  fi
  return 0
}

# per_day BYTES SPAN -> GiB per day with two decimals.
per_day() { awk -v b="$1" -v s="$2" 'BEGIN { printf "%.2f", (s > 0 ? b * 86400 / s : 0) / 1073741824 }'; }
days() { awk -v s="$1" 'BEGIN { printf "%.1f", s / 86400 }'; }
signed_gib() { awk -v b="$1" 'BEGIN { printf "%+.1f", b / 1073741824 }'; }

# storage_alerts: evaluates the growth and runway alerts after measure. Sets
# AL_<key> to 1 (alerting), 0 (clear) or empty (unknown, so the last state
# holds) and AL_TEXT_<key> to the alert's words, for the keys growth,
# c_runway, d_runway and d_substitution; they are read through indirection.
# shellcheck disable=SC2034
storage_alerts() {
  local gmax cmin dmin rate
  gmax=$(threshold FM_DISK_ROOM_GROWTH_MAX 0.5G) || { ERR="bad FM_DISK_ROOM_GROWTH_MAX"; return 1; }
  cmin=$(threshold FM_DISK_ROOM_C_FREE_MIN 100G) || { ERR="bad FM_DISK_ROOM_C_FREE_MIN"; return 1; }
  dmin=$(threshold FM_DISK_ROOM_D_FREE_MIN 50G) || { ERR="bad FM_DISK_ROOM_D_FREE_MIN"; return 1; }
  GROWTH_MAX=$gmax C_FREE_MIN=$cmin D_FREE_MIN=$dmin
  sample_growth; d_runway; substitution
  AL_growth='' AL_c_runway='' AL_d_runway='' AL_d_substitution=''
  # A week's rate needs at least six days of samples and a sample under 2 hours old.
  if [ "$gmax" != off ] && [ -n "$LG_WEEK_SPAN" ] && [ "$LG_WEEK_SPAN" -ge 518400 ] &&
    [ $(( $(now) - SAMPLE_AT )) -lt 7200 ]; then
    rate=$(awk -v b="$LG_WEEK" -v s="$LG_WEEK_SPAN" 'BEGIN { printf "%.0f", b * 86400 / s }')
    if [ "$rate" -gt "$gmax" ]; then AL_growth=1; else AL_growth=0; fi
    AL_TEXT_growth="Linux used grew $(per_day "$LG_WEEK" "$LG_WEEK_SPAN") GiB/day over the last $(days "$LG_WEEK_SPAN") days (limit $(gib "$gmax") GiB/day, approved installs and kept datasets included)"
  fi
  if [ "$cmin" != off ] && [ -n "$HOST_FREE" ]; then
    if [ "$HOST_FREE" -lt "$cmin" ]; then AL_c_runway=1; else AL_c_runway=0; fi
    AL_TEXT_c_runway="$HOST has $(gib "$HOST_FREE") GiB actually free (floor $(gib "$cmin") GiB)"
    if [ -n "$RECLAIM" ] && [ "$RECLAIM" -ge $((5 * GIB)) ]; then
      AL_TEXT_c_runway="$AL_TEXT_c_runway; a compaction could return about $(gib "$RECLAIM") GiB when the captain runs one"
    fi
  fi
  if [ "$dmin" != off ] && [ -n "$D_AFTER" ]; then
    if [ "$D_AFTER" -lt "$dmin" ]; then AL_d_runway=1; else AL_d_runway=0; fi
    AL_TEXT_d_runway="D: has $(gib "$D_AFTER") GiB after $(gib "$D_RES") GiB of reservations (floor $(gib "$dmin") GiB$([ "$D_SRC" = published ] && echo ', from the last published reading'))"
  fi
  if [ -n "$SUBST" ]; then AL_d_substitution=1; else AL_d_substitution=0; fi
  AL_TEXT_d_substitution="mandatory D: bulk substituted Linux storage: ${SUBST:-none}"
  return 0
}

ALERT_KEYS='growth c_runway d_runway d_substitution'

# storage_alert_line: compares the evaluated alerts with the recorded ones and
# prints one line naming each alert that started or cleared; an unchanged
# state prints nothing, so a standing alert is reported once.
storage_alert_line() {
  local rec k v old raised='' cleared='' tmp line
  rec="$(state_dir)/storage-alerts"
  tmp=$(mktemp "$(state_dir)/.storage-alerts.XXXXXX") || return 0
  for k in $ALERT_KEYS; do
    v="AL_$k"; v=${!v}
    old=$( [ -r "$rec" ] && sed -n "s/^$k=//p" "$rec" | head -n 1)
    [ -n "$v" ] || v=${old:-0}
    if [ "$v" = 1 ] && [ "$old" != 1 ]; then
      line="AL_TEXT_$k"; raised="$raised${raised:+; }${!line}"
    elif [ "$v" = 0 ] && [ "$old" = 1 ]; then
      cleared="$cleared${cleared:+, }${k//_/ }"
    fi
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
  done
  mv -f -- "$tmp" "$rec" 2>/dev/null || rm -f -- "$tmp"
  if [ -n "$raised" ]; then
    printf 'storage alert: %s%s' "$raised" "${cleared:+; cleared: $cleared}"
  elif [ -n "$cleared" ]; then
    printf 'storage alert cleared: %s' "$cleared"
  fi
}

# window_line LABEL SPAN CHANGE -> "LABEL +X GiB over D days", or "LABEL unknown".
window_line() {
  if [ -n "$2" ] && [ -n "$3" ]; then
    printf '%s %s GiB over %s days (%s GiB/day)' "$1" "$(signed_gib "$3")" "$(days "$2")" "$(per_day "$3" "$2")"
  else
    printf '%s unknown' "$1"
  fi
}

cmd_growth() {
  local h k v t
  [ "$#" -eq 0 ] || die "growth takes no arguments"
  measure || die "$ERR"
  storage_alerts || die "$ERR"
  if [ -n "$SAMPLE_AT" ]; then
    printf 'Linux used: %s GiB at %s; %s; %s\n' "$(gib "$SAMPLE_USED")" \
      "$(date -u -d "@$SAMPLE_AT" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$SAMPLE_AT")" \
      "$(window_line 'last day' "$LG_DAY_SPAN" "$LG_DAY")" "$(window_line 'last week' "$LG_WEEK_SPAN" "$LG_WEEK")"
  else
    printf 'Linux used: no sampler readings\n'
  fi
  if [ -n "$HOST_FREE" ]; then
    printf '%s free: %s GiB; used %s, %s\n' "$HOST" "$(gib "$HOST_FREE")" \
      "$(window_line 'last day' "$LG_DAY_SPAN" "$CG_DAY")" "$(window_line 'last week' "$LG_WEEK_SPAN" "$CG_WEEK")"
  fi
  if [ -n "$VHDX_SIZE" ]; then
    h=$(history_change 2 86400); k=$(history_change 2 604800)
    printf 'disk file: %s GiB; %s; %s\n' "$(gib "$VHDX_SIZE")" \
      "$(window_line 'last day' "${h% *}" "${h#* }")" "$(window_line 'last week' "${k% *}" "${k#* }")"
  fi
  if [ -n "$D_FREE" ]; then
    h=$(history_change 4 86400); k=$(history_change 4 604800)
    printf 'D: free %s GiB (%s), reserved %s GiB, after reservations %s GiB; free %s; %s\n' \
      "$(gib "$D_FREE")" "$D_SRC" "$(gib "$D_RES")" "$(gib "$D_AFTER")" \
      "$(window_line 'last day' "${h% *}" "${h#* }")" "$(window_line 'last week' "${k% *}" "${k#* }")"
  else
    printf 'D: not measured (%s); reserved %s GiB\n' "${RR_STATE:-no publication}" "$(gib "$D_RES")"
  fi
  printf 'reserved writes (Linux/C:): %s GiB%s\n' "$(gib "$RESERVED")" "${RES_LIST:+ ($RES_LIST)}"
  for k in $ALERT_KEYS; do
    v="AL_$k"; t="AL_TEXT_$k"
    case "${!v}" in
      1) printf 'ALERT %s: %s\n' "${k//_/ }" "${!t}" ;;
      0) printf 'ok %s\n' "${k//_/ }" ;;
      *) printf 'unknown %s (not enough readings, or turned off)\n' "${k//_/ }" ;;
    esac
  done
  printf 'thresholds: growth %s, C: free %s, D: free after reservations %s\n' \
    "$([ "$GROWTH_MAX" = off ] && echo off || echo "$(gib "$GROWTH_MAX") GiB/day")" \
    "$([ "$C_FREE_MIN" = off ] && echo off || echo "$(gib "$C_FREE_MIN") GiB")" \
    "$([ "$D_FREE_MIN" = off ] && echo off || echo "$(gib "$D_FREE_MIN") GiB")"
}

cmd_status() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  measure || die "$ERR"
  results_root
  if [ "$json" = 1 ]; then
    printf '{"margin":%s,"host":"%s","host_free":%s,"linux_free":%s,"linux_used":%s,"reserved":%s,"room":%s,"low":%s,"vhdx":"%s","vhdx_size":%s,"fragmented_free":%s,"fs_overhead":%s,"slack":%s,"reclaimable":%s,"results_active":"%s","results_state":"%s","ssd_free":%s,"ssd_total":%s,"shadow_reserved":%s,"shadow_source":"%s","shadow_max":%s,"shadow_used":%s,"shadow_events":%s,"shadow_reading":"%s","shadow_allocated":%s,"swap_reserved":%s,"swap_source":"%s","swap_size":%s,"swap_file_size":%s,"trim_reclaimable":%s}\n' \
      "$MARGIN" "$HOST" "${HOST_FREE:-null}" "$LINUX_FREE" "$LINUX_USED" "$RESERVED" "$ROOM" \
      "$([ "$ROOM" -lt "$MARGIN" ] && echo true || echo false)" "$VHDX" "${VHDX_SIZE:-null}" \
      "${FRAG:-null}" "${OVERHEAD:-null}" "${SLACK:-null}" "${RECLAIM:-null}" "$RR_ACTIVE" "$RR_STATE" "${RR_FREE:-null}" "${RR_TOTAL:-null}" \
      "$SHADOW_RES" "$SHADOW_SRC" "${SHADOW_MAX:-null}" "${SHADOW_USED:-null}" "${SHADOW_EVENTS:-null}" "$SHADOW_READING" "${SHADOW_ALLOC:-null}" \
      "$SWAP_RES" "$SWAP_SRC" "${SWAP_SIZE:-null}" "${SWAP_LEN:-null}" "${TRIM_MORE:-null}"
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
    swap_line
  fi
  if [ -n "$VHDX_SIZE" ]; then
    printf 'disk file: %s GiB (%s); slack %s GiB, of which fragmented %s and ext4 metadata %s; reclaimable by compaction %s\n' \
      "$(gib "$VHDX_SIZE")" "$VHDX" "$(gib "$SLACK")" "$(if [ -n "$FRAG" ]; then printf '%s GiB' "$(gib "$FRAG")"; else printf unknown; fi)" \
      "$(if [ -n "$OVERHEAD" ]; then printf '%s GiB' "$(gib "$OVERHEAD")"; else printf unknown; fi)" \
      "$(if [ -n "$RECLAIM" ]; then printf 'about %s GiB (disk file block table)' "$(gib "$RECLAIM")"; else printf 'unknown (disk file block table unreadable)'; fi)"
    if [ -n "$RECLAIM" ]; then
      printf 'after a trim: %s (ext4 free 1 MiB blocks the disk file still holds; reclaim-now trims before compacting)\n' \
        "$(if [ -n "$TRIM_MORE" ]; then printf 'about %s GiB more' "$(gib "$TRIM_MORE")"; else printf 'unknown (ext4 mb_groups unreadable)'; fi)"
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
    c) printf 'fetched results root: no active SSD publication (state %s); per-fetch wait/refusal/fallback rules apply\n' "$RR_STATE" ;;
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

# Job-kind history -------------------------------------------------------------

# read_write_history KIND sets WRITE_SAMPLES and WRITE_HIGH; missing is empty,
# but an existing unreadable, empty or malformed file fails closed.
read_write_history() {
  local file dir out
  WRITE_SAMPLES=0 WRITE_HIGH=0
  dir="$(state_dir)/write-history"
  file="$dir/$1"
  if { [ -e "$dir" ] || [ -L "$dir" ]; } && { [ ! -d "$dir" ] || [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; then
    ERR="cannot read write history directory $dir"; return 1
  fi
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    ERR="cannot read write history $file"; return 1
  fi
  out=$(LC_ALL=C awk '
    function integer(v) { return v ~ /^(0|[1-9][0-9]*)$/ && length(v) <= 18 }
    NF != 4 || $1 != "fm-disk-write/v1" || !integer($2) ||
      !integer($3) || !integer($4) || $4 + 0 > 255 { bad = 1 }
    { n++; if (length($3) > length(high) ||
        (length($3) == length(high) && "x" $3 > "x" high)) high = $3 }
    END { if (bad || !n) exit 1; printf "%d %s\n", n, high }
  ' "$file") || { ERR="corrupt write history $file"; return 1; }
  read -r WRITE_SAMPLES WRITE_HIGH <<<"$out"
}

# kind_expect KIND DECLARED sets EXPECT and LINE; check's exit convention.
kind_expect() {
  local kind=$1 declared=$2
  read_write_history "$kind" || { LINE="cannot measure disk room: $ERR"; return 2; }
  if [ -z "$declared" ]; then
    if [ "$WRITE_SAMPLES" -eq 0 ]; then
      LINE="cannot measure disk room: no write history for kind $kind; declare --expect-write for its first run"
      return 2
    fi
    EXPECT=$WRITE_HIGH
  elif [ "$declared" -lt "$WRITE_HIGH" ]; then
    LINE="low: kind $kind declared $declared bytes below recorded high $WRITE_HIGH bytes ($WRITE_SAMPLES samples); raise --expect-write"
    return 1
  else
    EXPECT=$declared
  fi
}

# Shell builtins only: a subshell would read the wrong process's counters.
read_write_counter() {
  local key value rest
  IO_BYTES=''
  while read -r key value rest; do
    if [ "$key" = write_bytes: ]; then
      case "$value" in ''|*[!0-9]*|???????????????????*) return 1 ;; esac
      IO_BYTES=$value
      return 0
    fi
  done <"/proc/$$/io" 2>/dev/null
  return 1
}

record_write() {
  local kind=$1 bytes=$2 rc=$3 dir
  with_lock
  read_write_history "$kind" || { printf 'fm-disk-room: %s; repair history before retrying\n' "$ERR" >&2; return 1; }
  dir="$(state_dir)/write-history"
  if ! mkdir -p "$dir" || ! printf 'fm-disk-write/v1 %s %s %s\n' "$(now)" "$bytes" "$rc" >>"$dir/$kind"; then
    printf 'fm-disk-room: cannot record write history %s/%s; repair history before retrying\n' "$dir" "$kind" >&2
    return 1
  fi
}

cmd_write_history() {
  { [ "$#" -eq 1 ] && valid_name "$1"; } || die "write-history needs KIND"
  with_lock
  read_write_history "$1" || die "$ERR"
  printf '{"kind":"%s","samples":%s,"high_bytes":%s}\n' "$1" "$WRITE_SAMPLES" "$WRITE_HIGH"
}

cmd_check() {
  local expect='' exclude='' kind='' rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect-write) [ "$#" -ge 2 ] || die "--expect-write needs a size"; expect=$(to_bytes "$2") || die "bad size: $2"; shift 2 ;;
      --exclude) { [ "$#" -ge 2 ] && valid_name "$2"; } || die "--exclude needs a name"; exclude=$2; shift 2 ;;
      --kind) { [ "$#" -ge 2 ] && valid_name "$2"; } || die "--kind needs a kind"; kind=$2; shift 2 ;;
      *) die "unknown check argument: $1" ;;
    esac
  done
  [ -n "$expect$kind" ] || die "check needs --expect-write SIZE or --kind KIND"
  if [ -n "$kind" ]; then
    with_lock
    kind_expect "$kind" "$expect"; rc=$?
    [ "$rc" -eq 0 ] || { printf '%s\n' "$LINE"; return "$rc"; }
    expect=$EXPECT
  fi
  admit "$expect" "$exclude"; rc=$?
  printf '%s\n' "$LINE"
  return "$rc"
}

cmd_run() {
  local name='' expect='' kind='' before rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) { [ "$#" -ge 2 ] && valid_name "$2"; } || die "--name needs a name"; name=$2; shift 2 ;;
      --kind) { [ "$#" -ge 2 ] && valid_name "$2"; } || die "--kind needs a kind"; kind=$2; shift 2 ;;
      --expect-write) [ "$#" -ge 2 ] || die "--expect-write needs a size"; expect=$(to_bytes "$2") || die "bad size: $2"; shift 2 ;;
      --) shift; break ;;
      *) die "unknown run argument: $1" ;;
    esac
  done
  [ -n "$name" ] && [ -n "$expect$kind" ] && [ "$#" -gt 0 ] || die "run needs --name, --expect-write or --kind, and -- COMMAND"
  with_lock
  if [ -n "$kind" ]; then
    live_reservations >/dev/null
    if [ -e "$(state_dir)/reservations/$name" ]; then
      printf 'fm-disk-room: refused %s: reservation already live; use a unique --name\n' "$name" >&2
      return 75
    fi
    if ! kind_expect "$kind" "$expect"; then
      printf 'fm-disk-room: refused %s: %s\n' "$name" "$LINE" >&2
      return 75
    fi
    expect=$EXPECT
    if ! read_write_counter; then
      printf 'fm-disk-room: refused %s: cannot measure storage write counter /proc/%s/io\n' "$name" "$$" >&2
      return 75
    fi
  fi
  if ! admit "$expect" "$name"; then
    printf 'fm-disk-room: refused %s: %s\n' "$name" "$LINE" >&2
    exit 75
  fi
  write_reservation "$name" "$expect" "$$" 0
  exec 9>&-
  [ -n "$kind" ] || exec "$@"
  read_write_counter || { printf 'fm-disk-room: refused %s: cannot measure storage write counter\n' "$name" >&2; return 75; }
  before=$IO_BYTES
  "$@"; rc=$?
  if read_write_counter && [ "$IO_BYTES" -ge "$before" ]; then
    (record_write "$kind" "$(( IO_BYTES - before ))" "$rc") || { [ "$rc" -ne 0 ] || rc=74; }
  else
    printf 'fm-disk-room: cannot measure completed write for %s; no sample recorded\n' "$name" >&2
    [ "$rc" -ne 0 ] || rc=74
  fi
  rm -f -- "$(state_dir)/reservations/$name"
  return "$rc"
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

cmd_reserve_bulk() {
  local name=${1:-} task='' download='' expanded='' packaging='' pid='' ttl=$DEFAULT_TTL
  local root device dir bytes free reserved=0 line margin after mp rc
  valid_name "$name" || die "reserve-bulk needs NAME"
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --task) task=$2 ;;
      --download) download=$(to_bytes "$2") || die "bad download size" ;;
      --expanded) expanded=$(to_bytes "$2") || die "bad expanded size" ;;
      --packaging) packaging=$(to_bytes "$2") || die "bad packaging size" ;;
      --pid) case "$2" in ''|*[!0-9]*) die "--pid needs a live pid" ;; esac
        [ -r "/proc/$2/stat" ] || die "--pid needs a live pid"; pid=$2 ;;
      --ttl) case "$2" in ''|*[!0-9]*|??????????*) die "--ttl needs seconds (at most 9 digits)" ;; esac
        ttl=$((10#$2)) ;;
      *) die "unknown reserve-bulk argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$task" ] && [ -n "$download" ] && [ -n "$expanded" ] && [ -n "$packaging" ] ||
    die "reserve-bulk needs --task, --download, --expanded and --packaging"
  bytes=$(( download + expanded + packaging ))
  margin=$(to_bytes "${FM_DISK_ROOM_BULK_MARGIN:-50G}") || die "bad FM_DISK_ROOM_BULK_MARGIN"
  with_lock
  root=$(FM_STORAGE_RESULTS_ROOT="${FM_DISK_ROOM_RESULTS_ROOT:-${FM_STORAGE_RESULTS_ROOT:-}}" \
    "$SCRIPT_DIR/fm-storage.sh" verify-bulk-root "$task"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  mp="${FM_STORAGE_MNT:-/mnt}/d"
  device=$(stat -c %d -- "$mp/lattice-data/tetjet-results" 2>/dev/null)
  case "$device" in ''|*[!0-9]*) printf 'fm-disk-room: wait: wrong-filesystem-identity\n' >&2; return 75 ;; esac
  dir="$(state_dir)/reservations-d/$device"
  while read -r line; do
    [ -n "$line" ] && reserved=$(( reserved + ${line##* } ))
  done < <(live_reservations '' "$dir")
  [ ! -e "$dir/$name" ] || { printf 'fm-disk-room: wait: reservation-exists: %s\n' "$name" >&2; return 75; }
  free=$(df_field "$mp/lattice-data/tetjet-results" avail)
  case "$free" in ''|*[!0-9]*|???????????????????*) printf 'fm-disk-room: wait: cannot-measure-D\n' >&2; return 75 ;; esac
  after=$(( free - reserved - bytes ))
  if [ "$after" -lt "$margin" ]; then
    printf 'fm-disk-room: wait: insufficient-space: D: would have %s GiB after %s GiB peak and %s GiB reservations (margin %s GiB)\n' \
      "$(gib "$after")" "$(gib "$bytes")" "$(gib "$reserved")" "$(gib "$margin")" >&2
    return 75
  fi
  # Recheck identity immediately before recording admission; never rewrite pins.
  FM_STORAGE_RESULTS_ROOT="${FM_DISK_ROOM_RESULTS_ROOT:-${FM_STORAGE_RESULTS_ROOT:-}}" \
    "$SCRIPT_DIR/fm-storage.sh" verify-bulk-root "$task" >/dev/null || return "$?"
  [ "$(stat -c %d -- "$mp/lattice-data/tetjet-results" 2>/dev/null)" = "$device" ] || {
    printf 'fm-disk-room: wait: wrong-filesystem-identity\n' >&2; return 75;
  }
  write_reservation "$name" "$bytes" "$pid" "$ttl" "$dir" || die "cannot record D: reservation"
  printf '%s\n' "$root"
}

cmd_release_bulk() {
  local dir
  valid_name "${1:-}" && [ "$#" -eq 1 ] || die "release-bulk needs NAME"
  with_lock
  for dir in "$(state_dir)/reservations-d/"*; do
    [ -d "$dir" ] && rm -f -- "$dir/$1"
  done
  return 0
}

cmd_release() {
  valid_name "${1:-}" || die "release needs a NAME"
  rm -f -- "$(state_dir)/reservations/$1"
}

cmd_watch_line() {
  local rec t last_kind last_t last_room msg='' kind='' measured=1 storage=''
  rec="$(state_dir)/alert"
  t=$(now)
  mkdir -p "$(state_dir)" 2>/dev/null || return 0
  if ! measure; then
    kind=error; msg="disk room: cannot measure ($ERR)"; ROOM=0; measured=0
  elif [ "$ROOM" -lt "$MARGIN" ]; then
    kind=low
    msg="disk room low: $(gib "$ROOM") GiB real room on $(limit_name) after $(gib "$RESERVED") GiB of declared writes and $(gib "$SHADOW_RES") GiB of shadow storage headroom$([ "$SWAP_RES" -gt 0 ] && printf ' and %s GiB of swap file growth' "$(gib "$SWAP_RES")") (margin $(gib "$MARGIN") GiB); $(advice)"
  else
    rm -f -- "$rec"
  fi
  if [ -n "$kind" ] && [ -r "$rec" ]; then
    read -r last_kind last_t last_room <"$rec" || true
    if [ "${last_kind:-}" = "$kind" ] && [ $(( t - ${last_t:-0} )) -lt "$REALERT_SECS" ] \
      && { [ "$kind" = error ] || [ "$ROOM" -gt $(( ${last_room:-0} - REALERT_DROP )) ]; }; then
      msg=''
    fi
  fi
  [ -n "$msg" ] && { printf '%s %s %s\n' "$kind" "$t" "$ROOM" >"$rec" 2>/dev/null || true; }
  if [ "$measured" = 1 ]; then
    if storage_alerts; then
      history_record
      storage=$(storage_alert_line)
      rm -f -- "$(state_dir)/storage-alerts-error"
    elif [ "$(cat "$(state_dir)/storage-alerts-error" 2>/dev/null)" != "$ERR" ]; then
      printf '%s\n' "$ERR" >"$(state_dir)/storage-alerts-error" 2>/dev/null || true
      storage="storage alerts: cannot evaluate ($ERR)"
    fi
  fi
  if [ -n "$msg" ] && [ -n "$storage" ]; then
    printf '%s | %s\n' "$msg" "$storage"
  elif [ -n "$msg$storage" ]; then
    printf '%s\n' "$msg$storage"
  fi
  return 0
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
    for v in MARGIN HOST ROOT VHDX MB_GROUPS DEV_SIZE COMPACT_RESULT POWERSHELL SHADOW_RECORD SHADOW_MAX WEVTUTIL STATE \
      WSLCONFIG MEMINFO BOOT_ID RESULTS_ROOT SAMPLES GROWTH_MAX C_FREE_MIN D_FREE_MIN; do
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

# Interface --------------------------------------------------------------------

# json_value JSON KEY -> the raw value of a top-level KEY in a one-line object.
json_value() { printf '%s\n' "$1" | sed -n "s/.*[{,]\"$2\":\(\"[^\"]*\"\|[^,}]*\).*/\1/p"; }

# self_probe MARGIN ARG... -> this script run hermetically: every
# FM_DISK_ROOM_* setting replaced, Linux-only, state and readings in SELF_TMP.
self_probe() {
  local margin=$1 v
  shift
  (
    for v in $(compgen -e); do case "$v" in FM_DISK_ROOM_*) unset "$v" ;; esac; done
    export FM_DISK_ROOM_HOST='' FM_DISK_ROOM_ROOT="$SELF_TMP" FM_DISK_ROOM_STATE="$SELF_TMP/state" \
      FM_DISK_ROOM_POWERSHELL='' FM_DISK_ROOM_WEVTUTIL='' FM_DISK_ROOM_MB_GROUPS="$SELF_TMP/none" \
      FM_DISK_ROOM_RESULTS_ROOT="$SELF_TMP/none" FM_DISK_ROOM_SAMPLES="$SELF_TMP/none" \
      FM_DISK_ROOM_COMPACT_RESULT="$SELF_TMP/none" FM_DISK_ROOM_MARGIN="$margin"
    [ -z "$SELF_TEXT" ] || exec bash -c "$SELF_TEXT" "$SELF" "$@"
    exec "$SELF" "$@"
  )
}

# self_test_v1 -> nothing on success, else what failed.
self_test_v1() {
  local out rc spec key kind v
  [ "$(self_probe 0 --interface v1)" = "fm-disk-room-interface/v1" ] || { echo "--interface v1 does not print fm-disk-room-interface/v1"; return; }
  out=$(self_probe 0 status --json 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { echo "status --json exited $rc"; return; }
  for spec in $INTERFACE_V1_FIELDS; do
    key=${spec%%:*}; kind=${spec#*:}; v=$(json_value "$out" "$key")
    case "$kind:$v" in
      int:|int:*[!0-9-]*|opt:) echo "status --json field $key is not an integer: '$v'"; return ;;
      opt:null) ;;
      opt:*[!0-9-]*) echo "status --json field $key is not an integer or null: '$v'"; return ;;
      bool:true|bool:false) ;;
      bool:*) echo "status --json field $key is not a boolean: '$v'"; return ;;
      str:\"*\") ;;
      str:*) echo "status --json field $key is not a string: '$v'"; return ;;
    esac
  done
  out=$(self_probe 0 check --expect-write 1K 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "${out#ok: }" != "$out" ] || { echo "check with room did not exit 0 with 'ok: ' (exit $rc)"; return; }
  out=$(self_probe 100000T check --expect-write 0 2>/dev/null); rc=$?
  [ "$rc" -eq 1 ] && [ "${out#low: }" != "$out" ] || { echo "check under the margin did not exit 1 with 'low: ' (exit $rc)"; return; }
  self_probe 0 check >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || { echo "check without --expect-write did not exit 2 (exit $rc)"; return; }
  self_probe 0 run --name fm-self-test --expect-write 1K -- sh -c 'exit 7' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 7 ] || { echo "an admitted run did not return the command's status (exit $rc)"; return; }
  out=$(self_probe 100000T run --name fm-self-test --expect-write 0 -- sh -c 'echo ran' 2>&1); rc=$?
  [ "$rc" -eq 75 ] && [ "${out#fm-disk-room: refused fm-self-test: }" != "$out" ] || { echo "a refused run did not exit 75 with its refusal line (exit $rc)"; return; }
  out=$(self_probe 0 reserve fm-self-test 1G --ttl 60 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "${out#reserved fm-self-test: }" != "$out" ] || { echo "reserve did not exit 0 with 'reserved NAME: ' (exit $rc)"; return; }
  [ "$(json_value "$(self_probe 0 status --json 2>/dev/null)" reserved)" = "$GIB" ] || { echo "status --json reserved does not count a 1G reservation as $GIB bytes"; return; }
  self_probe 0 release fm-self-test >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && [ "$(json_value "$(self_probe 0 status --json 2>/dev/null)" reserved)" = 0 ] || { echo "release did not exit 0 and drop the reservation (exit $rc)"; return; }
  out=$(self_probe 0 watch-line 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || { echo "watch-line above the margin did not exit 0 silently (exit $rc)"; return; }
}

self_test_v2() {
  local failure out rc
  failure=$(self_test_v1)
  [ -z "$failure" ] || { printf '%s\n' "$failure"; return; }
  [ "$(self_probe 0 --interface)" = "fm-disk-room-interface/v2" ] || { echo "--interface does not print fm-disk-room-interface/v2"; return; }
  self_probe 0 run --name fm-self-kind --kind self-kind --expect-write 1M -- sh -c 'exit 7' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 7 ] || { echo "kind run did not return command status (exit $rc)"; return; }
  out=$(self_probe 0 write-history self-kind 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$(json_value "$out" samples)" = 1 ] || { echo "kind run did not record its sample"; return; }
  out=$(self_probe 0 check --kind self-kind 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "${out#ok: }" != "$out" ] || { echo "check without a declaration did not use kind history"; return; }
}

cmd_self_test() {
  local want=${1:-} failure
  [ "$#" -eq 1 ] && [ -n "$want" ] || die "--self-test needs one interface version, such as v1"
  if [ "$want" != v1 ] && [ "$want" != v2 ]; then
    printf 'fm-disk-room: does not serve interface %s (serves fm-disk-room-interface/%s)\n' "$want" "$INTERFACE"
    return 1
  fi
  SELF_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-disk-room-self-test.XXXXXX") || die "cannot create a temp directory"
  failure=$("self_test_$want")
  rm -rf -- "$SELF_TMP"
  if [ -n "$failure" ]; then
    printf 'fm-disk-room: self-test %s failed: %s\n' "$want" "$failure"
    return 1
  fi
  printf 'fm-disk-room: self-test %s passed (fm-disk-room-interface/%s)\n' "$want" "$INTERFACE"
}

case "${1:-}" in
  --interface)
    [ "$#" -le 2 ] || die "--interface takes at most one version"
    case "${2:-$INTERFACE}" in
      v1|v2) printf 'fm-disk-room-interface/%s\n' "${2:-$INTERFACE}" ;;
      *) printf 'fm-disk-room: unsupported interface %s\n' "$2"; exit 1 ;;
    esac ;;
  --self-test) shift; cmd_self_test "$@" ;;
  status) shift; cmd_status "$@" ;;
  check) shift; cmd_check "$@" ;;
  run) shift; cmd_run "$@" ;;
  write-history) shift; cmd_write_history "$@" ;;
  reserve) shift; cmd_reserve "$@" ;;
  reserve-bulk) shift; cmd_reserve_bulk "$@" ;;
  release-bulk) shift; cmd_release_bulk "$@" ;;
  release) shift; cmd_release "$@" ;;
  watch-line) shift; cmd_watch_line ;;
  growth) shift; cmd_growth "$@" ;;
  arm) cmd_arm ;;
  disarm) cmd_disarm ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
