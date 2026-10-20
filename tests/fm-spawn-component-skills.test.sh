#!/usr/bin/env bash
# fm-spawn's component-skill wiring (bin/fm-component-spawn-lib.sh,
# docs/component-skills.md): a Claude crewmate's worktree
# settings.local.json carries the component hook on
# PreToolUse, the PostToolUse Bash sweep and the compact SessionStart, and
# running those entries injects a mapped file's goal once per session; a Claude
# secondmate's --settings file carries the same entries for the mate's own home
# map; the Pi extension appends the goal to a read result, sweeps after bash and
# resets on compaction; a Codex brief carries the `## Component skills` section;
# an unusable map yields a section that says so and a spawn warning; and a
# repository without a map gets no section while the hook stays silent.
#
# These run the REAL fm-spawn against a fake tmux pane and an isolated worktree,
# then run the generated hook entries and drive the Pi extension in a plain Node
# host, so the spawn wiring and the real bin/fm-component-check.sh are
# exercised together with no live harness session.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
TMP_ROOT=$(fm_test_tmproot fm-spawn-component-skills)
export FM_COMPONENT_STATE_DIR="$TMP_ROOT/component-state"
unset GROK_AGENT GROK_HOOK_EVENT

COMPONENT_MATCHER='Read|Edit|Write|MultiEdit|NotebookEdit'

skill_md() {  # <name> <goal>
  printf -- '---\nname: %s\ndescription: Load before changing %s. One owner.\n---\n\n# %s\n\n## Goal and operating principle\n%s\n\n## Refuse\n- A shortcut.\n\n## Review\n1. %s check.\n' \
    "$1" "$1" "$1" "$2" "$1"
}

commit_all() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

# make_case <name> <harness> <id> <map|nomap|badmap>: a spawn home, a project
# whose committed tree has the given map, and a worktree of it. Sets HOME_DIR,
# PROJ_DIR, WT_DIR (physical) and FAKEBIN_DIR.
make_case() {
  local name=$1 harness=$2 id=$3 map=$4 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  FAKEBIN_DIR=$(make_spawn_fakebin "$case_dir/fake" "$harness")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_init_commit "$PROJ_DIR"
  case "$map" in
    map)
      mkdir -p "$PROJ_DIR/docs" "$PROJ_DIR/.agents/skills/ledger" "$PROJ_DIR/src/ledger"
      skill_md ledger 'LEDGER-GOAL: one append-only ledger.' >"$PROJ_DIR/.agents/skills/ledger/SKILL.md"
      printf '%s\n' '{"schema":"component-map/v1","components":[{"id":"ledger","skill":"ledger","paths":["src/ledger/**","docs/ledger.md"]}]}' \
        >"$PROJ_DIR/docs/component-map.json"
      printf 'x = 1\n' >"$PROJ_DIR/src/ledger/store.py"
      commit_all "$PROJ_DIR" map
      ;;
    badmap)
      mkdir -p "$PROJ_DIR/docs"
      printf '{not json\n' >"$PROJ_DIR/docs/component-map.json"
      commit_all "$PROJ_DIR" 'bad map'
      ;;
  esac
  fm_git_add_origin "$PROJ_DIR" "$PROJ_DIR.origin.git"
  git -C "$PROJ_DIR" worktree add --quiet -b "wt-$name" "$case_dir/wt"
  WT_DIR=$(cd "$case_dir/wt" && pwd -P)
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

