#!/usr/bin/env bash
# fm-alert-store-lib.sh - read and write level-asserted alert stores.
#
# Sourced, never executed. docs/alert-store.md owns the store format
# (fm-alert-store/v1), the registration format (fm-alert-registration/v1), the
# projection rule and the adoption steps; this header owns only the functions.
#
# An alarm is an active entry in an owned store. The status-line blocker that
# wakes a supervisor is a projection of that entry: bin/fm-alert-store.sh tick
# re-posts every active entry missing from its status file's decision fold, and
# bin/fm-classify-lib.sh asks fm_alert_store_holds before a supersede note may
# close a blocker. Only clearing the entry, or an owner acknowledgement with an
# expiry, removes the projection.
#
# Read side (pure, no locks; safe inside the decision fold's subshells):
#   fm_alert_store_registrations <status-file>   registration files naming it
#   fm_alert_registration_read <reg-file>        sets FM_ALERT_REG_* or fails
#   fm_alert_store_holds <status-file> <key>     0 when a registered store holds
#                                                <key> active, or cannot be read
#   fm_alert_store_wanted <store> <now-epoch>    "<key>\t<reason>" per active,
#                                                unacknowledged entry
#   fm_alert_store_known_keys <store>            every key the store has named
#   fm_alert_store_ack_of <store> <key> <now>    "<by>\t<until>" of a valid ack
#   fm_alert_store_bad_acks <store> <now-epoch>  active keys with an invalid ack
# Write side (callers serialize with a lock; bin/fm-alert-store.sh does):
#   fm_alert_store_assert <store> <id> <key> <reason> [<kind>] [<subject>]
#   fm_alert_store_clear <store> <id> <key> <reason>
#   fm_alert_store_sync <store> <id> <wanted-file> <reason>
#   fm_alert_store_ack <store> <id> <key> <by> <seconds> <reason>
# Every reader and writer needs jq. A failure sets FM_ALERT_PROBLEM to one
# plain-language sentence and returns 1.

FM_ALERT_STORE_SCHEMA=fm-alert-store/v1
FM_ALERT_REGISTRATION_SCHEMA=fm-alert-registration/v1
FM_ALERT_STORE_EVENTS_MAX=500
FM_ALERT_ACK_MAX_SECONDS=604800
FM_ALERT_PROBLEM=

