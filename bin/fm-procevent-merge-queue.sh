#!/usr/bin/env bash
# Merge-queue owner-side glue: a built-in process-event adapter for tasks that
# hand a pushed head to an external merge train instead of landing it
# themselves. The worker hands the head over and declares a wait; one watch per waiting
# head polls the queue tokenlessly and wakes the home only on that head's final
# RESULT or a queue STALL line; and the routine outcomes are settled by this
# script with no agent turn.
#
# Usage:
#   fm-procevent-merge-queue.sh handoff <task-id> <branch> <head40>
#                               [--expect <UTC|+seconds>] [--requested | --open-ended]
#                               [--priority <value>]
#                               [--resume-note <text> | --resume-note-file <path>]
#                               -- <note>...
#   fm-procevent-merge-queue.sh arm <task-id> <head40>
#   fm-procevent-merge-queue.sh result|result-ready <head40>
#   fm-procevent-merge-queue.sh source-id <task-id> <head40>
#   fm-procevent-merge-queue.sh classify <result-file>
#   fm-procevent-merge-queue.sh settle <result-file>
#   fm-procevent-merge-queue.sh retire <task-id> <head40>
#   fm-procevent-merge-queue.sh watch <task-id> <head40>
#   fm-procevent-merge-queue.sh terminal|self-announcing|autohandle ...
#
# handoff    Run by the worker (with FM_HOME naming its supervising home) once
#            its head is pushed to <branch>: runs the queue's own handoff.sh
#            with this home's configured name, arms the watch, stores the
#            optional resume note, and delegates the expected-time policy to
#            fm-park.sh --adopt-merge-queue with a merge-result wait tag.
#            An explicit --expect follows the park owner's threshold policy;
#            omission preserves legacy parking for already-issued worker briefs.
#            --requested and --open-ended retain the park owner's meanings.
#            Policy validation precedes queue submission and source arming.
#            Both adopt this watch and record the incarnation, without a
#            second resume watch. A refused queue handoff
#            arms and appends nothing.
#            --priority forwards two argv words before the queue's positionals;
#            pipeline is the queue's supported value. Other values are forwarded
#            unchanged for the queue to refuse. Priority refusals preserve the
#            queue's stderr and exit status, with no fallback to normal handoff.
#            An unknown-option refusal means the installed handoff.sh must be
#            republished by a queue install supporting priority.
#            --priority=value is not accepted. --test-only is refused here:
#            this adapter waits for landing results, not rehearsal results.
# submit     Internal fm-park.sh seam: submit [--priority <value>]
#            <task> <branch> <head> <note> [<resume-note>].
#            Called only after the park owner validates the entire wait policy;
#            runs handoff.sh and arms the source, without another policy check.
# arm        Register the watch for one handed-over head (idempotent). Use it
#            to re-arm after an `error` outcome or when a head was handed over
#            by hand. The source id is merge-queue-<task-id>-<head8>, so a new
#            head for the same task gets its own watch.
# result     Print the head's final RESULT line, or nothing while it is still
#            pending. Exit 2 when the queue cannot be read.
# result-ready  Exit 0 for a final result, 1 pending, 2 unreadable. The
#            configured declared-wait checker and park condition reuse this read.
# source-id  Print the canonical source id.
# classify   Print the captured outcome class: landed-clean, landed-unproven,
#            culprit, conflict, precheck-unavailable, superseded, dropped,
#            unexpected, stall, error, or unknown (malformed capture).
# pending-result <task> <head>
#            Internal conversion preflight: print the first pending non-stall
#            capture for this owner, empty on none; malformed captures refuse.
# settle     Apply one captured outcome (see below). Exit 0 when fully handled
#            here, 1 when the home's firstmate still has to act on it.
#            Uses fm-procevent-lib.sh's outer task transition lock, shared with
#            park conversion. Reads live/parked state only under that lock.
#            Autohandle holds the lock through the handled acknowledgement and
#            rechecks it there, so competing handlers cannot duplicate delivery.
# retire     Stop a head's watch. Captured results are never touched.
# watch      The blocking child the generic runner executes; never run it in a
#            conversational turn. It emits one outcome document on stdout.
#            While pending it calls the park owner's expire-queue under the
#            shared transition lock; no additional listener is registered.
#            A failed expiry emits error for supervision, never a guessed park.
# terminal, self-announcing, autohandle
#            The generic runner's adapter seams (bin/fm-procevent.sh header).
#            Every outcome but `stall` ends the watch. The adapter is
#            self-announcing: every outcome settle fully handles is announced
#            by the status or parent-channel line settle writes, so the runner
#            publishes a firstmate wake only for what settle leaves unhandled.
#
# What settle does, per outcome:
#   landed-clean     outcome=landed with files=N identical=N and no differ or
#                    dropped file. Records the per-file counts and evidence
#                    path in the task's note before guarded bin/fm-teardown.sh,
#                    whose own landed-sync refreshes this home's and the main
#                    home's project clone once its locks are released. Only
#                    when cleanup refuses (and so never reached that refresh)
#                    does settle refresh them itself through
#                    bin/fm-landed-sync.sh, after reporting the refusal. Before cleanup it appends
#                      done: landed <main40> on <branch> through the merge queue (...)
#                    so cleanup can read the completion and close the backlog.
#                    Only after successful cleanup does the glue publish its
#                    landed parent-channel line; it never recreates task.status.
#                    The existing task body is preserved.
#                    A refused note update stops before cleanup. A teardown refusal is never
#                    bypassed: settle appends a keyed blocked line naming why,
#                    publishes it upward, and leaves the wake for firstmate.
#   landed-unproven  outcome=landed with any differ or dropped file, or without
#                    the per-file fields. Nothing is cleaned up. A secondmate
#                    home posts one keyed needs-decision line on its parent
#                    channel naming the files; a main home leaves the wake.
#   culprit, conflict
#                    Relaunches the worker in its existing copy through
#                    bin/fm-control.sh relaunch with the RESULT line and the
#                    stored resume note, or sends that note durably to the
#                    adopted live waiter without a relaunch. Live delivery relies
#                    on the durable ordinary inbox plus its watcher doorbell and
#                    unread-message escalation ladder (fm-task-inbox-lib.sh), not
#                    fire-and-forget delivery. Declared waits never mute that ladder.
#                    A successful parked
#                    resume is counted through fm-park-churn.sh's token-dedup
#                    owner; failed launches and live results do not count.
#                    A refused delivery or relaunch leaves the wake.
#   precheck-unavailable
#                    The train could not complete the head's precheck (for
#                    example its run budget ran out): final, nothing landed, and
#                    no code verdict. Relaunches the worker like a culprit, with
#                    a note saying execution was unavailable rather than red and
#                    asking it to diagnose and hand over a new head, since the
#                    train never retries this one. A refused relaunch leaves the
#                    wake.
#   superseded       outcome=dropped with exact note "superseded by <sha8|sha40>": silent.
#   dropped          Any other dropped: appends `failed:` to the task status,
#                    which a secondmate home's ledger delivery publishes upward.
#   unexpected       Any nonempty RESULT outcome except taken that this
#                    adapter does not recognize: ends the wait, reports the raw
#                    outcome on the parent channel, cleans and relaunches nothing.
#                    A main home leaves the wake for firstmate.
#   stall            A queue STALL line written after this head's HANDOFF.
#                    A secondmate home posts one parent-channel note per STALL
#                    line (the first watch in the home to see it claims it); a
#                    main home leaves the wake. The watch keeps going.
#   error            The queue could not be read for FM_MERGE_QUEUE_ERROR_BUDGET
#                    consecutive polls (default 5): the watch stops and wakes
#                    firstmate, which fixes the cause and re-arms.
#
# Configuration: config/merge-queue (LOCAL, gitignored, not inherited), one
# key=value per line; docs/configuration.md "Merge queue" owns the schema.
#   dir=<queue directory>   holds queue.log and handoff.sh, and result.sh when
#                           the train provides it (FM_MERGE_QUEUE_DIR overrides)
#   home=<name>             this home's name in HANDOFF lines (default: the
#                           secondmate id, else "main")
#   interval=<secs>         poll cadence (default 60; FM_MERGE_QUEUE_INTERVAL)
#
# Queue reads. The train's read helper `result.sh <head40>` is used when it is
# executable in the queue directory, under fm-timeout-lib.sh's five-second
# bound (timeout is unreadable); otherwise queue.log is parsed for the
# last final RESULT naming the head. STALL lines are always read from queue.log.
# The home=, task=, and evidence= RESULT fields are used when present and
# tolerated when absent: the task comes from the watch itself, and a missing
# evidence= falls back to an "evidence <path>" phrase in the note.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SELF="$SCRIPT_DIR/fm-procevent-merge-queue.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ADAPTER=merge-queue
MQ_STATE="$STATE/merge-queue"
# The lifecycle owners settle delegates to; overridable only so tests can
# observe the calls without a live worker.
TEARDOWN_BIN=${FM_MERGE_QUEUE_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}
CONTROL_BIN=${FM_MERGE_QUEUE_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
FLEET_SYNC_BIN=${FM_MERGE_QUEUE_FLEET_SYNC_BIN:-$SCRIPT_DIR/fm-landed-sync.sh}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

head_valid() { [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]; }

task_valid() {
  fm_task_id_path_safe "${1-}" || return 1
  fm_procevent_source_id_valid "$ADAPTER-$1-12345678"
}

source_id_for() { printf '%s-%s-%s\n' "$ADAPTER" "$1" "${2:0:8}"; }

# --- configuration -------------------------------------------------------------

config_value() {  # <key>
  local file="$CONFIG/merge-queue"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  sed -n "s/^$1=//p" "$file" | tail -1
}

queue_dir() {
  local dir=${FM_MERGE_QUEUE_DIR:-}
  [ -n "$dir" ] || dir=$(config_value dir) || dir=
  # shellcheck disable=SC2088 # Matching a literal leading tilde to expand it.
  case "$dir" in "~/"*) dir=$HOME/${dir#"~/"} ;; esac
  [ -n "$dir" ] || return 1
  printf '%s\n' "$dir"
}

home_name() {
  local name
  name=$(config_value home) || name=
  [ -n "$name" ] || name=$(fm_parent_channel_home_id "$FM_HOME" 2>/dev/null) || name=
  printf '%s\n' "${name:-main}"
}

poll_interval() {
  local n=${FM_MERGE_QUEUE_INTERVAL:-}
  [ -n "$n" ] || n=$(config_value interval) || n=
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || n=60
  printf '%s\n' "$n"
}

# --- queue reads ---------------------------------------------------------------

# The field <name>= of a queue line, from the part before its free-text note.
line_field() {  # <line> <name>
  local fields=${1%% note=*} word
  for word in $fields; do
    case "$word" in "$2="*) printf '%s\n' "${word#"$2"=}"; return 0 ;; esac
  done
  return 1
}

