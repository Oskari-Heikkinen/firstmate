#!/usr/bin/env bash
# fm-claude-update.sh - update Claude Code without ever breaking the working
# copy: each release goes into its own folder, is verified there, and only then
# becomes live through one symlink rename, with the previous version kept for
# rollback. docs/claude-update.md owns the design and the install; the
# claude-update skill owns the agent procedure.
#
# Usage:
#   fm-claude-update.sh run
#       The timer's job. Pick the newest release at or below the dist-tag that
#       is at least the minimum release age old (and not in skipped-versions),
#       then install, verify and switch to it. Already live: re-verify the live
#       copy. Older than the live version: keep the live one (never downgrades).
#   fm-claude-update.sh install VERSION
#       Install, verify and switch to exactly VERSION, ignoring the release age
#       and removing VERSION from skipped-versions. Also adopts a first version.
#   fm-claude-update.sh stage [VERSION]
#       Install and verify into a fresh folder and switch nothing. Without
#       VERSION, stage what `run` would pick. A verified copy is kept under
#       versions/ for a later switch unless that folder already exists.
#   fm-claude-update.sh rollback
#       Verify the previous version, then make it current in one rename; the
#       version rolled back from becomes previous and is added to
#       skipped-versions so `run` does not take it again.
#   fm-claude-update.sh status
#       Print the live, previous and kept versions, the last healthy run, the
#       standing alarm and the settings.
#   fm-claude-update.sh check
#       For a firstmate custom watcher check: print one line when an alarm is
#       new (repeated every 6 hours while it stands), once when it clears, and
#       when no healthy run happened within the stale limit; else nothing.
#   fm-claude-update.sh arm | disarm
#       Write FM_HOME's state/claude-update.check.sh shim (running `check` with
#       this script's FM_CLAUDE_UPDATE_* settings) and bind it with
#       fm-check-register.sh, or retire it with fm-check-unregister.sh.
#
# Layout under the root (FM_CLAUDE_UPDATE_ROOT, default ~/.local/share/claude-code):
#   versions/<v>/      one npm --global prefix per version; bin/claude is its
#                      entry point and .fm-claude-update/install.log its npm log
#   current, previous  relative symlinks to versions/<v>; current/bin/claude is
#                      the stable path every consumer runs
#   staging/<v>-<utc>-<pid>  an install in progress (renamed into versions/ once verified)
#   failed/<v>-<utc>-<pid>   a failed install or a copy that stopped verifying, kept
#                      with its log and reason for diagnosis (newest KEEP_FAILED)
# State (FM_CLAUDE_UPDATE_STATE, default ~/.local/state/claude-update):
#   log                one plain line per event: UTC time, what, why, what next
#   alarm              the standing failure, one line; removed by a healthy run
#   last-ok            epoch and summary of the last healthy run
#   skipped-versions   versions `run` never takes (rollback adds them); one per
#                      line, delete a line to allow it again
#   check-memo, lock   the check's repeat memory; the run lock
#
# Every failure leaves current and previous as they were, keeps its evidence,
# writes the alarm and exits 1. A run that finds another holding the lock logs
# the skip and exits 0; other commands exit 75 then. Misuse exits 2.
#
# A stop on request (SIGTERM, as `systemctl --user stop claude-update.service`
# or the unit's TimeoutStartSec sends, or SIGINT or SIGHUP) is not a failure: it
# stops npm, removes the unfinished staging folder, releases the lock, logs
# "stopped on request" and exits 128+signal (143 for SIGTERM) with no alarm, so
# the stopped run's next step is a rerun, an install or a rollback. A stop that
# arrives while a switch or rollback renames the links waits for those few
# renames and their checks to finish, so current and previous never point at a
# half-done switch; a step that fails while the stop waits is retried once,
# since the stop's own signal to every process in the unit most likely failed
# it, and pruning old versions waits for the next run.
#
# The install always passes --allow-scripts=<package>: the package's postinstall
# is what replaces bin/claude.exe (a ~500-byte stub) with the native binary, and
# npm documents unreviewed install scripts as skipped by default.
# npm treats a failed download of the optional native package as success and
# leaves the stub, so a failed attempt is rerun into the same folder, up to
# INSTALL_TRIES attempts, before the install fails; the log is --loglevel=verbose
# so each dropped optional package shows as "reify failed optional dependency".
#
# Environment (all optional):
#   FM_CLAUDE_UPDATE_ROOT, FM_CLAUDE_UPDATE_STATE   see above
#   FM_CLAUDE_UPDATE_PACKAGE        npm package (default @anthropic-ai/claude-code)
#   FM_CLAUDE_UPDATE_BIN            entry point name in bin/ (default claude)
#   FM_CLAUDE_UPDATE_TAG            dist-tag that caps the versions considered (default latest)
#   FM_CLAUDE_UPDATE_MIN_AGE_HOURS  minimum release age before `run` takes a version (default 24)
#   FM_CLAUDE_UPDATE_MIN_BYTES      smallest plausible binary (default 50000000)
#   FM_CLAUDE_UPDATE_MIN_FREE_MB    free space needed on the root's filesystem (default 2048)
#   FM_CLAUDE_UPDATE_KEEP           verified versions kept, current and previous included (default 3)
#   FM_CLAUDE_UPDATE_KEEP_FAILED    failed folders kept (default 3)
#   FM_CLAUDE_UPDATE_INSTALL_SECS   npm install timeout (default 900)
#   FM_CLAUDE_UPDATE_INSTALL_TRIES  npm install attempts per version before it fails (default 5)
#   FM_CLAUDE_UPDATE_VIEW_RETRY_SECS  wait before the one retry of a failed version check (default 60)
#   FM_CLAUDE_UPDATE_STALE_HOURS    no healthy run for this long is reported (default 50)
#   FM_CLAUDE_UPDATE_NPM            npm to run (default: npm on PATH, else /opt/node24/bin/npm)
#   FM_CLAUDE_UPDATE_NOW            epoch override for tests
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${FM_CLAUDE_UPDATE_ROOT:-$HOME/.local/share/claude-code}
STATE=${FM_CLAUDE_UPDATE_STATE:-$HOME/.local/state/claude-update}
PKG=${FM_CLAUDE_UPDATE_PACKAGE:-@anthropic-ai/claude-code}
BIN=${FM_CLAUDE_UPDATE_BIN:-claude}
TAG=${FM_CLAUDE_UPDATE_TAG:-latest}
MIN_AGE_HOURS=${FM_CLAUDE_UPDATE_MIN_AGE_HOURS:-24}
MIN_BYTES=${FM_CLAUDE_UPDATE_MIN_BYTES:-50000000}
MIN_FREE_MB=${FM_CLAUDE_UPDATE_MIN_FREE_MB:-2048}
KEEP=${FM_CLAUDE_UPDATE_KEEP:-3}
KEEP_FAILED=${FM_CLAUDE_UPDATE_KEEP_FAILED:-3}
INSTALL_SECS=${FM_CLAUDE_UPDATE_INSTALL_SECS:-900}
INSTALL_TRIES=${FM_CLAUDE_UPDATE_INSTALL_TRIES:-5}
VIEW_RETRY_SECS=${FM_CLAUDE_UPDATE_VIEW_RETRY_SECS:-60}
STALE_HOURS=${FM_CLAUDE_UPDATE_STALE_HOURS:-50}
REPEAT_SECS=21600
SETTINGS="ROOT STATE PACKAGE BIN TAG MIN_AGE_HOURS MIN_BYTES MIN_FREE_MB KEEP KEEP_FAILED INSTALL_SECS INSTALL_TRIES VIEW_RETRY_SECS STALE_HOURS NPM"