# The schemas a store may carry. tj-capacity-alerts/v1 is the shape this format
# generalises: it has no acks object, so it reads as a store nothing has
# acknowledged.
# shellcheck disable=SC2016  # $s is a jq variable.
_FM_ALERT_STORE_VALID='(.schema == "fm-alert-store/v1" or .schema == "tj-capacity-alerts/v1")
  and (.active | type) == "object"
  and ((.acks // {}) | type) == "object"
  and ((.events // []) | type) == "array"
  and ([.active | keys[] | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")] | all)'

# What an acknowledgement may hide, shared by every reader. An ack counts only
# when its at and until both parse, at is not in the future, and until is at
# most $max seconds after at; any other ack is unknown, so it hides nothing and
# the tick reports it (fm_alert_store_bad_acks). A store written by its own tool
# therefore cannot hide an alarm longer than the ack command could.
# shellcheck disable=SC2016  # $now, $max, $a and $u are jq variables.
_FM_ALERT_ACK_DEFS='def _ts: if type == "string" then (try fromdateiso8601 catch null) else null end;
def ack_valid($now; $max): (.at | _ts) as $a | (.until | _ts) as $u
  | $a != null and $u != null and $a <= $now and $u >= $a and ($u - $a) <= $max;
def ack_hides($now; $max): ack_valid($now; $max) and ((.until | _ts) > $now);
def ack_bad($now; $max): (ack_valid($now; $max) | not) and (((.until | _ts) // ($now + 1)) > $now);'

# 0 when <value> is a store id or alert key: the decision-key slug.
fm_alert_slug_ok() {  # <value>
  case "$1" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# The registration directory beside a status file: state/alert-stores/.
_fm_alert_registration_dir() {  # <status-file>
  local d=${1%/*}
  [ "$d" != "$1" ] || d=.
  printf '%s/alert-stores' "$d"
}

# Print every registration file in the status file's state directory. A
# registration's own status= line decides whether it names this file; that is
# fm_alert_registration_read's job, so this lists them all.
fm_alert_store_registrations() {  # <status-file>
  local dir reg
  dir=$(_fm_alert_registration_dir "$1")
  [ -d "$dir" ] || return 0
  for reg in "$dir"/*.reg; do
    # A dangling link is still a registration, an unreadable one, so it holds.
    [ -e "$reg" ] || [ -L "$reg" ] || continue
    printf '%s\n' "$reg"
  done
}

# Parse one registration. On success sets FM_ALERT_REG_STORE (the store id),
# FM_ALERT_REG_PATH (the absolute store path), FM_ALERT_REG_STATUS (the status
# file's name in the same state directory) and FM_ALERT_REG_OWNER.
fm_alert_registration_read() {  # <reg-file>
  local reg=$1 line schema='' name
  FM_ALERT_REG_STORE='' FM_ALERT_REG_PATH='' FM_ALERT_REG_STATUS='' FM_ALERT_REG_OWNER=''
  name=${reg##*/}
  name=${name%.reg}
  if [ -L "$reg" ] || [ ! -f "$reg" ] || [ ! -r "$reg" ]; then
    FM_ALERT_PROBLEM="registration $reg cannot be read"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*) schema=${line#schema=} ;;
      store=*) FM_ALERT_REG_STORE=${line#store=} ;;
      path=*) FM_ALERT_REG_PATH=${line#path=} ;;
      status=*) FM_ALERT_REG_STATUS=${line#status=} ;;
      owner=*) FM_ALERT_REG_OWNER=${line#owner=} ;;
    esac
  done < "$reg"
  if [ "$schema" != "$FM_ALERT_REGISTRATION_SCHEMA" ]; then
    FM_ALERT_PROBLEM="registration $reg is not $FM_ALERT_REGISTRATION_SCHEMA"
    return 1
  fi
  if [ "$FM_ALERT_REG_STORE" != "$name" ] || ! fm_alert_slug_ok "$FM_ALERT_REG_STORE"; then
    FM_ALERT_PROBLEM="registration $reg must name store=$name, a [A-Za-z0-9._-] id"
    return 1
  fi
  case "$FM_ALERT_REG_PATH" in
    /*) ;;
    *) FM_ALERT_PROBLEM="registration $reg needs an absolute path="; return 1 ;;
  esac
  case "$FM_ALERT_REG_STATUS" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) FM_ALERT_PROBLEM="registration $reg needs status=<name>.status in its own state directory"; return 1 ;;
    *.status) ;;
    *) FM_ALERT_PROBLEM="registration $reg needs status=<name>.status in its own state directory"; return 1 ;;
  esac
  [ -n "$FM_ALERT_REG_OWNER" ] || FM_ALERT_REG_OWNER=unnamed
  return 0
}

# 0 when the store at <path> parses as a known schema with usable objects.
fm_alert_store_readable() {  # <store>
  if ! command -v jq >/dev/null 2>&1; then
    FM_ALERT_PROBLEM="jq is not installed, so store $1 cannot be read"
    return 1
  fi
  if [ -L "$1" ] || [ ! -f "$1" ] || [ ! -r "$1" ]; then
    FM_ALERT_PROBLEM="store $1 is missing or unreadable"
    return 1
  fi
  if ! jq -e "$_FM_ALERT_STORE_VALID" "$1" >/dev/null 2>&1; then
    FM_ALERT_PROBLEM="store $1 is not a valid $FM_ALERT_STORE_SCHEMA (or tj-capacity-alerts/v1) store"
    return 1
  fi
  return 0
}

# The decision fold's question: may a supersede note close blocker <key> in
# <status-file>? 0 (keep it open) when a registration for this status file
# names a store whose active object holds <key>, and also when such a store
# cannot be read: unknown is failure, so an unreadable store never lets a
# relaunch mute what it may hold. An invalid registration is unknown too, unless
# its status line plainly names another status file. 1 when no registered store
# claims the key.
fm_alert_store_holds() {  # <status-file> <key>
  local f=$1 key=$2 base reg rc named
  base=${f##*/}
  [ -d "$(_fm_alert_registration_dir "$f")" ] || return 1
  while IFS= read -r reg; do
    [ -n "$reg" ] || continue
    if ! fm_alert_registration_read "$reg"; then
      named=$(sed -n 's/^status=//p' "$reg" 2>/dev/null | head -n 1)
      [ -n "$named" ] && [ "$named" != "$base" ] && continue
      return 0
    fi
    [ "$FM_ALERT_REG_STATUS" = "$base" ] || continue
    fm_alert_store_readable "$FM_ALERT_REG_PATH" || return 0
    rc=0
    jq -e --arg k "$key" '.active | has($k)' "$FM_ALERT_REG_PATH" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) ;;
      *) return 0 ;;
    esac
  done <<EOF
$(fm_alert_store_registrations "$f")
EOF
  return 1
}

# Print "<key>\t<reason>" for every active entry with no unexpired
# acknowledgement: the set the status file must show as open blockers.
fm_alert_store_wanted() {  # <store> <now-epoch>
  fm_alert_store_readable "$1" || return 1
  # shellcheck disable=SC2016  # jq variables.
  jq -r --argjson now "$2" --argjson max "$FM_ALERT_ACK_MAX_SECONDS" "$_FM_ALERT_ACK_DEFS"'
    (.acks // {}) as $acks
    | .active | to_entries[]
    | select(($acks[.key] // null) as $ack
        | $ack == null or (($ack | type) != "object") or (($ack | ack_hides($now; $max)) | not))
    | [.key, ((.value.reason // "") | tostring | gsub("[\r\n\t]+"; " "))] | @tsv' "$1" 2>/dev/null || {
    FM_ALERT_PROBLEM="store $1 could not be projected"
    return 1
  }
}

# Print every key the store has named: active, acknowledged, or in an event.
fm_alert_store_known_keys() {  # <store>
  fm_alert_store_readable "$1" || return 1
  jq -r '[(.active | keys[]), ((.acks // {}) | keys[]), ((.events // [])[] | .key? // empty | strings)] | unique[]' "$1" 2>/dev/null || {
    FM_ALERT_PROBLEM="store $1 keys could not be read"
    return 1
  }
}

# Print the ack that hides <key>, as "<by>\t<until>", when it is valid and
# unexpired.
fm_alert_store_ack_of() {  # <store> <key> <now-epoch>
  # shellcheck disable=SC2016  # jq variables.
  jq -r --arg k "$2" --argjson now "$3" --argjson max "$FM_ALERT_ACK_MAX_SECONDS" "$_FM_ALERT_ACK_DEFS"'
    (.acks // {})[$k] // empty
    | select(type == "object" and ack_hides($now; $max))
    | [((.by // "owner") | tostring), .until] | @tsv' "$1" 2>/dev/null
}

# Print every active key whose acknowledgement is not valid and would otherwise
# still be in force, one per line: the tick reports each one as a problem.
fm_alert_store_bad_acks() {  # <store> <now-epoch>
  # shellcheck disable=SC2016  # jq variables.
  jq -r --argjson now "$2" --argjson max "$FM_ALERT_ACK_MAX_SECONDS" "$_FM_ALERT_ACK_DEFS"'
    (.acks // {}) as $acks
    | .active | keys[]
    | select(($acks[.] // null) as $ack
        | $ack != null and ((($ack | type) != "object") or ($ack | ack_bad($now; $max))))' "$1" 2>/dev/null
}

# Apply one jq program to the store and replace it atomically. A missing store
# starts empty under <id>; an existing one must be a writable fm-alert-store/v1
# store, because a tj-capacity-alerts/v1 file belongs to the tool writing it.
_fm_alert_store_write() {  # <store> <id> <jq-program> [jq args...]
  local store=$1 id=$2 prog=$3 tmp now nowiso
  shift 3
  if ! command -v jq >/dev/null 2>&1; then
    FM_ALERT_PROBLEM="jq is not installed, so store $store cannot be written"
    return 1
  fi
  if [ -e "$store" ] || [ -L "$store" ]; then
    fm_alert_store_readable "$store" || return 1
    if ! jq -e --arg s "$FM_ALERT_STORE_SCHEMA" '.schema == $s' "$store" >/dev/null 2>&1; then
      FM_ALERT_PROBLEM="store $store is written by its own tool, not through this library"
      return 1
    fi
    if ! jq -e --arg id "$id" '.store == $id' "$store" >/dev/null 2>&1; then
      FM_ALERT_PROBLEM="store $store does not belong to store id $id"
      return 1
    fi
  fi
  now=$(date +%s) || return 1
  nowiso=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  tmp=$(mktemp "${store%/*}/.${store##*/}.XXXXXX" 2>/dev/null) || {
    FM_ALERT_PROBLEM="cannot create a temporary file beside $store"
    return 1
  }
  # shellcheck disable=SC2016  # jq variables.
  if ! { if [ -f "$store" ]; then cat -- "$store"; else printf 'null'; fi; } \
    | jq --arg id "$id" --arg now "$nowiso" --argjson nowepoch "$now" \
        --argjson max "$FM_ALERT_STORE_EVENTS_MAX" "$@" '
      (. // {schema: "fm-alert-store/v1", store: $id, at: $now, revision: 0,
             active: {}, acks: {}, events: []})
      | .at = $now
      | .acks = ((.acks // {}) | with_entries(select((.value.until | fromdateiso8601? // 0) > $nowepoch)))
      | '"$prog"'
      | .events = (.events[-$max:])' > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    FM_ALERT_PROBLEM="${FM_ALERT_PROBLEM:-the update to $store was refused}"
    return 1
  fi
  if ! mv -f -- "$tmp" "$store"; then
    rm -f -- "$tmp"
    FM_ALERT_PROBLEM="cannot replace $store"
    return 1
  fi
}

# Raise <key> (a no-op beyond refreshing detected_at and reason when it is
# already active: one cause raises once).
fm_alert_store_assert() {  # <store> <id> <key> <reason> [<kind>] [<subject>]
  local key=$3
  FM_ALERT_PROBLEM=
  fm_alert_slug_ok "$key" || { FM_ALERT_PROBLEM="alert key '$key' is not a [A-Za-z0-9._-] slug"; return 1; }
  # shellcheck disable=SC2016  # jq variables.
  _fm_alert_store_write "$1" "$2" '
    if .active[$key] then
      .active[$key].reason = $reason | .active[$key].detected_at = $now
    else
      .revision += 1
      | .active[$key] = {key: $key, kind: $kind, subject: $subject, reason: $reason,
                         since: $now, detected_at: $now, evidence: {}}
      | .events += [{seq: .revision, at: $now, action: "raised", key: $key, alert: .active[$key]}]
    end' --arg key "$key" --arg reason "$4" --arg kind "${5:-$key}" --arg subject "${6:-}"
}

# Clear <key> and any acknowledgement of it; clearing an inactive key is a no-op.
fm_alert_store_clear() {  # <store> <id> <key> <reason>
  local key=$3
  FM_ALERT_PROBLEM=
  fm_alert_slug_ok "$key" || { FM_ALERT_PROBLEM="alert key '$key' is not a [A-Za-z0-9._-] slug"; return 1; }
  # shellcheck disable=SC2016  # jq variables.
  _fm_alert_store_write "$1" "$2" '
    if .active[$key] then
      .revision += 1
      | .events += [{seq: .revision, at: $now, action: "cleared", key: $key,
                     reason: $reason, alert: .active[$key]}]
      | del(.active[$key]) | del(.acks[$key])
    else . end' --arg key "$key" --arg reason "$4"
}

# Make the store's active set equal <wanted-file> in one write: a JSON object
# mapping each key to {kind, subject, reason, since, evidence}. A new key is
# raised with that since and evidence, an active key refreshes its reason,
# evidence and detected_at as assert does, and an active key absent from the
# file is cleared with <reason>. For a tool that computes its whole alarm set
# each pass and owns every key in its store.
fm_alert_store_sync() {  # <store> <id> <wanted-file> <reason>
  FM_ALERT_PROBLEM=
  if ! jq -e 'type == "object" and ([keys[] | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")] | all)
      and ([.[] | type == "object" and (.reason | type) == "string"] | all)' "$3" >/dev/null 2>&1; then
    FM_ALERT_PROBLEM="wanted set $3 is not an object of slug keys with a reason each"
    return 1
  fi
  # shellcheck disable=SC2016  # jq variables.
  _fm_alert_store_write "$1" "$2" '
    reduce ($want[0] | to_entries[]) as $e (.;
      if .active[$e.key] then
        .active[$e.key].reason = $e.value.reason | .active[$e.key].detected_at = $now
        | .active[$e.key].evidence = ($e.value.evidence // .active[$e.key].evidence)
      else
        .revision += 1
        | .active[$e.key] = {key: $e.key, kind: ($e.value.kind // $e.key), subject: ($e.value.subject // ""),
                             reason: $e.value.reason, since: ($e.value.since // $now),
                             detected_at: $now, evidence: ($e.value.evidence // {})}
        | .events += [{seq: .revision, at: $now, action: "raised", key: $e.key, alert: .active[$e.key]}]
      end)
    | reduce (.active | keys[] | select(. as $k | $want[0] | has($k) | not)) as $k (.;
      .revision += 1
      | .events += [{seq: .revision, at: $now, action: "cleared", key: $k, reason: $reason, alert: .active[$k]}]
      | del(.active[$k]) | del(.acks[$k]))' --slurpfile want "$3" --arg reason "$4"
}

# Acknowledge active <key> for <seconds> (1 to FM_ALERT_ACK_MAX_SECONDS). The
# entry stays active; the projection hides it until the expiry, then re-asserts.
fm_alert_store_ack() {  # <store> <id> <key> <by> <seconds> <reason>
  local key=$3 secs=$5
  FM_ALERT_PROBLEM=
  fm_alert_slug_ok "$key" || { FM_ALERT_PROBLEM="alert key '$key' is not a [A-Za-z0-9._-] slug"; return 1; }
  case "$secs" in
    ''|*[!0-9]*|0*) FM_ALERT_PROBLEM="an acknowledgement needs an expiry of 1 to $FM_ALERT_ACK_MAX_SECONDS seconds"; return 1 ;;
  esac
  if [ "${#secs}" -gt 7 ] || [ "$secs" -gt "$FM_ALERT_ACK_MAX_SECONDS" ]; then
    FM_ALERT_PROBLEM="an acknowledgement needs an expiry of 1 to $FM_ALERT_ACK_MAX_SECONDS seconds"
    return 1
  fi
  if [ ! -f "$1" ] || ! jq -e --arg k "$key" '.active | has($k)' "$1" >/dev/null 2>&1; then
    FM_ALERT_PROBLEM="alert $key is not active in $1, so there is nothing to acknowledge"
    return 1
  fi
  # shellcheck disable=SC2016  # jq variables.
  _fm_alert_store_write "$1" "$2" '
    .revision += 1
    | .acks[$key] = {by: $by, reason: $reason, at: $now,
                     until: (($nowepoch + $secs) | todate)}
    | .events += [{seq: .revision, at: $now, action: "acked", key: $key, ack: .acks[$key]}]' \
    --arg key "$key" --arg by "$4" --argjson secs "$secs" --arg reason "$6"
}
