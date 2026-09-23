#!/usr/bin/env bash
# Behavior tests for a ship or scout worktree nested inside a firstmate home.
#
# A second mate's project clone can keep an in-project Treehouse pool, which
# puts the task worktree under <home>/projects/<project>/.treehouse/... . Claude
# and Pi load instruction files from every ancestor directory, so without a
# per-launch exclusion such a worker would load the home's supervisor contract.
# These tests drive the real fm-spawn with a fake tmux pane and real git
# worktrees, then check the two public outputs that carry the exclusion: the
# Claude launch's --settings JSON, and the per-task Pi extension executed
# against a fake Pi host with a system prompt in Pi's own context-file shape.
# tests/fm-nested-home-context-live-e2e.test.sh proves the same launches
# against the installed harnesses.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-nested-home-context)
trap fm_test_cleanup EXIT

make_pi_probe() {
  cat > "$1/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.85.1' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$1/pi"
}

# new_case <name> <harness> <layout> sets CASE_DIR, HOME_DIR, PROJ_DIR, WT_DIR,
# FAKEBIN_DIR, LAUNCH_LOG. layout is nested (an in-project pool inside the home,
# as a second mate's clone has it) or outside (a pool outside every home).
new_case() {
  local name=$1 harness=$2 layout=$3
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  printf '@AGENTS.md\n' > "$HOME_DIR/CLAUDE.md"
  printf 'home supervisor contract\n' > "$HOME_DIR/AGENTS.md"
  PROJ_DIR="$HOME_DIR/projects/proj"
  if [ "$layout" = nested ]; then
    WT_DIR="$PROJ_DIR/.treehouse/pool/1/proj"
  else
    WT_DIR="$CASE_DIR/pool/1/proj"
  fi
  mkdir -p "$(dirname "$WT_DIR")"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  if [ "$layout" = nested ]; then
    printf '*\n' > "$PROJ_DIR/.treehouse/.gitignore"
  fi
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  make_pi_probe "$FAKEBIN_DIR"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  : > "$LAUNCH_LOG"
}

spawn_ship() {
  local id=$1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off
}

# The single-quoted JSON word after --settings in the captured claude launch.
claude_settings() {
  sed -n "s/.* --settings '\([^']*\)'.*/\1/p" "$LAUNCH_LOG" | head -n 1
}

canonical() {
  (cd "$1" && pwd -P)
}

# drive_pi_filter <ext> <home-dir> <project-dir> prints the system prompt the
# extension leaves after before_agent_start, or NO-HANDLER / UNCHANGED.
drive_pi_filter() {
  EXT_PATH=$1 HOME_FILE="$2/AGENTS.md" PROJECT_FILE="$3/AGENTS.md" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on: () => {} } });
const handler = handlers["before_agent_start"];
if (!handler) { console.log("NO-HANDLER"); process.exit(0); }
const contextFiles = [
  { path: process.env.HOME_FILE, content: "home supervisor contract" },
  { path: process.env.PROJECT_FILE, content: "project rules" },
];
let systemPrompt = "base prompt\n\n<project_context>\n\nProject-specific instructions and guidelines:\n\n";
for (const f of contextFiles) {
  systemPrompt += `<project_instructions path="${f.path}">\n${f.content}\n</project_instructions>\n\n`;
}
systemPrompt += "</project_context>\n";
const result = await handler({ type: "before_agent_start", prompt: "hi", systemPrompt, systemPromptOptions: { contextFiles } }, {});
console.log(result && typeof result.systemPrompt === "string" ? result.systemPrompt : "UNCHANGED");
EOF
}

