#!/usr/bin/env bash
# fm-supervision-host.sh - the supervision host: watcher-cycle ownership plus a
# headless engine session that runs the supervision branch's contract beside a
# non-Pi primary (docs/supervision-host.md owns the design).
#
# Usage:
#   fm-supervision-host.sh park [--restart]
#   fm-supervision-host.sh stop
#
# A primary's arm owner runs this in place of bin/fm-watch-arm.sh when the home
# runs the host (by explicit config/supervision-host opt-in on every primary,
# never with config/supervision-host-off; docs/configuration.md "Supervision
# host"): the Claude Stop auto-arm
# (bin/fm-claude-stop-autoarm.sh), the Cursor stop-hook park
# (bin/fm-turnend-guard-cursor.sh), the OpenCode TUI plugin
# (.opencode/plugins/fm-primary-watch-arm.js), the omp watch extension
# (.omp/extensions/fm-primary-omp-watch.ts), Grok's model-owned background arm
# (docs/supervision-protocols/grok.md), and Codex's foreground checkpoint
# (bin/fm-watch-checkpoint.sh). To that owner it IS an arm: it prints the
# arm's own lines and exits only when main is needed, and stays parked across
# every close it handled itself. Each owner passes its harness as
# FM_SUPERVISION_HOST_PRIMARY, which the engine carries as the primary pin.
#
# OUTPUT, the contract every owner reads. The first cycle's status line
# ("watcher: started ..." or "watcher: attached ...") is printed as soon as the
# arm prints it, so an owner that waits for arm readiness sees it at once;
# everything else is printed in one write when the host exits: the close as
# the arm printed it (without that status line), then any "supervision-host:"
# lines. A "supervision-host:" line is a wake in its own right (the park
# boundary prints nothing else); "supervision-host stood down: ..." means this
# session or generation no longer owns supervision and the owner stands down
# silently; an exit status above 128, or no output at all, means the host
# itself died and the owner retries it. Any other close is judged exactly as
# the arm's. --restart starts the first cycle with fm-watch-arm.sh --restart,
# and an FM_WATCH_PREDECESSOR_ARM_PID the owner passes reaches that first
# cycle only, for owners that start their own successor after every close
# (OpenCode, omp).
#
# THE LOOP. It owns watcher cycles through bin/fm-watch-arm.sh. The posture is
# the away-posture record state/.afk-contract, read at every close and again
# when a turn starts: only an away record is away, and no record or quiet
# mode's record (fm_afk_contract_away_present, bin/fm-afk-contract.sh AWAY OR
# QUIET) is a present captain. On each actionable close:
#   - attended (no away record): the close reaches main exactly as the arm printed
#     it, as without the host, unless the supervision session may take it: the
#     home names a usable engine, its turns have every tool they need, this
#     primary has a verified dialog mirror (bin/fm-host-mirror.sh verified;
#     fm_supervision_host_attended_ready owns the list), the main session's
#     lock holder can be identified, the session is not cooling down after
#     engine errors, and the Pi branch's offer rule
#     (bin/fm-branch-dispatch.mjs offer) says the branch may take this close,
#     so main-only classes (check triggers, decision-owned triggers, a scan
#     that is unsafe or holds nothing for the branch) stay main's. That
#     pass-through starts the successor watcher cycle and leaves it running
#     before the close is printed, so supervision continues when the session
#     drops the handoff. It confirms no handling handoff, so the recovery
#     marker still reads downtime and the re-arm owner delivers the close to
#     main. The host records that successor's arm before relinquishing it
#     (detach_successor owns the persistence check and failure path). The
#     session's next park without --restart requests a take-over of its cycle
#     rather than an ordinary attach; bin/fm-watch-arm.sh's --take-over header owns the
#     conditions under which that restores a single owner and the fallback;
#   - away (an away record exists): every close goes to the engine.
# Every turn that starts attended meets that rule again at its start, so a
# close accepted away whose turn starts attended (the captain returned in
# between) or an attended close whose task turned main-only while the
# successor started reaches main exactly as the arm printed it, and that
# successor cycle stays running.
# A close the engine takes is handled in one order: it starts and verifies the
# successor watcher cycle and confirms the handling handoff (the order
# docs/watcher-continuity.md owns), computes the rows the branch may claim in
# the turn's posture with the dispatch owner, publishes that grant
# (bin/fm-wake-grant.sh), runs one bounded headless engine turn
# (bin/fm-supervision-engine-lib.sh) with the generated branch prompt
# (bin/fm-branch-prompt.sh), the dialog-mirror feed (bin/fm-host-mirror.sh)
# at the head of an attended wake and the away tail instead when away,
# releases the branch's leases and grant, and counts the wake handled only
# when that turn exited cleanly, recorded a durable report
# (bin/fm-branch-report.sh), and left none of its granted rows in the wake
# queue. A handled wake with only routine outcomes never wakes
# main, and neither does any handled wake while away: captain outcomes wait in
# the outcome store for the return drain's BRANCH OUTCOMES section. A handled
# attended wake that recorded a captain outcome exits with one "supervision-host: branch-outcome:"
# line naming its store rows, without the close it handled; main drains, where
# the BRANCH OUTCOMES section (bin/fm-wake-drain.sh) presents every
# unprocessed captain outcome until main acknowledges it. Otherwise the host
# parks on the successor.
# Every other outcome exits with the close's own reason line plus one
# "supervision-host:" line saying why main has this wake, after stopping the
# successor cycle so main's next turn end starts from the same state as
# without the host. Whenever the captain returned during an away engine turn
# that recorded visible outcomes, handled or not, the return brief was rendered
# before they existed, so the host exits with the close, one "supervision-host:"
# line naming them, and one line per visible outcome, for main to relay. The
# host injects nothing and has no delivery path of its own; the owner's
# existing wake path is the only way main hears from it, and its fallback is
# always to exit with the close's own reason line. That handoff is only a
# prompt: each non-silent outcome recorded after the return is already a
# durable queued wake
# (bin/fm-branch-report.sh), so it still reaches main when the host dies at the
# turn's end or its owner drops the handoff, as a superseded Cursor park does.
#
# THE LATCH. An opted-in host persists engine health across short-lived
# parks; docs/supervision-host.md "The broken-session latch" owns the policy.
#
# THE PARK BOUNDARY. Claude drops the exit 2 of a Stop hook it terminated at
# the hook's configured timeout (docs/verification/supervision.md), Cursor's
# stop hook carries the same tracked 28800-second registration, and a host
# that handles its own wakes is not shortened by them, so the host ends its
# own park before that timeout: after FM_SUPERVISION_HOST_PARK_SECONDS (default
# 27000, under the tracked 28800-second registration) it stops this home's
# watcher and exits with one "supervision-host: cycle boundary" line, which the
# owner delivers as an ordinary wake; main drains, acknowledges, and ends its
# turn, and that turn end starts the next park. The boundary is checked on
# every loop pass, however many closes are already waiting, and an away close
# whose engine turn could still be running at the turn limit (the turn bound
# plus the engine grace), judged when the close arrives and again just before
# the turn starts, is not handled: the host exits through the same boundary
# with that close printed ahead of the line. The turn limit is the boundary
# itself unless the owner sets FM_SUPERVISION_HOST_PARK_LIMIT later: Codex's
# checkpoint, whose bound is the park itself rather than a harness timeout,
# lets a turn that starts before the boundary finish after it. The harness
# times its hook on a monotonic clock that a VM guest (WSL2) can run several
# percent ahead of the wall clock, so the park's elapsed time is the larger of
# Bash's SECONDS and the boot clock (/proc/uptime) since the owner process
# (FM_SUPERVISION_HOST_OWNER_PID, else the host) started.
#
# OWNERSHIP. Before activation, every successor cycle, and every engine turn
# the host proves this session still holds the fleet lock
# (bin/fm-session-lock-lib.sh) and, when launched by the auto-arm, that the
# auto-arm generation it serves (FM_SUPERVISION_HOST_AUTOARM_GEN owned by
# FM_SUPERVISION_HOST_OWNER_PID) is still current; otherwise it stands down
# with a "supervision-host:" line and leaves the decision to its owner; a
# host that stands down before activation leaves the owner's host record,
# processes, arms, and leases alone. The engine runs with
# FM_SUPERVISION_ACTOR=branch, the session-lock holder as FM_LEASE_HOLDER_PID,
# the primary's harness pin, and this turn's report id, so every guarded
# script applies the same partition, leases, and away relocation it applies to
# the Pi branch. At activation the host stops anything a crashed predecessor
# left running (recorded with identities, never by name), including the
# engine descendants its turn recorded. Arm rows also carry a unique launch
# token in argv: recovery may match its unchanged birth plus that home/role
# token across exec; legacy rows still require the full identity. Before an
# arm row is published, startup samples its own child for at most five seconds
# (0.05 s between unavailable samples), requiring a valid nonempty identity.
# Exhaustion or a failed write wakes the owner and retires the tracked child.
# Catchable stop signals are deferred only across launch/pid registration;
# during identity acquisition ordinary EXIT cleanup already owns that child.
# Activation
# stops the home-bound watcher directly when a recorded arm could not relay
# its stop, removes that turn's files, and
# releases the branch actor's leases; it releases them again after every
# engine turn. It also reads the record of a successor a pass-through left for
# main: while that arm still runs under its recorded identity, the first cycle
# without --restart requests a take-over rather than an ordinary attach.
# Activation removes the
# record only once that identity is no longer alive, so a later host retries a
# take-over that left it running.
#
# STOP. fm-supervision-host.sh stop ends this home's host park on request, at
# any point, for anything an idle host would otherwise hold up (an install, an
# update, a landing). It reads the host row of state/.supervision-host only as
# a regular file under a 5-second bound, and signals that pid only while its
# current identity equals the recorded one and that identity's command line is
# this script's park verb: a reused pid, a foreign process, or an unreadable
# identity is never signalled. It sends USR1 first and writes nothing before
# it. The host ends its park the way the boundary does (THE PARK BOUNDARY), at
# its next safe point: within a park tick while parked, after an arm launch,
# before an engine turn starts, and at once while it waits on a turn's engine,
# never inside its bookkeeping; a stopped turn's engine is stopped and the
# wake that turn held stays queued; the arms and this home's watcher are
# stopped, so the
# watcher publishes downtime; and it exits 0 with any close already read and one
# "supervision-host: stopped on request" line, which every owner delivers as
# an ordinary wake. Main drains, acknowledges and ends its turn, and that turn
# end starts the next park, which resumes from the durable wake queue. The
# verb leaves the engine record, the latch, the left-successor record and the
# wake queue alone. Only when the host has not exited within
# FM_SUPERVISION_HOST_STOP_WAIT seconds does the verb send TERM (the host's
# signal exit, which its owner retries), and after 10 more seconds KILL; the
# next host's activation stops anything a KILLed host left running. It prints
# one "supervision-host stop:" line, appends it to the host log after any
# signal, and exits 0 when the host stopped on request or was already stopped
# (no record, a dead pid, or a pid that now runs another process), 3 when it
# had to be forced, and 1 when it refused or the host still runs.
#
# STATE (all under state/, owned here): .supervision-host (this host's pid and
# the processes it runs), .supervision-host-engine (the engine conversation:
# engine, model, session id, main-session key, turn count, running cost),
# .supervision-host-turn and .supervision-host-receipts (the current turn's
# report scope and the reports it recorded), .supervision-host-prompt and
# .supervision-host-wake (the prompt and wake text of the current turn),
# .supervision-host-mirror (the dialog-mirror feed while an attended wake is
# rendered), .supervision-host-left (the pid and identity of the successor arm a
# pass-through left running for main, until that arm is gone),
# .supervision-host-health (the latch: errors, cooldown, and probe time, keyed
# to the main session, engine, and model), and .supervision-host.log (a bounded
# ledger of where every close went, with each engine turn's usage and
# outcome).
#
# Tunables (environment): FM_SUPERVISION_HOST_PARK_SECONDS (27000; a positive
# integer below the 28800-second registration, any other value is the default),
# FM_SUPERVISION_HOST_PARK_LIMIT (the park boundary; a later value below the
# registration lets turns run past the boundary up to it, any other value is
# the boundary), FM_SUPERVISION_HOST_TURN_TIMEOUT (1200), FM_SUPERVISION_HOST_ROTATE_TURNS (20:
# a new engine conversation after this many turns; every main session start
# also opens a new one), FM_SUPERVISION_HOST_READY_TIMEOUT (25: how long a
# successor cycle may take to verify), FM_SUPERVISION_HOST_POLL (1),
# FM_SUPERVISION_HOST_STOP_WAIT (120: how long the stop verb waits for the
# host to end its park on request before it escalates; read by the verb).
# Park duration uses Bash's process-relative SECONDS counter (including Bash
# 3.2) and, where /proc/uptime exists, the boot clock since the owner's start
# (THE PARK BOUNDARY), each read without a fork; durable timestamps still use
# epoch time. Arm exit probes use a 0.5-second builtin read on
# a private, unlinked FIFO on Bash 4+ (fractional read timeouts); Bash 3.2 keeps
# ordinary 0.5-second child sleeps. Maintenance and boundary checks keep their
# POLL cadence, and close observation still takes at most that probe interval
# plus work/scheduling time. A builtin wait is interruptible by a caught signal;
# HUP/TERM use native fatal handling and EXIT cleanup outside that read, so
# a foreground bookkeeping helper cannot defer shutdown. USR1 is the stop
# request (STOP), caught throughout and honoured at a safe point, so a park
# tick bounds its wait outside an engine turn. A FIFO setup or read
# failure exits with a supervision-host wake instead of spinning.
# FM_TEST_SUPERVISION_HOST_CLOCK names a file holding the park's elapsed
# seconds, which the park and turn boundary checks read in place of SECONDS,
# and FM_TEST_SUPERVISION_HOST_UPTIME names a file read in place of
# /proc/uptime (unset beside the first, the boot clock is not read), both only
# when FM_TEST_SEAM=1; tests/lib.sh arms the marker for isolated suites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

