#!/usr/bin/env bash
# fm-park.sh - park a ship or scout task that only waits on an external result,
# so no idle agent session is held open for it, and relaunch it as a fresh
# session automatically when the result arrives.
#
# Usage:
#   fm-park.sh <task-id> --handoff <file> [--when <condition>] [--deadline <iso>]
#              [--adopt-merge-queue <head40>] [--open-ended] [--relocation-safe]
#   fm-park.sh release <task-id> <park-token>  bounded registered copy-return action
#   fm-park.sh release-ready <task-id> <park-token>  cheap release condition
#   fm-park.sh pickup <task-id>        explicit authority for an inbox-only wait
#   fm-park.sh poll <task-id> <park-token>  incarnation-bound listener condition
#
# config/park-release=on enables a per-home canary; absent/off retains copies.
# --relocation-safe attests that no job, external producer, future result or
# continuation input depends on this copy or its temp folder. Unknown/dirty
# artifacts still refuse release; this is not discard authority. --open-ended
# and inbox:<task-id> waits qualify immediately, other waits after 24 continuous
# hours. Re-arming the same uninterrupted condition does not restart its clock.
# Release runs only after verified exit, through its own incarnation-bound
# process-event action source. The ordinary wait checker never saves/releases.
# release is callback-only: a current token, verified-stop receipt, recorded
# source and existing generic-runner context are mandatory before its one claim.
# An owner runs the registered source, never invokes release manually.
# The action is claimed once, bounded separately, and interruption preserves
# custody and reports the failure without consuming the resume error budget.
# Release budgets expensive children to an internal deadline, reserving at least
# two seconds (up to 30 seconds) for notification/lock cleanup before its outer
# action envelope. A later listener poll or restore entry only notifies uncertain
# hard-kill custody; it never reaps locks, edits custody records or retries native
# work. The supervisor must reconcile that rare interrupted transaction.
# Missing/invalid attempt evidence stays not-yet (poll exit 1) with an error on
# stderr. Only notification append failure uses poll exit 2, so the existing
# condition-error outcome wakes the supervisor after its ordinary error budget.
# bin/fm-suspend-lib.sh owns saved-work custody, exclusions and crash phases.
# A failed qualification retains today's park; a prepared transaction failure
# wakes the supervisor and requires reconciliation before any further action.
#
# --adopt-merge-queue adopts only the exact built-in queue source already
# registered for this task/head. Its condition must be the queue adapter's
# result-ready command. It records park_source and emits [wait=merge-result:head]
# but arms no resume watch: the queue adapter alone settles results. Cancel and
# cleanup retire that source through ordinary guarded retirement. The queue
# runner retires its durably captured terminal source before its landing action
# only for this proven park incarnation, preserving evidence and acknowledgement.
#   fm-park.sh validate <handoff-file> [--when <condition>]
#   fm-park.sh check <condition>
#   fm-park.sh resume <task-id>
#   fm-park.sh cancel <task-id>
#   fm-park.sh stop <task-id>
#
# This CLI is stable: a worker, its supervisor, and other automation (a memory
# guard parking idle agents) all call the park form above.
#
# park      Requires a handoff that passes `validate`, installs it as
#           data/<id>/handoff.md, records the park in the task record, arms a
#           deterministic condition->action watch named park-<id> through
#           bin/fm-procevent-when.sh, appends a declared-wait status line, and
#           finally stops the agent through `bin/fm-control.sh <id> exit`.
#           Default park retains the local copy and every uncommitted change.
#           Enabled copy-free suspension uses the separate saved-custody path
#           described above; it never calls terminal cleanup or discards work. Idempotent: parking an already-parked task retires the old
#           watch and re-arms it with the new handoff, condition, and deadline
#           rather than adding a second watch. A resumed task parks again at
#           once: park acknowledges its own watch's earlier `fired` outcome (the
#           relaunch that started this session) before re-arming; any other
#           unhandled outcome still refuses the re-arm until the supervisor
#           handles it. --when defaults to the one
#           condition named in the handoff's "Waiting for" section; when given,
#           it must equal that condition exactly. --deadline is a UTC time,
#           YYYY-MM-DDTHH:MM[:SS]Z, default seven days from now (FM_PARK_DEADLINE_SECS).
#           When run by the worker parking itself (FM_TASK_ID is the task, or
#           the current directory is inside its worktree), the exit is detached
#           through `stop` so this command can return before its own session is
#           stopped; its output goes to data/<id>/park-exit.log. A Claude
#           worker parking itself is refused, before anything is installed,
#           while its session still runs a background shell or Monitor watch,
#           because Claude's exit would stop on its "Background work is
#           running" prompt; the refusal lists them, and the worker stops them
#           and parks again. A failed exit
#           leaves the park armed: the watch still relaunches the task when the
#           condition holds. Park records the task's spawn_gen incarnation so
#           resume can tell whether the session it would replace is still the
#           parked one.
# validate  Check a handoff file: it needs non-empty "Goal", "Done",
#           "Waiting for", and "Next steps" sections (any Markdown heading
#           level), and "Waiting for" must name a machine-checkable condition.
# check     Evaluate one condition once: exit 0 true, 1 not yet, any other exit
#           an error. This is the watch's condition command.
# resume    The watch's action: relaunch the parked task as a fresh session
#           through `bin/fm-control.sh <id> relaunch --note-file`, with a note
#           carrying the handoff path and a pointer to the results. On success
#           the record reads park_state=resumed and a working: status line is
#           appended so the new session is not mistaken for the declared wait.
#           On failure retained-copy work reads park_state=resume-failed; saved
#           work keeps its resumable wait so pre-allocation failures are retryable.
#           Everything else is intact, and the nonzero exit becomes the watch's
#           action-failed outcome, which wakes the supervisor. When the task was
#           relaunched or respawned since it parked (its spawn_gen changed), the
#           live session is left alone: nothing is relaunched, the park fields
#           are cleared, and the nonzero exit wakes the supervisor with that
#           reason; the watch fires once, so it is already spent.
# cancel    Retire automatic pickup and mark park_state=cancelled, without
#           relaunching or resolving an approval. Saved work remains intact;
#           an explicit owner `resume <id>` (no listener token) or control
#           relaunch can restore it later. A retired listener cannot do so.
#           Tearing down a parked task
#           (bin/fm-teardown.sh) retires its watch the same way.
# stop      The detached exit of a self-park: after FM_PARK_SELF_EXIT_DELAY
#           seconds (3) stop the agent through `bin/fm-control.sh <id> exit`; if
#           that fails, append a blocked: status line naming park-exit.log so the
#           supervisor is woken rather than an idle session holding memory.
#
# Conditions (one line, no shell interpretation):
#   file:<absolute-path>          true once the path exists (a fetched run, a results file)
#   pr-merged:<github-pr-url>     true once the PR is merged; closed unmerged is an error
#   inbox:<task-id>              true only after explicit `pickup <task-id>`;
#                                 ordinary text/reminders never authorize pickup
#   cmd:<executable> [args...]    run directly, arguments split on whitespace;
#                                 exit 0 true, 1 not yet, anything else an error;
#                                 an executable path must be absolute
# Written without backticks, a file: or pr-merged: condition ends at the first
# whitespace, and trailing punctuation (.,;:)) is not part of it.
#
# Outcomes that need the supervisor come from the watch itself: the deadline
# passing without the condition (never-true), repeated condition errors
# (condition-error), and a failed relaunch (action-failed) each wake firstmate
# through the process-event path; a successful relaunch wakes it as fired.
# The .agents/skills/process-event-sources skill owns handling those wakes.
#
# Task record fields owned by this script (state/<id>.meta):
#   park_state=parked|resumed|resume-failed|cancelled
#   park_handoff=<absolute path of data/<id>/handoff.md>
#   park_when=<condition>
#   park_deadline=<UTC ISO time>
#   park_token=<token>         binds the listener to one park incarnation
#   park_pickup=<park-token>   explicit supervisor pickup of an inbox-only wait
#   park_exit_confirmed=<park-token>  verified stop receipt for release readiness
#   park_release_source=<when-source-id>  separate bounded copy-release action
#   park_release_attempt=<park-token>  claimed one attempt for this incarnation
#   park_release_timeout=<seconds>  recorded outer action bound (minimum 5)
#   park_release_pid=<pid>      release lock owner; live/unknown never reclaimed
#   park_release_pid_identity=<fm_pid_identity>  parent-only PID reuse evidence
#   park_release_notified=<park-token>  idempotent interrupted-custody notification
#   wait_started_at=<epoch>    continuous unresolved-condition start
#   park_open_ended=0|1        explicit open-ended wait classification
#   park_relocation_safe=0|1   attestation, never a bypass of safety checks
#   park_at=<epoch>            when the latest park was recorded
#   park_spawn_gen=<token>     the task's spawn_gen when it parked
#   park_resumed_at=<epoch>    when the latest resume relaunched the task
#   park_source=<source-id>    adopted queue source, empty for ordinary parks
#
# Environment knobs:
#   FM_PARK_INTERVAL       condition poll cadence in seconds (300)
#   FM_PARK_STABLE         consecutive true polls required (2)
#   FM_PARK_ERROR_BUDGET   consecutive condition errors before waking (5)
#   FM_PARK_DEADLINE_SECS  default deadline from now (604800)
#   FM_PARK_RELEASE_TIMEOUT  separate copy-release action bound (1800 seconds, minimum 5)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-suspend-lib.sh
. "$SCRIPT_DIR/fm-suspend-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Test seam: a fake control plane stands in for the harness endpoint.
CONTROL="${FM_PARK_CONTROL_OVERRIDE:-$SCRIPT_DIR/fm-control.sh}"
WHEN="$SCRIPT_DIR/fm-procevent-when.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

