---
name: task-evidence
description: >-
  Agent-only guide to keeping task evidence that lives inside a disposable task copy or its /tmp/fm-<id> temp folder.
  Load before writing a report, note, or other record under data/<id>/ that cites a file inside a task copy or its temp folder, and on any cleanup refusal that names declared evidence, evidence.list, or a record referencing a path cleanup would destroy.
user-invocable: false
metadata:
  internal: true
---

# Task evidence

Cleanup returns a task's copy to the pool (hard reset, untracked files removed) and deletes its own `/tmp/fm-<id>` temp folder.
Scratch evidence cited from either place would be lost, so cleanup preserves declared evidence itself and refuses while a record still points at undeclared files there.
Clean tracked source citations are recoverable from git and do not need declarations; `bin/fm-task-evidence-lib.sh` owns that exemption and citation-suffix handling.
`bin/fm-task-evidence-lib.sh`'s header owns the exact declaration format, copy layout, verification, and refusal rules; this skill covers only how agents use it.

## When it runs

`bin/fm-teardown.sh` runs it for every ship and scout cleanup, after the landed-work checks pass and before anything is returned, closed, or removed.
It is not a separate step anyone invokes, polls, or waits on.

## What a worker does

- When a record you leave under `data/<id>/` (report, notes, findings) cites a file or directory inside your copy or your temp folder, add that path to `data/<id>/evidence.list`, one per line, relative to the copy root or absolute.
- Keep evidence in the copy as ignored or untracked scratch that git does not flag as uncommitted work, such as an ignored `workspace/` folder; the landed-work refusal still treats tracked edits and non-ignored untracked files as unlanded work.
- Cite the evidence by its original path if that is clearer; a declared path, or any path under a declared directory, counts as covered.

## Hand steps agents no longer do

- Do not hand-copy review, merge, or run evidence out of a copy before cleanup, and do not hand-write checksums for it.
- Do not hand-delete `/tmp/fm-<id>` after cleanup; cleanup removes exactly that folder when the task record names it, and leaves any other recorded temp path in place with a warning.

## Signals and receipts

- The preserved copy lands at `data/<id>/evidence/copy/...` and `data/<id>/evidence/tmp/...`, with `data/<id>/evidence/MANIFEST.sha256`; re-verify later with `cd data/<id>/evidence && sha256sum -c MANIFEST.sha256`.
- Cite `data/<id>/evidence/...` in any later record that must outlive the task.
- A `REFUSED:` line from cleanup names each undeclared reference or bad declaration; nothing was changed.

## On a refusal

Read each named path.
If it is real evidence, declare it in `data/<id>/evidence.list` and re-run cleanup; if the reference is incidental, remove or rewrite it in the record.
`--force` does not lift this refusal, and a captain's discard authority for unlanded work is not permission to orphan a report's evidence.
A declared path whose source is already gone is accepted only when an earlier copy under `data/<id>/evidence/` still verifies against its manifest.
