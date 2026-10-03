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
# CLAUDE_CODE_OAUTH_TOKEN unset so no env token answers for the folder, and a
# throwaway XDG_CACHE_HOME so quota-axi's shared cache is left alone), and
# only its authStatus is used, never its usage numbers: a lapsed
# access token that still holds a refresh token is status expired (it renews
# on next use), not a sign-out.
#
# Floor: config/account-floor, one integer percent 0-100 (default 10).
# Outlook (fm_account_outlook_of): each window bounding a Claude account's
# all-models use (the 5-hour session and the weekly allowance) is projected on
# its own: at the burn rate so far (percent used over the elapsed share of the
# window), is it used up before it resets? The projection is unknown for a
# window whose length, percent left, or reset is not reported, or less than 5%
# of which has elapsed. The account's outlook is then, first match:
#   low      a window below the floor runs out first, or its projection is
#            unknown; with no window data, the effective percent left is below
#            the floor (the plain floor rule)
#   draining a window is projected to run out before it resets
#   resets   below the floor, but every such window resets before running out
#   ok       known room otherwise; nothing (unknown) when usage is unknown
# New spawns steer away from low and draining accounts; live agents move, and
# this main session is asked to restart, only off a low account. Work goes to an
# ok account first; with none ok, a draining account still at or above the floor
# receives work off a low account, so work never stops while one has room.
# Unknown usage is never low, so a failed read never moves work, and a resets
# account is left alone.
#
# Spawn choice (fm_account_resolve_spawn), Claude launches only, first match:
#   1. FM_SPAWN_ACCOUNT=<name>, the explicit switch bin/fm-account.sh passes
#      through bin/fm-control.sh to a relaunch.
#   2. A secondmate launch: that home's config/account pin, written by
#      `fm-account.sh use`; a relaunch or respawn keeps it.
#   3. A ship or scout relaunch: the account= its task record already carries.
#   4. A fresh ship or scout spawn: this home's config/spawn-account, else its
#      config/account, else the registered account whose folder is the
#      launcher's own CLAUDE_CONFIG_DIR - then, when that choice is low or
#      draining, the account with room (fm_account_room); a draining choice
#      moves only to an ok account.
# A named account that is not registered, or not Claude, or whose folder is
# missing, refuses rather than silently launching on another login.
# A launching home's config/claude-account pin (bin/fm-worker-account-lib.sh)
# outranks all of the above: with it present nothing is chosen here, and an
# explicit FM_SPAWN_ACCOUNT refuses because the pin cannot be overridden. With no
# registry and no FM_SPAWN_ACCOUNT the launch is unchanged: the launcher's own
# CLAUDE_CONFIG_DIR is forwarded exactly as before.
#
# Usage cache: state/.account-usage-<name>, one |-separated line written only
# here: <epoch>|<status>|<percent-left>|<reset-epoch>|<runway-seconds>|<plan>|<windows>,
# <windows> being a comma-separated "<length-secs>:<percent-left>:<reset-epoch>"
# per bounding window, any part empty when unknown.
# FM_ACCOUNT_USAGE_TTL (seconds, default 120) bounds its age;
# FM_ACCOUNT_QUOTA_TIMEOUT (seconds, default 20) bounds one quota-axi read.
# Every quota-axi read runs with NODE_OPTIONS (any value already set kept)
# carrying --network-family-autoselection-attempt-timeout of
# FM_ACCOUNT_QUOTA_CONNECT_MS milliseconds (default 2000): Node's own 250 ms per
# address attempt fails every read as "fetch failed" on a link whose TCP connect
# takes longer, while 0 leaves NODE_OPTIONS untouched.
# A read that answers error or unreadable without timing out - quota-axi's
# "fetch failed" is a request that never reached the host, which hits every
# login at once during a network blip - is retried up to
# FM_ACCOUNT_QUOTA_ATTEMPTS reads in all (default 3) after a backoff of
# FM_ACCOUNT_QUOTA_RETRY_DELAY seconds (default 1), doubling each time; the
# total stays inside the watcher's 30-second check bound. A rate_limited or
# sign-in reading is a real answer and is never retried. A read that still
# fails is unknown usage, never exhausted.
#
# Blind readings (fm_account_readings_blind): every registered account's read
# came back error, unreadable, or no-quota-axi, so no reading says anything
# about room; bin/fm-account.sh then reports the readings blind instead of
# balanced.
#
# Live login (fm_account_live_index, fm_account_live_for): the account a running
# agent is actually on, from the CLAUDE_CONFIG_DIR of each process named claude
# (the comm rule bin/fm-harness.sh applies) whose working folder is the agent's
# own: a worker's worktree, a second mate's home, or this home for its session.
# Only that one environment entry is read, by matching its name inside
# /proc/<pid>/environ, and it is used only to look up the registered account; no
# other environment value or credential is read, printed, or kept. An absent
# entry is Claude's default ~/.claude. A process that cannot be read, or none
# found, is unknown; a folder no account registers is unregistered.
# FM_PROC_ROOT_OVERRIDE (default /proc) is the test seam.
#
# Sign-in streak: state/.account-signin-<name>, one line
# "<first-epoch>|<last-epoch>|<count>" written only here at each real read. A read of auth_required or
# missing-folder counts it up, fresh or expired removes it, and any other
# status (rate_limited, error, unreadable) leaves it alone. A login is
# confirmed as needing sign-in (fm_account_signin_confirmed) only after at
# least 3 counted reads whose first and last span FM_ACCOUNT_SIGNIN_CONFIRM_SECS
# (default 900).

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_ACCOUNT_NAME_RE='^[a-z0-9][a-z0-9._-]*$'
FM_ACCOUNT_DEFAULT_PRIORITY=100
FM_ACCOUNT_DEFAULT_FLOOR=10
FM_ACCOUNT_OUTLOOK_MIN_ELAPSED_PCT=5

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

