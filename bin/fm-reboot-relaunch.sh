#!/usr/bin/env bash
# fm-reboot-relaunch.sh - session-start relaunch of this home's recorded workers
# whose agent died while their local copy and durable record survived, most
# often because the machine restarted.
#
# Usage: fm-reboot-relaunch.sh plan
#        fm-reboot-relaunch.sh run [--lock-pid <pid>] [--deadline <epoch>]
#
#   plan  Read-only. Classifies every recorded ordinary direct report of THIS
#         home and prints one line for each whose agent is not proven running:
#           relaunch <id>: <proof>; <what the replacement resumes from>
#           stopped <id>: <why it is left stopped>
#         A task whose agent is running prints nothing, so empty output means
#         nothing to recover. bin/fm-session-start.sh prints this in its digest.
#         A Herdr endpoint that reads `missing` is reported as pending proof,
#         because proving it gone starts the recorded session's server, which
#         plan never does.
#   run   Performs the relaunches, one at a time, through the one guarded
#         relaunch owner, bin/fm-control.sh <id> relaunch --note-file, and prints
#         the result block described under OUTPUT. It refuses unless this
#         session holds the fleet lock: --lock-pid names the lock owner a
#         detached caller captured while it held the lock, and the lock must
#         still name it; without it the calling process must own the lock
#         itself (bin/fm-session-lock-lib.sh). bin/fm-startup-network.sh runs it
#         first in the locked deferred startup stage, so a lock-refused
#         read-only session and a context re-emit never reach it.
#         --deadline stops STARTING relaunches at that epoch second; a task not
#         reached is reported and left for the next session start.
#
# WHO IS CONSIDERED. Only state/<id>.meta records in this home with kind ship or
# scout (absent kind reads as ship) and no remote_host. A secondmate is never
# touched here - bin/fm-bootstrap.sh's secondmate liveness sweep owns those - and
# another home's endpoints are never read, because every endpoint comes from this
# home's own validated record (bin/fm-backend.sh fm_backend_validate_task_endpoint).
#
# THE RELAUNCH GATE. A task is relaunched only when every one of these holds:
#   - its backend has a recovery-grade agent-state classifier (tmux, herdr), and
#     that classifier proves the agent gone: `dead` on the recorded endpoint, or
#     `missing` confirmed by the control plane's one absence proof
#     (bin/fm-control-lib.sh fm_control_endpoint_absence_verdict). An agent that
#     is merely idle reads `alive`; an unreadable, ambiguous, or unproven read is
#     left stopped. A tmux `missing` can never be proven from a task record, so
#     it is always left stopped.
#   - its recorded harness has verified control mechanics and can be relaunched
#     without guessing its launch command.
#   - its recorded worktree exists and its instructions (data/<id>/brief.md) are
#     present.
#   - no earlier relaunch transaction for it was interrupted part-way
#     (state/<id>.control-relaunch in a non-final phase).
#   - firstmate did not stop it deliberately (state/<id>.control-exit, written
#     by bin/fm-control.sh exit).
#   - it has something to resume from: a resume note at data/<id>/resume.md, or
#     a usable newest status line.
#   - its newest status line does not declare that it needs no live agent:
#       paused         a declared wait is left stopped, EXCEPT a pause keyed
#                      `reboot` (the reboot-safe line a worker writes before a
#                      planned restart) or one whose `until` time has passed.
#       captain-held   left stopped: it waits on the captain.
#       done           a scout's done is a finished report awaiting cleanup, and
#                      a ship done that bin/fm-dod-lib.sh treats as a ready
#                      signal (fm_dod_should_gate_ship_done) awaits merge or
#                      landing; both are left stopped. A no-mistakes handoff
#                      done still needs its worker to run validation, so it is
#                      relaunched.
#       failed         left stopped: firstmate decides what happens next.
#     Every other newest line (working, blocked, needs-decision, resolved, and
#     legacy text) needs a live worker and is relaunched.
#   - no automatic relaunch was already attempted for it since this machine
#     started (IDEMPOTENCY below).
#
# THE NOTE. The replacement inherits the local copy but none of the
# conversation, so the note says the machine restarted (or the agent otherwise
# stopped), points at the resume note when there is one, and quotes the newest
# status line. bin/fm-control.sh appends it to the task's instructions.
#
# IDEMPOTENCY. Before each attempt, run records state/<id>.reboot-relaunch
# (written only by this script) keyed to this machine's boot: the kernel boot id
# on Linux, the boot time on macOS, and otherwise the task record's content
# hash. A later session start in the same boot finds the key and leaves the task
# stopped instead of relaunching again, whatever the first attempt's result
# was, so a worker that keeps dying is handed to firstmate rather than retried
# every session start. FM_REBOOT_RELAUNCH_BOOT_ID overrides the boot identity
# (tests only). Teardown removes the record.
#
# OPT-OUT. config/reboot-relaunch holding `off` disables run entirely (plan
# still reports what it would do). Absent or `on` enables it. Any other value
# disables it and says so, because a mistyped opt-out must not relaunch workers.
#
# OUTPUT of run, in bin/fm-bootstrap.sh's report protocol so it rides the
# deferred startup report unchanged:
#   BOOTSTRAP_INFO: reboot relaunch: relaunched <id> (<proof>; <resume source>)
#   BOOTSTRAP_INFO: reboot relaunch: left <id> stopped: <reason>
#     a deliberate stop that needs nothing now (a declared wait, a finished
#     report, a deliberate exit, an attempt already made this boot, opt-out).
#   REBOOT_RELAUNCH: <id>: left stopped: <reason>
#   REBOOT_RELAUNCH: <id>: relaunch failed: <first error line>
#   REBOOT_RELAUNCH: <id>: not attempted: <reason>
#     actionable: no worker is running for that task and none was started;
#     recover it through stuck-crewmate-recovery.
# Silence means no recorded worker needed relaunching.
#
# Environment:
#   FM_HOME                 required; the home whose records are read.
#   FM_REBOOT_RELAUNCH_BOOT_ID  boot identity override (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-reboot-relaunch.sh" | sed 's/^# \{0,1\}//; $d'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-reboot-relaunch refuses to resolve tasks without an explicit firstmate home" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

