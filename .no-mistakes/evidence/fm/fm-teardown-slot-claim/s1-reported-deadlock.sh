#!/usr/bin/env bash
# Scenario 1: the reported deadlock. lattice-auto-return owns pool slot (claim names it);
# parked scout lattice-gen-audit-search still names the same slot, its endpoint is gone.
. "$(dirname "$0")/live-drive-lib.sh"
setup_case s1
O=lattice-auto-return S=lattice-gen-audit-search
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
meta "$HOMEDIR/state/$O.meta" "window=firstmate:fm-$O" "endpoint_task_id=$O" "worktree=$SLOT" "project=$L/project" "kind=ship"
claim "$O"
window_idle "$O"
echo "sentinel" >> "$(git -C "$SLOT" rev-parse --git-common-dir)/info/exclude"; : > "$SLOT/sentinel"
echo "=== slot: $SLOT"
echo "=== records: $S (parked, no window) and $O (window fm-$O idle in slot); claim task=$O"
teardown "$HOMEDIR" "$O"
show_state
echo "scout record content kept: $(cat "$HOMEDIR/state/$S.meta" 2>/dev/null | tr '\n' ' ')"
cleanup_case
