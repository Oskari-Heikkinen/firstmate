#!/usr/bin/env bash
# fm-park.sh - park a ship or scout task that only waits on an external result,
# so no idle agent session is held open for it, and relaunch it as a fresh
# session automatically when the result arrives.
#
# Usage:
#   fm-park.sh <task-id> --handoff <file> [--when <condition>] [--deadline <iso>]
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
#           It never tears down, discards, or touches the worktree or branch:
#           the local copy and every uncommitted change stay exactly as they
#           were. Idempotent: parking an already-parked task retires the old
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
#           stopped; its output goes to data/<id>/park-exit.log. A failed exit
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
#           On failure the record reads park_state=resume-failed, everything
#           else is left intact, and the nonzero exit becomes the watch's
#           action-failed outcome, which wakes the supervisor. When the task was
#           relaunched or respawned since it parked (its spawn_gen changed), the
#           live session is left alone: nothing is relaunched, the park fields
#           are cleared, and the nonzero exit wakes the supervisor with that
#           reason; the watch fires once, so it is already spent.
# cancel    Retire the watch and mark the record park_state=cancelled, without
#           relaunching anything.
# stop      The detached exit of a self-park: after FM_PARK_SELF_EXIT_DELAY
#           seconds (3) stop the agent through `bin/fm-control.sh <id> exit`; if
#           that fails, append a blocked: status line naming park-exit.log so the
#           supervisor is woken rather than an idle session holding memory.
#
# Conditions (one line, no shell interpretation):
#   file:<absolute-path>          true once the path exists (a fetched run, a results file)
#   pr-merged:<github-pr-url>     true once the PR is merged; closed unmerged is an error
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
#   park_at=<epoch>            when the latest park was recorded
#   park_spawn_gen=<token>     the task's spawn_gen when it parked
#   park_resumed_at=<epoch>    when the latest resume relaunched the task
#
# Environment knobs:
#   FM_PARK_INTERVAL       condition poll cadence in seconds (300)
#   FM_PARK_STABLE         consecutive true polls required (2)
#   FM_PARK_ERROR_BUDGET   consecutive condition errors before waking (5)
#   FM_PARK_DEADLINE_SECS  default deadline from now (604800)
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
      case "$line" in
        park_*=*)
          [ "$#" -gt 0 ] || continue
          case "$keys" in *" ${line%%=*} "*) continue ;; esac
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
        if (match(lines[i], /`(file|pr-merged|cmd):[^`]*`/)) {
          print substr(lines[i], RSTART + 1, RLENGTH - 2); exit
        }
      for (i = 1; i <= NR; i++)
        if (match(lines[i], /(^|[ \t])(file|pr-merged|cmd):/)) {
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
  local handoff='' want='' deadline_iso='' deadline_epoch now rel dest wt here detached=0 detach out
  task_resolve "${1-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --handoff) handoff=${2-}; shift 2 || die "--handoff needs a file" ;;
      --when) want=${2-}; shift 2 || die "--when needs a condition" ;;
      --deadline) deadline_iso=${2-}; shift 2 || die "--deadline needs a UTC time" ;;
      *) die "unknown park argument: $1" ;;
    esac
  done
  [ -n "$handoff" ] || die "park needs --handoff <file> (sections: Goal, Done, Waiting for, Next steps)"
  validate_handoff "$handoff" "$want"
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
  ack_own_fired
  "$WHEN" retire "park-$ID" >/dev/null 2>&1 || true
  park_record "park_state=parked" "park_handoff=$dest" "park_when=$HANDOFF_CONDITION" \
    "park_deadline=$deadline_iso" "park_at=$now" "park_spawn_gen=$(meta_get spawn_gen)" \
    || die "cannot record the park in task $ID's record"
  if ! out=$("$WHEN" arm "park-$ID" \
      --interval "${FM_PARK_INTERVAL:-300}" --stable "${FM_PARK_STABLE:-2}" \
      --deadline "$rel" --error-budget "${FM_PARK_ERROR_BUDGET:-5}" --action-timeout 900 \
      --condition "$SCRIPT_DIR/fm-park.sh" check "$HANDOFF_CONDITION" \
      --action "$SCRIPT_DIR/fm-park.sh" resume "$ID" 2>&1); then
    park_record "park_state=cancelled" || true
    die "could not arm the resume watch, so task $ID was not parked and its agent keeps running: $out"
  fi
  status_append "$PAUSED_VERB: parked until $deadline_iso - waiting for $HANDOFF_CONDITION; relaunches automatically with $dest" \
    || die "task $ID is parked and its watch armed, but the status line could not be appended"

  [ "${FM_TASK_ID-}" != "$ID" ] || detached=1
  wt=$(meta_get worktree)
  here=$(pwd -P 2>/dev/null || true)
  if [ -n "$wt" ] && wt=$(cd "$wt" 2>/dev/null && pwd -P); then
    case "$here/" in "$wt"/*) detached=1 ;; esac
  fi
  if [ "$detached" -eq 1 ]; then
    # The worker is parking itself: stopping the agent would kill this very
    # command, so return first and let a detached exit stop the session.
    # A new session keeps the exit alive when the agent's own process group
    # is interrupted; nohup is the fallback where setsid is absent.
    if command -v setsid >/dev/null 2>&1; then detach="setsid"; else detach="nohup"; fi
    "$detach" "$SCRIPT_DIR/fm-park.sh" stop "$ID" > "$DATA/$ID/park-exit.log" 2>&1 < /dev/null &
    printf 'parked %s: waiting for %s until %s; this session stops in a few seconds and a fresh one starts with %s when the condition holds\n' \
      "$ID" "$HANDOFF_CONDITION" "$deadline_iso" "$dest"
    return 0
  fi
  if ! out=$("$CONTROL" "$ID" exit 2>&1); then
    printf 'fm-park: task %s is parked and its watch armed, but its agent could not be stopped: %s\n' "$ID" "$out" >&2
    exit 1
  fi
  printf 'parked %s: waiting for %s until %s; agent stopped (%s)\n' "$ID" "$HANDOFF_CONDITION" "$deadline_iso" "$out"
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
  local out
  task_resolve "${1-}"
  sleep "${FM_PARK_SELF_EXIT_DELAY:-3}"
  if ! out=$("$CONTROL" "$ID" exit 2>&1); then
    printf '%s\n' "$out"
    status_append "blocked: parked and its resume watch armed, but this session could not be stopped; see $DATA/$ID/park-exit.log" || true
    exit 1
  fi
  printf '%s\n' "$out"
}

# --- resume and cancel -------------------------------------------------------

cmd_resume() {
  local cond handoff note out
  task_resolve "${1-}"
  [ "$(meta_get park_state)" = parked ] \
    || die "task $ID is not parked (park_state=$(meta_get park_state)); nothing to resume"
  if [ "$(meta_get spawn_gen)" != "$(meta_get park_spawn_gen)" ]; then
    park_record || die "task $ID was relaunched or respawned since it parked, but its park record could not be cleared"
    printf 'fm-park: task %s was relaunched or respawned since it parked, so its live session was left running and the park cleared; nothing was relaunched\n' "$ID" >&2
    exit 1
  fi
  cond=$(meta_get park_when)
  handoff=$(meta_get park_handoff)
  note="$DATA/$ID/park-resume-note.md"
  {
    echo "This task was parked while it waited on an external result, and the wait is over: $(results_pointer "$cond")."
    echo "The condition was: $cond"
    echo "Read the handoff at $handoff first; it records the goal, what was already done, and the next steps."
    echo "Continue from its next steps. If you must wait on something external again, park again rather than idling."
  } > "$note" || die "cannot write the resume note for task $ID"
  if ! out=$("$CONTROL" "$ID" relaunch --note-file "$note" 2>&1); then
    park_record "park_state=resume-failed" || true
    printf 'fm-park: the condition held but task %s could not be relaunched; its record and local copy are unchanged: %s\n' "$ID" "$out" >&2
    exit 1
  fi
  park_record "park_state=resumed" "park_resumed_at=$(date +%s)" \
    || printf 'fm-park: task %s was relaunched but its park record could not be updated\n' "$ID" >&2
  status_append "working: resumed from park - $cond held; fresh session started from $handoff" || true
  printf 'resumed %s: %s\n' "$ID" "$out"
}

cmd_cancel() {
  task_resolve "${1-}"
  "$WHEN" retire "park-$ID" >/dev/null || die "could not retire the watch for task $ID"
  [ -z "$(meta_get park_state)" ] || park_record "park_state=cancelled" \
    || die "the watch is retired but task $ID's park record could not be updated"
  printf 'cancelled park of %s; nothing was relaunched\n' "$ID"
}

case "${1-}" in
  ''|-h|--help|help) usage; [ -n "${1-}" ] || exit 2 ;;
  validate) shift; cmd_validate "$@" ;;
  check) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_check "$1" ;;
  resume) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_resume "$1" ;;
  cancel) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_cancel "$1" ;;
  stop) shift; [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_stop "$1" ;;
  *) cmd_park "$@" ;;
esac