MODE=${1:-}
[ "$#" -eq 0 ] || shift
LOCK_PID=
DEADLINE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lock-pid) LOCK_PID=${2:-}; shift; [ "$#" -eq 0 ] || shift ;;
    --deadline) DEADLINE=${2:-}; shift; [ "$#" -eq 0 ] || shift ;;
    *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
  esac
done
case "$DEADLINE" in
  ''|*[!0-9]*) DEADLINE= ;;
esac

# --- classification -----------------------------------------------------------

# One line of printable text, capped, for quoting a status line inside a reason.
quote_line() {  # <line>
  fm_cap_line "$(printf '%s' "$1" | tr -d '\r' | tr '\n' ' ')"
}

boot_key() {
  local id
  if [ -n "${FM_REBOOT_RELAUNCH_BOOT_ID:-}" ]; then
    printf 'boot:%s' "$FM_REBOOT_RELAUNCH_BOOT_ID"
    return 0
  fi
  id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
  if [ -n "$id" ]; then
    printf 'boot:%s' "$id"
    return 0
  fi
  id=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p' | head -1)
  if [ -n "$id" ]; then
    printf 'boot:%s' "$id"
    return 0
  fi
  return 1
}

# The idempotency key for one task: the boot identity, or the task record's
# content hash on a host that exposes none.
attempt_key() {  # <meta>
  local key
  if key=$(boot_key); then
    printf '%s' "$key"
    return 0
  fi
  printf 'meta:%s' "$(cksum < "$1" 2>/dev/null | awk '{print $1 "-" $2}')"
}