line_note() {  # <line>
  case "$1" in *" note="*) printf '%s\n' "${1#* note=}" ;; esac
}

is_final_result() {  # <line> <head>
  case "$1" in "RESULT "*) ;; *) return 1 ;; esac
  [ "$(line_field "$1" head)" = "$2" ] || return 1
  case "$(line_field "$1" outcome)" in ''|taken) return 1 ;; *) return 0 ;; esac
}

# Print the final RESULT line for <head>, or nothing while pending. Exit 2 when
# the queue cannot be read.
queue_result() {  # <head>
  local head=$1 dir out rc line
  dir=$(queue_dir) || return 2
  if [ -x "$dir/result.sh" ] && [ ! -d "$dir/result.sh" ]; then
    out=$(fm_run_timed 5 "$dir/result.sh" "$head" 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || return 2
    line=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
    [ -n "$line" ] || return 0
    if [[ "$line" = "RESULT "* ]] && [ "$(line_field "$line" head)" = "$head" ] \
      && [ "$(line_field "$line" outcome)" = taken ]; then
      return 0
    fi
    is_final_result "$line" "$head" || return 2
    printf '%s\n' "$line"
    return 0
  fi
  [ -f "$dir/queue.log" ] && [ -r "$dir/queue.log" ] || return 2
  line=$(grep -E "^RESULT [^ ]+ head=$head outcome=[^ ]+" \
    "$dir/queue.log" 2>/dev/null | grep -vE ' outcome=taken( |$)' | tail -1)
  [ -n "$line" ] || return 0
  printf '%s\n' "$line"
}

# Print the first STALL line written after <head>'s last HANDOFF that no watch
# in this home has reported yet, claiming it; nothing when there is none.
queue_new_stall() {  # <head>
  local head=$1 dir log from line key
  dir=$(queue_dir) || return 2
  log="$dir/queue.log"
  [ -f "$log" ] && [ -r "$log" ] || return 2
  from=$(grep -nE "^HANDOFF .* head=$head( |$)" "$log" 2>/dev/null | tail -1 | cut -d: -f1)
  [ -n "$from" ] || return 0
  (umask 077; mkdir -p "$MQ_STATE/stalls") || return 2
  while IFS= read -r line; do
    key=$(printf '%s' "$line" | fm_pr_sha256 /dev/stdin) || key=
    [ -n "$key" ] || key=$(printf '%s' "$line" | cksum | tr ' ' -)
    if mkdir "$MQ_STATE/stalls/$key" 2>/dev/null; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(tail -n "+$((from + 1))" "$log" | grep '^STALL ')
  return 0
}

# --- outcome documents ---------------------------------------------------------

doc_value() {  # <file> <key>
  awk -v k="$2: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}

evidence_of() {  # <line>
  local ev
  ev=$(line_field "$1" evidence) && [ -n "$ev" ] && { printf '%s\n' "$ev"; return 0; }
  ev=$(line_note "$1" | grep -oE 'evidence [^ ;,]+' | head -1)
  [ -n "$ev" ] && printf '%s\n' "${ev#evidence }"
}

empty_list() { case "${1-}" in ''|-) return 0 ;; esac; return 1; }

outcome_class() {  # <file>
  local status line outcome files identical
  status=$(doc_value "$1" status)
  case "$status" in
    stall) printf 'stall\n'; return ;;
    error) printf 'error\n'; return ;;
    result) ;;
    *) printf 'unknown\n'; return ;;
  esac
  line=$(doc_value "$1" line)
  outcome=$(line_field "$line" outcome) || outcome=
  case "$outcome" in
    culprit|conflict|precheck-unavailable) printf '%s\n' "$outcome" ;;
    dropped)
      if [[ "$(line_note "$line")" =~ ^superseded\ by\ ([0-9a-f]{8}|[0-9a-f]{40})$ ]]; then
        printf 'superseded\n'
      else
        printf 'dropped\n'
      fi
      ;;
    landed)
      files=$(line_field "$line" files) || files=
      identical=$(line_field "$line" identical) || identical=
      if [[ "$files" =~ ^[0-9]+$ ]] && [ "$identical" = "$files" ] \
        && empty_list "$(line_field "$line" differ)" \
        && empty_list "$(line_field "$line" dropped)"; then
        printf 'landed-clean\n'
      else
        printf 'landed-unproven\n'
      fi
      ;;
    '') printf 'unknown\n' ;;
    *) printf 'unexpected\n' ;;
  esac
}

