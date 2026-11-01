#!/usr/bin/env bash
# Behavior tests for the worker prompt-prefix cut: .agents/worker-skills.list
# and its parser (bin/fm-worker-prefix-lib.sh), the members a ship or scout
# launch gains from bin/fm-spawn.sh, and the first-turn size check
# (bin/fm-worker-prefix-check.sh). docs/configuration.md "Worker prompt
# prefix" owns the contract these prove.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-worker-prefix-lib.sh
. "$ROOT/bin/fm-worker-prefix-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-prefix)
trap fm_test_cleanup EXIT
LIST="$ROOT/.agents/worker-skills.list"
CHECK="$ROOT/bin/fm-worker-prefix-check.sh"

# A fake pi whose help advertises the skill flags when FM_FAKE_PI_SKILLS=1.
make_pi_probe() {
  cat > "$1/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.85.1' 'Options: --help --tui-mode <mode>'
  [ "${FM_FAKE_PI_SKILLS:-0}" != 1 ] || printf '%s\n' '  --no-skills  disable skill discovery' '  --skill <path>  load a skill'
fi
exit 0
SH
  chmod +x "$1/pi"
}

# new_case <name> <harness> sets CASE_DIR, HOME_DIR, PROJ_DIR, WT_DIR,
# FAKEBIN_DIR, LAUNCH_LOG and USER_HOME for a project other than Firstmate.
new_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  fm_test_spawn_home "$HOME_DIR" "$2"
  USER_HOME="$HOME_DIR/user-home"
  PROJ_DIR="$HOME_DIR/projects/proj"
  WT_DIR="$CASE_DIR/pool/1/proj"
  mkdir -p "$(dirname "$WT_DIR")" "$USER_HOME"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$1"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  make_pi_probe "$FAKEBIN_DIR"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  : > "$LAUNCH_LOG"
}

# new_firstmate_case <name> <harness>: the same for a worktree of Firstmate's
# own repository, through a fixture code root that runs this checkout's bin/.
new_firstmate_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  fm_test_spawn_home "$HOME_DIR" "$2"
  USER_HOME="$HOME_DIR/user-home"
  mkdir -p "$USER_HOME"
  FM_CODE_ROOT="$CASE_DIR/firstmate"
  fm_git_init_commit "$FM_CODE_ROOT"
  ln -s "$ROOT/bin" "$FM_CODE_ROOT/bin"
  mkdir -p "$FM_CODE_ROOT/.agents"
  ln -s "$ROOT/.agents/skills" "$FM_CODE_ROOT/.agents/skills"
  ln -s "$ROOT/.agents/worker-skills.list" "$FM_CODE_ROOT/.agents/worker-skills.list"
  printf 'firstmate supervisor contract\n' > "$FM_CODE_ROOT/AGENTS.md"
  git -C "$FM_CODE_ROOT" add -A
  git -C "$FM_CODE_ROOT" -c user.name=t -c user.email=t@t commit -qm firstmate
  fm_git_add_origin "$FM_CODE_ROOT" "$FM_CODE_ROOT.origin.git"
  PROJ_DIR=$FM_CODE_ROOT
  WT_DIR="$CASE_DIR/pool/1/firstmate"
  mkdir -p "$(dirname "$WT_DIR")"
  git -C "$FM_CODE_ROOT" worktree add --quiet -b "wt-$1" "$WT_DIR"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  make_pi_probe "$FAKEBIN_DIR"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  : > "$LAUNCH_LOG"
}

spawn_ship() {  # <id> [<spawn-args>...]
  fm_test_spawn_brief "$HOME_DIR" "$1"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PI_CODING_AGENT_DIR='' fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$1" "$PROJ_DIR" --mode no-mistakes --yolo off "${@:2}"
}

spawn_firstmate_ship() {  # <id> [<spawn-args>...]
  fm_test_spawn_brief "$HOME_DIR" "$1"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PI_CODING_AGENT_DIR='' ROOT=$FM_CODE_ROOT fm_test_run_spawn "$HOME_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$1" "$FM_CODE_ROOT" --mode direct-push --yolo off "${@:2}"
}

claude_settings() {
  sed -n "s/.* --settings '\([^']*\)'.*/\1/p" "$LAUNCH_LOG" | head -n 1
}

make_skill() {  # <root> <name>
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: fixture\n---\n' "$2" > "$1/$2/SKILL.md"
}

# --- the list ----------------------------------------------------------------

test_every_repo_skill_is_classified() {
  local entries dir name missing='' stale=''
  entries=$(fm_worker_skills_read "$LIST") || fail "the tracked worker skill list does not parse"
  for dir in "$ROOT"/.agents/skills/*/; do
    [ -f "${dir}SKILL.md" ] || continue
    name=${dir%/}
    name=${name##*/}
    printf '%s\n' "$entries" | awk -v n="$name" '$2 == n { f = 1 } END { exit !f }' || missing+=" $name"
  done
  [ -z "$missing" ] || fail ".agents/worker-skills.list does not classify these repository skills:$missing"
  # A keep entry for a repository skill that is gone keeps nothing; the list
  # must not drift into naming skills that no longer exist there.
  for name in $(printf '%s\n' "$entries" | awk '$1 == "keep" { print $2 }'); do
    case "$name" in
    lattice-dev-process | lattice-research-decisions | laptop-machine-ops | lean-supervision | no-mistakes | \
      review-preferences | run-reports | tetjet-operations | artifact-design | artifact-diagramming | claude-api | dataviz) ;;
    *) [ -f "$ROOT/.agents/skills/$name/SKILL.md" ] || stale+=" $name" ;;
    esac
  done
  [ -z "$stale" ] || fail ".agents/worker-skills.list keeps repository skills that do not exist:$stale"
  pass "every repository skill is classified in .agents/worker-skills.list and every kept repository entry exists"
}