run_spawn() {  # <id>
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$1" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# component_command <settings> <event> <matcher>: the component hook command
# registered for <event> under <matcher>, failing unless there is exactly one.
component_command() {
  local cmds
  cmds=$(jq -r --arg ev "$2" --arg m "$3" \
    '.hooks[$ev][]? | select(.matcher == $m) | .hooks[] | select(.command | contains("fm-component-check.sh")) | "\(.timeout)\t\(.command)"' "$1")
  [ "$(printf '%s\n' "$cmds" | grep -c .)" = 1 ] || fail "$1 must register one component hook for $2 matcher '$3', got: $cmds"
  [ "${cmds%%$'\t'*}" = 10 ] || fail "$1 component hook for $2 must carry a 10-second timeout: $cmds"
  printf '%s\n' "${cmds#*$'\t'}"
}

# context <hook-output>: the additionalContext of a --claude output, empty when silent.
context() {
  [ -n "$1" ] || return 0
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'
}

pre_read() {  # <command> <session> <file> <cwd>
  jq -nc --arg s "$2" --arg f "$3" --arg c "$4" \
    '{hook_event_name:"PreToolUse", session_id:$s, tool_name:"Read", tool_input:{file_path:$f}, cwd:$c}' |
    sh -c "$1"
}

post_bash() {  # <command> <session> <cwd>
  jq -nc --arg s "$2" --arg c "$3" \
    '{hook_event_name:"PostToolUse", session_id:$s, tool_name:"Bash", tool_input:{command:"edit"}, cwd:$c}' |
    sh -c "$1"
}

compact() {  # <command> <session>
  jq -nc --arg s "$2" '{hook_event_name:"SessionStart", source:"compact", session_id:$s}' | sh -c "$1"
}

test_claude_crewmate_settings_carry_the_component_hook() {
  local id=comp-claude out settings pre bash_cmd start ctx brief
  make_case claude claude "$id" map
  out=$(run_spawn "$id")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write settings.local.json"
  pre=$(component_command "$settings" PreToolUse "$COMPONENT_MATCHER")
  bash_cmd=$(component_command "$settings" PostToolUse Bash)
  start=$(component_command "$settings" SessionStart compact)
  assert_contains "$pre" "FM_HOME=" "the component hook must name the spawning home"
  assert_contains "$pre" "$HOME_DIR" "the component hook must name the spawning home"
  assert_contains "$pre" "--claude" "the component hook must ask for Claude's output shape"
  jq -e '.hooks.UserPromptSubmit and .hooks.SessionEnd' "$settings" >/dev/null \
    || fail "the component entries must sit beside the busy hooks, not replace them"

  ctx=$(context "$(pre_read "$pre" cl-1 "$WT_DIR/src/ledger/store.py" "$WT_DIR")")
  assert_contains "$ctx" "LEDGER-GOAL" "a Read of a mapped file must inject its component goal"
  assert_contains "$ctx" "$WT_DIR/.agents/skills/ledger/SKILL.md" "the injection must name the skill path"
  out=$(pre_read "$pre" cl-1 "$WT_DIR/src/ledger/store.py" "$WT_DIR")
  assert_equals "" "$out" "a second touch in the same session must stay silent"
  out=$(compact "$start" cl-1)
  assert_equals "" "$out" "a compact SessionStart must print nothing"
  ctx=$(context "$(pre_read "$pre" cl-1 "$WT_DIR/src/ledger/store.py" "$WT_DIR")")
  assert_contains "$ctx" "LEDGER-GOAL" "the goal must return after compaction"

  printf 'y = 2\n' >"$WT_DIR/src/ledger/index.py"
  ctx=$(context "$(post_bash "$bash_cmd" cl-2 "$WT_DIR")")
  rm -f "$WT_DIR/src/ledger/index.py"
  assert_contains "$ctx" "LEDGER-GOAL" "the Bash sweep must inject the goal of a file a command changed"

  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_grep '## Component skills' "$brief" "a Claude brief must carry the component section too"
  pass "a Claude crewmate's settings.local.json carries the component hook beside the busy hooks, and it injects, dedupes, resets and sweeps"
}

test_codex_brief_carries_the_component_section() {
  local id=comp-codex out brief section
  make_case codex codex "$id" map
  out=$(run_spawn "$id")
  expect_code 0 $? "codex spawn should succeed: $out"
  assert_absent "$WT_DIR/.claude/settings.local.json" "a codex spawn must not write Claude settings"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_present "$brief" "codex spawn did not render the launch brief"
  section=$(sed -n '/^## Component skills$/,$p' "$brief")
  assert_contains "$section" "## Component skills" "a codex brief for a mapped checkout must carry the component section"
  assert_contains "$section" "Before changing a mapped path, load its skill; before reporting done, answer its Review checks" \
    "the section must state the load-and-review rule"
  assert_contains "$section" "record \`Component review: <id>: PASS\` or the finding in your report or PR body." \
    "the section must say how the self-review is recorded"
  assert_contains "$section" "- \`ledger\`: skill \`$WT_DIR/.agents/skills/ledger/SKILL.md\`; paths \`src/ledger/**\`, \`docs/ledger.md\`" \
    "the section must list the component id, skill path and globs"
  assert_contains "$section" "fm-component-map.sh touched $WT_DIR <path>" "the section must name the lookup command"
  [ "$(grep -c '^## Component skills$' "$brief")" = 1 ] || fail "the brief must carry exactly one component section"
  assert_grep 'brief for comp-codex' "$brief" "the section must be appended to, not replace, the brief"
  pass "a Codex brief carries the component section with ids, skill paths, globs and the rule"
}

test_unusable_map_is_reported_in_the_brief() {
  local id=comp-badmap out brief
  make_case badmap codex "$id" badmap
  out=$(run_spawn "$id")
  expect_code 0 $? "an unusable map must not stop the spawn: $out"
  assert_contains "$out" "docs/component-map.json is unusable" "spawn must warn about an unusable map"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_grep '## Component skills' "$brief" "an unusable map must still produce the section"
  assert_grep 'could not be read' "$brief" "the section must say the map could not be read"
  assert_grep "fm-component-map.sh check $WT_DIR" "$brief" "the section must name the check command"
  pass "an unusable map yields a brief section that says so and a spawn warning"
}

test_repo_without_a_map_gets_no_section_and_a_silent_hook() {
  local id=comp-nomap out settings pre rc
  make_case nomap claude "$id" nomap
  out=$(run_spawn "$id")
  expect_code 0 $? "claude spawn without a map should succeed: $out"
  assert_no_grep '## Component skills' "$HOME_DIR/data/$id/launch-brief.md" \
    "a checkout without a map must get no component section"
  settings="$WT_DIR/.claude/settings.local.json"
  pre=$(component_command "$settings" PreToolUse "$COMPONENT_MATCHER")
  out=$(pre_read "$pre" nm-1 "$WT_DIR/README.md" "$WT_DIR")
  rc=$?
  expect_code 0 "$rc" "the component hook must exit 0 in a repository without a map"
  assert_equals "" "$out" "the component hook must stay silent in a repository without a map"
  pass "a repository without a map gets no brief section, and the installed hook is silent"
}

# drive_pi_component <ext> <wt>: fire the extension's tool_result and
# session_compact handlers the way Pi does and check what they return.
drive_pi_component() {
  EXT_PATH="$1" WT="$2" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { writeFileSync, rmSync } from "node:fs";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on: () => {} } });