die() { printf 'fm-park: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

meta_get() {  # <key>: the last value of key= in this task's record
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "$META" 2>/dev/null
}

task_resolve() {  # <id>
  ID=${1-}
  fm_task_id_path_safe "$ID" || die "not a valid task id: '$ID'"
  META="$STATE/$ID.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || die "task $ID has no task record in this home ($META)"
  case "$(meta_get kind)" in
    ship|scout) ;;
    *) die "task $ID is kind '$(meta_get kind)'; only ship and scout tasks park (a secondmate idles by design)" ;;
  esac
  [ -z "$(meta_get remote_host)" ] || die "task $ID runs on another host; park it there"
}

# --- task record -------------------------------------------------------------

# park_record <key=value>...: atomically set the given park_* fields, keeping
# every other line in order; with no arguments, remove every park_* field. The
# pr=/pr_head= pair stays the record's tail, which bin/fm-pr-lib.sh requires, so
# the new lines go just before it.
park_record() {
  local lock tmp line placed=0 kv keys=' '
  for kv in "$@"; do keys="$keys${kv%%=*} "; done
  lock=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$lock"
  tmp=$(mktemp "$STATE/.$ID.meta.park.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$keys" in *" ${line%%=*} "*) continue ;; esac
      case "$line" in
        park_*=*|wait_started_at=*)
          [ "$#" -gt 0 ] || continue
          ;;
        pr=*)
          if [ "$placed" -eq 0 ]; then
            for kv in "$@"; do printf '%s\n' "$kv"; done
            placed=1
          fi
          ;;
      esac
      printf '%s\n' "$line"
    done < "$META"
    if [ "$placed" -eq 0 ]; then
      for kv in "$@"; do printf '%s\n' "$kv"; done
    fi
  } > "$tmp" || { rm -f -- "$tmp"; fm_lock_release "$lock"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! fm_backlog_atomic_transition publish "$tmp" "$META" "task record" "$STATE"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

status_append() {  # <line>
  local status="$STATE/$ID.status"
  printf '%s\n' "$(status_stamp_line "$1")" >> "$status" || return 1
  if [ -e "$CONFIG/fleet-ledger" ]; then
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$status" >/dev/null 2>&1 || true
  fi
}

# --- conditions --------------------------------------------------------------

# condition_valid <condition>: 0 when it is one of the documented kinds and
# well formed; otherwise prints why on stderr.
condition_valid() {
  local cond=${1-} value exe
  case "$cond" in
    *$'\n'*) echo "a condition is one line" >&2; return 1 ;;
    inbox:*) fm_task_id_path_safe "${cond#inbox:}" || return 1; return 0 ;;
    file:/*) return 0 ;;
    file:*) echo "file: needs an absolute path" >&2; return 1 ;;
    pr-merged:*)
      value=${cond#pr-merged:}
      fm_pr_url_parse "$value" && [ "$FM_PR_PROVIDER" = github ] \
        || { echo "pr-merged: needs a full GitHub pull request URL" >&2; return 1; }
      ;;
    cmd:*)
      read -r exe _ <<< "${cond#cmd:}"
      [ -n "$exe" ] || { echo "cmd: needs an executable" >&2; return 1; }
      case "$exe" in
        /*) [ -x "$exe" ] && [ -f "$exe" ] ;;
        */*) echo "cmd: an executable path must be absolute: $exe" >&2; return 1 ;;
        *) command -v -- "$exe" >/dev/null 2>&1 ;;
      esac || { echo "cmd: executable is unavailable: $exe" >&2; return 1; }
      ;;
    *) echo "unknown condition kind (use file:, pr-merged:, or cmd:): $cond" >&2; return 1 ;;
  esac
}