# --- status and parent-channel lines ------------------------------------------

append_status() {  # <task> <line>
  local file="$STATE/$1.status"
  status_stamp_line "$2" >/dev/null || return 1
  printf '%s\n' "$(status_stamp_line "$2")" >> "$file" || return 1
  if [ -e "$CONFIG/fleet-ledger" ]; then
    FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
      "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$file" >/dev/null 2>&1 || true
  fi
}

# Publish on the parent channel. 0 published, 1 main home (nothing to publish),
# other codes as bin/fm-parent-channel-lib.sh documents.
parent_report() {  # <line>
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1"
}

meta_value() {  # <task> <key>
  grep "^$2=" "$STATE/$1.meta" 2>/dev/null | tail -1 | cut -d= -f2-
}

default_branch_of() {  # <repo>
  local ref
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=
  ref=${ref#origin/}
  printf '%s\n' "${ref:-main}"
}

# --- commands ------------------------------------------------------------------

cmd_source_id() {
  task_valid "${1-}" || die "task id must be path-safe and short enough for a source id: ${1-}"
  head_valid "${2-}" || die "head must be a full 40-hex sha"
  source_id_for "$1" "$2"
}

cmd_arm() {
  local task=${1-} head=${2-} sid
  sid=$(cmd_source_id "$task" "$head") || exit 1
  [ -f "$STATE/$task.meta" ] || die "no task record for $task in this home"
  queue_dir >/dev/null || die "no merge queue is configured: set dir= in $CONFIG/merge-queue"
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$sid" -- "$SELF" watch "$task" "$head" >/dev/null \
    || die "cannot register the watch $sid"
  printf 'armed: %s\n' "$sid"
}

cmd_submit() {
  local priority='' priority_set=0 queue_rc
  if [ "${1-}" = --priority ]; then
    [ "$#" -ge 2 ] || die "--priority needs a value"
    priority=$2; priority_set=1; shift 2
  fi
  local task=${1-} branch=${2-} head=${3-} note=${4-} dir home
  cmd_source_id "$task" "$head" >/dev/null || return 1
  [ -n "$branch" ] && [ -n "$note" ] || die "queue submission needs a branch and note"
  dir=$(queue_dir) || die "no merge queue is configured"
  home=$(home_name)
  if [ "$priority_set" -eq 1 ]; then
    "$dir/handoff.sh" --priority "$priority" "$home" "$task" "$branch" "$head" "$note"
    queue_rc=$?
    if [ "$queue_rc" -ne 0 ]; then
      printf '%s\n' 'error: the queue refused the priority handoff; nothing was armed. If it rejected the option as unknown, its installed handoff.sh needs republishing by a priority-capable queue install; no normal-handoff fallback was attempted.' >&2
      return "$queue_rc"
    fi
  else
    "$dir/handoff.sh" "$home" "$task" "$branch" "$head" "$note" || die "the queue refused the handoff; nothing was armed"
  fi
  if [ "$#" -ge 5 ]; then
    (umask 077; mkdir -p "$MQ_STATE") || die "cannot create $MQ_STATE"
    printf '%s\n' "$5" > "$MQ_STATE/$task.resume" || die "cannot store the resume note"
  fi
  ( cmd_arm "$task" "$head" ) || die "handed $head to the queue but could not arm its watch; run: $SELF arm $task $head"
}

cmd_handoff() {
  local task=${1-} branch=${2-} head=${3-} resume='' resume_set=0 dir note tmp sid
  local -a park_args=()
  [ "$#" -ge 3 ] || usage
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect) [ "$#" -ge 2 ] || die "--expect needs a UTC time or +seconds"; park_args+=(--expect "$2"); shift 2 ;;
      --requested|--open-ended) park_args+=("$1"); shift ;;
      --priority) [ "$#" -ge 2 ] || die "--priority needs a value"; park_args+=(--queue-priority "$2"); shift 2 ;;
      --priority=*) die "use --priority <value>, not --priority=<value>" ;;
      --test-only) die "--test-only is not supported: this adapter waits for landing results; priority cannot be used for a rehearsal" ;;
      --resume-note) [ "$#" -ge 2 ] || die "--resume-note needs text"; resume=$2; resume_set=1; shift 2 ;;
      --resume-note-file)
        [ "$#" -ge 2 ] && [ -f "$2" ] || die "--resume-note-file needs a readable file"
        resume=$(cat "$2"); resume_set=1; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  note="$*"
  [ -n "$branch" ] || die "handoff needs a branch"
  [ -n "$note" ] || die "handoff needs a short note after --"
  cmd_source_id "$task" "$head" >/dev/null || exit 1
  [ -f "$STATE/$task.meta" ] || die "no task record for $task in this home (is FM_HOME set to the supervising home?)"
  dir=$(queue_dir) || die "no merge queue is configured: set dir= in $CONFIG/merge-queue"
  [ -x "$dir/handoff.sh" ] || die "the queue has no executable handoff.sh: $dir"
  [ "$resume_set" != 1 ] || park_args+=(--queue-resume-note "$resume")
  sid=$(source_id_for "$task" "$head")
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-queue-handoff.XXXXXX") || die "cannot write park handoff"
  {
    printf '## Goal\nFinish the queued task %s.\n## Done\nHanded %s to the merge queue.\n' "$task" "$head"
    # shellcheck disable=SC2016 # Markdown code span, not shell substitution.
    printf '## Waiting for\n`cmd:%s result-ready %s`\n' "$SELF" "$head"
    printf '## Next steps\nThe queue source %s owns settlement; on conflict, culprit or precheck-unavailable follow the RESULT and resume note.\n' "$sid"
    [ "$resume_set" -eq 0 ] || printf '%s\n' "$resume"
  } > "$tmp"
  FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-park.sh" "$task" --handoff "$tmp" --adopt-merge-queue "$head" \
    --submit-merge-queue "$branch" "$note" ${park_args[@]+"${park_args[@]}"}
  local rc=$?
  rm -f -- "$tmp"
  if [ "$rc" -ne 0 ]; then
    printf 'error: queue handoff/wait failed for %s; see the refusal above\n' "$task" >&2
    return 1
  fi
  printf 'handed: %s %s\n' "$task" "$head"
}

