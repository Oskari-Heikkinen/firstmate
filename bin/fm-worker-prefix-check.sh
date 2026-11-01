#!/usr/bin/env bash
# fm-worker-prefix-check.sh - compare a new Claude worker's first-turn prompt
# prefix with the size this home expects, and raise one alert when it is over.
#
# Usage:
#   fm-worker-prefix-check.sh <home> <state-dir> <config-dir> <task-id> <project> < <stop-hook-json>
#
# bin/fm-spawn.sh installs this as a ship or scout Claude worker's second Stop
# hook, behind a test for state/<task-id>.prefix-checked, so it runs at the end
# of the worker's turns until it reaches a verdict and never again for that
# launch; a launch or relaunch removes the marker. docs/configuration.md
# "Worker prompt prefix" owns the operator contract and config/worker-prefix-size;
# docs/verification/runtime-backends.md records the transcript fields read.
#
# It reads transcript_path from the hook's JSON on stdin and the first
# assistant record of that transcript: the prefix is that record's
# message.usage input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens, the whole prompt of the worker's first model call.
# A transcript with no assistant record yet leaves no verdict, so the next Stop
# tries again. Every verdict appends one line to state/worker-prefix/log and
# sets the store state/worker-prefix/alerts.json (store id worker-prefix,
# registered against state/worker-prefix.status) to it:
#   over    prefix > expected + margin: raises worker-prefix-over-<project>
#   within  clears worker-prefix-over-<project>
#   unread  no readable transcript, or a first record without numeric usage:
#           raises worker-prefix-unread-<project>
# over and within also clear worker-prefix-unread-<project>. A
# config/worker-prefix-size the parser refuses raises worker-prefix-config and
# the check uses the built-in size; a readable file clears it.
#
# Exit status: 0 verdict recorded or not yet due, 1 the verdict could not be
# recorded (the marker stays absent so the next Stop tries again), 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WORKER_PREFIX_EXPECTED_DEFAULT=20000
FM_WORKER_PREFIX_MARGIN_DEFAULT=5000

[ "$#" -eq 5 ] || {
  echo "usage: fm-worker-prefix-check.sh <home> <state-dir> <config-dir> <task-id> <project> < <stop-hook-json>" >&2
  exit 2
}
HOME_DIR=$1 STATE=$2 CONFIG=$3 ID=$4 PROJECT=$5
MARKER="$STATE/$ID.prefix-checked"
DIR="$STATE/worker-prefix"
STORE="$DIR/alerts.json"
STORE_ID=worker-prefix
STATUS_NAME=worker-prefix.status
[ ! -e "$MARKER" ] || exit 0

# Keys are status decision-key slugs, so the project name is folded into one.
SLUG=$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9._-' '-')
[ -n "$SLUG" ] || SLUG=unnamed
KEY_OVER="worker-prefix-over-$SLUG"
KEY_UNREAD="worker-prefix-unread-$SLUG"
KEY_CONFIG=worker-prefix-config

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
# default, # comments). Non-zero with CONFIG_PROBLEM set when the file is
# unreadable or an entry is malformed or repeated; the built-in size stays set.
read_size() {
  local file="$CONFIG/worker-prefix-size" line scope expected margin rest n=0 seen=' '
  local def_e='' def_m='' own_e='' own_m=''
  EXPECTED=$FM_WORKER_PREFIX_EXPECTED_DEFAULT MARGIN=$FM_WORKER_PREFIX_MARGIN_DEFAULT CONFIG_PROBLEM=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    CONFIG_PROBLEM="config/worker-prefix-size is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    read -r scope expected margin rest <<<"$line"
    [ -n "${scope:-}" ] || continue
    case "$expected:$margin" in
    *[!0-9:]* | :* | *:) CONFIG_PROBLEM="config/worker-prefix-size line $n is not '<scope> <expected-tokens> <margin-tokens>' with whole numbers" ;;
    esac
    [ -z "$rest" ] || CONFIG_PROBLEM="config/worker-prefix-size line $n has more than three fields"
    [ -z "${scope//[A-Za-z0-9._-]/}" ] || CONFIG_PROBLEM="config/worker-prefix-size line $n has a scope that is not a project name"
    case "$seen" in *" $scope "*) CONFIG_PROBLEM="config/worker-prefix-size line $n repeats the scope $scope" ;; esac
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
  if [ -n "$own_e" ]; then
    EXPECTED=$own_e MARGIN=$own_m
  elif [ -n "$def_e" ]; then
    EXPECTED=$def_e MARGIN=$def_m
  fi
}