cmd_check() {
  local cond=${1-} state
  local -a argv
  condition_valid "$cond" || exit 2
  case "$cond" in
    inbox:*)
      task_resolve "${cond#inbox:}"
      [ -n "$(meta_get park_token)" ] && [ "$(meta_get park_pickup)" = "$(meta_get park_token)" ] && exit 0
      exit 1 ;;
    file:*) [ -e "${cond#file:}" ] && exit 0; exit 1 ;;
    pr-merged:*)
      state=$(gh pr view "${cond#pr-merged:}" --json state --jq .state 2>&1) || {
        printf 'cannot read the pull request: %s\n' "$state"; exit 2; }
      case "$state" in
        MERGED) exit 0 ;;
        OPEN) exit 1 ;;
        CLOSED) echo "the pull request was closed without merging"; exit 3 ;;
        *) printf 'unexpected pull request state: %s\n' "$state"; exit 2 ;;
      esac
      ;;
    cmd:*)
      read -r -a argv <<< "${cond#cmd:}"
      exec "${argv[@]}"
      ;;
  esac
}

# The pointer a resumed session reads first to find what it was waiting for.
results_pointer() {  # <condition>
  local cond=$1
  case "$cond" in
    inbox:*) printf 'the supervisor explicitly authorized pickup; read ordinary inbox messages in sequence' ;;
    file:*) printf 'the results are at %s' "${cond#file:}" ;;
    pr-merged:*) printf 'the pull request %s is merged' "${cond#pr-merged:}" ;;
    cmd:*) printf 'the check "%s" now succeeds; run it to read the result' "${cond#cmd:}" ;;
  esac
}

# --- handoff validation ------------------------------------------------------

# section_body <file> <heading>: the lines under a heading, case-insensitive,
# up to the next heading of any level.
section_body() {
  awk -v want="$2" '
    function norm(s) { sub(/^#+[ \t]+/, "", s); sub(/[ \t:]+$/, "", s); return tolower(s) }
    /^#+[ \t]/ { inside = (norm($0) == want); next }
    inside { print }
  ' "$1"
}

section_filled() {  # <body>: 0 when it holds any non-placeholder text
  printf '%s\n' "$1" | awk '
    { line = $0; gsub(/[ \t>*_`-]/, "", line); low = tolower(line) }
    line != "" && low !~ /^(tbd|todo|none|n\/a|\.\.\.)$/ && low !~ /^\{.*\}$/ { found = 1 }
    END { exit found ? 0 : 1 }'
}

# The one condition named in a "Waiting for" body: the first backticked token
# starting with a known kind, else the first such word (at a line start or after
# whitespace): a cmd: takes the rest of its line, a file: or pr-merged: only its
# first token without trailing punctuation.
waiting_condition() {  # <body>
  printf '%s\n' "$1" | awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++)
        if (match(lines[i], /`(file|pr-merged|cmd|inbox):[^`]*`/)) {
          print substr(lines[i], RSTART + 1, RLENGTH - 2); exit
        }
      for (i = 1; i <= NR; i++)
        if (match(lines[i], /(^|[ \t])(file|pr-merged|cmd|inbox):/)) {
          line = substr(lines[i], RSTART); sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
          if (line !~ /^cmd:/) { sub(/[ \t].*/, "", line); sub(/[.,;:)]+$/, "", line) }
          print line; exit
        }
    }'
}

# validate_handoff <file> [condition]: sets HANDOFF_CONDITION; dies with every
# problem named at once.
validate_handoff() {
  local file=$1 want=${2-} section body problems='' waiting err
  [ -f "$file" ] && [ -r "$file" ] || die "handoff file is missing or unreadable: $file"
  for section in goal "done" "waiting for" "next steps"; do
    body=$(section_body "$file" "$section")
    section_filled "$body" || problems="$problems"$'\n'"  - section \"$section\" is missing or empty"
  done
  waiting=$(section_body "$file" "waiting for")
  HANDOFF_CONDITION=$(waiting_condition "$waiting")
  if [ -z "$HANDOFF_CONDITION" ]; then
    problems="$problems"$'\n'"  - \"Waiting for\" names no condition (file:<path>, pr-merged:<url>, or cmd:<executable> [args])"
  elif [ -n "$want" ] && [ "$want" != "$HANDOFF_CONDITION" ]; then
    problems="$problems"$'\n'"  - \"Waiting for\" does not name the --when condition: $want (it names $HANDOFF_CONDITION)"
  fi
  if [ -n "$HANDOFF_CONDITION" ] && ! err=$(condition_valid "$HANDOFF_CONDITION" 2>&1); then
    problems="$problems"$'\n'"  - $err"
  fi
  [ -z "$problems" ] || die "handoff $file is incomplete:$problems
A handoff needs ## Goal, ## Done, ## Waiting for (with one machine-checkable condition), and ## Next steps."
}

cmd_validate() {
  local file=${1-} want=''
  [ -n "$file" ] || { usage >&2; exit 2; }
  shift
  case "${1-}" in
    --when) want=${2-}; [ -n "$want" ] || die "--when needs a condition" ;;
    '') ;;
    *) die "unknown validate argument: $1" ;;
  esac
  validate_handoff "$file" "$want"
  printf 'handoff ok: waiting for %s\n' "$HANDOFF_CONDITION"
}

# --- park --------------------------------------------------------------------

