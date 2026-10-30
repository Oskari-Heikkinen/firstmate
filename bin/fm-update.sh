#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch to origin's green pointer - the newest main
# commit whose CI passed, or origin/<default> on a remote without that pointer,
# which the output then names (bin/fm-ff-lib.sh owns that choice) - then fast-forwards every
# registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash.
# A secondmate divergence whose complete local tree result is already present at
# the target is reconciled with reset --keep; every other unsafe target is
# skipped and reported, with divergence recorded durably by fm-ff-lib.sh.
# A tracked-files update never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives local and remote parent-targeted secondmate sync, so
# there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - restart-secondmates: fm-<id>...|none (every live secondmate this pass left
#     on origin's sync target - advanced OR already there - whose recorded runtime can
#     prove a restart)
#   - nudge-secondmates: fm-<id>...|none   (the residual: live secondmates on
#     that same tip whose runtime CANNOT prove a restart, so the older re-read
#     steer is all that is honest for them)
#
# The two sets are disjoint, and restart is UNCONDITIONAL on a successful update
# of that home. It is deliberately not gated on the git diff: replacing the agent
# is the only thing that re-resolves the launch-time wiring - turn-end hooks,
# harness flags, per-harness feature switches - which a running agent froze when
# it started and which no changed_instr list describes. An unchanged tracked
# surface therefore is NOT evidence that the running agent is already on the
# current behavior, so an ALREADY-CURRENT home restarts too.
#
# Only two things keep a live mate out of the restart set, and neither is papered
# over as a reload:
#   - its home was SKIPPED (dirty, uniquely diverged, offline, unsafe). It is not
#     on the new bytes, nothing here forces, stashes, or discards it, and it gets
#     no action at all. A divergence remains in the durable reconciliation record
#     that this or a later bootstrap/update pass surfaces.
#   - its runtime cannot prove the old agent stopped and a replacement came up
#     (bin/fm-secondmate-restart-lib.sh owns that test), so it falls to the
#     honest re-read steer and is reported as a nudge, never as a reload.
# A positively dead or missing endpoint has no agent to replace and is left to
# the ordinary startup recovery.
#
# A fast-forward that lands changes bytes under bin/ in place, which desyncs
# the trust binding of any locally armed fm-procevent-when watch whose action
# executable lives in the updated repo; left alone, the watch's next fire
# would be wrongly refused. After each home's own update (primary and every
# local secondmate), this script best-effort runs that home's own
# fm-procevent-when.sh rebind-all to republish those bindings against the new
# bytes; a failure there is swallowed rather than failing the update.
#
# A helper another home runs under a pin is held by its declared consumers
# (docs/helper-consumers.md): when the primary's advance would deploy a helper
# version some consumer has not accepted, bin/fm-ff-lib.sh skips it, and this
# script then holds the WHOLE pass - no secondmate moves either, so every home
# stays on one version - and prints
#   held-for-helper: <helper>@<sha12> awaiting <consumer>,...[; ...]
# (`awaiting malformed declaration <name>,...` when a declaration file is
# malformed or unreadable) before the three action lines, which then all report
# nothing to do. --allow-helper-break <consumer> (repeatable, also a malformed
# declaration's file name without .conf) carries the captain's explicit
# "update anyway" for that consumer: the pass proceeds, and each target that
# deploys the unaccepted version prints a `helper-consumers:` line recording
# the override. The override stays on this machine: a remote secondmate's
# update checks that machine's own declarations without it, so a held remote
# home reports its hold and converges once its own consumer accepts. After its fetch, the pass also runs
# `bin/fm-helper-consumers.sh pending` on the sync target, so a helper version
# no consumer has accepted yet is recorded and noted even when nothing else
# noticed its landing; its `helper-pending:` lines are reported as they come.
# Each held pass also appends one line per version that held it to the hold log
# through `bin/fm-helper-consumers.sh log` (one `held` line with `-` fields
# when the check failed without naming a version). Because the landing gate
# keeps unaccepted versions off the default branch, that line is `bypass`,
# which also raises the unaccepted-version alarm at once, unless the log's
# `break` lines name every awaited consumer for that version (then `held`); an
# unreadable log counts as no break. A pass that leaves the
# primary updated or already current appends `cleared` for each of this home's
# holds still open. A line that cannot be written prints
# `hold-log: not written: ...` and changes nothing else.
# The primary's hold is bounded: check-advance --hold-bound lets it advance once
# every version holding it has been held for the hold limit (config/helper-hold-max,
# 1h by default), counted from that version's first held line. That pass prints a
# `helper-consumers:` line per version it deploys unaccepted, appends one
# `expired` line for each before its `cleared` lines, and leaves the consumers'
# owners to the armed helper-unaccepted alarm, saying so when it is not armed.
# A held pass names in held-for-helper when the limit lets a pass proceed, or why
# no limit applies (a malformed declaration, or an unreadable limit file or log).
# With no declarations none of this prints anything.
#
# Usage: fm-update.sh [--allow-helper-break <consumer>]... [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--allow-helper-break <consumer>]... [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
FF_HELPER_ALLOW_BREAK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-helper-break)
      case "${2:-}" in
        ''|.*|*[!A-Za-z0-9._-]*) usage; exit 1 ;;
      esac
      FF_HELPER_ALLOW_BREAK="$FF_HELPER_ALLOW_BREAK $2"
      shift 2
      ;;
    *) usage; exit 1 ;;
  esac