const wt = process.env.WT;
const ctx = (id) => ({ cwd: wt, sessionManager: { getSessionId: () => id } });
const base = [{ type: "text", text: "file body" }];
const read = (id) => handlers.tool_result({ toolName: "read", input: { path: "src/ledger/store.py" }, content: base }, ctx(id));
let out = await read("pi-1");
assert.equal(out.content.length, 2);
assert.deepEqual(out.content[0], base[0]);
assert.match(out.content[1].text, /LEDGER-GOAL/);
assert.equal(await read("pi-1"), undefined, "a second read in the session stays silent");
await handlers.session_compact({ reason: "manual" }, ctx("pi-1"));
assert.match((await read("pi-1")).content[1].text, /LEDGER-GOAL/, "the goal returns after compaction");
assert.equal(await handlers.tool_result({ toolName: "read", input: { path: "README.md" }, content: base }, ctx("pi-2")), undefined);
assert.equal(await handlers.tool_result({ toolName: "grep", input: { pattern: "x" }, content: base }, ctx("pi-2")), undefined);
writeFileSync(wt + "/src/ledger/index.py", "y = 2\n");
out = await handlers.tool_result({ toolName: "bash", input: { command: "edit" }, content: base }, ctx("pi-3"));
rmSync(wt + "/src/ledger/index.py");
assert.match(out.content[1].text, /LEDGER-GOAL/, "bash sweeps for changed files");
console.log("ok");
EOF
}