FIRST_ARM_RESTART=0
HOST_VERB=park
case "${1:-}" in
  park)
    case "$#:${2:-}" in
      1:) ;;
      2:--restart) FIRST_ARM_RESTART=1 ;;
      *) echo "usage: fm-supervision-host.sh park [--restart] | stop" >&2; exit 2 ;;
    esac
    ;;
  stop)
    [ "$#" -eq 1 ] || { echo "usage: fm-supervision-host.sh park [--restart] | stop" >&2; exit 2; }
    HOST_VERB=stop
    ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: fm-supervision-host.sh park [--restart] | stop" >&2; exit 2 ;;
esac

numeric_or() {  # <value> <default>
  case "$1" in ''|0*|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
ENGINE_GRACE=$(numeric_or "${FM_SUPERVISION_ENGINE_GRACE:-}" 30)
PARK_SECONDS=$(numeric_or "${FM_SUPERVISION_HOST_PARK_SECONDS:-}" 27000)
[ "$PARK_SECONDS" -lt 28800 ] 2>/dev/null || PARK_SECONDS=27000
PARK_LIMIT=$(numeric_or "${FM_SUPERVISION_HOST_PARK_LIMIT:-}" "$PARK_SECONDS")
{ [ "$PARK_LIMIT" -lt 28800 ] && [ "$PARK_LIMIT" -ge "$PARK_SECONDS" ]; } 2>/dev/null || PARK_LIMIT=$PARK_SECONDS
TURN_TIMEOUT=$(numeric_or "${FM_SUPERVISION_HOST_TURN_TIMEOUT:-}" 1200)
ROTATE_TURNS=$(numeric_or "${FM_SUPERVISION_HOST_ROTATE_TURNS:-}" 20)
READY_TIMEOUT=$(numeric_or "${FM_SUPERVISION_HOST_READY_TIMEOUT:-}" 25)
POLL=$(numeric_or "${FM_SUPERVISION_HOST_POLL:-}" 1)
COOLDOWN=$FM_SUPERVISION_HOST_COOLDOWN
COOLDOWN_MAX=3600
AUTOARM_GEN=${FM_SUPERVISION_HOST_AUTOARM_GEN:-}
AUTOARM_OWNER=${FM_SUPERVISION_HOST_OWNER_PID:-}
PRIMARY=${FM_SUPERVISION_HOST_PRIMARY:-}
[ -n "$PRIMARY" ] || PRIMARY=$(fm_supervision_host_primary)
# The owner's predecessor arm belongs to the first cycle only.
OWNER_PREDECESSOR=${FM_WATCH_PREDECESSOR_ARM_PID:-}
case "$OWNER_PREDECESSOR" in *[!0-9]*) OWNER_PREDECESSOR= ;; esac
unset FM_WATCH_PREDECESSOR_ARM_PID FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN

HOST_RECORD="$STATE/.supervision-host"
ENGINE_RECORD="$STATE/.supervision-host-engine"
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"
PROMPT_FILE="$STATE/.supervision-host-prompt"
WAKE_FILE="$STATE/.supervision-host-wake"
HOST_LOG="$STATE/.supervision-host.log"
ENGINE_PID_FILE="$STATE/.supervision-host.engine-pid"
HEALTH_FILE="$STATE/.supervision-host-health"
MIRROR_FEED="$STATE/.supervision-host-mirror"
LEFT_RECORD="$STATE/.supervision-host-left"

HOST_PID=$$
HOST_STARTED_SECONDS=$SECONDS
HOST_STARTED=$(date +%s)
GEN="host-$HOST_PID-$HOST_STARTED"
TURN_SEQ=0
LAST_TURN=
TURN_POSTURE=
ENGINE_ERROR=0
HEALTH_NOTE=
GRANT_ACTIVE=0
ARM_PID=
ARM_OUT=
ARM_TEXT=
ARM_START_FAILURE=
CLOSED_ARM_PID=
HANDLE_WHY=
HANDLE_RC=0
ENGINE_SUBSHELL=
SUCCESSOR_PID=
SUCCESSOR_OUT=
SUCCESSOR_WATCHER=
SUCCESSOR_GENERATION=
ENGINE_RUNNING=0
# The successor arm a predecessor's pass-through left for main, which the
# first cycle takes over.
LEFT_ARM=
# The running turn's result and diagnostics files, removed by the cleanup when
# the host is stopped mid-turn.
TURN_RESULT=
TURN_ERRORS=
# The first cycle's status line, printed as soon as the arm prints it
# (header, OUTPUT) and left out of that cycle's close.
READY_PENDING=1
READY_LINE=
# Descriptor 9 is reserved for the host's private timeout FIFO, never stdin.
WAIT_BUILTIN=0
WAIT_DIR=
WAIT_READING=0
WAIT_SIGNAL=0
ARM_LAUNCHING=0
LAUNCH_SIGNAL=0
# The first caught signal's exit status, and whether an exit path printed its
# close (emit): the cleanup names an exit that did neither.
HOST_SIGNALLED=
HOST_EMITTED=0
# A stop request (USR1 from the stop verb): whether one arrived, whether the
# host is activated far enough to honour it, whether it is waiting on an
# engine turn (the one wait the trap ends at once), and whether an exit is
# already under way, which a request never interrupts.
HOST_STOP_REQUESTED=0
HOST_STOP_READY=0
HOST_STOP_AT_ONCE=0
HOST_ENDING=0
STOP_WAIT=$(numeric_or "${FM_SUPERVISION_HOST_STOP_WAIT:-}" 120)

log_line() {  # <text>
  local tmp
  printf '%s\t%s\n' "$(date +%s)" "$1" >> "$HOST_LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$HOST_LOG" 2>/dev/null | tr -d ' ')" -gt 600 ] 2>/dev/null; then
    tmp=$(mktemp "$HOST_LOG.tmp.XXXXXX" 2>/dev/null) || return 0
    tail -n 400 "$HOST_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$HOST_LOG" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
  fi
}

identity_of() {  # <pid>
  local identity
  _fm_engine_identity_to identity "$1" || return 0
  printf '%s\n' "$identity"
}