test_list_parser_refuses_bad_lists() {
  local dir="$TMP_ROOT/parser" out status
  mkdir -p "$dir"
  out=$(fm_worker_skills_read "$dir/absent" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a missing list was accepted"
  assert_contains "$out" "must be a readable regular file" "a missing list did not say why"
  printf '# only a comment\n\n' > "$dir/empty"
  out=$(fm_worker_skills_read "$dir/empty" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a list naming no skill was accepted"
  assert_contains "$out" "lists no skill" "an empty list did not say why"
  printf 'keep a\nhide b\n' > "$dir/class"
  out=$(fm_worker_skills_read "$dir/class" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an unknown class was accepted"
  assert_contains "$out" "line 2 has class 'hide'" "an unknown class did not name its line"
  printf 'keep a b\n' > "$dir/fields"
  out=$(fm_worker_skills_read "$dir/fields" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an entry with a third field was accepted"
  assert_contains "$out" "line 1 is malformed" "a third field did not name its line"
  printf "keep it's\n" > "$dir/quote"
  out=$(fm_worker_skills_read "$dir/quote" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a name with a quote was accepted"
  printf 'keep a\nname-only a\n' > "$dir/dup"
  out=$(fm_worker_skills_read "$dir/dup" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a repeated name was accepted"
  assert_contains "$out" "line 2 names a a second time" "a repeated name did not name its line"
  printf '  keep a  \n# c\nname-only anthropic-skills:b' > "$dir/good"
  out=$(fm_worker_skills_read "$dir/good") || fail "a good list without a final newline was refused"
  assert_equals $'keep a\nname-only anthropic-skills:b' "$out" "a good list did not parse to its entries"
  pass "the list parser refuses a missing, empty, unknown-class, malformed, quoted or repeated entry and reads a good one"
}

test_claude_setting_names_every_unkept_skill() {
  local dir="$TMP_ROOT/claude-setting" entries out
  mkdir -p "$dir/cfg/skills/synced/s1" "$dir/cfg/skills/synced/s2"
  make_skill "$dir/repo" kept-repo
  make_skill "$dir/repo" new-repo
  make_skill "$dir/repo" "bad name"
  make_skill "$dir/cfg/skills" kept-user
  make_skill "$dir/cfg/skills" other-user
  printf '{"skills":[{"name":"pdf"},{"name":"x\\"y"}]}\n' > "$dir/cfg/skills/synced/s1/manifest.json"
  printf 'not json\n' > "$dir/cfg/skills/synced/s2/manifest.json"
  printf 'keep kept-repo\nkeep kept-user\nname-only bundled\nkeep anthropic-skills:keepme\n' > "$dir/list"
  entries=$(fm_worker_skills_read "$dir/list") || fail "fixture list refused"
  out=$(fm_worker_prefix_claude_setting "$entries" "$dir/cfg" "$dir/repo" "$dir/absent" 2>"$dir/err") \
    || fail "the setting builder failed"
  printf '{%s}' "${out#,}" | jq -e '
    .disableArtifact == true and .disableClaudeAiConnectors == true and .disableWorkflows == true
    and .permissions.deny == ["AskUserQuestion","ScheduleWakeup","ReportFindings","ListAgents"]
    and .skillListingBudgetFraction == 0.05
    and .skillOverrides == {"anthropic-skills:pdf":"name-only","bundled":"name-only","new-repo":"name-only","other-user":"name-only"}
  ' >/dev/null || fail "the Claude worker members are wrong: $out"
  assert_contains "$(cat "$dir/err")" "cannot read the synced skill manifest $dir/cfg/skills/synced/s2/manifest.json" \
    "an unreadable synced manifest was skipped silently"
  pass "the Claude members deny the four tools, raise the skill listing budget, and make every unkept listed, found or synced skill name-only"
}

test_pi_skill_dirs_take_kept_skills_and_whole_project_roots() {
  local dir="$TMP_ROOT/pi-dirs" entries out
  make_skill "$dir/a" kept1
  make_skill "$dir/a" dropped
  make_skill "$dir/b" kept1
  make_skill "$dir/b" kept2
  mkdir -p "$dir/project"
  printf 'keep kept1\nkeep kept2\nkeep kept3\nname-only dropped\n' > "$dir/list"
  entries=$(fm_worker_skills_read "$dir/list") || fail "fixture list refused"
  out=$(fm_worker_prefix_pi_skill_dirs "$entries" "$dir/a" "$dir/b" -- "$dir/project" "$dir/absent")
  assert_equals "$dir/a/kept1"$'\n'"$dir/b/kept2"$'\n'"$dir/project" "$out" \
    "Pi did not get each kept skill once from its first root plus the existing project root"
  pass "a Pi worker gets each kept skill from the first root holding it and a project's own skill roots whole"
}

test_launch_builder_keeps_special_characters_in_paths() {
  local dir agent wt out words
  dir="$TMP_ROOT/special-paths"
  agent="$dir/agent a&b c'd"
  wt="$dir/wt a&b c'd"
  make_skill "$agent/skills" kept1
  mkdir -p "$wt/.agents/skills" "$dir/home" "$dir/bin"
  make_pi_probe "$dir/bin"
  out=$(HOME="$dir/home" FM_FAKE_PI_SKILLS=1 fm_worker_prefix_launch 'pi__CLAUDEENV____PISKILLS__ --tail' 'keep kept1' pi \
    "$dir/cfg" "$dir/root" '' "$dir/bin/pi" t1 "$wt" "$agent") || fail "the launch builder failed"
  eval "words=($out)"
  assert_equals 7 "${#words[@]}" "the launch did not split into its words: $out"
  assert_equals "$agent/skills/kept1" "${words[3]}" "a kept skill path with & space and apostrophe was altered: $out"
  assert_equals "$wt/.agents/skills" "${words[5]}" "a project skill root with & space and apostrophe was altered: $out"
  pass "the launch builder keeps & spaces and apostrophes in the paths it substitutes"
}

# --- the launch --------------------------------------------------------------

test_claude_ship_launch_carries_the_cut() {
  local out settings hooks cmd
  new_case claude-ship claude
  make_skill "$USER_HOME/.claude/skills" no-mistakes
  make_skill "$USER_HOME/.claude/skills" operator-private
  out=$(spawn_ship prefix-claude-z1) || fail "claude spawn failed: $out"
  settings=$(claude_settings)
  printf '%s' "$settings" | jq -e '
    .disableArtifact == true and .disableClaudeAiConnectors == true and .disableWorkflows == true
    and .permissions.deny == ["AskUserQuestion","ScheduleWakeup","ReportFindings","ListAgents"]
    and .skillListingBudgetFraction == 0.05
    and .skillOverrides["operator-private"] == "name-only" and .skillOverrides.afk == "name-only"
    and .skillOverrides["code-review"] == "name-only"
    and (.skillOverrides | has("no-mistakes") or has("worker-guide") | not)
  ' >/dev/null || fail "a claude ship launch lacks the worker prompt-prefix members: $settings"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CODE_DISABLE_AUTO_MEMORY" \
    "a worker of a project other than Firstmate lost its own auto-memory"
  hooks=$(jq -r '.hooks.Stop[0].hooks[].command' "$WT_DIR/.claude/settings.local.json")
  cmd=$(printf '%s\n' "$hooks" | grep -F fm-worker-prefix-check.sh) \
    || fail "the ship's Stop hooks have no prefix check: $hooks"
  assert_contains "$cmd" "'prefix-claude-z1' 'proj'" "the prefix check does not name the task and project"
  pass "a claude ship launch carries the prompt-prefix members and the first-turn check, and keeps a project's auto-memory"
}

# Claude can run a turn's Stop hooks before the reply reaches the transcript,
# so the same check runs again on the next prompt and at the session's end.
test_claude_check_reruns_on_the_next_prompt_and_session_end() {
  local out settings state transcript stop submit end
  new_case claude-late claude
  out=$(spawn_ship prefix-late-z4) || fail "claude spawn failed: $out"
  state=$(cd "$HOME_DIR/state" && pwd -P)
  settings="$WT_DIR/.claude/settings.local.json"
  stop=$(jq -r '.hooks.Stop[0].hooks[].command' "$settings" | grep -F fm-worker-prefix-check.sh)
  submit=$(jq -r '.hooks.UserPromptSubmit[0].hooks[].command' "$settings" | grep -F fm-worker-prefix-check.sh)
  end=$(jq -r '.hooks.SessionEnd[0].hooks[].command' "$settings" | grep -F fm-worker-prefix-check.sh)
  [ -n "$stop" ] || fail "the ship's Stop hooks have no prefix check: $(cat "$settings")"
  assert_equals "$stop" "$submit" "the ship's UserPromptSubmit hooks lack the prefix check"
  assert_equals "$stop" "$end" "the ship's SessionEnd hooks lack the prefix check"
  transcript="$CASE_DIR/t.jsonl"
  jq -cn --arg t "$transcript" '{hook_event_name:"UserPromptSubmit",prompt:"x",transcript_path:$t}' | sh -c "$submit" \
    || fail "the first prompt's hook failed"
  assert_absent "$state/prefix-late-z4.prefix-checked" "the first prompt, before Claude wrote a transcript, wrote a marker"
  assert_absent "$state/worker-prefix/log" "the first prompt, before Claude wrote a transcript, logged a verdict"
  printf '%s\n' '{"type":"user"}' > "$transcript"
  jq -cn --arg t "$transcript" '{hook_event_name:"UserPromptSubmit",prompt:"x",transcript_path:$t}' | sh -c "$submit" \
    || fail "the first prompt's hook failed on a reply-less transcript"
  assert_absent "$state/prefix-late-z4.prefix-checked" "the first prompt wrote a marker before any reply"
  jq -cn --arg t "$transcript" '{hook_event_name:"Stop",transcript_path:$t}' | sh -c "$stop" || fail "the Stop hook failed"
  assert_absent "$state/prefix-late-z4.prefix-checked" "a Stop before the reply reached the transcript wrote a marker"
  printf '%s\n' '{"type":"assistant","version":"9.9.9","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":900,"cache_read_input_tokens":0}}}' >> "$transcript"
  jq -cn --arg t "$transcript" '{hook_event_name:"SessionEnd",reason:"other",transcript_path:$t}' | sh -c "$end" \
    || fail "the SessionEnd hook failed"
  assert_present "$state/prefix-late-z4.prefix-checked" "the session's end did not check the late reply"
  assert_grep "verdict=within" "$state/worker-prefix/log" "the session's end logged no verdict"
  jq -cn --arg t "$transcript" '{hook_event_name:"UserPromptSubmit",prompt:"x",transcript_path:$t}' | sh -c "$submit" \
    || fail "the UserPromptSubmit hook failed"
  assert_equals 1 "$(wc -l < "$state/worker-prefix/log" | tr -d ' ')" "a checked worker was checked again on the next prompt"
  pass "the prefix check waits through the first prompt and a Stop before the reply, then checks the reply once at the session's end, and the next prompt adds nothing"
}

test_claude_stop_hook_records_a_verdict_once() {
  local out cmd state transcript
  new_case claude-hook claude
  out=$(spawn_ship prefix-hook-z2) || fail "claude spawn failed: $out"
  state=$(cd "$HOME_DIR/state" && pwd -P)
  cmd=$(jq -r '.hooks.Stop[0].hooks[].command' "$WT_DIR/.claude/settings.local.json" | grep -F fm-worker-prefix-check.sh)
  transcript="$CASE_DIR/t.jsonl"
  printf '%s\n' '{"type":"user"}' \
    '{"type":"assistant","version":"9.9.9","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":40000,"cache_read_input_tokens":0}}}' > "$transcript"
  jq -cn --arg t "$transcript" '{transcript_path:$t}' | sh -c "$cmd" || fail "the Stop hook command failed"
  assert_present "$state/prefix-hook-z2.prefix-checked" "the Stop hook left no marker"
  jq -e '.active | has("worker-prefix-over-proj")' "$state/worker-prefix/alerts.json" >/dev/null \
    || fail "an over-size first turn raised no alarm: $(cat "$state/worker-prefix/alerts.json")"
  assert_grep "verdict=over" "$state/worker-prefix/log" "the check did not log its verdict"
  jq -cn --arg t "$transcript" '{transcript_path:$t}' | sh -c "$cmd" || fail "the second Stop failed"
  assert_equals 1 "$(wc -l < "$state/worker-prefix/log" | tr -d ' ')" "a marked worker was checked again"
  # A relaunch onto the same task: the fake window reports a bare shell, so the
  # old agent is gone and fm-spawn launches a replacement.
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-original"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
esac
case "\$1" in list-windows) printf 'fm-%s\n' 'prefix-hook-z2'; exit 0 ;; esac
exec '$FAKEBIN_DIR/tmux-original' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PI_CODING_AGENT_DIR='' fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    prefix-hook-z2 --relaunch --harness claude) || fail "claude relaunch failed: $out"
  assert_absent "$state/prefix-hook-z2.prefix-checked" "the relaunch kept the previous launch's marker"
  cmd=$(jq -r '.hooks.Stop[0].hooks[].command' "$WT_DIR/.claude/settings.local.json" | grep -F fm-worker-prefix-check.sh)
  jq -cn --arg t "$transcript" '{transcript_path:$t}' | sh -c "$cmd" || fail "the relaunched Stop hook failed"
  assert_equals 2 "$(wc -l < "$state/worker-prefix/log" | tr -d ' ')" "the relaunched worker was not checked"
  pass "the installed Stop hook records one verdict per launch and then costs one file test"
}

test_firstmate_repo_claude_worker_drops_auto_memory() {
  local out settings
  new_firstmate_case claude-firstmate claude
  out=$(spawn_firstmate_ship prefix-fm-z4) || fail "firstmate-repo claude spawn failed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 claude " \
    "a Firstmate-repo worker kept the supervisor's auto-memory"
  settings=$(claude_settings)
  printf '%s' "$settings" | jq -e '.skillOverrides.afk == "name-only" and (.skillOverrides | has("worker-guide") | not)' >/dev/null \
    || fail "a Firstmate-repo worker's skill overrides are wrong: $settings"
  pass "a Firstmate-repo claude worker launches with auto-memory off"
}

test_pi_ship_launch_loads_only_kept_skills() {
  local out launch kept
  new_case pi-ship pi
  make_skill "$USER_HOME/.agents/skills" no-mistakes
  make_skill "$USER_HOME/.agents/skills" operator-private
  make_skill "$USER_HOME/.pi/agent/skills" review-preferences
  make_skill "$WT_DIR/.agents/skills" project-own
  git -C "$WT_DIR" add -A
  git -C "$WT_DIR" -c user.name=t -c user.email=t@t commit -qm 'project skill'
  # fm-spawn resets the pooled copy to origin's default branch, so the
  # project's skill must be there.
  git -C "$WT_DIR" push -q origin HEAD:main
  out=$(FM_FAKE_PI_SKILLS=1 spawn_ship prefix-pi-z5 --model openai-codex/gpt-5.6-sol) || fail "pi spawn failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  kept="--no-skills --skill '$USER_HOME/.agents/skills/no-mistakes' --skill '$USER_HOME/.pi/agent/skills/review-preferences' --skill '"
  assert_contains "$launch" "$kept" "a Pi ship did not load exactly the kept skills"
  assert_contains "$launch" "review-preferences' --skill '$(cd "$WT_DIR" && pwd -P)/.agents/skills' " \
    "a Pi ship did not load its project's own skills whole"
  assert_not_contains "$launch" "operator-private" "a Pi ship loaded an unkept skill"
  pass "a Pi ship launch turns discovery off and loads the kept skills and the project's own skills"
}

test_pi_ship_launch_keeps_special_characters_in_paths() {
  local out agent launch
  # bash 5.2 expands & in an unquoted ${x//pat/rep} replacement; the case
  # directory carries one into every home path the launch template substitutes.
  new_case 'pi-a&b' pi
  agent="$CASE_DIR/agent a&b c'd"
  make_skill "$agent/skills" review-preferences
  fm_test_spawn_brief "$HOME_DIR" prefix-pi-z9
  out=$(FM_FAKE_PI_SKILLS=1 FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PI_CODING_AGENT_DIR="$agent" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" prefix-pi-z9 "$PROJ_DIR" --mode no-mistakes --yolo off --model openai-codex/gpt-5.6-sol) \
    || fail "pi spawn failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" " --skill $(_fm_worker_prefix_quote "$agent/skills/review-preferences") " \
    "a Pi ship's kept skill path with & space and apostrophe was altered on its way through the spawn"
  assert_contains "$launch" "pi-a&b/home/data/prefix-pi-z9/launch-brief.md" "a brief path with & was altered in the launch"
  assert_not_contains "$launch" "pi-a__" "a launch placeholder replaced the & in a path"
  pass "a Pi ship launch keeps & spaces and apostrophes in its brief and kept skill paths"
}

test_pi_without_skill_flags_launches_unchanged_with_a_warning() {
  local out
  new_case pi-old pi
  out=$(spawn_ship prefix-pi-z6 --model openai-codex/gpt-5.6-sol) || fail "pi spawn failed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "--no-skills" "a Pi without the flags was passed them"
  assert_contains "$out" "does not advertise --no-skills and --skill" "a Pi without the flags gave no warning"
  pass "a Pi without the skill flags launches unchanged and says so"
}

test_firstmate_repo_pi_worker_takes_kept_repo_skills() {
  local out launch
  new_firstmate_case pi-firstmate pi
  out=$(FM_FAKE_PI_SKILLS=1 spawn_firstmate_ship prefix-fm-pi-z7 --model openai-codex/gpt-5.6-sol) \
    || fail "firstmate-repo pi spawn failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "/pool/1/firstmate/.agents/skills/worker-guide'" "a Firstmate-repo Pi worker lost a kept repo skill"
  assert_not_contains "$launch" "/.agents/skills/afk'" "a Firstmate-repo Pi worker loaded a supervisor skill"
  assert_not_contains "$launch" "/.agents/skills' " "a Firstmate-repo Pi worker loaded a skill root whole"
  pass "a Firstmate-repo Pi worker loads only the kept repository skills"
}

test_bad_list_refuses_the_launch_before_provisioning() {
  local scratch entry out status
  new_case bad-list claude
  scratch="$CASE_DIR/root"
  mkdir -p "$scratch/.agents"
  for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
    case "${entry##*/}" in .agents | data | state | .git) continue ;; esac
    [ -e "$entry" ] && ln -s "$entry" "$scratch/${entry##*/}"
  done
  ln -s "$ROOT/.agents/skills" "$scratch/.agents/skills"
  printf 'keep worker-guide\nhide afk\n' > "$scratch/.agents/worker-skills.list"
  out=$(FM_TEST_SPAWN_ROOT="$scratch" spawn_ship prefix-bad-z8); status=$?
  [ "$status" -ne 0 ] || fail "a launch with a bad skill list succeeded: $out"
  assert_contains "$out" "has class 'hide'" "the refusal did not name the bad entry"
  assert_absent "$HOME_DIR/state/prefix-bad-z8.meta" "a refused launch left task metadata"
  pass "a skill list the parser refuses stops the launch before any record exists"
}

# --- the first-turn check ----------------------------------------------------

check_home() {  # <name>: sets CK_HOME CK_STATE CK_CONFIG
  CK_HOME="$TMP_ROOT/check-$1"
  CK_STATE="$CK_HOME/state"
  CK_CONFIG="$CK_HOME/config"
  mkdir -p "$CK_STATE" "$CK_CONFIG"
}

transcript() {  # <file> <prefix-tokens|bad|none>
  {
    printf '%s\n' '{"type":"user","message":{}}' ''
    case "$2" in
    none) ;;
    bad) printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":"x"}}}' ;;
    *) printf '{"type":"assistant","version":"2.1.314","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$2" ;;
    esac
    printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":999999}}}'
  } > "$1"
}

run_check() {  # <task-id> <transcript-path|''>
  jq -cn --arg t "$2" 'if $t == "" then {} else {transcript_path:$t} end' \
    | "$CHECK" "$CK_HOME" "$CK_STATE" "$CK_CONFIG" "$1" proj
}

active() {
  jq -r '.active | keys[]' "$CK_STATE/worker-prefix/alerts.json" 2>/dev/null | tr '\n' ' '
}

test_check_over_then_within_clears_the_alarm() {
  check_home verdicts
  transcript "$CK_HOME/over.jsonl" 30000
  run_check t1 "$CK_HOME/over.jsonl" || fail "the over check failed"
  assert_contains "$(active)" "worker-prefix-over-proj" "a first turn over expected+margin raised no alarm"
  assert_grep "prefix=30000 expected=20000 margin=5000 verdict=over" "$CK_STATE/worker-prefix/log" \
    "the over verdict did not read the first assistant record"
  assert_grep "store=worker-prefix" "$CK_STATE/alert-stores/worker-prefix.reg" "the store was not registered"
  transcript "$CK_HOME/within.jsonl" 25000
  run_check t2 "$CK_HOME/within.jsonl" || fail "the within check failed"
  assert_not_contains "$(active)" "worker-prefix-over-proj" "a first turn at expected+margin did not clear the alarm"
  pass "a first turn over the expected size plus margin raises the alarm and one within it clears it"
}

test_check_unread_states_raise_their_own_alarm() {
  check_home unread
  run_check u1 '' || fail "the check failed on a hook without a transcript"
  assert_contains "$(active)" "worker-prefix-unread-proj" "a hook naming no transcript raised no alarm"
  assert_present "$CK_STATE/u1.prefix-checked" "an unread verdict left no marker"
  transcript "$CK_HOME/bad.jsonl" bad
  run_check u2 "$CK_HOME/bad.jsonl" || fail "the check failed on bad usage"
  assert_grep "u2 project=proj claude=unknown prefix=? expected=20000 margin=5000 verdict=unread" "$CK_STATE/worker-prefix/log" \
    "bad usage was not read as unread"
  transcript "$CK_HOME/ok.jsonl" 100
  run_check u3 "$CK_HOME/ok.jsonl" || fail "the within check failed"
  assert_not_contains "$(active)" "worker-prefix-unread-proj" "a readable first turn did not clear the unread alarm"
  run_check u4 "$CK_HOME/missing.jsonl" || fail "the check failed on a missing transcript"
  assert_contains "$(active)" "worker-prefix-unread-proj" "a missing transcript raised no alarm"
  pass "a missing, unnamed or non-numeric first turn raises the unread alarm and a readable one clears it"
}

test_check_waits_for_the_first_assistant_record() {
  check_home pending
  printf '%s\n' '{"type":"user","message":{}}' > "$CK_HOME/early.jsonl"
  printf '%s' '{"type":"assistant","message":{"usage":{"input_tok' >> "$CK_HOME/early.jsonl"
  run_check p1 "$CK_HOME/early.jsonl" || fail "the check failed before the first reply"
  assert_absent "$CK_STATE/p1.prefix-checked" "a transcript whose first reply is still being written was given a verdict"
  assert_absent "$CK_STATE/worker-prefix/log" "a transcript with no reply yet was logged"
  : > "$CK_STATE/p2.prefix-checked"
  transcript "$CK_HOME/big.jsonl" 90000
  run_check p2 "$CK_HOME/big.jsonl" || fail "the marked check failed"
  assert_absent "$CK_STATE/worker-prefix/log" "a marked task was checked again"
  # Only a regular marker counts: a directory there is not a verdict.
  mkdir "$CK_STATE/p3.prefix-checked"
  transcript "$CK_HOME/ok.jsonl" 100
  run_check p3 "$CK_HOME/ok.jsonl"
  assert_grep "p3 project=proj" "$CK_STATE/worker-prefix/log" "a directory at the marker path stopped the check"
  pass "the check waits for a first reply still being written and never repeats once a regular marker exists"
}

test_check_reads_a_corrupt_line_before_the_first_reply_as_unread() {
  check_home corrupt
  printf '%s\n' '{"type":"user","message":{}}' 'not json {' \
    '{"type":"assistant","message":{"usage":{"input_tokens":100}}}' > "$CK_HOME/t.jsonl"
  run_check k1 "$CK_HOME/t.jsonl" || fail "the check failed on a corrupt line"
  assert_contains "$(active)" "worker-prefix-unread-proj" "a corrupt complete line before the first reply was skipped"
  assert_grep "k1 project=proj claude=unknown prefix=? expected=20000 margin=5000 verdict=unread" "$CK_STATE/worker-prefix/log" \
    "a corrupt complete line before the first reply did not read as unread"
  pass "a complete line before the first reply that is not JSON reads as unread, not as a skippable tail"
}

# usage_transcript <file> <usage-json>: one assistant record with that usage.
usage_transcript() {
  printf '{"type":"assistant","message":{"usage":%s}}\n' "$2" > "$1"
}

test_check_refuses_invalid_usage_counts() {
  local n=0 usage
  check_home counts
  transcript "$CK_HOME/over.jsonl" 30000
  run_check v0 "$CK_HOME/over.jsonl" || fail "the over check failed"
  for usage in '{"input_tokens":30000.5}' '{"input_tokens":-1}' '{"input_tokens":1e400}' \
    '{"input_tokens":18446744073709581616}' '{"input_tokens":1000000000}' '{"input_tokens":"7"}' \
    '{"input_tokens":5,"cache_creation_input_tokens":-3}' '{"input_tokens":0.5,"cache_read_input_tokens":0.5}' \
    '{"input_tokens":5,"cache_read_input_tokens":false}' '{"cache_read_input_tokens":5}' '"usage"' 'null'; do
    n=$((n + 1))
    usage_transcript "$CK_HOME/u$n.jsonl" "$usage"
    run_check "v$n" "$CK_HOME/u$n.jsonl" || fail "the check failed on usage $usage"
    assert_grep "v$n project=proj claude=unknown prefix=? expected=20000 margin=5000 verdict=unread" "$CK_STATE/worker-prefix/log" \
      "usage $usage was not read as unread"
    assert_contains "$(active)" "worker-prefix-over-proj" "usage $usage cleared the over alarm"
  done
  usage_transcript "$CK_HOME/exp.jsonl" '{"input_tokens":3e4,"cache_creation_input_tokens":null}'
  run_check w1 "$CK_HOME/exp.jsonl" || fail "the check failed on an exponent count"
  assert_grep "w1 project=proj claude=unknown prefix=30000 expected=20000 margin=5000 verdict=over" "$CK_STATE/worker-prefix/log" \
    "a whole-number count in exponent form was not read as that number"
  usage_transcript "$CK_HOME/max.jsonl" '{"input_tokens":999999999,"cache_creation_input_tokens":999999999,"cache_read_input_tokens":999999999}'
  run_check w2 "$CK_HOME/max.jsonl" || fail "the check failed on the largest counts"
  assert_grep "w2 project=proj claude=unknown prefix=2999999997 expected=20000 margin=5000 verdict=over" "$CK_STATE/worker-prefix/log" \
    "the largest valid counts were not summed exactly"
  pass "fractional, negative, oversized, overflowing, non-numeric or missing token counts read as unread and never clear the alarm"
}

test_check_never_opens_a_non_regular_transcript() {
  local kind rc
  check_home special
  for kind in fifo directory dangling; do
    case "$kind" in
    fifo) mkfifo "$CK_HOME/$kind" ;;
    directory) mkdir "$CK_HOME/$kind" ;;
    dangling) ln -s "$CK_HOME/absent.jsonl" "$CK_HOME/$kind" ;;
    esac
    rc=0
    # shellcheck disable=SC2016 # the inner shell expands its own arguments
    fm_run_timed 30 bash -c 'jq -cn --arg t "$5" "{transcript_path:\$t}" | "$0" "$1" "$2" "$3" "$4" proj' \
      "$CHECK" "$CK_HOME" "$CK_STATE" "$CK_CONFIG" "s-$kind" "$CK_HOME/$kind" || rc=$?
    [ "$rc" -ne 124 ] || fail "the check blocked on a $kind transcript"
    [ "$rc" -eq 0 ] || fail "the check failed on a $kind transcript: exit $rc"
    assert_grep "s-$kind project=proj claude=unknown prefix=? expected=20000 margin=5000 verdict=unread" "$CK_STATE/worker-prefix/log" \
      "a $kind transcript was not read as unread"
  done
  if [ "$(id -u)" != 0 ]; then
    transcript "$CK_HOME/locked.jsonl" 100
    chmod 000 "$CK_HOME/locked.jsonl"
    run_check s-locked "$CK_HOME/locked.jsonl" || fail "the check failed on an unreadable transcript"
    chmod 600 "$CK_HOME/locked.jsonl"
    assert_grep "s-locked project=proj claude=unknown prefix=? expected=20000 margin=5000 verdict=unread" "$CK_STATE/worker-prefix/log" \
      "an unreadable transcript was not read as unread"
  fi
  printf '{"transcript_path":' | "$CHECK" "$CK_HOME" "$CK_STATE" "$CK_CONFIG" s-hook proj || fail "the check failed on bad hook input"
  assert_grep "s-hook project=proj claude=unknown prefix=? expected=20000 margin=5000 verdict=unread" "$CK_STATE/worker-prefix/log" \
    "hook input that is not JSON was not read as unread"
  pass "a FIFO, directory, dangling or unreadable transcript, or hook input that is not JSON, reads as unread without blocking"
}

