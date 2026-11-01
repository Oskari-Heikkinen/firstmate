#!/usr/bin/env bash
# fm-worker-prefix-check.sh - compare a new Claude worker's first-turn prompt
# prefix with the size this home expects, and raise one alert when it is over.
#
# Usage:
#   fm-worker-prefix-check.sh <home> <state-dir> <config-dir> <task-id> <project> < <hook-json>
#
# bin/fm-spawn.sh installs this as a ship or scout Claude worker's Stop,
# UserPromptSubmit and SessionEnd hook, behind a test for
# state/<task-id>.prefix-checked, so it runs at those points until it reaches
# a verdict and never again for that launch; a launch or relaunch removes the
# marker. Claude can run the Stop hooks before the turn's reply is in the
# transcript, so the next prompt or the session's end checks that reply. docs/configuration.md
# "Worker prompt prefix" owns the operator contract and config/worker-prefix-size;
# docs/verification/runtime-backends.md records the transcript fields read.
#
# It reads transcript_path from the hook's JSON on stdin and the first
# assistant record of that transcript: the prefix is that record's
# message.usage input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens, the whole prompt of the worker's first model call.
# Each must be a whole number from 0 to 999999999 (the cache counters may be
# absent or null). A transcript with no assistant record yet, or only a
# partly written last line, leaves no verdict, so the next hook tries again;
# so does a transcript that does not exist yet at a UserPromptSubmit, since a
# session's first prompt can come before Claude creates it.
# Every verdict appends one line to state/worker-prefix/log and sets the store
# state/worker-prefix/alerts.json (store id worker-prefix, registered against
# state/worker-prefix.status) to it:
#   over      prefix > expected + margin: raises worker-prefix-over-<project>
#   within    clears worker-prefix-over-<project>
#   unjudged  config/worker-prefix-size is refused, so there is no size to
#             compare with: leaves worker-prefix-over-<project> as it is
#   unread    the hook input is not JSON or names no transcript, the transcript
#             is not a readable regular file (other than not yet existing at a
#             UserPromptSubmit), a complete line before its first
#             assistant record is not JSON, or that record has no valid usage:
#             raises worker-prefix-unread-<project>
# over, within and unjudged also clear worker-prefix-unread-<project>. A
# config/worker-prefix-size that is present but not a readable regular file,
# holds a NUL byte, lists no size, or has a bad line raises worker-prefix-config;
# a readable file, or none, clears it.
#
# When the check cannot finish (its state cannot be created, the store cannot
# be registered or set, or the log or marker cannot be written), it appends
# one direct `blocked [key=worker-prefix-check-<task-id>]` line to
# state/worker-prefix.status, unless that worker's key is already open there,
# and the marker stays absent so the next hook tries again; that worker's next
# finished check appends the matching resolved line. The key is per worker, so
# one worker's open failure neither hides nor is resolved by another's.
#
# Exit status: 0 verdict recorded or not yet due, 1 the check could not finish
# and that is recorded, 2 usage, 3 the check could not finish and not even that
# could be recorded (the hook's own fallback then records it).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WORKER_PREFIX_EXPECTED_DEFAULT=20000
FM_WORKER_PREFIX_MARGIN_DEFAULT=5000

[ "$#" -eq 5 ] || {
  echo "usage: fm-worker-prefix-check.sh <home> <state-dir> <config-dir> <task-id> <project> < <hook-json>" >&2
  exit 2
}
HOME_DIR=$1 STATE=$2 CONFIG=$3 ID=$4 PROJECT=$5
MARKER="$STATE/$ID.prefix-checked"
DIR="$STATE/worker-prefix"
STORE="$DIR/alerts.json"
STORE_ID=worker-prefix
STATUS_NAME=worker-prefix.status
[ ! -f "$MARKER" ] || exit 0

