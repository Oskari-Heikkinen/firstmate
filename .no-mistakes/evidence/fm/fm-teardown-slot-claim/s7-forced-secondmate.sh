#!/usr/bin/env bash
. "$(dirname "$0")/live-drive-lib.sh"
O=lattice-auto-return S=lattice-gen-audit-search P=lattice-mate
echo "################ S7: forced teardown of the lattice-mate secondmate home whose two children share the claimed slot -> slot returned exactly once, both child records cleared"
setup_case s7
ROOT_HOME="$L/root"; mkdir -p "$ROOT_HOME/state" "$ROOT_HOME/data" "$ROOT_HOME/config"
printf '%s' "$P" > "$HOMEDIR/.fm-secondmate-home"
meta "$ROOT_HOME/state/$P.meta" "window=firstmate:fm-$P" "endpoint_task_id=$P" "worktree=$HOMEDIR" "project=$HOMEDIR" "home=$HOMEDIR" \
  "kind=secondmate" "mode=secondmate" "harness=echo" "yolo=off" "projects=alpha"
tmux new-window -d -t firstmate -n "fm-$P" -c "$HOMEDIR"
meta "$HOMEDIR/state/$O.meta" "window=firstmate:fm-$O" "endpoint_task_id=$O" "worktree=$SLOT" "project=$L/project" "kind=ship"
window_idle "$O"
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
claim "$O"
echo "=== root home $ROOT_HOME holds secondmate $P; $HOMEDIR holds $O (claim owner, idle window) and parked $S (no window) on one slot"
teardown "$ROOT_HOME" "$P" --force
show_state
echo "root records: $(cd "$ROOT_HOME/state" && ls *.meta 2>/dev/null | tr '\n' ' ')"
echo "treehouse return count for the slot: $(grep -c "^treehouse return.*$SLOT" "$L/treehouse-calls.log" 2>/dev/null || echo 0)"
echo "slot dir still exists: $([ -d "$SLOT" ] && echo yes || echo no)"
cleanup_case