test_check_records_its_own_failure_once_and_resolves_it() {
  local status
  check_home failure
  status="$CK_STATE/worker-prefix.status"
  transcript "$CK_HOME/t.jsonl" 100
  : > "$CK_STATE/worker-prefix"
  run_check f1 "$CK_HOME/t.jsonl"
  expect_code 1 $? "a check that cannot create its state did not exit 1"
  assert_absent "$CK_STATE/f1.prefix-checked" "a check that could not finish wrote its marker"
  assert_grep "blocked [key=worker-prefix-check-f1]" "$status" "a check that cannot create its state raised nothing"
  assert_grep "cannot create $CK_STATE/worker-prefix" "$status" "the failure line does not say what failed"
  run_check f1 "$CK_HOME/t.jsonl"
  assert_equals 1 "$(grep -c 'key=worker-prefix-check' "$status")" "a repeated failure appended a second blocked line"
  run_check g1 "$CK_HOME/t.jsonl"
  assert_grep "blocked [key=worker-prefix-check-g1]" "$status" "another worker's open failure hid this worker's"
  rm "$CK_STATE/worker-prefix"
  run_check f1 "$CK_HOME/t.jsonl" || fail "the check failed once its state could be created"
  assert_present "$CK_STATE/f1.prefix-checked" "the recovered check wrote no marker"
  assert_equals "resolved" "$(grep -F 'key=worker-prefix-check-f1]' "$status" | tail -n 1 | cut -d' ' -f1)" \
    "the recovered check did not resolve its failure"
  assert_equals "blocked" "$(grep -F 'key=worker-prefix-check-g1]' "$status" | tail -n 1 | cut -d' ' -f1)" \
    "one worker's finished check resolved another worker's failure"
  mkdir "$CK_STATE/f2.prefix-checked"
  run_check f2 "$CK_HOME/t.jsonl"
  expect_code 1 $? "a check that cannot write its marker did not exit 1"
  assert_equals "blocked" "$(grep -F 'key=worker-prefix-check-f2]' "$status" | tail -n 1 | cut -d' ' -f1)" \
    "a marker that cannot be written raised nothing"
  pass "a check that cannot finish raises one blocker per worker, retries without repeating it, and resolves only its own when it finishes"
}

