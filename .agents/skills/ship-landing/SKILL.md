---
name: ship-landing
description: Load when a ship reports done with a PR or ready branch, before bin/fm-pr-check.sh or bin/fm-pr-merge.sh or any other landing, when deciding whether a reviewed or green head can still land after the default branch moved, when a PR's checks go red or a merge poll fires, when a direct-push task lands or switches to a PR, before writing a ship brief's landing instructions, and before teardown of a ship task.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

Why this skill exists: heads were landed on a base that had moved, merged on a green or CLEAN reading that never covered current main, and torn down after a merge that had not happened, while each brief restated its own landing mode and drifted (root causes R2 and R1, problems P21 and P16).

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
A `direct-push` task has no PR: it reports `done [at=<epoch>]: ready in branch <ship-branch> ...` when stopping at ready and `done [at=<epoch>]: landed <sha> on <default-branch>` once pushed and the default branch's checks on it are green, `bin/fm-crew-state.sh` says whether that head is on origin's default branch, and no merge poll is armed.
When a direct-push task switches to a PR mid-flight, record the switch with `bin/fm-promote.sh <id> --switch-mode <no-mistakes|direct-PR>` before registering the PR; it also supersedes the delivery contract in the task's brief for any relaunch, and the live worker receives that new contract section through `bin/fm-send.sh`; until then PR registration and merge refuse it, and cleanup refuses while a PR on its branch is open.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, a direct-push worker pushes it to its task branch or lands it, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
Landing authority is owned by `AGENTS.md`: hard rule 2 in section 1, and the `yolo` and red-check rules in section 7; review PASS alone creates no authority.
A ship brief points at this skill and at the task's recorded delivery mode, and never restates the landing mode in its own words, because a restated copy drifts from the record the tools read.
A custom check written to watch a landing follows the `handoff-coverage` skill's custom-check rules.

## Before any merge or landing

These checks exist because a passing forge reading answers a narrower question than "is this safe to land".

- `mergeable`/`CLEAN` means only that git found no textual conflict, and green checks prove only the head they ran on; neither proves the head was tested with today's default branch.
  Before merging, fetch and confirm the head contains the current default branch with `git merge-base --is-ancestor origin/<default> <head>`.
  A head that does not is integrated on current main by its worker and re-runs main's required set on the integrated head before it is handed back; never land the earlier reviewed head over a moved main.
- Integration is the worker's step, and it checks for leftover conflict markers before any commit (`git diff --check` and `git diff --cached --check` name them).
  Registries and generated files are regenerated from the integrated sources at integration time, never hand-merged, because a hand-merged copy can match neither side.
- Name the repository on every `gh` call, with `-R <owner>/<repo>` or the full PR URL: in a copy with an `upstream` remote a bare PR number resolves upstream and acts on the wrong pull request.
- Never chain `bin/fm-teardown.sh` after `bin/fm-pr-merge.sh` in one command.
  Teardown counts a pushed branch as landed, so a refused or queued merge followed by teardown removes the task while its PR is still open.
  Tear down only after the merge prints `verified: <url> is merged`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.
When `config/project-capacity` caps the project, re-evaluate its queued work after a recorded PR-ready handoff too.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
