#!/usr/bin/env bash
# Drives the real fm-spawn for a nested claude worker whose home path contains
# a glob metacharacter, then an apostrophe, and shows what the launch carries.
set -u
WT=$1; ROOT=$WT
. "$WT/tests/fixtures.sh"
T=$(mktemp -d /tmp/fm-nested-adv.XXXXXX); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
drive() { local label=$1 HOME_DIR=$2
  fm_test_spawn_home "$HOME_DIR" claude
  local PROJ="$HOME_DIR/projects/proj" N="$HOME_DIR/projects/proj/.treehouse/pool/1/proj" FAKE log="$T/$RANDOM.log"
  fm_git_worktree "$PROJ" "$N" wt-adv; printf '*\n' > "$PROJ/.treehouse/.gitignore"
  FAKE=$(fm_test_make_spawn_fakebin "$T/fake-$RANDOM"); fm_test_spawn_brief "$HOME_DIR" adv-z1; : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$HOME_DIR" "$N" "$FAKE" adv-z1 "$PROJ" --mode no-mistakes --yolo off); rc=$?
  echo "== $label (home=$HOME_DIR) spawn exit=$rc"
  printf '%s\n' "$out" | grep -i 'warning: firstmate home' || echo "(no glob warning)"
  # Re-parse the launch as the shell would, and extract the --settings argument.
  launch=$(grep -m1 ' --settings ' "$log")
  eval "set -- ${launch#*claude }"
  while [ $# -gt 0 ] && [ "$1" != --settings ]; do shift; done
  printf 'settings arg as the shell parses it: %s\n' "$2"
  printf '%s' "$2" | jq -c '{valid_json:true, claudeMdExcludes}' || echo "INVALID JSON"
}
drive "glob metacharacter" "$T/home[1]"
drive "apostrophe" "$T/cap'n home"