test_stop_hook_records_a_checker_that_cannot_record_itself() {
  local dir state cmd out rc
  dir="$TMP_ROOT/hook-fallback"
  state="$dir/a&b c'd/state"
  mkdir -p "$state" "$dir/config" "$dir/root/bin"
  transcript "$dir/t.jsonl" 100
  cmd=$(fm_worker_prefix_hook_command "$dir/root" "$dir" "$state" "$dir/config" h1 proj)
  out=$(jq -cn --arg t "$dir/t.jsonl" '{transcript_path:$t}' | sh -c "$cmd" 2>&1) || fail "a missing checker failed the Stop hook: $out"
  assert_grep "blocked [key=worker-prefix-check-h1]" "$state/worker-prefix.status" "a missing checker raised nothing"
  assert_grep "worker h1 exited 127" "$state/worker-prefix.status" "the fallback line does not name the worker and exit"
  assert_absent "$state/h1.prefix-checked" "a checker that never ran was marked done"
  out=$(jq -cn --arg t "$dir/t.jsonl" '{transcript_path:$t}' | sh -c "$cmd" 2>&1) || fail "a second missing-checker turn failed: $out"
  assert_equals 1 "$(grep -c 'key=worker-prefix-check-h1' "$state/worker-prefix.status")" "a broken checker reported again on its next turn"
  # A checker that works again finishes and resolves the fallback's blocker.
  cmd=$(fm_worker_prefix_hook_command "$ROOT" "$dir" "$state" "$dir/config" h1 proj)
  out=$(jq -cn --arg t "$dir/t.jsonl" '{transcript_path:$t}' | sh -c "$cmd" 2>&1) || fail "the repaired check failed: $out"
  assert_present "$state/h1.prefix-checked" "the repaired check wrote no marker"
  assert_equals "resolved" "$(grep -F 'key=worker-prefix-check-h1]' "$state/worker-prefix.status" | tail -n 1 | cut -d' ' -f1)" \
    "the repaired check did not resolve the fallback's blocker"
  printf '#!/bin/sh\nexit 1\n' > "$dir/root/bin/fm-worker-prefix-check.sh"
  chmod +x "$dir/root/bin/fm-worker-prefix-check.sh"
  cmd=$(fm_worker_prefix_hook_command "$dir/root" "$dir" "$state" "$dir/config" h2 proj)
  printf '{}' | sh -c "$cmd" || fail "a checker that recorded its own failure failed the Stop hook"
  assert_equals 0 "$(grep -c 'key=worker-prefix-check-h2' "$state/worker-prefix.status")" \
    "the fallback repeated a failure the checker had recorded"
  assert_absent "$state/h2.prefix-checked" "a recorded failure was marked done"
  if [ "$(id -u)" != 0 ]; then
    printf '#!/bin/sh\nexit 3\n' > "$dir/root/bin/fm-worker-prefix-check.sh"
    chmod 400 "$state/worker-prefix.status"
    rc=0
    out=$(printf '{}' | sh -c "$cmd" 2>&1) || rc=$?
    chmod 600 "$state/worker-prefix.status"
    expect_code 1 "$rc" "an unrecordable failure did not surface as a Stop hook error"
    assert_contains "$out" "cannot record that the prompt-prefix check for worker h2 failed" \
      "the Stop hook error does not say what could not be recorded"
  fi
  pass "the Stop hook records a missing or unrecording checker once, retries it until it finishes and resolves, quotes an & space and apostrophe path, and errors visibly when it cannot record"
}

