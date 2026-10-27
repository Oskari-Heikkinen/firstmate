---
name: firstmate-coding-guidelines
description: Load first, before reading code, whenever you will edit any tracked file in the Firstmate repository - a script or library under bin/, a test under tests/, a skill under .agents/skills/ (including adding a new one), a doc under docs/, AGENTS.md, CONTRIBUTING.md or the README - as firstmate or as a worker on a Firstmate-repo task, even when a more specific skill also applies; and before deciding where a new rule or fact belongs, moving text out of AGENTS.md, or writing a worker brief for a Firstmate-repo change. Holds the knowledge-placement tree, the one-owner rule for prose and for code that parses a shared format, size and trigger hygiene, harness-dependent proof and the repo style rules.
user-invocable: false
metadata:
  internal: true
---

# firstmate-coding-guidelines

Load this before changing firstmate's shared, tracked material: any file tracked in this repository.

Route conditional detail to its on-demand owner so always-loaded instructions stay focused on rules needed in every session.
Each component's goals and review checks live in the skill that `docs/component-map.json` names for it; load it before changing a mapped path.

Why this skill exists: rules were written where no agent would read them at the moment of action, the same fact was restated in several files that then drifted, and dated rules accumulated in always-loaded text (root causes R1, R4 and R8).

## Knowledge-placement decision tree

Before writing a new fact anywhere in this repo, ask where it belongs, in this order.

1. Does the firstmate AGENT need this on every session or every turn to operate?
   If yes: `AGENTS.md`, inline.
2. Does the agent need it only in a nameable situation - a spawn, a recovery, a specific wake type, a specific lifecycle step?
   If yes: an agent-only skill under `.agents/skills/`, whose description states its load trigger; leave a one-line inline pointer in `AGENTS.md` only when an always-loaded rule must name the skill.
3. Is it public product, setup, or user/operator reference?
   If yes: the surface classified for that audience in [`docs/documentation-audiences.md`](../../../docs/documentation-audiences.md), limited to current behavior, setup, supported limits, stable invariants, concise rationale, and current verification entry points.
4. Is it contributor/maintainer architecture?
   If yes: the classified maintainer-architecture owner for stable ownership, extension points, mechanism boundaries, and safety rationale.
5. Is it active reusable verification for a current guarantee?
   If yes: an explicitly classified maintainer-verification record may keep current dates, versions, exact commands, and exact output.
6. Is it task or incident evidence - chronology, transcripts, branches, temporary paths, failed hypotheses, or delivery proof?
   If yes: keep it in the private task report or PR evidence by default, after distilling every unique current fact into its authoritative owner.
7. Is it mechanics - exact flags, exact commands, exact paths?
   If yes: the script's own header comment plus its `--help` output, not prose in `AGENTS.md`, a skill, or a second documentation owner.

Stop at the first tier that answers yes.
Do not place a fact at a more convenient tier than the one this tree gives you.
The machine-consumed inventory in [`docs/documentation-audiences.json`](../../../docs/documentation-audiences.json) is the single classification owner for maintained prose surfaces; do not add parallel front matter or a second audience list.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly once.
Every other mention of it is a one-line cross-reference, never a restatement.
A single deliberate one-line reinforcement at a genuine risk point is allowed, for example a "don't forget X" placed exactly where forgetting X is costly.
Restating the contract's substance a second time is not allowed: the two copies will drift the moment only one is edited.
When you touch a contract, patch, replace, or prune the owner's existing language rather than appending a new clause or paragraph wherever possible, then grep the repo for its other mentions and update the cross-references, not duplicate the change into a second full copy.
The rule covers code too: each shared format (a registry line, an outcome vocabulary, a status line) has one parsing function that every reader sources, and a value it does not recognize surfaces as unrecognized - an alarm or a detail - never as a silent default, because a fix in one hand-rolled parser never reaches its siblings.

## Inline-stub pattern