marker_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$STATE/$1.reboot-relaunch" 2>/dev/null | tail -1
}

write_marker() {  # <id> <key> <result>
  local id=$1 tmp
  tmp=$(mktemp "$STATE/.$id.reboot-relaunch.XXXXXX" 2>/dev/null) || return 1
  if printf 'key=%s\nattempted=%s\nresult=%s\n' "$2" "$(date +%s)" "$3" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STATE/$id.reboot-relaunch" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# classify <meta> <plan|run>: sets
#   CLASS    alive | skip | relaunch | stopped | attention
#   REASON   why (stopped/attention), or the proof (relaunch)
#   RESUME   resume-note path, or empty
#   LAST     newest status line, or empty
#   KEY      the idempotency key
# `stopped` is a deliberate stop that needs nothing now; `attention` is a task
# with no running agent that this script will not relaunch and firstmate must
# recover by hand.
classify() {  # <meta> <plan|run>
  local meta=$1 mode=$2 id kind window backend target state absence recorded family wt phase until_epoch verb note mode_field status
  id=$(basename "$meta" .meta)
  CLASS=skip REASON='' RESUME='' LAST='' KEY=''
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in ship|scout) ;; *) return 0 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0

  window=$(fm_meta_get "$meta" window)
  if [ -z "$window" ]; then
    CLASS=attention REASON="its record names no endpoint, so there is no agent to prove gone"
    return 0
  fi
  if ! fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    CLASS=attention REASON="its record does not pass endpoint validation, so its agent's state cannot be read"
    return 0
  fi
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  if ! fm_control_backend_state_verified "$backend"; then
    CLASS=attention REASON="the $backend backend has no recovery-grade agent-state classifier, so the agent cannot be proven gone"
    return 0
  fi
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
  case "$state" in
    alive) CLASS=alive; return 0 ;;
    dead) REASON="agent gone from its surviving $backend endpoint" ;;
    missing)
      if [ "$backend" != herdr ]; then
        CLASS=attention REASON="its $backend endpoint is missing, and a task record cannot prove a $backend endpoint gone rather than unreachable"
        return 0
      fi
      if [ "$mode" = plan ]; then
        REASON="herdr endpoint missing, pending the relaunch's absence proof"
      else
        absence=$(fm_control_endpoint_absence_verdict "$backend" "$target")
        case "${absence%%$'\t'*}" in
          gone) REASON="herdr endpoint proven gone" ;;
          dead) REASON="agent gone from its surviving herdr endpoint" ;;
          alive) CLASS=alive; return 0 ;;
          *)
            CLASS=attention REASON="its herdr endpoint is missing and could not be proven gone: ${absence#*$'\t'}"
            return 0
            ;;
        esac
      fi
      ;;
    *)
      CLASS=attention REASON="its agent state reads '$state', not proven gone"
      return 0
      ;;
  esac

  KEY=$(attempt_key "$meta")
  if [ -f "$STATE/$id.reboot-relaunch" ] && [ "$(marker_field "$id" key)" = "$KEY" ]; then
    CLASS=stopped REASON="an automatic relaunch was already attempted since this machine started (result: $(marker_field "$id" result)); recover it by hand"
    return 0
  fi
  if [ -f "$STATE/$id.control-exit" ]; then
    CLASS=stopped REASON="firstmate stopped this worker deliberately"
    return 0
  fi
  recorded=$(fm_meta_get "$meta" harness)
  if ! family=$(fm_control_harness_family "$recorded") || ! fm_control_harness_supported "$family"; then
    CLASS=attention REASON="its recorded harness '${recorded:-none}' has no verified control mechanics"
    return 0
  fi
  if [ "$family" != "$recorded" ]; then
    CLASS=attention REASON="its recorded harness '$recorded' is a launch-command basename whose original command cannot be reconstructed; relaunch it with an explicit harness"
    return 0
  fi
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    CLASS=attention REASON="its recorded local copy ${wt:-(none)} is missing"
    return 0
  fi
  if [ ! -f "$DATA/$id/brief.md" ]; then
    CLASS=attention REASON="its instructions $DATA/$id/brief.md are missing"
    return 0
  fi
  phase=$(sed -n 's/^phase=//p' "$STATE/$id.control-relaunch" 2>/dev/null | tail -1)
  case "$phase" in
    ''|complete|failed:*) ;;
    *)
      CLASS=attention REASON="an earlier relaunch stopped part-way (phase $phase); reconcile $STATE/$id.control-relaunch first"
      return 0
      ;;
  esac

  if [ -s "$DATA/$id/resume.md" ]; then
    RESUME="$DATA/$id/resume.md"
  fi
  status="$STATE/$id.status"
  LAST=$(last_status_line "$status")
  if [ -n "$LAST" ]; then
    verb=$(status_line_verb "$LAST")
    note=$(status_line_note "$LAST")
    case "$verb" in
      "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
        if [ "$(_fm_decision_key "$LAST" 2>/dev/null)" = reboot ]; then
          :
        elif until_epoch=$(status_paused_until "$LAST") && [ "$until_epoch" -le "$(date +%s)" ]; then
          :
        elif until_epoch=$(status_paused_until "$LAST"); then
          CLASS=stopped REASON="it declared a wait until $(date -u -d "@$until_epoch" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$until_epoch" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$until_epoch"): $(quote_line "$note")"
          return 0
        else
          CLASS=stopped REASON="it declared a wait: $(quote_line "$note")"
          return 0
        fi
        ;;
      "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}")
        CLASS=stopped REASON="it is held for the captain: $(quote_line "$note")"
        return 0
        ;;
      done)
        if [ "$kind" = scout ]; then
          CLASS=stopped REASON="a done scout awaiting cleanup"
          return 0
        fi
        mode_field=$(fm_meta_get "$meta" mode)
        if fm_dod_should_gate_ship_done "$kind" "$mode_field" "$LAST"; then
          CLASS=stopped REASON="it reported its finished work, which needs no live worker: $(quote_line "$note")"
          return 0
        fi
        ;;
      failed)
        CLASS=stopped REASON="it reported failure, so firstmate decides what happens next: $(quote_line "$note")"
        return 0
        ;;
    esac
  elif [ -z "$RESUME" ]; then
    CLASS=attention REASON="it has neither a resume note ($DATA/$id/resume.md) nor a status line to resume from"
    return 0
  fi
  CLASS=relaunch
}

