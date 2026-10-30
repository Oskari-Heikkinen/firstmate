#!/usr/bin/env bash
# fm-storage.sh - put fetched results on an external SSD when one is usable,
# and publish that choice in one machine-local file that every fetcher reads.
# There is no C: or Linux fallback: when the SSD is not usable, writers wait.
# docs/storage.md owns the results-root file format
# (lattice-storage-results-root/v1), the states, and the reader rules.
#
# Usage:
#   fm-storage.sh detect
#       Read Windows volumes and disks (no admin, no writes) and print the
#       candidate SSD and the state a check would reach before mounting.
#   fm-storage.sh check
#       The periodic entry point: detect, mount through the narrow sudoers
#       rule when needed (sudo -n only; a refusal is state not-mounted; a listed
#       mount that fails with No such device is released with umount -l and
#       mounted again, and a refused repair is state stale-mount), set up
#       the folder layout and measure write speed once, probe, then write the
#       results-root file atomically and notify on a state change.
#       The Windows listing is tried up to 3 times; a check that still cannot
#       read it keeps the last readable published state until 3 consecutive
#       checks have failed, then publishes unreadable. A check whose listing
#       fails first proves the remembered SSD without Windows (mount, marker,
#       published device, write probe) and, when all pass, publishes it as ok.
#       Prints one line.
#   fm-storage.sh setup
#       Run check now, then print status.
#   fm-storage.sh status
#       Print the published choice from the results-root file (no Windows call).
#   fm-storage.sh root [--root ROOT] [TASK]
#       Apply the reader rules and print the directory to use: the template
#       with {task} replaced by TASK (kept as {task} when TASK is omitted).
#       On any doubt exit 75 with one stderr wait: reason and print no path.
#       With --root research it prints the verified D: research directory
#       (verify-bulk-root's answer, exit 75 the same way otherwise).
#   fm-storage.sh verify-bulk-root [--root ROOT] [TASK]
#       Verify the published D: root and live volume identity, without reserving.
#       Exit 75 with one stderr reason on unavailable storage; never return C:
#       or Linux.
#   fm-storage.sh bulk-root [--root ROOT] TASK --name NAME --download SIZE
#                         --expanded SIZE --packaging SIZE [--pid PID] [--ttl SECONDS]
#       Verify and admit the whole allocation peak via fm-disk-room reserve-bulk.
#       Print only the D: root on success (0); unavailable/low room exits 75,
#       misuse exits 2. No pin files are read or rewritten by either command.
#   ROOT names one D: directory under <mount>/lattice-data: tetjet-results
#   (the default, line 1's template) or research. Any other name exits 2.
#   fm-storage.sh install-timer [--notify FILE]
#       Write storage.conf (notification file, kept min_free and min_size), then
#       write and enable the user-level fm-storage.timer (every 5 minutes,
#       Nice=19, idle IO). No root. The removed --fallback option exits 2.
#   fm-storage.sh uninstall-timer
#       Disable and remove that timer; the config and results-root stay.
#
# fm-storage/v2 (a draft contract; docs/storage.md "fm-storage/v2" owns it):
#   fm-storage.sh --interface
#       Print fm-storage/v2. Reads no configuration and writes nothing.
#   fm-storage.sh reserve --volume linux|host-c|d --class CLASS TASK
#                         --name NAME --bytes N --pid PID
#       Resolve CLASS to its root through site-config for this host
#       (uname -n), refuse a root that is not on VOLUME, then admit N bytes
#       for the life of PID through fm-disk-room.sh reserve-token, which
#       checks every other argument. Prints one token (0). A wait exits 75 and
#       a refusal 2 (1 for owner-state), each with one stderr line
#       "fm-storage: wait|refused: CODE: VOLUME:CLASS: DETAIL".
#   fm-storage.sh release TASK --token TOKEN
#       fm-disk-room.sh release-token: drop that one admission (0, repeatable).
#   fm-storage.sh status --json
#       One fm-storage/v2 status line: the class map digest, fm-disk-room.sh
#       admission-status's reading of every pool, and a site-config wait as a
#       reason. 0 ok, 75 waiting (one stderr wait line), 2 refused (1 for
#       owner-state). Takes no lock and writes, prunes and probes nothing.
#   fm-storage.sh site-config --here HOST
#   fm-storage.sh health --volume d
#       fm-storage-roots.py, whose header owns both.
#
# Files (config dir ${XDG_CONFIG_HOME:-~/.config}/lattice-storage):
#   results-root   the published file (docs/storage.md)
#   storage.conf   key=value: notify, min_free, min_size (a leftover fallback=
#                  line is ignored)
#   ssd-identity   key=value: uniqueid, letter, fs, label, setup_at, write_mib_s
#   class-map.json the storage class map (fm-storage-class-map/v1), read only
#                  by fm-storage-roots.py
# State dir ${XDG_STATE_HOME:-~/.local/state}/fm-storage: last-state, lock,
#   unreadable-runs (consecutive checks whose listing failed; removed on success).
#
# Environment (all optional; each overrides storage.conf):
#   FM_STORAGE_FALLBACK  removed and ignored: no command uses a fallback
#   FM_STORAGE_NOTIFY    status file that receives one note line per state change
#   FM_STORAGE_MIN_FREE  SSD free space below which it is full (default 50G)
#   FM_STORAGE_MIN_SIZE  smallest volume taken as the SSD (default 1500000000000)
#   FM_STORAGE_MAX_AGE   oldest check a reader trusts, seconds (default 1800)
#   FM_STORAGE_CONFIG    config dir;  FM_STORAGE_STATE  state dir
#   FM_STORAGE_RESULTS_ROOT  publication override for mandatory-bulk readers
#   FM_STORAGE_MNT       WSL mount base (default /mnt)
#   FM_STORAGE_MOUNTINFO mount table (default /proc/self/mountinfo)
#   FM_STORAGE_MOUNT_PROBE  command run as PROBE -- MOUNTPOINT to tell a dead
#                        listed mount from a live one (default stat)
#   FM_STORAGE_SPEED_SIZE  write-speed test size (default 1G)
#   FM_STORAGE_PS_BACKOFF  seconds slept before each listing retry (default "5 15")
#   FM_STORAGE_POWERSHELL  powershell.exe to use (default: the one on PATH, else
#                        /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
#   FM_STORAGE_MACHINE_ID  machine id file site-config proves the host by
#                        (default /etc/machine-id)
#   FM_STORAGE_NOW       epoch override for tests (and status --json's sampled_at)
set -u

