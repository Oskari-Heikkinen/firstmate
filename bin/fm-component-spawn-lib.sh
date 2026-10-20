#!/usr/bin/env bash
# Spawn-time wiring of component skills (docs/component-skills.md): the
# component hook entries bin/fm-spawn.sh writes into a Claude settings file and
# a Pi extension, and what it appends to a ship or scout launch brief: the
# component review pack and the `## Component skills` section.
# Sourced by bin/fm-spawn.sh. This file is sourced by scripts and has no side
# effects on source.
#
# Why one owner: the hook command, its matchers and the brief section must
# agree for crewmates, scouts and secondmates of every harness, and component
# paths resolve only through bin/fm-component-map.sh; nothing here parses the
# map or a skill's Markdown.

# JSON string literal, quotes included, of <text>.
fm_component_json() {
  perl -MJSON::PP -MEncode=decode_utf8 -e 'print JSON::PP->new->utf8->allow_nonref->encode(decode_utf8($ARGV[0]))' -- "$1"
}

fm_component_sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The hook's FM_HOME: the home whose config/component-map.json applies, the
# spawning home or a secondmate's own home.
fm_component_home() {  # <kind> <fm-home> <worktree>
  if [ "$1" = secondmate ]; then printf '%s' "$3"; else printf '%s' "$2"; fi
}

# Claude hook entries, each followed by a comma, to open a settings file's
# "hooks" object: SessionStart on compact, PreToolUse on the file tools and
# PostToolUse on Bash, each passing --claude with a 10-second timeout. A
# worktree of Firstmate's own repo also registers them in the tracked
# .claude/settings.json; the hook's per-session record makes the second
# registration inject nothing.
fm_component_claude_entries() {  # <fm-root> <kind> <fm-home> <worktree>
  local hook
  hook="{\"type\":\"command\",\"command\":$(fm_component_json "FM_HOME=$(fm_component_sq "$(fm_component_home "$2" "$3" "$4")") $(fm_component_sq "$1/bin/fm-component-check.sh") --claude || true"),\"timeout\":10}"
  printf '"SessionStart":[{"matcher":"compact","hooks":[%s]}],"PreToolUse":[{"matcher":"Read|Edit|Write|MultiEdit|NotebookEdit","hooks":[%s]}],"PostToolUse":[{"matcher":"Bash","hooks":[%s]}],' "$hook" "$hook" "$hook"
}

# Pi extension handlers, for the body of a default-exported (pi) function that
# has execFile from node:child_process in scope.
fm_component_pi_handlers() {  # <fm-root> <kind> <fm-home> <worktree>
  cat <<EOF
  // Component hook (docs/component-skills.md): after a read, edit or write,
  // append the goal of each component that claims the file to the tool
  // result; after bash, the hook sweeps git status for changed files. A
  // compaction forgets what this session was told. The hook always exits 0
  // and prints nothing where no component map claims a path.
  const componentCheck = $(fm_component_json "$1/bin/fm-component-check.sh");
  const componentEnv = { ...process.env, FM_HOME: $(fm_component_json "$(fm_component_home "$2" "$3" "$4")") };
  const componentCwd = $(fm_component_json "$4");
  const componentTools: Record<string, string> = { read: "Read", edit: "Edit", write: "Write", bash: "Bash" };
  const componentHook = (args: string[], input = "") => new Promise<string>((resolve) => {
    try {
      const child = execFile(componentCheck, args, { env: componentEnv, timeout: 10000 },
        (_err: any, stdout: any) => resolve(typeof stdout === "string" ? stdout.trim() : ""));
      child.stdin?.end(input);
    } catch { resolve(""); }
  });
  const componentSession = (ctx: any) => {
    try { return String(ctx?.sessionManager?.getSessionId?.() ?? ""); } catch { return ""; }
  };
  pi.on("tool_result", async (event: any, ctx: any) => {
    const tool = componentTools[event?.toolName];
    if (!tool) return;
    const args = ["--tool", tool, "--cwd", typeof ctx?.cwd === "string" && ctx.cwd ? ctx.cwd : componentCwd];
    if (tool !== "Bash") {
      const path = event?.input?.path;
      if (typeof path !== "string" || !path) return;
      args.push("--path", path);
    }
    const session = componentSession(ctx);
    if (session) args.push("--session", session);
    const text = await componentHook(args);
    if (!text) return;
    return { content: [...(Array.isArray(event.content) ? event.content : []), { type: "text", text }] };
  });
  pi.on("session_compact", async (_event: any, ctx: any) => {
    await componentHook([], JSON.stringify({ hook_event_name: "SessionStart", source: "compact", session_id: componentSession(ctx) }));
  });
EOF
}