# fm_account_fetch <provider> <dir>: a bounded quota-axi read, retried as the
# header says, printed as
# "<status>|<percent-left>|<reset-epoch>|<runway-seconds>|<plan>|<windows>"
# with empty fields for anything unknown. Never fails.
fm_account_fetch() {
  local provider=$1 dir=$2 row rc reset_iso reset='' timeout=${FM_ACCOUNT_QUOTA_TIMEOUT:-20}
  local status left runway plan windows attempt=0
  local attempts=${FM_ACCOUNT_QUOTA_ATTEMPTS:-3} delay=${FM_ACCOUNT_QUOTA_RETRY_DELAY:-1}
  if ! command -v quota-axi >/dev/null 2>&1; then
    printf 'no-quota-axi||||\n'
    return 0
  fi
  if [ ! -d "$dir" ]; then
    printf 'missing-folder||||\n'
    return 0
  fi
  case "$attempts" in '' | *[!0-9]* | 0) attempts=3 ;; esac
  case "$delay" in '' | *[!0-9]*) delay=1 ;; esac
  while :; do
    row=$(fm_account_fetch_once "$provider" "$dir" "$timeout") && rc=0 || rc=$?
    case "${row%%|*}" in error | unreadable) ;; *) break ;; esac
    attempt=$((attempt + 1))
    { [ "$attempt" -lt "$attempts" ] && ! fm_timed_out "$rc"; } || break
    sleep "$delay"
    delay=$((delay * 2))
  done
  IFS='|' read -r status left reset_iso runway plan windows <<<"$row"
  # A lapsed Claude access token draws 401 and 429 alternately from the
  # profile-only read; only the classifier's expired_refreshable, a login that
  # still holds a refresh token, turns either reading into expired.
  if [ "$provider" = claude ]; then
    case "$status" in auth_required | rate_limited)
      [ "$(fm_account_classify_claude "$dir" "$timeout")" != expired_refreshable ] || status=expired
      ;;
    esac
  fi
  [ -z "$reset_iso" ] || reset=$(fm_account_iso_epoch "$reset_iso")
  case "$left" in *[!0-9.]*) left= ;; esac
  left=${left%%.*}
  printf '%s|%s|%s|%s|%s|%s\n' "$status" "$left" "$reset" "$runway" "$plan" "$windows"
}

# fm_account_node_options: NODE_OPTIONS for one quota-axi read (see the header).
fm_account_node_options() {
  local ms=${FM_ACCOUNT_QUOTA_CONNECT_MS:-2000}
  case "$ms" in '' | *[!0-9]*) ms=2000 ;; esac
  if [ "$((10#$ms))" -eq 0 ]; then
    printf '%s' "${NODE_OPTIONS:-}"
    return 0
  fi
  printf '%s' "${NODE_OPTIONS:+$NODE_OPTIONS }--network-family-autoselection-attempt-timeout=$((10#$ms))"
}