# Startup only: never publish an empty proof when a child crosses exec.
# The caller has registered this child with cleanup before entering here.
record_process() {  # <role> <pid> [launch-token]
  local identity deadline=$((SECONDS + 5))
  while :; do
    if _fm_engine_identity_to identity "$2" && [ -n "$identity" ]; then
      printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$identity" "${3:-}" >> "$HOST_RECORD" 2>/dev/null
      return $?
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

# Re-record a process under its current identity. Safe only for this host's
# own unreaped child, whose pid cannot be recycled: its first identity may have
# been read between its fork and its exec. The await loop runs this every
# second, so the identity and the record are read in the shell and only a
# changed identity starts a process.
refresh_process() {  # <pid>
  local pid=$1 identity tmp role='' recorded_pid='' recorded_identity='' launch_token='' stale=0
  [ -n "$pid" ] && [ -f "$HOST_RECORD" ] || return 0
  _fm_engine_identity_to identity "$pid" || true
  [ -n "$identity" ] || return 0
  while IFS=$'\t' read -r role recorded_pid recorded_identity launch_token || [ -n "$role" ]; do
    [ "$recorded_pid" = "$pid" ] && [ "$recorded_identity" != "$identity" ] && stale=1
    role=
  done 2>/dev/null < "$HOST_RECORD"
  [ "$stale" -eq 1 ] || return 0
  tmp=$(mktemp "$HOST_RECORD.tmp.XXXXXX" 2>/dev/null) || return 0
  awk -F '\t' -v OFS='\t' -v pid="$pid" -v id="$identity" '$2 == pid { $3 = id } { print }' "$HOST_RECORD" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$HOST_RECORD" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

forget_process() {  # <pid>
  local tmp
  [ -f "$HOST_RECORD" ] || return 0
  tmp=$(mktemp "$HOST_RECORD.tmp.XXXXXX" 2>/dev/null) || return 0
  awk -F '\t' -v pid="$1" '$2 != pid' "$HOST_RECORD" > "$tmp" 2>/dev/null && mv -f "$tmp" "$HOST_RECORD" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# An arm can exec after its first recording. Match both its birth and the
# unique home/role launch token retained in argv across that exec. Neither a
# recycled pid nor another process with the same birth tick owns that token.
# Legacy rows and non-arm processes still require their entire identity.
recorded_identity_matches() {  # <pid> <identity> [launch-token]
  local current token=${3:-} recorded_birth current_birth argv_hex
  current=$(identity_of "$1")
  MATCH_CURRENT=$current
  MATCH_REASON=exact-identity
  [ -n "$2" ] || { MATCH_REASON=empty-recorded-identity; return 1; }
  [ -n "$current" ] || { MATCH_REASON='current-identity-unavailable'; return 1; }
  [ "$current" != "$2" ] || return 0
  MATCH_REASON='identity-mismatch-without-launch-token'
  [ -n "$token" ] || return 1
  MATCH_REASON=invalid-launch-token
  case "$token" in "$STATE"/.supervision-host-arm.??????) ;; *) return 1 ;; esac
  case "$2" in
    *-starttime=*' cmdline-hex='*)
      recorded_birth=${2%% cmdline-hex=*}
      current_birth=${current%% cmdline-hex=*}
      MATCH_REASON='birth-mismatch'
      [ "$recorded_birth" = "$current_birth" ] || return 1
      MATCH_REASON=launch-argv-mismatch
      argv_hex=$(printf '%s\0' "$SCRIPT_DIR/fm-watch-arm.sh" --host-arm "$token" | od -An -v -tx1)
      argv_hex=${argv_hex//[[:space:]]/}
      case "${current#* cmdline-hex=}" in *"00$argv_hex"*) MATCH_REASON='birth-and-launch'; return 0 ;; esac
      ;;
    *)
      # Portable ps identity: the first 24 C-locale characters are lstart.
      MATCH_REASON='birth-mismatch'
      [ "${2:0:24}" = "${current:0:24}" ] || return 1
      MATCH_REASON=launch-argv-mismatch
      case "$current" in *" $SCRIPT_DIR/fm-watch-arm.sh --host-arm $token"|*" $SCRIPT_DIR/fm-watch-arm.sh --host-arm $token "*) MATCH_REASON='birth-and-launch'; return 0 ;; esac
      ;;
  esac
  return 1
}

# Stop only a proven recorded process: TERM, then KILL once <seconds> pass.
stop_recorded() {  # <pid> <identity> <seconds> [arm-launch-token]
  local pid=$1 identity=$2 limit=$(( ${3:-10} * 10 )) token=${4:-} i
  STOP_RECORDED_FORCED=0
  MATCH_CURRENT=
  MATCH_REASON=not-alive
  fm_pid_alive "$pid" || return 0
  recorded_identity_matches "$pid" "$identity" "$token" || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  i=0
  while [ "$i" -lt "$limit" ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid" && recorded_identity_matches "$pid" "$identity" "$token"; then
    if kill -KILL "$pid" 2>/dev/null; then
      STOP_RECORDED_FORCED=1
    fi
  fi
}

branch_env() {  # <command...>: run with the branch actor identity
  FM_SUPERVISION_ACTOR=branch "$@"
}

release_branch_leases() {
  branch_env "$SCRIPT_DIR/fm-lease.sh" release-actor --actor branch >/dev/null 2>&1 || true
}

# Snapshot the home-bound watcher before stopping an arm. A fallback must
# signal this identity, never a successor that acquired the lock meanwhile.
# Unreadable, non-regular or unvalidated records give no fallback authority;
# a failed or five-second-bounded snapshot never prevents arm retirement.
capture_home_watcher() {
  local snapshot
  CAPTURED_WATCHER_PID=
  CAPTURED_WATCHER_IDENTITY=
  [ -e "$STATE/.watch.lock" ] || return 0
  # Bookkeeping is optional evidence, never a prerequisite for signalling a
  # proven arm. Reject unsafe records before opening them, and bound the whole
  # read/validation to cover replacement between that check and open as well.
  # Five seconds bounds local metadata only, not watcher readiness or health.
  # shellcheck disable=SC2016 # Expand positional parameters in the bounded child shell, not here.
  if snapshot=$(fm_run_timed 5 bash -c '
    . "$1/fm-wake-lib.sh"
    for name in pid fm-home watcher-path pid-identity; do
      file="$2/.watch.lock/$name"
      [ ! -L "$file" ] && [ -f "$file" ] && [ -r "$file" ] || exit 1
    done
    fm_file_text_to pid "$2/.watch.lock/pid" || exit 1
    fm_watcher_lock_matches_pid "$2" "$1/fm-watch.sh" "$pid" "$3" || exit 1
    printf "%s\t%s\n" "$pid" "$FM_WATCHER_MATCHED_IDENTITY"
  ' _ "$SCRIPT_DIR" "$STATE" "$FM_HOME" 2>/dev/null); then
    IFS=$'\t' read -r CAPTURED_WATCHER_PID CAPTURED_WATCHER_IDENTITY <<< "$snapshot"
  else
    printf 'supervision-host: watcher cleanup snapshot unavailable; no unproven watcher will be signalled\n' >&2
  fi
}

# The lock proves the home, not which arm owns the cycle. Only a watcher's
# actual parent may authorize fallback cleanup after that arm is killed.
captured_watcher_is_child_of() {  # <arm-pid>
  local stat parent
  local -a fields
  [ -n "$CAPTURED_WATCHER_PID" ] || return 1
  if fm_file_text_to stat "/proc/$CAPTURED_WATCHER_PID/stat" 2>/dev/null; then
    read -r -a fields <<< "${stat##*)}"
    [ "${#fields[@]}" -ge 2 ] || return 1
    parent=${fields[1]}
  else
    parent=$(ps -p "$CAPTURED_WATCHER_PID" -o ppid= 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
  fi
  [ -n "$CAPTURED_WATCHER_PID" ] && [ "$parent" = "$1" ]
}

# Stop whatever a predecessor host left running, then take the record. The
# auto-arm admits one generation at a time, so a predecessor still alive here
# was superseded (its owner died or went stale) or crashed mid-cleanup.
activate() {
  local role pid identity launch_token row rest forced_owner=0 owns_watcher watcher_pid watcher_identity
  mkdir -p "$STATE" || return 1
  capture_home_watcher
  watcher_pid=$CAPTURED_WATCHER_PID
  watcher_identity=$CAPTURED_WATCHER_IDENTITY
  if [ -f "$HOST_RECORD" ]; then
    # The predecessor host first, with room for its own cleanup (which stops
    # its engine and arms), before anything it left is stopped individually.
    while IFS="$(printf '\t')" read -r role pid identity launch_token; do
      [ "$role" = host ] || continue
      [ "$pid" != "$HOST_PID" ] || continue
      stop_recorded "$pid" "$identity" $((ENGINE_GRACE + 20))
    done < "$HOST_RECORD"
  fi
  if [ -f "$ENGINE_PID_FILE" ]; then
    IFS="$(printf '\t')" read -r pid identity < "$ENGINE_PID_FILE" || true
    stop_recorded "${pid:-}" "${identity:-}" $((ENGINE_GRACE + 5))
    rm -f "$ENGINE_PID_FILE"
  fi
  if [ -f "$HOST_RECORD" ]; then
    # Preserve empty tab fields: whitespace IFS would move a launch token
    # into an empty identity and lose the actual rejected predecessor proof.
    while IFS= read -r row; do
      role=${row%%$'\t'*}; rest=
      [ "$row" = "$role" ] || rest=${row#*$'\t'}
      pid=${rest%%$'\t'*}; identity=''; launch_token=
      if [ "$rest" != "$pid" ]; then
        rest=${rest#*$'\t'}
        identity=${rest%%$'\t'*}
        [ "$rest" = "$identity" ] || launch_token=${rest#*$'\t'}
      fi
      if [ "$role" = arm ]; then
        owns_watcher=0
        captured_watcher_is_child_of "$pid" && owns_watcher=1
        stop_recorded "$pid" "$identity" 10 "$launch_token"
        log_line "recovery-arm	reason=$MATCH_REASON	current=$MATCH_CURRENT	old-row=$row"
        [ "$STOP_RECORDED_FORCED" -eq 0 ] || [ "$owns_watcher" -eq 0 ] || forced_owner=1
      fi
    done < "$HOST_RECORD"
  fi
  # A caught TERM cannot interrupt an arm's foreground health helper. If its
  # grace expired, killing the arm did not stop the watcher. Stop the verified
  # home-bound identity captured before cleanup, not a newer lock holder.
  # Dead/stale arm rows and cycles another arm owns authorize no fallback.
  # Detached successors also stay for take-over.
  if [ "$forced_owner" -eq 1 ]; then
    stop_recorded "$watcher_pid" "$watcher_identity" 10
  fi
  # A predecessor killed outright ran no cleanup: reap the engine descendants
  # its turn recorded, then drop that turn's files.
  local ledger
  for ledger in "$STATE"/.supervision-host-descendants.*; do
    case "$ledger" in *.pids|*.next) continue ;; esac
    [ -f "$ledger" ] && _fm_engine_reap "$ledger"
  done
  rm -f "$STATE"/.supervision-host-arm.* "$STATE"/.supervision-host-descendants.* "$STATE"/.supervision-host-result.* \
    "$STATE"/.supervision-host-errors.* "$STATE"/.supervision-host-readback.* "$TURN_FILE" "$MIRROR_FEED" 2>/dev/null || true
  # The successor a pass-through left for main: the first cycle takes it over
  # while it still answers to its recorded identity, and its record goes only
  # once it does not.
  if [ -f "$LEFT_RECORD" ]; then
    pid='' identity=''
    IFS="$(printf '\t')" read -r pid identity < "$LEFT_RECORD" || true
    if fm_pid_alive "$pid" && [ -n "$identity" ] && [ "$(identity_of "$pid")" = "$identity" ]; then
      LEFT_ARM=$pid
    else
      rm -f "$LEFT_RECORD"
    fi
  fi
  printf 'host\t%s\t%s\n' "$HOST_PID" "$(identity_of "$HOST_PID")" > "$HOST_RECORD" || return 1
  release_branch_leases
}

# Stop a running engine turn: TERM the bounded process, whose watchdog passes
# it on and KILLs after its grace, then let the turn's own poller reap the
# engine's descendants before giving up on it.
stop_engine_turn() {
  local pid='' identity='' i limit
  [ -f "$ENGINE_PID_FILE" ] && IFS="$(printf '\t')" read -r pid identity < "$ENGINE_PID_FILE"
  if [ -n "$pid" ] && fm_pid_alive "$pid" && [ "$(identity_of "$pid")" = "$identity" ]; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  limit=$(( (ENGINE_GRACE + 10) * 10 ))
  i=0
  while [ -n "$ENGINE_SUBSHELL" ] && fm_pid_alive "$ENGINE_SUBSHELL" && [ "$i" -lt "$limit" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -z "$ENGINE_SUBSHELL" ] || kill -KILL "$ENGINE_SUBSHELL" 2>/dev/null || true
}

# A host stopped by a signal, or one that exits without printing its close,
# leaves a line saying so, with the park clocks and whether its owner is still
# running: no later wake explains such a stop.
log_stopped() {
  local why owner=none
  case "$HOST_SIGNALLED" in
    '') [ "$HOST_EMITTED" -eq 0 ] || return 0
        why='no close was printed (a HUP or TERM outside the park wait, or an unplanned exit)' ;;
    129) why='signal HUP' ;;
    130) why='signal INT' ;;
    143) why='signal TERM' ;;
    *) why="signal status $HOST_SIGNALLED" ;;
  esac
  if [ -n "$AUTOARM_OWNER" ]; then
    owner="$AUTOARM_OWNER gone"
    ! kill -0 "$AUTOARM_OWNER" 2>/dev/null || owner="$AUTOARM_OWNER alive"
  fi
  park_elapsed
  log_line "stopped	$why	after ${PARK_ELAPSED}s wall=${PARK_WALL}s boot=${PARK_BOOT:-none}${PARK_BOOT:+s}	owner=$owner"
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local rc=$? f
  HOST_ENDING=1
  trap - EXIT HUP TERM INT
  exec 9>&-
  if [ -n "$WAIT_DIR" ]; then
    rm -f "$WAIT_DIR/tick" 2>/dev/null || true
    rmdir "$WAIT_DIR" 2>/dev/null || true
  fi
  if [ "$ENGINE_RUNNING" -eq 1 ]; then
    stop_engine_turn
  fi
  retire_arm "$SUCCESSOR_PID" "$SUCCESSOR_OUT"
  retire_arm "$ARM_PID" "$ARM_OUT"
  log_stopped
  if [ "$GRANT_ACTIVE" -eq 1 ]; then
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    "$SCRIPT_DIR/fm-wake-grant.sh" deactivate "$HOST_PID" "$GEN" >/dev/null 2>&1 || true
  fi
  release_branch_leases
  rm -f "$TURN_FILE" "$ENGINE_PID_FILE" 2>/dev/null || true
  for f in "$TURN_RESULT" "$TURN_ERRORS"; do
    case "$f" in "$STATE"/.supervision-host-*) rm -f "$f" 2>/dev/null || true ;; esac
  done
  if [ -f "$HOST_RECORD" ] && [ "$(awk -F '\t' '$1 == "host" { print $2; exit }' "$HOST_RECORD" 2>/dev/null)" = "$HOST_PID" ]; then
    rm -f "$HOST_RECORD" 2>/dev/null || true
  fi
  exit "$rc"
}
# Stop one arm this host started (its TERM handler stops the watcher it owns)
# and drop its output file.
retire_arm() {  # <pid> <output-file>
  local pid=${1:-} out=${2:-} i watcher_pid watcher_identity owns_watcher=0
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    capture_home_watcher
    watcher_pid=$CAPTURED_WATCHER_PID
    watcher_identity=$CAPTURED_WATCHER_IDENTITY
    captured_watcher_is_child_of "$pid" && owns_watcher=1
    kill -TERM "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 100 ] && fm_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if fm_pid_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      # The arm could not run its handler. Never leave that watcher behind,
      # but never reach a successor that took the lock while the arm stopped.
      [ "$owns_watcher" -eq 0 ] || stop_recorded "$watcher_pid" "$watcher_identity" 10
    fi
    wait "$pid" 2>/dev/null || true
  fi
  [ -z "$pid" ] || forget_process "$pid"
  [ -z "$out" ] || rm -f "$out" 2>/dev/null || true
}