GIB=1073741824
FORMAT='lattice-storage-results-root/v1'
PS_TIMEOUT=30
UNREADABLE_LIMIT=3
PS_DIR=/mnt/c/Windows/System32/WindowsPowerShell/v1.0

die() { printf 'fm-storage: %s\n' "$*" >&2; exit 2; }

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }

now() { printf '%s\n' "${FM_STORAGE_NOW:-$(date +%s)}"; }

config_dir() { printf '%s\n' "${FM_STORAGE_CONFIG:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/lattice-storage}"; }
state_dir() { printf '%s\n' "${FM_STORAGE_STATE:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/fm-storage}"; }
mnt_base() { printf '%s\n' "${FM_STORAGE_MNT:-/mnt}"; }

# to_bytes SIZE -> bytes on stdout, or fail.
to_bytes() {
  local v=$1 n unit mult
  case "$v" in ''|*[!0-9.KMGTkmgt]*) return 1 ;; esac
  n=${v%%[KMGTkmgt]*}
  unit=${v#"$n"}
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

tib() { awk -v b="$1" 'BEGIN { printf "%.2f TiB", b / 1099511627776 }'; }

# kv FILE KEY -> value of the first KEY= line.
kv() { [ -r "$1" ] && sed -n "s/^$2=//p" "$1" | head -n 1; }

conf() {
  local key=$1 envval=$2 default=${3:-}
  if [ -n "$envval" ]; then printf '%s\n' "$envval"; return; fi
  local v
  v=$(kv "$(config_dir)/storage.conf" "$key")
  printf '%s\n' "${v:-$default}"
}

load_conf() {
  NOTIFY=$(conf notify "${FM_STORAGE_NOTIFY:-}")
  MIN_FREE=$(to_bytes "$(conf min_free "${FM_STORAGE_MIN_FREE:-}" 50G)") || die "min_free is not a size"
  MIN_SIZE=$(to_bytes "$(conf min_size "${FM_STORAGE_MIN_SIZE:-}" 1500000000000)") || die "min_size is not a size"
}

# root_dir ROOT -> its directory name under lattice-data, or fail when unknown.
root_dir() {
  case "$1" in
    tetjet-results|research) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

valid_template() { case "$1" in /*'{task}'*) return 0 ;; *) return 1 ;; esac; }

# write_atomic FILE < content
write_atomic() {
  local f=$1 tmp
  mkdir -p "$(dirname "$f")" || return 1
  tmp=$(mktemp "$f.tmp.XXXXXX") || return 1
  if ! { cat >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$f"; }; then
    rm -f "$tmp"
    return 1
  fi
}

powershell_bin() {
  if [ -n "${FM_STORAGE_POWERSHELL:-}" ]; then
    [ -x "$FM_STORAGE_POWERSHELL" ] || return 1
    printf '%s' "$FM_STORAGE_POWERSHELL"
    return 0
  fi
  command -v powershell.exe 2>/dev/null && return 0
  [ -x "$PS_DIR/powershell.exe" ] && { printf '%s' "$PS_DIR/powershell.exe"; return 0; }
  return 1
}

# windows_listing -> VOL|letter|fstype|fs|drivetype|size|free|uniqueid|label
# and DISK|number|bus|partstyle|size|isboot|issystem lines, ending with END.
# WSL interop can fail transiently under load (UtilAcceptVsock timeouts), so a
# call that errors, times out, or lacks the END sentinel is retried after each
# FM_STORAGE_PS_BACKOFF delay; the last attempt's output is returned.
windows_listing() {
  local out delay
  out=$(windows_listing_once)
  for delay in ${FM_STORAGE_PS_BACKOFF-5 15}; do
    printf '%s\n' "$out" | grep -qx END && break
    sleep "$delay"
    out=$(windows_listing_once)
  done
  printf '%s\n' "$out"
}

windows_listing_once() {
  local ps
  ps=$(powershell_bin) || return 1
  # shellcheck disable=SC2016
  timeout "$PS_TIMEOUT" "$ps" -NoProfile -NonInteractive -Command '$ErrorActionPreference="Stop"; Get-Volume | ForEach-Object { "VOL|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f $_.DriveLetter,$_.FileSystemType,$_.FileSystem,$_.DriveType,$_.Size,$_.SizeRemaining,$_.UniqueId,$_.FileSystemLabel }; Get-Disk | ForEach-Object { "DISK|{0}|{1}|{2}|{3}|{4}|{5}" -f $_.Number,$_.BusType,$_.PartitionStyle,$_.Size,$_.IsBoot,$_.IsSystem }; "END"' 2>/dev/null \
    | tr -d '\r'
}

is_mounted() { awk -v mp="$1" '$5 == mp { found = 1 } END { exit !found }' "${FM_STORAGE_MOUNTINFO:-/proc/self/mountinfo}" 2>/dev/null; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# detect: sets STATE (empty when a usable candidate was found), REASON, the
# SSD_* fields for the chosen volume, and LISTING (the Windows answer).
detect() {
  local kind letter fstype fs dtype size free uid label num bus pstyle isboot issys
  local cands=() c remembered pick='' bigdisk=''
  STATE='' REASON='' SSD_LETTER='' SSD_FS='' SSD_SIZE='' SSD_FREE='' SSD_ID='' SSD_LABEL=''
  LISTING=$(windows_listing)
  if ! printf '%s\n' "$LISTING" | grep -qx END; then
    STATE=unreadable REASON="could not list Windows volumes (powershell.exe failed or timed out)"
    return
  fi
  remembered=$(kv "$(config_dir)/ssd-identity" uniqueid)
  while IFS='|' read -r kind letter fstype fs dtype size free uid label; do
    [ "$kind" = VOL ] || continue
    case "$letter" in [D-Zd-z]) ;; *) continue ;; esac
    case "$dtype" in Fixed|Removable) ;; *) continue ;; esac
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -ge "$MIN_SIZE" ] || continue
    c="$letter|$fstype|$fs|$size|$free|$uid|$label"
    cands+=("$c")
    [ -n "$remembered" ] && [ "$uid" = "$remembered" ] && pick=$c
  done <<<"$LISTING"
  if [ -z "$pick" ]; then
    if [ "${#cands[@]}" -eq 1 ]; then
      pick=${cands[0]}
    elif [ "${#cands[@]}" -gt 1 ]; then
      STATE=ambiguous REASON="${#cands[@]} large volumes and none is the remembered SSD; nothing picked"
      return
    fi
  fi
  if [ -z "$pick" ]; then
    while IFS='|' read -r kind num bus pstyle size isboot issys; do
      [ "$kind" = DISK ] || continue
      [ "$isboot" = True ] || [ "$issys" = True ] && continue
      case "$size" in ''|*[!0-9]*) continue ;; esac
      [ "$size" -ge "$MIN_SIZE" ] && bigdisk="disk $num ($bus, $(tib "$size"), partition style $pstyle)"
    done <<<"$LISTING"
    if [ -n "$bigdisk" ]; then
      STATE=raw REASON="$bigdisk has no lettered NTFS or exFAT volume; formatting needs the captain; nothing written"
    else
      STATE=absent REASON="no SSD found in Windows"
    fi
    return
  fi
  IFS='|' read -r SSD_LETTER fstype fs SSD_SIZE SSD_FREE SSD_ID SSD_LABEL <<<"$pick"
  SSD_LETTER=$(printf '%s' "$SSD_LETTER" | tr '[:lower:]' '[:upper:]')
  case "$(lower "$fs"),$(lower "$fstype")" in
    ntfs,*|*,ntfs) SSD_FS=NTFS ;;
    exfat,*|*,exfat) SSD_FS=exFAT ;;
    *)
      SSD_FS=${fs:-${fstype:-unknown}}
      STATE=raw REASON="SSD $SSD_LETTER: ($(tib "$SSD_SIZE")) filesystem is ${SSD_FS} (RAW, unformatted or unsupported); formatting needs the captain; nothing written"
      return
      ;;
  esac
}

cmd_detect() {
  load_conf
  detect
  if [ -n "$SSD_LETTER" ]; then
    printf 'candidate: %s: %s, %s total, %s free, id %s, label %s\n' "$SSD_LETTER" "$SSD_FS" \
      "$(tib "$SSD_SIZE")" "$(tib "${SSD_FREE:-0}")" "$SSD_ID" "${SSD_LABEL:-none}"
  fi
  printf 'state: %s%s\n' "${STATE:-usable}" "${REASON:+ - $REASON}"
}

# mount_dead MP: 0 when MP is listed but a bounded stat fails with a dead-mount
# error (ENODEV or ENOTCONN), as a drvfs mount does after its device dropped
# out under it; a healthy, slow or otherwise failing mount is not dead.
mount_dead() {
  local err
  err=$(LC_ALL=C timeout 10 "${FM_STORAGE_MOUNT_PROBE:-stat}" -- "$1" 2>&1 >/dev/null) && return 1
  case "$err" in *'No such device'*|*'Transport endpoint is not connected'*) return 0 ;; esac
  return 1
}

# mount_ssd MP: 0 when MP is mounted and answers afterwards. A listed mount
# that answers is used as is; a dead one is released with umount -l and
# mounted again through the same rule. Sets STATE and REASON on failure.
mount_ssd() {
  local mp=$1 l dead=''
  if is_mounted "$mp"; then
    mount_dead "$mp" || return 0
    dead=1
  fi
  l=$(lower "$SSD_LETTER")
  case "$l" in [d-h]) ;; *)
    STATE=${dead:+stale-mount} REASON="SSD is $SSD_LETTER:, outside the mount rule's letters D to H${dead:+, and $mp is a dead mount}"
    return 1 ;;
  esac
  if [ -n "$dead" ] && { ! sudo -n /usr/bin/umount -l "$mp" >/dev/null 2>&1 || is_mounted "$mp"; }; then
    STATE=stale-mount REASON="SSD $SSD_LETTER: is in Windows but $mp is a dead mount and releasing it with umount -l was refused"
    return 1
  fi
  if ! sudo -n /usr/bin/mount -t drvfs "$SSD_LETTER:" "$mp" -o "uid=$(id -u),gid=$(id -g)" >/dev/null 2>&1 || ! is_mounted "$mp"; then
    if [ -n "$dead" ]; then
      STATE=stale-mount REASON="SSD $SSD_LETTER: is in Windows; the dead mount $mp was released but mounting it again was refused"
    else
      STATE=not-mounted REASON="SSD $SSD_LETTER: is in Windows but not mounted in WSL; restart the laptop with the SSD plugged in, or see the mount rule section in docs/storage.md"
    fi
    return 1
  fi
  if [ -n "$dead" ] && mount_dead "$mp"; then
    STATE=stale-mount REASON="SSD $SSD_LETTER: is in Windows but $mp still fails with a dead-mount error after mounting it again"
    return 1
  fi
}

# speed_test DIR -> MiB/s on stdout, or fail.
speed_test() {
  local dir=$1 size count start end f
  size=$(to_bytes "${FM_STORAGE_SPEED_SIZE:-1G}") || return 1
  count=$(( size / 1048576 )); [ "$count" -ge 1 ] || count=1
  f="$dir/.speedtest.$$"
  start=$(date +%s%N)
  if ! timeout 600 nice -n 19 ionice -c3 dd if=/dev/zero of="$f" bs=1M count="$count" conv=fdatasync status=none 2>/dev/null; then
    rm -f "$f"; return 1
  fi
  end=$(date +%s%N)
  rm -f "$f"
  awk -v c="$count" -v ns=$(( end - start )) 'BEGIN { if (ns <= 0) ns = 1; printf "%.0f\n", c / (ns / 1e9) }'
}

# setup_and_probe MP: folders, marker, identity and speed (first time only),
# then the write probe. Sets STATE/REASON on failure.
setup_and_probe() {
  local mp=$1 data ident marker old speed
  data="$mp/lattice-data"
  marker="$data/.lattice-storage-id"
  ident="$(config_dir)/ssd-identity"
  if [ -e "$marker" ]; then
    old=$(head -n 1 "$marker" 2>/dev/null)
    if [ "$old" != "$SSD_ID" ]; then
      STATE=ambiguous REASON="the marker on $SSD_LETTER: names another volume ($old); nothing picked"
      return 1
    fi
  fi
  if ! mkdir -p "$data/tetjet-results" "$data/research" "$data/archive" 2>/dev/null; then
    STATE=unwritable REASON="could not create the folders on $SSD_LETTER:"
    return 1
  fi
  if [ ! -e "$marker" ]; then
    printf '%s\n' "$SSD_ID" | write_atomic "$marker" || { STATE=unwritable REASON="could not write the marker on $SSD_LETTER:"; return 1; }
  fi
  if [ "$(kv "$ident" uniqueid)" != "$SSD_ID" ] || case "$(kv "$ident" write_mib_s)" in ''|unknown) true ;; *) false ;; esac; then
    speed=$(speed_test "$data") || speed=unknown
    printf 'uniqueid=%s\nletter=%s\nfs=%s\nlabel=%s\nsetup_at=%s\nwrite_mib_s=%s\n' \
      "$SSD_ID" "$SSD_LETTER" "$SSD_FS" "$SSD_LABEL" "$(now)" "$speed" | write_atomic "$ident" \
      || { STATE=unwritable REASON="could not record the SSD identity"; return 1; }
  fi
  if ! { : >"$data/.probe.$$" && rm -f "$data/.probe.$$"; } 2>/dev/null; then
    STATE=unwritable REASON="write probe on $SSD_LETTER: failed"
    return 1
  fi
}

publish() {
  local line1 mp=$1
  if [ "$STATE" = ok ]; then line1="$mp/lattice-data/tetjet-results/{task}"; else line1=unavailable; fi
  {
    printf '%s\nformat=%s\nactive=%s\nstate=%s\nreason=%s\nchecked_at=%s\n' \
      "$line1" "$FORMAT" "$([ "$STATE" = ok ] && echo ssd || echo c)" "$STATE" "$REASON" "$(now)"
    if [ -n "$SSD_LETTER" ]; then
      printf 'ssd_letter=%s\nssd_id=%s\nssd_fs=%s\nssd_free_bytes=%s\nssd_total_bytes=%s\n' \
        "$SSD_LETTER" "$SSD_ID" "$SSD_FS" "$SSD_FREE" "$SSD_SIZE"
      if [ "$STATE" = ok ]; then
        printf 'ssd_marker=%s\narchive=%s\n' "$mp/lattice-data/.lattice-storage-id" "$mp/lattice-data/archive"
        printf 'ssd_device=%s\n' "$(stat -c %d -- "$mp" 2>/dev/null)"
        [ -n "$IDENTITY" ] && printf 'ssd_identity=%s\n' "$IDENTITY"
      fi
    fi
    [ -n "$SSD_LETTER" ] && printf 'write_mib_s=%s\n' "$(kv "$(config_dir)/ssd-identity" write_mib_s)"
  } | write_atomic "$(config_dir)/results-root" || die "could not write $(config_dir)/results-root"
  LINE1=$line1
}

notify() {
  local key last lastf
  key="$STATE${SSD_LETTER:+ $SSD_LETTER}"
  lastf="$(state_dir)/last-state"
  last=$(cat "$lastf" 2>/dev/null || true)
  [ "$key" = "$last" ] && return 0
  # The very first reading of an absent SSD is the baseline, not news.
  if [ -n "$last" ] || [ "$STATE" != absent ]; then
    if [ -n "$NOTIFY" ]; then
      if [ "$STATE" = ok ]; then
        printf 'note [at=%s]: SSD storage %s: %s; fetched results go to %s\n' "$(now)" "$STATE" "$REASON" "$LINE1" >>"$NOTIFY" || return 0
      else
        printf 'note [at=%s]: SSD storage %s: %s; fetched-result writers wait until it is usable\n' "$(now)" "$STATE" "$REASON" >>"$NOTIFY" || return 0
      fi
    fi
  fi
  printf '%s\n' "$key" | write_atomic "$lastf" || true
}

run_check() {
  local mp='' lock
  IDENTITY=''
  load_conf
  mkdir -p "$(state_dir)" || die "cannot create $(state_dir)"
  lock="$(state_dir)/lock"
  exec 9>"$lock"
  flock -w 60 9 || die "another check holds $lock"
  detect
  if [ "$STATE" = unreadable ] && ! marker_identity; then
    keep_last_readable && return 0
  else
    rm -f "$(state_dir)/unreadable-runs"
  fi
  if [ -z "$STATE" ]; then
    mp="$(mnt_base)/$(lower "$SSD_LETTER")"
    if [ "$SSD_FREE" -lt "$MIN_FREE" ] 2>/dev/null; then
      STATE=full REASON="SSD $SSD_LETTER: has $(tib "$SSD_FREE") free, under the $(tib "$MIN_FREE") minimum"
    elif ! mount_ssd "$mp"; then
      STATE=${STATE:-not-mounted}
    elif setup_and_probe "$mp"; then
      STATE=ok REASON="SSD $SSD_LETTER: $SSD_FS, $(tib "$SSD_FREE") free${IDENTITY:+; identity from the marker (Windows listing failed)}"
    fi
  else
    release_stale
  fi
  publish "$mp"
  notify
  printf 'results root: %s (%s: %s)\n' "$LINE1" "$STATE" "$REASON"
}

# marker_identity: with the Windows listing unreadable, prove the remembered
# SSD from WSL alone: its mount is present, the marker names the remembered
# volume id, the mount's device is the published ssd_device, and a write probe
# succeeds. On success sets the SSD_* fields (free and total from statfs),
# IDENTITY=marker and an empty STATE; otherwise appends the failed check to
# REASON and changes nothing else.
marker_identity() {
  local ident l mp data uid fs dev why='' st bs
  ident="$(config_dir)/ssd-identity"
  uid=$(kv "$ident" uniqueid); fs=$(kv "$ident" fs); l=$(lower "$(kv "$ident" letter)")
  mp="$(mnt_base)/$l"; data="$mp/lattice-data"
  dev=$(kv "$(config_dir)/results-root" ssd_device)
  if [ -z "$uid" ] || [ -z "$fs" ] || [ -z "$l" ]; then
    why="no remembered SSD"
  elif ! is_mounted "$mp"; then
    why="$mp is not mounted"
  elif [ "$(head -n 1 "$data/.lattice-storage-id" 2>/dev/null)" != "$uid" ]; then
    why="the marker on $mp is missing or names another volume"
  elif [ -z "$dev" ] || [ "$(stat -c %d -- "$mp" 2>/dev/null)" != "$dev" ]; then
    why="the device of $mp is not the published ssd_device"
  elif ! { : >"$data/.probe.$$" && rm -f "$data/.probe.$$"; } 2>/dev/null; then
    why="write probe on $mp failed"
  elif ! st=$(stat -f -c '%a %b %S' -- "$mp" 2>/dev/null) || ! read -r SSD_FREE SSD_SIZE bs <<<"$st"; then
    why="could not read the free space of $mp"
  fi
  if [ -n "$why" ]; then
    SSD_FREE='' SSD_SIZE=''
    REASON="$REASON; marker check failed: $why"
    return 1
  fi
  SSD_FREE=$(( SSD_FREE * bs )) SSD_SIZE=$(( SSD_SIZE * bs ))
  SSD_LETTER=$(printf '%s' "$(kv "$ident" letter)" | tr '[:lower:]' '[:upper:]')
  SSD_ID=$uid SSD_FS=$fs SSD_LABEL=$(kv "$ident" label) IDENTITY=marker STATE='' REASON=''
}

# keep_last_readable: count this unreadable check; while fewer than
# UNREADABLE_LIMIT consecutive checks have failed and a readable state is
# published, leave that state, its root and last-state untouched (no note).
# Fails when unreadable should be published now.
keep_last_readable() {
  local f runs last
  f="$(state_dir)/unreadable-runs"
  runs=$(cat "$f" 2>/dev/null)
  case "$runs" in ''|*[!0-9]*) runs=0 ;; esac
  runs=$(( runs + 1 ))
  printf '%s\n' "$runs" | write_atomic "$f" || true
  [ "$runs" -lt "$UNREADABLE_LIMIT" ] || return 1
  f="$(config_dir)/results-root"
  [ "$(sed -n 2p "$f" 2>/dev/null)" = "format=$FORMAT" ] || return 1
  last=$(kv "$f" state)
  case "$last" in ''|unreadable) return 1 ;; esac
  printf 'results root: %s (kept %s: Windows listing failed, %s of %s consecutive checks)\n' \
    "$(head -n 1 "$f")" "$last" "$runs" "$UNREADABLE_LIMIT"
}

# release_stale: the remembered SSD is gone from Windows but its WSL mount
# remains; release it lazily when the rule allows, unless another Windows
# volume now holds that letter.
release_stale() {
  local l mp
  [ "$STATE" = absent ] || return 0
  l=$(lower "$(kv "$(config_dir)/ssd-identity" letter)")
  case "$l" in [d-h]) ;; *) return 0 ;; esac
  printf '%s\n' "$LISTING" | awk -F'|' -v l="$l" '$1 == "VOL" && tolower($2) == l { found = 1 } END { exit !found }' && return 0
  mp="$(mnt_base)/$l"
  is_mounted "$mp" || return 0
  if sudo -n /usr/bin/umount -l "$mp" >/dev/null 2>&1 && ! is_mounted "$mp"; then
    REASON="SSD removed; its stale WSL mount was released"
  else
    STATE=stale-mount REASON="SSD removed but $mp is still mounted and could not be released"
  fi
}

cmd_status() {
  local f age active
  f="$(config_dir)/results-root"
  [ -r "$f" ] || { printf 'results root: not published yet (no %s); writers wait\n' "$f"; return 0; }
  active=$(kv "$f" active)
  age=$(( $(now) - $(kv "$f" checked_at || echo 0) ))
  printf 'results root: %s (%s, state %s, checked %s s ago)\n' "$(head -n 1 "$f")" \
    "$([ "$active" = ssd ] && echo SSD || echo 'none, writers wait')" "$(kv "$f" state)" "$age"
  printf 'reason: %s\n' "$(kv "$f" reason)"
  if [ -n "$(kv "$f" ssd_letter)" ]; then
    printf 'SSD %s: %s, %s free of %s, write speed %s MiB/s\n' "$(kv "$f" ssd_letter)" "$(kv "$f" ssd_fs)" \
      "$(tib "$(kv "$f" ssd_free_bytes)")" "$(tib "$(kv "$f" ssd_total_bytes)")" "$(kv "$f" write_mib_s)"
  fi
}

# root keeps the legacy reader rules for its answer, but any doubt is a wait
# (exit 75 with one reason), never a C: or Linux path.
cmd_root() {
  local task='{task}' f line1 checked root=tetjet-results
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ "$#" -ge 2 ] || die "--root needs a ROOT"; root=$2; shift 2 ;;
      -*) die "unknown option $1" ;;
      *) task=$1; shift ;;
    esac
  done
  root_dir "$root" >/dev/null || die "unknown root $root (known: tetjet-results, research)"
  if [ "$root" != tetjet-results ]; then
    case "$task" in '{task}') ;; ''|.|..|*[!A-Za-z0-9._-]*) die "invalid TASK" ;; esac
    cmd_verify_bulk_root --root "$root" "$task"
    return
  fi
  f="$(config_dir)/results-root"
  [ -r "$f" ] || { bulk_wait missing-publication; return 75; }
  [ "$(sed -n 2p "$f")" = "format=$FORMAT" ] || { bulk_wait invalid-publication; return 75; }
  [ "$(kv "$f" active)" = ssd ] && [ "$(kv "$f" state)" = ok ] || {
    bulk_wait "storage-unavailable: $(kv "$f" state): $(kv "$f" reason)"; return 75;
  }
  line1=$(head -n 1 "$f")
  valid_template "$line1" || { bulk_wait wrong-root; return 75; }
  checked=$(kv "$f" checked_at)
  case "$checked" in ''|*[!0-9]*) bulk_wait stale-publication; return 75 ;; esac
  [ "${#checked}" -le 10 ] && [ $(( $(now) - 10#$checked )) -le "${FM_STORAGE_MAX_AGE:-1800}" ] || {
    bulk_wait stale-publication; return 75;
  }
  [ -e "$(kv "$f" ssd_marker)" ] || { bulk_wait missing-marker; return 75; }
  printf '%s\n' "${line1//\{task\}/$task}"
}

# Bulk verification is read-only: no mount, setup, probe, or fallback writes.
bulk_wait() { printf 'fm-storage: wait: %s\n' "$*" >&2; return 75; }

cmd_verify_bulk_root() {
  local task='' root=tetjet-results dir f mp marker uid checked age device actual rootdev hostdev cand mount
  if [ "${1:-}" = --root ]; then
    [ "$#" -ge 2 ] || die "--root needs a ROOT"
    root=$2; shift 2
  fi
  [ "$#" -le 1 ] || die "verify-bulk-root takes one TASK"
  task=${1:-'{task}'}
  dir=$(root_dir "$root") || die "unknown root $root (known: tetjet-results, research)"
  case "$task" in '{task}') ;; ''|.|..|*[!A-Za-z0-9._-]*) die "invalid TASK" ;; esac
  f=${FM_STORAGE_RESULTS_ROOT:-$(config_dir)/results-root}
  [ -r "$f" ] || { bulk_wait missing-publication; return 75; }
  [ "$(sed -n 2p "$f")" = "format=$FORMAT" ] || { bulk_wait invalid-publication; return 75; }
  [ "$(kv "$f" active)" = ssd ] && [ "$(kv "$f" state)" = ok ] || {
    bulk_wait "storage-unavailable: $(kv "$f" state): $(kv "$f" reason)"; return 75;
  }
  [ "$(kv "$f" ssd_letter)" = D ] || { bulk_wait wrong-volume; return 75; }
  case "$(kv "$f" ssd_fs)" in NTFS|exFAT) ;; *) bulk_wait wrong-filesystem; return 75 ;; esac
  checked=$(kv "$f" checked_at); age=${FM_STORAGE_MAX_AGE:-1800}
  case "$checked:$age" in *[!0-9:]*|:*|*:) bulk_wait stale-publication; return 75 ;; esac
  [ "${#checked}" -le 10 ] && [ "${#age}" -le 10 ] || { bulk_wait stale-publication; return 75; }
  checked=$((10#$checked)); age=$((10#$age))
  [ "$(now)" -ge "$checked" ] && [ $(( $(now) - checked )) -le "$age" ] || {
    bulk_wait stale-publication; return 75;
  }
  mp="$(mnt_base)/d"
  cand=$(head -n 1 "$f")
  [ "$cand" = "$mp/lattice-data/tetjet-results/{task}" ] &&
    [ "$(realpath -e -- "$mp/lattice-data/$dir" 2>/dev/null)" = "$mp/lattice-data/$dir" ] || {
    bulk_wait wrong-root; return 75;
  }
  marker=$(kv "$f" ssd_marker); uid=$(kv "$f" ssd_id)
  [ "$marker" = "$mp/lattice-data/.lattice-storage-id" ] && [ -r "$marker" ] || {
    bulk_wait missing-marker; return 75;
  }
  [ -n "$uid" ] && [ "$(head -n 1 "$marker" 2>/dev/null)" = "$uid" ] &&
    [ "$(kv "$(config_dir)/ssd-identity" uniqueid)" = "$uid" ] || {
    bulk_wait wrong-volume-identity; return 75;
  }
  # A letter-shaped directory or a copied marker on Linux is not a volume.
  mount=$(awk -v mp="$mp" '$5 == mp { for (i=7; i<=NF; i++) if ($i == "-") print $(i+1) "|" $(i+2) }' \
    "${FM_STORAGE_MOUNTINFO:-/proc/self/mountinfo}" 2>/dev/null)
  case "$mount" in '9p|D:'|'9p|D:\134'|'drvfs|D:'|'drvfs|D:\134') ;;
    *) bulk_wait wrong-mount-identity; return 75 ;; esac
  device=$(kv "$f" ssd_device)
  actual=$(stat -c %d -- "$mp/lattice-data/$dir" 2>/dev/null)
  rootdev=$(stat -c %d -- / 2>/dev/null)
  hostdev=$(stat -c %d -- "${FM_DISK_ROOM_HOST:-/mnt/c}" 2>/dev/null || true)
  [ -n "$device" ] && [ "$actual" = "$device" ] && [ "$actual" != "$rootdev" ] &&
    [ "$actual" != "$hostdev" ] || { bulk_wait wrong-filesystem-identity; return 75; }
  printf '%s\n' "$mp/lattice-data/$dir/$task"
}

# Another root shares the D: filesystem, so it is admitted in the same D:
# reservation pool and prints its own verified directory instead.
cmd_bulk_root() {
  local task name='' root=tetjet-results out
  if [ "${1:-}" = --root ]; then
    [ "$#" -ge 2 ] || die "--root needs a ROOT"
    root=$2; shift 2
  fi
  root_dir "$root" >/dev/null || die "unknown root $root (known: tetjet-results, research)"
  task=${1:-}
  [ "$#" -gt 0 ] || die "bulk-root needs TASK"
  shift
  [ "${1:-}" = --name ] && [ "$#" -ge 2 ] || die "bulk-root needs --name NAME"
  name=$2; shift 2
  if [ "$root" = tetjet-results ]; then
    "$(dirname "${BASH_SOURCE[0]}")/fm-disk-room.sh" reserve-bulk "$name" --task "$task" "$@"
    return
  fi
  out=$(cmd_verify_bulk_root --root "$root" "$task") || return "$?"
  "$(dirname "${BASH_SOURCE[0]}")/fm-disk-room.sh" reserve-bulk "$name" --task "$task" "$@" >/dev/null || return "$?"
  printf '%s\n' "$out"
}

# fm-storage/v2 ---------------------------------------------------------------
# The v2 verbs read the class map only through fm-storage-roots.py and admit
# only through fm-disk-room.sh's token admissions. docs/storage.md
# "fm-storage/v2" owns the contract.

V2_INTERFACE=fm-storage/v2

v2_say() {
  local detail=${3//[^[:print:]]/?}
  printf 'fm-storage: %s: %s: %s\n' "$1" "$2" "${detail:0:300}" >&2
  [ "$1" = wait ] && return 75
  [ "$2" = owner-state ] && return 1
  return 2
}

cmd_interface() {
  [ "$#" -eq 0 ] || { v2_say refused invalid-argument "--interface takes no operand"; return; }
  printf '%s\n' "$V2_INTERFACE"
}

# v2_site: run site-config for this host (uname -n, which the class map names
# as a host id or alias). On 0 V2_SITE holds the roots object; on a wait (75)
# or refusal (2) V2_KIND, V2_CODE and V2_DETAIL hold its line, unprinted.
v2_site() {
  local here out rc line
  V2_SITE='' V2_KIND='' V2_CODE='' V2_DETAIL=''
  here=$(uname -n 2>/dev/null) || here=''
  out=$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/fm-storage-roots.py" site-config --here "$here" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then V2_SITE=$out; return 0; fi
  line=${out%%$'\n'*}
  case "$rc:$line" in
    '75:fm-storage: wait: '*?': '*) V2_KIND='wait' ;;
    '2:fm-storage: refused: '*?': '*) V2_KIND='refused' ;;
    *) V2_KIND=refused V2_CODE=owner-state V2_DETAIL="site-config failed with exit $rc: $line"; return 1 ;;
  esac
  line=${line#fm-storage: "$V2_KIND": }
  V2_CODE=${line%%: *} V2_DETAIL=${line#*: }
  return "$rc"
}

# reserve: resolve --class to its root through the class map, check the root's
# volume is --volume, then admit through fm-disk-room.sh reserve-token, which
# validates every other argument and owns the charge.
cmd_reserve() {
  local volume='' class='' where root rc
  local -a args=("$@")
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --volume|--class|--name|--bytes|--pid) [ "$#" -ge 2 ] || break
        case "$1" in --volume) volume=$2 ;; --class) class=$2 ;; esac
        shift 2 ;;
      *) shift ;;
    esac
  done
  case "$volume" in linux|host-c|d) ;; *) v2_say refused invalid-argument "--volume must be linux, host-c or d"; return ;; esac
  where="$volume:$class"
  v2_site; rc=$?
  [ "$rc" -eq 0 ] || { v2_say "$V2_KIND" "$V2_CODE" "$where: $V2_DETAIL"; return; }
  root=$(printf '%s\n' "$V2_SITE" | jq -r --arg c "$class" --arg v "$volume" '
    .classes[$c] as $r | if $r == null then "unknown-class"
    else .roots[$r] | if .transport != "local" then "remote" elif .volume != $v then "volume \(.volume)"
      else "ok \(.path)" end end' 2>/dev/null)
  case "$root" in
    'ok /'*) root=${root#ok } ;;
    unknown-class) v2_say refused unknown-class "$where: the class map binds no class $class"; return ;;
    'volume '*) v2_say refused wrong-volume "$where: class $class is bound to a root on ${root#volume }"; return ;;
    remote) v2_say refused remote-unproven "$where: class $class is bound to a root on another host"; return ;;
    *) v2_say refused owner-state "$where: cannot read the site roots"; return ;;
  esac
  exec "$(dirname "${BASH_SOURCE[0]}")/fm-disk-room.sh" reserve-token --root "$root" "${args[@]}"
}

# status --json: the class map digest, fm-disk-room.sh admission-status's
# reading of every pool, and any site-config wait as one more reason. The
# owner's wait or refusal line passes through on stderr; status writes nothing.
cmd_status_json() {
  local map sha t out rc state reason=''
  [ "$#" -eq 0 ] || { v2_say refused invalid-argument "status --json takes no operand"; return; }
  command -v jq >/dev/null 2>&1 || { v2_say refused owner-state "jq is not installed"; return; }
  t=$(now)
  case "$t" in ''|*[!0-9]*|????????????????*) v2_say refused owner-state "bad clock reading $t"; return ;; esac
  v2_site; rc=$?
  case "$rc" in
    0) ;;
    75) reason=$(jq -cn --arg c "$V2_CODE" --arg d "$V2_DETAIL" '[{code: $c, volume: null, term: null, detail: $d}]') ;;
    *) v2_say "$V2_KIND" "$V2_CODE" "$V2_DETAIL"; return ;;
  esac
  map="$(config_dir)/class-map.json"
  if command -v sha256sum >/dev/null 2>&1; then sha=$(sha256sum <"$map" 2>/dev/null)
  else sha=$(shasum -a 256 <"$map" 2>/dev/null); fi
  sha=${sha%% *}
  case "$sha" in *[!0-9a-f]*|'') v2_say refused owner-state "cannot hash $map"; return ;; esac
  [ "${#sha}" -eq 64 ] || { v2_say refused owner-state "cannot hash $map"; return; }
  out=$("$(dirname "${BASH_SOURCE[0]}")/fm-disk-room.sh" admission-status --json)
  rc=$?
  case "$rc" in
    0) state=ok; [ -z "$reason" ] || state=waiting ;;
    75) state=waiting ;;
    1|2) state=refused ;;
    *) v2_say refused owner-state "admission-status failed with exit $rc"; return ;;
  esac
  [ -n "$out" ] && out=$(printf '%s\n' "$out" | jq -c --argjson t "$t" --arg sha "$sha" --arg state "$state" --argjson extra "${reason:-[]}" '
    select(.schema == "fm-disk-room-admission-status/v1")
    | {interface: "fm-storage/v2", sampled_at: $t, state: $state, class_map_sha256: $sha,
       volumes: .volumes, c_terms: .c_terms, reasons: (.reasons + $extra)}' 2>/dev/null)
  if [ -z "$out" ]; then
    [ "$rc" -eq 0 ] || return "$rc"
    v2_say refused owner-state "admission-status printed no readable object"; return
  fi
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] && [ -n "$reason" ] && { v2_say wait "$V2_CODE" "$V2_DETAIL"; return; }
  return "$rc"
}

UNIT=fm-storage

cmd_install_timer() {
  local nf='' dir self k v
  while [ $# -gt 0 ]; do
    case "$1" in
      --fallback) die "--fallback was removed: writers wait when the SSD is unavailable, never fall back" ;;
      --notify) nf=${2:-}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  {
    [ -n "$nf" ] && printf 'notify=%s\n' "$nf"
    for k in min_free min_size; do
      v=$(kv "$(config_dir)/storage.conf" "$k")
      [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
    done
  } | write_atomic "$(config_dir)/storage.conf" || die "could not write storage.conf"
  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$dir" || die "cannot create $dir"
  printf '[Unit]\nDescription=Publish the fetched-results root on the external SSD\n\n[Service]\nType=oneshot\nNice=19\nIOSchedulingClass=idle\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin:%s\nExecStart=%s check\n' "$PS_DIR" "$self" \
    | write_atomic "$dir/$UNIT.service" || die "could not write $dir/$UNIT.service"
  printf '[Unit]\nDescription=Check the external SSD every 5 minutes\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=5min\nAccuracySec=30s\n\n[Install]\nWantedBy=timers.target\n' \
    | write_atomic "$dir/$UNIT.timer" || die "could not write $dir/$UNIT.timer"
  printf 'wrote %s/storage.conf, %s/%s.service and %s.timer\n' "$(config_dir)" "$dir" "$UNIT" "$UNIT"
  command -v systemctl >/dev/null 2>&1 \
    || die "systemctl not found; enable later with: systemctl --user daemon-reload && systemctl --user enable --now $UNIT.timer"
  if ! { systemctl --user daemon-reload && systemctl --user enable --now "$UNIT.timer"; }; then
    die "could not enable $UNIT.timer"
  fi
  printf 'enabled %s.timer\n' "$UNIT"
}

cmd_uninstall_timer() {
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  command -v systemctl >/dev/null 2>&1 && systemctl --user disable --now "$UNIT.timer" 2>/dev/null
  rm -f "$dir/$UNIT.service" "$dir/$UNIT.timer"
  command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null
  printf 'removed %s.timer and %s.service from %s\n' "$UNIT" "$UNIT" "$dir"
}

case "${1:-}" in
  detect) cmd_detect ;;
  check) run_check ;;
  setup) run_check && cmd_status ;;
  status) if [ "${2:-}" = --json ]; then shift 2; cmd_status_json "$@"; else cmd_status; fi ;;
  root) shift; cmd_root "$@" ;;
  verify-bulk-root) shift; cmd_verify_bulk_root "$@" ;;
  bulk-root) shift; cmd_bulk_root "$@" ;;
  --interface) shift; cmd_interface "$@" ;;
  reserve) shift; cmd_reserve "$@" ;;
  release) shift; exec "$(dirname "${BASH_SOURCE[0]}")/fm-disk-room.sh" release-token "$@" ;;
  site-config|health) exec python3 -I "$(dirname "${BASH_SOURCE[0]}")/fm-storage-roots.py" "$@" ;;
  install-timer) shift; cmd_install_timer "$@" ;;
  uninstall-timer) cmd_uninstall_timer ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command $1 (see --help)" ;;
esac
