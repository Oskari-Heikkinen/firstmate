---
name: quiet-waits
description: >-
  Agent-only reference for the automation that keeps declared waits, superseded
  blockers, and config pushes out of the supervisor's chat.
  Use before briefing or steering a worker onto a machine-checkable wait, on a
  wake saying a declared wait condition no longer holds or that its endpoint has
  no agent, when an OPEN DECISIONS or UNREAD STATUS line shows a
  `note [supersedes=...]` or `note [receipt=config-reread]` record, and before
  closing a blocker or acknowledging a config push by hand.
  Owns when each automation runs, how agents declare and wait on it, which
  records and receipts it emits, and which hand steps it retires.
user-invocable: false
metadata:
  internal: true
---

# quiet-waits

Load this before briefing or steering a worker onto a machine-checkable wait, on a wake that says a declared wait condition no longer holds or that its endpoint has no agent, when a drain shows a `note [supersedes=...]` or `note [receipt=config-reread]` line, and before closing a blocker or acknowledging a config push by hand.

Three automations share one purpose: a wake whose answer a script can already prove never reaches the supervisor's chat.
Each is deterministic, leaves a durable record, and never suppresses a needs-decision, blocked, failed, done, or check wake.

## Declared waits the watcher acknowledges itself

A worker declares a wait by appending a `paused:` line with one `[wait=<kind>:<arg>]` tag before the colon.
The kinds, what makes each hold, and the rule that a missing checker or unreadable source counts as not holding are owned by `status_declared_wait_check` in [`bin/fm-classify-lib.sh`](../../../bin/fm-classify-lib.sh): `heavy:<job-id>`, `until:<UTC>`, `merge-result:<head-sha>`, and `receipt:<absolute-path>`.
A pause without a tag keeps the ordinary four-hour recheck bound, even with a future prose `until <UTC>` clause; with a tag, the tag alone governs and a passed prose ETA is ignored.
The heavy-slot tool writes its own `paused [key=heavy-<id>] [wait=heavy:<id>] ...` line when it queues a job and a keyed `resolved` line when it ends, so a worker using that tool writes nothing extra.

When it runs: in normal supervision, [`bin/fm-watch.sh`](../../../bin/fm-watch.sh) checks the task's newest status line whenever a bare turn-end or a stale pane would otherwise wake the supervisor.
While the condition holds and the endpoint still has an agent, it acknowledges that wake itself and records one row in `state/.quiet-wait-acks`; a stale pane is recorded once per declaration.
While away or quiet mode's daemon owns triage, the daemon keeps its own declared-wait handling and this path does not run.

What still wakes the supervisor:

- Any new status line, whatever its verb.
- A tagged condition that stops holding, which is an immediate recheck naming the condition.
- A holding condition whose endpoint has no running agent or whose liveness cannot be verified, which is an immediate recheck naming that liveness.
- A changed or unreadable lane fingerprint, including moved HEAD, red PR checks, or unread steers, even before the periodic recheck is due.
- A standing wait unseen for the standing-waits ceiling, and every heartbeat.

How agents use it:

- Firstmate briefs or steers a worker to tag its pause whenever a script can check the wait, rather than asking it to report progress.
- On a lapsed-condition wake, read the task's current state with `bin/fm-crew-state.sh <id>` and steer or recover the worker; the wait has ended, not the task.
- On a no-agent wake, follow `stuck-crewmate-recovery`; the declared wait does not make the dead endpoint healthy.
- `state/.quiet-wait-acks` is an audit trail for "why was I not woken", never an input to any decision.

Hand steps retired: acknowledging a no-op turn-end or stale wake for a lane whose tagged wait still holds, and re-checking a heavy job, merge-queue result, or receipt by hand while it is pending.

## Superseded blockers close themselves

A typed `note [supersedes=<kind>] [at=<epoch>]: <evidence>` line closes every blocker open before it, keyed or unkeyed, in the shared decision fold, and the drain shows that note as the closing evidence.
It never closes a needs-decision.
The kinds are `relaunch`, `resume`, and `validation-run`; `status_supersedes_kind` in `bin/fm-classify-lib.sh` owns them, and `fm_status_supersede_blockers` in [`bin/fm-wake-lib.sh`](../../../bin/fm-wake-lib.sh) owns the writer, which appends only when a blocker is actually open.

When it runs:

- `bin/fm-control.sh <id> relaunch` writes the `relaunch` note after a verified relaunch.
- `bin/fm-send.sh` writes the `validation-run` note after a confirmed steer that starts a new `/no-mistakes` run on a worker.
- A worker resuming from a reboot note writes the `resume` note itself, as its brief tells it.

Hand steps retired: appending `resolved` lines for blockers a relaunch, reboot resume, or new validation run already superseded.
A blocker raised after the note stays open, and a needs-decision still needs its real answer through `ask-user-authority`.

## Config pushes need no chat turn

When inherited config changes under a running local second mate, `fm_config_reread_send_pointer` in [`bin/fm-config-inherit-lib.sh`](../../../bin/fm-config-inherit-lib.sh) owns the queued generation, durable wake, and fire-and-forget doorbell before its parent-side receipt.
The parent's status file for that second mate then gets a typed `note [receipt=config-reread] [at=<epoch>]: ...` receipt through the self-announced append, so it rides along with the parent's next status presentation without waking the parent or requiring a chat acknowledgement.
The second mate's next wake drain prints a `CONFIG REREAD` section naming each queued instruction file once; it reads and applies those files at that intake.
`secondmate-provisioning` owns the generation, retry, and quarantine contract.

Hand steps retired: acknowledging a config push in the second mate's chat, and checking the second mate's pane to confirm the push was delivered; the receipt is that confirmation.
A remote second mate still receives its marked re-read instruction through its own route.
