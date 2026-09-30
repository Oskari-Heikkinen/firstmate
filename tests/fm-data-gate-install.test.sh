#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the user-level data gate installer (docs/data-gate.md).
#
# Every case runs bin/fm-data-gate-install.sh with HOME pointed at a fresh
# temporary directory, never the real one: install, re-install (idempotent),
# uninstall (byte-identical restore), dry-run (writes nothing), uninstall after
# a later edit (only gate entries removed, even across a re-install), an
# unparseable settings file (left untouched), every registered Claude login
# folder, the generated bulk paths, the Codex trust entry, and the installed
# hooks, plugins and extensions actually calling the gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-data-gate-install)
INSTALL="$ROOT/bin/fm-data-gate-install.sh"
GATE="$ROOT/bin/fm-data-gate.sh"

AXI_HOOKS='{
  "hooks": {
    "SessionStart": [
      {"matcher": "", "hooks": [{"type": "command", "command": "gh-axi", "timeout": 10}]},
      {"matcher": "", "hooks": [{"type": "command", "command": "chrome-devtools-axi", "timeout": 10}]},
      {"matcher": "", "hooks": [{"type": "command", "command": "lavish-axi", "timeout": 10}]}
    ]
  },
  "theme": "dark"
}'

new_home() {  # <name>
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/.claude" "$h/.claude-work" "$h/.claude-gmail" "$h/.claude-tetmet" "$h/.codex" "$h/.codex-alt" \
    "$h/.grok" "$h/.config/opencode" "$h/.pi/agent" "$h/.omp/agent/extensions" "$h/Tools/firstmate/bin" \
    "$h/Tools/firstmate/config" "$h/Tools/firstmate/data/rolling-runs-v9/slices" \
    "$h/Tools/firstmate/data/exp/tetjet-results" "$h/lattice-ledger"
  : >"$h/Tools/firstmate/AGENTS.md"
  printf 'gmail claude ~/.claude-gmail 1\ntetmet claude %s/.claude-tetmet 2\nwork claude ~/.claude-work 3\nalt codex ~/.codex-alt\n' "$h" \
    >"$h/Tools/firstmate/config/accounts"
  printf 'rolling-runs-v9/slices\n' >"$h/Tools/firstmate/data/bulk-paths.txt"
  printf '%s\n' "$AXI_HOOKS" >"$h/.claude/settings.json"
  printf '%s' "$AXI_HOOKS" >"$h/.codex/hooks.json"
  printf 'scratch/\n' >"$h/lattice-ledger/.ignore"
  printf 'model = "x"\n' >"$h/.codex/config.toml"
  printf '%s\n' "$h"
}

snapshot() {  # <home>: hash every file outside the installer's own state dir
  (cd "$1" && find . -path ./.local -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$f"
  done
  find . -path ./.local -prune -o -type d -print | LC_ALL=C sort)
}

inst() {  # <home> <args...>
  local h=$1
  shift
  HOME="$h" "$INSTALL" "$@"
}

test_dry_run_writes_nothing() {
  local h before out
  h=$(new_home dry)
  before=$(snapshot "$h")
  out=$(inst "$h" install --dry-run) || fail "dry-run install failed: $out"
  assert_contains "$out" "dry run: nothing was written" "dry run says so"
  assert_contains "$out" "changed   $h/.claude/settings.json" "dry run still prints the per-file summary"
  assert_equals "$before" "$(snapshot "$h")" "dry-run install changes no file"
  assert_absent "$h/.local/state/lattice-data-gate" "dry-run install writes no state"
  inst "$h" install >/dev/null || fail "install failed"
  before=$(snapshot "$h")
  inst "$h" uninstall --dry-run >/dev/null || fail "dry-run uninstall failed"
  assert_equals "$before" "$(snapshot "$h")" "dry-run uninstall changes no file"
  pass "dry-run changes nothing"
}