done

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
# Only the primary's holds are logged, so only they take the hold limit.
FF_HELPER_HOLD_HOME=$FM_HOME
ff_target "$FM_ROOT" "firstmate" origin no no
FF_HELPER_HOLD_HOME=""
if [ "$FF_STATUS" = "updated" ]; then
  if [ -n "$FF_INSTR" ]; then
    reread_firstmate="yes"
  fi
  # A fast-forward changes bin/'s bytes out from under any locally armed
  # fm-procevent-when watch's trust binding, with no tampering involved; left
  # alone, the very next fire is refused and the watch dies silently. Refresh
  # every such watch now, right after the update that broke it. FM_ROOT_OVERRIDE
  # is passed explicitly rather than relying on the script's own location: this
  # process's own FM_ROOT is the repo that was just updated, which is not
  # always where this very script file happens to live (FM_ROOT_OVERRIDE, as
  # this test suite uses to point fm-update.sh at a fixture checkout).
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-procevent-when.sh" rebind-all || true
fi

# Record any declared helper version at the sync target that a consumer has not
# accepted yet; the header owns why this runs here, after the fetch.
if [ -n "$FF_BASE_COMMIT" ]; then
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-helper-consumers.sh" pending --repo "$FM_ROOT" "$FF_BASE_COMMIT" || true
fi

# Hold log: a held pass logs each version that held it, and a pass that leaves
# the primary on its target clears this home's open holds (see the header).
hold_log() {  # <outcome> <helper> <sha256> <consumers> <note>
  local out
  out=$("$SCRIPT_DIR/fm-helper-consumers.sh" log "$1" "$FM_HOME" "${FF_BASE_COMMIT:--}" "$2" "$3" "$4" "$5" 2>&1) \
    || echo "hold-log: not written: $1 $2: $(first_line "$out")"
}
# The landing gate keeps unaccepted versions off the default branch, so a held
# version is a bypass unless a landing break line covers each of its consumers.
hold_outcome() {  # <helper> <sha256> <consumers>; sets OUTCOME
  local c
  OUTCOME=held
  for c in ${3//,/ }; do
    case "$broken" in *$'\n'"${1##*/}@$2 $c"$'\n'*) ;; *) OUTCOME=bypass; return 0 ;; esac
  done
}
if [ -n "$FF_HELD" ]; then
  if broken=$("$SCRIPT_DIR/fm-helper-consumers.sh" holds 2>/dev/null); then
    broken=$'\n'$(printf '%s\n' "$broken" | awk -F '\t' '$2 == "break" {
      b = $5; sub(/.*\//, "", b); n = split($7, c, ",")
      for (i = 1; i <= n; i++) print b "@" $6 " " c[i] }')$'\n'
  else
    broken=unreadable
  fi
  logged=no
  while IFS=$'\t' read -r kind helper sha consumers; do
    case "$kind" in
      hold) hold_outcome "$helper" "$sha" "$consumers"
        hold_log "$OUTCOME" "$helper" "$sha" "$consumers" "held-for-helper: awaiting $consumers"; logged=yes ;;
      unproven) hold_outcome "$helper" "$sha" "$consumers"
        hold_log "$OUTCOME" "$helper" "$sha" "$consumers" "held-for-helper: awaiting malformed declaration $consumers"; logged=yes ;;
    esac
  done <<< "$FF_HELPER_RECORDS"
  [ "$logged" = yes ] || hold_log held - - - "held-for-helper: $FF_HELD"
elif [ "$FF_STATUS" = "updated" ] || [ "$FF_STATUS" = "current" ]; then
  breaks=$(printf '%s' "$FF_HELPER_RECORDS" | awk -F '\t' '$1 == "break" { s = s (s == "" ? "" : ", ") $4 }  END { print s }')
  expired=$(printf '%s' "$FF_HELPER_RECORDS" | awk -F '\t' '$1 == "expired" { s = s (s == "" ? "" : ", ") $4 }  END { print s }')
  how=""
  [ -z "$breaks" ] || how=" with --allow-helper-break for $breaks"
  [ -z "$expired" ] || how="$how${how:+ and} past the hold limit for $expired"
  while IFS=$'\t' read -r kind helper sha consumers since; do
    [ "$kind" = expired ] || continue
    hold_log expired "$helper" "$sha" "$consumers" "deployed unaccepted by $consumers: held since $since, past the hold limit; they wait until they accept it"
  done <<< "$FF_HELPER_RECORDS"
  if [ -n "$expired" ] && [ ! -e "$STATE/helper-unaccepted.check.sh" ]; then
    echo "helper-consumers: the helper-unaccepted alarm is not armed in $STATE, so the owners of $expired get no alarm; arm it with bin/fm-helper-consumers.sh alarm --arm"
  fi
  if open_holds=$("$SCRIPT_DIR/fm-helper-consumers.sh" holds --open --home "$FM_HOME" 2>/dev/null); then
    while IFS=$'\t' read -r _ helper sha consumers _; do
      [ -n "$helper" ] || continue
      hold_log cleared "$helper" "$sha" "$consumers" "pass $FF_STATUS at the target$how"
    done <<< "$open_holds"
  else
    echo "hold-log: not written: cannot read this home's open holds, so none is cleared"
  fi