test_check_reads_the_size_config() {
  check_home config
  printf '# sizes\ndefault 50000 1000\nproj 10000 100\nother 1 1\n' > "$CK_CONFIG/worker-prefix-size"
  transcript "$CK_HOME/t.jsonl" 10200
  run_check c1 "$CK_HOME/t.jsonl" || fail "the configured check failed"
  assert_grep "prefix=10200 expected=10000 margin=100 verdict=over" "$CK_STATE/worker-prefix/log" \
    "a project's own size line was not used"
  printf 'default 10000 x\n' > "$CK_CONFIG/worker-prefix-size"
  run_check c2 "$CK_HOME/t.jsonl" || fail "the check failed on a bad config"
  assert_contains "$(active)" "worker-prefix-config" "a bad size file raised no alarm"
  assert_grep "c2 project=proj claude=2.1.314 prefix=10200 expected=? margin=? verdict=unjudged" "$CK_STATE/worker-prefix/log" \
    "a bad size file was judged against the built-in size"
  printf 'default 10000 100\ndefault 1 1\n' > "$CK_CONFIG/worker-prefix-size"
  run_check c3 "$CK_HOME/t.jsonl" || fail "the check failed on a repeated scope"
  assert_contains "$(active)" "worker-prefix-config" "a repeated scope raised no alarm"
  printf 'default 10000 100\n' > "$CK_CONFIG/worker-prefix-size"
  run_check c4 "$CK_HOME/t.jsonl" || fail "the check failed on a fixed config"
  assert_not_contains "$(active)" "worker-prefix-config" "a fixed size file did not clear the alarm"
  pass "the check reads its size from config on every run, alarms on a bad file and clears when it is fixed"
}

