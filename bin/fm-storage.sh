#!/usr/bin/env bash
# fm-storage.sh - put fetched results on an external SSD when one is usable,
# and publish that choice (with a C: fallback) in one machine-local file that
# every fetcher reads. docs/storage.md owns the results-root file format
# (lattice-storage-results-root/v1), the states, and the reader rules.
#
# Usage:
#   fm-storage.sh detect
#       Read Windows volumes and disks (no admin, no writes) and print the
#       candidate SSD and the state a check would reach before mounting.
#   fm-storage.sh check
#       The periodic entry point: detect, mount through the narrow sudoers
#       rule when needed (sudo -n only; a refusal is state not-mounted), set up
#       the folder layout and measure write speed once, probe, then write the
#       results-root file atomically and notify on a state change.
#       The Windows listing is tried up to 3 times; a check that still cannot
#       read it keeps the last readable published state until 3 consecutive
#       checks have failed, then publishes unreadable. Prints one line.
#   fm-storage.sh setup
#       Run check now, then print status.
#   fm-storage.sh status
#       Print the published choice from the results-root file (no Windows call).
#   fm-storage.sh root [TASK]
#       Apply the reader rules and print the directory to use: the template
#       with {task} replaced by TASK (kept as {task} when TASK is omitted).
#       Falls back to the C: template on any doubt.
#   fm-storage.sh install-timer --fallback TEMPLATE [--notify FILE]
#       Write storage.conf (fallback template and notification file), then
#       write and enable the user-level fm-storage.timer (every 5 minutes,
#       Nice=19, idle IO). No root.
#   fm-storage.sh uninstall-timer
#       Disable and remove that timer; the config and results-root stay.
#
# Files (config dir ${XDG_CONFIG_HOME:-~/.config}/lattice-storage):
#   results-root   the published file (docs/storage.md)
#   storage.conf   key=value: fallback, notify, min_free, min_size
#   ssd-identity   key=value: uniqueid, letter, fs, label, setup_at, write_mib_s
# State dir ${XDG_STATE_HOME:-~/.local/state}/fm-storage: last-state, lock,
#   unreadable-runs (consecutive checks whose listing failed; removed on success).
#
# Environment (all optional; each overrides storage.conf):
#   FM_STORAGE_FALLBACK  C: results template containing {task}
#   FM_STORAGE_NOTIFY    status file that receives one note line per state change
#   FM_STORAGE_MIN_FREE  SSD free space below which it is full (default 50G)
#   FM_STORAGE_MIN_SIZE  smallest volume taken as the SSD (default 1500000000000)
#   FM_STORAGE_MAX_AGE   oldest check a reader trusts, seconds (default 1800)
#   FM_STORAGE_CONFIG    config dir;  FM_STORAGE_STATE  state dir
#   FM_STORAGE_MNT       WSL mount base (default /mnt)
#   FM_STORAGE_MOUNTINFO mount table (default /proc/self/mountinfo)
#   FM_STORAGE_SPEED_SIZE  write-speed test size (default 1G)
#   FM_STORAGE_PS_BACKOFF  seconds slept before each listing retry (default "5 15")
#   FM_STORAGE_POWERSHELL  powershell.exe to use (default: the one on PATH, else
#                        /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
#   FM_STORAGE_NOW       epoch override for tests
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
  FALLBACK=$(conf fallback "${FM_STORAGE_FALLBACK:-}")
  NOTIFY=$(conf notify "${FM_STORAGE_NOTIFY:-}")
  MIN_FREE=$(to_bytes "$(conf min_free "${FM_STORAGE_MIN_FREE:-}" 50G)") || die "min_free is not a size"
  MIN_SIZE=$(to_bytes "$(conf min_size "${FM_STORAGE_MIN_SIZE:-}" 1500000000000)") || die "min_size is not a size"
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

# mount_ssd MP: 0 when MP is mounted afterwards.
mount_ssd() {
  local mp=$1 l
  is_mounted "$mp" && return 0
  l=$(lower "$SSD_LETTER")
  case "$l" in [d-h]) ;; *) REASON="SSD is $SSD_LETTER:, outside the mount rule's letters D to H"; return 1 ;; esac
  if ! sudo -n /usr/bin/mount -t drvfs "$SSD_LETTER:" "$mp" -o "uid=$(id -u),gid=$(id -g)" >/dev/null 2>&1 || ! is_mounted "$mp"; then
    REASON="SSD $SSD_LETTER: is in Windows but not mounted in WSL; restart the laptop with the SSD plugged in, or see the mount rule section in docs/storage.md"
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
  if ! mkdir -p "$data/tetjet-results" "$data/archive" 2>/dev/null; then
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
  if [ "$STATE" = ok ]; then line1="$mp/lattice-data/tetjet-results/{task}"; else line1=$FALLBACK; fi
  {
    printf '%s\nformat=%s\nactive=%s\nstate=%s\nreason=%s\nchecked_at=%s\n' \
      "$line1" "$FORMAT" "$([ "$STATE" = ok ] && echo ssd || echo c)" "$STATE" "$REASON" "$(now)"
    if [ -n "$SSD_LETTER" ]; then
      printf 'ssd_letter=%s\nssd_id=%s\nssd_fs=%s\nssd_free_bytes=%s\nssd_total_bytes=%s\n' \
        "$SSD_LETTER" "$SSD_ID" "$SSD_FS" "$SSD_FREE" "$SSD_SIZE"
      if [ "$STATE" = ok ]; then
        printf 'ssd_marker=%s\narchive=%s\n' "$mp/lattice-data/.lattice-storage-id" "$mp/lattice-data/archive"
      fi
    fi
    printf 'fallback=%s\n' "$FALLBACK"
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
      printf 'note [at=%s]: SSD storage %s: %s; fetched results go to %s\n' "$(now)" "$STATE" "$REASON" "$LINE1" >>"$NOTIFY" || return 0
    fi
  fi
  printf '%s\n' "$key" | write_atomic "$lastf" || true
}

