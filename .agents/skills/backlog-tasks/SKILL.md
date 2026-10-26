---
name: backlog-tasks
description: Load before any bin/fm-tasks-axi.sh call that adds, shows, lists, updates, moves, blocks or closes a backlog task, before replacing or bulk-editing task notes, and when a backlog read comes back empty or in an unexpected shape or a backlog call is refused. Holds the verbs, what show really prints, and why replacing a note always archives the old body. Spawning or starting a queued task is bin/fm-spawn.sh's job, not a backlog edit.
user-invocable: false
metadata:
  internal: true
---

# backlog-tasks

Why this skill exists: it prevents task notes being overwritten with nothing (R15), which happened when a scripted bulk update read the old bodies through a flag that does not exist, got empty strings, and replaced fourteen notes beyond recovery.
The tool allowed it silently, so the safeguard has to be in how the call is made.

## Always through the home wrapper

Reach the backlog only through [`bin/fm-tasks-axi.sh`](../../../bin/fm-tasks-axi.sh), never a bare `tasks-axi`.
A bare call resolves the backlog paths against its working directory, so from the wrong directory it silently forks the queue.
The wrapper's `--help` owns addressing, file-argument rewriting and its refusals, and `fm-tasks-axi.sh <command> --help` prints the command's own flags.
When a call is refused or a flag is unknown, read that help rather than guessing a spelling.

## The verbs

| Intent | Verb | Note |
|---|---|---|
| Queue new work | `add` | `add --start` is refused: only `bin/fm-spawn.sh` starts a row, because it also creates the task record, status file and inbox |
| Read one task | `show <id> --full` | Prints text; there is no `--json` on a read |
| Read many | `list`, `ready` | Filters are in `list --help` |
| Change fields or the note | `update <id>` | `--body` or `--body-file` replaces the whole note |
| Finish | `done <id>` | Pass `--pr <url>` when a PR landed it |
| Dependencies | `block <id> --by <other>`, `unblock` | |
| Rename or move | `mv` | |

A task waiting on the operator is never held with a bare `hold`: `bin/fm-captain-hold.sh hold` owns that, and `captain-hold-lifecycle` owns when to use it.
Work routed to a secondmate lives in that home's backlog; `secondmate-provisioning` owns handing backlog between homes.

## Replacing a note

`update --body` and `--body-file` replace the entire note, so a replace built from a failed read writes an empty or partial note over real history.

1. Read the current note with `show <id> --full` and check the read is nonempty and is the task you meant.
2. Build the new note from what you read, keeping anything still true.
3. Replace it with `--archive-body`, every time, so the previous body survives even if steps 1 and 2 went wrong.
4. Run `show <id> --full` again and check the result.

For a bulk change, do one task first and check it, then loop.
Abort the whole loop on the first empty or failed read; never carry on with an empty old body.
`AGENTS.md` section 10 owns the read-first and `--archive-body` rule; this section is the why and the order.

## When a read looks wrong

An empty result, a missing field or output in a shape you did not expect means the call or its flags were wrong, not that the task is empty.
Stop before any write that depends on it, check the exact command against its `--help`, and re-run the read.
