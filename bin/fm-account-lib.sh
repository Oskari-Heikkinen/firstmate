# shellcheck shell=bash
# Subscription account registry, per-account usage, and spawn account choice.
# Usage: . bin/fm-account-lib.sh   (callers set their own CONFIG and STATE dirs)
#
# This file is the single owner of the account contract; docs/configuration.md
# "Subscription accounts" is its operator reference and bin/fm-account.sh is its
# command surface.
#
# Registry: config/accounts, one account per non-empty, non-comment line:
#   <name> <provider> <login-folder> [<priority>]
# <name> is lowercase [a-z0-9._-]; <provider> is claude or codex; <login-folder>
# is absolute or ~/-relative with no whitespace (Claude's CLAUDE_CONFIG_DIR,
# Codex's CODEX_HOME); <priority> is a non-negative integer, lower first,
# default 100, ties keeping file order. Only Claude accounts are ever chosen for
# a launch; other providers are shown with their usage and never switched.
# Nothing here reads, copies, or prints a credential: usage comes from
# quota-axi's --profile-only read of the one login folder, whose output is
# redacted, and only the folder's existence is ever tested directly. When that
# read says a Claude login needs sign-in or is rate limited, one more read of
# the same folder classifies it (quota-axi --no-credential-refresh, with
# CLAUDE_CODE_OAUTH_TOKEN unset so no env token answers for the folder), and
# only its status and authStatus are used, never its usage numbers: a lapsed
# access token that still holds a refresh token is status expired (it renews
# on next use), not a sign-out.
#
# Floor: config/account-floor, one integer percent 0-100 (default 10). A Claude
# account whose known effective percent left is below the floor is low; unknown
# usage is never treated as low, so a failed read never moves work.
#
# Spawn choice (fm_account_resolve_spawn), Claude launches only, first match:
#   1. FM_SPAWN_ACCOUNT=<name>, the explicit switch bin/fm-account.sh passes
#      through bin/fm-control.sh to a relaunch.
#   2. A secondmate launch: that home's config/account pin, written by
#      `fm-account.sh use`; a relaunch or respawn keeps it.
#   3. A ship or scout relaunch: the account= its task record already carries.
#   4. A fresh ship or scout spawn: this home's config/spawn-account, else its
#      config/account, else the registered account whose folder is the
#      launcher's own CLAUDE_CONFIG_DIR - then, when that choice is low, the
#      first registered Claude account with known room at or above the floor.
# A named account that is not registered, or not Claude, or whose folder is
# missing, refuses rather than silently launching on another login. With no
# registry and no FM_SPAWN_ACCOUNT the launch is unchanged: the launcher's own
# CLAUDE_CONFIG_DIR is forwarded exactly as before.
#
# Usage cache: state/.account-usage-<name>, one |-separated line written only
# here: <epoch>|<status>|<percent-left>|<reset-epoch>|<runway-seconds>|<plan>.
# FM_ACCOUNT_USAGE_TTL (seconds, default 120) bounds its age;
# FM_ACCOUNT_QUOTA_TIMEOUT (seconds, default 20) bounds one quota-axi read.
#
# Sign-in streak: state/.account-signin-<name>, one line "<first-epoch>|<count>"
# written only here at each real read. A read of auth_required or
# missing-folder counts it up, fresh or expired removes it, and any other
# status (rate_limited, error, unreadable) leaves it alone. A login is
# confirmed as needing sign-in (fm_account_signin_confirmed) only after at
# least 3 counted reads spanning FM_ACCOUNT_SIGNIN_CONFIRM_SECS (default 900).

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_NAME_RE='^[a-z0-9][a-z0-9._-]*$'
FM_ACCOUNT_DEFAULT_PRIORITY=100
FM_ACCOUNT_DEFAULT_FLOOR=10

fm_account_registry() {  # <config-dir>
  printf '%s/accounts' "$1"
}

fm_account_expand_dir() {  # <path>
  # shellcheck disable=SC2088 # a literal ~/ prefix from the registry, expanded here
  case "$1" in
    '~') printf '%s' "${HOME:-}" ;;
    '~/'*) printf '%s/%s' "${HOME:-}" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_account_list <config-dir>: print "<name>\t<provider>\t<dir>\t<priority>"
