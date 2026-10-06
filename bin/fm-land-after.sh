#!/usr/bin/env bash
# Dependency-ordered landings: hold a live waiting task behind a blocker task
# and send it one prepared rebase-and-continue steer once the blocker lands.
#
# Usage:
#   fm-land-after.sh register <waiting-task> --after <blocker-task> [--steer <text>]
#   fm-land-after.sh status <blocker-task>
#   fm-land-after.sh [--home <dir>] landed <blocker-task>
#   fm-land-after.sh [--home <dir>] deliver <blocker-task>
#
# register  The one command firstmate runs. It records the blocked-by edge in
#           this home's backlog (fm-tasks-axi.sh block, idempotent; both rows
#           must exist), records the steer text the waiting task will receive
#           (the default names the blocker and says to fetch, rebase onto the
#           default branch, re-run what the landing path requires, and continue
#           the landing), and arms one condition->action watch per blocker
#           through bin/fm-procevent-when.sh named "land-after-<blocker>":
#           condition `landed`, action `deliver`, both this script with an
#           explicit --home. Several waiting tasks may register behind one
#           blocker; they share its watch. Re-registering an unsent waiter
#           replaces its steer; a waiter already steered is refused. A provably
#           ended watch is retired and re-armed, with the outcome recorded in
#           watch-rearmed. An ambiguous or unreadable watch refuses registration
#           for supervisor handling instead of claiming to be armed. The waiting
#           task must be live (state/<id>.meta present). When the blocker's
#           steers were already delivered, register delivers the new waiter's
#           steer at once instead of arming again. Nothing blocks on the
#           condition; the watcher starts the watch on its next cycle. The
#           watch polls every FM_LAND_AFTER_INTERVAL seconds (default 30),
#           needs two consecutive landed polls, and gives up after 14 days.
# status    Print the blocker's recorded evidence and each waiter's delivery state.
# landed    The watch condition; never run it as a wait in a conversational turn.
#           Exit 0 when the blocker's landed commit is on the default branch,
#           1 while it is not yet (including an unreadable forge), and 3 when
#           the blocker failed or was cancelled or its landing can no longer be
#           verified - its latest done/failed status event is failed:, its
#           recorded PR closed unmerged, or its task record is gone with no
#           landed evidence observed. Exit 3 is a condition error, so the watch
#           ends with a condition-error outcome that wakes firstmate and steers
#           no one. Evidence, in order: a PR URL from the task record's pr= or,
#           once the record is gone, the backlog row's pr link, read on the
#           forge (merged is landed); else a direct-push `done: landed <sha> on
#           <branch>` line whose sha is the remote default tip or a proven
#           ancestor of that exact remote tip (missing objects are fetched into
#           a private bare evidence cache, never into the project or worker's
#           copy); else a local-only done task whose head is on the
#           project's default branch. The first positive verdict is written to
#           the blocker's private evidence record so a cleanup that removes the
#           task record before the next poll cannot lose it; a recorded verdict
#           answers every later poll.
# deliver   The watch action. Refuses unless landed evidence is recorded. For
#           each registered waiter, exactly once: a live task receives its
#           recorded steer through bin/fm-send.sh (inbox plane); a task no
#           longer live is recorded as skipped. A per-waiter claim is taken
#           with an exclusive create before sending and becomes the sent
#           marker after fm-send confirms the durable record, so a rerun never
#           steers twice; a failed send drops its claim so a rerun retries it,
#           and a claim left by a crash is reported for manual verification
#           rather than resent. Exit 0 when every waiter is sent or skipped,
#           1 otherwise, so a partial delivery reaches firstmate as the
#           watch's action-failed outcome; rerun deliver after fixing it.
#
# Records live under state/land-after/<blocker>/ and are written only by this
# script: <waiter>.steer, <waiter>.claim, <waiter>.sent, <waiter>.skipped, the
# landed evidence record, delivered marker, watch-result-cursor (the last result
# sequence before this watch was armed), watch-rearmed, and ancestry.git (bare
# object cache for direct-push evidence). The watch's own outcome
# handling and retirement belong to bin/fm-procevent-when.sh and the
# process-event-sources skill.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ "${1-}" = --home ]; then
  [ -n "${2-}" ] || { printf 'error: --home needs a directory\n' >&2; exit 2; }
  FM_HOME=$2
  shift 2
fi
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

LAND_DIR="$STATE/land-after"
LANDED_NOT_YET=1
LANDED_FAILED=3

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit "${1:-2}"; }

