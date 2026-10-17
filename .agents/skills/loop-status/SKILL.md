---
name: loop-status
description: Load before answering where a TETJET experiment request stands or why it waits, when a loop stall alert from bin/fm-loop.sh reaches you, and before acknowledging one.
user-invocable: false
metadata:
  internal: true
---

# loop-status

Load this before answering where an experiment request stands or why it waits, when a loop stall alert reaches you, and before acknowledging one.

`bin/fm-loop.sh` is the tool: its header and `--help` own the commands.
[`docs/loop-status.md`](../../../docs/loop-status.md) owns the stages, the alert conditions and the lead-time report.
The "Loop sources" section of [`docs/configuration.md`](../../../docs/configuration.md#loop-sources-configloop-sources) owns the config file.
This skill owns only how agents use it.

## What agents no longer do by hand

- Join submit receipts, hand-off records, operator pickups, collected records, batch registrations, analyses, the snapshot, backlogs and park files to find one request's stage: `bin/fm-loop.sh status` does it for every open request.
- Work out how long a request has waited, or since when: the AGE column and `--json`'s `age_seconds` give it.
- Count lead times from the hand-off queue: `bin/fm-loop.sh leadtime` prints them per family and per week.

## Using it

- Run it in the home whose `config/loop-sources` names the sources; it reads every source and writes only that home's own `state/loop-alerts/`.
- A source that reads as missing or unreadable means its columns are unknown, not empty or healthy; name the source when reporting, and do not guess the stage from other files.
- TETJET's capacity alerts (`tj-lane-refused`, `tj-idle`, `tj-capacity-unread`) show beside the stages but belong to tetjet-mate; act on them through the `tj-capacity-alerts` skill, never through `ack` here.
- Lane truth stays with tetjet-mate: the snapshot columns are what its snapshot says, not a second opinion.

## Alerts

- Each alert line names the condition and its subject; act on the cause first, then acknowledge with `bin/fm-loop.sh ack <alert-id>`.
- Acknowledge only an alert you have handed to its owner or resolved; an ack silences that record until the condition clears and recurs.
- A `check: .../state/loop-alerts.check.sh` wake carries one line per newly opened alert from `bin/fm-loop.sh alerts --new`; it never repeats an alert already reported, so act on each line when it arrives rather than waiting for a reminder.
- Install or remove that check only with `bin/fm-loop.sh arm` or `disarm` (steps in the "Watcher check" section of the doc); never write or delete `state/loop-alerts.check.sh` or `state/loop-alerts/reported.cursor` by hand, and never run `alerts --new` as a diagnostic, because it consumes what the check would report: use `alerts` or `status`.
- Never edit or delete a record under `state/loop-alerts/` by hand; its `log` file explains every raise, clear and ack.