test_nested_claude_worker_excludes_home_instruction_files() {
  local out settings home
  new_case claude-nested claude nested
  out=$(spawn_ship nested-claude-z1) || fail "nested claude spawn failed: $out"
  settings=$(claude_settings)
  [ -n "$settings" ] || fail "claude launch carried no --settings word: $(cat "$LAUNCH_LOG")"
  home=$(canonical "$HOME_DIR")
  printf '%s' "$settings" | jq -e --arg h "$home" '
    .feedbackDrafts == "off"
    and .attribution.commit == ""
    and .claudeMdExcludes == [($h + "/CLAUDE.md"), ($h + "/CLAUDE.local.md"), ($h + "/AGENTS.md"), ($h + "/.claude/CLAUDE.md"), ($h + "/.claude/rules/**")]
  ' >/dev/null || fail "nested claude settings did not exclude exactly the home instruction files: $settings"
  printf '%s' "$settings" | jq -e --arg w "$(canonical "$WT_DIR")" '[.claudeMdExcludes[] | select(startswith($w))] == []' >/dev/null \
    || fail "nested claude settings excluded a file of the worktree itself: $settings"
  pass "a nested claude worker's launch excludes only the home's own instruction files"
}

test_outside_claude_worker_launch_is_unchanged() {
  local out settings
  new_case claude-outside claude outside
  out=$(spawn_ship outside-claude-z2) || fail "outside claude spawn failed: $out"
  settings=$(claude_settings)
  [ "$settings" = '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}' ] \
    || fail "a worktree outside the home changed the claude settings: $settings"
  pass "a claude worker whose worktree is outside the home launches unchanged"
}

test_secondmate_launch_keeps_its_contract() {
  local out settings id=secondmate-contract-z3 sm
  new_case secondmate-contract claude outside
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$sm" --secondmate) || fail "secondmate spawn failed: $out"
  settings=$(claude_settings)
  printf '%s' "$settings" | jq -e 'has("claudeMdExcludes") | not' >/dev/null \
    || fail "a secondmate launch excluded instruction files: $settings"
  pass "a second mate's launch excludes no instruction file, so its home contract still loads"
}

test_nested_pi_worker_drops_only_the_home_context_file() {
  local out ext result home_block project_block
  new_case pi-nested pi nested
  out=$(spawn_ship nested-pi-z4) || fail "nested pi spawn failed: $out"
  ext="$HOME_DIR/state/nested-pi-z4.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"
  result=$(drive_pi_filter "$ext" "$HOME_DIR" "$WT_DIR") || fail "pi extension drive failed: $result"
  home_block="<project_instructions path=\"$HOME_DIR/AGENTS.md\">"
  project_block="<project_instructions path=\"$WT_DIR/AGENTS.md\">"
  case "$result" in NO-HANDLER | UNCHANGED) fail "nested pi extension left the prompt alone: $result" ;; esac
  assert_not_contains "$result" "$home_block" "nested pi prompt still carries the home AGENTS.md"
  assert_not_contains "$result" "home supervisor contract" "nested pi prompt still carries the home contract text"
  assert_contains "$result" "$project_block" "nested pi prompt lost the project's own AGENTS.md"
  assert_contains "$result" "project rules" "nested pi prompt lost the project's own rules"
  pass "a nested pi worker's extension drops the home context file and keeps the project's"
}

test_outside_pi_worker_extension_adds_no_filter() {
  local out ext result
  new_case pi-outside pi outside
  out=$(spawn_ship outside-pi-z5) || fail "outside pi spawn failed: $out"
  ext="$HOME_DIR/state/outside-pi-z5.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"
  result=$(drive_pi_filter "$ext" "$HOME_DIR" "$WT_DIR") || fail "pi extension drive failed: $result"
  [ "$result" = NO-HANDLER ] || fail "a pi worker outside the home registered a context filter: $result"
  pass "a pi worker whose worktree is outside the home registers no context filter"
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v node >/dev/null 2>&1 || fail "node is required"
test_nested_claude_worker_excludes_home_instruction_files
test_outside_claude_worker_launch_is_unchanged
test_secondmate_launch_keeps_its_contract
test_nested_pi_worker_drops_only_the_home_context_file
test_outside_pi_worker_extension_adds_no_filter
printf '# all fm-spawn-nested-home-context tests passed\n'