test_install_merges_and_backs_up() {
  local h out backups
  h=$(new_home merge)
  out=$(inst "$h" install) || fail "install failed: $out"
  for f in .claude/settings.json .claude-work/settings.json .claude-gmail/settings.json .claude-tetmet/settings.json \
    .codex/hooks.json .codex/config.toml .grok/hooks/lattice-data-gate.json \
    .config/opencode/plugins/lattice-data-gate.js .pi/agent/extensions/lattice-data-gate.ts \
    .omp/agent/extensions/lattice-data-gate.ts Tools/firstmate/data/bulk-paths.txt \
    Tools/firstmate/data/.ignore Tools/firstmate/data/.rgignore \
    lattice-ledger/.ignore lattice-ledger/.rgignore .config/lattice-data-gate/mode; do
    assert_present "$h/$f" "install writes $f"
    assert_contains "$out" "$h/$f" "summary names $f"
  done
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const cmds = s.hooks.SessionStart.map((g) => g.hooks[0].command).join(",");
    if (cmds !== "gh-axi,chrome-devtools-axi,lavish-axi") throw new Error("SessionStart disturbed: " + cmds);
    if (s.theme !== "dark") throw new Error("other keys disturbed");
    const pre = s.hooks.PreToolUse;
    if (pre.length !== 1 || pre[0].matcher !== "Bash|Grep|Glob" || !pre[0].hooks[0].command.includes("fm-data-gate.sh")) throw new Error(JSON.stringify(pre));
  ' "$h/.claude/settings.json" || fail "claude settings keep existing entries and gain one gate entry"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (s.hooks.SessionStart.length !== 3 || s.hooks.PreToolUse[0].matcher !== "Bash") throw new Error("codex merge wrong");
  ' "$h/.codex/hooks.json" || fail "codex hooks keep axi entries and gain a Bash gate entry"
  assert_absent "$h/.codex-alt/settings.json" "a Codex account folder gets no Claude settings"
  assert_equals "log" "$(cat "$h/.config/lattice-data-gate/mode")" "default mode after install is log"
  assert_equals "log" "$(HOME="$h" env -u LATTICE_DATA_GATE "$GATE" mode)" "the gate reads mode log"
  assert_grep "rolling-runs-v9/slices/" "$h/Tools/firstmate/data/.rgignore" "home ignore lists its bulk paths"
  assert_grep "search-recording/" "$h/lattice-ledger/.ignore" "ledger ignore lists search-recording"
  assert_grep "scratch/" "$h/lattice-ledger/.ignore" "an existing ignore entry is kept"
  backups=$(find "$h/.local/state/lattice-data-gate/backups" -type f | wc -l)
  assert_equals 5 "$((backups))" "every pre-existing file touched is backed up (claude, codex hooks and config, bulk paths, ledger .ignore)"
  cmp -s "$(find "$h/.local/state/lattice-data-gate/backups" -path '*/.claude/settings.json')" <(printf '%s\n' "$AXI_HOOKS") \
    || fail "the claude backup holds the exact pre-install bytes"
  assert_grep 'model = "x"' "$h/.codex/config.toml" "the Codex config keeps its own settings"
  pass "install merges without disturbing entries and backs up each touched file"
}

test_generated_bulk_paths_feed_gate_and_ignores() {
  local h roots data
  h=$(new_home bulk)
  data="$h/Tools/firstmate/data"
  inst "$h" install >/dev/null || fail "install failed"
  assert_grep 'rolling-runs-v9/slices' "$data/bulk-paths.txt" "the home's own bulk line is kept"
  for entry in 'rolling-runs-*/slices/' '*/tetjet-results/' 'shell-contact-first-runs/runs*/'; do
    assert_grep "$entry" "$data/bulk-paths.txt" "bulk-paths.txt is generated with $entry"
    assert_grep "$entry" "$data/.rgignore" ".rgignore lists the generated $entry"
  done
  roots=$(HOME="$h" "$GATE" roots)
  assert_contains "$roots" "root $data/exp/tetjet-results" "the gate protects a generated bulk glob's match"
  HOME="$h" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$h/Tools/firstmate" --command 'du -sh data/exp' >/dev/null 2>&1
  expect_code 2 $? "a scan over a generated bulk dir's parent is refused"
  HOME="$h" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$h/Tools/firstmate" --command 'find data/rolling-runs-v9 -name x' >/dev/null 2>&1
  expect_code 2 $? "a scan over a rolling-runs dir is refused"
  pass "one generated bulk definition feeds the gate and the ignore files"
}

