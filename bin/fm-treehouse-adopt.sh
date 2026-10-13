#!/usr/bin/env bash
# fm-treehouse-adopt.sh - owner-run, in-place adoption of retained pooled tasks.
# Usage: FM_HOME=<owning-home> bin/fm-treehouse-adopt.sh [<task-id>]
# Requires Treehouse v3.1.2's native lease and status --json interfaces.
# With no id, visits this home's ordinary task records only. Relaunch performs
# the same per-record repair automatically before stopping a legacy holder.
# Under task metadata and shared project locks, an exclusive recorded copy
# with an absent or exact task/home claim is leased and published in place.
# Live holders require this task's FM_TASK_ID and recorded pane identity, or
# its own idle Herdr login shell/plain get with an idle login-shell child.
# Unrelated processes, foreign panes and unrelated shell children still refuse.
# Existing matching leases are reused, never replaced. Duplicate records,
# foreign claims/leases and unverified holders remain owner-reconciliation cases.
# Never type cd/exit into a retained pane to enable adoption: native lease is
# state-only and protects the copy before its interactive get can exit.
# It never returns, resets, cleans, discards, or edits another home's records.
# Native status/lease may tidy stale dead-process pool owner records; a direct
# non-Firstmate Treehouse client can race the process check under our lock.
# Failure after leasing preserves and reports the lease identity for retry.
# Exit: 0 adopted/already protected; 1 conflicts/errors; 2 usage/dependency error.
set -u
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
esac
[ "$#" -le 1 ] && [ -n "${FM_HOME:-}" ] || {
  echo 'error: usage: FM_HOME=<owning-home> fm-treehouse-adopt.sh [<task-id>]' >&2; exit 2;
}
ID=${1:-}
case "$ID" in .|..|*[!A-Za-z0-9._-]*) exit 2 ;; esac
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || exit 2
[ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || exit 2
[ -z "${FM_STATE_OVERRIDE:-}" ] || [ "$FM_STATE_OVERRIDE" = "$FM_HOME/state" ] || exit 2
export FM_HOME FM_STATE_OVERRIDE="$FM_HOME/state"
for tool in treehouse jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing $tool" >&2; exit 2; }
done
treehouse lease --help >/dev/null 2>&1 || { echo 'error: Treehouse native lease unavailable (requires v3.1.2)' >&2; exit 2; }
# shellcheck source=bin/fm-wake-lib.sh
. "$SELF_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SELF_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-treehouse-adopt-lib.sh
. "$SELF_DIR/fm-treehouse-adopt-lib.sh"
adopt_record() (
  local meta=$1 id project wt lock meta_lock='' project_lock=''
  id=${meta##*/}; id=${id%.meta}
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  case "$(fm_treehouse_record_field "$meta" kind)" in ship|scout) ;; *) return 0 ;; esac
  trap '[ -z "$project_lock" ] || fm_lock_release "$project_lock"; [ -z "$meta_lock" ] || fm_lock_release "$meta_lock"; fm_lease_guard_release' EXIT
  trap 'exit 1' HUP INT TERM
  fm_lease_guard "$id" 'owner adoption' || return 1
  lock=$(fm_meta_lock_path "$meta") && fm_lock_try_acquire "$lock" || return 1
  meta_lock=$lock
  project=$(fm_treehouse_record_field "$meta" project) || return 1
  case "$(fm_treehouse_record_field "$meta" copy_state)" in
    ''|retained) ;;
    released) return 0 ;;
    *) echo "refused: interrupted copy custody for $id; no historical slot adoption" >&2; return 1 ;;
  esac
  wt=$(fm_treehouse_record_field "$meta" worktree) || return 1
  [ -n "$wt" ] || return 0
  if ! fm_treehouse_pool_slot "$project" "$wt"; then
    [ ! -f "$(dirname "$(dirname "$wt")")/treehouse-state.json" ]; return $?
  fi
  lock=$(fm_treehouse_project_lock_path "$project") && fm_lock_try_acquire "$lock" || return 1
  project_lock=$lock
  fm_treehouse_adopt_locked "$meta" "$id" "$project" "$FM_HOME"
)
rc=0
records=("$STATE"/*.meta)
[ -z "$ID" ] || records=("$STATE/$ID.meta")
for meta in "${records[@]}"; do
  if [ -z "$ID" ]; then [ -e "$meta" ] || [ -L "$meta" ] || continue; fi
  if ! adopt_record "$meta"; then
    echo "refused: $meta; no contents discarded, reconcile or retry as the home owner" >&2
    rc=1
  fi
done
exit "$rc"