resume_source() {
  if [ -n "$RESUME" ]; then
    printf 'resume from %s' "$RESUME"
  else
    printf 'resume from its newest status line'
  fi
}

write_note() {  # <file>
  {
    echo "The machine restarted, or this worker's agent otherwise stopped, and firstmate"
    echo "relaunched this worker automatically at session start."
    if [ -n "$RESUME" ]; then
      echo
      echo "Read your resume note first and continue from it: $RESUME"
    fi
    if [ -n "$LAST" ]; then
      echo
      echo "Your newest status line before the stop was:"
      echo
      printf '    %s\n' "$(quote_line "$LAST")"
    fi
    echo
    echo "If that line declared a reboot-safe pause, the restart has happened: resume the"
    echo "work and report status as usual."
  } > "$1"
}

meta_records() {
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    printf '%s\n' "$meta"
  done
}

# --- modes --------------------------------------------------------------------

switch_value() {
  local value
  [ -e "$CONFIG/reboot-relaunch" ] || { printf 'on'; return 0; }
  value=$(sed -n 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /./{p;q;}' "$CONFIG/reboot-relaunch" 2>/dev/null)
  printf '%s' "$value"
}

cmd_plan() {
  local meta id printed=0 switch
  [ -d "$STATE" ] || return 0
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    id=$(basename "$meta" .meta)
    classify "$meta" plan
    case "$CLASS" in
      relaunch) printf 'relaunch %s: %s; %s\n' "$id" "$REASON" "$(resume_source)" ;;
      stopped|attention) printf 'stopped %s: %s\n' "$id" "$REASON" ;;
      *) continue ;;
    esac
    printed=1
  done < <(meta_records)
  [ "$printed" -eq 1 ] || return 0
  switch=$(switch_value)
  if [ "$switch" = on ]; then
    printf 'The relaunch lines run in the locked deferred startup stage; its result there (bin/fm-startup-network.sh report) is authoritative and may supersede endpoint records printed before it.\n'
  else
    printf 'config/reboot-relaunch is %s, so nothing is relaunched automatically.\n' "$(quote_line "${switch:-empty}")"
  fi
}

