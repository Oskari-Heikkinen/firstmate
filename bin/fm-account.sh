#!/usr/bin/env bash
# fm-account.sh - subscription accounts: usage per login, who runs on which,
# the switch, automatic rebalancing, and the captain's collapsible panel.
#
# Usage:
#   fm-account.sh status [--json] [--refresh]
#   fm-account.sh use <task-id> <account> [--no-relaunch] [--note <text>]
#   fm-account.sh default <account>|--clear
#   fm-account.sh rebalance [--check] [--dry-run]
#   fm-account.sh auto on|off|sync
#   fm-account.sh panel
#   fm-account.sh watch [--once] [--interval <secs>]
#
# bin/fm-account-lib.sh owns the registry format (config/accounts), the floor
# (config/account-floor), usage reads, and the account a launch gets;
# docs/configuration.md "Subscription accounts" is the operator reference.
#
# status     One table: each account's provider, plan, percent left, runway,
#            reset, outlook (LOW, RUNNING OUT, or low, resets first; see the
#            lib header), and the sessions and workers on it, then where new spawns
#            go, suggested moves, sign-ins needed, and recent moves. Workers of
#            this home's local second mates are read from their records too.
#            An agent's account is its launch record (account= in its task
#            record), else a second mate's pin, else - marked "~" - the account
#            of the session that launched it, since fm-spawn forwards that
#            session's login. Beside it, each running Claude agent's live
#            account (the lib header's live login; unknown when its process
#            cannot be read, unregistered for a login no account names), marked
#            MISMATCH when it differs from the recorded one; --json carries it as
#            live_account and live_mismatch. When every account's read failed
#            the advice is the one "account readings blind" line.
#            --refresh ignores the usage cache.
# use        Move one direct report onto <account> through the guarded path and
#            record it durably. A second mate gets <home>/config/account (the
#            pin every later relaunch and respawn honors), then the
#            persist-gated bin/fm-secondmate-restart.sh unless its record
#            already shows that account. A ship or scout is relaunched with
#            bin/fm-control.sh relaunch (its task record then carries the new
#            account), only while it is between steps: an idle pane, no
#            attributed no-mistakes run, and a working or paused status. The
#            relaunch note is generated unless --note is given. --no-relaunch
#            records a second mate's pin only (for one already on that account
#            or stopped). A remote second mate and a non-Claude worker refuse.
# default    Set or clear config/spawn-account, this home's starting account for
#            new ship and scout spawns (a low or running-out outlook still
#            moves a spawn off it).
# rebalance  Move every direct report on a low Claude account (below the floor
#            and not projected to reset before running out; the lib header owns
#            the outlook) to the first account with room, through `use`,
#            skipping any that is
#            not between steps (retried by the next run), then print one line
#            per move plus any restart or sign-in the captain must do. Only the
#            captain can restart this home's own session or sign in to a login.
#            Only the main home prints sign-in and no-room lines here, and a
#            sign-in only once the lib's sign-in streak confirms it; status and
#            the panel still show every home's current readings.
#            When every account's read failed it never prints "balanced"; the
#            blind readings are its needs-the-captain line (main home only).
#            --dry-run prints the plan only. --check is the watcher form: it
#            prints one wake line only when a move is due or the advice changed
#            (or 30 minutes after an unhandled move line) and nothing otherwise;
#            advice that goes quiet and returns unchanged within the sign-in
#            confirmation window (FM_ACCOUNT_SIGNIN_CONFIRM_SECS, default 900)
#            does not wake again.
# auto       on/off writes config/account-auto; sync makes state/accounts.check.sh
#            match it: installed and registered (bin/fm-check-register.sh) while
#            config/accounts exists and auto is not off, retired otherwise.
#            bin/fm-bootstrap.sh runs sync at every session start.
# panel      Toggle the side pane: inside Herdr, split this pane to the right
#            and run `watch` there, or stop the running one (its pane closes
#            with it). Outside Herdr it prints how to run `watch` instead.
#            FM_ACCOUNT_PANEL_RATIO, when set, is passed as the split ratio.
# watch      The panel loop: redraw status every --interval (default 60)
#            seconds; keys r refresh, s switch an agent, d set the new-spawn
#            default, a rebalance now, q close. --once draws one frame and exits.
#
# Runtime records written only here: state/.account-usage-<name> (lib cache),
# state/.account-signin-<name> (lib sign-in streak), state/account-moves.log
# (<epoch>|<id>|<from>|<to>|<result>),
# state/.account-check (<epoch>|<fingerprint>|<quiet-since-epoch>, the --check
# fingerprint), state/.account-panel (the running panel's pid).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"

MOVES_LOG="$STATE/account-moves.log"
CHECK_ID=accounts

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $1" >&2
  exit 1
}

need_registry() {
  fm_account_list "$CONFIG" >/dev/null || die "$FM_ACCOUNT_ERROR"
  [ -f "$(fm_account_registry "$CONFIG")" ] || die "no config/accounts registry in $CONFIG; see docs/configuration.md \"Subscription accounts\""
}