test_reinstall_is_idempotent() {
  local h first out backups_before backups_after
  h=$(new_home idem)
  inst "$h" install >/dev/null || fail "install failed"
  first=$(snapshot "$h")
  backups_before=$(find "$h/.local/state/lattice-data-gate/backups" -type f | wc -l)
  out=$(inst "$h" install) || fail "re-install failed"
  assert_equals "$first" "$(snapshot "$h")" "re-install changes no file"
  if printf '%s\n' "$out" | grep -qE '^(changed|created) '; then fail "re-install reports a change: $out"; fi
  backups_after=$(find "$h/.local/state/lattice-data-gate/backups" -type f | wc -l)
  assert_equals "$backups_before" "$backups_after" "re-install takes no new backup"
  pass "re-install is idempotent"
}

test_uninstall_restores_bytes() {
  local h before out
  h=$(new_home restore)
  before=$(snapshot "$h")
  inst "$h" install >/dev/null || fail "install failed"
  inst "$h" install >/dev/null || fail "re-install failed"
  out=$(inst "$h" uninstall) || fail "uninstall failed: $out"
  assert_equals "$before" "$(snapshot "$h")" "uninstall restores every file and directory byte-identically"
  assert_contains "$out" "restored  $h/.claude/settings.json" "summary names the restore"
  assert_absent "$h/.local/state/lattice-data-gate/install-manifest.json" "uninstall clears the manifest"
  pass "uninstall restores byte-identical pre-install content"
}

test_reinstall_after_edit_keeps_edits() {
  local h data
  h=$(new_home reedit)
  data="$h/Tools/firstmate/data"
  inst "$h" install >/dev/null || fail "install failed"
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.model = "opus";
    s.permissions = { allow: ["Bash(ls)"] };
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' "$h/.claude/settings.json"
  printf 'mine/\n' >>"$data/.ignore"
  printf 'extra-bulk/\n' >>"$data/bulk-paths.txt"
  inst "$h" install --gate "$TMP_ROOT/elsewhere/fm-data-gate.sh" >/dev/null || fail "re-install failed"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const text = JSON.stringify(s);
    if (text.includes("fm-data-gate.sh")) throw new Error("gate entry left behind");
    if (s.model !== "opus" || s.permissions?.allow?.[0] !== "Bash(ls)" || s.theme !== "dark") throw new Error("edits lost: " + text);
  ' "$h/.claude/settings.json" || fail "edits made between two installs survive uninstall"
  assert_equals "mine/" "$(cat "$data/.ignore")" "an ignore line added between installs survives uninstall"
  assert_equals "$(printf 'rolling-runs-v9/slices\nextra-bulk/')" "$(cat "$data/bulk-paths.txt")" "bulk lines added between installs survive uninstall"
  assert_no_grep 'pre_tool_use' "$h/.codex/config.toml" "no Codex trust entry is left behind"
  pass "a re-install after edits never makes uninstall discard them"
}

test_uninstall_after_edit_strips_only_gate() {
  local h
  h=$(new_home edited)
  inst "$h" install >/dev/null || fail "install failed"
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.hooks.PreToolUse.push({ matcher: "Edit", hooks: [{ type: "command", command: "my-own-hook" }] });
    s.model = "opus";
    fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  ' "$h/.claude/settings.json"
  printf 'mine/\n' >>"$h/Tools/firstmate/data/.ignore"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const text = JSON.stringify(s);
    if (text.includes("fm-data-gate.sh")) throw new Error("gate entry left behind");
    if (!text.includes("my-own-hook") || s.model !== "opus" || s.hooks.SessionStart.length !== 3) throw new Error("later edits lost: " + text);
  ' "$h/.claude/settings.json" || fail "uninstall after an edit removes only the gate entry"
  assert_equals "mine/" "$(cat "$h/Tools/firstmate/data/.ignore")" "uninstall keeps a later ignore line and drops only the gate block"
  pass "uninstall after later edits removes only the gate entries"
}