test_check_refuses_every_bad_size_file() {
  local n=0 body
  check_home bad-config
  transcript "$CK_HOME/over.jsonl" 30000
  run_check b0 "$CK_HOME/over.jsonl" || fail "the over check failed"
  transcript "$CK_HOME/t.jsonl" 100
  for body in 'default 1:2 3' 'default 18446744073709581616 5' 'default 1000000000 5' 'default 0 5' 'default -1 5' \
    'default 10.5 5' '# only a comment' '   ' '' 'pro/j 100 5' 'default 100 5 6' 'default 100'; do
    n=$((n + 1))
    printf '%s\n' "$body" > "$CK_CONFIG/worker-prefix-size"
    run_check "b$n" "$CK_HOME/t.jsonl" || fail "the check failed on size file '$body'"
    assert_grep "b$n project=proj claude=2.1.314 prefix=100 expected=? margin=? verdict=unjudged" "$CK_STATE/worker-prefix/log" \
      "size file '$body' was not refused"
    assert_contains "$(active)" "worker-prefix-config" "size file '$body' raised no config alarm"
    assert_contains "$(active)" "worker-prefix-over-proj" "size file '$body' certified the prefix within"
  done
  : > "$CK_CONFIG/worker-prefix-size"
  run_check b-empty "$CK_HOME/t.jsonl" || fail "the check failed on an empty size file"
  assert_grep "b-empty project=proj claude=2.1.314 prefix=100 expected=? margin=? verdict=unjudged" "$CK_STATE/worker-prefix/log" \
    "an empty size file was not refused"
  printf 'default 100\0 5\n' > "$CK_CONFIG/worker-prefix-size"
  run_check b-nul "$CK_HOME/t.jsonl" || fail "the check failed on a size file with a NUL byte"
  assert_grep "b-nul project=proj claude=2.1.314 prefix=100 expected=? margin=? verdict=unjudged" "$CK_STATE/worker-prefix/log" \
    "a size file with a NUL byte was not refused"
  rm "$CK_CONFIG/worker-prefix-size"
  mkdir "$CK_CONFIG/worker-prefix-size"
  run_check b-dir "$CK_HOME/t.jsonl" || fail "the check failed on a directory size file"
  assert_grep "b-dir project=proj claude=2.1.314 prefix=100 expected=? margin=? verdict=unjudged" "$CK_STATE/worker-prefix/log" \
    "a directory at the size file path was not refused"
  rmdir "$CK_CONFIG/worker-prefix-size"
  printf 'default 0000150 000\n' > "$CK_CONFIG/worker-prefix-size"
  run_check b-zeros "$CK_HOME/t.jsonl" || fail "the check failed on leading zeros"
  assert_grep "b-zeros project=proj claude=2.1.314 prefix=100 expected=150 margin=0 verdict=within" "$CK_STATE/worker-prefix/log" \
    "leading zeros were not read as decimal"
  assert_not_contains "$(active)" "worker-prefix-config" "a good size file did not clear the config alarm"
  pass "a size file that is empty, comment-only, non-regular, holds a NUL, or has a malformed, oversized or zero field is refused and never certifies a prefix"
}

