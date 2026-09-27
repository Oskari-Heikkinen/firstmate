#!/usr/bin/env bash
. "$(dirname "$0")/live-drive-lib.sh"
O=lattice-auto-return S=lattice-gen-audit-search
base_records() {  # <scout-kind-line...>
  meta "$HOMEDIR/state/$O.meta" "window=firstmate:fm-$O" "endpoint_task_id=$O" "worktree=$SLOT" "project=$L/project" "kind=ship"
  window_idle "$O"
  echo "sentinel" >> "$(git -C "$SLOT" rev-parse --git-common-dir)/info/exclude"; : > "$SLOT/sentinel"
}

echo "################ S2: relaunched scout is ALIVE in the claimed slot -> owner teardown must refuse, nothing killed"
setup_case s2; base_records
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
claim "$O"; window_agent "$S"; sleep 1
teardown "$HOMEDIR" "$O"; show_state; cleanup_case

echo; echo "################ S3: scout window exists but holds only an idle shell (classifier: dead) -> owner teardown proceeds"
setup_case s3; base_records
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
claim "$O"; window_idle "$S"; sleep 1
teardown "$HOMEDIR" "$O"; show_state; cleanup_case

echo; echo "################ S4: stale side - tear down the parked scout while the claim names the owner -> scout records go, owner's slot/window/claim untouched"
setup_case s4; base_records
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
mkdir -p "$HOMEDIR/data/$S"; echo "# report" > "$HOMEDIR/data/$S/report.md"
claim "$O"
teardown "$HOMEDIR" "$S"; show_state; cleanup_case

echo; echo "################ S5: adversarial - secondmate record names the slot as worktree= and home=, claim names owner -> must still refuse"
setup_case s5; base_records
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "home=$SLOT" "project=$L/project" "kind=secondmate"
claim "$O"
teardown "$HOMEDIR" "$O"; show_state; cleanup_case

echo; echo "################ S6: adversarial - same double record but NO claim -> must still refuse"
setup_case s6; base_records
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$SLOT" "project=$L/project" "kind=scout"
teardown "$HOMEDIR" "$O"; show_state; cleanup_case

echo; echo "################ S6b: adversarial - non-secondmate record names the slot only as home= (endpoint missing), claim names owner -> must still refuse"
setup_case s6b; base_records
meta "$HOMEDIR/state/$S.meta" "window=firstmate:fm-$S" "endpoint_task_id=$S" "worktree=$L/project" "home=$SLOT" "project=$L/project" "kind=scout"
claim "$O"
teardown "$HOMEDIR" "$O"; show_state; cleanup_case