# first_usage <transcript>: print "<prefix-tokens> <version>" from the first
# assistant record, "bad" when that record has no numeric usage, nothing when
# there is no assistant record yet. Lines that are not JSON (a partly written
# tail) are skipped, and the read stops at the first assistant record.
first_usage() {
  jq -nrR '
    first(inputs | fromjson? | select(type == "object" and .type == "assistant"))
    | (.message.usage // {}) as $u
    | if ([$u.input_tokens, ($u.cache_creation_input_tokens // 0), ($u.cache_read_input_tokens // 0)] | all(type == "number"))
      then "\($u.input_tokens + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) \(.version // "unknown" | tostring | gsub("[^A-Za-z0-9._-]"; "?"))"
      else "bad" end
  ' <"$1"
}

hook=$(cat)
transcript=$(printf '%s' "$hook" | jq -r '.transcript_path // empty | strings' 2>/dev/null) || transcript=
prefix='' version=unknown verdict='' why=''
if [ -z "$transcript" ]; then
  verdict=unread why="the Stop hook input names no transcript_path"
elif [ ! -r "$transcript" ]; then
  verdict=unread why="the transcript $transcript cannot be read"
elif ! usage=$(first_usage "$transcript" 2>/dev/null); then
  verdict=unread why="the transcript $transcript cannot be parsed"
elif [ -z "$usage" ]; then
  exit 0
elif [ "$usage" = bad ]; then
  verdict=unread why="the first assistant record in $transcript carries no numeric usage"
else
  prefix=${usage%% *} version=${usage#* }
fi

mkdir -p "$DIR" || exit 1
register || exit 1
if read_size; then
  alert clear "$KEY_CONFIG" "config/worker-prefix-size reads again" || exit 1
else
  alert assert "$KEY_CONFIG" "$CONFIG_PROBLEM; worker prefix checks use the built-in $EXPECTED tokens with a $MARGIN margin until it is fixed" "$KEY_CONFIG" || exit 1
fi
if [ -z "$verdict" ]; then
  if [ "$prefix" -gt $((EXPECTED + MARGIN)) ]; then
    verdict=over
    alert assert "$KEY_OVER" "worker $ID ($PROJECT, claude $version) started with a $prefix-token prompt prefix, over the expected $EXPECTED by more than $MARGIN; compare its settings and loaded skills with docs/configuration.md \"Worker prompt prefix\"" "worker-prefix-over" || exit 1
  else
    verdict=within
    alert clear "$KEY_OVER" "worker $ID ($PROJECT, claude $version) started within $MARGIN of the expected $EXPECTED tokens ($prefix)" || exit 1
  fi
  alert clear "$KEY_UNREAD" "worker $ID's first-turn usage was read" || exit 1
else
  alert assert "$KEY_UNREAD" "worker $ID ($PROJECT): $why, so its prompt prefix size is unknown" "worker-prefix-unread" || exit 1
fi
printf '%s %s project=%s claude=%s prefix=%s expected=%s margin=%s verdict=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$PROJECT" "$version" "${prefix:-?}" "$EXPECTED" "$MARGIN" "$verdict" >>"$DIR/log" || exit 1
: >"$MARKER" || exit 1