fi

# A held primary holds the whole pass (see the header).
if [ -n "$FF_HELD" ]; then
  echo "held-for-helper: $FF_HELD"
  echo "reread-firstmate: no"
  echo "restart-secondmates: none"
  echo "nudge-secondmates: none"
  exit 0
fi

# --- secondmates -----------------------------------------------------------
# Every live secondmate this pass leaves on origin's sync target is restarted, whether it
# advanced or was already there. The header above owns why the git diff does not
# gate that, and which two conditions - a skipped home, an unprovable runtime -
# are the only ways a live mate stays out of the restart set.

# FF_NUDGE_WINDOWS and FF_SEEN_HOMES are the sweep's own accumulators and are
# reset here per its contract; the instruction-gated nudge set is the session-start
# sweep's threshold, not this command's, so only the two sets below are read.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""
FF_RESTART_WINDOWS=""
FF_STEER_WINDOWS=""

secondmate_agent_may_be_alive() {  # <id>
  local id=$1 meta="$STATE/$1.meta" remote_host state=unreadable
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    state=$("$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null) || state=unreadable
  elif fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" \
      "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null) || state=unreadable
  fi
  case "$state" in
    dead|missing) return 1 ;;
    *) return 0 ;;
  esac
}

selector_claimed() {  # <selector>
  case " $FF_RESTART_WINDOWS $FF_STEER_WINDOWS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Route one secondmate whose home this pass left on the target commit. Restart is
# the outcome unless its runtime cannot prove one, in which case it keeps the
# re-read steer and is reported as a nudge rather than as a reload. A stopped
# endpoint has no agent to replace and is left to startup recovery.
claim_settled_secondmate() {  # <id>
  local id=$1
  selector_claimed "fm-$id" && return 0
  secondmate_agent_may_be_alive "$id" || return 0
  if fm_secondmate_restart_capable "$STATE/$id.meta"; then
    FF_RESTART_WINDOWS="$FF_RESTART_WINDOWS fm-$id"
  else
    FF_STEER_WINDOWS="$FF_STEER_WINDOWS fm-$id"
  fi
}

# bin/fm-ff-lib.sh calls this for each local home it left AT the base with a live
# endpoint - status "updated" or "current" alike. A skipped home never gets here.
fm_ff_after_secondmate_settled() {  # <id> <home> <window> <status> <instr>
  # Same bin/-changed-out-from-under-a-watch problem as the primary home
  # above, for a local secondmate's own worktree; "current" means bin/ did
  # not move there this pass, so there is nothing to rebind. Run the
  # secondmate's OWN copy of the script, explicitly overriding FM_ROOT to its
  # own worktree rather than letting an outer FM_ROOT_OVERRIDE (this process's
  # own, if the caller set one) leak into the child and misscope it.
  if [ "${4:-}" = "updated" ] && [ -x "$2/bin/fm-procevent-when.sh" ]; then
    FM_HOME="$2" FM_ROOT_OVERRIDE="$2" "$2/bin/fm-procevent-when.sh" rebind-all || true
  fi
  claim_settled_secondmate "$1"
}

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin yes

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            remote_detail=${remote_result#synced: }
            # The host reports its advance as "<commit> instr=<paths>"; a host
            # whose Firstmate copy predates that suffix reports the commit alone.
            # The suffix is now reporting detail only: the routing below no longer
            # reads it, so an older host's silence can no longer downgrade a
            # restartable mate to a steer.
            case "$remote_detail" in
              *' instr='*)
                remote_instr=${remote_detail##* instr=}
                remote_commit=${remote_detail%% instr=*}
                ;;
              *) remote_instr=""; remote_commit=$remote_detail ;;
            esac
            if [ -n "$remote_instr" ]; then
              echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST ($remote_commit, instructions changed: $remote_instr)"
            else
              echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST ($remote_commit)"
            fi
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              claim_settled_secondmate "$id"
            fi
            ;;
          current:*)
            echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })"
            # Already on the target commit is a SUCCESSFUL update of that home,
            # so it earns the same restart as one that had to advance.
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              claim_settled_secondmate "$id"
            fi
            ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_secondmate "$id" "$home" "" origin yes
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

# claim_settled_secondmate puts each live settled mate in exactly one set, so the
# two lines below are disjoint by construction: no mate is ever restarted and
# then also steered about the instructions it just relaunched on.

echo "reread-firstmate: $reread_firstmate"
echo "restart-secondmates:${FF_RESTART_WINDOWS:- none}"
echo "nudge-secondmates:${FF_STEER_WINDOWS:- none}"