host_still_owner() {
  fm_session_lock_owned_by_self "$STATE" || return 1
  [ -n "$AUTOARM_GEN" ] || return 0
  fm_autoarm_ledger_read "$STATE" || return 1
  [ "$FM_AUTOARM_GEN" = "$AUTOARM_GEN" ] && [ "$FM_AUTOARM_OWNER" = "$AUTOARM_OWNER" ] \
    && [ "$FM_AUTOARM_OUTCOME" = arming ]
}

start_arm() {  # <pid-variable> <output-variable> <predecessor or empty> [arm flags]
  local pid_variable=$1 out_variable=$2 predecessor=$3 out pid
  shift 3
  ARM_START_FAILURE=
  out=$(mktemp "$STATE/.supervision-host-arm.XXXXXX") || return 1
  printf -v "$out_variable" '%s' "$out"
  # No stop may exit between the asynchronous launch and cleanup owning $!.
  ARM_LAUNCHING=1
  LAUNCH_SIGNAL=0
  trap 'host_signal 129' HUP
  trap 'host_signal 143' TERM
  # An arm left for main outlives this host, and Claude tears the hook's
  # process group down after the exit-2 rewake, so it gets a group of its own
  # (the shape start_handling_successor in bin/fm-claude-stop-autoarm.sh uses).
  [ "${ARM_OWN_GROUP:-0}" -ne 1 ] || set -m 2>/dev/null || true
  if [ -n "$predecessor" ]; then
    # shellcheck disable=SC2094 # --host-arm retains this pathname only as an argv identity token; it never reads it.
    FM_WATCH_PREDECESSOR_ARM_PID=$predecessor FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" --host-arm "$out" "$@" >"$out" 2>&1 </dev/null &
  else
    # shellcheck disable=SC2094 # --host-arm retains this pathname only as an argv identity token; it never reads it.
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" --host-arm "$out" "$@" >"$out" 2>&1 </dev/null &
  fi
  pid=$!
  printf -v "$pid_variable" '%s' "$pid"
  ARM_LAUNCHING=0
  host_stop_signals
  [ "$LAUNCH_SIGNAL" -eq 0 ] || exit "$LAUNCH_SIGNAL"
  [ "${ARM_OWN_GROUP:-0}" -ne 1 ] || set +m 2>/dev/null || true
  stop_if_requested
  if ! record_process arm "$pid" "$out"; then
    log_line "arm-start-failed	pid=$pid	initial identity unavailable within 5s or record unwritable"
    ARM_START_FAILURE='supervision-host: initial arm identity could not be recorded within 5s; retiring the owned child; drain and re-arm supervision'
    return 1
  fi
}

# The boot-clock second the owner process started (THE PARK BOUNDARY), read
# once at startup from Linux /proc/<pid>/stat field 22; empty off Linux or
# where there is no boot clock to read, and the park then runs on SECONDS
# alone.
PARK_UPTIME=/proc/uptime
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  if [ -n "${FM_TEST_SUPERVISION_HOST_UPTIME:-}" ]; then
    PARK_UPTIME=$FM_TEST_SUPERVISION_HOST_UPTIME
  elif [ -n "${FM_TEST_SUPERVISION_HOST_CLOCK:-}" ]; then
    PARK_UPTIME=
  fi
fi
PARK_BOOT_START=
park_boot_start() {
  local pid stat ticks hz
  local -a fields
  [ -n "$PARK_UPTIME" ] && [ "$_FM_UNAME" = Linux ] && [ -r /proc/uptime ] || return 0
  hz=$(numeric_or "$(getconf CLK_TCK 2>/dev/null)" 100)
  for pid in "$AUTOARM_OWNER" "$HOST_PID"; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    fm_file_text_to stat "/proc/$pid/stat" || continue
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a fields <<< "${stat##*)}"
    ticks=${fields[19]:-}
    case "$ticks" in ''|*[!0-9]*) continue ;; esac
    PARK_BOOT_START=$((ticks / hz))
    return 0
  done
  log_line "park-clock	the owner's boot-clock start is unreadable; the park runs on the wall clock alone"
}

park_elapsed() {  # Sets PARK_ELAPSED, PARK_WALL and PARK_BOOT without a production clock/helper fork.
  local up _
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_SUPERVISION_HOST_CLOCK:-}" ]; then
    PARK_WALL=$(numeric_or "$(cat "$FM_TEST_SUPERVISION_HOST_CLOCK" 2>/dev/null)" 0)
  else
    PARK_WALL=$((SECONDS - HOST_STARTED_SECONDS))
  fi
  PARK_ELAPSED=$PARK_WALL
  PARK_BOOT=
  [ -n "$PARK_BOOT_START" ] || return 0
  { IFS=' .' read -r up _ < "$PARK_UPTIME"; } 2>/dev/null || return 0
  case "$up" in ''|*[!0-9]*) return 0 ;; esac
  [ "$up" -ge "$PARK_BOOT_START" ] || return 0
  PARK_BOOT=$((up - PARK_BOOT_START))
  [ "$PARK_BOOT" -le "$PARK_ELAPSED" ] || PARK_ELAPSED=$PARK_BOOT
}

boundary_reached() {
  park_elapsed
  [ "$PARK_ELAPSED" -ge "$PARK_SECONDS" ]
}

# True when an engine turn started now could still be running at the turn
# limit (the boundary unless the owner set a later one).
turn_crosses_boundary() {
  park_elapsed
  [ $((PARK_ELAPSED + TURN_TIMEOUT + ENGINE_GRACE)) -ge "$PARK_LIMIT" ]
}

# End the park on purpose: stop the current and successor arms and this
# home's watcher, print any close already read so main drains it, then <line>.
end_park() {  # <log-event> <line>
  HOST_ENDING=1
  retire_arm "$ARM_PID" "$ARM_OUT"
  retire_arm "$SUCCESSOR_PID" "$SUCCESSOR_OUT"
  ARM_PID=
  ARM_OUT=
  SUCCESSOR_PID=
  SUCCESSOR_OUT=
  "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  park_elapsed
  log_line "$1	after ${PARK_ELAPSED}s	wall=${PARK_WALL}s boot=${PARK_BOOT:-none}${PARK_BOOT:+s}"
  emit "$2"
  exit 0
}

boundary_exit() {
  end_park boundary 'supervision-host: cycle boundary - the host ended its park at its bound; drain, acknowledge, and end the turn, and the next park starts on its own'
}

# End the park on a stop request (header, STOP), the way the boundary ends it,
# after stopping a running engine turn; the wake that turn held stays queued.
stop_exit() {
  HOST_ENDING=1
  if [ "$ENGINE_RUNNING" -eq 1 ]; then
    stop_engine_turn
    ENGINE_RUNNING=0
  fi
  end_park stop-requested 'supervision-host: stopped on request - fm-supervision-host.sh stop ended the park; drain, acknowledge, and end the turn, and the next park starts on its own'
}

# The USR1 trap. While the host waits on an engine turn it ends the park at
# once; anywhere else it only records the request, which the next safe point
# honours (stop_if_requested), so no bookkeeping is cut short.
# shellcheck disable=SC2329 # Invoked by the USR1 trap.
host_stop_request() {
  HOST_STOP_REQUESTED=1
  [ "$HOST_STOP_AT_ONCE" -eq 0 ] || stop_if_requested
}

# A safe point: end the park here if a stop was requested.
stop_if_requested() {
  if [ "$HOST_STOP_REQUESTED" -eq 1 ] && [ "$HOST_STOP_READY" -eq 1 ] \
    && [ "$HOST_ENDING" -eq 0 ] && [ "$HOST_EMITTED" -eq 0 ]; then
    stop_exit
  fi
}