lock_held() {
  local current
  if [ -n "$LOCK_PID" ]; then
    case "$LOCK_PID" in *[!0-9]*) return 1 ;; esac
    [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
    current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
    [ "$current" = "$LOCK_PID" ]
    return
  fi
  fm_session_lock_owned_by_self "$STATE"
}

cmd_run() {
  local meta id switch out rc note detail
  [ -d "$STATE" ] || return 0
  if ! lock_held; then
    echo "error: this session does not hold the fleet lock for $FM_HOME, so no worker is relaunched from here" >&2
    return 1
  fi
  switch=$(switch_value)
  case "$switch" in
    on) ;;
    off) return 0 ;;
    *)
      echo "REBOOT_RELAUNCH: config/reboot-relaunch holds '$(quote_line "$switch")', not on or off, so no worker was relaunched; fix the file to re-enable it"
      return 0
      ;;
  esac
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    id=$(basename "$meta" .meta)
    classify "$meta" run
    case "$CLASS" in
      alive|skip) continue ;;
      stopped)
        echo "BOOTSTRAP_INFO: reboot relaunch: left $id stopped: $REASON"
        continue
        ;;
      attention)
        echo "REBOOT_RELAUNCH: $id: left stopped: $REASON"
        continue
        ;;
    esac
    if [ -n "$DEADLINE" ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "REBOOT_RELAUNCH: $id: not attempted: the startup time bound was reached first; the next session start retries it"
      continue
    fi
    if ! write_marker "$id" "$KEY" started; then
      echo "REBOOT_RELAUNCH: $id: not attempted: its attempt record could not be written, and relaunching without one could repeat every session start"
      continue
    fi
    note=$(mktemp "${TMPDIR:-/tmp}/fm-reboot-relaunch-note.XXXXXX" 2>/dev/null) || note=
    if [ -z "$note" ]; then
      write_marker "$id" "$KEY" "failed: no note file" || true
      echo "REBOOT_RELAUNCH: $id: not attempted: a temporary note file could not be created"
      continue
    fi
    write_note "$note"
    rc=0
    out=$(FM_HOME="$FM_HOME" FM_SPAWN_NO_GUARD=1 \
      "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note-file "$note" 2>&1 </dev/null) || rc=$?
    rm -f "$note" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      write_marker "$id" "$KEY" relaunched || true
      echo "BOOTSTRAP_INFO: reboot relaunch: relaunched $id ($REASON; $(resume_source))"
    else
      detail=$(printf '%s\n' "$out" | grep '^error:' | head -1)
      [ -n "$detail" ] || detail=$(printf '%s\n' "$out" | awk 'NF { l=$0 } END { print l }')
      [ -n "$detail" ] || detail="exited $rc"
      detail=$(quote_line "$detail")
      write_marker "$id" "$KEY" "failed: $detail" || true
      echo "REBOOT_RELAUNCH: $id: relaunch failed: $detail"
    fi
  done < <(meta_records)
  return 0
}

case "$MODE" in
  plan) cmd_plan ;;
  run) cmd_run || exit 1 ;;
  *)
    usage >&2
    exit 2
    ;;
esac
exit 0
