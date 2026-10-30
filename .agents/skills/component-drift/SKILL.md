---
name: component-drift
description: Load when a component-skill drift item (drift-<skill>-...) or a component-drift-failed alarm arrives, and before re-pinning a component skill's sources or installing the drift timer.
user-invocable: false
metadata:
  internal: true
---

# component-drift

The captain's standing rule is that deterministic, repeatable work runs as scheduled, guarded software, never as an agent remembering to run a command.
`bin/fm-component-drift.sh` is that software for component-skill pins: it runs `bin/fm-component-map.sh drift` over every local home and keeps one item per drifted skill in the skill's owner home.
Its header and `--help` own the steps, the owner rule, the state, the alarms and the exit codes; `docs/component-map.md` "Drift run" owns how it is installed.

## When it runs

- Daily, from the user timer main firstmate's machine installs once the run is approved; nothing runs it as an agent task or a scheduled-run brief.
- On demand, `bin/fm-component-drift.sh run` from main firstmate's checkout gives the same result; a rerun never files an item twice.

## What it emits

- A Queued backlog item named `drift-<skill>-<hash>-<time>` in the owner home, plus a wake in that home's inbox; its body names the drifted sources, the components, why it was routed there and the update path.
- While that item is open, a changed drift rewrites the same item (the earlier body is archived) and wakes the home again; it never opens a second item for the skill.
- A `component-drift-failed-...` note in main firstmate's inbox when a run fails or is refused because another run holds the lock; it names the log, whose `FAILED` lines say what to fix.
- No note for a stop on request (`systemctl --user stop`, or the service's start limit on a hung run): the log says "stopped on request", and the next run resolves an add the stop cut short and retries its wakes.
- An item whose home has been retired from main's `data/secondmates.md` counts as gone, so the skill's next item goes to the owner its rule names now.

## Acting on a drift item

- Follow the update path in the item's body: read each source's change, bring the skill's goal, refuse and review sections in line, pin the new sha256, and land the skill through its repository's normal path with a non-author review.
- A source change that contradicts the skill is a finding against the source's owner, raised with that owner, not a silent skill edit.
- Close the item only once the new pins have landed; closing it without re-pinning makes the next run file a new item.
- An item routed to main because no local home owns the skill is main's to route to the right owner, or to fix the skill's `metadata.owner`.

## What agents no longer do by hand

- Do not hash pinned sources, run `drift` across homes, or file, rewrite or close drift items to keep them current; the run does that.
- Do not edit `state/component-drift/` by hand; on a broken ledger, the run refuses and names it, and moving it aside starts fresh.