run_check() {
  local mp='' lock
  load_conf
  valid_template "$FALLBACK" || die "no C: fallback template with {task} configured (install-timer --fallback TEMPLATE or FM_STORAGE_FALLBACK)"
  mkdir -p "$(state_dir)" || die "cannot create $(state_dir)"
  lock="$(state_dir)/lock"
  exec 9>"$lock"
  flock -w 60 9 || die "another check holds $lock"
  detect
  if [ "$STATE" = unreadable ]; then
    keep_last_readable && return 0
  else
    rm -f "$(state_dir)/unreadable-runs"
  fi
  if [ -z "$STATE" ]; then
    mp="$(mnt_base)/$(lower "$SSD_LETTER")"
    if [ "$SSD_FREE" -lt "$MIN_FREE" ] 2>/dev/null; then
      STATE=full REASON="SSD $SSD_LETTER: has $(tib "$SSD_FREE") free, under the $(tib "$MIN_FREE") minimum"
    elif ! mount_ssd "$mp"; then
      STATE=not-mounted
    elif setup_and_probe "$mp"; then
      STATE=ok REASON="SSD $SSD_LETTER: $SSD_FS, $(tib "$SSD_FREE") free"
    fi
  else
    release_stale
  fi
  publish "$mp"
  notify
  printf 'results root: %s (%s: %s)\n' "$LINE1" "$STATE" "$REASON"
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
  [ -r "$f" ] || { printf 'results root: not published yet (no %s); readers use the C: fallback\n' "$f"; return 0; }
  active=$(kv "$f" active)
  age=$(( $(now) - $(kv "$f" checked_at || echo 0) ))
  printf 'results root: %s (%s, state %s, checked %s s ago)\n' "$(head -n 1 "$f")" \
    "$([ "$active" = ssd ] && echo SSD || echo 'C: fallback')" "$(kv "$f" state)" "$age"
  printf 'reason: %s\n' "$(kv "$f" reason)"
  if [ -n "$(kv "$f" ssd_letter)" ]; then
    printf 'SSD %s: %s, %s free of %s, write speed %s MiB/s\n' "$(kv "$f" ssd_letter)" "$(kv "$f" ssd_fs)" \
      "$(tib "$(kv "$f" ssd_free_bytes)")" "$(tib "$(kv "$f" ssd_total_bytes)")" "$(kv "$f" write_mib_s)"
  fi
  printf 'fallback: %s\n' "$(kv "$f" fallback)"
}

cmd_root() {
  local task='{task}' f line1 fb
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) die "unknown option $1" ;;
      *) task=$1; shift ;;
    esac
  done
  load_conf
  f="$(config_dir)/results-root"
  fb=$FALLBACK
  [ -r "$f" ] && [ -z "$fb" ] && fb=$(kv "$f" fallback)
  valid_template "$fb" || die "no C: fallback template known"
  line1=$fb
  if [ -r "$f" ] && [ "$(sed -n 2p "$f")" = "format=$FORMAT" ]; then
    local cand
    cand=$(head -n 1 "$f")
    if valid_template "$cand" && [ "$(kv "$f" active)" = ssd ]; then
      if [ $(( $(now) - $(kv "$f" checked_at || echo 0) )) -le "${FM_STORAGE_MAX_AGE:-1800}" ] \
        && [ -e "$(kv "$f" ssd_marker)" ]; then
        line1=$cand
      fi
    elif valid_template "$cand"; then
      line1=$cand
    fi
  fi
  printf '%s\n' "${line1//\{task\}/$task}"
}

UNIT=fm-storage

cmd_install_timer() {
  local fb='' nf='' dir self k v
  while [ $# -gt 0 ]; do
    case "$1" in
      --fallback) fb=${2:-}; shift 2 ;;
      --notify) nf=${2:-}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  valid_template "$fb" || die "--fallback must be an absolute path containing {task}"
  {
    printf 'fallback=%s\n' "$fb"
    [ -n "$nf" ] && printf 'notify=%s\n' "$nf"
    for k in min_free min_size; do
      v=$(kv "$(config_dir)/storage.conf" "$k")
      [ -n "$v" ] && printf '%s=%s\n' "$k" "$v"
    done
  } | write_atomic "$(config_dir)/storage.conf" || die "could not write storage.conf"
  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$dir" || die "cannot create $dir"
  printf '[Unit]\nDescription=Choose the fetched-results root (external SSD or C: fallback)\n\n[Service]\nType=oneshot\nNice=19\nIOSchedulingClass=idle\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin:%s\nExecStart=%s check\n' "$PS_DIR" "$self" \
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
  status) cmd_status ;;
  root) shift; cmd_root "$@" ;;
  install-timer) shift; cmd_install_timer "$@" ;;
  uninstall-timer) cmd_uninstall_timer ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command $1 (see --help)" ;;
esac