# Print the first cycle's status line once the arm has written it in full.
stream_ready_line() {
  local complete line
  complete=$(wc -l < "$ARM_OUT" 2>/dev/null | tr -d ' ')
  case "$complete" in ''|0|*[!0-9]*) return 0 ;; esac
  line=$(head -n "$complete" "$ARM_OUT" 2>/dev/null | grep -E -m 1 '^watcher: (started|attached) ' || true)
  [ -n "$line" ] || return 0
  printf '%s\n' "$line"
  READY_LINE=$line
  READY_PENDING=0
}

# An O_RDWR FIFO keeps its own writer open: read blocks until its timeout,
# with no child process and no EOF spin. Unlink it before starting any arm so
# no other process can open it. Bash 3.2 cannot read with a fractional timeout.
prepare_park_wait() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || return 0
  WAIT_DIR=$(mktemp -d "$STATE/.supervision-host-wait.XXXXXX") || return 1
  mkfifo -m 600 "$WAIT_DIR/tick" || return 1
  exec 9<> "$WAIT_DIR/tick" || return 1
  rm -f "$WAIT_DIR/tick" && rmdir "$WAIT_DIR" || return 1
  WAIT_DIR=
  WAIT_BUILTIN=1
}

# Only timed read needs caught HUP/TERM: unwind it before EXIT cleanup closes
# its descriptor (exiting inside read can abort some Bash versions). Elsewhere
# native fatal handling runs EXIT cleanup without waiting for a foreground
# bookkeeping helper; a caught signal would wait for that helper to finish.
host_stop_signals() {
  trap - HUP TERM
  trap 'host_signal 130' INT
}

host_signal() {  # <exit-status>
  [ -n "$HOST_SIGNALLED" ] || HOST_SIGNALLED=$1
  if [ "$ARM_LAUNCHING" -eq 1 ]; then
    [ "$LAUNCH_SIGNAL" -ne 0 ] || LAUNCH_SIGNAL=$1
  elif [ "$WAIT_READING" -eq 1 ]; then
    [ "$WAIT_SIGNAL" -ne 0 ] || WAIT_SIGNAL=$1
  else
    exit "$1"
  fi
}

park_wait_half_second() {
  local _ rc
  if [ "$WAIT_BUILTIN" -eq 0 ]; then
    sleep 0.5
    stop_if_requested
    return
  fi
  trap 'host_signal 129' HUP
  trap 'host_signal 143' TERM
  WAIT_READING=1
  if IFS= read -r -t 0.5 -u 9 _; then rc=0; else rc=$?; fi
  WAIT_READING=0
  host_stop_signals
  [ "$WAIT_SIGNAL" -eq 0 ] || exit "$WAIT_SIGNAL"
  stop_if_requested
  # A timeout returns >128. EOF, a bad descriptor or unexpected data must not
  # turn a broken timer into a busy loop; cleanup still retires the arms.
  if [ "$rc" -le 128 ]; then
    emit 'supervision-host: park timer failed; drain and re-arm supervision'
    exit 1
  fi
}

# One bounded existing wait interval. Kept callable for isolated CI calibration
# with a private process identity; it starts no arm, engine or watcher.
host_wait_interval() {
  local i
  refresh_process "$ARM_PID"
  [ "$READY_PENDING" -eq 0 ] || stream_ready_line
  boundary_reached && return 1
  # Preserve the outer identity/readiness/boundary cadence and half-second probes.
  i=$((POLL * 2))
  while [ "$i" -gt 0 ] && fm_pid_alive "$ARM_PID"; do
    park_wait_half_second
    fm_supervision_tick_loop
    i=$((i - 1))
  done
  return 0
}

# Wait for the current arm to close. Returns 0 with ARM_TEXT set,
# or 1 when the park boundary arrives first.
await_close() {
  while fm_pid_alive "$ARM_PID"; do
    host_wait_interval || return 1
  done
  wait "$ARM_PID" 2>/dev/null || true
  ARM_TEXT=$(cat "$ARM_OUT" 2>/dev/null || true)
  if [ -n "$READY_LINE" ]; then
    # Already printed: drop its first occurrence from this first close.
    ARM_TEXT=$(printf '%s\n' "$ARM_TEXT" | awk -v line="$READY_LINE" '!dropped && $0 == line { dropped = 1; next } { print }')
    READY_LINE=
  fi
  READY_PENDING=0
  forget_process "$ARM_PID"
  rm -f "$ARM_OUT" 2>/dev/null || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
  ARM_OUT=
  return 0
}

# Print the close read so far, then the given lines, in one write (header,
# OUTPUT), so an owner reading a stream sees the whole exit at once.
emit() {  # [line...]
  local text=$ARM_TEXT line
  HOST_EMITTED=1
  for line in "$@"; do
    [ -n "$line" ] || continue
    text=${text:+$text$'\n'}$line
  done
  [ -z "$text" ] || printf '%s\n' "$text"
}