cmd_result() {
  head_valid "${1-}" || die "head must be a full 40-hex sha"
  queue_result "$1"
}

cmd_result_ready() {
  local line rc
  line=$(cmd_result "$@"); rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$line" ]
}

emit() {  # <sid> <task> <head> <status> <detail> [<line>]
  printf 'merge-queue: %s\n' "$1"
  printf 'task: %s\n' "$2"
  printf 'head: %s\n' "$3"
  printf 'status: %s\n' "$4"
  printf 'detail: %s\n' "$5"
  [ -z "${6-}" ] || printf 'line: %s\n' "$6"
}

cmd_watch() {
  local task=${1-} head=${2-} sid interval budget errors=0 line rc expiry_out
  sid=$(cmd_source_id "$task" "$head") || exit 1
  interval=$(poll_interval)
  budget=${FM_MERGE_QUEUE_ERROR_BUDGET:-5}
  case "$budget" in ''|*[!0-9]*|0) budget=5 ;; esac
  while :; do
    line=$(queue_result "$head"); rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
      emit "$sid" "$task" "$head" result "final result for $head" "$line"
      exit 0
    fi
    if [ "$rc" -eq 0 ]; then
      if ! expiry_out=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-park.sh" expire-queue "$task" "$head" 2>&1); then
        emit "$sid" "$task" "$head" error "queue live-wait expiry failed: ${expiry_out//$'\n'/ }; reconcile and re-arm $sid"
        exit 0
      fi
      line=$(queue_new_stall "$head"); rc=$?
      if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
        emit "$sid" "$task" "$head" stall "the merge queue reported a stall" "$line"
        exit 0
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      errors=0
    else
      errors=$((errors + 1))
      if [ "$errors" -ge "$budget" ]; then
        emit "$sid" "$task" "$head" error "the merge queue at $(queue_dir 2>/dev/null || printf 'an unconfigured location') could not be read for $errors polls; fix it and re-arm with: $SELF arm $task $head"
        exit 0
      fi
    fi
    sleep "$interval"
  done
}