valid_id() { fm_task_id_path_safe "${1-}"; }
blocker_dir() { printf '%s/%s\n' "$LAND_DIR" "$1"; }
watch_name() { printf 'land-after-%s\n' "$1"; }

default_steer() {  # <blocker>
  printf 'Dependency landed: %s is now on the default branch. Fetch, rebase your branch onto the current default branch, re-run what your landing path requires, and continue your landing.\n' "$1"
}

ensure_dir() {  # <dir>
  (umask 077; mkdir -p "$1") || return 1
  [ -d "$1" ] && [ ! -L "$1" ]
}

write_atomic() {  # <dest> <content>
  local tmp
  tmp=$(umask 077; mktemp "$(dirname "$1")/.tmp.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$1" || { rm -f -- "$tmp"; return 1; }
}

LOCK_HELD=
lock_blocker() {  # <blocker>
  LOCK_HELD="$(blocker_dir "$1")/.lock"
  fm_lock_acquire_wait "$LOCK_HELD"
  trap 'fm_lock_release "$LOCK_HELD"' EXIT
}
unlock_blocker() {
  [ -n "$LOCK_HELD" ] || return 0
  fm_lock_release "$LOCK_HELD"
  LOCK_HELD=
  trap - EXIT
}

# --- landed ------------------------------------------------------------------

# Latest done: or failed: event in the status log, or nothing.
latest_outcome_line() {  # <status-file>
  local line verb found=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    verb=$(status_line_verb "$line")
    case "$verb" in done|failed) found=$line ;; esac
  done < "$1"
  printf '%s' "$found"
}

backlog_pr_link() {  # <blocker> -> pr URL from the backlog row, or nothing
  local out
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -n 's/^  links: *//p' | head -1 \
    | tr -d '"' | tr ', ' '\n' | sed -n 's/^pr://p' | head -1
}

# Forge verdict for a PR URL: 0 merged, 1 open or unreadable, 3 closed unmerged.
pr_verdict() {  # <url>
  fm_pr_url_parse "$1" || { printf 'recorded PR URL is not recognized: %s\n' "$1"; return "$LANDED_NOT_YET"; }
  case "$FM_PR_PROVIDER" in
    github) fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" ;;
    gitlab) fm_pr_gitlab_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" ;;
    *) false ;;
  esac || { printf 'forge read failed for %s; not landed yet\n' "$1"; return "$LANDED_NOT_YET"; }
  if [ "$FM_PR_RECORD_MERGED" = true ]; then
    printf 'PR %s merged\n' "$1"
    return 0
  fi
  case "$FM_PR_RECORD_STATE" in
    CLOSED|closed)
      printf 'PR %s was closed without merging\n' "$1"
      return "$LANDED_FAILED" ;;
  esac
  printf 'PR %s is %s\n' "$1" "$FM_PR_RECORD_STATE"
  return "$LANDED_NOT_YET"
}