test_pi_extension_injects_the_component_goal() {
  local id=comp-pi out ext
  make_case pi pi "$id" map
  out=$(run_spawn "$id")
  expect_code 0 $? "pi spawn should succeed: $out"
  ext="$HOME_DIR/state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"
  out=$(drive_pi_component "$ext" "$WT_DIR") || fail "the Pi component handlers misbehaved: $out"
  pass "the Pi extension appends a mapped file's goal to the read result, dedupes, resets on compaction and sweeps after bash"
}

# A Claude secondmate gets the entries through its --settings file, and the
# hook reads the mate's own home map rather than the parent's.
test_claude_secondmate_settings_carry_the_component_hook() {
  local id=comp-sm case_dir primary sm fakebin settings pre ctx out
  case_dir="$TMP_ROOT/secondmate"
  primary="$case_dir/primary"
  sm="$case_dir/sm"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$primary" claude
  mkdir -p "$sm/bin" "$sm/data/notes" "$sm/state" "$sm/config" "$sm/projects" "$case_dir/skills/notes"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$sm/bin/fm-turnend-guard.sh"
  printf '# Firstmate\n' >"$sm/AGENTS.md"
  printf '%s\n' "$id" >"$sm/.fm-secondmate-home"
  printf 'charter\n' >"$sm/data/charter.md"
  fm_git_init_commit "$sm"
  skill_md notes 'NOTES-GOAL: notes stay append-only.' >"$case_dir/skills/notes/SKILL.md"
  jq -nc --arg s "$case_dir/skills/notes/SKILL.md" --arg g "$sm/data/notes/**" \
    '{schema:"component-map/v1", components:[{id:"notes", skill:$s, paths:[$g]}]}' >"$sm/config/component-map.json"
  printf 'note\n' >"$sm/data/notes/a.md"
  : >"$case_dir/launch.log"
  out=$(FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$primary" "$sm" "$fakebin" "$id" "$sm" claude --secondmate) \
    || fail "claude secondmate spawn failed: $out"
  settings="$primary/state/$id.claude-settings.json"
  assert_present "$settings" "claude secondmate spawn did not write its settings file"
  assert_absent "$sm/.claude/settings.local.json" "claude secondmate spawn wrote the home's settings.local.json"
  pre=$(component_command "$settings" PreToolUse "$COMPONENT_MATCHER")
  component_command "$settings" PostToolUse Bash >/dev/null
  component_command "$settings" SessionStart compact >/dev/null
  ctx=$(context "$(pre_read "$pre" sm-1 "$sm/data/notes/a.md" "$sm")")
  assert_contains "$ctx" "NOTES-GOAL" "the secondmate's hook must read the mate's own home map"
  pass "a Claude secondmate's --settings file carries the component hook for the mate's own home"
}

test_claude_crewmate_settings_carry_the_component_hook
test_codex_brief_carries_the_component_section
test_unusable_map_is_reported_in_the_brief
test_repo_without_a_map_gets_no_section_and_a_silent_hook
test_pi_extension_injects_the_component_goal
test_claude_secondmate_settings_carry_the_component_hook

echo "all fm-spawn-component-skills tests passed"