fmt_duration() {  # <seconds>
  local s=$1 d h m
  case "$s" in '' | *[!0-9]*) printf -- '-'; return ;; esac
  d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

self_label() {
  local id=
  [ -f "$FM_HOME/.fm-secondmate-home" ] && IFS= read -r id <"$FM_HOME/.fm-secondmate-home"
  printf '%s' "${id:-main}"
}

# agent_account <meta> <launcher-account>: "<account>|<basis>" for a Claude
# agent; basis is recorded, pinned, or inferred. Rows here are |-separated so
# an empty field survives bash's read.
agent_account() {
  local meta=$1 launcher=$2 acct home
  acct=$(fm_account_recorded_name "$meta")
  [ -n "$acct" ] || acct=$(fm_account_name_for_dir "$CONFIG" "$(fm_account_meta_get "$meta" claude_config_dir)" claude)
  if [ -n "$acct" ]; then printf '%s|recorded' "$acct"; return; fi
  if [ "$(fm_account_meta_get "$meta" kind)" = secondmate ]; then
    home=$(fm_account_meta_get "$meta" home)
    acct=$(fm_account_read_name "$home/config/account")
    if [ -n "$acct" ]; then printf '%s|pinned' "$acct"; return; fi
  fi
  printf '%s|inferred' "$launcher"
}

# agent_dir <meta>: the folder the agent's process runs in - a second mate's
# home, otherwise its worktree; nothing for a remote second mate, whose
# processes this host cannot see.
agent_dir() {
  [ -z "$(fm_account_meta_get "$1" remote_host)" ] || return 0
  if [ "$(fm_account_meta_get "$1" kind)" = secondmate ]; then
    fm_account_meta_get "$1" home
  else
    fm_account_meta_get "$1" worktree
  fi
}