# Keys are status decision-key slugs, so the project name is folded into one.
SLUG=$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9._-' '-')
[ -n "$SLUG" ] || SLUG=unnamed
KEY_OVER="worker-prefix-over-$SLUG"
KEY_UNREAD="worker-prefix-unread-$SLUG"
KEY_CONFIG=worker-prefix-config
# The hook's fallback (fm_worker_prefix_hook_command in
# bin/fm-worker-prefix-lib.sh) writes this key too.
KEY_CHECK="worker-prefix-check-$ID"

# check_open: zero when this worker's last [key=$KEY_CHECK] line of the status
# file is blocked, one when it is not or there is none, two when the file
# cannot be read.
check_open() {
  local last
  last=$(grep -F "[key=$KEY_CHECK]" "$STATE/$STATUS_NAME" 2>/dev/null)
  case $? in
  0) ;;
  1) return 1 ;;
  *) [ ! -e "$STATE/$STATUS_NAME" ] && return 1 || return 2 ;;
  esac
  case "${last##*$'\n'}" in blocked*) return 0 ;; esac
  return 1
}

status_line() {  # <line>
  "$SCRIPT_DIR/fm-worker-status.sh" "$STATE/$STATUS_NAME" "$CONFIG" "$1" >/dev/null 2>&1
}

# fail <reason>: record that this check could not finish, once while the key
# stays open, and exit 1, or 3 when even that record fails.
fail() {
  check_open && exit 1
  status_line "blocked [key=$KEY_CHECK] [at=<epoch>]: $KEY_CHECK: the prompt-prefix check for worker $ID ($PROJECT) could not finish: $1; it retries at the worker's next turn end" || exit 3
  exit 1
}

alert() {  # assert|clear <key> <reason> [kind]
  FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-alert-store.sh" "$1" "$STORE" "$STORE_ID" "$2" "$3" ${4:+"$4"} ${4:+"$PROJECT"} >/dev/null
}

# Bind the store to state/worker-prefix.status through fm-alert-store.sh
# register, only when the registration differs, so the alert-store log records
# only a real change.
register() {
  local reg="$STATE/alert-stores/$STORE_ID.reg" want cur=''
  want="schema=fm-alert-registration/v1
store=$STORE_ID
path=$STORE
status=$STATUS_NAME
owner=fm-worker-prefix-check"
  [ -e "$STATE/$STATUS_NAME" ] || : >>"$STATE/$STATUS_NAME" || return 1
  [ ! -f "$reg" ] || cur=$(cat "$reg" 2>/dev/null)
  [ "$cur" != "$want" ] || return 0
  FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
    "$SCRIPT_DIR/fm-alert-store.sh" register "$STORE" "$STORE_ID" "$STATUS_NAME" fm-worker-prefix-check >/dev/null
}