cmd_park() {
  local handoff='' want='' deadline_iso='' deadline_epoch now rel dest wt here detached=0 detach out adopted='' sid='' tag=''
  local open_ended=0 relocation_safe=0 started token release_name release_timeout
  task_resolve "${1-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --open-ended) open_ended=1; shift ;;
      --relocation-safe) relocation_safe=1; shift ;;
      --handoff) handoff=${2-}; shift 2 || die "--handoff needs a file" ;;
      --when) want=${2-}; shift 2 || die "--when needs a condition" ;;
      --deadline) deadline_iso=${2-}; shift 2 || die "--deadline needs a UTC time" ;;
      --adopt-merge-queue) adopted=${2-}; [ -n "$adopted" ] || die "--adopt-merge-queue needs a head"; shift 2 ;;
      *) die "unknown park argument: $1" ;;
    esac
  done
  release_timeout=${FM_PARK_RELEASE_TIMEOUT:-1800}
  case "$release_timeout" in ''|0*|*[!0-9]*) die "copy-release action bound must be an integer of at least 5 seconds" ;; esac
  [ "${#release_timeout}" -le 6 ] && [ "$release_timeout" -ge 5 ] || die "copy-release action bound must be 5..999999 seconds"
  [ -n "$handoff" ] || die "park needs --handoff <file> (sections: Goal, Done, Waiting for, Next steps)"
  validate_handoff "$handoff" "$want"
  case "$(meta_get copy_state)" in ''|retained) ;; *) die "saved copy custody requires reconciliation or restoration, not re-park" ;; esac
  case "$HANDOFF_CONDITION" in inbox:*) [ "$HANDOFF_CONDITION" = "inbox:$ID" ] || die "inbox condition must name this task" ;; esac
  if [ -n "$adopted" ]; then
    fm_procevent_merge_queue_registration_matches "$STATE" "$ID" "$adopted" "$SCRIPT_DIR/fm-procevent-merge-queue.sh" \
      || die "no matching registered queue source for task $ID head $adopted"
    [ "$HANDOFF_CONDITION" = "cmd:$SCRIPT_DIR/fm-procevent-merge-queue.sh result-ready $adopted" ] \
      || die "adopted queue condition must be its result-ready command"
    [ -n "$(meta_get spawn_gen)" ] || die "adopting a queue source requires a task incarnation"
    sid="merge-queue-$ID-${adopted:0:8}"
    tag=" [key=merge-queue] [wait=merge-result:$adopted]"
  fi
  [ "${FM_TASK_ID-}" != "$ID" ] || detached=1
  wt=$(meta_get worktree)
  here=$(pwd -P 2>/dev/null || true)
  if [ -n "$wt" ] && wt=$(cd "$wt" 2>/dev/null && pwd -P); then
    case "$here/" in "$wt"/*) detached=1 ;; esac
  fi
  [ "$detached" -eq 0 ] || [ "$(meta_get harness)" != claude ] || refuse_claude_background_work
  now=$(date +%s)
  if [ -n "$deadline_iso" ]; then
    deadline_epoch=$(fm_utc_iso_to_epoch "$deadline_iso") \
      || die "--deadline must be a UTC time like 2026-10-02T12:00Z: $deadline_iso"
  else
    deadline_epoch=$(( now + ${FM_PARK_DEADLINE_SECS:-604800} ))
  fi
  rel=$(( deadline_epoch - now ))
  [ "$rel" -gt 0 ] || die "--deadline is not in the future: $deadline_iso"
  deadline_iso=$(date -u -d "@$deadline_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$deadline_epoch" +%Y-%m-%dT%H:%M:%SZ) || die "cannot format the deadline"

  mkdir -p "$DATA/$ID" || die "cannot create $DATA/$ID"
  dest="$DATA/$ID/handoff.md"
  if [ "$(cd "$(dirname "$handoff")" && pwd -P)/$(basename "$handoff")" != "$(cd "$DATA/$ID" && pwd -P)/handoff.md" ]; then
    if ! cp -- "$handoff" "$dest.tmp.$$" || ! mv -f -- "$dest.tmp.$$" "$dest"; then
      rm -f -- "$dest.tmp.$$"
      die "cannot install the handoff at $dest"
    fi
  fi

  # Re-park replaces the watch rather than adding one.
  retire_release_source || die "cannot retire the earlier copy-release source"
  ack_own_fired
  if [ -n "$(meta_get park_source)" ] && [ "$(meta_get park_source)" != "$sid" ]; then
    "$SCRIPT_DIR/fm-procevent.sh" retire "$(meta_get park_source)" >/dev/null \
      || die "cannot retire the earlier adopted source"
  fi
  "$WHEN" retire "park-$ID" >/dev/null 2>&1 || true
  started=$now
  if [ "$(meta_get park_state)" = parked ] && [ "$(meta_get park_when)" = "$HANDOFF_CONDITION" ] &&
     [ "$(meta_get park_spawn_gen)" = "$(meta_get spawn_gen)" ]; then
    started=$(meta_get wait_started_at)
    case "$started" in ''|*[!0-9]*) started=$(meta_get park_at) ;; esac
    case "$started" in ''|*[!0-9]*) started=$now ;; esac
  fi
  token="park.$now.${BASHPID:-$$}.$RANDOM"
  park_record "park_state=parked" "park_handoff=$dest" "park_when=$HANDOFF_CONDITION" \
    "park_token=$token" "park_pickup=" 'park_exit_confirmed=' 'park_release_source=' 'park_release_attempt=' \
    "park_release_timeout=$release_timeout" 'park_release_pid=' 'park_release_pid_identity=' 'park_release_notified=' \
    "wait_started_at=$started" "park_open_ended=$open_ended" "park_relocation_safe=$relocation_safe" \
    "park_source=$sid" "park_deadline=$deadline_iso" "park_at=$now" "park_spawn_gen=$(meta_get spawn_gen)" \
    || die "cannot record the park in task $ID's record"
  if [ -z "$sid" ] && ! out=$("$WHEN" arm "park-$ID" \
      --interval "${FM_PARK_INTERVAL:-300}" --stable "${FM_PARK_STABLE:-2}" \
      --deadline "$rel" --error-budget "${FM_PARK_ERROR_BUDGET:-5}" --action-timeout 900 \
      --condition "$SCRIPT_DIR/fm-park.sh" poll "$ID" "$token" \
      --action "$SCRIPT_DIR/fm-park.sh" resume "$ID" "$token" 2>&1); then
    park_record "park_state=cancelled" || true
    die "could not arm the resume watch, so task $ID was not parked and its agent keeps running: $out"
  fi
  if [ -z "$sid" ] && fm_suspend_enabled "$CONFIG" && [ "$relocation_safe" = 1 ]; then
    release_name=$(release_source_name) || die "cannot name the copy-release source"
    if ! out=$("$WHEN" arm "$release_name" --interval "${FM_PARK_INTERVAL:-300}" --stable 1 \
        --deadline "$rel" --error-budget "${FM_PARK_ERROR_BUDGET:-5}" \
        --action-timeout "$release_timeout" \
        --condition "$SCRIPT_DIR/fm-park.sh" release-ready "$ID" "$token" \
        --action "$SCRIPT_DIR/fm-park.sh" release "$ID" "$token" 2>&1); then
      "$WHEN" retire "park-$ID" >/dev/null 2>&1 || true
      park_record 'park_state=cancelled' || true
      die "could not arm copy release; agent left running: $out"
    fi
    park_record "park_release_source=when-$release_name" || die "cannot record the copy-release source"
  fi
  status_append "$PAUSED_VERB$tag: parked until $deadline_iso - waiting for $HANDOFF_CONDITION; result action owned by ${sid:-park-$ID} with $dest" \
    || die "task $ID is parked and its watch armed, but the status line could not be appended"

  if [ "$detached" -eq 1 ]; then
    # The worker is parking itself: stopping the agent would kill this very
    # command, so return first and let a detached exit stop the session.
    # A new session keeps the exit alive when the agent's own process group
    # is interrupted; nohup is the fallback where setsid is absent.
    if command -v setsid >/dev/null 2>&1; then detach="setsid"; else detach="nohup"; fi
    "$detach" "$SCRIPT_DIR/fm-park.sh" stop "$ID" "$token" > "$DATA/$ID/park-exit.log" 2>&1 < /dev/null &
    printf 'parked %s: waiting for %s until %s; this session stops in a few seconds and a fresh one starts with %s when the condition holds\n' \
      "$ID" "$HANDOFF_CONDITION" "$deadline_iso" "$dest"
    return 0
  fi
  if ! out=$("$CONTROL" "$ID" exit 2>&1); then
    printf 'fm-park: task %s is parked and its watch armed, but its agent could not be stopped: %s\n' "$ID" "$out" >&2
    exit 1
  fi
  park_record "park_exit_confirmed=$token" || die "verified exit could not be recorded"
  printf 'parked %s: waiting for %s until %s; agent stopped (%s)\n' "$ID" "$HANDOFF_CONDITION" "$deadline_iso" "$out"
}

# refuse_claude_background_work: a Claude session asked to exit while one of
# its own background shells or Monitor watches still runs stops on its
# "Background work is running" prompt instead of exiting, so the detached exit
# would leave it idle until someone intervenes by hand. Claude hands every tool
# shell CLAUDE_PID, the process that owns those shells; it is trusted only when
# it is an ancestor of this command, so a value inherited from elsewhere is
# ignored. Each shell child of that process that is not this command's own tool
# shell is background work, and park refuses before installing anything. An
# unreadable process table steps aside; the detached exit's blocked line
# remains the backstop.
refuse_claude_background_work() {
  local agent=${CLAUDE_PID-} pid=$$ hops=0 found=0 chain=' ' table list='' cpid cppid ccomm base what
  case "$agent" in ''|*[!0-9]*) return 0 ;; esac
  while [ "$hops" -lt 32 ]; do
    case "$pid" in ''|*[!0-9]*) break ;; esac
    [ "$pid" -gt 1 ] || break
    [ "$pid" != "$agent" ] || { found=1; break; }
    chain="$chain$pid "
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  [ "$found" -eq 1 ] || return 0
  table=$(ps -A -o pid= -o ppid= -o comm= 2>/dev/null) || return 0
  while read -r cpid cppid ccomm; do
    [ "$cppid" = "$agent" ] || continue
    case "$chain" in *" $cpid "*) continue ;; esac
    base=${ccomm##*/}
    case "${base#-}" in
      bash|sh|zsh|dash|ash|ksh|mksh|fish|tcsh|csh)
        # Claude wraps each command in a long shell preamble, so name what
        # the shell is running (its children) when it runs anything.
        what=$(awk -v p="$cpid" '$2 == p { printf "%s%s", sep, $1; sep = "," }' <<< "$table")
        [ -z "$what" ] || what=$(ps -o args= -p "$what" 2>/dev/null | paste -sd ';' - | cut -c1-160)
        [ -n "$what" ] || what=$(ps -o args= -p "$cpid" 2>/dev/null | cut -c1-160)
        list="$list"$'\n'"  - shell $cpid running: $what" ;;
    esac
  done <<< "$table"
  [ -n "$list" ] || return 0
  die "task $ID was not parked: this Claude session still runs background work, and exiting now would stop on Claude's \"Background work is running\" prompt and leave the session idle:$list
