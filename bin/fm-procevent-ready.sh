#!/usr/bin/env bash
# Preauthorized read-only handoff -> fresh scout, using the when action owner.
# Usage: fm-procevent-ready.sh authorize <spec.json> --preauthorized
#        fm-procevent-ready.sh cancel <task> <generation>
#        fm-procevent-ready.sh inspect <task> <generation>
#        fm-procevent-ready.sh condition|dispatch <task> <generation>
#
# This is FIRSTMATE-owned commissioning, not authority inferred from a green
# observation. Only authorize explicitly commissioned read-only analysis/diagnosis.
# Spec schema fm-ready-v1: task, generation (path-safe strings), source (observer
# id), handoff (home-relative immutable file), project (home-relative directory),
# profile:{harness,model,effort}, deadline (absolute epoch), capacity (positive
# integer), allow_partial (boolean), existing_generation (null or spawn_gen).
# Only analysis-ready and test-finished observations are eligible, never main-CI.
# The saved data/<task>/brief.md must name the handoff and
# data/<task>/readiness.json. Its generated scout contract limits work to the
# preapproved read-only scope. The handoff owns original question, exact plan/pin,
# privacy and reading scope, expected receipts, gaps, output paths and the pinned
# domain skill/version. The project verifier supplies the schema-checked receipt
# consumed by fm-procevent-observe.sh, including its exact identity and revision.
#
# authorize snapshots the handoff/brief hashes, exact backlog row, observation
# identity and approved profile. A task id is never silently reused/recommissioned.
# All paths remain home-relative across a home move; mismatched material refuses.
# condition only observes readiness. Dispatch RECHECKS freshness, cancellation,
# deadline, identity, hashes, queued/unheld/unblocked backlog, capacity and prior
# artifact immediately before calling fm-spawn.sh --scout with the saved profile.
# An existing scout is usable only at the explicitly commissioned spawn_gen; its
# receipt goes through generation-bound, idempotent fm-send, not another launch.
# The one per-home action lock serializes these automatic dispatches, not shared
# observations; ordinary manual spawn remains under its existing lifecycle owner.
#
# when owns the pre-action at-most-once claim, timeout, capture and exception wake.
# dispatch also persists an intent BEFORE invoking lifecycle and a confirmation
# AFTER success (including actual spawn_gen). A preexisting intent never retries;
# inspect presents the known metadata/artifact for firstmate reconciliation. A
# crash or failed/ambiguous launch is NOT a successful dispatch and cannot spawn
# twice. A later receipt revision belongs to this same analysis identity; it
# cannot silently create a successor. Missing capacity, held work or changed
# evidence emits an action failure for firstmate, not an unbounded renewal loop.
# No cleanup, merge, retry, experiment launch or scientific verdict is authorized.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# Lifecycle helpers refuse to guess a home, so hand them this one explicitly.
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DIR="$STATE/ready"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# Backend metadata parsing is shared with spawn/send, never reconstructed here.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
die() { printf 'ready: %s\n' "$*" >&2; exit 2; }
action_lock() {
  fm_lock_acquire_wait "$DIR/.actions.lock" || die 'automatic action owner busy'
  trap 'fm_lock_release "$DIR/.actions.lock"' EXIT
}
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
valid() {
  jq -e '
    def path: type=="string" and length>0 and (startswith("/")|not) and (split("/")|all(.!=".." and .!=""));
    def name: type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def pos: type=="number" and .>0 and floor==.;
    .schema=="fm-ready-v1" and (.task|name) and (.generation|name) and
    (.source|test("^obs-[a-f0-9]{60}$")) and (.handoff|path) and (.project|path) and
    (.profile.harness|name) and (.profile.model|type=="string" and length>0) and
    (.profile.effort|IN("low","medium","high","xhigh","max","ultra")) and
    (.deadline|pos) and (.capacity|pos) and (.allow_partial|type=="boolean") and
    (.existing_generation==null or (.existing_generation|name))' "$1" >/dev/null
}
identity() {
  TASK=$1; GEN=$2
  if ! fm_task_id_path_safe "$TASK" || ! fm_task_id_path_safe "$GEN"; then die 'invalid task/generation'; fi
  RECORD="$DIR/$TASK.json"
}
load() {
  fm_pr_private_file_valid "$RECORD" 600 "$(fm_pr_file_device "$DIR")" || die 'authorization unavailable'
  fm_pr_private_file_valid "$RECORD.sha256" 600 "$(fm_pr_file_device "$DIR")" || die 'authorization trust binding unavailable'
  [ "$(fm_pr_sha256 "$RECORD")" = "$(< "$RECORD.sha256")" ] || die 'authorization changed'
  [ "$(jq -r .spec.generation "$RECORD")" = "$GEN" ] || die 'stale generation'
  [ ! -e "$DIR/$TASK.cancelled" ] || die 'authorization cancelled'
}
row() {
  fm_backlog_row_probe "$DATA" "$TASK" || die "backlog row unavailable: $FM_BACKLOG_ROW_ERROR"
  case "$FM_BACKLOG_ROW_STATE" in 'queued no no'|'in_flight no no') ;; *) die 'task is not queued/active unheld unblocked work' ;; esac
  fm_backlog_row_show "$DATA" "$TASK"
}
sha_text() { local tmp hash; tmp=$(mktemp); printf '%s' "$1" > "$tmp"; hash=$(fm_pr_sha256 "$tmp"); rm -f "$tmp"; printf '%s' "$hash"; }
check_material() {
  local handoff brief
  handoff="$FM_HOME/$(jq -r .spec.handoff "$RECORD")"
  brief="$DATA/$TASK/brief.md"
  [ "$(fm_pr_sha256 "$handoff")" = "$(jq -r .handoff_sha256 "$RECORD")" ] || die 'handoff changed'
  [ "$(fm_pr_sha256 "$brief")" = "$(jq -r .brief_sha256 "$RECORD")" ] || die 'brief changed'
  [ "$(sha_text "$(row)")" = "$(jq -r .backlog_sha256 "$RECORD")" ] || die 'backlog identity or authorization changed'
}
ready_snapshot() {
  local snap now source
  now=$(date +%s)
  [ "$now" -lt "$(jq -r .spec.deadline "$RECORD")" ] || die 'authorization expired'
  source=$(jq -r .spec.source "$RECORD")
  snap=$("$SCRIPT_DIR/fm-procevent-observe.sh" snapshot "$source") || die 'observation unavailable'
  printf '%s' "$snap" | jq -e --slurpfile r "$RECORD" --argjson now "$now" '
    .spec.identity==$r[0].identity and .spec.deadline>$now and
    (.status=="ready" or (.status=="partial" and $r[0].spec.allow_partial)) and
    .evidence.verified==true and .evidence.terminal==true and
    .evidence.observed_at<= $now and .evidence.observed_at>=($now-.spec.max_age)' >/dev/null || return 1
  # Re-read the authoritative receipt just before dispatch: a previously ready
  # observation is not enough if its producer has since revised/revoked it.
  local receipt
  receipt="$FM_HOME/$(printf '%s' "$snap" | jq -r .spec.receipt)"
  [ "$(jq -cS . "$receipt")" = "$(printf '%s' "$snap" | jq -cS .evidence)" ] || return 1
  printf '%s' "$snap" | jq '.events[-1] + {evidence:.evidence}'
}
authorize() {
  local input=$1 spec snapshot handoff brief backlog hash tmp seconds
  valid "$input" || die 'invalid preauthorization spec'
  spec=$(jq -cS . "$input")
  identity "$(jq -r .task "$input")" "$(jq -r .generation "$input")"
  fm_procevent_source_id_valid "when-ready-$TASK" || die 'task id too long for readiness source'
  (umask 077; mkdir -p "$DIR")
  [ ! -L "$DIR" ] || die 'authorization directory is a symlink'
  action_lock
  [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || die 'task already commissioned; inspect instead of creating another analyst'
  snapshot=$("$SCRIPT_DIR/fm-procevent-observe.sh" snapshot "$(jq -r .source "$input")")
  printf '%s' "$snapshot" | jq -e '.spec.identity.kind|IN("analysis-ready","test-finished")' >/dev/null || die 'CI/ordinary green is not launch authority'
  seconds=$(( $(jq -r .deadline "$input") - $(date +%s) ))
  [ "$seconds" -gt 0 ] || die 'deadline expired'
  handoff="$FM_HOME/$(jq -r .handoff "$input")"; brief="$DATA/$TASK/brief.md"
  [ -f "$handoff" ] && [ -f "$brief" ] || die 'saved handoff or brief missing'
  if ! grep -Fq "$(jq -r .handoff "$input")" "$brief" || ! grep -Fq "data/$TASK/readiness.json" "$brief"; then die 'brief must reference saved handoff and readiness receipt'; fi
  backlog=$(row); hash=$(sha_text "$backlog")
  tmp=$(umask 077; mktemp "$DIR/.authorize.XXXXXX")
  jq -n --argjson spec "$spec" --argjson snap "$snapshot" --arg h "$(fm_pr_sha256 "$handoff")" --arg b "$(fm_pr_sha256 "$brief")" --arg row "$hash" \
    '{spec:$spec,identity:$snap.spec.identity,handoff_sha256:$h,brief_sha256:$b,backlog_sha256:$row}' > "$tmp"
  mv "$tmp" "$RECORD"
  (umask 077; fm_pr_sha256 "$RECORD" > "$RECORD.sha256")
  "$SCRIPT_DIR/fm-procevent-observe.sh" subscribe "$(jq -r .source "$input")" "$TASK" "$GEN"
  # The immutable record survives an arm failure. Inspect it; never blindly
  # authorize a replacement task. The when outcome is the dispatch receipt.
  "$SCRIPT_DIR/fm-procevent-when.sh" arm "ready-$TASK" --deadline "$seconds" --stable 1 \
    --condition "$SCRIPT_DIR/fm-procevent-ready.sh" condition "$TASK" "$GEN" \
    --action "$SCRIPT_DIR/fm-procevent-ready.sh" dispatch "$TASK" "$GEN"
}
dispatch() {
  local event existing meta active=0 f receipt tmp gen
  action_lock
  load; check_material
  [ ! -e "$DIR/$TASK.claim.json" ] || die 'prior dispatch intent exists; inspect known task, never spawn again'
  event=$(ready_snapshot) || die 'receipt not ready or changed'
  [ ! -e "$DATA/$TASK/report.md" ] || die 'analysis artifact already exists'
  existing=$(jq -r '.spec.existing_generation // empty' "$RECORD")
  meta="$STATE/$TASK.meta"
  if [ -e "$meta" ]; then
    [ -n "$existing" ] && [ "$(fm_meta_get "$meta" spawn_gen)" = "$existing" ] && [ "$(fm_meta_get "$meta" kind)" = scout ] || die 'task exists at an unapproved incarnation'
  else
    [ -z "$existing" ] || die 'commissioned existing analyst is missing'
    fm_backlog_row_probe "$DATA" "$TASK" && [ "$FM_BACKLOG_ROW_STATE" = 'queued no no' ] || die 'fresh analysis is not queued'
    for f in "$STATE"/*.meta; do
      [ -f "$f" ] || continue
      [ "$(fm_meta_get "$f" kind)" = secondmate ] || active=$((active + 1))
    done
    [ "$active" -lt "$(jq -r .spec.capacity "$RECORD")" ] || die 'preauthorized capacity exhausted'
  fi
  receipt="$DATA/$TASK/readiness.json"
  [ ! -e "$receipt" ] || die 'receipt artifact already exists; reconcile consumption'
  tmp=$(umask 077; mktemp "$DATA/$TASK/.ready.XXXXXX")
  printf '%s\n' "$event" > "$tmp"; mv "$tmp" "$receipt"
  # Exclusive durable intent BEFORE effects; even failure cannot authorize retry.
  (umask 077; set -o noclobber; jq -n --arg g "$GEN" --argjson e "$event" '{generation:$g,event:$e,status:"intent"}' > "$DIR/$TASK.claim.json") || die 'dispatch already claimed'
  if [ -n "$existing" ]; then
    FM_SEND_EXPECTED_SPAWN_GEN="$existing" FM_SEND_IDEMPOTENT=1 \
      "$SCRIPT_DIR/fm-send.sh" "$TASK" "The commissioned evidence is ready at data/$TASK/readiness.json. Follow the saved handoff; retain every warning and reading constraint." || die 'delivery unconfirmed; inspect claim'
    gen=$existing
  else
    "$SCRIPT_DIR/fm-spawn.sh" "$TASK" "$FM_HOME/$(jq -r .spec.project "$RECORD")" --scout \
      --harness "$(jq -r .spec.profile.harness "$RECORD")" --model "$(jq -r .spec.profile.model "$RECORD")" \
      --effort "$(jq -r .spec.profile.effort "$RECORD")" || die 'spawn unconfirmed; inspect claim'
    gen=$(fm_meta_get "$meta" spawn_gen)
    [ -n "$gen" ] || die 'spawn returned without an incarnation; inspect claim'
  fi
  tmp=$(umask 077; mktemp "$DIR/.confirm.XXXXXX")
  jq --arg gen "$gen" '.status="confirmed" | .spawn_gen=$gen' "$DIR/$TASK.claim.json" > "$tmp"
  mv "$tmp" "$DIR/$TASK.claim.json"
  "$SCRIPT_DIR/fm-procevent-observe.sh" ack "$(jq -r .spec.source "$RECORD")" "$TASK" "$GEN" "$(printf '%s' "$event" | jq -r .event)"
  printf 'confirmed: %s %s\n' "$TASK" "$gen"
}
case "${1:-}" in
  authorize) [ "$#" = 3 ] && [ "$3" = --preauthorized ] || die 'explicit preauthorization required'; authorize "$2" ;;
  condition) identity "${2:?}" "${3:?}"; load; ready_snapshot >/dev/null ;;
  dispatch) identity "${2:?}" "${3:?}"; dispatch ;;
  cancel)
    identity "${2:?}" "${3:?}"
    action_lock
    load; (umask 077; printf '%s\n' "$GEN" > "$DIR/$TASK.cancelled") ;;
  inspect)
    identity "${2:?}" "${3:?}"
    [ "$(jq -r .spec.generation "$RECORD")" = "$GEN" ] || die 'stale generation'
    jq . "$RECORD"
    [ ! -f "$DIR/$TASK.claim.json" ] || jq . "$DIR/$TASK.claim.json"
    printf 'current_spawn_gen: %s\n' "$(fm_meta_get "$STATE/$TASK.meta" spawn_gen)"
    printf 'No retry is authorized by this inspection. Reconcile known task and artifact.\n' ;;
  -h|--help|'') usage ;;
  *) exit 1 ;;
esac