cmd_classify() {
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  outcome_class "$1"
}

cmd_terminal() {
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  case "$(outcome_class "$1")" in stall|unknown) return 1 ;; esac
  return 0
}

relaunch_note() {  # <line> <head> <task>
  printf 'The merge queue returned %s for the head you handed over, %s:\n%s\n\n' \
    "$(line_field "$1" outcome)" "$2" "$1"
  printf 'Your resume note from the handoff:\n'
  if [ -f "$MQ_STATE/$3.resume" ]; then cat "$MQ_STATE/$3.resume"; else printf '(none recorded)\n'; fi
  if [ "$(line_field "$1" outcome)" = precheck-unavailable ]; then
    printf '\nThe queue could not complete the precheck for that head, so execution was unavailable: this is not a code verdict, and the queue will not retry that head.\n'
    printf 'Diagnose why the precheck could not run (the note names its receipt and diagnostics), fix or rebase in this copy, re-run the gate, push a new head to your branch, and hand it over with:\n'
  else
    printf '\nFix what the result names in this copy, re-run the gate, push a new head to your branch, and hand it over again with:\n'
  fi
  printf "  FM_HOME='%s' '%s' handoff %s <branch> <new-head40> --expect <UTC|+seconds> [--priority <value>] [--resume-note <text>] -- <note>\n" "$FM_HOME" "$SELF" "$3"
  printf 'then end the turn; the adapter owns the live or parked result wait.\n'
}