Stop every background shell and Monitor watch this session started (or let them finish), then run the same park command again."
}

# The resume that started this session left its watch's fired outcome captured;
# acknowledge it, and only it, so the re-arm below is not refused. Any other
# unhandled outcome of this watch is the supervisor's and still blocks the arm.
ack_own_fired() {
  local sid="when-park-$ID" result base
  while IFS= read -r result; do
    base=${result%.result}
    [ "${base%.*}" = "$(fm_procevent_inbox_dir "$STATE")/$sid" ] || continue
    [ "$("$WHEN" classify "$result" 2>/dev/null)" = fired ] || continue
    "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$(fm_procevent_result_sequence "$result")" >/dev/null \
      || die "cannot acknowledge the earlier resume of task $ID ($result)"
  done < <(fm_procevent_pending "$STATE")
}

cmd_stop() {
  local out token
  task_resolve "${1-}"
  token=${2:-$(meta_get park_token)}
  sleep "${FM_PARK_SELF_EXIT_DELAY:-3}"
  [ "$(meta_get park_token)" = "$token" ] && [ "$(meta_get park_state)" = parked ] || die "retired park incarnation cannot stop an agent"
  if ! out=$("$CONTROL" "$ID" exit 2>&1); then
    printf '%s\n' "$out"
    status_append "blocked: parked and its resume watch armed, but this session could not be stopped; see $DATA/$ID/park-exit.log" || true
    exit 1
  fi
  printf '%s\n' "$out"
  park_record "park_exit_confirmed=$token" || die "verified exit could not be recorded"
}