# fm_account_fetch_once <provider> <dir> <timeout>: one quota-axi read, printed
# as "<status>|<percent-left>|<reset-iso>|<runway-seconds>|<plan>|<windows>"; returns the
# read's own exit status so a timeout is visible to the caller.
fm_account_fetch_once() {
  local provider=$1 dir=$2 timeout=$3 json row rc=0 nodeopts
  nodeopts=$(fm_account_node_options)
  case "$provider" in
    claude) json=$(fm_run_timed "$timeout" env NODE_OPTIONS="$nodeopts" CLAUDE_CONFIG_DIR="$dir" quota-axi --provider claude --profile-only --json 2>/dev/null </dev/null) || rc=$? ;;
    codex) json=$(fm_run_timed "$timeout" env NODE_OPTIONS="$nodeopts" CODEX_HOME="$dir" quota-axi --provider codex --profile-only --json 2>/dev/null </dev/null) || rc=$? ;;
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
    def len: if .id == "five_hour" then 18000
      elif .id == "seven_day" then 604800 else "" end;
    def epoch: try (sub("\\.[0-9]+"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601) catch "";
    [ ($a.boundedBy // [])[] as $id | ([$r.windows[]? | select(.id == $id)] | first) as $w |
      if $w == null then "::" else
      [ ($w | len), ($w.percentRemaining // "" | tostring | sub("[.].*"; "")),
        (if $w.resetsAt then ($w.resetsAt | epoch) else "" end) ] | map(tostring) | join(":") end
    ] as $windows |
    [ ($r.state.status // "unknown"),
      ($a.effectivePercentRemaining // "" | tostring),
      ($reset // ""),
      (if $a.runway.status? == "projected_exhaustion" then ($a.runway.usableRunwaySeconds // "" | tostring) else "" end),
      ($r.plan // ""),
      ($windows | join(",")) ] | join("|") end' 2>/dev/null) || row=
  [ -n "$row" ] || row='unreadable||||'
  printf '%s\n' "$row"
  return "$rc"
}

# fm_account_classify_claude <dir> <timeout>: the authStatus from quota-axi's
# own classifier for one Claude login, read without refreshing or writing the
# credential and against a throwaway quota cache so the shared one is never
# written or cleared, or nothing when that read is unreadable. Only this field
# is taken; its usage numbers never are.
fm_account_classify_claude() {
  local json cache
  cache=$(mktemp -d "${TMPDIR:-/tmp}/fm-account-classify.XXXXXX" 2>/dev/null) || return 0
  json=$(fm_run_timed "$2" env -u CLAUDE_CODE_OAUTH_TOKEN NODE_OPTIONS="$(fm_account_node_options)" CLAUDE_CONFIG_DIR="$1" XDG_CACHE_HOME="$cache" quota-axi --provider claude --no-credential-refresh --json 2>/dev/null </dev/null) || true
  rm -rf "$cache"
  printf '%s' "$json" | jq -r '([.providers[]? | select(.provider == "claude")] | first) as $r |
    if $r == null then empty else ($r.state.authStatus // "") end' 2>/dev/null || true
}

# fm_account_signin_note <state-dir> <name> <status>: update the sign-in
# streak for one real read (see the header).
fm_account_signin_note() {
  local rec="$1/.account-signin-$2" first='' last='' count='' now tmp
  [ -d "$1" ] || return 0
  case "$3" in
    fresh | expired) rm -f "$rec" 2>/dev/null; return 0 ;;
    auth_required | missing-folder) ;;
    *) return 0 ;;
  esac
  now=$(date +%s)
  [ -f "$rec" ] && IFS='|' read -r first last count <"$rec"
  case "$first$count" in '' | *[!0-9]*) first=$now count=0 ;; esac
  tmp="$rec.tmp.${BASHPID:-$$}"
  if ! { printf '%s|%s|%s\n' "$first" "$now" "$((count + 1))" >"$tmp" && mv -f "$tmp" "$rec"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
  fi
}

# fm_account_signin_confirmed <state-dir> <name>: 0 when the login's sign-in
# streak has at least 3 reads whose first and last span the confirmation window.
fm_account_signin_confirmed() {
  local first='' last='' count='' window=${FM_ACCOUNT_SIGNIN_CONFIRM_SECS:-900}
  [ -f "$1/.account-signin-$2" ] && IFS='|' read -r first last count <"$1/.account-signin-$2"
  case "$first$last$count" in '' | *[!0-9]*) return 1 ;; esac
  case "$window" in '' | *[!0-9]*) window=900 ;; esac
  [ "$count" -ge 3 ] && [ $((last - first)) -ge "$window" ]
}

# fm_account_usage <config-dir> <state-dir> <name> [ttl]: cached usage line
# "<status>|<percent-left>|<reset-epoch>|<runway-seconds>|<plan>|<windows>".
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

# fm_account_readings_blind <status>...: 0 when there is at least one status and
# every one is a failed read (see the header).
fm_account_readings_blind() {
  local s
  [ $# -gt 0 ] || return 1
  for s in "$@"; do
    case "$s" in error | unreadable | no-quota-axi) ;; *) return 1 ;; esac
  done
  return 0
}

# fm_account_live_index: one "<cwd>\t<login-folder>" line per readable process
# named claude, <login-folder> being "~/.claude" when the entry is absent, and
# "<cwd>\t?" for one whose environment cannot be read (see the header).
fm_account_live_index() {
  local proc=${FM_PROC_ROOT_OVERRIDE:-/proc} p comm cwd entry
  for p in "$proc"/[0-9]*; do
    [ -d "$p" ] || continue
    comm=
    IFS= read -r comm <"$p/comm" 2>/dev/null || continue
    case "${comm##*/}" in *claude*) ;; *) continue ;; esac
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
    [ -n "$cwd" ] || continue
    if [ ! -r "$p/environ" ]; then
      printf '%s\t?\n' "$cwd"
      continue
    fi
    # grep -z prints only the matching entry; nothing else leaves the file.
    entry=$(grep -z -m1 '^CLAUDE_CONFIG_DIR=' "$p/environ" 2>/dev/null | tr -d '\0')
    if [ -n "$entry" ]; then
      printf '%s\t%s\n' "$cwd" "${entry#CLAUDE_CONFIG_DIR=}"
    elif [ "$(head -c1 "$p/environ" 2>/dev/null | wc -c)" -gt 0 ]; then
      printf '%s\t~/.claude\n' "$cwd"
    else
      printf '%s\t?\n' "$cwd"
    fi
  done
}

# fm_account_live_for <config-dir> <index> <dir>: the live account of the agent
# whose working folder is <dir> - its account name, "unregistered", or
# "unknown"; several processes on different logins join with "+".
fm_account_live_for() {
  local config=$1 index=$2 want=$3 cwd folder name out='' seen='|'
  [ -n "$want" ] || { printf unknown; return 0; }
  [ ! -d "$want" ] || want=$(cd -P "$want" 2>/dev/null && pwd) || want=$3
  want=${want%/}
  while IFS=$'\t' read -r cwd folder; do
    [ "${cwd%/}" = "$want" ] || continue
    if [ "$folder" = '?' ]; then
      name=unknown
    else
      name=$(fm_account_name_for_dir "$config" "$folder" claude)
      [ -n "$name" ] || name=unregistered
    fi
    case "$seen" in *"|$name|"*) continue ;; esac
    seen="$seen$name|"
    out="${out:+$out+}$name"
  done <<<"$index"
  printf '%s' "${out:-unknown}"
}