# collect_agents: one row per agent this home can see, |-separated:
# <home-label> <id> <kind> <harness> <account> <basis> <direct 0|1> <live>
# <live> is the lib's live account for a Claude agent and empty otherwise.
collect_agents() {
  local self self_acct meta id kind harness row home sm_acct m index
  self=$(self_label)
  self_acct=$(fm_account_name_for_dir "$CONFIG" "${CLAUDE_CONFIG_DIR:-}" claude)
  index=$(fm_account_live_index)
  printf '%s|%s|session|claude|%s|session|0|%s\n' "$self" "$self" "$self_acct" \
    "$(fm_account_live_for "$CONFIG" "$index" "$FM_HOME")"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_account_meta_get "$meta" kind)
    harness=$(fm_account_meta_get "$meta" harness)
    if [ "$harness" != claude ]; then
      printf '%s|%s|%s|%s||other|1|\n' "$self" "$id" "${kind:-ship}" "$harness"
      continue
    fi
    row=$(agent_account "$meta" "$self_acct")
    printf '%s|%s|%s|claude|%s|1|%s\n' "$self" "$id" "${kind:-ship}" "$row" \
      "$(fm_account_live_for "$CONFIG" "$index" "$(agent_dir "$meta")")"
    [ "$kind" = secondmate ] || continue
    [ -z "$(fm_account_meta_get "$meta" remote_host)" ] || continue
    home=$(fm_account_meta_get "$meta" home)
    [ -n "$home" ] && [ -d "$home/state" ] || continue
    sm_acct=${row%%|*}
    for m in "$home"/state/*.meta; do
      [ -f "$m" ] || continue
      [ "$(fm_account_meta_get "$m" kind)" != secondmate ] || continue
      harness=$(fm_account_meta_get "$m" harness)
      if [ "$harness" != claude ]; then
        printf '%s|%s|%s|%s||other|0|\n' "$id" "$(basename "$m" .meta)" "$(fm_account_meta_get "$m" kind)" "$harness"
        continue
      fi
      printf '%s|%s|%s|claude|%s|0|%s\n' "$id" "$(basename "$m" .meta)" \
        "$(fm_account_meta_get "$m" kind)" "$(agent_account "$m" "$sm_acct")" \
        "$(fm_account_live_for "$CONFIG" "$index" "$(agent_dir "$m")")"
    done
  done
}

# account_rows: "<name>|<provider>|<dir>|<status>|<left>|<reset>|<runway>|<plan>|<windows>"
account_rows() {
  local ttl=$1 name provider dir priority
  while IFS=$'\t' read -r name provider dir _; do
    [ -n "$name" ] || continue
    printf '%s|%s|%s|%s\n' "$name" "$provider" "$dir" \
      "$(fm_account_usage "$CONFIG" "$STATE" "$name" "$ttl")"
  done <<<"$(fm_account_list "$CONFIG")"
}

# readings_blind <account-rows>: 0 when every account's read failed.
readings_blind() {
  local statuses
  mapfile -t statuses < <(printf '%s\n' "$1" | awk -F'|' 'NF { print $4 }')
  fm_account_readings_blind "${statuses[@]}"
}

# with_outlook <account-rows> <floor>: each row with "|<outlook>" appended as
# its tenth field, a cache line from before the windows field included.
with_outlook() {
  local name provider dir status left reset runway plan windows
  while IFS='|' read -r name provider dir status left reset runway plan windows; do
    [ -n "$name" ] || continue
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$name" "$provider" "$dir" "$status" "$left" "$reset" "$runway" "$plan" "$windows" \
      "$(fm_account_outlook_of "$2" "$status|$left|$reset|$runway|$plan|$windows")"
  done <<<"$1"
}

# crew_movable <id>: 0 when a ship or scout is between steps; prints the reason
# otherwise.
crew_movable() {
  local line
  line=$(FM_CREW_STATE_NO_FORGE=1 FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null | head -1)
  case "$line" in
    'state: working · source: status-log'* | 'state: paused · source: status-log'*) return 0 ;;
  esac
  printf '%s' "${line:-state unreadable}"
  return 1
}

log_move() {  # <id> <from> <to> <result>
  printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$1" "${2:--}" "$3" "$4" >>"$MOVES_LOG" 2>/dev/null || true
}

# advice <agents> <accounts> [captain]: captain-facing lines (restart this
# session, sign in), one per line. With captain (rebalance), sign-in and
# no-room lines come from the main home only, and a sign-in line exactly while
# the lib's sign-in streak confirms it. The no-room line needs proof for every
# Claude account: a fresh reading with a low outlook, or a sign-in line of its
# own; one unknown reading (error, unreadable, rate_limited, expired) withholds
# it, so a failed read never counts as exhausted. When every reading failed
# (the lib's blind readings) the one line is that the readings are blind, in
# the captain form from the main home only, like the sign-in lines.
advice() {
  local agents=$1 accounts=$2 captain=${3:-} floor room self_acct name provider dir status rest main=0
  local proven=0 unproven=0
  [ "$(self_label)" = main ] && main=1
  if readings_blind "$accounts"; then
    [ -n "$captain" ] && [ "$main" = 0 ] && return 0
    if printf '%s\n' "$accounts" | awk -F'|' 'NF && $4 != "no-quota-axi" { exit 1 }'; then
      printf 'account readings blind: quota-axi is not installed on this machine, so no account usage can be read; install quota-axi\n'
      return 0
    fi
    printf 'account readings blind: every account usage read failed (%s), so no move or room verdict can be made; check this machine'"'"'s connection to the usage service\n' \
      "$(printf '%s\n' "$accounts" | awk -F'|' 'NF { s = s (s ? ", " : "") $1 } END { print s }')"
    return 0
  fi
  floor=$(fm_account_floor "$CONFIG")
  room=$(fm_account_room "$CONFIG" "$STATE")
  self_acct=$(printf '%s\n' "$agents" | awk -F'|' '$6 == "session" { print $5; exit }')
  if [ "$main" = 1 ] && [ -n "$self_acct" ] && fm_account_is_low "$CONFIG" "$STATE" "$self_acct" && [ -n "$room" ] && [ "$room" != "$self_acct" ]; then
    fm_account_get "$CONFIG" "$room"
    printf 'restart this main session on %s: exit it, then start it again with CLAUDE_CONFIG_DIR=%s (%s is below the %s%% floor)\n' \
      "$room" "$FM_ACCOUNT_DIR" "$self_acct" "$floor"
  fi
  while IFS='|' read -r name provider dir status rest; do
    [ -n "$name" ] || continue
    if [ "$provider" = claude ]; then
      if [ "$status" = fresh ] && [ "$(fm_account_outlook_of "$floor" "$status|$rest")" = low ]; then
        proven=1
      elif [ -n "$captain" ] && [ "$main" = 1 ] && fm_account_signin_confirmed "$STATE" "$name"; then
        :
      elif [ -z "$captain" ] && { [ "$status" = auth_required ] || [ "$status" = missing-folder ]; }; then
        :
      else
        unproven=1
      fi
    fi
    # The captain form follows the confirmed streak, not this one reading, so
    # an in-between rate_limited or error reading neither drops nor adds a line.
    if [ -n "$captain" ]; then
      [ "$main" = 1 ] && fm_account_signin_confirmed "$STATE" "$name" && status=auth_required || status=
    fi
    case "$status" in
      auth_required | missing-folder) printf 'sign in to account %s (%s login folder %s)\n' "$name" "$provider" "$dir" ;;
    esac
  done <<<"$accounts"
  if [ -z "$room" ] && [ "$proven" = 1 ] && [ "$unproven" = 0 ] && { [ -z "$captain" ] || [ "$main" = 1 ]; }; then
    printf 'no Claude account has room above the %s%% floor; sign in to another login or wait for a reset\n' "$floor"
  fi
}

# plan_moves <agents>: "<id>|<kind>|<from>|<to>" for direct Claude reports on
# a low account, when an account with room exists.
plan_moves() {
  local agents=$1 id kind harness acct direct room
  while IFS='|' read -r _ id kind harness acct _ direct _; do
    [ "$direct" = 1 ] && [ "$harness" = claude ] && [ -n "$acct" ] || continue
    fm_account_is_low "$CONFIG" "$STATE" "$acct" || continue
    room=$(fm_account_room "$CONFIG" "$STATE" "$acct")
    [ -n "$room" ] || continue
    printf '%s|%s|%s|%s\n' "$id" "$kind" "$acct" "$room"
  done <<<"$agents"
}

cmd_status() {
  local json=0 ttl='' agents accounts floor name provider dir status left reset runway
  local now on others pref pick moves line pct outlook live
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --refresh) ttl=0 ;;
      *) die "unknown status option: $1" ;;
    esac
    shift
  done
  need_registry
  accounts=$(account_rows "${ttl:-${FM_ACCOUNT_USAGE_TTL:-120}}")
  agents=$(collect_agents)
  floor=$(fm_account_floor "$CONFIG")
  pref=$(fm_account_new_spawn_preference "$CONFIG")
  pick=
  [ -z "$pref" ] || pick=$(fm_account_pick "$CONFIG" "$STATE" "$pref")
  moves=$(plan_moves "$agents")
  if [ "$json" = 1 ]; then
    jq -n --arg floor "$floor" --arg pref "$pref" --arg pick "$pick" \
      --arg accounts "$(with_outlook "$accounts" "$floor")" --arg agents "$agents" --arg moves "$moves" \
      --arg advice "$(advice "$agents" "$accounts")" '
      def rows($s): $s | split("\n") | map(select(. != "") | split("|"));
      def num($v): if $v == "" or $v == null then null else ($v | tonumber) end;
      { floor: ($floor | tonumber),
        new_spawns: { preferred: (if $pref == "" then null else $pref end),
                      account: (if $pick == "" then null else $pick end) },
        accounts: [ rows($accounts)[] | { name: .[0], provider: .[1], login_folder: .[2],
          status: .[3], percent_left: num(.[4]), resets_at: num(.[5]),
          runway_seconds: num(.[6]), plan: (if (.[7] // "") == "" then null else .[7] end),
          outlook: (if .[1] == "claude" and (.[9] // "") != "" then .[9] else null end),
          low: (.[1] == "claude" and .[9] == "low") } ],
        agents: [ rows($agents)[] | { home: .[0], id: .[1], kind: .[2], harness: .[3],
          account: (if (.[4] // "") == "" then null else .[4] end), basis: .[5], direct: (.[6] == "1"),
          live_account: (if (.[7] // "") == "" or .[7] == "unknown" then null else .[7] end),
          live_mismatch: ((.[7] // "") != "" and .[7] != "unknown" and .[7] != (if (.[4] // "") == "" then "unregistered" else .[4] end)) } ],
        moves: [ rows($moves)[] | { id: .[0], kind: .[1], from: .[2], to: .[3] } ],
        advice: ($advice | split("\n") | map(select(. != ""))) }'
    return
  fi
  now=$(date +%s)
  printf 'Accounts  (floor %s%%)\n' "$floor"
  while IFS='|' read -r name provider _ status left reset runway _ _ outlook; do
    [ -n "$name" ] || continue
    pct='?'
    [ -z "$left" ] || pct="$left%"
    line=$(printf '%-8s %-6s %4s  runway %-6s resets %s' "$name" "$provider" \
      "$pct" "$(fmt_duration "$runway")" \
      "$( [ -n "$reset" ] && printf 'in %s' "$(fmt_duration $((reset > now ? reset - now : 0)))" || printf -- '-')")
    case "$status" in
      fresh | '') ;;
      expired) line="$line  [expired: renews on next use]" ;;
      *) line="$line  [$status]" ;;
    esac
    if [ "$provider" = claude ]; then
      case "$outlook" in
        low) line="$line  LOW" ;;
        draining) line="$line  RUNNING OUT" ;;
        resets) line="$line  low, resets first" ;;
      esac
    fi
    printf '%s\n' "$line"
    on=$(printf '%s\n' "$agents" | awk -F'|' -v a="$name" '
      $5 == a && ($3 == "session" || $3 == "secondmate") { s = s (s ? ", " : "") $2 ($6 == "inferred" ? "~" : "") }
      $5 == a && $3 != "session" && $3 != "secondmate" { w++ }
      END { if (w) s = s (s ? " +" : "") w " worker" (w > 1 ? "s" : ""); print s }')
    [ -z "$on" ] || printf '    on it: %s\n' "$on"
  done <<<"$(with_outlook "$accounts" "$floor")"
  others=$(printf '%s\n' "$agents" | awk -F'|' '$6 == "other" { n++ } END { print n + 0 }')
  [ "$others" = 0 ] || printf '  other harnesses: %s worker(s)\n' "$others"
  if [ -n "$pick" ]; then
    if [ "$pick" = "$pref" ]; then printf 'New spawns: %s\n' "$pick"
    elif fm_account_is_low "$CONFIG" "$STATE" "$pref"; then printf 'New spawns: %s (%s is below the floor)\n' "$pick" "$pref"
    else printf 'New spawns: %s (%s is running out before its reset)\n' "$pick" "$pref"; fi
  fi
  if [ -n "$moves" ]; then
    printf 'Moving automatically:\n'
    printf '%s\n' "$moves" | awk -F'|' '{ printf "  %s  %s -> %s\n", $1, $3, $4 }'
  fi
  live=$(printf '%s\n' "$agents" | awk -F'|' '$4 == "claude" && $8 != "" {
      tag = ($8 != "unknown" && $8 != ($5 == "" ? "unregistered" : $5)) ? "  MISMATCH" : ""
      printf "  %-22s recorded %-10s live %s%s\n", (($7 == "1" || $3 == "session") ? $2 : $1 "/" $2), ($5 == "" ? "-" : $5) ($6 == "inferred" ? "~" : ""), $8, tag }')
  [ -z "$live" ] || printf 'Agents (recorded / live login):\n%s\n' "$live"
  advice "$agents" "$accounts" | sed 's/^/Needs the captain: /'
  if [ -s "$MOVES_LOG" ]; then
    printf 'Recent moves:\n'
    tail -n 3 "$MOVES_LOG" | while IFS='|' read -r reset name provider dir status; do
      printf '  %s ago  %s  %s -> %s  %s\n' "$(fmt_duration $((now - reset)))" "$name" "$provider" "$dir" "$status"
    done
  fi
}

# move_check <id> <account>: validate one direct report for a move to a Claude
# account; sets MOVE_META MOVE_KIND MOVE_FROM MOVE_HOME. Prints the refusal.
move_check() {
  local id=$1 acct=$2 harness
  MOVE_META="$STATE/$id.meta" MOVE_KIND='' MOVE_FROM='' MOVE_HOME=''
  [ -f "$MOVE_META" ] || { echo "error: no task $id in this home" >&2; return 1; }
  fm_account_get "$CONFIG" "$acct" || { echo "error: $FM_ACCOUNT_ERROR" >&2; return 1; }
  [ "$FM_ACCOUNT_PROVIDER" = claude ] || { echo "error: account $acct is a $FM_ACCOUNT_PROVIDER login; only Claude accounts can be switched" >&2; return 1; }
  [ -d "$FM_ACCOUNT_DIR" ] || { echo "error: sign in to account $acct first: login folder $FM_ACCOUNT_DIR does not exist" >&2; return 1; }
  MOVE_KIND=$(fm_account_meta_get "$MOVE_META" kind)
  harness=$(fm_account_meta_get "$MOVE_META" harness)
  [ "$harness" = claude ] || { echo "error: $id runs on $harness, not Claude; account switching covers Claude workers only" >&2; return 1; }
  MOVE_FROM=$(fm_account_recorded_name "$MOVE_META")
  [ "$MOVE_KIND" = secondmate ] || return 0
  [ -z "$(fm_account_meta_get "$MOVE_META" remote_host)" ] || { echo "error: $id is a remote second mate; switch its account on its own host" >&2; return 1; }
  MOVE_HOME=$(fm_account_meta_get "$MOVE_META" home)
  [ -n "$MOVE_HOME" ] && [ -d "$MOVE_HOME" ] || { echo "error: $id has no local home recorded" >&2; return 1; }
}

# move_verify <id> <from> <account> <exit>: report and log whether the task
# record now carries <account>.
move_verify() {
  if [ "$(fm_account_recorded_name "$STATE/$1.meta")" = "$3" ]; then
    echo "moved: $1 ${2:-unrecorded} -> $3"
    log_move "$1" "$2" "$3" moved
    return 0
  fi
  echo "error: $1 did not come back on $3 (exit $4); its record still reads ${2:-unrecorded}" >&2
  log_move "$1" "$2" "$3" failed
  return 1
}

# restart_mates <account-for-each "id=account"...>: pin every second mate, then
# one persist-gated restart for all of them, then verify each.
restart_mates() {
  local pair id acct ids=() froms=() accts=() i rc=0 status=0
  for pair in "$@"; do
    id=${pair%%=*} acct=${pair#*=}
    move_check "$id" "$acct" || { status=1; continue; }
    fm_account_write_name "$MOVE_HOME/config/account" "$acct" || { echo "error: could not record account $acct for $id" >&2; status=1; continue; }
    if [ "$MOVE_FROM" = "$acct" ]; then
      echo "unchanged: $id already runs on $acct"
      continue
    fi
    ids+=("$id") froms+=("$MOVE_FROM") accts+=("$acct")
  done
  [ "${#ids[@]}" -gt 0 ] || return "$status"
  "$SCRIPT_DIR/fm-secondmate-restart.sh" "${ids[@]}" || rc=$?
  for i in "${!ids[@]}"; do
    move_verify "${ids[$i]}" "${froms[$i]}" "${accts[$i]}" "$rc" || status=1
  done
  return "$status"
}

# move_crew <id> <account> <note>: relaunch one ship or scout onto <account>
# while it is between steps; 2 means not now.
move_crew() {
  local id=$1 acct=$2 note=$3 reason rc=0
  move_check "$id" "$acct" || return 1
  if [ "$MOVE_FROM" = "$acct" ]; then
    echo "unchanged: $id already runs on $acct"
    return 0
  fi
  if ! reason=$(crew_movable "$id"); then
    echo "waiting: $id is not between steps ($reason); it moves on a later run" >&2
    return 2
  fi
  [ -n "$note" ] || note="Your subscription account changed from ${MOVE_FROM:-its previous login} to $acct because the old one was running out. Nothing else changed: continue this task from the local copy, its commits, and your instructions."
  FM_SPAWN_ACCOUNT=$acct "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note "$note" || rc=$?
  move_verify "$id" "$MOVE_FROM" "$acct" "$rc"
}

cmd_use() {
  local id='' acct='' norelaunch=0 note=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-relaunch) norelaunch=1 ;;
      --note) [ $# -ge 2 ] || die "--note needs text"; note=$2; shift ;;
      -*) die "unknown use option: $1" ;;
      *) if [ -z "$id" ]; then id=$1; elif [ -z "$acct" ]; then acct=$1; else die "use takes <task-id> <account>"; fi ;;
    esac
    shift
  done
  [ -n "$id" ] && [ -n "$acct" ] || die "usage: fm-account.sh use <task-id> <account> [--no-relaunch] [--note <text>]"
  need_registry
  case "$id" in main | "$(self_label)")
    fm_account_get "$CONFIG" "$acct" || die "$FM_ACCOUNT_ERROR"
    die "this home's own session cannot relaunch itself; exit it, then start it again with CLAUDE_CONFIG_DIR=$FM_ACCOUNT_DIR"
    ;;
  esac
  move_check "$id" "$acct" || exit 1
  if [ "$MOVE_KIND" = secondmate ]; then
    if [ "$norelaunch" = 1 ]; then
      fm_account_write_name "$MOVE_HOME/config/account" "$acct" || die "could not record account $acct for $id"
      log_move "$id" "$MOVE_FROM" "$acct" pinned
      echo "recorded: $id is pinned to $acct; its next relaunch or respawn uses it"
      return 0
    fi
    restart_mates "$id=$acct"
    return
  fi
  [ "$norelaunch" = 0 ] || die "--no-relaunch applies to second mates only; a worker keeps its account in its task record"
  move_crew "$id" "$acct" "$note"
}

cmd_default() {
  [ $# -eq 1 ] || die "usage: fm-account.sh default <account>|--clear"
  need_registry
  if [ "$1" = --clear ]; then
    rm -f "$CONFIG/spawn-account"
    echo "cleared: new spawns start from this session's own account"
    return
  fi
  fm_account_get "$CONFIG" "$1" || die "$FM_ACCOUNT_ERROR"
  [ "$FM_ACCOUNT_PROVIDER" = claude ] || die "account $1 is a $FM_ACCOUNT_PROVIDER login; new spawns need a Claude account"
  fm_account_write_name "$CONFIG/spawn-account" "$1" || die "could not write config/spawn-account"
  echo "default: new spawns start on $1"
}

cmd_rebalance() {
  local check=0 dry=0 agents accounts moves adv id kind from to fp last stamp quiet now line ready mates window
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1 ;;
      --dry-run) dry=1 ;;
      *) die "unknown rebalance option: $1" ;;
    esac
    shift
  done
  if [ "$check" = 1 ]; then
    fm_account_list "$CONFIG" >/dev/null 2>&1 || { echo "accounts: config/accounts is malformed: $FM_ACCOUNT_ERROR"; return 0; }
    [ -f "$(fm_account_registry "$CONFIG")" ] || return 0
  else
    need_registry
  fi
  agents=$(collect_agents)
  accounts=$(account_rows "${FM_ACCOUNT_USAGE_TTL:-120}")
  moves=$(plan_moves "$agents")
  adv=$(advice "$agents" "$accounts" captain)
  if [ "$check" = 1 ]; then
    ready=
    while IFS='|' read -r id kind from to; do
      [ -n "$id" ] || continue
      [ "$kind" = secondmate ] || crew_movable "$id" >/dev/null || continue
      ready+="$id|$kind|$from|$to"$'\n'
    done <<<"$moves"
    moves=${ready%$'\n'}
    fp=$(printf '%s\n%s' "$moves" "$adv" | cksum | awk '{ print $1 }')
    now=$(date +%s)
    last='' stamp=0 quiet=''
    [ -f "$STATE/.account-check" ] && IFS='|' read -r stamp last quiet <"$STATE/.account-check"
    case "$stamp" in '' | *[!0-9]*) stamp=0 ;; esac
    case "$quiet" in *[!0-9]*) quiet='' ;; esac
    window=${FM_ACCOUNT_SIGNIN_CONFIRM_SECS:-900}
    case "$window" in '' | *[!0-9]*) window=900 ;; esac
    # Quiet advice keeps the last fingerprint and notes when it went quiet, so
    # the same advice returning inside the window is not a new wake; a ready
    # move returning after a quiet spell always wakes.
    if [ -z "$moves$adv" ]; then
      [ ! -f "$STATE/.account-check" ] || [ -n "$quiet" ] ||
        printf '%s|%s|%s\n' "$stamp" "$last" "$now" >"$STATE/.account-check" 2>/dev/null || true
      return 0
    fi
    if [ "$fp" = "$last" ] && { [ -z "$quiet" ] || { [ -z "$moves" ] && [ $((now - quiet)) -lt "$window" ]; }; } &&
      { [ -z "$moves" ] || [ $((now - stamp)) -lt 1800 ]; }; then
      [ -z "$quiet" ] || printf '%s|%s|\n' "$stamp" "$last" >"$STATE/.account-check" 2>/dev/null || true
      return 0
    fi
    printf '%s|%s|\n' "$now" "$fp" >"$STATE/.account-check" 2>/dev/null || true
    line='accounts:'
    [ -z "$moves" ] || line="$line $(printf '%s\n' "$moves" | awk -F'|' '{ s = s (s ? ", " : "") $1 " " $3 "->" $4 } END { print s }') - run bin/fm-account.sh rebalance (automatic, no captain approval);"
    [ -z "$adv" ] || line="$line needs the captain: $(printf '%s\n' "$adv" | paste -sd';' - | sed 's/;/; /g')"
    printf '%s\n' "${line%;}"
    return 0
  fi
  if [ -z "$moves" ] && ! readings_blind "$accounts"; then
    echo "balanced: no agent needs to move"
  fi
  mates=()
  while IFS='|' read -r id kind from to; do
    [ -n "$id" ] || continue
    if [ "$dry" = 1 ]; then
      echo "would move: $id $from -> $to"
    elif [ "$kind" = secondmate ]; then
      mates+=("$id=$to")
    else
      move_crew "$id" "$to" "" 2>&1 || true
    fi
  done <<<"$moves"
  if [ "${#mates[@]}" -gt 0 ]; then
    restart_mates "${mates[@]}" 2>&1 || true
  fi
  [ -z "$adv" ] || printf '%s\n' "$adv" | sed 's/^/needs the captain: /'
  return 0
}

check_body() {
  printf '#!/bin/sh\n# Generated by bin/fm-account.sh auto: automatic subscription-account rebalancing.\nexec env FM_HOME=%s %s rebalance --check\n' \
    "$(printf '%q' "$FM_HOME")" "$(printf '%q' "$FM_ROOT/bin/fm-account.sh")"
}

cmd_auto() {
  local mode=${1:-} want=0 check="$STATE/$CHECK_ID.check.sh" body
  case "$mode" in
    on | off) fm_account_write_name "$CONFIG/account-auto" "$mode" || die "could not write config/account-auto" ;;
    sync) ;;
    *) die "usage: fm-account.sh auto on|off|sync" ;;
  esac
  if [ -f "$(fm_account_registry "$CONFIG")" ] && [ "$(fm_account_read_name "$CONFIG/account-auto")" != off ]; then
    want=1
  fi
  if [ "$want" = 0 ]; then
    if [ -e "$check" ]; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || die "could not retire state/$CHECK_ID.check.sh"
      echo "auto: automatic account rebalancing off"
    elif [ "$mode" != sync ]; then
      echo "auto: automatic account rebalancing off"
    fi
    return 0
  fi
  [ -d "$STATE" ] || die "state directory $STATE is missing"
  body=$(check_body)
  if [ -f "$check" ] && [ "$(cat "$check")" = "$body" ] && [ -f "$STATE/$CHECK_ID.check-trust" ]; then
    [ "$mode" = sync ] || echo "auto: automatic account rebalancing on"
    return 0
  fi
  if ! { (umask 077 && printf '%s\n' "$body" >"$check.tmp.$$") && chmod 0700 "$check.tmp.$$" && mv -f "$check.tmp.$$" "$check"; }; then
    rm -f "$check.tmp.$$"
    die "could not write state/$CHECK_ID.check.sh"
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || die "could not register state/$CHECK_ID.check.sh"
  echo "auto: automatic account rebalancing on"
}

panel_pid() {
  local pid=
  [ -f "$STATE/.account-panel" ] && IFS= read -r pid <"$STATE/.account-panel"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -q 'fm-account.sh watch' || return 1
  printf '%s' "$pid"
}

cmd_panel() {
  local pid out pane args
  if pid=$(panel_pid); then
    kill -TERM "$pid" 2>/dev/null || die "could not stop the accounts panel (pid $pid)"
    echo "panel: closed"
    return 0
  fi
  if [ "${HERDR_ENV:-}" != 1 ] || [ -z "${HERDR_PANE_ID:-}" ] || [ -z "${HERDR_SESSION:-}" ]; then
    echo "panel: not inside a Herdr pane; run 'FM_HOME=$FM_HOME $FM_ROOT/bin/fm-account.sh watch' in any terminal instead"
    return 0
  fi
  need_registry
  args=(pane split --pane "$HERDR_PANE_ID" --direction right --no-focus --cwd "$FM_ROOT" --env "FM_HOME=$FM_HOME")
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || args+=(--env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR")
  [ -z "${FM_ACCOUNT_PANEL_RATIO:-}" ] || args+=(--ratio "$FM_ACCOUNT_PANEL_RATIO")
  out=$("${HERDR_BIN_PATH:-herdr}" "${args[@]}" --session "$HERDR_SESSION" 2>&1) || die "herdr could not split this pane: $out"
  pane=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ -n "$pane" ] || die "herdr split returned no pane id: $out"
  out=$("${HERDR_BIN_PATH:-herdr}" pane run "$pane" "exec $(printf '%q' "$FM_ROOT/bin/fm-account.sh") watch" --session "$HERDR_SESSION" 2>&1) \
    || die "herdr could not start the panel in pane $pane: $out"
  echo "panel: open in pane $pane (run this again to close it)"
}

prompt_pick() {  # <prompt> <options...>: echo the chosen option or nothing
  local p=$1 i=1 o n
  shift
  [ $# -gt 0 ] || return 0
  printf '%s\n' "$p" >/dev/tty
  for o in "$@"; do printf '  %d) %s\n' "$i" "$o" >/dev/tty; i=$((i + 1)); done
  printf '> ' >/dev/tty
  IFS= read -r n </dev/tty || return 0
  case "$n" in '' | *[!0-9]*) return 0 ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le $# ] || return 0
  eval "printf '%s' \"\${$n}\""
}

claude_accounts() {
  fm_account_list "$CONFIG" | awk -F'\t' '$2 == "claude" { print $1 }'
}

cmd_watch() {
  local once=0 interval=60 key refresh='' id acct ids=() accts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --once) once=1 ;;
      --interval) [ $# -ge 2 ] || die "--interval needs seconds"; interval=$2; shift ;;
      *) die "unknown watch option: $1" ;;
    esac
    shift
  done
  if [ "$once" = 1 ]; then
    cmd_status
    return
  fi
  printf '%s\n' "$$" >"$STATE/.account-panel" 2>/dev/null || true
  trap 'rm -f "$STATE/.account-panel"; exit 0' TERM INT HUP
  while :; do
    clear 2>/dev/null || printf '\033[H\033[2J'
    (cmd_status $refresh) 2>&1
    refresh=''
    printf '\n[r]efresh [s]witch [d]efault [a] rebalance [q]uit\n'
    key=
    IFS= read -rsn1 -t "$interval" key </dev/tty || true
    case "$key" in
      q) break ;;
      r) refresh=--refresh ;;
      a) (cmd_rebalance) || true; printf 'press Enter'; read -r _ </dev/tty || true ;;
      d)
        mapfile -t accts < <(claude_accounts)
        acct=$(prompt_pick 'New spawns start on:' "${accts[@]}")
        [ -z "$acct" ] || (cmd_default "$acct") || true
        sleep 1
        ;;
      s)
        mapfile -t ids < <(collect_agents | awk -F'|' '$7 == 1 && $4 == "claude" { print $2 }')
        id=$(prompt_pick 'Move which agent?' "${ids[@]}")
        mapfile -t accts < <(claude_accounts)
        [ -z "$id" ] || acct=$(prompt_pick "Move $id to:" "${accts[@]}")
        if [ -n "$id" ] && [ -n "$acct" ]; then
          (cmd_use "$id" "$acct") || true
          printf 'press Enter'
          read -r _ </dev/tty || true
        fi
        ;;
    esac
  done
  rm -f "$STATE/.account-panel"
}

case "${1:-}" in
  -h | --help | '') usage; exit 0 ;;
esac
cmd=$1
shift
case "$cmd" in
  status) cmd_status "$@" ;;
  use) cmd_use "$@" ;;
  default) cmd_default "$@" ;;
  rebalance) cmd_rebalance "$@" ;;
  auto) cmd_auto "$@" ;;
  panel) cmd_panel "$@" ;;
  watch) cmd_watch "$@" ;;
  *) usage >&2; exit 2 ;;
esac