die() { printf 'fm-claude-update: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }
now() { printf '%s\n' "${FM_CLAUDE_UPDATE_NOW:-$(date +%s)}"; }
utc() { date -u -d "@${1:-$(now)}" +%Y-%m-%dT%H:%M:%SZ; }
stamp() { printf '%s-%s\n' "$(date -u -d "@$(now)" +%Y%m%dT%H%M%SZ)" "$$"; }
valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

for v in MIN_AGE_HOURS MIN_BYTES MIN_FREE_MB KEEP KEEP_FAILED INSTALL_SECS INSTALL_TRIES VIEW_RETRY_SECS STALE_HOURS; do
  [[ ${!v} =~ ^[0-9]+$ ]] || die "FM_CLAUDE_UPDATE_$v must be a whole number, not '${!v}'"
done
[ "$KEEP" -ge 2 ] || die "FM_CLAUDE_UPDATE_KEEP must be at least 2 (current and previous)"
[ "$INSTALL_TRIES" -ge 1 ] || die "FM_CLAUDE_UPDATE_INSTALL_TRIES must be at least 1"

# ver_lt A B: A sorts before B as major.minor.patch.
ver_lt() {
  local IFS=. a b i
  read -r -a a <<<"$1"
  read -r -a b <<<"$2"
  for i in 0 1 2; do
    [ "${a[i]}" -lt "${b[i]}" ] && return 0
    [ "${a[i]}" -gt "${b[i]}" ] && return 1
  done
  return 1
}

log() {
  mkdir -p "$STATE" 2>/dev/null
  printf '%s %s\n' "$(utc)" "$*" >>"$STATE/log" 2>/dev/null || printf '%s %s\n' "$(utc)" "$*" >&2
}

say() { printf '%s\n' "$*"; log "$*"; }

npm_cmd() {
  if [ -n "${FM_CLAUDE_UPDATE_NPM:-}" ]; then printf '%s\n' "$FM_CLAUDE_UPDATE_NPM"
  elif command -v npm >/dev/null 2>&1; then command -v npm
  else printf '%s\n' /opt/node24/bin/npm
  fi
}

# Heavy work runs at the lowest CPU and I/O priority. A command prefix, not a
# function, so a backgrounded heavy command is the process a stop signals.
HEAVY=(nice -n 19)
if command -v ionice >/dev/null 2>&1; then HEAVY+=(ionice -c3); fi

# link_version NAME: the version current or previous points at, or nothing.
link_version() {
  local t
  t=$(readlink "$ROOT/$1" 2>/dev/null) || return 0
  t=${t#versions/}
  valid_version "$t" && printf '%s\n' "$t"
}

# set_link NAME VERSION: point NAME at versions/VERSION in one rename.
set_link() {
  local tmp="$ROOT/.$1.tmp.$$"
  rm -f -- "$tmp"
  ln -s "versions/$2" "$tmp" && mv -T -f -- "$tmp" "$ROOT/$1"
}

# take_lock: hold the run lock on fd 9 and, from then on, take a stop on request.
take_lock() {
  mkdir -p "$STATE" || return 1
  exec 9>>"$STATE/lock" || return 1
  flock -n 9 || return 1
  trap 'on_stop 15 SIGTERM' TERM
  trap 'on_stop 2 SIGINT' INT
  trap 'on_stop 1 SIGHUP' HUP
}

# What a stop has to undo: the running npm install and the staging folder it
# writes. SWITCHING marks the link renames a stop waits for.
CHILD='' STAGE='' SWITCHING='' STOP_PENDING=''

# on_stop NUM NAME: stop now, or after the switch in progress.
on_stop() {
  if [ -n "$SWITCHING" ]; then
    STOP_PENDING="$1 $2"
    return 0
  fi
  stop_now "$1" "$2" ''
}

# stop_now NUM NAME NOTE: signal the npm install first, then remove its staging
# folder, release the lock, log the stop and exit 128+NUM. Never alarms.
stop_now() {
  local live what
  trap '' TERM INT HUP
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null
    wait "$CHILD" 2>/dev/null
  fi
  what='no staging folder was in progress'
  if [ -n "$STAGE" ] && [ -e "$STAGE" ]; then
    if rm -rf -- "$STAGE"; then
      what="removed the unfinished staging folder $STAGE"
    else
      what="could not remove the unfinished staging folder $STAGE"
    fi
  fi
  flock -u 9 2>/dev/null
  exec 9>&-
  live=$(link_version current)
  log "stopped on request ($2)$3: $what; lock released; live claude unchanged (${live:-no managed version}); no alarm; next: rerun fm-claude-update.sh run, install or rollback"
  printf 'fm-claude-update: stopped on request (%s); live claude unchanged (%s)\n' "$2" "${live:-no managed version}" >&2
  exit $((128 + $1))
}

# switch_done: the link renames are finished; take a stop that waited for them.
switch_done() {
  local pending=$STOP_PENDING
  SWITCHING='' STOP_PENDING=''
  [ -z "$pending" ] || stop_now "${pending%% *}" "${pending#* }" ' during a switch, after the switch finished'
}

# again CMD...: run a switch step, and once more when it failed while a stop
# waited: `systemctl stop` signals every process in the unit, so the stop's own
# signal most likely failed it, and the switch still has to finish truthfully.
again() {
  "$@" && return 0
  [ -n "$STOP_PENDING" ] || return 1
  log "retrying $1 once: it failed while a stop waited for the switch"
  "$@"
}

# move_in SRC DST: rename SRC to DST, done also when a killed mv had renamed it.
move_in() {
  mv -T -- "$1" "$2" 2>/dev/null || { [ ! -e "$1" ] && [ -e "$2" ]; }
}

# alarm WHAT EVIDENCE NEXT: record the standing failure, then exit 1.
alarm() {
  local live line tmp
  live=$(link_version current)
  line="claude-update failed at $(utc): $1; evidence: $2; live claude unchanged (${live:-no managed version}); next: $3"
  mkdir -p "$STATE"
  tmp=$(mktemp "$STATE/.alarm.XXXXXX") && printf '%s\n' "$line" >"$tmp" && mv -f -- "$tmp" "$STATE/alarm"
  log "FAILED: $1; evidence $2; next: $3"
  printf '%s\n' "$line" >&2
  exit 1
}

# healthy SUMMARY: a run that ended with a verified live copy.
healthy() {
  local tmp
  tmp=$(mktemp "$STATE/.last-ok.XXXXXX") && printf '%s %s\n' "$(now)" "$1" >"$tmp" && mv -f -- "$tmp" "$STATE/last-ok"
  if [ -f "$STATE/alarm" ]; then
    rm -f -- "$STATE/alarm"
    log "alarm cleared: $1"
  fi
}

# verify PREFIX VERSION: PREFIX/bin/BIN is a real, plausibly sized executable
# inside PREFIX whose --version prints exactly VERSION. Sets DETAIL either way.
verify() {
  local prefix=$1 want=$2 entry real base size out got
  entry="$prefix/bin/$BIN"
  base=$(readlink -f "$prefix") || { DETAIL="$prefix cannot be resolved"; return 1; }
  if [ ! -e "$entry" ]; then
    DETAIL="$entry is missing (npm did not link the package's $BIN)"
    return 1
  fi
  real=$(readlink -f "$entry")
  case "$real" in
    "$base"/*) : ;;
    *) DETAIL="$entry resolves to $real, outside $base"; return 1 ;;
  esac
  if [ ! -f "$real" ] || [ ! -x "$real" ]; then
    DETAIL="$real is not an executable file"
    return 1
  fi
  size=$(stat -c %s "$real" 2>/dev/null || wc -c <"$real")
  size=${size//[!0-9]/}
  if [ "${size:-0}" -lt "$MIN_BYTES" ]; then
    DETAIL="$real is ${size:-0} bytes, under the $MIN_BYTES-byte floor (a stub: the package's install step did not place the native binary)"
    return 1
  fi
  out=$(DISABLE_AUTOUPDATER=1 timeout 60 "$entry" --version 2>&1 </dev/null 9>&-) || {
    DETAIL="$entry --version failed: $(printf '%s' "$out" | head -n 1)"
    return 1
  }
  got=$(printf '%s\n' "$out" | head -n 1 | awk '{ print $1 }')
  if [ "$got" != "$want" ]; then
    DETAIL="$entry --version printed '$(printf '%s' "$out" | head -n 1)', not $want"
    return 1
  fi
  DETAIL="$size-byte binary, --version $want"
}

room_ok() {
  local free
  mkdir -p "$ROOT" || return 1
  free=$(df -Pk -- "$ROOT" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }')
  [ -n "$free" ] && [ "$free" -ge "$MIN_FREE_MB" ]
}

# pick: print "<pick|none> <cap>" for the newest release at or below TAG that is
# at least MIN_AGE_HOURS old and not skipped; nonzero when the registry answer
# cannot be read.
pick() {
  local npm json skips
  npm=$(npm_cmd)
  if ! json=$(timeout 120 "$npm" view "$PKG" time dist-tags --json 2>>"$STATE/log"); then
    log "version check failed; retrying once in ${VIEW_RETRY_SECS}s"
    sleep "$VIEW_RETRY_SECS"
    json=$(timeout 120 "$npm" view "$PKG" time dist-tags --json 2>>"$STATE/log") || return 1
  fi
  skips=$(cat "$STATE/skipped-versions" 2>/dev/null)
  printf '%s' "$json" | python3 -I -c '
import json, re, sys
from datetime import datetime
tag, min_age, now, skips = sys.argv[1], float(sys.argv[2]) * 3600, float(sys.argv[3]), set(sys.argv[4].split())
d = json.load(sys.stdin)
key = lambda v: tuple(int(p) for p in v.split("."))
cap = d["dist-tags"][tag]
if not re.fullmatch(r"\d+\.\d+\.\d+", cap):
    sys.exit(1)
best = None
for v, t in d["time"].items():
    if not re.fullmatch(r"\d+\.\d+\.\d+", v) or v in skips or key(v) > key(cap):
        continue
    age = now - datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    if age >= min_age and (best is None or key(v) > key(best)):
        best = v
print(best or "none", cap)
' "$TAG" "$MIN_AGE_HOURS" "$(now)" "$skips"
}

# install_fresh VERSION WHY: npm-install VERSION into a new staging folder and
# verify it there, rerunning a failed attempt into the same folder up to
# INSTALL_TRIES times. On success STAGED names the folder; on failure the folder
# moves to failed/ and the alarm fires.
install_fresh() {
  local ver=$1 npm stage rc try=0 log_file
  npm=$(npm_cmd)
  room_ok || alarm "not enough room: under ${MIN_FREE_MB} MiB free for $ROOT" "df $ROOT" "free space, then rerun fm-claude-update.sh run"
  mkdir -p "$ROOT/staging" "$ROOT/failed" "$ROOT/versions"
  stage="$ROOT/staging/$ver-$(stamp)"
  STAGE=$stage
  mkdir -p "$stage/.fm-claude-update"
  log_file="$stage/.fm-claude-update/install.log"
  : >"$log_file"
  log "installing $PKG@$ver into $stage; why: $2; next: verify it there"
  while :; do
    try=$((try + 1))
    printf '== fm-claude-update: attempt %s of %s at %s\n' "$try" "$INSTALL_TRIES" "$(utc)" >>"$log_file"
    # In the background, so a stop interrupts the wait at once; timeout forwards
    # the stop to npm's process group and kills it 30 s later if still running.
    # npm never inherits the lock's fd 9, so nothing it leaves behind holds it.
    "${HEAVY[@]}" timeout -k 30 "$INSTALL_SECS" "$npm" install --global --prefix "$stage" \
      --allow-scripts="$PKG" --foreground-scripts --include=optional --no-audit --no-fund \
      --loglevel=verbose "$PKG@$ver" >>"$log_file" 2>&1 9>&- &
    CHILD=$!
    wait "$CHILD"
    rc=$?
    CHILD=''
    if [ "$rc" -ne 0 ]; then
      DETAIL="npm install exited $rc"
    elif verify "$stage" "$ver"; then
      break
    fi
    if [ "$try" -ge "$INSTALL_TRIES" ]; then
      fail_folder "$stage" "$ver" "$DETAIL (after $try attempts)"
      STAGE=''
      if [ "$rc" -ne 0 ]; then
        alarm "npm install of $PKG@$ver exited $rc (after $try attempts)" "$FAILED/.fm-claude-update/install.log" "read that log, then rerun fm-claude-update.sh run"
      fi
      alarm "verification of $PKG@$ver failed after $try attempts: $DETAIL" "$FAILED/.fm-claude-update/install.log" "read that log, then rerun fm-claude-update.sh run"
    fi
    log "attempt $try of $INSTALL_TRIES for $PKG@$ver failed: $DETAIL; why: a dropped optional download leaves the stub; next: rerun npm install into $stage"
  done
  log "verified $stage on attempt $try: $DETAIL"
  STAGED=$stage
}

# fail_folder DIR VERSION REASON: keep DIR under failed/ with its reason.
fail_folder() {
  FAILED="$ROOT/failed/$2-$(stamp)"
  mkdir -p "$ROOT/failed" "$1/.fm-claude-update"
  printf '%s\n' "$3" >"$1/.fm-claude-update/reason" 2>/dev/null
  if mv -T -- "$1" "$FAILED" 2>/dev/null; then
    log "kept the failed copy of $2 at $FAILED: $3"
  else
    FAILED=$1
  fi
  prune_failed
}

# entries DIR: the names in DIR, one per line.
entries() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null; }

prune_failed() {
  local d n=0
  # Failed folders are named <version>-<utc stamp>; newest stamp first.
  while IFS= read -r d; do
    n=$((n + 1))
    [ "$n" -le "$KEEP_FAILED" ] && continue
    rm -rf -- "${ROOT:?}/failed/$d" && log "removed old failed copy failed/$d (keeping the newest $KEEP_FAILED)"
  done < <(entries "$ROOT/failed" | sort -t- -k2,2r)
}

# prune_versions: keep current, previous and the newest others up to KEEP.
# Skipped once a stop waits, since the stop may have killed a link read and
# made current or previous look empty; the next run prunes.
prune_versions() {
  local cur prev d n=2
  cur=$(link_version current)
  prev=$(link_version previous)
  while IFS= read -r d; do
    if [ -n "$STOP_PENDING" ]; then
      log "skipped pruning old versions: a stop is waiting; the next run prunes"
      return 0
    fi
    valid_version "$d" || continue
    if [ "$d" = "$cur" ] || [ "$d" = "$prev" ]; then continue; fi
    n=$((n + 1))
    [ "$n" -le "$KEEP" ] && continue
    rm -rf -- "${ROOT:?}/versions/$d" && log "removed old version versions/$d (keeping $KEEP versions)"
  done < <(entries "$ROOT/versions" | sort -t. -k1,1nr -k2,2nr -k3,3nr)
}

# switch_to VERSION WHY: make versions/VERSION live, installing it first when it
# is absent or no longer verifies.
switch_to() {
  local ver=$1 why=$2 old
  old=$(link_version current)
  if [ -d "$ROOT/versions/$ver" ] && ! verify "$ROOT/versions/$ver" "$ver"; then
    if [ "$ver" = "$old" ] || [ "$ver" = "$(link_version previous)" ]; then
      alarm "the kept copy of $ver no longer verifies: $DETAIL" "$ROOT/versions/$ver" "reinstall it with fm-claude-update.sh install $ver"
    fi
    fail_folder "$ROOT/versions/$ver" "$ver" "kept copy stopped verifying: $DETAIL"
  fi
  if [ ! -d "$ROOT/versions/$ver" ]; then
    install_fresh "$ver" "$why"
    SWITCHING=1
    again move_in "$STAGED" "$ROOT/versions/$ver" \
      || alarm "could not move $STAGED into versions/$ver" "$STAGED" "check $ROOT, then rerun"
    STAGE=''
  fi
  SWITCHING=1
  again verify "$ROOT/versions/$ver" "$ver" \
    || alarm "versions/$ver failed verification after the move: $DETAIL" "$ROOT/versions/$ver" "check $ROOT, then rerun"
  if [ "$old" = "$ver" ]; then
    healthy "$ver already live and verified ($DETAIL)"
    say "claude-update: $ver is already live and verified"
    switch_done
    return 0
  fi
  if [ -n "$old" ]; then
    again set_link previous "$old" || alarm "could not point previous at $old" "$ROOT" "check $ROOT, then rerun"
  fi
  again set_link current "$ver" || alarm "could not point current at $ver" "$ROOT" "check $ROOT, then rerun"
  if ! again verify "$ROOT/current" "$ver"; then
    local bad=$DETAIL
    if [ -n "$old" ]; then set_link current "$old"; else rm -f -- "$ROOT/current"; fi
    alarm "the switched-to current did not verify, switched back: $bad" "$ROOT/versions/$ver" "investigate before rerunning"
  fi
  prune_versions
  healthy "switched ${old:-nothing} -> $ver ($DETAIL)"
  say "claude-update: switched ${old:-nothing} -> $ver; previous ${old:-none} kept for rollback"
  switch_done
}

cmd_run() {
  local cur choice cap ver
  [ "$#" -eq 0 ] || die "run takes no arguments"
  if ! take_lock; then
    log "skipped: another claude-update run holds the lock; nothing changed"
    return 0
  fi
  cur=$(link_version current)
  choice=$(pick) || alarm "version check failed: npm view $PKG could not be read" "$STATE/log" "check the network and registry; the next run retries"
  ver=${choice%% *}
  cap=${choice#* }
  if [ "$ver" = none ]; then
    if [ -n "$cur" ]; then
      verify "$ROOT/current" "$cur" || alarm "the live copy $cur no longer verifies: $DETAIL" "$ROOT/versions/$cur" "roll back with fm-claude-update.sh rollback"
    fi
    healthy "waiting: no $PKG release at or below $TAG $cap is ${MIN_AGE_HOURS}h old yet"
    say "claude-update: waiting, no release at or below $TAG $cap is ${MIN_AGE_HOURS}h old yet; live ${cur:-none}"
    return 0
  fi
  if [ -n "$cur" ] && [ "$ver" != "$cur" ] && ver_lt "$ver" "$cur"; then
    verify "$ROOT/current" "$cur" || alarm "the live copy $cur no longer verifies: $DETAIL" "$ROOT/versions/$cur" "roll back with fm-claude-update.sh rollback"
    healthy "kept $cur: newest eligible release $ver is older (no automatic downgrade)"
    say "claude-update: kept $cur; newest release past ${MIN_AGE_HOURS}h is $ver, older, and run never downgrades"
    return 0
  fi
  if [ "$ver" = "$cur" ]; then
    verify "$ROOT/current" "$cur" || alarm "the live copy $cur no longer verifies: $DETAIL" "$ROOT/versions/$cur" "reinstall it with fm-claude-update.sh install $cur, or roll back"
    healthy "$cur is current and verified ($DETAIL); $TAG is $cap"
    say "claude-update: $cur is current and verified; $TAG is $cap"
    return 0
  fi
  switch_to "$ver" "newest release past ${MIN_AGE_HOURS}h (live ${cur:-none}, $TAG $cap)"
}

cmd_install() {
  if [ "$#" -ne 1 ] || ! valid_version "$1"; then die "install takes one VERSION like 2.1.306"; fi
  take_lock || { printf 'fm-claude-update: another claude-update run holds the lock\n' >&2; exit 75; }
  if grep -qxF -- "$1" "$STATE/skipped-versions" 2>/dev/null; then
    grep -vxF -- "$1" "$STATE/skipped-versions" >"$STATE/.skipped.tmp"
    mv -f -- "$STATE/.skipped.tmp" "$STATE/skipped-versions"
    log "removed $1 from skipped-versions: installed by hand"
  fi
  switch_to "$1" "installed by hand"
}

cmd_stage() {
  local ver choice
  [ "$#" -le 1 ] || die "stage takes at most one VERSION"
  take_lock || { printf 'fm-claude-update: another claude-update run holds the lock\n' >&2; exit 75; }
  if [ "$#" -eq 1 ]; then
    valid_version "$1" || die "stage takes a VERSION like 2.1.306"
    ver=$1
  else
    choice=$(pick) || alarm "version check failed: npm view $PKG could not be read" "$STATE/log" "check the network and registry, then rerun"
    ver=${choice%% *}
    [ "$ver" != none ] || { say "claude-update stage: no release is ${MIN_AGE_HOURS}h old yet; nothing staged"; return 0; }
  fi
  install_fresh "$ver" "staging only: nothing switches"
  SWITCHING=1
  if [ -e "$ROOT/versions/$ver" ]; then
    rm -rf -- "$STAGED"
    STAGE=''
    say "claude-update stage: a fresh $ver installed and verified ($DETAIL); versions/$ver already exists and was left untouched; nothing switched"
  else
    again move_in "$STAGED" "$ROOT/versions/$ver" || alarm "could not move $STAGED into versions/$ver" "$STAGED" "check $ROOT"
    STAGE=''
    say "claude-update stage: $ver installed and verified at $ROOT/versions/$ver ($DETAIL); nothing switched"
  fi
  switch_done
}

cmd_rollback() {
  local cur prev
  [ "$#" -eq 0 ] || die "rollback takes no arguments"
  take_lock || { printf 'fm-claude-update: another claude-update run holds the lock\n' >&2; exit 75; }
  cur=$(link_version current)
  prev=$(link_version previous)
  [ -n "$prev" ] || alarm "rollback refused: no previous version is kept" "$ROOT" "install a known-good version with fm-claude-update.sh install VERSION"
  verify "$ROOT/versions/$prev" "$prev" || alarm "rollback refused: previous $prev does not verify: $DETAIL" "$ROOT/versions/$prev" "install a known-good version with fm-claude-update.sh install VERSION"
  SWITCHING=1
  [ -z "$cur" ] || again set_link previous "$cur" || alarm "could not point previous at $cur" "$ROOT" "check $ROOT"
  again set_link current "$prev" || alarm "could not point current at $prev" "$ROOT" "check $ROOT"
  if [ -n "$cur" ] && ! grep -qxF -- "$cur" "$STATE/skipped-versions" 2>/dev/null; then
    printf '%s\n' "$cur" >>"$STATE/skipped-versions"
  fi
  healthy "rolled back ${cur:-nothing} -> $prev"
  say "claude-update: rolled back ${cur:-nothing} -> $prev; run skips ${cur:-nothing} until it is removed from $STATE/skipped-versions"
  switch_done
}

cmd_status() {
  local cur prev d
  cur=$(link_version current)
  prev=$(link_version previous)
  printf 'live:      %s\n' "${cur:-none} ($ROOT/current/bin/$BIN)"
  printf 'previous:  %s\n' "${prev:-none}"
  printf 'kept:      %s\n' "$(entries "$ROOT/versions" | sort -V | tr '\n' ' ')"
  printf 'failed:    %s\n' "$(entries "$ROOT/failed" | sort | tr '\n' ' ')"
  if [ -f "$STATE/last-ok" ]; then
    read -r d _ <"$STATE/last-ok"
    printf 'last ok:   %s %s\n' "$(utc "$d")" "$(cut -d' ' -f2- "$STATE/last-ok")"
  else
    printf 'last ok:   never\n'
  fi
  printf 'alarm:     %s\n' "$(cat "$STATE/alarm" 2>/dev/null || echo none)"
  printf 'skipped:   %s\n' "$(tr '\n' ' ' 2>/dev/null <"$STATE/skipped-versions")"
  printf 'settings:  %s, tag %s, min age %sh, keep %s, log %s\n' "$PKG" "$TAG" "$MIN_AGE_HOURS" "$KEEP" "$STATE/log"
}

# check: print at most one line; the memo is "<key> <epoch>" of the last line.
cmd_check() {
  local t key line last_key='' last_at=0 ok_at
  t=$(now)
  [ -r "$STATE/check-memo" ] && read -r last_key last_at <"$STATE/check-memo"
  if [ -f "$STATE/alarm" ]; then
    line=$(head -n 1 "$STATE/alarm" 2>/dev/null) || line=
    [ -n "$line" ] || line="claude-update alarm file $STATE/alarm is unreadable"
    key="alarm:$(printf '%s' "$line" | cksum | cut -d' ' -f1)"
  else
    ok_at=
    [ -r "$STATE/last-ok" ] && read -r ok_at _ <"$STATE/last-ok"
    if ! [[ ${ok_at:-} =~ ^[0-9]+$ ]]; then
      key=stale
      line="claude-update has no healthy run on record ($STATE/last-ok missing or unreadable); check systemctl --user status claude-update.timer and $STATE/log"
    elif [ $((t - ok_at)) -ge $((STALE_HOURS * 3600)) ]; then
      key=stale
      line="claude-update has had no healthy run since $(utc "$ok_at") (limit ${STALE_HOURS}h); check systemctl --user status claude-update.timer and $STATE/log"
    else
      if [ -n "$last_key" ] && [ "$last_key" != ok ]; then
        printf 'claude-update recovered: %s\n' "$(cut -d' ' -f2- "$STATE/last-ok")"
        mkdir -p "$STATE" && printf 'ok %s\n' "$t" >"$STATE/check-memo"
      fi
      return 0
    fi
  fi
  if [ "$key" = "$last_key" ] && [[ $last_at =~ ^[0-9]+$ ]] && [ $((t - last_at)) -lt "$REPEAT_SECS" ]; then
    return 0
  fi
  printf '%s\n' "$line"
  mkdir -p "$STATE" && printf '%s %s\n' "$key" "$t" >"$STATE/check-memo"
}

cmd_arm() {
  local home state shim tmp v name
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  state=${FM_STATE_OVERRIDE:-$home/state}
  shim="$state/claude-update.check.sh"
  [ -d "$state" ] && [ ! -L "$state" ] || die "state directory $state is unavailable"
  [ ! -L "$shim" ] || die "refusing a symlinked $shim"
  tmp=$(umask 077; mktemp "$state/.fm-claude-update-check.XXXXXX") || die "cannot write in $state"
  {
    printf '%s\n' '#!/usr/bin/env bash' '# Auto-generated by fm-claude-update.sh arm - Claude Code update alarm check.'
    for v in $SETTINGS; do
      name=FM_CLAUDE_UPDATE_$v
      [ -z "${!name+x}" ] || printf 'export %s=%q\n' "$name" "${!name}"
    done
    printf 'exec %q check\n' "$SCRIPT_DIR/fm-claude-update.sh"
  } >"$tmp"
  if ! chmod 0700 "$tmp"; then
    rm -f -- "$tmp"
    die "cannot write $shim"
  fi
  # The register binds the staged bytes before renaming them onto the shim, so
  # a watcher sweep never finds the new shim unbound.
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" claude-update --from "$tmp" >/dev/null; then
    rm -f -- "$tmp" "$shim"
    die "cannot register $shim"
  fi
  printf 'armed: %s\n' "$shim"
}

cmd_disarm() {
  local home
  home=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-unregister.sh" claude-update
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  install) shift; cmd_install "$@" ;;
  stage) shift; cmd_stage "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  status) shift; cmd_status ;;
  check) shift; cmd_check ;;
  arm) cmd_arm ;;
  disarm) cmd_disarm ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