When content moves out of `AGENTS.md` into a skill, decide what stays behind by asking one question: what must survive with no skill loaded?
That is the trigger condition for loading the skill, plus any safety-critical fact that fires on a wake the skill itself is not loaded for.
Everything else - the procedure, the mechanism, the surrounding detail - moves out completely.
Do not leave a partial restatement behind "just in case".
A partial copy is exactly the duplication the one-owner rule forbids.
After moving, renumbering or retitling `AGENTS.md` text, grep `.agents/skills/`, `docs/` and `bin/` for references to the old section number or heading (`AGENTS.md` section N) and repoint each one in the same change, because nothing else fails on a dangling section reference.
Usually nothing stays: the skill's own description is its trigger, so `AGENTS.md` keeps a line only for a safety rule or a recorded-mistake fix that must hold with no skill loaded.

## Size discipline

`AGENTS.md` keeps only safety-critical rules and rules that fix a mistake agents actually made; everything else moves to a skill loaded at its trigger, a script, or a doc, or is cut.
Apply the decision tree above to every line you are about to add to `AGENTS.md`, prefer rewriting or pruning existing entries over appending, and preserve every safety boundary.
If an addition needs more than a few lines of conditional detail (detail that matters only in a specific situation) or reference detail (a wire format, an exact schema, historical rationale), you are almost certainly adding it to the wrong file.
`AGENTS.md`'s token cost is paid by every session of every fleet member, every time, whether or not that session ever hits the situation the new lines describe.
A skill's cost is paid only by the sessions that actually load it.
When in doubt, write the fact into the skill or doc first by patching that owner's existing language, and add only the one-line trigger to `AGENTS.md`.
A rule that keeps recurring while its skill is already loaded needs a tool or guard that enforces it, not more prose.

## Trigger hygiene

A new skill is dead weight if nothing loads it.
Every new skill needs its load trigger declared in its description, which is the always-loaded trigger index; add an inline `AGENTS.md` pointer only in the operating section whose always-loaded rule must name it.
State the trigger as a condition ("load before X", "load on Y wake"), never as a vague pointer.
`fm_brief_worker_role` in `bin/fm-dod-lib.sh` names this skill, with its file path as the fallback, in every launch brief whose project may be Firstmate, and `CONTRIBUTING.md`'s "Development" section carries the same instruction for contributors.
A brief points at a skill by name and by its absolute path in the home's checkout instead of copying the skill's rule text, so a worker in another repository, which cannot see Firstmate's skill index, can still read it, and the rule keeps one owner.

## Compatibility and enforcement

Before changing shared tracked behavior, review every affected supported primary harness and runtime backend rather than checking only the adapters active in the current fleet.
Mark an axis not applicable only after inspecting its integration surface, and update the corresponding verification evidence when behavior changes.

For critical safety, routing, startup, and supervision infrastructure, prefer deterministic and idempotent enforcement over relying on agent memory alone.
Keep instructions as the authority and discovery layer, but make repeated execution converge safely and make invalid or unsafe states fail closed wherever the runtime can enforce them.

### Harness-dependent checks

This section is the single owner of the rule and of how to satisfy it.

A check is harness-dependent when its verdict comes from something the vendor emits: a process name, rendered output, a spinner or keybind glyph, a banner, or a key the harness binds.
Anything in that class must be proven end to end against the real harness, because a stub or fake agent can only confirm the assumption already written into the stub.
That proof is authorized to spend tokens; the cost is small against a check that silently stops working.

Build the check on the most structural signal that answers the question, and prefer a kernel or protocol fact over anything a release note could change.
When a rendered surface is genuinely the only source, read more than one independent signal and let any of them carry a positive verdict, so no single vendor string is load-bearing.
Where a surface signal is unavoidable, back it with a guard that fails loudly naming the harness and version rather than degrading quietly.

Every such check needs two tests, because they fail for different reasons:

