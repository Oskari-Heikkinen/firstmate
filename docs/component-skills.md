# Component hook

This document is the authoritative human-readable contract for the hook that tells an agent which component governs a file it touches.

The shipped mechanism is `bin/fm-component-check.sh`.
On the first touch of a mapped path in a session it returns that component's goal section and the path of its skill as context.
It informs and never blocks.
The component map and the skill shape it reads are owned by [`component-map.md`](component-map.md).

## Why this exists

A component skill carries the goal and operating principle of one part of a repository, the changes that part refuses, and the checklist a review of it applies.
A skill loads only when the model judges its description relevant, and that judgment is weakest exactly when it matters most: an agent starting a quick fix in a component it has not read about.
The fix then follows local convenience instead of the component's goal, and the review layer catches it only after the work is done.

The hook makes the goal arrive deterministically.
The path an agent touches is a mechanical signal, the map turns it into a component, and the goal reaches the agent's context before the agent changes anything.

## Purpose and boundary

The hook answers one question: which component governs this path, and what is that component's goal.

It deliberately does **not** enforce anything.
A deny cannot verify that the agent understood the goal, it would stall harnesses whose reads are not hooked, and the review pack from `bin/fm-component-map.sh review-pack` already checks conformance deterministically.

It does not choose components by judgment either.
A path the map does not cover produces nothing, and a path two components cover produces both.

It reads maps and skills only through `bin/fm-component-map.sh`, through `touched` for resolution and `goal` for the goal text.
It never parses a map or a skill itself, so the map tools stay the single owner of the schema, the globs and the skill shape.

## Shipped mechanism

`bin/fm-component-check.sh` runs in one of three modes, chosen from its input.

- **Path mode.**
  The input names a file through `tool_input.file_path`, `tool_input.notebook_path`, Grok's `toolInput`, or `--path`.
  A relative path resolves against the input's working directory.
  The hook resolves the file against two sources: the repository map at `docs/component-map.json` in the file's git top level, and the home map at `$FM_HOME/config/component-map.json`.
  A file that does not exist yet, such as a Write into a new directory, resolves through its nearest existing parent directory.
- **Sweep mode.**
  A Bash tool call names no file, so after it the hook runs `git --no-optional-locks status --porcelain` in the working directory's repository, which never rewrites the index under the agent's own git commands.
  Every changed or untracked path is fingerprinted by its status, size and modification time, with one batched `stat` and one `awk` diff, so a sweep stays cheap however many paths are dirty.
  A path whose fingerprint differs from this session's previous sweep counts as touched.
  A rename counts only its new path.
- **Reset mode.**
  A `SessionStart` whose source is `compact` forgets which components the main session was told about, so their goals return after compaction.
  Subagent records are kept, because compaction of the main context does not touch a subagent's context.
  Every other `SessionStart` source, including `resume`, keeps the record.

Each component is injected once per session.
A subagent, identified by `agent_id`, has its own context and therefore its own record, so it receives the goal even when the main session already has it.
Records live under `FM_COMPONENT_STATE_DIR`, which defaults to `${TMPDIR:-/tmp}/fm-component-check.<uid>`, in owner-only directories serialized with `flock`.
A payload with no session id falls back to the parent process id.

Each injected block opens with one line naming the touched files, the component, whether it is provisional, and the skill path that holds its full rules, refuse list and review checklist.
The component's `## Goal and operating principle` section follows that line verbatim.
When the goal cannot be read, the block says so and points at `bin/fm-component-map.sh check`.

Claude Code caps `additionalContext` at 10,000 characters, and the hook keeps its text under 9,500.
When a full block does not fit behind earlier blocks, the hook adds only its opening line with a note that the goal comes with the next touch, and leaves the component unrecorded so the next touch of its files delivers it.
A block too big for any message, which only a goal over the size `check` enforces can produce, gets its opening line with a note that the goal is over the size limit and that `bin/fm-component-map.sh check` reports it; that component is recorded, so the note is not repeated.

