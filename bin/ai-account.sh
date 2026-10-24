#!/usr/bin/env bash
# ai-account - switch the Claude and OpenAI subscriptions used on this machine.
#
#   ai-account                        overview: every account, quota left, and what runs on it
#   ai-account status                 show the active account per provider and the saved ones
#   ai-account move claude NAME       recorded move through FM_HOME/bin/fm-account.sh
#                                     (this chat session: restart it yourself)
#   ai-account add claude|openai NAME  create account NAME and log it in (interactive, once)
#   ai-account use claude|openai NAME  make NAME the active account
#   ai-account quota                  show the quota left on every saved Claude account (and OpenAI)
#
# What an account covers:
#   claude: Claude Code (config folder ~/.claude for "main", ~/.claude-NAME otherwise, picked by
#           the ~/.local/bin/claude wrapper) and Pi's "anthropic" login.
#   openai: Codex CLI (~/.codex for "main", ~/.codex-NAME otherwise, picked by ~/.local/bin/codex)
#           and Pi's "openai-codex" login.
# Pi keeps one login per provider in ~/.pi/agent/auth.json and re-reads it under its own lock on
# every request, so "use" swaps that entry under the same lock and running Pi workers move to the
# new account at their next request. Claude Code and Codex sessions already running keep the
# account they started with until restarted; new ones start on the active account.
# Every folder except the login is shared (symlinked), so settings, memory, skills, plugins and
# history are the same whichever account is active.
# Tracked source: bin/ai-account.sh; install as ~/.local/bin/ai-account.
# Requires the existing Claude/Codex wrappers and ~/.config/ai-accounts/quota-line.py.
# move uses FM_HOME (default /home/oskari/Tools/firstmate); see fm-account.sh --help.
# shellcheck disable=SC2034 # Preserve the imported retry loop.
set -euo pipefail

CFG="$HOME/.config/ai-accounts"
PI_AUTH="$HOME/.pi/agent/auth.json"
mkdir -p "$CFG/pi/anthropic" "$CFG/pi/openai-codex"
chmod 700 "$CFG"

die() { echo "ai-account: $*" >&2; exit 1; }

pi_provider() { case "$1" in claude) echo anthropic ;; openai) echo openai-codex ;; *) die "provider must be claude or openai" ;; esac; }
cli_base() { case "$1" in claude) echo "$HOME/.claude" ;; openai) echo "$HOME/.codex" ;; esac; }
cli_login_file() { case "$1" in claude) echo ".credentials.json" ;; openai) echo "auth.json" ;; esac; }
cli_dir() { local base; base=$(cli_base "$1"); [ "$2" = main ] && echo "$base" || echo "$base-$2"; }
active() { cat "$CFG/active-$1" 2>/dev/null || echo main; }
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "account name must be lowercase letters, digits or dashes"; }

# Run a python snippet on Pi's auth.json while holding Pi's own lock (proper-lockfile: <file>.lock dir).
with_pi_lock() {
  local lock="$PI_AUTH.lock" i
  for i in $(seq 1 100); do mkdir "$lock" 2>/dev/null && break; sleep 0.1; done
  [ -d "$lock" ] || die "Pi's login file stayed locked; try again"
  trap 'rmdir "$PI_AUTH.lock" 2>/dev/null || true' EXIT
  python3 - "$@"
  rmdir "$lock"; trap - EXIT
}

# Save the Pi entry for provider $1 into profile $2 (from auth file $3, default Pi's live one).
pi_save() {
  local prov=$1 name=$2 src=${3:-$PI_AUTH}
  local out="$CFG/pi/$prov/$name.json"
  python3 - "$src" "$prov" "$out" <<'PY'
import json, os, sys
src, prov, out = sys.argv[1:]
data = json.load(open(src)) if os.path.exists(src) else {}
if prov not in data:
    sys.exit(f"ai-account: no {prov} login found in {src}")
fd = os.open(out + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data[prov], f)
os.replace(out + ".tmp", out)
PY
}