# Stop the successor cycle: the state main's own turn end starts from without
# the host.
retire_successor() {
  [ -n "$SUCCESSOR_PID" ] || return 0
  retire_arm "$SUCCESSOR_PID" "$SUCCESSOR_OUT"
  SUCCESSOR_PID=
  SUCCESSOR_OUT=
  "$SCRIPT_DIR/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

# Hand the close to main: stop the successor cycle, print the close, why, and
# any further "supervision-host:" lines, and exit.
exit_to_main() {  # <why> [further lines]
  local lines=${2:-} rc=0
  retire_successor
  if [ -n "$SUCCESSOR_GENERATION" ] \
    && ! fm_recovery_marker_publish "$STATE/.watcher-down" downtime >/dev/null 2>&1; then
    log_line "to-main	downtime-unrestored	$1"
    lines=${lines:+$lines$'\n'}"supervision-host: watcher downtime could not be restored for the main hand-back"
    rc=1
  fi
  log_line "to-main	$1"
  emit "supervision-host: $1" "$lines"
  exit "$rc"
}

# The outcome store (bin/fm-branch-outcome.sh) owns and validates these rows.
# True when the captain returned during this close's engine turn and that turn
# recorded visible outcomes; sets RETURNED_ROWS and RETURNED_SEQS. A lookup
# failure is distinct from a valid turn with no visible outcomes.
TURN_RECEIPT_SEQS=
RETURNED_ROWS=
RETURNED_SEQS=
RETURNED_LOOKUP_FAILED=0
returned_during_turn() {
  TURN_RECEIPT_SEQS=
  RETURNED_ROWS=
  RETURNED_SEQS=
  RETURNED_LOOKUP_FAILED=0
  [ -n "$LAST_TURN" ] && [ "$TURN_POSTURE" = away ] && ! fm_afk_contract_away_present "$STATE" || return 1
  if ! TURN_RECEIPT_SEQS=$(awk -F '\t' -v turn="$LAST_TURN" \
    '$1 == turn { printf "%s%s", sep, $2; sep = "," }' "$RECEIPTS" 2>/dev/null); then
    RETURNED_LOOKUP_FAILED=1
    return 1
  fi
  [ -n "$TURN_RECEIPT_SEQS" ] || return 1
  if ! RETURNED_ROWS=$("$SCRIPT_DIR/fm-branch-outcome.sh" lookup --seqs "$TURN_RECEIPT_SEQS" 2>/dev/null); then
    RETURNED_LOOKUP_FAILED=1
    return 1
  fi
  if ! RETURNED_SEQS=$(printf '%s\n' "$RETURNED_ROWS" \
    | jq -rs 'map(select(.silent != true) | .seq | tostring) | join(", ")'); then
    RETURNED_LOOKUP_FAILED=1
    return 1
  fi
  [ -n "$RETURNED_SEQS" ]
}

# One "supervision-host:" line per visible outcome selected above.
turn_outcome_lines() {
  [ -n "$RETURNED_ROWS" ] || return 0
  printf '%s\n' "$RETURNED_ROWS" \
    | jq -r 'select(.silent != true)
        | "supervision-host: outcome \(.seq) for \(.task) [\(.verdict)]: \(.summary)"' \
    | tr -d '\r'
}

turn_outcome_lookup_warning() {
  printf 'supervision-host: outcome lookup failed for turn receipt rows %s; visible outcomes may require manual review' \
    "${TURN_RECEIPT_SEQS:-unknown}"
}

stand_down() {  # <why>
  log_line "stand-down	$1"
  emit "supervision-host stood down: $1"
  exit 0
}

# Start the successor cycle and wait until it proves a live watcher. Sets
# SUCCESSOR_WATCHER and SUCCESSOR_GENERATION (empty when the arm attached).
start_successor() {  # <predecessor-arm-pid>
  local deadline line
  SUCCESSOR_WATCHER=
  SUCCESSOR_GENERATION=
  start_arm SUCCESSOR_PID SUCCESSOR_OUT "$1" || return 1
  deadline=$(( $(date +%s) + READY_TIMEOUT ))
  while :; do
    line=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$SUCCESSOR_OUT" 2>/dev/null | head -n 1)
    if [ -n "$line" ]; then
      SUCCESSOR_WATCHER=$(printf '%s\n' "$line" | sed -E 's/^watcher: (started|attached) pid=([0-9]+).*/\2/')
      case "$line" in
        *' recovery-generation='*) SUCCESSOR_GENERATION=${line##* recovery-generation=} ;;
      esac
      refresh_process "$SUCCESSOR_PID"
      return 0
    fi
    fm_pid_alive "$SUCCESSOR_PID" || return 1
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

# Record the successor for the next host to take over, then drop it from this
# host's cleanup without stopping it. A successor whose record does not read
# back as a regular file holding exactly its pid and identity stays tracked,
# so the cleanup stops it and main's next turn end arms a fresh cycle; that
# returns 1. The shell signals background jobs when it exits, and this arm's
# handler would then stop the watcher, so disown it first. The capture file
# stays tracked so the EXIT trap unlinks it; the arm already holds that
# descriptor and keeps waiting on the watcher.
detach_successor() {
  local identity tmp=
  [ -n "${SUCCESSOR_PID:-}" ] || return 0
  identity=$(identity_of "$SUCCESSOR_PID")
  if [ -z "$identity" ] || ! tmp=$(mktemp "$LEFT_RECORD.tmp.XXXXXX" 2>/dev/null) \
    || ! printf '%s\t%s\n' "$SUCCESSOR_PID" "$identity" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$LEFT_RECORD" 2>/dev/null \
    || [ -L "$LEFT_RECORD" ] || [ ! -f "$LEFT_RECORD" ] \
    || [ "$(cat "$LEFT_RECORD" 2>/dev/null)" != "$SUCCESSOR_PID"$'\t'"$identity" ]; then
    [ -z "$tmp" ] || rm -f "$tmp" "$LEFT_RECORD/${tmp##*/}" 2>/dev/null || true
    log_line "pass-through	successor-unrecorded	$(printf '%s\n' "$REASON" | head -n 1)"
    return 1
  fi
  disown "$SUCCESSOR_PID" 2>/dev/null || true
  forget_process "$SUCCESSOR_PID"
  SUCCESSOR_PID=
}

# Start the same successor a handled wake starts and leave it running. It
# confirms no handling handoff: main, not the engine, handles this close, and
# the re-arm owner delivers it only while the recovery marker still reads
# downtime (autoarm_commit in bin/fm-claude-stop-autoarm.sh). A failed start
# returns 1; the caller still prints the close unchanged.
leave_successor_for_main() {
  if ! ARM_OWN_GROUP=1 start_successor "$CLOSED_ARM_PID"; then
    log_line "pass-through	successor-unverified	$(printf '%s\n' "$REASON" | head -n 1)"
    return 1
  fi
  detach_successor
}

# The engine conversation for this turn: the recorded one while it belongs to
# this main session and has turns left, otherwise a new one. Sets ENGINE_SESSION
# and ENGINE_MODE (new|resume).
choose_conversation() {
  local key recorded_key recorded_session recorded_engine recorded_model turns
  key=$(fm_supervision_host_main_key "$STATE") || key=
  recorded_key=$(sed -n 's/^key=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  recorded_session=$(sed -n 's/^session=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  recorded_engine=$(sed -n 's/^engine=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  recorded_model=$(sed -n 's/^model=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
  turns=$(numeric_or "$(sed -n 's/^turns=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)" 0)
  if [ -n "$key" ] && [ -n "$recorded_session" ] && [ "$recorded_key" = "$key" ] \
    && [ "$recorded_engine" = "$FM_SUPERVISION_ENGINE" ] \
    && [ "$recorded_model" = "$FM_SUPERVISION_ENGINE_MODEL" ] \
    && [ "$turns" -lt "$ROTATE_TURNS" ] && [ -s "$PROMPT_FILE" ]; then
    ENGINE_SESSION=$recorded_session
    ENGINE_MODE=resume
    ENGINE_TURNS=$turns
    ENGINE_COST=$(sed -n 's/^conversation_cost=//p' "$ENGINE_RECORD" 2>/dev/null | head -n 1)
    ENGINE_KEY=$key
    return 0
  fi
  ENGINE_SESSION=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$ENGINE_SESSION" in
    ????????-????-????-????-????????????) ;;
    *) ENGINE_SESSION=$(node -e 'process.stdout.write(require("node:crypto").randomUUID())' 2>/dev/null) || return 1 ;;
  esac
  ENGINE_MODE=new
  ENGINE_TURNS=0
  ENGINE_COST=0
  ENGINE_KEY=$key
  local tmp
  tmp=$(mktemp "$PROMPT_FILE.tmp.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-branch-prompt.sh" > "$tmp" 2>/dev/null \
    || [ "$(wc -c < "$tmp" | tr -d ' ')" -lt 1024 ]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$PROMPT_FILE" || return 1
  return 0
}

write_engine_record() {  # <turns> <conversation-cost>
  local tmp
  tmp=$(mktemp "$ENGINE_RECORD.tmp.XXXXXX") || return 1
  printf 'engine=%s\nmodel=%s\nsession=%s\nkey=%s\nturns=%s\nconversation_cost=%s\n' \
    "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" "$ENGINE_SESSION" "$ENGINE_KEY" "$1" "$2" > "$tmp" \
    && mv -f "$tmp" "$ENGINE_RECORD"
}

# Persist health between host parks; the main-session key prevents a recycled
# lock pid from inheriting another session's conversation or latch.
# docs/supervision-host.md "The broken-session latch" owns the policy.
health_key() {
  fm_supervision_host_health_key "$STATE"
}

# Sets HEALTH_ERRORS, HEALTH_COOLDOWN, and HEALTH_RETRY for the current key.
health_load() {
  local key
  HEALTH_ERRORS=0
  HEALTH_COOLDOWN=0
  HEALTH_RETRY=0
  key=$(health_key) || return 0
  [ "$(sed -n 's/^key=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" = "$key" ] || return 0
  HEALTH_ERRORS=$(numeric_or "$(sed -n 's/^errors=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" 0)
  HEALTH_COOLDOWN=$(numeric_or "$(sed -n 's/^cooldown=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" 0)
  HEALTH_RETRY=$(numeric_or "$(sed -n 's/^retry_after=//p' "$HEALTH_FILE" 2>/dev/null | head -n 1)" 0)
}

health_save() {
  local key tmp
  key=$(health_key) || return 0
  tmp=$(mktemp "$HEALTH_FILE.tmp.XXXXXX" 2>/dev/null) || return 0
  printf 'key=%s\nerrors=%s\ncooldown=%s\nretry_after=%s\n' \
    "$key" "$HEALTH_ERRORS" "$HEALTH_COOLDOWN" "$HEALTH_RETRY" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$HEALTH_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

# True while the latch holds main to every wake. Needs the engine config.
health_cooling() {
  local retry
  health_load
  retry=$(fm_supervision_host_paused_until "$STATE") && [ "$(date +%s)" -lt "$retry" ]
}

# Fold one finished turn into the latch. Sets HEALTH_NOTE to the one line main
# is owed when the latch trips for the first time.
health_record() {  # <engine-error 0|1> <reports>
  local now
  now=$(date +%s)
  HEALTH_NOTE=
  health_load
  if [ "$1" -eq 1 ]; then
    HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
    if [ "$HEALTH_ERRORS" -ge 2 ] || [ "$HEALTH_COOLDOWN" -gt 0 ]; then
      if [ "$HEALTH_COOLDOWN" -eq 0 ]; then
        HEALTH_COOLDOWN=$COOLDOWN
        HEALTH_NOTE="supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next $((COOLDOWN / 60)) minutes, then one wake probes it again"
      else
        HEALTH_COOLDOWN=$((HEALTH_COOLDOWN * 2))
        [ "$HEALTH_COOLDOWN" -le "$COOLDOWN_MAX" ] || HEALTH_COOLDOWN=$COOLDOWN_MAX
      fi
      HEALTH_RETRY=$((now + HEALTH_COOLDOWN))
      log_line "latch	errors=$HEALTH_ERRORS	cooldown=${HEALTH_COOLDOWN}s"
    fi
  elif [ "$2" -gt 0 ]; then
    [ "$HEALTH_COOLDOWN" -eq 0 ] || log_line "recovered	after a successful probe"
    HEALTH_ERRORS=0
    HEALTH_COOLDOWN=0
    HEALTH_RETRY=0
  elif [ "$HEALTH_COOLDOWN" -gt 0 ] && [ "$HEALTH_RETRY" -le "$now" ]; then
    HEALTH_RETRY=$((now + HEALTH_COOLDOWN))
  fi
  health_save
}

# Handle one close on the engine, in the posture the record gives when the
# turn starts (TURN_POSTURE). Returns 0 when the wake is handled (or held
# nothing the branch may claim), 2 with ATTENDED_WHY set when the turn starts
# attended and the supervision session may not take the close
# (attended_acceptor, whose offer scan is the turn's scope), else sets HANDLE_WHY and returns 1; sets ENGINE_ERROR
# when the turn failed on the engine itself. Runs in the host's own shell,
# never a subshell, because it advances the host's grant and turn state.
handle_wake() {  # <reason-lines>
  local reason=$1 first scope status corrupted rows tasks unscoped rc turn readback
  local receipts usage result errors unacked mirror
  LAST_TURN=
  ENGINE_ERROR=0
  HEALTH_NOTE=
  TURN_POSTURE=attended
  ! fm_afk_contract_away_present "$STATE" || TURN_POSTURE=away
  first=$(printf '%s\n' "$reason" | head -n 1)
  if [ "$TURN_POSTURE" = attended ]; then
    attended_acceptor "$first" || return 2
    scope=$ATTENDED_OFFER
  else
    set --
    case "$first" in heartbeat*) set -- --heartbeat ;; esac
    if ! scope=$(node "$SCRIPT_DIR/fm-branch-dispatch.mjs" scope "$@" --afk 2>/dev/null); then
      HANDLE_WHY="branch eligibility could not be computed"
      return 1
    fi
  fi
  status=$(printf '%s\n' "$scope" | sed -n 's/^status=//p')
  corrupted=$(printf '%s\n' "$scope" | sed -n 's/^corrupted=//p')
  rows=$(printf '%s\n' "$scope" | sed -n 's/^rows=//p')
  tasks=$(printf '%s\n' "$scope" | sed -n 's/^tasks=//p')
  unscoped=$(printf '%s\n' "$scope" | sed -n 's/^unscoped=//p')
  if [ "$corrupted" = 1 ]; then
    HANDLE_WHY="a queued wake could not be read or resolved to a task record, so its scope is unknown"
    return 1
  fi
  if [ "$status" = empty ] || [ -z "$rows" ]; then
    log_line "no-op	nothing for the branch to claim	$first"
    return 0
  fi
  if [ "$GRANT_ACTIVE" -eq 0 ]; then
    if ! "$SCRIPT_DIR/fm-wake-grant.sh" activate "$HOST_PID" "$GEN" >/dev/null 2>&1; then
      HANDLE_WHY="the branch grant could not be activated"
      return 1
    fi
    GRANT_ACTIVE=1
  fi
  # shellcheck disable=SC2086 # rows is a space-separated list of sequence numbers.
  "$SCRIPT_DIR/fm-wake-grant.sh" publish "$GEN" $rows >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) ;;
    3) HANDLE_WHY="main already claimed these wake rows"; return 1 ;;
    *) HANDLE_WHY="the branch grant could not be published"; return 1 ;;
  esac
  if ! host_still_owner; then
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="this session no longer owns supervision"
    return 1
  fi
  if ! choose_conversation; then
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="the branch prompt or engine conversation could not be prepared"
    return 1
  fi
  TURN_SEQ=$((TURN_SEQ + 1))
  turn="$GEN.$TURN_SEQ"
  LAST_TURN=$turn
  : > "$RECEIPTS"
  printf 'turn=%s\nrows=%s\ntasks=%s\nunscoped=%s\nwake=%s\nposture=%s\n' \
    "$turn" "$rows" "$tasks" "${unscoped:-0}" "$first" "$TURN_POSTURE" > "$TURN_FILE"
  readback=
  if [ "$TURN_POSTURE" = away ]; then
    readback=$(mktemp "$STATE/.supervision-host-readback.XXXXXX") || readback=
    if [ -n "$readback" ]; then
      FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" readback > "$readback" 2>/dev/null || : > "$readback"
    fi
  fi
  # The dialog mirror (bin/fm-host-mirror.sh) rides at the head of an
  # attended wake. The engine never judges without the captain's words, so a
  # feed that cannot be read hands the wake to main. Away needs none, so an
  # away wake never reads the mirror or moves its cursor.
  mirror=$MIRROR_FEED
  rm -f "$mirror"
  if [ "$TURN_POSTURE" = attended ] \
    && ! (umask 077; exec "$SCRIPT_DIR/fm-host-mirror.sh" feed "$ENGINE_SESSION" "$ENGINE_MODE" > "$mirror" 2>/dev/null); then
    rm -f "$TURN_FILE" "$mirror"
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="the dialog mirror could not be read"
    return 1
  fi
  set -- --report "the bin/fm-branch-report.sh command"
  if [ "$TURN_POSTURE" = away ]; then
    set -- "$@" --away ${readback:+--readback-file "$readback"}
  else
    set -- "$@" --mirror-file "$mirror"
  fi
  rm -f "$WAKE_FILE"
  rc=0
  printf '%s\n' "$reason" \
    | (umask 077; exec node "$SCRIPT_DIR/fm-branch-dispatch.mjs" wake-prompt "$@" > "$WAKE_FILE" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$readback" ] || rm -f "$readback"
    rm -f "$TURN_FILE" "$mirror"
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    HANDLE_WHY="the wake prompt could not be rendered"
    [ "$rc" -ne 3 ] || HANDLE_WHY="the dialog mirror could not be read"
    return 1
  fi
  [ -z "$readback" ] || rm -f "$readback"
  rm -f "$mirror"
  if turn_crosses_boundary; then
    rm -f "$TURN_FILE"
    "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
    boundary_exit
  fi
  result=$(mktemp "$STATE/.supervision-host-result.XXXXXX") || result=/dev/null
  errors=$(mktemp "$STATE/.supervision-host-errors.XXXXXX") || errors=/dev/null
  TURN_RESULT=$result
  TURN_ERRORS=$errors
  stop_if_requested
  ENGINE_RUNNING=1
  # Backgrounded and waited, so a signal to the host is handled at once
  # instead of after the whole turn; the cleanup stops the engine.
  (
    export FM_HOME STATE
    [ -z "${FM_STATE_OVERRIDE:-}" ] || export FM_STATE_OVERRIDE
    [ -z "${FM_CONFIG_OVERRIDE:-}" ] || export FM_CONFIG_OVERRIDE
    export FM_SUPERVISION_ACTOR=branch
    FM_LEASE_HOLDER_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null | tr -cd '0-9')
    export FM_LEASE_HOLDER_PID
    export FM_SUPERVISION_PRIMARY_HARNESS="$PRIMARY"
    export FM_BRANCH_REPORT_TURN="$turn"
    fm_supervision_engine_turn "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" \
      "$PROMPT_FILE" "$WAKE_FILE" "$ENGINE_SESSION" "$ENGINE_MODE" "$TURN_TIMEOUT" \
      "$result" "$errors" "$ENGINE_PID_FILE"
  ) &
  ENGINE_SUBSHELL=$!
  HOST_STOP_AT_ONCE=1
  stop_if_requested
  wait "$ENGINE_SUBSHELL"
  # One command reads the status and closes the at-once window, so a request
  # landing after the engine returned waits for the bookkeeping below.
  HOST_STOP_AT_ONCE=0 rc=$?
  ENGINE_SUBSHELL=
  ENGINE_RUNNING=0
  release_branch_leases
  # shellcheck disable=SC2086 # rows is a space-separated list of sequence numbers.
  unacked=$(fm_wake_rows_queued $rows) || unacked=$rows
  unacked=$(printf '%s\n' "$unacked" | awk 'NF { printf "%s%s", sep, $1; sep = " " }')
  "$SCRIPT_DIR/fm-wake-grant.sh" release "$GEN" >/dev/null 2>&1 || true
  rm -f "$TURN_FILE"
  receipts=$(awk -F '\t' -v turn="$turn" '$1 == turn { n++ } END { print n + 0 }' "$RECEIPTS" 2>/dev/null)
  usage=$(fm_supervision_engine_result "$FM_SUPERVISION_ENGINE" "$result" "${ENGINE_COST:-0}" 2>/dev/null || true)
  [ "$result" = /dev/null ] || rm -f "$result"
  TURN_RESULT=
  if [ "$rc" -ne 0 ] || [ -z "$usage" ] || [ "${usage#error=0}" = "$usage" ]; then
    ENGINE_ERROR=1
  fi
  health_record "$ENGINE_ERROR" "${receipts:-0}"
  if [ "$ENGINE_ERROR" -eq 0 ] && [ "${receipts:-0}" -gt 0 ] && [ -z "$unacked" ]; then
    write_engine_record $((ENGINE_TURNS + 1)) "$(printf '%s\n' "$usage" | sed -n 's/.* conversation_cost=\([^ ]*\).*/\1/p')" \
      || rm -f "$ENGINE_RECORD"
    [ "$TURN_POSTURE" != attended ] || "$SCRIPT_DIR/fm-host-mirror.sh" commit >/dev/null 2>&1 || true
    [ "$errors" = /dev/null ] || rm -f "$errors"
    TURN_ERRORS=
    log_line "handled	turn=$turn	posture=$TURN_POSTURE	rc=$rc	reports=$receipts	$usage	$first"
    return 0
  fi
  # A turn that did not handle its wake starts the next one on a new
  # conversation, so whatever went wrong in this one is not carried forward.
  rm -f "$ENGINE_RECORD"
  log_line "failed	turn=$turn	posture=$TURN_POSTURE	rc=$rc	reports=${receipts:-0}	unacked=${unacked:-none}	${usage:-no-result}	$(head -c 300 "$errors" 2>/dev/null | tr '\t\n' '  ')	$first"
  [ "$errors" = /dev/null ] || rm -f "$errors"
  TURN_ERRORS=
  if fm_timed_out "$rc"; then
    HANDLE_WHY="the engine turn hit its ${TURN_TIMEOUT}s bound"
  elif [ "$rc" -eq 127 ]; then
    HANDLE_WHY="the $FM_SUPERVISION_ENGINE engine could not run"
  elif [ "$rc" -ne 0 ]; then
    HANDLE_WHY="the engine turn failed (exit $rc)"
  elif [ "${usage#error=0}" = "$usage" ]; then
    HANDLE_WHY="the engine turn ended with an error or an incomplete result"
  elif [ "${receipts:-0}" -eq 0 ]; then
    HANDLE_WHY="the engine turn recorded no outcome for its wake"
  else
    HANDLE_WHY="the engine turn left its granted wake rows $unacked unacknowledged"
  fi
  return 1
}