test_calibrated_project_sizes_alarm_only_on_regression() {
  check_home calibrated
  # A project whose normal first turn sits above the default carries its own
  # measured line.
  printf 'default 20000 5000\nwide 40000 4000\n' > "$CK_CONFIG/worker-prefix-size"
  transcript "$CK_HOME/normal.jsonl" 41000
  jq -cn --arg t "$CK_HOME/normal.jsonl" '{transcript_path:$t}' | "$CHECK" "$CK_HOME" "$CK_STATE" "$CK_CONFIG" n1 wide \
    || fail "the calibrated check failed"
  assert_grep "n1 project=wide claude=2.1.314 prefix=41000 expected=40000 margin=4000 verdict=within" "$CK_STATE/worker-prefix/log" \
    "a normal first turn of a calibrated project was not judged against its own size"
  assert_not_contains "$(active)" "worker-prefix-over-wide" "a normal first turn of a calibrated project alarmed"
  transcript "$CK_HOME/regressed.jsonl" 52000
  jq -cn --arg t "$CK_HOME/regressed.jsonl" '{transcript_path:$t}' | "$CHECK" "$CK_HOME" "$CK_STATE" "$CK_CONFIG" n2 wide \
    || fail "the regression check failed"
  assert_contains "$(active)" "worker-prefix-over-wide" "a regressed first turn of a calibrated project did not alarm"
  pass "a project with its own measured size passes a normal first turn and alarms on a regression"
}