- A portable regression in `tests/` that pins the logic with real processes and no harness, so CI enforces the classifier everywhere it runs tmux.
  Drive the signals apart deliberately and assert the verdict survives losing one; assert the divergence itself so the case cannot go quietly vacuous.
  Confirm which signal a given construction actually blinds on each supported platform rather than assuming, because the same trick can break different sources on macOS and Linux.
- A live guard in the `live-harness-optin` family (`bin/fm-test-run.sh`) that exercises every INSTALLED harness for real and fails naming the harness and version.
  Report an absent harness explicitly rather than passing silently over it, and refuse a pass that checked nothing.
  Open it with `fm_live_gate` from `tests/lib.sh`, which is the single owner of that decision: a guard that spends no model tokens runs by default wherever its tools are installed, a guard that submits prompts stays opt-in, and its own variable or `FM_LIVE` forces it on (an absent tool then fails rather than skips) or off.
  The weekly CI run has no credentials and installs the public Pi package, so token-free guards exercise the available Pi surfaces while unavailable tools capability-skip; run a prompt-submitting guard after every harness upgrade and before trusting refreshed per-harness evidence.

Record the dated per-harness result in `docs/verification/runtime-backends.md`, and point at the live guard as the command that refreshes it, rather than leaving a version-scoped observation to rot into a false claim.

## Documentation change review

For every changed maintained prose surface, identify its inventory audience, authoritative owner, current-behavior relevance, destination for supporting evidence, and any unique safety fact that removal could lose.
Move or delete evidence only after the current owner and regression pointer are verified.
After all documentation, review-fix, and lint-fix commits, review the complete branch diff again against those criteria rather than reviewing only the latest commit.
Run `bin/fm-doc-audience-check.sh`; it enforces classification, README setup routing, local link targets, and owner pointers without keyword-linting legitimate evidence prose.

## Shell, tests and handoff

Before writing or changing a test under `tests/` or a script under `bin/`, load `firstmate-shell-tests`; it holds the shell and test traps (condition waits, hermetic fixtures, stock bash 3.2, SIGPIPE, argv limits, lint, assert helpers), while `CONTRIBUTING.md` "Testing" owns the shared helpers and the wait rule.
Before reporting READY or answering review findings, load `builder-self-check`.

## No-mistakes test configuration

Never configure a deterministic suite-walk `commands.test` in any repository's no-mistakes config, whether it selects the full suite, changed tests, a family, or a fixed script list.
Targeted validation belongs to the no-mistakes evidence path, while CI owns broad deterministic regression coverage.
The parsed configuration regression is [`tests/fm-nm-test-contract.test.sh`](../../../tests/fm-nm-test-contract.test.sh).

## Repo style rules

- Put one full sentence per line in tracked Markdown.
- Never wrap multiple sentences onto one physical line.
- Plain dash `-`, never an em dash.
- Never add an agent name as a commit co-author.
- `bin/*.sh` and `bin/backends/*.sh` must pass `shellcheck`.
- Run Firstmate production-library tests and commands that source `bin/` scripts under `bash` explicitly, never through the tool shell's default interpreter.
- Run `bin/fm-lint.sh` before treating a script change as done; it is the single owner of the lint definition that CI and the no-mistakes pre-push gate both invoke, its own header owns what that definition covers, and it refuses to run under any other version of either linter.
- When a task names a specific tool, implement the work with that tool, or explicitly flag the substitution and its new dependency footprint for review before shipping.
- Colocate tests with the existing pattern in `tests/`, name them `<subject>.test.sh`, and extend an existing script rather than inventing a new runner.
- Tests must exercise behavior through an executable or public interface and must never assert implementation-source bytes, including through parsers, regexes, snapshots, or indirect wrappers.
- A maintainer-verification record under `docs/verification/` records active empirical facts, not assumptions or task chronology.
- Include the date, version, exact commands run, and exact output needed to support the current guarantee.
- Keep incident chronology and delivery evidence in private task reports or PR evidence unless a concise rationale is required to maintain a current safety boundary.
