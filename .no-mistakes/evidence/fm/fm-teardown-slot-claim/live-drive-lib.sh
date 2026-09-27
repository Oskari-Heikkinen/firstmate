#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh, real treehouse pool, real tmux on an
# isolated server (TMUX_TMPDIR), isolated FM_HOME. Nothing touches the operator's
# tmux/herdr sessions or fleet FM_HOME.
unset TMUX TMUX_PANE
# Sandbox fleet only (temp FM_HOME, private tmux server, private treehouse pool):
# the documented test-harness escape hatch from bin/fm-gate-refuse-lib.sh.
export FM_GATE_REFUSE_BYPASS=1
REPO=${REPO:?}
setup_case() {  # <name> -> sets L, SLOT, HOMEDIR
  L=$(mktemp -d "/tmp/fm-live-$1.XXXX")
  export TMUX_TMPDIR="$L/tmux"; mkdir -p "$TMUX_TMPDIR"
  export TREEHOUSE_ROOT="$L/pool"
  git init -q --bare "$L/origin.git"
  git clone -q "$L/origin.git" "$L/project" 2>/dev/null
  git -C "$L/project" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
  git -C "$L/project" push -q origin HEAD:main
  git -C "$L/project" fetch -q origin
  SLOT=$(cd "$L/project" && treehouse get --lease --no-fetch --lease-holder fm-live 2>/dev/null)
  git -C "$SLOT" checkout -q --detach origin/main
  HOMEDIR="$L/lattice-mate"
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/data" "$HOMEDIR/config"
  mkdir -p "$L/bin"; cp /bin/sleep "$L/bin/claude"
  # Logging shim in front of the REAL treehouse so treehouse invocations can be counted.
  mkdir -p "$L/shim"; printf '#!/usr/bin/env bash\nprintf "treehouse %%s\\n" "$*" >> "%s/treehouse-calls.log"\nexec %s "$@"\n' "$L" "$(command -v treehouse)" > "$L/shim/treehouse"; chmod +x "$L/shim/treehouse"; export PATH="$L/shim:$PATH"
  tmux new-session -d -s firstmate -n keep -c "$L" "sleep 3600"
}
meta() {  # <file> k=v...
  local f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
}
claim() {  # <task> [home]
  printf 'task=%s\nhome=%s\n' "$1" "${2:-$HOMEDIR}" > "$(dirname "$SLOT")/.fm-slot-owner"
}
window_idle() { tmux new-window -d -t firstmate -n "fm-$1" -c "$SLOT"; }          # shell only -> dead
window_agent() { tmux new-window -d -t firstmate -n "fm-$1" -c "$SLOT" "$L/bin/claude 3600"; }  # comm=claude -> alive
teardown() {  # <home> <id> [flags]
  local home=$1; shift
  echo "\$ FM_HOME=$home bin/fm-teardown.sh $*"
  FM_HOME="$home" "$REPO/bin/fm-teardown.sh" "$@" 2>&1; local rc=$?
  echo "[exit $rc]"; return $rc
}
show_state() {
  echo "--- state after ---"
  echo "records: $(cd "$HOMEDIR/state" && ls *.meta 2>/dev/null | tr '\n' ' ')"
  if [ -f "$(dirname "$SLOT")/.fm-slot-owner" ]; then echo "claim: $(tr '\n' ' ' < "$(dirname "$SLOT")/.fm-slot-owner")"; else echo "claim: <none>"; fi
  echo "tmux windows: $(tmux list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')"
  echo "sentinel in slot: $([ -e "$SLOT/sentinel" ] && echo present || echo gone)"
  echo "claude (relaunched agent) processes alive: $(pgrep -f "$L/bin/claude" | wc -l)"
  echo "treehouse calls: $(grep -v '^treehouse status' "$L/treehouse-calls.log" 2>/dev/null | grep -v '^treehouse get' | tr '\n' ';')"
  echo "treehouse status: $(cd "$L/project" && treehouse status 2>/dev/null | grep -v -e 'new version' -e 'treehouse update' -e '^$')"
}
cleanup_case() { tmux kill-server 2>/dev/null || true; rm -rf "$L"; }