## Output contract

- Inject returns exit 0 and writes the context to stdout.
  With `--claude` that is `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}`, where the event is the input's own, defaulting to `PreToolUse` in path mode and `PostToolUse` in sweep mode.
  Without `--claude` it is the plain text, for adapters.
- Silent returns exit 0 with no output: nothing mapped, everything already injected, a reset, a path outside any repository with no home map, or no map anywhere.
- An unusable map, one that `bin/fm-component-map.sh touched` refuses with exit 3, produces one context line naming the map and its first problem, once per session.
  It never produces a deny.
- A bad argument (reported on stderr), malformed or empty stdin, a payload that is not a JSON object, missing `jq` in stdin mode, and any resolver failure all fail open with exit 0, because several harnesses read exit 2 as a block.

## Harness wiring

| Harness | Wiring | Status |
| --- | --- | --- |
| Claude | Tracked `.claude/settings.json`: `PreToolUse` on `Read\|Edit\|Write\|MultiEdit\|NotebookEdit`, `PostToolUse` on `Bash`, and `SessionStart` on `compact`, each passing `--claude` with a 10-second timeout. | Wired for sessions in this repository. |
| Grok | Grok loads Claude project settings, so each tracked entry carries the `GROK_AGENT`/`GROK_HOOK_EVENT` guard and is inert under Grok, as recorded in [`turnend-guard.md`](turnend-guard.md). | Not wired; a Grok adapter would call the hook with `--tool`. |
| Codex | Crewmates and scouts launch with hooks disabled. | Not wired; relies on the component section in the task brief. |
| Cursor | Cursor also loads Claude project settings, and the component entries do not stand down on a Cursor payload the way the supervision entries do, because no Cursor registration covers this event. | Fires with Claude-shaped output; whether Cursor reads that context is unverified. |
| Pi | pi-code loads `<project>/.claude/settings.json` and keeps running the Claude-shaped hooks it delivers, as recorded in [`turnend-guard.md`](turnend-guard.md), and the component entries carry only the Grok guard. | Fires with Claude-shaped output; whether pi-code reads that context is unverified. |
| Others | Gemini, opencode and omp would call `--tool <name> --path <file> --session <id>` from their own pre-tool event. | Not wired. |

Installing the hook into crewmate and secondmate sessions in other repositories, the adapter wiring, and the brief section for hook-less harnesses belong to `bin/fm-spawn.sh` and are not part of this script.

## Automated validation

`tests/fm-component-check.test.sh` drives the script through its public input shapes against fixture repositories and homes.
It covers injection on Read, Edit and a relative notebook path, silence on a second touch, a file in two components, silence for unmapped paths, a repository with no map and a path outside any repository, a Write into a missing directory, a separate subagent record, reset on `compact` but not on `resume`, the Bash sweep including a rename in a clean repository and untracked names with spaces, an unchanged index after a sweep over a stale one, a time bound on sweeps over 2,000 untracked files, one non-blocking line for an unusable map, fail-open on malformed stdin, the home map alone and beside a repository map, the output cap with held-back goals arriving on the next touch, a goal over the budget recorded with its pointer line, bad arguments failing open, and the Grok and `--tool` shapes.
`tests/fm-component-map.test.sh` covers the `goal` command and the home-map forms of `check` and `touched`.
`tests/fm-turnend-guard.test.sh` pins that the tracked entries stay inert under Grok.

## Known residual gaps

- The first sweep in a session counts every changed path, because the hook cannot tell which changes predate the session.
  A session that starts in a dirty worktree may therefore receive goals for files it has not touched yet.
- The sweep sees only the working directory's git repository.
  A Bash command that changes home data outside git, or files in another repository, is caught only when a file tool later touches them.
- A home map is never checked in CI, because it lives outside the repository.
  `bin/fm-component-map.sh check <map>` validates one on demand.
- A Bash command that only reads a mapped file changes nothing in `git status`, so it injects no goal.
