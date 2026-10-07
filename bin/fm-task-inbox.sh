#!/usr/bin/env bash
# fm-task-inbox.sh - identity-bound milestone delivery through the steering inbox.
#
# Usage (FM_HOME is the registering supervisor's home, always explicit):
#   fm-task-inbox.sh register <route-id> <registration.json>
#   fm-task-inbox.sh deliver <route-id> <event.json>
#   fm-task-inbox.sh receipt <route-id> <delivery-key>
#
# Registration schema (fm-task-milestone-route.v1), exact fields:
#   kind: batch-ready | result-receipt
#   request, batch: nonempty opaque ids
#   producer, consumer: {home: main | secondmate:<id>, task, generation}
#     generation is the task metadata's spawn_gen, not a timestamp or PID.
#   independent: boolean; true requires distinct producer/consumer tasks
#   exclusions: [{home, task}, ...] authors forbidden as this consumer
# Registrations are explicit prior routing authority, not approval of evidence.
# A route is immutable. Re-registration of identical content is idempotent.
#
# Event schema (fm-task-milestone.v1), exact fields:
#   kind, request, batch, producer: must exactly match registration
#   evidence_sha256: lowercase SHA256 of payload's exact UTF-8 bytes
#   payload: nonempty text containing the owner receipt, including EVERY
#     limitation/refusal and evidence reference; no inference of PASS or ready
#     is performed here. Owner-specific emitters remain responsible for facts.
# One (route, evidence digest) binds one immutable event. Reusing that key with
# different content refuses. Output is a JSON delivery receipt: enqueued means
# only durable delivery; consumed means the worker moved it to handled/, NEVER
# acceptance, independent review, approval, or completion of the request;
# quarantined means a relaunch or the watcher moved it out of the live inbox
# because its consumer generation was no longer current.
# receipt/deliver retain that handled proof on observation so it survives inbox
# cleanup; read the consumption receipt before retiring the consuming task.
#
# Routes and delivery intents live in state/task-inbox-routes/, not a new bus.
# The ordinary task inbox, atomic sequencing/dedup and watcher re-ring ladder
# own delivery and missed-consumption escalation. There is no new daemon.
# A retry recovers the same intent and message, including a crash after enqueue
# but before recording its sequence. Once a sequence is recorded, its absence
# is ambiguous and refuses rather than delivering twice. Preserve this state
# and the task inbox when moving a home. Routes resolve secondmate IDs through
# the current registry on each call, never a captured absolute home path.
# Only local registered homes are supported; remote routes refuse explicitly
# (never interpreted as local paths). An owner may invoke deliver as an existing
# process-event action; nonzero results must follow that owner's failure path.
# Missing/stale tasks refuse, rather than spawning or authorizing successors.
# This operation does not replace or filter the status channel: producers still
# publish captain-relevant outcomes, decisions and failures by their usual path.
# Lifecycle metadata locks protect enqueue. A relaunch quarantines records bound
# to an older generation before the replacement reads its inbox, and the watcher
# quarantines any it still finds; either wakes the supervisor once, never
# ringing an old receipt into a replacement task. A secondmate consumer's quarantine
# also sends one failed line on its parent channel, since that parent registered it. Payloads also name their
# consumer generation. Reassignment requires new explicit registration.
#
# Independent deliveries take one claim per request/batch/kind/digest across
# routes, binding the consumer identity. A second reviewer cannot claim the same
# evidence. Claims survive failure/retry and never silently transfer: only a new
# registration for the same consumer {home, task} takes over, and only once the
# claiming route's generation is no longer that task's current one. The takeover
# (routes and generations) is recorded in the new route's receipt.
# These are routing exclusions, not proof of scientific or organizational
# independence. Review verdicts, privacy and priorities remain with agents.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_FM_HOME=${FM_HOME:-}
fail() { echo "fm-task-inbox: $*" >&2; exit 1; }
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$SCRIPT_DIR/fm-task-inbox.sh"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ -n "$CALLER_FM_HOME" ] && [ -d "$CALLER_FM_HOME/state" ] || fail 'FM_HOME with an existing state directory is required'
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    fail 'shasum or sha256sum is required'
  fi
}
HOME_ROOT=$(cd "$CALLER_FM_HOME" && pwd -P)
ROUTES="$HOME_ROOT/state/task-inbox-routes"
COMMAND=${1:-} ROUTE=${2:-} INPUT=${3:-}
[ "$#" = 3 ] || fail 'expected register|deliver|receipt <route-id> <file-or-key>'
case "$ROUTE" in ''|.*|*[!A-Za-z0-9._-]*) fail 'invalid route id' ;; esac
case "$COMMAND" in register|deliver|receipt) ;; *) fail 'unknown command' ;; esac
command -v jq >/dev/null || fail 'jq is required'
mkdir -p "$ROUTES/claims"
LOCKS=()
TMP=
INPUT_SNAPSHOT=
cleanup() {
  local i
  [ -z "$TMP" ] || rm -f "$TMP"
  [ -z "$INPUT_SNAPSHOT" ] || rm -f "$INPUT_SNAPSHOT"
  for ((i=${#LOCKS[@]}-1; i>=0; i--)); do fm_lock_release "${LOCKS[$i]}"; done
}
trap cleanup EXIT
lock() {
  fm_lock_try_acquire "$1" || fail "routing or lifecycle operation in progress: $1"
  LOCKS+=("$1")
}
# Nonblocking acquisition avoids inverting another lifecycle owner's order.
lock "$(secondmate_registry_lock_path "$HOME_ROOT/state")"
lock "$ROUTES/.lock"
if [ "$COMMAND" != receipt ]; then
  INPUT_SNAPSHOT=$(mktemp "$ROUTES/.input.XXXXXX")
  jq -Sc . "$INPUT" > "$INPUT_SNAPSHOT" || fail 'unreadable JSON input'
  INPUT=$INPUT_SNAPSHOT
fi

# Home placement is resolved only from the supervisor's own registry. No path
# in an event/registration may select a destination.
home_for() {
  local id=$1 path
  case "$id" in
    main) printf '%s' "$HOME_ROOT" ;;
    secondmate:*)
      secondmate_registry_line_for_id "$HOME_ROOT/data/secondmates.md" "${id#secondmate:}" \
        || fail "missing or ambiguous home route: $id"
      [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || fail "remote milestone delivery is unsupported: $id"
      path=$SECONDMATE_REGISTRY_HOME
      case "$path" in /*) ;; *) fail 'home route is not absolute' ;; esac
      [ -d "$path/state" ] || fail "home route is unavailable: $id"
      [ "$(fm_parent_channel_home_id "$path")" = "${id#secondmate:}" ] || fail "home identity mismatch: $id"
      (cd "$path" && pwd -P)
      ;;
    *) fail 'invalid home identity' ;;
  esac
}

JQ_TYPES='
  def id: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
  def home: . == "main" or (type == "string" and test("^secondmate:[A-Za-z0-9][A-Za-z0-9._-]*$"));
  def opaque: type == "string" and length > 0 and length <= 512 and (explode | all(. >= 32));
  def party: type == "object" and (keys == ["generation","home","task"]) and (.home|home) and (.task|id) and (.generation|id);
  def excluded: type == "object" and (keys == ["home","task"]) and (.home|home) and (.task|id);
  def kind: . == "batch-ready" or . == "result-receipt";
'
validate_route() {
  jq -e "$JQ_TYPES"'
    type == "object" and keys == ["batch","consumer","exclusions","independent","kind","producer","request","schema"]
    and .schema == "fm-task-milestone-route.v1" and (.kind|kind)
    and (.request|opaque) and (.batch|opaque) and (.producer|party) and (.consumer|party)
    and (.independent|type == "boolean") and (.exclusions|type == "array" and all(.[]; excluded))
    and ((.independent|not) or ((.producer|{home,task}) != (.consumer|{home,task})))
    and (.consumer as $c | all(.exclusions[]; . != ($c|{home,task})))
  ' "$1" >/dev/null || fail 'invalid route or excluded/non-independent consumer'
}
validate_event() {
  jq -e "$JQ_TYPES"'
    type == "object" and keys == ["batch","evidence_sha256","kind","payload","producer","request","schema"]
    and .schema == "fm-task-milestone.v1" and (.kind|kind)
    and (.request|opaque) and (.batch|opaque) and (.producer|party)
    and (.evidence_sha256|type == "string" and test("^[a-f0-9]{64}$"))
    and (.payload|type == "string" and length > 0 and (contains("\u0000")|not))
  ' "$1" >/dev/null || fail 'invalid milestone event'
  local digest
  digest=$(jq -jr .payload "$1" | sha256_stdin)
  [ "$digest" = "$(jq -r .evidence_sha256 "$1")" ] || fail 'evidence digest does not match payload'
}

# Pin both metadata records while checking identity and publishing to the inbox.
# All lock attempts are nonblocking, including duplicate producer/consumer paths.
check_parties() {
  local doc=$1 role home task gen meta count actual lock_path held producer_path='' excluded_home excluded_task
  for role in producer consumer; do
    home=$(home_for "$(jq -r ".$role.home" "$doc")")
    task=$(jq -r ".$role.task" "$doc")
    gen=$(jq -r ".$role.generation" "$doc")
    meta="$home/state/$task.meta"
    lock_path=$(fm_meta_lock_path "$meta") || fail 'cannot resolve metadata lock'
    held=0
    for actual in "${LOCKS[@]}"; do [ "$actual" != "$lock_path" ] || held=1; done
    [ "$held" = 1 ] || lock "$lock_path"
    [ -f "$meta" ] && [ ! -L "$meta" ] || fail "task unavailable: $role $task"
    count=$(grep -c '^spawn_gen=' "$meta" || true)
    actual=$(fm_meta_get "$meta" spawn_gen)
    [ "$count" = 1 ] && [ "$actual" = "$gen" ] || fail "stale or ambiguous task generation: $role $task"
    if [ "$role" = producer ]; then
      producer_path=$meta
    else
      if [ "$(jq -r .independent "$doc")" = true ] && [ "$producer_path" = "$meta" ]; then
        fail 'independent consumer resolves to the producer task'
      fi
      CONSUMER_HOME=$home; CONSUMER_TASK=$task
    fi
  done
  while IFS=$'\t' read -r excluded_home excluded_task; do
    [ -n "$excluded_home" ] || continue
    home=$(home_for "$excluded_home")
    [ "$home/state/$excluded_task.meta" != "$CONSUMER_HOME/state/$CONSUMER_TASK.meta" ] \
      || fail 'consumer resolves to an excluded author'
  done < <(jq -r '.exclusions[] | [.home,.task] | @tsv' "$doc")
}

atomic_copy() {
  TMP=$(mktemp "$ROUTES/.staging.XXXXXX")
  jq -Sc . "$1" > "$TMP"
  mv "$TMP" "$2"
  TMP=
}
REG="$ROUTES/$ROUTE.json"
if [ "$COMMAND" = register ]; then
  validate_route "$INPUT"
  check_parties "$INPUT"
  if [ -e "$REG" ]; then
    [ "$(jq -Sc . "$REG")" = "$(jq -Sc . "$INPUT")" ] || fail 'route already registered with different authority'
  else
    atomic_copy "$INPUT" "$REG"
  fi
  printf '{"route":"%s","outcome":"registered"}\n' "$ROUTE"
  exit 0
fi
[ -f "$REG" ] && [ ! -L "$REG" ] || fail 'route is not registered'
validate_route "$REG"
EVENTS="$ROUTES/$ROUTE"
mkdir -p "$EVENTS"
if [ "$COMMAND" = deliver ]; then
  validate_event "$INPUT"
  jq -e --slurpfile route "$REG" '
    {kind,request,batch,producer} == ($route[0]|{kind,request,batch,producer})
  ' "$INPUT" >/dev/null || fail 'event does not match registered producer/request/batch'
  KEY=$(jq -r .evidence_sha256 "$INPUT")
else
  KEY=$INPUT
fi
[[ "$KEY" =~ ^[a-f0-9]{64}$ ]] || fail 'invalid delivery key'
EVENT="$EVENTS/$KEY.json"
SEQUENCE="$EVENTS/$KEY.sequence"
RECEIPT="$EVENTS/$KEY.receipt.json"
TAKEOVER="$EVENTS/$KEY.takeover.json"
if [ "$COMMAND" = receipt ] && [ -f "$RECEIPT" ] \
  && [ "$(jq -r .outcome "$RECEIPT")" = consumed ]; then
  jq . "$RECEIPT"
  exit 0
fi
if [ "$COMMAND" = receipt ]; then
  [ -f "$EVENT" ] && [ -f "$SEQUENCE" ] || fail 'delivery has no confirmed inbox sequence; retry deliver'
else
  check_parties "$REG"
  if [ -f "$EVENT" ]; then
    [ "$(jq -Sc . "$EVENT")" = "$(jq -Sc . "$INPUT")" ] || fail 'delivery key already binds different content'
  fi
  if [ "$(jq -r .independent "$REG")" = true ]; then
    CLAIM_KEY=$(jq -Sc '{kind,request,batch,evidence_sha256}' "$INPUT" | sha256_stdin)
    CLAIM="$ROUTES/claims/$CLAIM_KEY.json"
    if [ ! -f "$CLAIM" ] || [ "$(jq -Sc .consumer "$CLAIM")" != "$(jq -Sc .consumer "$REG")" ] \
      || [ "$(jq -r .route "$CLAIM")" != "$ROUTE" ]; then
      if [ -f "$CLAIM" ]; then
        jq -e --slurpfile reg "$REG" '
          (.consumer|{home,task}) == ($reg[0].consumer|{home,task})
          and .consumer.generation != $reg[0].consumer.generation
        ' "$CLAIM" >/dev/null || fail 'evidence is already claimed by another reviewer route'
        TMP=$(mktemp "$ROUTES/.staging.XXXXXX")
        jq -Sc --arg route "$ROUTE" --slurpfile reg "$REG" '{from_route:.route,from_generation:.consumer.generation,
          to_route:$route,to_generation:$reg[0].consumer.generation}' "$CLAIM" > "$TMP"
        mv "$TMP" "$TAKEOVER"
        TMP=
      fi
      TMP=$(mktemp "$ROUTES/.staging.XXXXXX")
      jq -Sc --arg route "$ROUTE" '. + {route:$route}' "$REG" > "$TMP"
      mv "$TMP" "$CLAIM"
      TMP=
    fi
  fi
  # Intent before effect; the existing idempotent inbox write repairs a crash
  # after enqueue and before sequence publication without a duplicate message.
  [ -f "$EVENT" ] || atomic_copy "$INPUT" "$EVENT"
fi
# Receipt lookup resolves current placement and records handled proof, but can
# report historical consumption after task exit without calling it acceptance.
if [ "$COMMAND" = receipt ]; then
  CONSUMER_HOME=$(home_for "$(jq -r .consumer.home "$REG")")
  CONSUMER_TASK=$(jq -r .consumer.task "$REG")
fi
BODY=$(jq -Sc --arg route "$ROUTE" --slurpfile reg "$REG" \
  '. + {route:$route,consumer:$reg[0].consumer,notice:"Delivery is not acceptance. Check consumer generation before using this receipt; retain all limitations and refusals."}' "$EVENT")
INBOX=$(fm_task_inbox_dir "$CONSUMER_HOME/state" "$CONSUMER_TASK")
if [ -f "$SEQUENCE" ]; then
  BASE=$(cat "$SEQUENCE")
  [[ "$BASE" =~ ^[0-9]+\.msg$ ]] || fail 'invalid recorded inbox sequence'
  RECORD="$INBOX/$BASE"
  [ ! -f "$INBOX/handled/$BASE" ] || RECORD="$INBOX/handled/$BASE"
  [ ! -f "$INBOX/quarantine/$BASE" ] || RECORD="$INBOX/quarantine/$BASE"
  [ -f "$RECORD" ] && [ "$(fm_task_inbox_body "$RECORD")" = "$BODY" ] \
    || fail 'recorded delivery is missing or changed; reconcile rather than replay'
else
  RECORD=$(fm_task_inbox_write_idempotent "$CONSUMER_HOME/state" "$CONSUMER_TASK" "$BODY" '' "$(jq -r .consumer.generation "$REG")")
  TMP=$(mktemp "$ROUTES/.staging.XXXXXX")
  printf '%s\n' "${RECORD##*/}" > "$TMP"
  mv "$TMP" "$SEQUENCE"
  TMP=
fi
OUTCOME=enqueued
[ ! -f "$INBOX/handled/${RECORD##*/}" ] || OUTCOME=consumed
[ ! -f "$INBOX/quarantine/${RECORD##*/}" ] || OUTCOME=quarantined
TMP=$(mktemp "$ROUTES/.staging.XXXXXX")
jq -nc --arg route "$ROUTE" --arg key "$KEY" --arg outcome "$OUTCOME" \
  --arg record "${RECORD##*/}" --slurpfile reg "$REG" \
  --slurpfile takeover <(if [ -f "$TAKEOVER" ]; then cat "$TAKEOVER"; fi) \
  '$reg[0] | {schema:"fm-task-milestone-receipt.v1",route:$route,delivery_key:$key,
    outcome:$outcome,record:$record,kind,request,batch,producer,consumer}
    + if $takeover == [] then {} else {takeover:$takeover[0]} end' > "$TMP"
mv "$TMP" "$RECEIPT"
TMP=
jq . "$RECEIPT"
# No terminal injection here: the existing watcher delivers the durable inbox
# on its normal cadence, with exactly its supported backend/harness semantics.
