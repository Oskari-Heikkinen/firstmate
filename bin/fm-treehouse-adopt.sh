#!/usr/bin/env bash
# fm-treehouse-adopt.sh - owner-run, in-place adoption of retained pooled tasks.
# Usage: FM_HOME=<owning-home> bin/fm-treehouse-adopt.sh
# Requires Treehouse v3.1.2's native `lease` and `status --json` interfaces.
# Run manually once per home, not from spawn/recovery. Visits only this home's
# ordinary task records; registered local-home records are read for conflicts.
# Under the task metadata and shared project locks, an exclusive recorded copy
# with an absent or exact task/home claim and no live holder is durably leased,
# claimed and given treehouse_lease_holder/id fields. Existing matching leases
# are reused, never replaced. Conflicts are listed and left for their owner.
# It never returns, resets, cleans, discards, or edits another home's records.
# Native status/lease may tidy stale dead-process pool owner records. Firstmate
# checks for a live holder under its project lock before leasing, but a direct
# non-Firstmate Treehouse client can race that check; this limitation is accepted.
# Failure after leasing preserves the lease and reports its identity for retry.
# Exit: 0 all eligible records adopted/already protected; 1 conflicts/errors;
# 2 usage/dependency error. No automatic task-record migration or conflict repair.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
esac
[ "$#" -eq 0 ] && [ -n "${FM_HOME:-}" ] || {
  echo 'error: usage: FM_HOME=<owning-home> fm-treehouse-adopt.sh' >&2; exit 2;
}
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || exit 2
[ -d "$FM_HOME/state" ] && [ ! -L "$FM_HOME/state" ] || exit 2
[ -z "${FM_STATE_OVERRIDE:-}" ] || [ "$FM_STATE_OVERRIDE" = "$FM_HOME/state" ] || {
  echo 'error: state override must name this home' >&2; exit 2;
}
export FM_HOME FM_STATE_OVERRIDE="$FM_HOME/state"
for tool in treehouse jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: missing $tool" >&2; exit 2; }
done
treehouse lease --help >/dev/null 2>&1 || { echo 'error: Treehouse native lease unavailable (requires v3.1.2)' >&2; exit 2; }
# shellcheck source=bin/fm-wake-lib.sh
. "$SELF_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SELF_DIR/fm-lease-lib.sh"
META_LOCK='' PROJECT_LOCK='' TMP=''
cleanup() {
  [ -z "$TMP" ] || rm -f "$TMP"
  [ -z "$PROJECT_LOCK" ] || fm_lock_release "$PROJECT_LOCK"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"
  PROJECT_LOCK='' META_LOCK='' TMP=''
  fm_lease_guard_release
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

adopt_record() {
  local meta=$1 id project wt marker pool root holder lease old_holder old_lease
  local lock status row name pid result
  id=${meta##*/}; id=${id%.meta}
  case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) echo "conflict: unsafe task id $meta" >&2; return 1 ;; esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "conflict: unreadable record $meta" >&2; return 1; }
  case "$(fm_treehouse_record_field "$meta" kind)" in ship|scout) ;; *) return 0 ;; esac
  fm_lease_guard "$id" 'owner adoption' || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_try_acquire "$lock" || { echo "conflict: metadata lock busy for $id" >&2; return 1; }
  META_LOCK=$lock
  awk '
    /^(project|worktree|kind|treehouse_lease_holder|treehouse_lease_id)=/ {
      split($0,a,"="); if (++n[a[1]]>1) bad=1
    }
    END {exit bad}' "$meta" || { echo "conflict: ambiguous record $meta" >&2; return 1; }
  project=$(fm_treehouse_record_field "$meta" project) || return 1
  wt=$(fm_treehouse_record_field "$meta" worktree) || return 1
  [ -n "$wt" ] || return 0
  # Non-Treehouse tasks are out of scope; broken recorded pools must be reported.
  if ! fm_treehouse_pool_slot "$project" "$wt"; then
    if [ -f "$(dirname "$(dirname "$wt")")/treehouse-state.json" ]; then
      echo "conflict: cannot prove pooled copy $wt belongs to $project ($id)" >&2; return 1
    fi
    return 0
  fi
  wt=$(CDPATH='' cd -- "$wt" && pwd -P) || return 1
  lock=$(fm_treehouse_project_lock_path "$project") || return 1
  fm_lock_try_acquire "$lock" || { echo "conflict: project lock busy for $id" >&2; return 1; }
  PROJECT_LOCK=$lock
  fm_treehouse_collect_states "$STATE" && fm_treehouse_slot_records_exclusive "$wt" "$meta" || return 1
  marker=$(fm_treehouse_slot_owner_marker "$wt") || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_treehouse_slot_claim_matches "$wt" "$id" "$FM_HOME" || {
      echo "conflict: foreign or ambiguous claim $marker ($id)" >&2; return 1;
    }
  fi
  holder=$(fm_treehouse_lease_holder "$FM_HOME" "$id") || return 1
  old_holder=$(fm_treehouse_record_field "$meta" treehouse_lease_holder) || return 1
  old_lease=$(fm_treehouse_record_field "$meta" treehouse_lease_id) || return 1
  fm_treehouse_slot_lease_read "$wt" || { echo "conflict: unreadable pool lease for $wt" >&2; return 1; }
  if [ "$FM_TREEHOUSE_LEASED" = 1 ]; then
    if ! { [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$holder" ] && \
      { [ -z "$old_holder$old_lease" ] || { [ "$old_holder" = "$holder" ] && [ "$old_lease" = "$FM_TREEHOUSE_LEASE_ID" ]; }; }; }; then
      echo "conflict: foreign or replaced lease at $wt ($id)" >&2; return 1
    fi
    lease=$FM_TREEHOUSE_LEASE_ID
    if [ "$old_holder" = "$holder" ] && [ "$old_lease" = "$lease" ] && \
      fm_treehouse_slot_claim_matches "$wt" "$id" "$FM_HOME"; then
      printf 'already protected: %s %s\n' "$id" "$wt"
      return 0
    fi
  else
    [ -z "$old_holder$old_lease" ] || { echo "conflict: lost recorded lease at $wt ($id)" >&2; return 1; }
    pool=$(dirname "$(dirname "$wt")")
    root=$(dirname "$pool")
    [ "${root##*/}" = .treehouse ] || { echo "conflict: unsupported pool root $pool" >&2; return 1; }
    root=$(dirname "$root")
    # Read the exact row, without Treehouse healing away its process reservation.
    row=$(jq -cer --arg wt "$wt" '[.worktrees[] | select(.path==$wt)] | if length==1 then .[0] else error("ambiguous row") end' "$pool/treehouse-state.json") || return 1
    pid=$(printf '%s\n' "$row" | jq -er '(.owner_pid // 0) | select(type=="number" and .>=0 and floor==.)') || return 1
    if [ "$pid" != 0 ] && { fm_pid_alive "$pid" || ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'; }; then
      echo "conflict: live holder pid=$pid at $wt ($id)" >&2; return 1
    fi
    name=$(printf '%s\n' "$row" | jq -er '.name | select(type=="string" and test("^[A-Za-z0-9._-]+$") and .!="." and .!="..")') || return 1
    # The native resolver must expose this exact path/name before we lease by
    # name. It also supplies the real process scan; unverified never passes.
    status=$(cd "$project" && treehouse --root "$root" status --json) || return 1
    printf '%s\n' "$status" | jq -e --arg wt "$wt" --arg name "$name" '
      [.[] | select(.path==$wt and .name==$name)] | length==1 and
      (.[0] | (.status=="available" or .status=="dirty") and
        (.processes|type)=="array" and (.processes|length)==0)' >/dev/null || {
      echo "conflict: live/unverified holder or native pool mismatch at $wt ($id)" >&2; return 1;
    }
    result=$(cd "$project" && treehouse --root "$root" lease "$name" --lease-holder "$holder" --json) || {
      echo "error: native lease failed at $wt ($id); preserve and inspect its pool identity" >&2; return 1;
    }
    lease=$(printf '%s\n' "$result" | jq -er --arg wt "$wt" --arg h "$holder" '
      select(.path==$wt and .lease_holder==$h) | .lease_id | select(type=="string" and length>0 and (test("[\\r\\n\\t]")|not))') || {
      echo "error: unexpected native lease result for $id: $result; preserve the acquisition" >&2; return 1;
    }
  fi
  # If publication fails, the durable row protects the original contents. A
  # rerun can finish publication for this exact holder; never return on error.
  printf 'protected acquisition: %s %s holder=%s lease_id=%s\n' "$id" "$wt" "$holder" "$lease"
  fm_treehouse_slot_lease_matches "$wt" "$holder" "$lease" && \
    fm_treehouse_slot_records_exclusive "$wt" "$meta" && \
    fm_treehouse_slot_owner_claim "$wt" "$id" "$FM_HOME" || return 1
  TMP=$(mktemp "$STATE/.adopt-$id.XXXXXX") || return 1
  cp -p "$meta" "$TMP" || return 1
  awk '!/^treehouse_lease_holder=/ && !/^treehouse_lease_id=/' "$meta" > "$TMP" || return 1
  printf 'treehouse_lease_holder=%s\ntreehouse_lease_id=%s\n' "$holder" "$lease" >> "$TMP" || return 1
  mv "$TMP" "$meta" || return 1
  TMP=''
  printf 'adopted: %s %s\n' "$id" "$wt"
}

rc=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  if ! adopt_record "$meta"; then
    echo "refused: $meta; no contents discarded, reconcile or retry as the home owner" >&2
    rc=1
  fi
  cleanup
done
exit "$rc"
