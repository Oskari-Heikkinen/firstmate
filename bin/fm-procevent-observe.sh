#!/usr/bin/env bash
# Shared, read-only dependency observations, captured by fm-procevent.sh.
# Usage: fm-procevent-observe.sh arm <spec.json>
#        fm-procevent-observe.sh subscribe <source> <subscriber> <generation>
#        fm-procevent-observe.sh resubscribe <source> <subscriber> <old-generation> <new-generation>
#        fm-procevent-observe.sh pending <source> <subscriber> <generation>
#        fm-procevent-observe.sh ack <source> <subscriber> <generation> <event>
#        fm-procevent-observe.sh run <source>
#        fm-procevent-observe.sh classify|terminal|silent <result>
#        fm-procevent-observe.sh snapshot <source>
#
# Spec: {schema:"fm-observe-v1", identity:{kind, ...exact dependency fields},
# receipt:"relative/home/path.json", deadline:<absolute epoch>, max_age:<seconds>,
# interval:<positive seconds>}. CI identity additionally requires head (full SHA),
# attempt (positive integer), jobs (nonempty unique required job names). All check
# policy, repository, branch and application identities belong in identity, which
# the project producer must echo exactly. No branch-name-only green is accepted.
# Kinds: main-ci, receipt, analysis-ready, test-finished.
#
# The home-local producer atomically publishes {schema:"fm-evidence-v1", identity,
# revision:<nonempty string>, observed_at:<epoch>, status:pending|ready|partial|red}.
# main-ci additionally supplies head, attempt and jobs:[{name,status}], status being
# pending|success|failure; only ALL expected jobs successful at the EXACT head and
# attempt is green. Earlier green/revert heads are never reused, even if related:
# ancestry alone cannot prove checks on a later head. Project code owns check-set
# selection and trusted evidence collection (including every non-car main push).
# analysis-ready/test-finished require verified:true and terminal:true for ready,
# partial or red. The project verifier owns manifest/row/receipt/ledger joins;
# bind their exact identity and verifier policy/version into identity, not labels.
# Missing, malformed, contradictory, future-dated or stale evidence is unavailable.
# A revision's bytes cannot change and evidence time cannot go backwards.
#
# One registration per canonical identity per home; conflicting polling policy
# refuses rather than replacing subscribers. Machine-wide source claims in the
# process-event owner prevent two homes from polling the same identity: choose
# one owning home and consume its durable result, never start a competing source.
# Subscriptions and monotonic ack cursors are durable and generation-bound. Pending
# fans the SAME event documents to each subscriber; reading does not acknowledge.
# A different generation cannot inherit or reset a subscription implicitly;
# resubscribe moves it only from the exact current generation and keeps its
# cursor, so a relaunched consumer neither loses nor replays consumed events.
# The single ordinary process-event notification carries the shared result; consumers
# can use pending without agent courier turns. No worker lifecycle or action occurs.
#
# run is a blocking child, NEVER a conversational polling command. It journals
# transitions before returning them for capture; on restart it replays a journal
# event not yet present in the process-event inbox. Unchanged polls/revisions never
# notify. Red, ready, partial, unavailable and recovery notify; deadline expiry ends
# an unresolved observation, while an already ready observation closes silently.
# Only an expired observation may be re-armed, with a new future deadline and the
# same identity and receipt; it keeps its journal and subscribers and resumes as
# pending, so every renewal is an explicit bounded registration, never automatic.
# The existing runner owns capture, wake coalescing, restart and handled acks.
# A subscriber ack is consumption, not authority to merge, rerun, revert or launch.
# jq programs intentionally use literal dollar expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STORE="$STATE/observations"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
die() { printf 'observe: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
lock() {
  fm_procevent_source_id_valid "$1" || die 'invalid source'
  fm_procevent_source_lock_acquire "$1" || die 'source lock unavailable'
  trap 'fm_procevent_source_lock_release "$SID"' EXIT
}
load() {
  DB="$STORE/$SID.json"
  fm_pr_private_file_valid "$DB" 600 "$(fm_pr_file_device "$STORE")" || die 'observation unavailable or not private'
}
# All mutable observation state is one atomically replaced document under the
# same source lock as registration. Never advance a subscriber on mere delivery.
update() {
  local tmp
  tmp=$(umask 077; mktemp "$STORE/.update.XXXXXX")
  if ! jq "$@" "$DB" > "$tmp"; then rm -f "$tmp"; die 'invalid update'; fi
  mv -f "$tmp" "$DB"
}
valid_spec() {
  jq -e '
    def pos: type=="number" and .>0 and floor==.;
    .schema=="fm-observe-v1" and (.identity|type=="object") and
    (.identity.kind|IN("main-ci","receipt","analysis-ready","test-finished")) and
    (.receipt|type=="string" and length>0 and (startswith("/")|not) and (split("/")|all(.!=".." and .!=""))) and
    (.deadline|pos) and (.max_age|pos) and (.interval|pos) and
    (if .identity.kind=="main-ci" then
      (.identity.head|test("^[0-9a-f]{40}([0-9a-f]{24})?$")) and
      (.identity.attempt|pos) and
      (.identity.jobs|type=="array" and length>0 and all(type=="string" and length>0) and length==(unique|length))
    else true end)' "$1" >/dev/null
}
arm() {
  local spec=$1 canonical digest tmp
  valid_spec "$spec" || die 'invalid observation spec'
  canonical=$(jq -cS '.identity' "$spec")
  tmp=$(mktemp); printf '%s\n' "$canonical" > "$tmp"
  digest=$(fm_pr_sha256 "$tmp"); rm -f "$tmp"
  SID="obs-${digest:0:60}"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'state unavailable'
  (umask 077; mkdir -p "$STORE")
  [ ! -L "$STORE" ] || die 'observation directory is a symlink'
  lock "$SID"
  DB="$STORE/$SID.json"
  if [ -e "$DB" ]; then
    load
    if [ "$(jq -cS '.spec' "$DB")" != "$(jq -cS . "$spec")" ]; then
      [ "$(jq -r .status "$DB")" = expired ] || die 'identity already has a different spec'
      jq -e --slurpfile n "$spec" '.spec.receipt==$n[0].receipt' "$DB" >/dev/null || die 'identity already has a different receipt'
      [ "$(jq -r .deadline "$spec")" -gt "$(date +%s)" ] || die 'deadline already expired'
      update --slurpfile n "$spec" '.spec=$n[0] | .status="pending"'
    fi
  else
    [ "$(jq -r .deadline "$spec")" -gt "$(date +%s)" ] || die 'deadline already expired'
    tmp=$(umask 077; mktemp "$STORE/.arm.XXXXXX")
    jq '{spec:., status:"pending", revision:null, evidence:null, observed_at:0, events:[], subscribers:{}}' "$spec" > "$tmp"
    mv "$tmp" "$DB"
  fi
  case "$(jq -r .status "$DB")" in
    closed|expired) printf '%s\n' "$SID"; return ;;
  esac
  if [ ! -e "$STATE/procevent/$SID.source" ]; then
    fm_procevent_registration_publish_locked "$STATE" observe "$SID" "$SCRIPT_DIR/fm-procevent-observe.sh" run "$SID" || die 'registration failed; repeat arm to recover'
  fi
  printf '%s\n' "$SID"
}
subscription() {
  local op=$1 name=$2 gen=$3 event=${4:-0}
  if ! fm_task_id_path_safe "$name" || ! fm_task_id_path_safe "$gen"; then die 'invalid subscriber or generation'; fi
  lock "$SID"; load
  if [ "$op" = resubscribe ]; then
    fm_task_id_path_safe "$event" || die 'invalid new generation'
    jq -e --arg n "$name" --arg g "$gen" '.subscribers[$n].generation==$g' "$DB" >/dev/null || die 'subscriber is not at that generation'
    update --arg n "$name" --arg g "$event" '.subscribers[$n].generation=$g'
    return
  fi
  if jq -e --arg n "$name" '.subscribers|has($n)' "$DB" >/dev/null; then
    [ "$(jq -r --arg n "$name" '.subscribers[$n].generation' "$DB")" = "$gen" ] || die 'stale subscriber generation'
  elif [ "$op" = subscribe ]; then
    update --arg n "$name" --arg g "$gen" '.subscribers[$n]={generation:$g,cursor:0}'
  else die 'subscriber is not registered'; fi
  case "$op" in
    subscribe) ;;
    pending) jq --arg n "$name" '.subscribers[$n].cursor as $c | [.events[]|select(.event>$c)]' "$DB" ;;
    ack)
      [[ "$event" =~ ^[0-9]+$ ]] || die 'invalid event'
      jq -e --arg n "$name" --argjson e "$event" '.subscribers[$n].cursor <= $e and $e <= (.events|length)' "$DB" >/dev/null || die 'ack outside retained events'
      update --arg n "$name" --argjson e "$event" '.subscribers[$n].cursor=$e' ;;
  esac
}
# Evaluate one local receipt; source-specific interpretation remains at its producer.
evaluate() {
  local receipt=$1 spec=$2 now=$3
  jq -cn --slurpfile s "$spec" --slurpfile r "$receipt" --argjson now "$now" '
    $s[0].spec as $s | $r[0] as $r |
    if ($r|type)!="object" or $r.schema!="fm-evidence-v1" or $r.identity!=$s.identity or
       ($r.revision|type)!="string" or ($r.revision|length)==0 or
       ($r.observed_at|type)!="number" or $r.observed_at>$now or $r.observed_at<($now-$s.max_age) or
       ($r.status|IN("pending","ready","partial","red")|not) then "unavailable"
    elif $s.identity.kind=="main-ci" then
      if $r.head!=$s.identity.head or $r.attempt!=$s.identity.attempt or ($r.jobs|type)!="array" or
         ([$r.jobs[].name]|length)!=([$r.jobs[].name]|unique|length) or
         any($r.jobs[]; (.name|type)!="string" or (.status|IN("pending","success","failure")|not)) or
         any($s.identity.jobs[]; . as $n | [$r.jobs[]|select(.name==$n)]|length!=1)
      then "unavailable"
      elif any($r.jobs[]; . as $j | ($s.identity.jobs|index($j.name))!=null and $j.status=="failure") then "red"
      elif all($s.identity.jobs[]; . as $n | any($r.jobs[]; .name==$n and .status=="success")) then "ready"
      else "pending" end
    elif ($s.identity.kind|IN("analysis-ready","test-finished")) and $r.status!="pending" and
         ($r.verified!=true or $r.terminal!=true) then "unavailable"
    else $r.status end' 2>/dev/null || printf '"unavailable"\n'
}
# Keep the generic capture small even when the receipt/manifest is large.
# Consumers read the retained payload via pending/snapshot, not a truncated wake.
emit() { jq -c '{source,event,status,recovery,at}'; }
run() {
  local now status old event file captured receipt tmp evidence revision observed_at last_event
  while :; do
    lock "$SID"; load
    # Capture is the notification cursor. Journal-first publication closes the
    # source-side crash window without treating an emitted stdout as delivery.
    last_event=$(jq -c '.events[-1] // empty' "$DB")
    if [ -n "$last_event" ]; then
      event=$(printf '%s' "$last_event" | jq -r .event); captured=0
      for file in "$STATE/procevent-inbox/$SID".*.result; do
        [ -f "$file" ] || continue
        if jq -e --arg s "$SID" --argjson e "$event" '.source==$s and .event==$e' "$file" >/dev/null 2>&1; then captured=1; break; fi
      done
      if [ "$captured" = 0 ]; then printf '%s\n' "$last_event" | emit; return; fi
      # A re-armed observation is pending again; only a still-terminal one ends here.
      case "$(jq -r .status "$DB")" in expired|closed) printf '%s\n' "$last_event" | emit; return ;; esac
    fi
    now=$(date +%s); old=$(jq -r .status "$DB")
    receipt="$FM_HOME/$(jq -r .spec.receipt "$DB")"
    tmp=$(umask 077; mktemp "$STORE/.receipt.XXXXXX")
    # Bounded read: an accidentally huge receipt is unavailable, not a stuck poll.
    if [ -f "$receipt" ]; then head -c 1048577 "$receipt" > "$tmp" 2>/dev/null || true; fi
    evidence=null; revision=null; observed_at=0
    if [ "$(wc -c < "$tmp")" -gt 1048576 ]; then status=unavailable
    else status=$(evaluate "$tmp" "$DB" "$now" | jq -r .); fi
    if [ "$status" != unavailable ]; then
      evidence=$(jq -cS . "$tmp"); revision=$(jq -c .revision "$tmp"); observed_at=$(jq -r .observed_at "$tmp")
      if ! jq -e --argjson r "$revision" --argjson e "$evidence" --argjson t "$observed_at" '
        $t>=.observed_at and (.revision!=$r or .evidence==$e)' "$DB" >/dev/null; then status=unavailable; fi
    fi
    rm -f "$tmp"
    if [ "$now" -ge "$(jq -r .spec.deadline "$DB")" ]; then
      case "$old" in ready|partial) status=closed ;; *) status=expired ;; esac
    fi
    if [ "$status" != unavailable ] && [ "$evidence" != null ]; then
      update --argjson e "$evidence" --argjson r "$revision" --argjson t "$observed_at" '.evidence=$e | .revision=$r | .observed_at=$t'
    fi
    if [ "$status" != "$old" ]; then
      update --arg s "$SID" --arg status "$status" --arg old "$old" --argjson now "$now" '
        .status=$status | .events += [{source:$s,event:((.events|length)+1),status:$status,
        recovery:($old=="unavailable" or $old=="red"),at:$now,identity:.spec.identity,
        evidence:.evidence,subscribers:.subscribers}]'
      jq -c '.events[-1]' "$DB" | emit; return
    fi
    local interval
    interval=$(jq -r --argjson now "$now" '[.spec.interval, (.spec.deadline-$now)]|min' "$DB")
    fm_procevent_source_lock_release "$SID"; trap - EXIT
    sleep "$interval"
  done
}
case "${1:-}" in
  arm) [ "$#" = 2 ] || die 'arm requires spec'; arm "$2" ;;
  subscribe|resubscribe|pending|ack) op=$1; SID=${2:?}; shift 2; subscription "$op" "$@" ;;
  snapshot) SID=${2:?}; lock "$SID"; load; jq . "$DB" ;;
  run) SID=${2:?}; run ;;
  classify) jq -er .status "$2" ;;
  terminal) jq -e '.status=="expired" or .status=="closed"' "$2" >/dev/null ;;
  silent) jq -e '.status=="closed"' "$2" >/dev/null ;;
  -h|--help|'') usage ;;
  *) exit 1 ;;
esac