test_unparseable_settings_left_untouched() {
  local h out
  h=$(new_home broken)
  printf '{ not json\n' >"$h/.claude/settings.json"
  out=$(inst "$h" install) || fail "install failed"
  assert_contains "$out" "skipped   $h/.claude/settings.json" "an unparseable file is reported"
  assert_equals '{ not json' "$(cat "$h/.claude/settings.json")" "an unparseable file is left untouched"
  pass "unparseable settings are skipped, not clobbered"
}

test_only_existing_harnesses() {
  local h out
  h="$TMP_ROOT/bare"
  mkdir -p "$h/.claude"
  out=$(inst "$h" install) || fail "install failed"
  assert_absent "$h/.codex" "no codex dir is created"
  assert_absent "$h/.pi" "no pi dir is created"
  assert_present "$h/.claude/settings.json" "claude settings created where ~/.claude exists"
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  assert_absent "$h/.claude/settings.json" "uninstall removes a settings file install created"
  pass "only harnesses with a user config dir are touched"
}

test_installed_adapters_call_the_gate() {
  local h cmd payload cwd="$TMP_ROOT/adapters/Tools/firstmate"
  h=$(new_home adapters)
  inst "$h" install >/dev/null || fail "install failed"
  printf 'enforce\n' >"$h/.config/lattice-data-gate/mode"
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"rg foo"}}))' "$cwd")

  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.claude/settings.json")
  printf '%s' "$payload" | HOME="$h" env -u GROK_AGENT -u GROK_HOOK_EVENT sh -c "$cmd" >/dev/null 2>&1
  expect_code 2 $? "the installed Claude hook command refuses a home-root scan"
  printf '%s' "$payload" | HOME="$h" GROK_AGENT=1 sh -c "$cmd" >/dev/null 2>&1
  expect_code 0 $? "the Claude hook stands down under Grok"

  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.codex/hooks.json")
  printf '%s' "$payload" | HOME="$h" sh -c "$cmd" >/dev/null 2>&1
  expect_code 2 $? "the installed Codex hook command refuses a home-root scan"

  cmd=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PreToolUse[0].hooks[0].command)' "$h/.grok/hooks/lattice-data-gate.json")
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],toolName:"Bash",toolInput:{command:"rg foo"}}))' "$cwd")
  printf '%s' "$payload" | HOME="$h" sh -c "$cmd" 2>/dev/null | grep -q '"decision":"deny"' || fail "the installed Grok hook prints a deny decision"

  if [ "$(node -p 'Boolean(process.features.typescript)' 2>/dev/null)" != true ]; then
    pass "this node cannot load TypeScript; the Pi extension check is skipped here"
  else
  HOME="$h" node --input-type=module -e '
    const [ext, cwd] = process.argv.slice(1);
    const mod = await import(ext);
    const handlers = {};
    mod.default({ on: (name, fn) => { handlers[name] = fn; } });
    const blocked = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: "rg foo" } }, { cwd });
    if (!blocked.block || !blocked.reason.startsWith("BLOCKED (data gate)")) throw new Error("pi did not block: " + JSON.stringify(blocked));
    const allowed = await handlers.tool_call({ type: "tool_call", toolName: "bash", input: { command: "rg foo data" } }, { cwd: cwd + "/bin" });
    if (allowed.block) throw new Error("pi blocked an allowed call");
    const grep = await handlers.tool_call({ type: "tool_call", toolName: "grep", input: { pattern: "x", path: "/" } }, { cwd });
    if (!grep.block) throw new Error("pi grep tool over / not blocked");
  ' "$h/.pi/agent/extensions/lattice-data-gate.ts" "$cwd" 2>&1 || fail "the installed Pi extension blocks through the gate"
  fi

  HOME="$h" node --input-type=module -e '
    const [plugin, cwd] = process.argv.slice(1);
    const mod = await import(plugin);
    const hooks = await mod.LatticeDataGate({ directory: cwd });
    let threw = false;
    try { await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "du -sh ~" } }); } catch (e) { threw = e.message.startsWith("BLOCKED (data gate)"); }
    if (!threw) throw new Error("opencode did not block");
    await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "ls" } });
  ' "$h/.config/opencode/plugins/lattice-data-gate.js" "$cwd" 2>&1 || fail "the installed OpenCode plugin blocks through the gate"
  pass "installed Claude, Codex, Grok, Pi and OpenCode adapters call the gate"
}

