---
name: merge-queue
description: Only for a project that lands through an external merge queue or merge train - load before briefing, spawning, dispatching, relaunching or handing a head off for one of its tasks, before withdrawing or replacing a car in that train, and on any `procevent merge-queue` wake. Not for a PR, red checks or landing in a project without a queue (ship-landing), cleanup after a landing, or building merge-queue tooling (tool-design).
user-invocable: false
metadata:
  internal: true
---

# merge-queue

Load this before briefing or dispatching a task whose project lands through an external merge queue, before handing a head to that queue, and whenever a `check:` wake carries `procevent merge-queue <source-id> <sequence>`.

Why this skill exists: workers pushed around the train, because the tool let them and their briefs restated a landing mode that later drifted (root causes R2 and R1, problems P21 and P16).

`bin/fm-procevent-merge-queue.sh` is the owner-side glue, and its header and `--help` own the exact commands, the outcome classes, and what settling each one does.
It is a built-in process-event adapter, so the `process-event-sources` skill still owns the runner, the durable result, and the `handled` acknowledgement.
[`docs/configuration.md`](../../../docs/configuration.md#merge-queue-configmerge-queue) owns the per-home `config/merge-queue` schema; a home with no configured queue refuses every handoff.

## Briefing a queue-landed task

The worker never lands and never waits.
Spawn every queue-landed ship with `--yolo off`.
On a direct-push task, `--yolo on` writes a `# Current landing authority` section into the launch brief that supersedes the spec and pre-authorizes the worker's own landing, so a relaunched worker obeys it and pushes to the default branch around the queue.
A steer sent after spawn does not survive a relaunch, while the launch brief does, so fix the brief rather than steering: for a ship already spawned with `--yolo on`, rewrite that section's pre-authorized line in its stored launch brief to the stop-at-ready form before any relaunch.
Point the brief at this skill rather than restating the landing mode in prose; a restated copy is what drifts.
Put the exact handoff command in the brief's `## Firstmate spec`, with this home's own paths, so the worker runs it once its head is pushed to its task branch and its gate is green:

```sh
FM_HOME='<this home>' '<code root>/bin/fm-procevent-merge-queue.sh' handoff <task-id> <branch> <head40> \
  --resume-note '<what a relaunched worker must know>' -- <short note>
```

That one command runs the queue's own `handoff.sh` under this home's configured name, arms one watch for that head, stores the resume note, and parks the worker through `bin/fm-park.sh`'s queue-adoption option.
Park records the current worker incarnation and the `merge-result` declared wait, adopts that queue source without a second resume watch, and stops the worker.
The brief must tell the worker to do nothing after it succeeds, and to report `blocked:` with the command's error if it fails.
The resume note is what a relaunched worker reads after a `culprit`, `conflict` or `precheck-unavailable`, so it should carry anything the conversation alone knows, such as how the gate is run.

## What happens without an agent turn

The watch polls the queue's `result.sh`, or `queue.log` when the train has no read helper, and stays silent while the head is pending or only `taken`.
For the exact adopted queue park only, the runner retires its durably captured terminal source before applying the result, preserving the evidence and pending acknowledgement so cleanup cannot stop its own runner.
Cancellation outside that handler still uses ordinary guarded retirement.
It wakes nothing for the outcomes the glue settles itself:

- A clean landing (every file identical, none differing or dropped) records the per-file counts and evidence path in the task note before cleanup, preserving its existing body, and runs guarded cleanup, whose own `landed-sync` refreshes the clones.
  The task's `done: landed <main> on <branch> through the merge queue (...)` line is appended before guarded cleanup, so cleanup reads it and closes the backlog itself.
  After cleanup the glue publishes only its parent-channel landed line and never recreates the retired task status log.
  A cleanup refusal appends a blocker to the still-existing task status naming the landed head, main commit and refusal, and then refreshes the clones through `landed-sync` itself, because the refused cleanup never reached its refresh.
- A `culprit` or `conflict` relaunches the worker in its existing copy with the RESULT line and its resume note; the relaunched worker fixes the problem, pushes a new head, and hands it over again.
- A `precheck-unavailable` (the train could not complete the head's precheck, for example its run budget ran out) is final and landed nothing, but it is no code verdict: it relaunches the worker the same way, with a note saying execution was unavailable, that the queue never retries that head, and to diagnose and hand over a new head.
- A `dropped` head fails the task with the queue's reason; only the train's exact `superseded by <sha>` note is silent.
- An unexpected RESULT outcome ends the declared wait and reports one parent-channel blocker naming the raw outcome; it cleans and relaunches nothing.
- In a secondmate home, a landing with any differing or dropped file posts one `needs-decision` on the parent channel naming the files and cleans nothing, and a queue `STALL` posts one `note` on the parent channel; the watch keeps going after a stall.

## Handling a wake

A `procevent merge-queue` wake means the glue left that result for this home's firstmate.
Read the result and ask `bin/fm-procevent-merge-queue.sh classify <result-file>` what it is:

- `landed-clean` whose cleanup refused: the task status and parent channel already carry `blocked [key=merge-queue-cleanup]` naming the landed head, main commit and refusal; no successful cleanup was published.
  Treat it as any other cleanup refusal and never bypass it.
  A refused note update similarly records a blocker and attempts no cleanup.
- `landed-unproven` in a main home: the change is on main but not every file is proven identical there.
  Relay the files and evidence path to the captain as a decision and clean nothing until answered.
- `stall` in a main home: tell the captain the queue is stalled and since when.
- `culprit`, `conflict` or `precheck-unavailable` whose relaunch was refused: recover the worker with `stuck-crewmate-recovery`, then relaunch it with the RESULT line.
- `unexpected` in a main home: report the raw queue outcome to the captain; relaunch and clean nothing.
- `error`: the queue could not be read; fix the configuration or location, then re-arm with `bin/fm-procevent-merge-queue.sh arm <task-id> <head40>`.

Then acknowledge it with `bin/fm-procevent.sh handled <source-id> <sequence>`.

## Hand steps agents no longer do

- Never keep a worker alive, or poll, grep, or tail `queue.log` in a turn, to wait for a result.
- Never arm a separate park resume watch or resume a queue park by hand; the adopted queue source owns the result action.
- Never run cleanup, refresh the clone, or relaunch a worker by hand for an outcome the glue settles; a result it left unhandled is the only one that needs you.
- Never write the landed, failed, decision, or stall line to the parent channel yourself; the glue and the existing ledger delivery publish them.
- Never edit `queue.log` or anything else in the queue directory; the train owns it, and handoff goes only through the command above.
- Never withdraw or replace a car by pushing its head, or a fix, straight to the default branch: the train still holds the car and lands or rejects it against a main that moved under it.
  Withdraw it through the train's own interface or its owner, and hand a replacement head over through the command above.
