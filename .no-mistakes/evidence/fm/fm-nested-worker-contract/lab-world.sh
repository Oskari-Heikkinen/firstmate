#!/usr/bin/env bash
# Builds a throwaway home copy (repo at HEAD) with a nested worktree, runs the
# real fm-spawn for a nested claude worker, and writes an isolated claude config
# where the worktree is trusted but external CLAUDE.md imports are NOT approved.
set -u
WT=$1 T=$2
HOME_DIR="$T/home"; mkdir -p "$HOME_DIR"
git -C "$WT" archive HEAD | tar -x -C "$HOME_DIR"
ROOT=$HOME_DIR
. "$WT/tests/fixtures.sh"
fm_test_spawn_home "$HOME_DIR" claude
PROJ="$HOME_DIR/projects/proj"; NESTED="$PROJ/.treehouse/pool/1/proj"
fm_git_init_commit "$PROJ"
printf 'project rules\n' > "$PROJ/AGENTS.md"; printf '.treehouse/\n' > "$PROJ/.gitignore"
git -C "$PROJ" add -A && git -C "$PROJ" -c user.name=t -c user.email=t@t commit -qm p
fm_git_add_origin "$PROJ" "$PROJ.origin.git"
mkdir -p "$(dirname "$NESTED")"; git -C "$PROJ" worktree add -q -b wt "$NESTED"
FAKE=$(fm_test_make_spawn_fakebin "$T/fake")
fm_test_spawn_brief "$HOME_DIR" lab-claude; : > "$T/launch.log"
FM_FAKE_LAUNCH_LOG="$T/launch.log" fm_test_run_spawn "$HOME_DIR" "$NESTED" "$FAKE" lab-claude "$PROJ" --harness claude --mode no-mistakes --yolo off >/dev/null || exit 1
sed -n "s/.* --settings '\([^']*\)'.*/\1/p" "$T/launch.log" | head -n1 > "$T/settings.json"
mkdir -p "$T/cfg"
KEY=sk-ant-capture-only-0000000000000000000000
jq -n --arg n "$NESTED" --arg k "${KEY: -20}" '{hasCompletedOnboarding:true,theme:"dark",customApiKeyResponses:{approved:[$k],rejected:[]},projects:{($n):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true}}}' > "$T/cfg/.claude.json"
printf '%s\n' "$NESTED" > "$T/nested"