# Record the current logins as "main" the first time the tool runs.
init() {
  local p prov
  for p in claude openai; do
    prov=$(pi_provider "$p")
    [ -f "$CFG/active-$p" ] || echo main > "$CFG/active-$p"
    if [ ! -f "$CFG/pi/$prov/main.json" ] && [ "$(active "$p")" = main ] && [ -f "$PI_AUTH" ]; then
      pi_save "$prov" main 2>/dev/null || true
    fi
  done
}

# Make a CLI config folder for a new account: symlink everything but the login.
make_cli_dir() {
  local p=$1 name=$2 base dir item login
  base=$(cli_base "$p"); dir=$(cli_dir "$p" "$name"); login=$(cli_login_file "$p")
  mkdir -p "$dir"; chmod 700 "$dir"
  for item in "$base"/* "$base"/.[!.]*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in "$login"|.claude.json|*.lock) continue ;; esac
    [ -e "$dir/$(basename "$item")" ] || ln -s "$item" "$dir/$(basename "$item")"
  done
  if [ "$p" = claude ] && [ -f "$HOME/.claude.json" ] && [ ! -f "$dir/.claude.json" ]; then
    # Claude Code keeps its main settings file inside the chosen folder; start from the current
    # one without the signed-in account so the new login fills that in.
    python3 - "$HOME/.claude.json" "$dir/.claude.json" <<'PY'
import json, os, sys
src, out = sys.argv[1:]
d = json.load(open(src))
for k in ("oauthAccount", "primaryApiKey", "customApiKeyResponses", "userID"):
    d.pop(k, None)
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
PY
  fi
}

cmd_status() {
  local p prov n
  for p in claude openai; do
    prov=$(pi_provider "$p")
    printf '%-7s active: %-10s saved:' "$p" "$(active "$p")"
    for n in "$CFG/pi/$prov"/*.json; do [ -e "$n" ] && printf ' %s' "$(basename "$n" .json)"; done
    echo
  done
}

# Quota for every saved Claude account (each read from its own login only), then OpenAI.
cmd_quota() {
  local n dir mark fmt="$CFG/quota-line.py"
  echo "Claude:"
  for n in "$CFG/pi/anthropic"/*.json; do
    [ -e "$n" ] || continue
    n=$(basename "$n" .json); dir=$(cli_dir claude "$n")
    mark=$([ "$(active claude)" = "$n" ] && echo ' (active)' || true)
    if [ -f "$dir/.credentials.json" ]; then
      CLAUDE_CONFIG_DIR=$dir quota-axi --provider claude --profile-only --json 2>/dev/null | python3 "$fmt" "$n$mark"
    else
      echo "  $n$mark: not logged in to Claude Code yet (ai-account add claude $n)"
    fi
  done
  echo "OpenAI:"
  quota-axi --provider codex --json 2>/dev/null | python3 "$fmt" "$(active openai) (active)"
}

# Running Claude Code processes per account (by CLAUDE_CONFIG_DIR; none means main).
claude_procs() {
  local p d
  for p in $(ps -eo pid=,comm= | awk '$2 ~ /^claude/ {print $1}'); do
    d=$(tr '\0' '\n' </proc/"$p"/environ 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p')
    case "$d" in ""|"$HOME/.claude") echo main ;; "$HOME/.claude-"*) echo "${d#"$HOME/.claude-"}" ;; esac
  done | sort | uniq -c | awk '{printf "  %s: %s running Claude session(s)\n", $2, $1}'
}

cmd_overview() {
  cmd_quota
  echo "Running now:"
  claude_procs
  echo "Automatic watch (every 5 min, moves new work off an account at <=10% left): $(systemctl --user is-active fm-account-watch.timer 2>/dev/null)"
  echo "Switch everything: ai-account move claude NAME"
}

# Only fm-account owns fleet moves and their records; use remains the login primitive.
cmd_move() {
  local fm=${FM_HOME:-/home/oskari/Tools/firstmate}
  [ -x "$fm/bin/fm-account.sh" ] || die "missing $fm/bin/fm-account.sh; set FM_HOME to the Firstmate home"
  FM_HOME=$fm "$fm/bin/fm-account.sh" move "$@"
}

cmd_add() {
  local p=$1 name=$2 prov tmp
  prov=$(pi_provider "$p"); valid_name "$name"
  [ "$name" != main ] || die "main is the account you already have"
  make_cli_dir "$p" "$name"
  echo "Step 1/2: log the new account into $([ "$p" = claude ] && echo 'Claude Code' || echo 'Codex')."
  if [ "$p" = claude ]; then
    echo "  In the Claude session that opens, run /login, sign in with the new account, then /exit."
    CLAUDE_CONFIG_DIR=$(cli_dir claude "$name") "$HOME/.local/npm/bin/claude" || true
  else
    CODEX_HOME=$(cli_dir openai "$name") "$HOME/.local/npm/bin/codex" login || true
  fi
  echo "Step 2/2: log the new account into Pi (used by the workers)."
  echo "  In the Pi session that opens, run /login, choose $([ "$p" = claude ] && echo 'Anthropic' || echo 'OpenAI Codex'), sign in with the new account, then quit."
  # Log in against a private copy of Pi's folder so the live workers are not switched mid-login.
  tmp=$(mktemp -d); chmod 700 "$tmp"
  for item in "$HOME/.pi/agent"/*; do
    case "$(basename "$item")" in auth.json|sessions) continue ;; esac
    ln -s "$item" "$tmp/$(basename "$item")"
  done
  mkdir "$tmp/sessions"
  PI_CODING_AGENT_DIR=$tmp "$HOME/.local/npm/bin/pi" || true
  if pi_save "$prov" "$name" "$tmp/auth.json"; then
    echo "Saved account $name for $p. Switch with: ai-account use $p $name"
  else
    echo "Pi login was not completed; rerun: ai-account add $p $name" >&2
  fi
  rm -rf "$tmp"
}

cmd_use() {
  local p=$1 name=$2 prov cur
  prov=$(pi_provider "$p"); valid_name "$name"
  cur=$(active "$p")
  [ -f "$CFG/pi/$prov/$name.json" ] || die "no saved $p account '$name' (see: ai-account status)"
  [ -d "$(cli_dir "$p" "$name")" ] || die "missing config folder $(cli_dir "$p" "$name")"
  if [ "$cur" = "$name" ]; then echo "$p is already on $name"; return; fi
  # Swap Pi's entry: keep the outgoing account's latest (possibly refreshed) login, put the new one in.
  with_pi_lock "$PI_AUTH" "$prov" "$CFG/pi/$prov/$cur.json" "$CFG/pi/$prov/$name.json" <<'PY'
import json, os, sys
auth, prov, save_to, take_from = sys.argv[1:]
data = json.load(open(auth)) if os.path.exists(auth) else {}
if prov in data:
    fd = os.open(save_to + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data[prov], f)
    os.replace(save_to + ".tmp", save_to)
data[prov] = json.load(open(take_from))
fd = os.open(auth + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(auth + ".tmp", auth)
PY
  echo "$name" > "$CFG/active-$p"
  echo "$p switched: $cur -> $name."
  echo "  Pi workers use $name from their next request."
  echo "  New $([ "$p" = claude ] && echo 'Claude Code' || echo 'Codex') sessions start on $name; running ones keep $cur until restarted."
}

init
case "${1:-overview}" in
  overview) cmd_overview ;;
  status) cmd_status ;;
  move) [ $# -eq 3 ] || die "usage: ai-account move claude NAME"; cmd_move "$2" "$3" ;;
  quota) cmd_quota ;;
  add) [ $# -eq 3 ] || die "usage: ai-account add claude|openai NAME"; cmd_add "$2" "$3" ;;
  use) [ $# -eq 3 ] || die "usage: ai-account use claude|openai NAME"; cmd_use "$2" "$3" ;;
  -h|--help|help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (overview, status, add, use, move, quota)" ;;
esac