# --- resume and cancel -------------------------------------------------------

cmd_resume() {
  local cond handoff note out release_source
  task_resolve "${1-}"
  [ -z "${2-}" ] || [ "$(meta_get park_token)" = "$2" ] || die "retired park incarnation cannot resume"
  fm_suspend_reconcile_release "$META" "$ID" "$STATE" "$CONFIG" || die "cannot reconcile interrupted release notification"
  case "$(meta_get copy_state)" in ''|retained|released) ;; *) die "unfinished copy transaction; reconcile before resume" ;; esac
  case "$(meta_get park_state):$(meta_get copy_state):${2-}" in
    parked:*) ;;
    cancelled:released:|resume-failed:released:)
      [ -z "${FM_TASK_ID-}" ] || die "only the supervisor authorizes explicit saved-task resumption" ;;
    *) die "task $ID is not parked (park_state=$(meta_get park_state)); nothing to resume" ;;
  esac
  if [ "$(meta_get spawn_gen)" != "$(meta_get park_spawn_gen)" ]; then
    retire_release_source || die "superseded task's copy-release source could not be retired"
    park_record || die "task $ID was relaunched or respawned since it parked, but its park record could not be cleared"
    printf 'fm-park: task %s was relaunched or respawned since it parked, so its live session was left running and the park cleared; nothing was relaunched\n' "$ID" >&2
    exit 1
  fi
  [ -z "$(meta_get park_source)" ] || die "the adopted queue source owns this task's result action; park resume does not relaunch it"
  cond=$(meta_get park_when)
  if [ "$(meta_get copy_state)" = released ]; then
    fm_suspend_validate "$META" "$ID" "$FM_HOME" "$DATA" || die "saved-task proof is missing or invalid"
  fi
  handoff=$(meta_get park_handoff)
  note="$DATA/$ID/park-resume-note.md"
  {
    if [ "$(meta_get park_state)" = cancelled ]; then
      echo 'The owner explicitly resumed this cancelled wait. The waiting condition may still be unresolved; this does not resolve or waive any approval or obligation.'
    else
      echo "This task was parked while it waited on an external result, and the wait is over: $(results_pointer "$cond")."
    fi
    echo "The condition was: $cond"
    if [ "$(meta_get copy_state)" = released ]; then
      echo "This is a different copy under a fresh acquisition, even if its physical path is reused. Uncommitted state is not inherited; only the saved committed head verified by the bundle is restored."
    fi
    echo "Read the handoff at $handoff first; it records the goal, what was already done, and the next steps."
    echo "Continue from its next steps. If you must wait on something external again, park again rather than idling."
  } > "$note" || die "cannot write the resume note for task $ID"
  if ! out=$("$CONTROL" "$ID" relaunch --note-file "$note" 2>&1); then
    # A pre-allocation failure must remain directly retryable. Interrupted copy
    # transactions still refuse, but never erase the saved wait/owner authority.
    case "$(meta_get copy_state)" in
      released|restore-prepared) ;;
      *) park_record 'park_state=resume-failed' || true ;;
    esac
    printf 'fm-park: the condition held but task %s could not be relaunched; saved work and task records remain; reconcile any interrupted copy transaction: %s\n' "$ID" "$out" >&2
    exit 1
  fi
  release_source=$(meta_get park_release_source)
  if retire_release_source; then
    release_source=
  else
    status_append 'blocked [key=copy-release-source]: task resumed, but its obsolete copy-release source could not be retired; reconcile that source without relaunching the running task' || true
  fi
  park_record "park_state=resumed" "park_resumed_at=$(date +%s)" "park_release_source=$release_source" \
    || printf 'fm-park: task %s was relaunched but its park record could not be updated\n' "$ID" >&2
  status_append "working: resumed from park - $cond held; fresh session started from $handoff" || true
  printf 'resumed %s: %s\n' "$ID" "$out"
}

cmd_cancel() {
  task_resolve "${1-}"
  retire_release_source || die "cannot retire the copy-release source"
  if [ -n "$(meta_get park_source)" ]; then
    "$SCRIPT_DIR/fm-procevent.sh" retire "$(meta_get park_source)" >/dev/null \
      || die "could not retire the adopted queue watch for task $ID"
  else
    "$WHEN" retire "park-$ID" >/dev/null || die "could not retire the watch for task $ID"
  fi
  [ -z "$(meta_get park_state)" ] || park_record "park_state=cancelled" \
    || die "the watch is retired but task $ID's park record could not be updated"
  printf 'cancelled park of %s; nothing was relaunched\n' "$ID"
}

# Stable short source name, including home/task/incarnation without exceeding
# the existing when adapter's name bound. The bound argv still carries the full
# task/token; a name collision cannot confer task or acquisition authority.
release_source_name() {
  fm_suspend_release_source_name "$FM_HOME" "$ID" "$(meta_get park_token)"
}

retire_release_source() {
  local source name
  source=$(meta_get park_release_source)
  [ -n "$source" ] || return 0
  name=$(release_source_name) || return 1
  [ "$source" = "when-$name" ] || return 1
  "$WHEN" retire "$name" >/dev/null
}

cmd_release_ready() {
  task_resolve "${1-}"
  [ "$(meta_get park_token)" = "${2-}" ] && [ "$(meta_get park_state)" = parked ] &&
    [ "$(meta_get spawn_gen)" = "$(meta_get park_spawn_gen)" ] || return 2
  [ "$(meta_get park_exit_confirmed)" = "${2-}" ] &&
    [ "$(meta_get park_release_attempt)" != "${2-}" ] || return 1
  case "$(meta_get copy_state)" in ''|retained) ;; *) return 1 ;; esac
  fm_suspend_enabled "$CONFIG" && fm_suspend_qualified "$META" "$(date +%s)"
}