# The `## Component skills` section of a launch brief whose task checkout has a
# docs/component-map.json. Paths come only from `bin/fm-component-map.sh list`;
# a checkout without a map prints nothing, and an unusable map prints a
# section that says so and returns 1 so the caller can warn. Every harness gets
# it: it is the only component guidance a runtime without the component hook
# receives.
fm_component_skills_block() {  # <checkout> <fm-root>
  local checkout=$1 tool="$2/bin/fm-component-map.sh" rows rc=0 id skill prov globs mark
  # shellcheck disable=SC2016 # the backticks are Markdown, not expansions
  local sep='`, `'
  rows=$("$tool" list "$checkout" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat <<EOF
## Component skills
This checkout's \`docs/component-map.json\` could not be read (\`fm-component-map.sh list\` exited $rc), so no component is listed here. Run \`$tool check $checkout\` to see why; until it passes, look in \`.agents/skills/\` and \`.claude/skills/\` for the component skill that governs a path before changing it.
EOF
    return 1
  fi
  [ -n "$rows" ] || return 0
  cat <<EOF
## Component skills
This checkout maps its paths to component skills in \`docs/component-map.json\`. Before changing a mapped path, load its skill; before reporting done, answer its Review checks and record \`Component review: <id>: PASS\` or the finding in your report or PR body. \`$tool touched $checkout <path>\` names the components that claim a path.
EOF
  while IFS=$'\t' read -r id skill prov globs; do
    mark=
    [ "$prov" = 1 ] && mark=' (provisional)'
    # shellcheck disable=SC2016 # the backticks are Markdown, not expansions
    printf -- '- `%s`%s: skill `%s`; paths `%s`\n' "$id" "$mark" "$skill" "${globs//$'\t'/$sep}"
  done <<<"$rows"
}

# Append to a ship or scout's launch <brief> the component review pack file
# <pack> when it is non-empty (bin/fm-spawn.sh builds it for a review task),
# then fm_component_skills_block when <checkout> has a component map, in one
# rewrite through a temporary file beside <brief> and a rename. An unusable map
# warns and still appends the section that says so. Returns 1, with <brief>
# unchanged, only when the brief could not be rewritten.
fm_component_brief_append() {  # <checkout> <fm-root> <brief> <task-id> <pack>
  local checkout=$1 brief=$3 pack=$5 section='' tmp
  if [ -f "$checkout/docs/component-map.json" ]; then
    section=$(fm_component_skills_block "$checkout" "$2") ||
      echo "warning: $checkout/docs/component-map.json is unusable, so $4's brief says so instead of listing components; run bin/fm-component-map.sh check $checkout" >&2
  fi
  [ -s "$pack" ] || [ -n "$section" ] || return 0
  tmp="${brief%/*}/.${brief##*/}.component.${BASHPID:-$$}"
  if {
    cat -- "$brief" &&
      { [ ! -s "$pack" ] || cat -- "$pack"; } &&
      { [ -z "$section" ] || printf '\n%s\n' "$section"; }
  } >"$tmp" && mv -- "$tmp" "$brief"; then
    return 0
  fi
  rm -f -- "$tmp"
  echo "error: could not append the component review pack or skills section to $brief" >&2
  return 1
}