# Codex's hook trust contract (codex-rs hooks discovery): the key is
# "<hooks.json>:pre_tool_use:<group>:<handler>" and the hash is sha256 over the
# key-sorted compact JSON of {event_name, matcher, hooks:[normalized handler]}.
codex_expected_trust() {  # <hooks.json>
  node -e '
    const crypto = require("crypto");
    const path = process.argv[1];
    const groups = JSON.parse(require("fs").readFileSync(path, "utf8")).hooks.PreToolUse;
    const g = groups.findIndex((x) => x.hooks.some((k) => k.command.includes("fm-data-gate.sh")));
    const k = groups[g].hooks.findIndex((x) => x.command.includes("fm-data-gate.sh"));
    const hook = groups[g].hooks[k];
    const id = JSON.stringify({ event_name: "pre_tool_use", hooks: [{ async: false, command: hook.command, timeout: hook.timeout, type: "command" }], matcher: groups[g].matcher });
    process.stdout.write(`[hooks.state."${path}:pre_tool_use:${g}:${k}"]\ntrusted_hash = "sha256:${crypto.createHash("sha256").update(id).digest("hex")}"`);
  ' "$1"
}

test_codex_trust_and_status() {
  local h out
  h=$(new_home status)
  printf '[hooks.state."%s:pre_tool_use:0:0"]\ntrusted_hash = "sha256:old"\n\n[tui]\nx = 1\n' "$h/.codex/hooks.json" >>"$h/.codex/config.toml"
  out=$(inst "$h" status) || fail "status failed"
  assert_contains "$out" "missing   $h/.claude/settings.json" "status before install"
  assert_contains "$out" "missing   $h/.codex/config.toml" "no Codex trust before install"
  inst "$h" install >/dev/null || fail "install failed"
  assert_contains "$(cat "$h/.codex/config.toml")" "$(codex_expected_trust "$h/.codex/hooks.json")" "install records Codex's trust hash for exactly the gate hook"
  assert_equals 1 "$(grep -c 'pre_tool_use:0:0' "$h/.codex/config.toml")" "a stale entry at the gate hook's key is replaced, not duplicated"
  assert_grep 'x = 1' "$h/.codex/config.toml" "other Codex tables are kept"
  out=$(inst "$h" status) || fail "status failed"
  assert_contains "$out" "mode      log" "status shows the mode"
  assert_contains "$out" "installed $h/.codex/hooks.json" "status after install"
  assert_contains "$out" "installed $h/.codex/config.toml" "status sees the Codex trust entry"
  printf '[later]\ny = 2\n' >>"$h/.codex/config.toml"
  if inst "$h" install | grep -q "^changed   $h/.codex/config.toml"; then fail "a re-install rewrote a current Codex trust entry"; fi
  inst "$h" uninstall >/dev/null || fail "uninstall failed"
  assert_no_grep 'fm-data-gate' "$h/.codex/hooks.json" "uninstall removes the Codex hook"
  assert_no_grep 'pre_tool_use' "$h/.codex/config.toml" "uninstall removes the Codex trust entry"
  assert_grep 'y = 2' "$h/.codex/config.toml" "uninstall keeps later Codex settings"
  pass "install records the Codex trust hash and status reports it"
}

test_dry_run_writes_nothing
test_install_merges_and_backs_up
test_reinstall_is_idempotent
test_uninstall_restores_bytes
test_generated_bulk_paths_feed_gate_and_ignores
test_reinstall_after_edit_keeps_edits
test_uninstall_after_edit_strips_only_gate
test_unparseable_settings_left_untouched
test_only_existing_harnesses
test_installed_adapters_call_the_gate
test_codex_trust_and_status
