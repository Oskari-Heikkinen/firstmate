---
name: loop-observability
description: Load before changing bin/fm-loop.sh, bin/fm-loop.py, bin/fm-project-capacity-lib.sh, docs/loop-status.md or their tests. The loop view only reads records, says why each request waits, reads unknown as unknown and alerts once per occurrence; it never launches or edits a queue, and capacity admission fails closed.
user-invocable: false
metadata:
  internal: true
  sources:
    - path: docs/loop-status.md
      sha256: 79f350288c74bcd180f5239c371d7ddb5a1b64fd0abb353f893fe4d2b7d853a6
    - path: bin/fm-loop.sh
      sha256: 612c4fc26273562f2a75b7d46ad9148b9d928be11b3bb31ccb9248c61d55b78a
    - path: bin/fm-loop.py
      sha256: 2c8664749dc1e2456691b2461b9d827bae8f781d1fca23b6df129ae516a59eff
    - path: bin/fm-project-capacity-lib.sh
      sha256: 8722b50acaa6c2988b7b31c1e56a12ec23769c3c3675d5afdc487e1480a0ba94
---

# loop-observability

## Goal and operating principle

Anyone can see from records alone where every experiment request stands, why it waits, and when the loop stalls, so idle capacity and silent refusals never go unnoticed.
`fm-loop` is a read-only join over the loop's own records: it never writes, wakes, consumes or acknowledges a source, and its only writes are its alert records, cursors, log and check shim under `<home>/state`.
A missing, unreadable or wrong-schema source reads as unknown, never as empty or healthy, and an unknown condition never clears an alert.
Each alert is one durable record that wakes firstmate once per new occurrence through the watcher check, `source-unreadable` included; TETJET's own capacity alerts (`tj-lane-refused`, `tj-idle`, `tj-capacity-unread`) are shown beside the stages, never raised again.
`fm-project-capacity-lib.sh` is the one owner of per-project worker capacity: a declared number, counted from task records under the shared project lock, and an unreadable declaration refuses spawns instead of guessing.
Sources, thresholds and limits are data (`config/loop-sources`, a stage's `<home>.loop-source` key in the handoff registry, `config/project-capacity`), so a new source or project is a config line, not code.

## Where each rule lives

- `bin/fm-loop.sh` header: usage, the run cap and the watcher check's install.
- `bin/fm-loop.py`: the source list, stage rules, alert conditions and lead-time buckets; `docs/loop-status.md` explains them.
- `docs/configuration.md` "Loop sources" and "Project capacity": the two config file formats and the registry `loop-source` key.
- `bin/fm-project-capacity-lib.sh` header: the declaration format, what holds a place and the admission verdict; `bin/fm-spawn.sh` owns where the check runs.

## Refuse

- Writing, consuming, acknowledging, rotating or repairing any source, or contacting the capacity filler, its service or TETJET (`bin/fm-loop.py` docstring; `docs/loop-status.md` "What it reads" and "Capacity filler watch").
- Launching, retrying, re-queuing or unsticking a request from the loop view (`docs/loop-status.md`: "nothing is woken, consumed or acknowledged"; the plan's one start authority).
- Reading a missing or unreadable source as empty, or letting an alert clear while `source-unreadable` is raised (`docs/loop-status.md` "Alerts").
- Suppressing an alert in the very state it should report, such as an idle alarm muted while a lane is broken (wave-2 history H16: a ~50 h lane refusal went unseen this way; wave-2 queue section 7: queue state read `ok` while blocked).
- Folding supply and lane health into one derived status (`docs/loop-status.md`: shown "as separate fields, never one derived from the other").
- Raising TETJET's own capacity alerts again as loop alerts (`docs/loop-status.md`: tetjet-mate owns them).
- A watcher check that prints every open alert on each run, prints acknowledged alerts, hides `source-unreadable`, or moves its cursor before printing (`docs/loop-status.md` "Watcher check").
- Accepting an unknown schema leniently, or replaying the lane journal to recover a bad cursor (`docs/loop-status.md` "Capacity filler watch").
- A hard-coded source path, threshold, home or request family in code where a `config/loop-sources` line belongs (`docs/configuration.md` "Loop sources"; tool-design rule 4).
- Unbounded reads, tree walks or runs past the cap, a source read outside the per-source bound, or a sync to disk for an alert record that has not changed (`bin/fm-loop.sh` header: niced and capped at 60 s, sources read within a quarter of the cap; `docs/loop-status.md` "Alerts"; wave-2 history H9 unbounded read volume).
- Writing outside `<home>/state` from `arm` or `disarm` (`bin/fm-loop.sh` header).
- Guessing a capacity from a malformed declaration, counting holders outside the shared project lock, or adding a per-project branch to the capacity code (`bin/fm-project-capacity-lib.sh` header).

## Review

Answer each check PASS or FINDING.

1. Does the change write anything other than this home's alert records, cursors, log and check shim under `<home>/state`?
2. Does every missing, unreadable, stale or wrong-schema input read as unknown, raise its documented alert, and keep other alerts from clearing where the docs say so?
3. Is every new wait reason derived from records and shown in `status` with the source it came from?
4. Does each new alert have a durable record, a log line per raise, clear and acknowledgement, print once per occurrence in `alerts --new`, and stay quiet after `ack`?
5. Can any alert be suppressed while the condition it reports is true?
6. Are supply and lane health still separate fields, and are TETJET's own capacity alerts (`tj-lane-refused`, `tj-idle`, `tj-capacity-unread`) shown without being raised again?
7. Are new sources and thresholds config lines with documented defaults, and are stage rules and conditions stated once in `bin/fm-loop.py` and explained once in `docs/loop-status.md`?
8. Does the run stay niced, idle I/O, capped, and bounded in what it reads?
9. Does capacity admission still refuse on an unreadable declaration or holder record, evaluate under the shared project lock, and free a place only through records?
10. Would `tests/fm-loop.test.sh` or `tests/fm-project-capacity.test.sh` fail, through the public commands, if this behaviour broke?
11. Would a new request family, source or project need only a config line, not a code branch?
12. If a source pinned in this skill's `metadata.sources` changed, does every rule here still hold, and are the pins updated in the same change?