# Append the per-file receipt to the existing task body before cleanup can
# close/archive it. Read through the backlog owner and decode its TOON body
# field, which is JSON-quoted when the value needs escaping.
record_landing_note() {  # <task> <receipt>
  local task=$1 receipt=$2 shown body tmp rc
  shown=$(FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-tasks-axi.sh" show "$task" --full) || return 1
  body=$(printf '%s\n' "$shown" | sed -n 's/^  body: //p' | head -1 \
    | LC_ALL=C perl -MJSON::PP -e '
      local $/;
      my $shown = <STDIN>;
      $shown =~ s/\s+\z//;
      exit 0 if $shown eq "" || $shown eq "-";
      my $value = $shown =~ /\A"/
        ? JSON::PP->new->utf8->allow_nonref->decode($shown) : $shown;
      binmode STDOUT, ":raw";
      utf8::encode($value) if utf8::is_utf8($value);
      print $value;
    ') || return 1
  case $'\n'"$body"$'\n' in *$'\n'"$receipt"$'\n'*) return 0 ;; esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-merge-queue-body.XXXXXX") || return 1
  { [ -z "$body" ] || printf '%s\n\n' "$body"; printf '%s\n' "$receipt"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-tasks-axi.sh" update "$task" --body-file "$tmp" >/dev/null
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

settle_landed_clean() {  # <task> <head> <line>
  local task=$1 head=$2 line=$3 main files evidence project branch check out rc reason landed
  main=$(line_field "$line" main) || main=
  files=$(line_field "$line" files)
  evidence=$(evidence_of "$line") || evidence=
  check="per-file check files=$files identical=$files, evidence ${evidence:-not recorded}"
  if ! record_landing_note "$task" "merge queue: landed $main; $check"; then
    append_status "$task" "blocked [key=merge-queue-note]: head $head landed on main at $main but the per-file receipt could not be recorded; cleanup was not attempted" || true
    parent_report "blocked [key=merge-queue-note-$task]: task $task head $head landed on main at $main but the per-file receipt could not be recorded; cleanup was not attempted" || true
    return 1
  fi
  project=$(meta_value "$task" project)
  branch=main
  # No clone refresh before cleanup: its own landed-sync refreshes the clone
  # after it releases the project lock, so a refresh here would fetch twice.
  if [ -n "$project" ] && [ -d "$project" ]; then
    branch=$(default_branch_of "$project")
  fi
  landed="landed $main on $branch through the merge queue (head ${head:0:8}; $check)"
  append_status "$task" "done: $landed" || return 1
  out=$(FM_HOME=$FM_HOME "$TEARDOWN_BIN" "$task" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(printf '%s\n' "$out" | grep -m1 -iE 'refus|error' || printf '%s\n' "$out" | tail -1)
    reason=$(fm_parent_channel_clean_note "$reason")
    append_status "$task" "blocked [key=merge-queue-cleanup]: head $head landed on main at $main but cleanup refused: $reason" || true
    parent_report "blocked [key=merge-queue-cleanup-$task]: task $task head $head landed on main at $main but cleanup refused: $reason" || true
    printf 'cleanup refused for %s: %s\n' "$task" "$reason" >&2
    # The refusal stopped cleanup before its refresh, so the landed clone is
    # refreshed here instead.
    if [ -n "$project" ] && [ -d "$project" ]; then
      FM_HOME=$FM_HOME "$FLEET_SYNC_BIN" "$project" >/dev/null 2>&1 \
        || printf 'warning: could not refresh the project clone %s\n' "$project" >&2
    fi
    return 1
  fi
  parent_report "done [key=merge-queue-landed-$task-${head:0:8}]: task $task $landed"; rc=$?
  # Main homes have no parent channel; all other delivery failures stay pending.
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
}

settle_landed_unproven() {  # <task> <head> <line>
  local line=$3 differ dropped rc=0
  differ=$(line_field "$line" differ) || differ='(not reported)'
  dropped=$(line_field "$line" dropped) || dropped='(not reported)'
  parent_report "needs-decision [key=merge-queue-$1-${2:0:8}]: task $1 landed on $(line_field "$line" main | cut -c1-8) through the merge queue, but not every file is proven on main (files=$(line_field "$line" files || printf '?') identical=$(line_field "$line" identical || printf '?') differ=$differ dropped=$dropped, evidence $(evidence_of "$line" || printf 'not recorded')); nothing was cleaned up - decide whether to clean up or follow up" \
    || rc=$?
  [ "$rc" -eq 0 ]
}

cmd_settle() {
  [ -f "${1-}" ] || die "result file does not exist: ${1-}"
  fm_procevent_task_transition "$STATE" "$(doc_value "$1" task)" settle cmd_settle_locked "$@"
}

cmd_settle_locked() {
  local file=${1-} task head sid token='' rc=0 note
  task=$(doc_value "$file" task); head=$(doc_value "$file" head)
  sid=$(cmd_source_id "$task" "$head") || return 1
  if [ "$(meta_value "$task" park_state)" = live ] &&
     [ "$(meta_value "$task" park_source)" = "$sid" ] &&
     [ "$(meta_value "$task" park_spawn_gen)" = "$(meta_value "$task" spawn_gen)" ]; then
    token=$(meta_value "$task" park_token)
  fi
  cmd_apply_result_locked "$file" || return $?
  # Every successfully applied terminal outcome retires its live wait, not
  # just outcomes delivered back to the worker. Pending/error results keep it
  # for reconciliation; cleanup may already have removed the whole task record.
  if [ -n "$token" ] && [ "$(meta_value "$task" park_state)" = live ] && cmd_terminal "$file"; then
    FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-park.sh" complete-live-queue "$task" "$token" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
      note="queue result $head was applied for $task but live-wait completion failed; inspect $STATE/$task.meta; do not repeat the result action"
      printf 'warning: %s\n' "$note" >&2
      fm_wake_append check "merge-queue-status-$task-${head:0:8}" "check: $note" \
        || printf 'warning: applied queue result completion failure could not be queued for supervision\n' >&2
    fi
  fi
  return 0
}

cmd_apply_result_locked() {
  local file=${1-} class task head line sid note tmp rc token park_gen
  [ -f "$file" ] || die "result file does not exist: $file"
  cd / || true
  task=$(doc_value "$file" task)
  head=$(doc_value "$file" head)
  line=$(doc_value "$file" line)
  sid=$(cmd_source_id "$task" "$head") || return 1
  [ "$(doc_value "$file" merge-queue)" = "$sid" ] || die "result does not match its own task and head"
  class=$(outcome_class "$file")
  case "$class" in
    landed-clean) settle_landed_clean "$task" "$head" "$line" ;;
    landed-unproven) settle_landed_unproven "$task" "$head" "$line" ;;
    culprit|conflict|precheck-unavailable)
      tmp=$(mktemp "${TMPDIR:-/tmp}/fm-merge-queue-note.XXXXXX") || return 1
      relaunch_note "$line" "$head" "$task" > "$tmp"
      if [ "$(meta_value "$task" park_state)" = live ]; then
        token=$(meta_value "$task" park_token)
        if [ -z "$token" ] || [ "$(meta_value "$task" park_source)" != "$sid" ] ||
           [ "$(meta_value "$task" park_spawn_gen)" != "$(meta_value "$task" spawn_gen)" ]; then
          rm -f "$tmp"
          printf 'live queue wait for %s was superseded; result needs reconciliation\n' "$task" >&2
          return 1
        fi
        FM_HOME=$FM_HOME "${FM_MERGE_QUEUE_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}" "$task" --no-resume \
          "$(cat "$tmp")" >/dev/null
        rc=$?
        rm -f "$tmp"
        [ "$rc" -eq 0 ] || return 1
        rc=0
        FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-park.sh" complete-live-queue "$task" "$token" || rc=$?
        [ "$rc" -ne 3 ] || return 0 # The worker already declared newer work.
        append_status "$task" "working: merge queue returned $class for $head; result delivered to the live worker" || rc=1
        if [ "$rc" -ne 0 ]; then
          note="queue result $head was delivered to live task $task but its wait completion or status recording failed; inspect $STATE/$task.meta and $STATE/$task.status; do not resend"
          printf 'warning: %s\n' "$note" >&2
          fm_wake_append check "merge-queue-status-$task-${head:0:8}" "check: $note" \
            || printf 'warning: the delivered queue result status failure could not be queued for supervision\n' >&2
        fi
        # Delivery is the commit point; secondary notice failures never resend.
        return 0
      else
        token=; park_gen=
        if [ "$(meta_value "$task" park_state)" = parked ] && [ "$(meta_value "$task" park_source)" = "$sid" ] &&
           [ "$(meta_value "$task" park_spawn_gen)" = "$(meta_value "$task" spawn_gen)" ]; then
          token=$(meta_value "$task" park_token)
          park_gen=$(meta_value "$task" park_spawn_gen)
        fi
        FM_HOME=$FM_HOME "$CONTROL_BIN" "$task" relaunch --note-file "$tmp" >/dev/null 2>&1
        rc=$?
        rm -f "$tmp"
        [ "$rc" -eq 0 ] || { printf 'relaunch of %s was refused\n' "$task" >&2; return 1; }
        # Confirmed relaunch ends this adopted park, never a newer incarnation.
        # Completion is bookkeeping: a failure alarms, never retries the launch.
        if [ -n "$token" ]; then
          rc=0
          FM_HOME=$FM_HOME "$SCRIPT_DIR/fm-park.sh" complete-resumed-queue "$task" "$token" "$park_gen" "$sid" || rc=$?
          if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
            note="queue result $head relaunched task $task but adopted-park retirement failed; inspect $STATE/$task.meta; do not relaunch again"
            printf 'warning: %s\n' "$note" >&2
            fm_wake_append check "merge-queue-status-$task-${head:0:8}" "check: $note" \
              || printf 'warning: confirmed queue resume retirement failure could not be queued for supervision\n' >&2
          fi
        fi
        if [ -n "$token" ]; then
          "$SCRIPT_DIR/fm-park-churn.sh" record "$task" '' "$token" >/dev/null \
            || printf 'warning: task %s resumed, but its resume could not be counted for the churn alarm; settlement will not repeat the successful launch\n' "$task" >&2
        fi
      fi
      ;;
    superseded) return 0 ;;
    dropped)
      note=$(fm_parent_channel_clean_note "$(line_note "$line")")
      append_status "$task" "failed: the merge queue dropped head ${head:0:8}: ${note:-no reason given}" || return 1
      FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-inactive-reconcile.sh" report "$task"
      ;;
    unexpected)
      parent_report "blocked [key=merge-queue-unexpected-$task-${head:0:8}]: task $task head $head received unexpected merge queue RESULT outcome=$(line_field "$line" outcome); nothing was cleaned up or relaunched"
      ;;
    stall)
      parent_report "note [key=merge-queue-stall]: the merge queue is stalled ($(fm_parent_channel_clean_note "${line#STALL }")); task $task is waiting on head ${head:0:8}"
      ;;
    *) return 1 ;;
  esac
}