test_every_repo_skill_is_classified
test_list_parser_refuses_bad_lists
test_claude_setting_names_every_unkept_skill
test_pi_skill_dirs_take_kept_skills_and_whole_project_roots
test_launch_builder_keeps_special_characters_in_paths
test_claude_ship_launch_carries_the_cut
test_claude_stop_hook_records_a_verdict_once
test_claude_check_reruns_on_the_next_prompt_and_session_end
test_firstmate_repo_claude_worker_drops_auto_memory
test_pi_ship_launch_loads_only_kept_skills
test_pi_ship_launch_keeps_special_characters_in_paths
test_pi_without_skill_flags_launches_unchanged_with_a_warning
test_firstmate_repo_pi_worker_takes_kept_repo_skills
test_bad_list_refuses_the_launch_before_provisioning
test_check_over_then_within_clears_the_alarm
test_check_unread_states_raise_their_own_alarm
test_check_waits_for_the_first_assistant_record
test_check_reads_a_corrupt_line_before_the_first_reply_as_unread
test_check_refuses_invalid_usage_counts
test_check_never_opens_a_non_regular_transcript
test_check_records_its_own_failure_once_and_resolves_it
test_stop_hook_records_a_checker_that_cannot_record_itself
test_check_reads_the_size_config
test_check_refuses_every_bad_size_file
test_calibrated_project_sizes_alarm_only_on_regression

printf '# all fm-worker-prefix tests passed\n'