# for every registered account in choice order. Returns 1 and sets
# FM_ACCOUNT_ERROR on a malformed registry, printing nothing, so a bad file never
# yields a partial list.
fm_account_list() {
  local reg line name provider dir priority extra n=0 out='' seen='|'
  FM_ACCOUNT_ERROR=
  reg=$(fm_account_registry "$1")
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    read -r name provider dir priority extra <<<"$line"
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ -n "$extra" ] || [ -z "$dir" ]; then
      FM_ACCOUNT_ERROR="config/accounts line for '$name' must be: <name> <provider> <login-folder> [<priority>]"
      return 1
    fi
    case "$dir" in *'|'*)
      FM_ACCOUNT_ERROR="config/accounts account '$name' login folder must not contain '|'"
      return 1
      ;;
    esac
    [[ "$name" =~ $FM_ACCOUNT_NAME_RE ]] || {
      FM_ACCOUNT_ERROR="config/accounts name '$name' must be lowercase letters, digits, dot, dash, or underscore"
      return 1
    }
    case "$seen" in *"|$name|"*)
      FM_ACCOUNT_ERROR="config/accounts names '$name' twice"
      return 1
      ;;
    esac
    seen="$seen$name|"
    case "$provider" in claude | codex) ;; *)
      FM_ACCOUNT_ERROR="config/accounts account '$name' has unsupported provider '$provider' (claude or codex)"
      return 1
      ;;
    esac
    dir=$(fm_account_expand_dir "$dir")
    case "$dir" in /*) ;; *)
      FM_ACCOUNT_ERROR="config/accounts account '$name' login folder must be absolute or start with ~/"
      return 1
      ;;
    esac
    [ -n "$priority" ] || priority=$FM_ACCOUNT_DEFAULT_PRIORITY
    case "$priority" in '' | *[!0-9]*)
      FM_ACCOUNT_ERROR="config/accounts account '$name' priority '$priority' must be a non-negative integer"
      return 1
      ;;
    esac
    out+="$((10#$priority))"$'\t'"$n"$'\t'"$name"$'\t'"$provider"$'\t'"${dir%/}"$'\n'
  done <"$reg"
  [ -n "$out" ] || return 0
  printf '%s' "$out" | sort -t $'\t' -k1,1n -k2,2n | awk -F'\t' -v OFS='\t' '{ print $3, $4, $5, $1 }'
}

# fm_account_get <config-dir> <name>: set FM_ACCOUNT_PROVIDER, FM_ACCOUNT_DIR.
fm_account_get() {
  local list name provider dir priority
  FM_ACCOUNT_PROVIDER='' FM_ACCOUNT_DIR=''
  list=$(fm_account_list "$1") || return 1
  while IFS=$'\t' read -r name provider dir priority; do
    [ "$name" = "$2" ] || continue
    FM_ACCOUNT_PROVIDER=$provider FM_ACCOUNT_DIR=$dir
    return 0
  done <<<"$list"
  FM_ACCOUNT_ERROR="account '$2' is not registered in config/accounts"
  return 1
}

# fm_account_name_for_dir <config-dir> <dir> [provider]: the registered name
# whose login folder is <dir>, or nothing.
fm_account_name_for_dir() {
  local list want name provider dir priority
  [ -n "$2" ] || return 0
  want=$(fm_account_expand_dir "$2")
  want=${want%/}
  list=$(fm_account_list "$1" 2>/dev/null) || return 0
  while IFS=$'\t' read -r name provider dir priority; do
    [ -n "$name" ] || continue
    [ -z "${3:-}" ] || [ "$provider" = "$3" ] || continue
    [ "$dir" = "$want" ] && { printf '%s' "$name"; return 0; }
  done <<<"$list"
  return 0
}

fm_account_floor() {  # <config-dir>
  local v=
  [ -f "$1/account-floor" ] && IFS= read -r v <"$1/account-floor"
  v=${v//[[:space:]]/}
  case "$v" in '' | *[!0-9]*) v=$FM_ACCOUNT_DEFAULT_FLOOR ;; esac
  [ "$((10#$v))" -le 100 ] || v=100
  printf '%s' "$((10#$v))"
}

# fm_account_read_name <file>: the account name recorded in a one-line pin
# file, or nothing.
fm_account_read_name() {
  local v=
  [ -f "$1" ] || return 0
  IFS= read -r v <"$1" || true
  v=${v//[[:space:]]/}
  printf '%s' "$v"
}

# fm_account_write_name <file> <name>: atomically replace a one-line pin file.
fm_account_write_name() {
  local tmp
  mkdir -p "$(dirname "$1")" || return 1
  tmp="$1.tmp.${BASHPID:-$$}"
  if ! { printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$1"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# fm_account_meta_get <meta-file> <key>: the last value recorded for <key>.
fm_account_meta_get() {
  awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1" 2>/dev/null
}

# fm_account_iso_epoch <iso-8601>: epoch seconds, portable across GNU and BSD.
fm_account_iso_epoch() {
  jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601' 2>/dev/null
}

# fm_account_fetch <provider> <dir>: one bounded quota-axi read, printed as
# "<status>|<percent-left>|<reset-epoch>|<runway-seconds>|<plan>" with
# empty fields for anything unknown. Never fails.
fm_account_fetch() {
  local provider=$1 dir=$2 json row reset_iso reset='' timeout=${FM_ACCOUNT_QUOTA_TIMEOUT:-20}
  local status left runway plan auth cls
  if ! command -v quota-axi >/dev/null 2>&1; then
    printf 'no-quota-axi||||\n'
    return 0
  fi
  if [ ! -d "$dir" ]; then
    printf 'missing-folder||||\n'
    return 0
  fi
  case "$provider" in
    claude) json=$(fm_run_timed "$timeout" env CLAUDE_CONFIG_DIR="$dir" quota-axi --provider claude --profile-only --json 2>/dev/null </dev/null) || true ;;
    codex) json=$(fm_run_timed "$timeout" env CODEX_HOME="$dir" quota-axi --provider codex --profile-only --json 2>/dev/null </dev/null) || true ;;
    *) json='' ;;
  esac
  # quota-axi exits nonzero for a login that needs sign-in but still prints the
  # provider row whose state says so, which is exactly what the panel shows.
  row=$(printf '%s' "$json" | jq -r --arg p "$provider" '
    ([.providers[]? | select(.provider == $p)] | first) as $r |
    if $r == null then "unreadable||||" else
    (($r.quotaSemantics.effectiveAvailability // []) as $e |
      (([$e[] | select(.scope == "all_models")] | first) // ($e | first))) as $a |
    ($a.limitingWindowIds[0]? // null) as $lim |
    ([$r.windows[]? | select(.id == $lim)] | first | .resetsAt?) as $reset |
    [ ($r.state.status // "unknown"),
      ($a.effectivePercentRemaining // "" | tostring),
      ($reset // ""),
      (if $a.runway.status? == "projected_exhaustion" then ($a.runway.usableRunwaySeconds // "" | tostring) else "" end),
      ($r.plan // ""),
      ($r.state.authStatus // "") ] | join("|") end' 2>/dev/null) || row=
  [ -n "$row" ] || row='unreadable||||'
  IFS='|' read -r status left reset_iso runway plan auth <<<"$row"
  [ "$auth" != expired_refreshable ] || status=expired
  # A lapsed Claude access token draws 401 and 429 alternately from the
  # profile-only read; the classifier keeps auth_required only when it agrees
  # (or cannot be read), and says expired whenever a refresh token remains.
  if [ "$provider" = claude ]; then
    case "$status" in auth_required | rate_limited)
      cls=$(fm_account_classify_claude "$dir" "$timeout")
      if [ "${cls#*|}" = expired_refreshable ]; then
        status=expired
      elif [ "$status" = auth_required ] && [ -n "$cls" ] && [ "${cls%%|*}" != auth_required ]; then
        status=expired
      fi
      ;;
    esac
  fi
  [ -z "$reset_iso" ] || reset=$(fm_account_iso_epoch "$reset_iso")
  case "$left" in *[!0-9.]*) left= ;; esac
  left=${left%%.*}
  printf '%s|%s|%s|%s|%s\n' "$status" "$left" "$reset" "$runway" "$plan"
}

# fm_account_classify_claude <dir> <timeout>: "<status>|<authStatus>" from
# quota-axi's own classifier for one Claude login, read without refreshing or
# writing the credential, or nothing when that read is unreadable. Only these
# two fields are taken; its usage numbers never are.
fm_account_classify_claude() {
  local json
  json=$(fm_run_timed "$2" env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$1" quota-axi --provider claude --no-credential-refresh --json 2>/dev/null </dev/null) || true
  printf '%s' "$json" | jq -r '([.providers[]? | select(.provider == "claude")] | first) as $r |
    if $r == null then empty else "\($r.state.status // "")|\($r.state.authStatus // "")" end' 2>/dev/null || true
}

# fm_account_signin_note <state-dir> <name> <status>: update the sign-in
# streak for one real read (see the header).
fm_account_signin_note() {
  local rec="$1/.account-signin-$2" first='' count='' now tmp
  [ -d "$1" ] || return 0
  case "$3" in
    fresh | expired) rm -f "$rec" 2>/dev/null; return 0 ;;
    auth_required | missing-folder) ;;
    *) return 0 ;;
  esac
  now=$(date +%s)
  [ -f "$rec" ] && IFS='|' read -r first count <"$rec"
  case "$first" in '' | *[!0-9]*) first=$now count=0 ;; esac
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  tmp="$rec.tmp.${BASHPID:-$$}"
  if ! { printf '%s|%s\n' "$first" "$((count + 1))" >"$tmp" && mv -f "$tmp" "$rec"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
  fi
}

# fm_account_signin_confirmed <state-dir> <name>: 0 when the login's sign-in
# streak has at least 3 reads spanning the confirmation window.
fm_account_signin_confirmed() {
  local first='' count='' window=${FM_ACCOUNT_SIGNIN_CONFIRM_SECS:-900}
  [ -f "$1/.account-signin-$2" ] && IFS='|' read -r first count <"$1/.account-signin-$2"
  case "$first$count" in '' | *[!0-9]*) return 1 ;; esac
  case "$window" in '' | *[!0-9]*) window=900 ;; esac
  [ "$count" -ge 3 ] && [ $(($(date +%s) - first)) -ge "$window" ]
}

# fm_account_usage <config-dir> <state-dir> <name> [ttl]: cached usage line
# "<status>|<percent-left>|<reset-epoch>|<runway-seconds>|<plan>".
fm_account_usage() {
  local config=$1 state=$2 name=$3 ttl=${4:-${FM_ACCOUNT_USAGE_TTL:-120}}
  local cache stamp rest now line tmp
  fm_account_get "$config" "$name" || { printf 'unregistered||||\n'; return 0; }
  cache="$state/.account-usage-$name"
  now=$(date +%s)
  if [ -f "$cache" ] && IFS= read -r line <"$cache"; then
    stamp=${line%%|*}
    rest=${line#*|}
    case "$stamp" in '' | *[!0-9]*) ;; *)
      if [ $((now - stamp)) -lt "$ttl" ]; then
        printf '%s\n' "$rest"
        return 0
      fi
      ;;
    esac
  fi
  rest=$(fm_account_fetch "$FM_ACCOUNT_PROVIDER" "$FM_ACCOUNT_DIR")
  fm_account_signin_note "$state" "$name" "${rest%%|*}"
  if [ -d "$state" ]; then
    tmp="$cache.tmp.${BASHPID:-$$}"
    if ! { printf '%s|%s\n' "$now" "$rest" >"$tmp" && mv -f "$tmp" "$cache"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
    fi
  fi
  printf '%s\n' "$rest"
}

# fm_account_left <usage-line>: the percent-left field, or nothing.
fm_account_left() {
  local status left
  IFS='|' read -r status left _ <<<"$1"
  printf '%s' "$left"
}

# fm_account_is_low <config-dir> <state-dir> <name>: 0 only when usage is known
# and below the floor.
fm_account_is_low() {
  local left
  left=$(fm_account_left "$(fm_account_usage "$1" "$2" "$3")")
  [ -n "$left" ] && [ "$left" -lt "$(fm_account_floor "$1")" ]
}

# fm_account_room <config-dir> <state-dir> [<exclude>]: print the first
# registered Claude account, in choice order, whose known percent left is at or
# above the floor, skipping <exclude>; print nothing when none has room.
fm_account_room() {
  local config=$1 state=$2 exclude=${3:-} list name provider dir priority left floor
  floor=$(fm_account_floor "$config")
  list=$(fm_account_list "$config") || return 0
  while IFS=$'\t' read -r name provider dir priority; do
    [ "$provider" = claude ] && [ "$name" != "$exclude" ] || continue
    left=$(fm_account_left "$(fm_account_usage "$config" "$state" "$name")")
    if [ -n "$left" ] && [ "$left" -ge "$floor" ]; then
      printf '%s' "$name"
      return 0
    fi
  done <<<"$list"
}

# fm_account_pick <config-dir> <state-dir> <preferred>: print the account a
# new spawn should use - <preferred> unless it is low and another Claude account
# has room.
fm_account_pick() {
  local room
  if fm_account_is_low "$1" "$2" "$3"; then
    room=$(fm_account_room "$1" "$2" "$3")
    [ -z "$room" ] || { printf '%s' "$room"; return 0; }
  fi
  printf '%s' "$3"
}

# fm_account_new_spawn_preference <config-dir>: the account a fresh ship or
# scout spawn from this home starts from before the floor check, or nothing.
fm_account_new_spawn_preference() {
  local config=$1 name
  name=$(fm_account_read_name "$config/spawn-account")
  [ -n "$name" ] || name=$(fm_account_read_name "$config/account")
  [ -n "$name" ] || name=$(fm_account_name_for_dir "$config" "${CLAUDE_CONFIG_DIR:-}" claude)
  printf '%s' "$name"
}

# fm_account_resolve_spawn <config-dir> <state-dir> <kind> <relaunch 0|1>
#   <relaunch-meta> <secondmate-home>
# Sets FM_ACCOUNT_NAME and FM_ACCOUNT_DIR (both empty = leave the launcher's
# CLAUDE_CONFIG_DIR alone) and FM_ACCOUNT_NOTICE (a one-line stderr notice, or
# empty). Returns 1 with FM_ACCOUNT_ERROR set when a named account cannot be
# honored. See the header for the precedence.
fm_account_resolve_spawn() {
  local config=$1 state=$2 kind=$3 relaunch=$4 meta=$5 smhome=$6
  local name='' source='' recorded_dir pick left
  # shellcheck disable=SC2034 # results read by the sourcing caller
  FM_ACCOUNT_NAME='' FM_ACCOUNT_DIR='' FM_ACCOUNT_NOTICE='' FM_ACCOUNT_ERROR=''
  fm_account_list "$config" >/dev/null || return 1
  if [ -n "${FM_SPAWN_ACCOUNT:-}" ]; then
    name=$FM_SPAWN_ACCOUNT source='the requested switch'
  elif [ "$kind" = secondmate ]; then
    name=$(fm_account_read_name "$smhome/config/account")
    source="$smhome/config/account"
  elif [ "$relaunch" = 1 ]; then
    name=$(fm_account_meta_get "$meta" account)
    source='its task record'
    if [ -z "$name" ]; then
      recorded_dir=$(fm_account_meta_get "$meta" claude_config_dir)
      [ -n "$recorded_dir" ] && FM_ACCOUNT_DIR=$recorded_dir
      return 0
    fi
  else
    name=$(fm_account_new_spawn_preference "$config")
    source='this home'
  fi
  [ -n "$name" ] || return 0
  fm_account_get "$config" "$name" || {
    FM_ACCOUNT_ERROR="account '$name' named by $source is not registered in config/accounts"
    return 1
  }
  [ "$FM_ACCOUNT_PROVIDER" = claude ] || {
    FM_ACCOUNT_ERROR="account '$name' named by $source is a $FM_ACCOUNT_PROVIDER account, not a Claude login"
    return 1
  }
  if [ "$kind" != secondmate ] && [ "$relaunch" != 1 ] && [ -z "${FM_SPAWN_ACCOUNT:-}" ]; then
    pick=$(fm_account_pick "$config" "$state" "$name")
    if [ "$pick" != "$name" ]; then
      left=$(fm_account_left "$(fm_account_usage "$config" "$state" "$name")")
      # shellcheck disable=SC2034 # read by the sourcing caller
      FM_ACCOUNT_NOTICE="account: $name has ${left}% left, below the $(fm_account_floor "$config")% floor; this spawn uses $pick"
      name=$pick
      fm_account_get "$config" "$name" || return 1
    fi
  fi
  [ -d "$FM_ACCOUNT_DIR" ] || {
    # shellcheck disable=SC2034 # read by the sourcing caller
    FM_ACCOUNT_ERROR="account '$name' login folder $FM_ACCOUNT_DIR does not exist; sign in to it first"
    return 1
  }
  # shellcheck disable=SC2034 # read by the sourcing caller
  FM_ACCOUNT_NAME=$name
}