# The captain outcomes one turn recorded, as store rows.
turn_captain_seqs() {  # <turn>
  awk -F '\t' -v turn="$1" '$1 == turn && $3 == "captain" { printf "%s%s", sep, $2; sep = ", " }' "$RECEIPTS" 2>/dev/null
}

# Why an attended close stays with main exactly as the plain arm delivers it,
# or nothing when the supervision session may take it. Sets ATTENDED_WHY, and
# ATTENDED_OFFER to the offer's verdict and the scope it judged.
attended_acceptor() {  # <first-reason-line>
  local offer=
  ATTENDED_WHY=
  ATTENDED_OFFER=
  if ! fm_supervision_host_attended_ready "$CONFIG" "$PRIMARY"; then
    ATTENDED_WHY=$FM_SUPERVISION_HOST_UNREADY
  elif ! fm_supervision_host_main_key "$STATE" >/dev/null; then
    ATTENDED_WHY="the main session could not be identified"
  elif health_cooling; then
    ATTENDED_WHY="the supervision session is cooling down after engine errors"
  elif ! offer=$(printf '%s\n' "$1" | node "$SCRIPT_DIR/fm-branch-dispatch.mjs" offer 2>/dev/null); then
    ATTENDED_WHY="branch eligibility could not be computed"
  elif [ "$(printf '%s\n' "$offer" | sed -n 's/^eligible=//p')" != 1 ]; then
    ATTENDED_WHY="main-only"
  fi
  ATTENDED_OFFER=$offer
  [ -z "$ATTENDED_WHY" ]
}

# The stop verb's outcome (header, STOP): one line, then the ledger line,
# written only after any signal and only to a regular file, under a bound.
stop_verb_outcome() {  # <exit-status> <text>
  printf 'supervision-host stop: %s\n' "$2"
  if [ ! -e "$HOST_LOG" ] && [ ! -L "$HOST_LOG" ] || { [ ! -L "$HOST_LOG" ] && [ -f "$HOST_LOG" ]; }; then
    # shellcheck disable=SC2016 # Positional parameters of the bounded sh.
    fm_run_timed 5 sh -c 'printf "%s\tstop-verb\t%s\n" "$1" "$2" >> "$3"' sh "$(date +%s)" "$2" "$HOST_LOG" >/dev/null 2>&1 || true
  fi
  exit "$1"
}

# True when <identity>'s command line runs this script's park verb, so a
# record naming some other live process is refused rather than signalled.
identity_names_host() {  # <identity>
  local hex cmd='' i=0 pair
  case "$1" in
    *-starttime=*' cmdline-hex='*)
      hex=${1#* cmdline-hex=}
      while [ "$i" -lt "${#hex}" ]; do
        pair=${hex:$i:2}
        case "$pair" in
          00) cmd="$cmd " ;;
          [0-9a-f][0-9a-f]) cmd="$cmd\\x$pair" ;;
          *) return 1 ;;
        esac
        i=$((i + 2))
      done
      printf -v cmd '%b' "$cmd"
      cmd=${cmd% }
      ;;
    *)
      # Portable ps identity: the command follows the 24-character lstart.
      cmd=${1:25}
      ;;
  esac
  case "$cmd" in
    *'fm-supervision-host.sh park'|*'fm-supervision-host.sh park --restart') return 0 ;;
  esac
  return 1
}

# True when <pid> has exited but is not yet reaped: its command line is empty,
# so its identity cannot be read, yet it has nothing left to stop.
pid_is_zombie() {  # <pid>
  local stat='' state=''
  local -a fields
  if fm_file_text_to stat "${FM_PROC_ROOT_OVERRIDE:-/proc}/$1/stat" 2>/dev/null && [ -n "$stat" ]; then
    read -r -a fields <<< "${stat##*)}"
    state=${fields[0]:-}
  else
    state=$(fm_run_timed 5 ps -o stat= -p "$1" 2>/dev/null) || return 1
    state=${state#"${state%%[! ]*}"}
  fi
  case "$state" in Z*) return 0 ;; esac
  return 1
}