# The custody owner survives its internally timed children. EXIT/TERM cleanup
# shares every ordinary outcome; a hard kill is reconciled by poll/restore from
# dead-attempt evidence, never by replaying the native acquisition.
release_cleanup() {
  local rc=$1
  if [ "$rc" -ne 0 ] && [ "$(meta_get copy_state)" = release-prepared ]; then
    fm_suspend_notify_release "$META" "$ID" "$STATE" "$CONFIG" || true
  elif [ "${FM_SUSPEND_DEADLINE:-0}" -gt 0 ] && [ "$SECONDS" -ge "$FM_SUSPEND_DEADLINE" ] &&
       [ "$(meta_get copy_state)" = retained ]; then
    status_append 'blocked [key=copy-release-timeout]: internal release deadline expired before saved custody completed; work copy retained, reconcile before retry' || true
  fi
  [ -z "$project_lock" ] || fm_lock_release "$project_lock"
  [ -z "$meta_lock" ] || fm_lock_release "$meta_lock"
  [ -z "$control_lock" ] || fm_lock_release "$control_lock"
  if declare -F fm_lease_guard_release >/dev/null; then fm_lease_guard_release; fi
}

# One retained-refusal owner for the deadline-bound preparation steps. Expiry
# must remain an action failure, never a dirty/job/evidence qualification reason.
release_retain() { # <reason>; called with the metadata lock and local deadline
  [ "$SECONDS" -lt "$FM_SUSPEND_DEADLINE" ] || return 1
  fm_suspend_record "$META" "copy_retain_reason=$1"
}

# Release is the separate registered action, never part of condition polling.
cmd_release() (
  [ -z "${FM_TASK_ID-}" ] && [ "${FM_PROCEVENT_IN_RUNNER:-0}" = 1 ] || die "copy release is only a registered process-event action, never a manual or worker entrypoint"
  task_resolve "${1-}"
  printf 'copy release task=%s incarnation=%s\n' "$ID" "$2"
  local control_lock='' meta_lock='' project_lock='' lock release_wt release_project holder lease backend target status
  local bound headroom release_pid release_identity
  bound=$(meta_get park_release_timeout)
  case "$bound" in ''|0*|*[!0-9]*) die "missing or invalid registered release bound" ;; esac
  [ "${#bound}" -le 6 ] && [ "$bound" -ge 5 ] || die "registered release bound must be 5..999999 seconds"
  headroom=$((bound / 10)); [ "$headroom" -ge 2 ] || headroom=2
  [ "$headroom" -le 30 ] || headroom=30
  # Do not export to callers/restoration: this deadline belongs to this action.
  # shellcheck disable=SC2034 # Read dynamically by fm_suspend_run in the library.
  local FM_SUSPEND_DEADLINE=$((SECONDS + bound - headroom))
  trap 'release_cleanup "$?"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  fm_suspend_enabled "$CONFIG" || return 0
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  fm_lease_guard "$ID" 'park copy release' || return 1
  lock="$STATE/.control-$ID.lock"; fm_lock_try_acquire "$lock" || return 0; control_lock=$lock
  lock=$(fm_meta_lock_path "$META") && fm_lock_try_acquire "$lock" || return 0; meta_lock=$lock
  [ "$(meta_get park_state)" = parked ] && [ "$(meta_get spawn_gen)" = "$(meta_get park_spawn_gen)" ] || return 0
  [ "$(meta_get park_token)" = "$2" ] && [ "$(meta_get park_exit_confirmed)" = "$2" ] || return 0
  [ "$(meta_get park_release_source)" = "when-$(release_source_name)" ] || return 1
  [ "$(meta_get park_release_attempt)" != "$2" ] || return 0
  fm_current_pid release_pid || return 1
  release_identity=$(fm_pid_identity "$release_pid") && [ -n "$release_identity" ] || return 1
  fm_suspend_record "$META" "park_release_attempt=$2" "park_release_pid=$release_pid" \
    "park_release_pid_identity=$release_identity" || return 1
  case "$(meta_get copy_state)" in released) return 0 ;; ''|retained) ;; *) return 1 ;; esac
  if ! fm_suspend_qualified "$META" "$(date +%s)"; then
    fm_suspend_record "$META" 'copy_retain_reason=short wait or missing relocation-safety attestation' || return 1
    return 0
  fi
  # Never release when the wait already cleared: its sole listener owns resume.
  "$SCRIPT_DIR/fm-park.sh" check "$(meta_get park_when)" >/dev/null 2>&1; status=$?
  [ "$status" = 1 ] || return 0
  release_wt=$(meta_get worktree); release_project=$(meta_get project)
  if ! fm_suspend_dependencies_clear "$META" "$(meta_get park_handoff)" "$release_wt" "$(meta_get tasktmp)"; then
    fm_suspend_record "$META" 'copy_retain_reason=condition, handoff, temp artifacts or queue custody requires this copy' || return 1
    return 0
  fi
  # Unknown pipeline custody remains retained in this bounded first rollout.
  if [ "$(meta_get mode)" = no-mistakes ]; then
    fm_suspend_record "$META" 'copy_retain_reason=pipeline custody not relocation-qualified' || return 1
    return 0
  fi
  fm_backend_validate_task_endpoint "$META" "$ID" || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND; target=$FM_BACKEND_VALIDATED_TARGET
  case "$backend" in tmux|herdr) ;; *) return 0 ;; esac
  fm_backend_source "$backend" || return 1
  [ "$(fm_backend_agent_state "$backend" "$target")" = dead ] || return 0
  lock=$(fm_treehouse_project_lock_path "$release_project") && fm_lock_try_acquire "$lock" || return 0; project_lock=$lock
  fm_treehouse_pool_slot "$release_project" "$release_wt" || return 0
  # Existing repair owns retained legacy protection. No parallel adopter.
  # shellcheck source=bin/fm-treehouse-adopt-lib.sh
  . "$SCRIPT_DIR/fm-treehouse-adopt-lib.sh"
  fm_treehouse_adopt_locked "$META" "$ID" "$release_project" "$FM_HOME" || return 0
  fm_treehouse_relaunch_reservation "$release_project" "$STATE" "$META" "$ID" "$FM_HOME" || return 0
  if ! fm_suspend_routes_clear "$STATE" "$META" "$ID" "$FM_HOME" ||
     ! fm_suspend_clean_copy "$release_wt" || ! fm_suspend_quiet_copy "$release_project" "$release_wt" "$META" 1; then
    release_retain 'typed route, dirty/unknown artifacts or live/unverified job' || return 1
    return 0
  fi
  # Preserve declared evidence using the existing owner; dependencies still
  # must be relocation-independent, and unknown artifacts never get discarded.
  # shellcheck disable=SC2016 # Arguments expand only in the bounded child.
  if ! fm_suspend_run bash -c '. "$1"; shift; fm_task_evidence_preserve "$@"' _ \
      "$SCRIPT_DIR/fm-task-evidence-lib.sh" "$ID" "$DATA" "$release_wt" 1 "$(meta_get tasktmp)"; then
    release_retain 'declared evidence preservation refused; work copy and lease retained' || return 1
    return 0
  fi
  if ! fm_suspend_save "$META" "$ID" "$FM_HOME" "$DATA" "$release_wt"; then
    # Ordinary pre-preparation refusals keep today's park. Only an expired
    # internal budget changes that refusal into the retained-copy timeout.
    [ "$(meta_get copy_state)" != release-prepared ] || return 1
    release_retain 'saved-work proof unavailable before preparation; work copy and lease retained' || return 1
    return 0
  fi
  holder=$(meta_get treehouse_lease_holder); lease=$(meta_get treehouse_lease_id)
  # shellcheck disable=SC2016 # Arguments expand only in the bounded child.
  if ! fm_suspend_run bash -c '
       . "$1/fm-backend.sh"
       fm_backend_kill "$2" "$3" "" "fm-$4" || exit 1
       [ "$2" != herdr ] || fm_backend_herdr_endpoint_confirmed_gone "$3"
     ' _ "$SCRIPT_DIR" "$backend" "$target" "$ID" ||
     ! fm_suspend_quiet_copy "$release_project" "$release_wt" "$META" 0 ||
     ! fm_suspend_clean_copy "$release_wt" ||
     ! fm_treehouse_relaunch_reservation "$release_project" "$STATE" "$META" "$ID" "$FM_HOME" ||
     ! fm_suspend_validate "$META" "$ID" "$FM_HOME" "$DATA"; then
    return 1 # EXIT reports prepared custody and releases every owned lock.
  fi
  # Unbind the clean physical worktree from the kept logical branch BEFORE
  # retirement. A different selected slot must not find that branch occupied
  # by the released slot, and advancing the restored branch must not turn the
  # idle historical slot into apparently dirty work. Preserve the exact head.
  fm_suspend_run git -C "$release_wt" checkout --detach --no-overwrite-ignore "$FM_SUSPEND_HEAD" || return 1
  [ "$(git -C "$release_wt" rev-parse HEAD)" = "$FM_SUSPEND_HEAD" ] &&
    fm_suspend_clean_copy "$release_wt" && fm_suspend_quiet_copy "$release_project" "$release_wt" "$META" 0 &&
    fm_treehouse_relaunch_reservation "$release_project" "$STATE" "$META" "$ID" "$FM_HOME" || return 1
  # Remove the private claim while the exact native lease still authorizes
  # this copy. After native return, not even claim cleanup may inspect the
  # historical slot: it could already belong to a fresh acquisition.
  fm_treehouse_slot_owner_release "$release_wt" "$ID" || return 1
  # shellcheck disable=SC2016 # Arguments expand only in the bounded child.
  fm_suspend_run bash -c 'cd "$1" && exec treehouse return --if-lease-holder "$2" --if-lease-id "$3" "$4"' _ \
    "$release_project" "$holder" "$lease" "$release_wt" < /dev/null || return 1
  fm_suspend_record "$META" 'copy_state=released' 'worktree=' 'window=' 'treehouse_lease_holder=' 'treehouse_lease_id=' \
    'herdr_workspace_id=' 'herdr_tab_id=' 'herdr_pane_id=' 'copy_retain_reason=' || return 1
  fm_suspend_validate "$META" "$ID" "$FM_HOME" "$DATA" || {
    status_append 'blocked [key=copy-custody]: copy returned but saved-task proof no longer validates; records retained' || true; return 1;
  }
  printf 'suspended %s: saved branch and verified bundle; no copy reserved\n' "$ID"
)