direct_push_verdict() {  # <repo> <done-line> <blocker>
  local repo=$1 note sha remote branch tip cache origin
  note=$(status_line_note "$2")
  local LC_ALL=C
  if [[ "$note" =~ landed\ ([0-9a-f]{7,40})\ on\ ([A-Za-z0-9._/-]+) ]]; then
    sha=${BASH_REMATCH[1]}
  else
    printf 'no landed commit reported yet\n'
    return "$LANDED_NOT_YET"
  fi
  remote=$(git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null) \
    || { printf 'cannot read the remote default branch\n'; return "$LANDED_NOT_YET"; }
  branch=$(printf '%s\n' "$remote" | awk '$1 == "ref:" && $3 == "HEAD" {print $2}')
  tip=$(printf '%s\n' "$remote" | awk '$2 == "HEAD" && $1 != "ref:" {print $1}')
  [[ "$branch" == refs/heads/* && "$tip" =~ ^[0-9a-f]{40}$ ]] \
    || { printf 'cannot identify the remote default branch\n'; return "$LANDED_NOT_YET"; }
  case "$tip" in
    "$sha"*)
      [ -n "$tip" ] && { printf 'commit %s is the tip of %s\n' "$sha" "$branch"; return 0; } ;;
  esac
  if git -C "$repo" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
    printf 'commit %s is on %s\n' "$sha" "$branch"
    return 0
  fi
  # Remote advancement may be absent from every local project copy. Fetch only
  # into private evidence storage, avoiding any project refs or working files.
  cache="$(blocker_dir "$3")/ancestry.git"
  origin=$(git -C "$repo" remote get-url origin 2>/dev/null) || return "$LANDED_NOT_YET"
  case "$origin" in
    /*|*:* ) ;;
    *) origin="$repo/$origin" ;;
  esac
  ensure_dir "$(dirname "$cache")" || return "$LANDED_NOT_YET"
  if [ ! -d "$cache" ]; then
    (umask 077; git init --bare -q "$cache") || return "$LANDED_NOT_YET"
  fi
  if [ ! -L "$cache" ] && git -C "$cache" fetch --quiet --no-tags --filter=blob:none \
    "$origin" "$branch" >/dev/null 2>&1 \
    && git -C "$cache" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
    printf 'commit %s is on %s (remote evidence)\n' "$sha" "$branch"
    return 0
  fi
  printf 'commit %s is not proven on the default branch yet\n' "$sha"
  return "$LANDED_NOT_YET"
}

local_only_verdict() {  # <worktree> <project>
  local wt=$1 project=$2 head default
  head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) \
    || { printf 'cannot read the task head\n'; return "$LANDED_NOT_YET"; }
  default=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || default=
  default=${default#origin/}
  [ -n "$default" ] || default=$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null) || default=
  if [ -n "$default" ] && git -C "$project" merge-base --is-ancestor "$head" "refs/heads/$default" 2>/dev/null; then
    printf 'commit %s is on local %s\n' "$head" "$default"
    return 0
  fi
  printf 'task head is not on the local default branch yet\n'
  return "$LANDED_NOT_YET"
}

# Evaluate without the evidence record: prints one reason line, returns the
# condition exit code.
evaluate_landed() {  # <blocker>
  local id=$1 meta status outcome pr mode wt project
  meta="$STATE/$id.meta"
  status="$STATE/$id.status"
  if [ -f "$meta" ]; then
    outcome=$(latest_outcome_line "$status")
    if [ "$(status_line_verb "$outcome")" = failed ]; then
      printf 'blocker %s failed: %s\n' "$id" "$(status_line_note "$outcome")"
      return "$LANDED_FAILED"
    fi
    pr=$(fm_dod_meta_value "$meta" pr)
    [ -z "$pr" ] || { pr_verdict "$pr"; return; }
    mode=$(fm_dod_meta_value "$meta" mode)
    wt=$(fm_dod_meta_value "$meta" worktree)
    project=$(fm_dod_meta_value "$meta" project)
    [ "$(status_line_verb "$outcome")" = "done" ] \
      || { printf 'blocker %s has not reported done yet\n' "$id"; return "$LANDED_NOT_YET"; }
    case "$mode" in
      direct-push)
        if [ -d "$wt" ]; then direct_push_verdict "$wt" "$outcome" "$id"; else direct_push_verdict "$project" "$outcome" "$id"; fi
        return ;;
      local-only)
        local_only_verdict "$wt" "$project"
        return ;;
    esac
    printf 'blocker %s has no recorded PR yet\n' "$id"
    return "$LANDED_NOT_YET"
  fi
  if pr=$(backlog_pr_link "$id") && [ -n "$pr" ]; then
    pr_verdict "$pr"
    return
  fi
  printf 'blocker %s has no task record and no landed evidence was observed; verify its landing by hand\n' "$id"
  return "$LANDED_FAILED"
}

cmd_landed() {
  local id=${1-} dir evidence reason rc
  valid_id "$id" || die "invalid blocker task id: ${id-}"
  dir=$(blocker_dir "$id")
  evidence="$dir/landed"
  if [ -f "$evidence" ]; then
    printf 'landed (recorded): %s\n' "$(head -1 "$evidence")"
    exit 0
  fi
  reason=$(evaluate_landed "$id")
  rc=$?
  printf '%s\n' "$reason"
  if [ "$rc" -eq 0 ]; then
    if ! ensure_dir "$dir" || ! write_atomic "$evidence" "$reason"; then
      printf 'cannot record landed evidence\n'
      exit 2
    fi
  fi
  exit "$rc"
}

# --- deliver -----------------------------------------------------------------

deliver_locked() {  # <blocker> -> 0 all sent or skipped, 1 otherwise
  local id=$1 dir steer waiter failures=0 text
  dir=$(blocker_dir "$id")
  [ -f "$dir/landed" ] || { printf 'refused: no landed evidence is recorded for %s\n' "$id"; return 2; }
  [ -e "$dir/delivered" ] || write_atomic "$dir/delivered" "$(date +%s)" || return 1
  for steer in "$dir"/*.steer; do
    [ -f "$steer" ] || continue
    waiter=$(basename "$steer" .steer)
    if [ -e "$dir/$waiter.sent" ]; then
      printf '%s: already steered\n' "$waiter"
      continue
    fi
    if [ -e "$dir/$waiter.skipped" ]; then
      printf '%s: skipped earlier (not live)\n' "$waiter"
      continue
    fi
    if [ -e "$dir/$waiter.claim" ]; then
      printf '%s: an earlier delivery was claimed but never confirmed; check its steering inbox, then remove %s to allow a resend\n' \
        "$waiter" "$dir/$waiter.claim"
      failures=$((failures + 1))
      continue
    fi
    if [ ! -f "$STATE/$waiter.meta" ]; then
      write_atomic "$dir/$waiter.skipped" "$(date +%s)" || failures=$((failures + 1))
      printf '%s: not live; skipped\n' "$waiter"
      continue
    fi
    if ! (umask 077; set -o noclobber; printf '%s\n' "$(date +%s)" > "$dir/$waiter.claim") 2>/dev/null; then
      printf '%s: cannot claim delivery\n' "$waiter"
      failures=$((failures + 1))
      continue
    fi
    text=$(cat "$steer")
    if "$SCRIPT_DIR/fm-send.sh" "$waiter" "$text" >/dev/null; then
      mv -f -- "$dir/$waiter.claim" "$dir/$waiter.sent" || failures=$((failures + 1))
      printf '%s: steered\n' "$waiter"
    else
      rm -f -- "$dir/$waiter.claim"
      printf '%s: send failed; rerun deliver to retry\n' "$waiter"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

cmd_deliver() {
  local id=${1-} rc
  valid_id "$id" || die "invalid blocker task id: ${id-}"
  ensure_dir "$(blocker_dir "$id")" || die "cannot create the dependency directory"
  lock_blocker "$id"
  deliver_locked "$id"
  rc=$?
  unlock_blocker
  exit "$rc"
}

# --- register ------------------------------------------------------------------

# Highest captured result sequence, including already handled prior watches.
last_watch_result() {  # <source-id>
  local result seq highest=0
  for result in "$STATE/procevent-inbox/$1".*.result; do
    [ -f "$result" ] || continue
    seq=${result%.result}; seq=${seq##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" -le "$highest" ] || highest=$seq
  done
  printf '%s\n' "$highest"
}

# 0 registered and unclaimed, 1 proven terminal, 2 unknown/ambiguous.
existing_watch_state() {  # <blocker> <name>
  local dir sid cursor latest result class row rc
  dir=$(blocker_dir "$1"); sid="when-$2"
  [ -r "$dir/watch-result-cursor" ] || { printf 'watch result cursor is unreadable\n'; return 2; }
  cursor=$(cat "$dir/watch-result-cursor")
  case "$cursor" in ''|*[!0-9]*) printf 'watch result cursor is invalid\n'; return 2 ;; esac
  latest=$(last_watch_result "$sid")
  if [ "$latest" -gt "$cursor" ]; then
    result="$STATE/procevent-inbox/$sid.$latest.result"
    class=$("$SCRIPT_DIR/fm-procevent-when.sh" classify "$result") || return 2
    case "$class" in
      fired|action-failed|condition-error|never-true|rejected) printf '%s\n' "$class"; return 1 ;;
      *) printf 'watch outcome is %s; verify it manually\n' "$class"; return 2 ;;
    esac
  fi
  if [ -e "$STATE/when/$sid.fired" ] || [ -L "$STATE/when/$sid.fired" ]; then
    printf 'watch action was claimed without a captured outcome\n'; return 2
  fi
  fm_procevent_source_lock_acquire "$sid" || return 2
  fm_procevent_registration_matches_locked "$STATE" when "$sid" \
    "$SCRIPT_DIR/fm-procevent-when.sh" run "$sid"
  rc=$?
  fm_procevent_source_lock_release "$sid"
  [ "$rc" -eq 0 ] || { printf 'watch registration is missing or mismatched\n'; return 2; }
  row=$("$SCRIPT_DIR/fm-procevent.sh" list) || return 2
  row=$(printf '%s\n' "$row" | awk -v sid="$sid" '$1 == sid {print $2, $3}')
  case "$row" in
    'when live'|'when none') return 0 ;;
    *) printf 'watch ownership is unreadable or uncertain: %s\n' "$row"; return 2 ;;
  esac
}

cmd_register() {
  local waiter=${1-} blocker='' steer='' dir name out watch_state
  valid_id "$waiter" || die "invalid waiting task id: ${waiter-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --after) blocker=${2-}; shift 2 || die "--after needs a blocker task id" ;;
      --steer) steer=${2-}; shift 2 || die "--steer needs text" ;;
      *) die "unknown register argument: $1" ;;
    esac
  done
  valid_id "$blocker" || die "register needs --after <blocker-task>"
  [ "$blocker" != "$waiter" ] || die "a task cannot wait on itself"
  [ -f "$STATE/$waiter.meta" ] || die "waiting task $waiter is not live (no state/$waiter.meta)"
  [ -n "$steer" ] || steer=$(default_steer "$blocker")
  case "$steer" in *[![:space:]]*) ;; *) die "the steer text must not be empty" ;; esac
  name=$(watch_name "$blocker")
  "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$name" >/dev/null 2>&1 \
    || die "blocker id is too long for a watch name: $blocker"

  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" block "$waiter" --by "$blocker" 2>&1) \
    || die "cannot record the blocked-by edge in the backlog: $(printf '%s\n' "$out" | head -1)"

  dir=$(blocker_dir "$blocker")
  if ! ensure_dir "$LAND_DIR" || ! ensure_dir "$dir"; then
    die "cannot create the dependency directory"
  fi
  lock_blocker "$blocker"
  if [ -e "$dir/$waiter.sent" ] || [ -e "$dir/$waiter.claim" ]; then
    die "$waiter was already steered for $blocker"
  fi
  rm -f -- "$dir/$waiter.skipped"
  write_atomic "$dir/$waiter.steer" "$steer" || die "cannot record the steer"
  printf 'registered: %s waits for %s\n' "$waiter" "$blocker"

  if [ -e "$dir/delivered" ]; then
    printf 'blocker already landed; delivering now\n'
    deliver_locked "$blocker"
    local rc=$?
    unlock_blocker
    exit "$rc"
  fi
  if [ -e "$STATE/when/when-$name.spec" ] || [ -L "$STATE/when/when-$name.spec" ]; then
    out=$(existing_watch_state "$blocker" "$name"); watch_state=$?
    case "$watch_state" in
      0)
        printf 'watch %s is already armed\n' "when-$name"
        unlock_blocker
        exit 0 ;;
      1)
        "$SCRIPT_DIR/fm-procevent-when.sh" retire "$name" \
          || die "cannot retire ended watch when-$name"
        write_atomic "$dir/watch-rearmed" "$(date +%s) $out" || die "cannot record watch retirement"
        printf 're-arming ended watch when-%s (%s)\n' "$name" "$out" ;;
      *) die "cannot reuse watch when-$name: ${out:-watch state unreadable}; supervisor handling required" ;;
    esac
  fi
  write_atomic "$dir/watch-result-cursor" "$(last_watch_result "when-$name")" \
    || die "cannot record watch result cursor"
  "$SCRIPT_DIR/fm-procevent-when.sh" arm "$name" --interval "${FM_LAND_AFTER_INTERVAL:-30}" --deadline 1209600 \
    --condition "$SCRIPT_DIR/fm-land-after.sh" --home "$FM_HOME" landed "$blocker" \
    --action "$SCRIPT_DIR/fm-land-after.sh" --home "$FM_HOME" deliver "$blocker" \
    || die "cannot arm the landing watch for $blocker"
  unlock_blocker
}

# --- status ------------------------------------------------------------------

cmd_status() {
  local id=${1-} dir steer waiter state
  valid_id "$id" || die "invalid blocker task id: ${id-}"
  dir=$(blocker_dir "$id")
  [ -d "$dir" ] || { printf 'no waiters registered for %s\n' "$id"; return 0; }
  if [ -f "$dir/landed" ]; then
    printf 'blocker %s: landed (%s)\n' "$id" "$(head -1 "$dir/landed")"
  else
    printf 'blocker %s: not landed yet\n' "$id"
  fi
  for steer in "$dir"/*.steer; do
    [ -f "$steer" ] || continue
    waiter=$(basename "$steer" .steer)
    state=waiting
    [ ! -e "$dir/$waiter.claim" ] || state=claimed-unconfirmed
    [ ! -e "$dir/$waiter.skipped" ] || state=skipped
    [ ! -e "$dir/$waiter.sent" ] || state=steered
    printf '  %s: %s\n' "$waiter" "$state"
  done
}

case "${1-}" in
  register) shift; cmd_register "$@" ;;
  status)   shift; cmd_status "$@" ;;
  landed)   shift; cmd_landed "$@" ;;
  deliver)  shift; cmd_deliver "$@" ;;
  -h|--help) usage 0 ;;
  '') usage ;;
  *) die "unknown command: $1" ;;
esac