cmd_autohandle() {
  [ -f "${3-}" ] || die "result file does not exist: ${3-}"
  fm_procevent_task_transition "$STATE" "$(doc_value "$3" task)" settle cmd_autohandle_locked "$@"
}

cmd_autohandle_locked() {
  local sid=${1-} seq=${2-} file=${3-}
  [ -n "$sid" ] && [ -n "$seq" ] && [ -f "$file" ] || usage
  [ "$sid" = "$(doc_value "$file" merge-queue)" ] &&
    [ "$file" = "$(fm_procevent_inbox_dir "$STATE")/$sid.$seq.result" ] || die "capture identity does not match acknowledgement"
  fm_procevent_is_handled "$STATE" "$sid" "$seq" && return 0
  cmd_settle_locked "$file" || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null
}

# Read captured outcomes using the generic inbox owner. A terminal capture may
# have retired its registration before settlement; it still owns the result.
cmd_pending_result() {
  local task=${1-} head=${2-} sid pending result base
  sid=$(cmd_source_id "$task" "$head") || return 1
  pending=$(fm_procevent_pending "$STATE") || return 1
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    base=${result%.result}; base=${base%.*}
    [ "$base" = "$(fm_procevent_inbox_dir "$STATE")/$sid" ] || continue
    [ "$(doc_value "$result" merge-queue)" = "$sid" ] &&
      [ "$(doc_value "$result" task)" = "$task" ] && [ "$(doc_value "$result" head)" = "$head" ] \
      || die "captured queue result has inconsistent ownership: $result"
    case "$(outcome_class "$result")" in
      stall) continue ;;
      unknown) die "captured queue result is unreadable or unrecognized: $result" ;;
      *) printf '%s\n' "$result"; return 0 ;;
    esac
  done <<< "$pending"
}

cmd_retire() {
  local sid
  sid=$(cmd_source_id "${1-}" "${2-}") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid"
}

case "${1-}" in
  handoff)         shift; cmd_handoff "$@" ;;
  submit)          shift; cmd_submit "$@" ;;
  arm)             shift; cmd_arm "$@" ;;
  result)          shift; cmd_result "$@" ;;
  result-ready)    shift; cmd_result_ready "$@" ;;
  pending-result)  shift; cmd_pending_result "$@" ;;
  source-id)       shift; cmd_source_id "$@" ;;
  classify)        shift; cmd_classify "$@" ;;
  settle)          shift; cmd_settle "$@" ;;
  retire)          shift; cmd_retire "$@" ;;
  watch)           shift; cmd_watch "$@" ;;
  terminal)        shift; cmd_terminal "$@" ;;
  self-announcing) exit 0 ;;
  autohandle)      shift; cmd_autohandle "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