cmd_poll() {
  local reconcile_rc=0
  task_resolve "${1-}"
  [ "$(meta_get park_token)" = "${2-}" ] && [ "$(meta_get park_state)" = parked ] || exit 2
  fm_suspend_reconcile_release "$META" "$ID" "$STATE" "$CONFIG" || reconcile_rc=$?
  case "$reconcile_rc" in
    0) ;;
    1) exit 1 ;; # Uncertain attempt custody is not a condition error.
    *) exit 2 ;; # Notification-write failure uses the existing escalation.
  esac
  # The separate release action owns expensive custody and its own failures.
  # Never consume this listener's error budget while a transaction is preparing;
  # it can resume only once custody is settled, regardless of condition changes.
  case "$(meta_get copy_state)" in
    ''|retained|released) ;;
    release-prepared|restore-prepared) exit 1 ;;
    *) exit 2 ;;
  esac
  cmd_check "$(meta_get park_when)"
}

cmd_pickup() (
  task_resolve "${1-}"
  [ -z "${FM_TASK_ID-}" ] || die "only the supervisor authorizes pickup"
  # Same confused-agent-grade role/lease boundary as the existing owner tools;
  # an unmarked owner shell remains authorized, never an ordinary inbox message.
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  trap 'fm_lease_guard_release' EXIT
  fm_lease_guard "$ID" 'explicit inbox pickup' || die "supervisor lease refused pickup"
  [ "$(meta_get park_state)" = parked ] && [ "$(meta_get park_when)" = "inbox:$ID" ] || die "not an inbox-only wait"
  park_record "park_pickup=$(meta_get park_token)" || die "cannot record explicit pickup authority"
)

case "${1-}" in
  release) shift; [ "$#" = 2 ] && [ -n "$2" ] || exit 2; cmd_release "$@" ;;
  release-ready) shift; [ "$#" = 2 ] || exit 2; cmd_release_ready "$@" ;;
  poll) shift; [ "$#" = 2 ] || exit 2; cmd_poll "$@" ;;
  pickup) shift; [ "$#" = 1 ] || exit 2; cmd_pickup "$1" ;;
  ''|-h|--help|help) usage; [ -n "${1-}" ] || exit 2 ;;
  validate) shift; cmd_validate "$@" ;;
  check) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_check "$1" ;;
  resume) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }; cmd_resume "$@" ;;
  cancel) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_cancel "$1" ;;
  stop) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }; cmd_stop "$@" ;;
  *) cmd_park "$@" ;;
esac
