#!/usr/bin/env bash
# Live lab driver: five dead secondmates on a real (private-socket) tmux server,
# then the real session-start network phase (FM_BOOTSTRAP_NETWORK=only
# bin/fm-bootstrap.sh), which runs the deferred secondmate-liveness sweep that
# relaunches them in parallel through bin/fm-spawn.sh with the real claude CLI.
# Usage: lab-sweep-driver.sh <code-root> <label> <evidence-dir>
set -u
CODE=$1 LABEL=$2 EVD=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
MATES=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-mates.XXXXXX")
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || \
  /home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M3VMRRM8785SBTS6ZPPZ9EQB/bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null || true; chmod -R u+w "$LAB" "$MATES" 2>/dev/null; rm -rf "$LAB" "$MATES"; }
trap cleanup EXIT
touch "$LAB/state/.last-watcher-beat"
printf 'claude\n' > "$LAB/config/crew-harness"
IDS="mate1 mate2 mate3 mate4 mate5"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s firstmate -n primary -c "$CODE" -e FM_HOME="$LAB" bash
for id in $IDS; do
  home="$MATES/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  printf 'window=firstmate:fm-%s\nkind=secondmate\nharness=claude\nhome=%s\n' "$id" "$home" > "$LAB/state/$id.meta"
  # A dead secondmate: its window survives as a bare shell after the agent exited.
  T new-window -d -t firstmate -n "fm-$id" -c "$home" bash
done
{
  echo "== [$LABEL] before sweep: windows and foreground commands on the lab tmux server"
  T list-windows -t firstmate -F '#{window_name} #{pane_current_command}'
} > "$EVD/$LABEL-transcript.txt"
start=$(date +%s)
T new-window -d -t firstmate -n runner -c "$CODE" \
  "env FM_BACKEND=tmux FM_HOME='$LAB' FM_ADMISSION_RUN_DIR='$LAB/admission' FM_MEM_GUARD_DIR='$LAB/mem-guard' FM_BOOTSTRAP_NETWORK=only '$CODE/bin/fm-bootstrap.sh' > '$LAB/bootstrap.out' 2>&1; echo \$? > '$LAB/bootstrap.rc'"
i=0
while [ ! -s "$LAB/bootstrap.rc" ] && [ "$i" -lt 600 ]; do sleep 1; i=$((i + 1)); done
end=$(date +%s)
{
  echo
  echo "== [$LABEL] FM_BOOTSTRAP_NETWORK=only bin/fm-bootstrap.sh exited rc=$(cat "$LAB/bootstrap.rc" 2>/dev/null || echo TIMEOUT) after $((end - start))s; output:"
  cat "$LAB/bootstrap.out"
  echo
  echo "== [$LABEL] after sweep: windows and foreground commands"
  T list-windows -t firstmate -F '#{window_name} #{pane_current_command}'
  echo
  echo "== [$LABEL] per-mate relaunch ledgers (state/.secondmate-relaunch-<id>)"
  for id in $IDS; do printf '%s: ' "$id"; tr '\n' ' ' < "$LAB/state/.secondmate-relaunch-$id" 2>/dev/null; echo; done
  echo
  echo "== [$LABEL] admission ledger"
  cat "$LAB/admission/admitted" 2>/dev/null
} >> "$EVD/$LABEL-transcript.txt"
cat "$EVD/$LABEL-transcript.txt"