# read_size: set EXPECTED and MARGIN for $PROJECT from config/worker-prefix-size
# ("<scope> <expected-tokens> <margin-tokens>" lines, scope a project name or
# default, # comments; expected 1 to 999999999, margin 0 to 999999999). Only a
# missing file takes the built-in size. Non-zero with CONFIG_PROBLEM set when
# the file is not a readable regular file, holds a NUL byte (which read would
# drop silently), lists no size, or has a malformed or repeated entry.
read_size() {
  local file="$CONFIG/worker-prefix-size" line scope expected margin rest n=0 seen=' ' all kept
  local def_e='' def_m='' own_e='' own_m=''
  EXPECTED=$FM_WORKER_PREFIX_EXPECTED_DEFAULT MARGIN=$FM_WORKER_PREFIX_MARGIN_DEFAULT CONFIG_PROBLEM=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    CONFIG_PROBLEM="config/worker-prefix-size is not a readable regular file"
    return 1
  fi
  if ! { all=$(wc -c <"$file") && kept=$(tr -d '\000' <"$file" | wc -c) && [ "$all" -eq "$kept" ]; } 2>/dev/null; then
    CONFIG_PROBLEM="config/worker-prefix-size cannot be read or holds a NUL byte"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    scope='' expected='' margin='' rest=''
    read -r scope expected margin rest <<<"$line"
    [ -n "$scope" ] || continue
    if [ -n "$rest" ]; then
      CONFIG_PROBLEM="config/worker-prefix-size line $n has more than three fields"
    elif [ -z "$expected" ] || [ -z "$margin" ] || [ -n "${expected//[0-9]/}" ] || [ -n "${margin//[0-9]/}" ]; then
      CONFIG_PROBLEM="config/worker-prefix-size line $n is not '<scope> <expected-tokens> <margin-tokens>' with two whole numbers"
    elif [ "${#expected}" -gt 9 ] || [ "${#margin}" -gt 9 ]; then
      CONFIG_PROBLEM="config/worker-prefix-size line $n has a number over 999999999"
    elif [ "$((10#$expected))" -lt 1 ]; then
      CONFIG_PROBLEM="config/worker-prefix-size line $n expects 0 tokens; the expected size is at least 1"
    elif [ -n "${scope//[A-Za-z0-9._-]/}" ]; then
      CONFIG_PROBLEM="config/worker-prefix-size line $n has a scope that is not a project name"
    else
      case "$seen" in *" $scope "*) CONFIG_PROBLEM="config/worker-prefix-size line $n repeats the scope $scope" ;; esac
    fi
    [ -z "$CONFIG_PROBLEM" ] || return 1
    seen+="$scope "
    expected=$((10#$expected)) margin=$((10#$margin))
    if [ "$scope" = default ]; then
      def_e=$expected def_m=$margin
    elif [ "$scope" = "$PROJECT" ]; then
      own_e=$expected own_m=$margin
    fi
  done <"$file" || {
    CONFIG_PROBLEM="config/worker-prefix-size cannot be read"
    return 1
  }
  if [ "$seen" = ' ' ]; then
    CONFIG_PROBLEM="config/worker-prefix-size lists no size"
    return 1
  fi
  if [ -n "$own_e" ]; then
    EXPECTED=$own_e MARGIN=$own_m
  elif [ -n "$def_e" ]; then
    EXPECTED=$def_e MARGIN=$def_m
  fi
}

# first_usage <transcript> <complete-lines>: print "<prefix-tokens> <version>"
# from the first assistant record, "bad" when that record has no valid usage,
# "corrupt <n>" when complete line n before it is not JSON, nothing when there
# is no assistant record yet. Only a line past <complete-lines>, which had no
# newline when they were counted, may be a partly written tail and is skipped.
# The read stops at the first assistant record.
first_usage() {
  jq -nrR --argjson complete "$2" '
    def count: type == "number" and . >= 0 and . <= 999999999 and . == floor;
    first(
      foreach inputs as $l (0; . + 1; [., $l])
      | .[0] as $i
      | .[1]
      | select(test("^\\s*$") | not)
      | (try (fromjson | [.]) catch []) as $r
      | if $r == [] then (if $i <= $complete then ["corrupt", $i] else empty end)
        elif ($r[0] | type == "object" and .type == "assistant") then ["record", $r[0]]
        else empty end
    )
    | if .[0] == "corrupt" then "corrupt \(.[1])"
      else .[1]
      | ((.message // null) | if type == "object" then .usage else null end) as $u
      | if ($u | type) != "object" then "bad"
        else [$u.input_tokens, ($u.cache_creation_input_tokens | if . == null then 0 else . end),
              ($u.cache_read_input_tokens | if . == null then 0 else . end)] as $c
        | if ($c | all(count))
          then "\($c | add) \(.version // "unknown" | tostring | gsub("[^A-Za-z0-9._-]"; "?"))"
          else "bad" end
        end
      end
  ' <"$1"
}

hook=$(cat)
prefix='' version=unknown verdict='' why='' lines=''
if ! transcript=$(printf '%s' "$hook" | jq -r '.transcript_path // empty | strings' 2>/dev/null); then
  verdict=unread why="the hook input is not JSON"
elif [ -z "$transcript" ]; then
  verdict=unread why="the hook input names no transcript_path"
elif [ ! -e "$transcript" ] && [ ! -L "$transcript" ] &&
  [ "$(printf '%s' "$hook" | jq -r '.hook_event_name // empty | strings' 2>/dev/null)" = UserPromptSubmit ]; then
  # A session's first prompt can come before Claude creates its transcript.
  exit 0
elif [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
  # Tested before any open, so a FIFO or device never blocks the hook.
  verdict=unread why="the transcript $transcript is not a readable regular file"
elif ! lines=$(wc -l <"$transcript" 2>/dev/null) || ! lines=${lines//[!0-9]/} || [ -z "$lines" ] ||
  ! usage=$(first_usage "$transcript" "$lines" 2>/dev/null); then
  verdict=unread why="the transcript $transcript cannot be parsed"
elif [ -z "$usage" ]; then
  exit 0
elif [ "$usage" = bad ]; then
  verdict=unread why="the first assistant record in $transcript has no input, cache-creation and cache-read token counts that are whole numbers from 0 to 999999999"
elif [ "${usage%% *}" = corrupt ]; then
  verdict=unread why="line ${usage#* } of $transcript, before its first assistant record, is not JSON"
else
  prefix=${usage%% *} version=${usage#* }
fi

mkdir -p "$DIR" 2>/dev/null || fail "cannot create $DIR"
register || fail "cannot register the alert store $STORE against $STATE/$STATUS_NAME"
config_ok=1
read_size || config_ok=
if [ -n "$config_ok" ]; then
  alert clear "$KEY_CONFIG" "config/worker-prefix-size reads again" || fail "cannot clear $KEY_CONFIG in $STORE"
else
  alert assert "$KEY_CONFIG" "$CONFIG_PROBLEM; worker prompt-prefix sizes go unjudged until it is fixed" "$KEY_CONFIG" ||
    fail "cannot raise $KEY_CONFIG in $STORE"
fi
if [ -z "$verdict" ]; then
  limit=$((EXPECTED + MARGIN))
  if [ -z "$config_ok" ]; then
    verdict=unjudged EXPECTED='?' MARGIN='?'
  elif [ "$prefix" -gt "$limit" ] 2>/dev/null; then
    verdict=over
    alert assert "$KEY_OVER" "worker $ID ($PROJECT, claude $version) started with a $prefix-token prompt prefix, over the expected $EXPECTED by more than $MARGIN; compare its settings and loaded skills with docs/configuration.md \"Worker prompt prefix\"" "worker-prefix-over" ||
      fail "cannot raise $KEY_OVER in $STORE"
  elif [ "$prefix" -le "$limit" ] 2>/dev/null; then
    verdict=within
    alert clear "$KEY_OVER" "worker $ID ($PROJECT, claude $version) started within $MARGIN of the expected $EXPECTED tokens ($prefix)" ||
      fail "cannot clear $KEY_OVER in $STORE"
  else
    verdict=unread why="the prompt size $prefix cannot be compared with $limit"
  fi
fi
if [ "$verdict" = unread ]; then
  alert assert "$KEY_UNREAD" "worker $ID ($PROJECT): $why, so its prompt prefix size is unknown" "worker-prefix-unread" ||
    fail "cannot raise $KEY_UNREAD in $STORE"
else
  alert clear "$KEY_UNREAD" "worker $ID's first-turn usage was read" || fail "cannot clear $KEY_UNREAD in $STORE"
fi
printf '%s %s project=%s claude=%s prefix=%s expected=%s margin=%s verdict=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$PROJECT" "$version" "${prefix:-?}" "$EXPECTED" "$MARGIN" "$verdict" \
  2>/dev/null >>"$DIR/log" || fail "cannot append to $DIR/log"
: 2>/dev/null >"$MARKER" || fail "cannot write $MARKER"
# A resolve that fails takes the marker back, so the next hook retries it.
check_open
case $? in
0) status_line "resolved [key=$KEY_CHECK] [at=<epoch>]: $KEY_CHECK: the prompt-prefix check for worker $ID ($PROJECT) finished" ||
  { rm -f "$MARKER"; fail "cannot resolve $KEY_CHECK in $STATE/$STATUS_NAME"; } ;;
2) rm -f "$MARKER"; fail "cannot read $STATE/$STATUS_NAME" ;;
esac
