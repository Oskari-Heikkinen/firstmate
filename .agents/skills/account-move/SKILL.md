---
name: account-move
description: Load before choosing which account should take work, before moving or restarting sessions or workers because an account looks low, before moving a machine login with ai-account or fm-account move, on account-move-events status wakes, or when account-move-incomplete or the account-move alert store is reported.
user-invocable: false
metadata:
  internal: true
---

# Account move outcomes

`bin/fm-account.sh --help` owns move scope, refusals, records and automatic delivery; [configuration](../../../docs/configuration.md#subscription-accounts-configaccounts) owns operator setup.
The [alert-store skill](../alert-store/SKILL.md) owns store-held alarm handling.

Why this skill exists: moves were judged by one percent-left threshold, so sessions were moved off a window about to reset, and relaunched workers silently kept their old login (root cause R9, problem P20).

## Whether and where to move

- Decide from the outlook `bin/fm-account.sh status` prints, never from percent left alone; the `bin/fm-account-lib.sh` header owns how each window is projected.
- An account below the floor whose windows all reset before the work would use them up (`low, resets first`) is no reason to move or restart anything: the room comes back on its own, and a move costs a restart.
- Weigh the weekly allowance above the 5-hour window, because a weekly shortfall does not come back within the working day.
- Move work when an account is projected to run out before its window resets (the burn rate so far against the time left to the reset), and choose a target the same way.

## Outcomes

- Use the recorded move operation, not separate login changes, pin edits or hand-written launch records.
- On an outcome wake, read every unread event in the invoking home's `state/account-move-events.status`, including individual report failures before the summary.
  The event's reason names what happened and its next action identifies the recovery.
- A partial move retains completed work.
  Retry the same requested login after the named cause clears or the worker reaches a safe boundary; do not interrupt busy work or roll completed moves back.
- A done outcome still leaves the invoking session's manual restart outstanding.
  Never claim running sessions changed merely because their records name the requested account.
- An incomplete pending alarm with no final outcome means the command was interrupted or its delivery failed.
  Inspect the status events and five-field move history before retrying; do not clear the store or resolve its blocker by hand.
- A history or event-write failure must not be hidden by retrying with logging disabled.
  Restore the named path's availability first; the registered store keeps failed event delivery retriable through the existing tick.
- A missing helper or unavailable registration/storage is a refused operation, not a successful move.
  Preserve the command's stderr evidence and repair its installation or storage before retrying.
