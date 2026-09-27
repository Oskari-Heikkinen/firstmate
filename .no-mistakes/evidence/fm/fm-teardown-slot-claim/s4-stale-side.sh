#!/usr/bin/env bash
. "$(dirname "$0")/live-drive-lib.sh"
O=lattice-auto-return S=lattice-gen-audit-search
echo "################ S4: stale side - tear down the parked scout while the claim names the owner -> scout records go, owner's slot/window/claim untouched"
setup_case s4
meta "$HOMEDIR/state/$O.meta" "window=firstmate:fm-$O" "endpoint_task_id=$O" "worktree=$SLOT" "project=$L/project" "kind=ship"
window_idle "$O"
echo "sentinel" >> "$(git -C "$SLOT" rev-parse --git-common-dir)/info/exclude"; : > "$SLOT/sentinel"
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
mkdir -p "$HOMEDIR/data/$S"; echo "# report" > "$HOMEDIR/data/$S/report.md"
claim "$O"
echo "\$ FM_HOME=$HOMEDIR bin/fm-captain-hold.sh complete $S --none"
FM_HOME="$HOMEDIR" "$REPO/bin/fm-captain-hold.sh" complete "$S" --none 2>&1; echo "[exit $?]"
owner_pane_pid=$(tmux list-panes -t "firstmate:fm-$O" -F '#{pane_pid}')
teardown "$HOMEDIR" "$S"; show_state
echo "owner pane shell pid $owner_pane_pid alive: $(kill -0 "$owner_pane_pid" 2>/dev/null && echo yes || echo no)"
cleanup_case
