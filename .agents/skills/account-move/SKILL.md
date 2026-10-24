---
name: account-move
description: Load before moving a machine login with ai-account or fm-account move, on account-move-events status wakes, or when account-move-incomplete or the account-move alert store is reported.
user-invocable: false
metadata:
  internal: true
---

# Account move outcomes

`bin/fm-account.sh --help` owns move scope, refusals, records and automatic delivery; [configuration](../../../docs/configuration.md#subscription-accounts-configaccounts) owns operator setup.
The [alert-store skill](../alert-store/SKILL.md) owns store-held alarm handling.

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