# fm_account_left <usage-line>: the percent-left field, or nothing.
fm_account_left() {
  local status left
  IFS='|' read -r status left _ <<<"$1"
  printf '%s' "$left"
}

# fm_account_window_runs_out <length> <percent-left> <reset-epoch> <now>: 0
# when the window is projected to be used up before it resets, 1 when it resets
# first, 2 when the projection is unknown (see the header).
fm_account_window_runs_out() {
  local len=$1 pct=$2 reset=$3 now=$4 remaining elapsed
  case "$len$pct$reset" in '' | *[!0-9]*) return 2 ;; esac
  [ -n "$len" ] && [ -n "$pct" ] && [ -n "$reset" ] && [ "$len" -gt 0 ] || return 2
  remaining=$((reset - now))
  [ "$remaining" -gt 0 ] || return 1
  elapsed=$((len - remaining))
  [ $((elapsed * 100)) -ge $((len * FM_ACCOUNT_OUTLOOK_MIN_ELAPSED_PCT)) ] || return 2
  # Used at reset = used * len / elapsed; it runs out when that reaches 100.
  [ $(((100 - pct) * len)) -ge $((100 * elapsed)) ]
}

# fm_account_outlook_of <floor> <usage-line> [now]: low, draining, resets, ok,
# or nothing when usage is unknown (see the header).
fm_account_outlook_of() {
  local floor=$1 now=${3:-$(date +%s)} left windows w len pct reset rc
  local low=0 draining=0 resets=0
  IFS='|' read -r _ left _ _ _ windows <<<"$2"
  [ -n "$left" ] || return 0
  if [ -z "$windows" ]; then
    if [ "$left" -lt "$floor" ]; then printf low; else printf ok; fi
    return 0
  fi
  for w in ${windows//,/ }; do
    IFS=: read -r len pct reset <<<"$w"
    fm_account_window_runs_out "$len" "$pct" "$reset" "$now" && rc=0 || rc=$?
    if [ -n "$pct" ] && [ "$pct" -lt "$floor" ]; then
      if [ "$rc" = 1 ]; then resets=1; else low=1; fi
    elif [ "$rc" = 0 ]; then
      draining=1
    fi
  done
  # An effective reading below the floor that no window accounts for keeps the
  # plain floor rule.
  [ "$resets" = 1 ] || [ "$left" -ge "$floor" ] || low=1
  if [ "$low" = 1 ]; then printf low
  elif [ "$draining" = 1 ]; then printf draining
  elif [ "$resets" = 1 ]; then printf resets
  else printf ok; fi
}

# fm_account_outlook <config-dir> <state-dir> <name>: the account's outlook.
fm_account_outlook() {
  fm_account_outlook_of "$(fm_account_floor "$1")" "$(fm_account_usage "$1" "$2" "$3")"
}

# fm_account_is_low <config-dir> <state-dir> <name>: 0 only when the outlook is
# low, the one reading that moves live agents.
fm_account_is_low() {
  [ "$(fm_account_outlook "$1" "$2" "$3")" = low ]
}

# fm_account_room <config-dir> <state-dir> [<exclude>]: print the first
# registered Claude account, in choice order, whose outlook is ok, else the
# first whose outlook is draining with its percent left at or above the floor,
# skipping <exclude>; print nothing when none has room.
fm_account_room() {
  local config=$1 state=$2 exclude=${3:-} list name provider dir priority floor usage fallback=''
  list=$(fm_account_list "$config") || return 0
  floor=$(fm_account_floor "$config")
  while IFS=$'\t' read -r name provider dir priority; do
    [ "$provider" = claude ] && [ "$name" != "$exclude" ] || continue
    usage=$(fm_account_usage "$config" "$state" "$name")
    case "$(fm_account_outlook_of "$floor" "$usage")" in
      ok) printf '%s' "$name"; return 0 ;;
      draining) [ -n "$fallback" ] || [ "$(fm_account_left "$usage")" -lt "$floor" ] || fallback=$name ;;
    esac
  done <<<"$list"
  printf '%s' "$fallback"
}