# True once <pid> no longer runs as <identity>: exited, reaped, a zombie
# (whose command line is empty), or reused by another process.
host_gone_within() {  # <pid> <identity> <seconds>
  local deadline=$((SECONDS + $3)) current
  while :; do
    fm_pid_alive "$1" || return 0
    _fm_engine_identity_to current "$1" || current=
    [ "$current" = "$2" ] || return 0
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Stop this home's host (header, STOP): prove the recorded pid is a live host
# park under its recorded identity, ask it to end its park (USR1), and only if
# it does not answer within STOP_WAIT escalate to TERM, then KILL, each sent
# only while that identity still matches. Writes no state of its own.
stop_host() {
  local row='' role='' pid='' identity='' current=''
  if [ ! -e "$HOST_RECORD" ] && [ ! -L "$HOST_RECORD" ]; then
    stop_verb_outcome 0 'already stopped - no host record'
  fi
  if [ -L "$HOST_RECORD" ] || [ ! -f "$HOST_RECORD" ]; then
    stop_verb_outcome 1 "refused - $HOST_RECORD is not a regular file; nothing was signalled"
  fi
  # shellcheck disable=SC2016 # An awk program.
  if ! row=$(fm_run_timed 5 awk -F '\t' '$1 == "host" { print; exit }' "$HOST_RECORD" 2>/dev/null); then
    stop_verb_outcome 1 'refused - the host record could not be read within 5s; nothing was signalled'
  fi
  IFS=$'\t' read -r role pid identity _ <<< "$row"
  if [ "$role" != host ] || [ -z "$identity" ]; then
    stop_verb_outcome 1 'refused - the host record names no host with an identity; nothing was signalled'
  fi
  case "$pid" in
    ''|*[!0-9]*) stop_verb_outcome 1 'refused - the host record names no numeric pid; nothing was signalled' ;;
  esac
  fm_pid_alive "$pid" || stop_verb_outcome 0 "already stopped - recorded host pid $pid is not running"
  if ! _fm_engine_identity_to current "$pid"; then
    if ! fm_pid_alive "$pid" || pid_is_zombie "$pid"; then
      stop_verb_outcome 0 "already stopped - recorded host pid $pid is not running"
    fi
    stop_verb_outcome 1 "refused - the identity of pid $pid could not be read; nothing was signalled"
  fi
  if [ "$current" != "$identity" ]; then
    stop_verb_outcome 0 "already stopped - pid $pid now runs another process than the recorded host; nothing was signalled"
  fi
  if ! identity_names_host "$identity"; then
    stop_verb_outcome 1 "refused - recorded pid $pid is not a supervision host park; nothing was signalled"
  fi
  if ! kill -USR1 "$pid" 2>/dev/null; then
    host_gone_within "$pid" "$identity" 0 && stop_verb_outcome 0 "already stopped - recorded host pid $pid exited before the request"
    stop_verb_outcome 1 "failed - the stop request could not be sent to pid $pid"
  fi
  host_gone_within "$pid" "$identity" "$STOP_WAIT" \
    && stop_verb_outcome 0 "stopped pid $pid on request; it ended its park and printed its close for its owner"
  host_gone_within "$pid" "$identity" 0 || kill -TERM "$pid" 2>/dev/null || true
  host_gone_within "$pid" "$identity" 10 \
    && stop_verb_outcome 3 "stopped pid $pid with TERM after it left the request unanswered for ${STOP_WAIT}s; its owner retries the park"
  host_gone_within "$pid" "$identity" 0 || kill -KILL "$pid" 2>/dev/null || true
  host_gone_within "$pid" "$identity" 5 \
    && stop_verb_outcome 3 "stopped pid $pid with KILL after it left the request and TERM unanswered; the next host's activation stops what it left running"
  stop_verb_outcome 1 "failed - pid $pid still runs after the request, TERM and KILL"
}

# Sourcing exposes finite functions only, never ownership or lifecycle work.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

[ "$HOST_VERB" != stop ] || stop_host

# Ownership first: a host that does not own supervision leaves the owner's
# host, processes, arms, and leases alone. A stop request is honoured once
# the host has activated and its park wait is ready.
trap host_stop_request USR1
if ! host_still_owner; then
  stand_down "this session does not own supervision"
fi
trap cleanup EXIT
host_stop_signals
activate || { HOST_EMITTED=1; echo "supervision-host stood down: the host record could not be written"; exit 0; }
prepare_park_wait || { emit 'supervision-host: park timer could not be prepared; drain and re-arm supervision'; exit 1; }
HOST_STOP_READY=1
stop_if_requested
log_line "start	gen=$GEN	primary=$PRIMARY"
park_boot_start
fm_supervision_tick_loop_init "$STATE" "$CONFIG" "$STATE/.supervision-host-ticks" supervision-host half-second-wait-v1

# The first cycle.
if [ "$FIRST_ARM_RESTART" -eq 1 ]; then
  start_arm ARM_PID ARM_OUT "$OWNER_PREDECESSOR" --restart
elif [ -n "$LEFT_ARM" ]; then
  log_line "take-over	arm=$LEFT_ARM"
  start_arm ARM_PID ARM_OUT "$OWNER_PREDECESSOR" --take-over "$LEFT_ARM"
else
  start_arm ARM_PID ARM_OUT "$OWNER_PREDECESSOR"
fi || { emit "$ARM_START_FAILURE" 'watcher: FAILED - the supervision host could not start a watcher cycle'; exit 1; }

while :; do
  boundary_reached && boundary_exit
  await_close || boundary_exit
  REASON=$(printf '%s\n' "$ARM_TEXT" | grep -E '^(signal:|stale:|check:|heartbeat($|:))' || true)

  # The away daemon owns triage while its flag exists; the owner stands down.
  # A close with no wake is the arm's own failure or attach result, which the
  # owner judges exactly as it judges the arm's. Exit status 0 in both: a
  # status above 128 tells the owner the host itself died.
  if [ -z "$REASON" ]; then
    log_line "pass-through	a close without a wake"
    emit
    exit 0
  fi
  if [ -e "$STATE/.afk" ]; then
    log_line "pass-through	the away daemon's flag exists	$(printf '%s\n' "$REASON" | head -n 1)"
    emit
    exit 0
  fi
  # Attended: the close reaches main exactly as the plain arm delivers it,
  # unless the supervision session may take it (attended_acceptor).
  if ! fm_afk_contract_away_present "$STATE"; then
    if ! attended_acceptor "$(printf '%s\n' "$REASON" | head -n 1)"; then
      log_line "pass-through	attended	$ATTENDED_WHY	$(printf '%s\n' "$REASON" | head -n 1)"
      if [ "$ATTENDED_WHY" = main-only ]; then
        leave_successor_for_main || true
      fi
      # The owner delivers this close only while the recovery marker reads
      # downtime, and a turn's acknowledgement can already have consumed the
      # downtime of a close that landed during that turn.
      if ! fm_recovery_marker_publish "$STATE/.watcher-down" downtime >/dev/null 2>&1; then
        log_line "pass-through	downtime-unrestored	$(printf '%s\n' "$REASON" | head -n 1)"
        emit "$ARM_START_FAILURE" 'supervision-host: watcher downtime could not be restored for the main hand-back'
        exit 1
      fi
      emit "$ARM_START_FAILURE"
      exit 0
    fi
    host_still_owner || stand_down "this session no longer owns supervision"
  else
    if ! host_still_owner; then
      stand_down "this session no longer owns supervision"
    fi
    if ! fm_supervision_host_config "$CONFIG" "$PRIMARY"; then
      exit_to_main "the home no longer runs the supervision host"
    fi
    if [ -z "$FM_SUPERVISION_ENGINE" ]; then
      exit_to_main "no supervision engine runs here: $FM_SUPERVISION_ENGINE_PROBLEM; this wake is yours"
    fi
    if ! command -v node >/dev/null 2>&1; then
      exit_to_main "node is required to compute branch eligibility; this wake is yours"
    fi
    if health_cooling; then
      exit_to_main "the away session is paused after repeated engine errors until $(fm_supervision_host_clock "$HEALTH_RETRY"); this wake is yours"
    fi
  fi

  # A turn that could outlive the boundary would outlive the hook registration.
  turn_crosses_boundary && boundary_exit
  if ! ARM_OWN_GROUP=1 start_successor "$CLOSED_ARM_PID"; then
    exit_to_main "the successor watcher cycle could not be verified before handling; this wake is yours" "$ARM_START_FAILURE"
  fi
  if [ -n "$SUCCESSOR_GENERATION" ]; then
    if ! "$SCRIPT_DIR/fm-watch-arm.sh" --handling-delivered "$SUCCESSOR_GENERATION" --watcher-pid "$SUCCESSOR_WATCHER" >/dev/null 2>&1; then
      exit_to_main "the handling handoff to the successor watcher could not be confirmed; this wake is yours"
    fi
  fi

  # The captain returned during that turn: the return brief was rendered
  # before its visible outcomes existed, so main relays them now, handled or not.
  handle_wake "$REASON"
  HANDLE_RC=$?
  if [ "$HANDLE_RC" -eq 2 ]; then
    log_line "pass-through	attended	$ATTENDED_WHY	$(printf '%s\n' "$REASON" | head -n 1)"
    # The successor this turn already started and confirmed stays up. Retiring
    # it is what left no watcher after a close that became main-only.
    detach_successor
    # Main handles this close after all, so hand back the downtime the handoff
    # above consumed: the re-arm owner delivers the close only while the
    # recovery marker reads downtime (leave_successor_for_main).
    if [ -n "$SUCCESSOR_GENERATION" ] \
      && ! fm_recovery_marker_publish "$STATE/.watcher-down" downtime >/dev/null 2>&1; then
      log_line "pass-through	downtime-unrestored	$(printf '%s\n' "$REASON" | head -n 1)"
      exit 1
    fi
    emit
    exit 0
  fi
  if [ "$HANDLE_RC" -ne 0 ]; then
    if returned_during_turn; then
      exit_to_main "the away session could not take this wake: $HANDLE_WHY; this wake is yours, and the captain returned during its turn, so relay the visible outcomes it recorded (store rows $RETURNED_SEQS, listed next and in bin/fm-branch-outcome.sh list) to the captain" \
        "$(turn_outcome_lines)${HEALTH_NOTE:+$'\n'$HEALTH_NOTE}"
    elif [ "$RETURNED_LOOKUP_FAILED" -eq 1 ]; then
      exit_to_main "the away session could not take this wake: $HANDLE_WHY; this wake is yours, and the captain returned during its turn, but the recorded outcomes could not be verified" \
        "$(turn_outcome_lookup_warning)${HEALTH_NOTE:+$'\n'$HEALTH_NOTE}"
    fi
    if [ "$TURN_POSTURE" = away ]; then
      exit_to_main "the away session could not take this wake: $HANDLE_WHY; this wake is yours" "$HEALTH_NOTE"
    fi
    exit_to_main "the supervision session could not take this wake: $HANDLE_WHY; this wake is yours" "$HEALTH_NOTE"
  fi
  if returned_during_turn; then
    exit_to_main "the captain returned while the away session was handling this wake, which it finished after the return brief was rendered; relay its visible outcomes (store rows $RETURNED_SEQS, listed next and in bin/fm-branch-outcome.sh list) to the captain" \
      "$(turn_outcome_lines)"
  elif [ "$RETURNED_LOOKUP_FAILED" -eq 1 ]; then
    exit_to_main "the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them" \
      "$(turn_outcome_lookup_warning)"
  fi
  # Attended captain outcomes are main's to process; away they wait for the
  # return, including when the captain left while this turn ran. The close
  # itself was handled, so only the host's lines reach main.
  if [ -n "$LAST_TURN" ] && ! fm_afk_contract_away_present "$STATE"; then
    CAPTAIN_SEQS=$(turn_captain_seqs "$LAST_TURN")
    if [ -n "$CAPTAIN_SEQS" ]; then
      ARM_TEXT=
      exit_to_main "branch-outcome: the supervision session handled this wake and recorded captain outcomes for you (store rows $CAPTAIN_SEQS); run bin/fm-wake-drain.sh, act on its BRANCH OUTCOMES section, and acknowledge them as it prints" \
        "$HEALTH_NOTE"
    fi
  fi

  # Handled: park on the successor.
  ARM_PID=$SUCCESSOR_PID
  ARM_OUT=$SUCCESSOR_OUT
  SUCCESSOR_PID=
  SUCCESSOR_OUT=
  ARM_TEXT=
done