# fm_account_pick <config-dir> <state-dir> <preferred>: print the account a
# new spawn should use - <preferred> unless it is low and another Claude account
# has room, or it is draining and another Claude account is ok.
fm_account_pick() {
  local outlook room
  outlook=$(fm_account_outlook "$1" "$2" "$3")
  case "$outlook" in
    low | draining)
      room=$(fm_account_room "$1" "$2" "$3")
      if [ -n "$room" ] && { [ "$outlook" = low ] || [ "$(fm_account_outlook "$1" "$2" "$room")" = ok ]; }; then
        printf '%s' "$room"
        return 0
      fi
      ;;
  esac
  printf '%s' "$3"
}

# fm_account_recorded_name <meta>: the registered account name a task record
# carries in account=, or nothing. A config/claude-account pin also records
# account=, as `ordinary` or an absolute root (bin/fm-worker-account-lib.sh);
# neither is a registry name, so either reads as no recorded account.
fm_account_recorded_name() {
  local name
  name=$(fm_account_meta_get "$1" account)
  case "$name" in
    ordinary|/*) return 0 ;;
  esac
  printf '%s' "$name"
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
  if [ -e "$config/claude-account" ] || [ -L "$config/claude-account" ]; then
    [ -z "${FM_SPAWN_ACCOUNT:-}" ] || {
      FM_ACCOUNT_ERROR="config/claude-account pins this home's Claude login, so account '$FM_SPAWN_ACCOUNT' cannot be honored"
      return 1
    }
    return 0
  fi
  fm_account_list "$config" >/dev/null || return 1
  if [ -n "${FM_SPAWN_ACCOUNT:-}" ]; then
    name=$FM_SPAWN_ACCOUNT source='the requested switch'
  elif [ "$kind" = secondmate ]; then
    name=$(fm_account_read_name "$smhome/config/account")
    source="$smhome/config/account"
  elif [ "$relaunch" = 1 ]; then
    name=$(fm_account_recorded_name "$meta")
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
      if fm_account_is_low "$config" "$state" "$name"; then
        # shellcheck disable=SC2034 # read by the sourcing caller
        FM_ACCOUNT_NOTICE="account: $name has ${left}% left, below the $(fm_account_floor "$config")% floor; this spawn uses $pick"
      else
        # shellcheck disable=SC2034 # read by the sourcing caller
        FM_ACCOUNT_NOTICE="account: $name is on pace to run out before its usage window resets; this spawn uses $pick"
      fi
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
