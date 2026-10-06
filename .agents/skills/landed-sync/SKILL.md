---
name: landed-sync
description: >-
  Agent-only procedure for the automatic refresh of the main home's project
  clone after every landing on a project's default branch. Use on any
  `check: landed-sync <project>` wake. Owns what triggers the refresh, what it
  reports, and what an agent may and may not do about a stuck clone or a stale
  git lock.
user-invocable: false
metadata:
  internal: true
---

# landed-sync

Load this on any `check: landed-sync <project>` wake.

`bin/fm-landed-sync.sh` is the automation, and its header and `--help` own the exact behavior, the report kinds, and the lock-age threshold.
It refreshes the main home's clone of a project only through `bin/fm-fleet-sync.sh`, so the clone is fast-forwarded and never forced, stashed, or discarded.

## When it runs

No agent runs it by hand after a landing; every landing path calls it:

- A recorded PR merge, whether this home merged it or its merge poll saw it, starts it in the background.
- Task cleanup runs it after refreshing this home's own clone, which covers direct-push and merge-queue landings too.
- A clean merge-queue landing runs it before cleanup, so the main clone is current even if cleanup refuses.

A secondmate's landing refreshes the main home's clone as well as its own, and reports only into the main home.

## Handling a wake

The wake names one problem with the main home's clone; it is reported once and not repeated until a later refresh succeeds.

- `not refreshed: on ...` (a dirty, diverged, or off-default clone): the clone may hold real work.
  Tell the captain which clone is behind and why, and change nothing in it without the captain's concrete word under hard rule 1.
- `stale git lock ... left in place`: a git lock file no process holds, older than the threshold, is blocking the clone, typically left by a crash or reboot.
  Tell the captain its path and age.
  Never remove it yourself; removing it is a project operation that needs the captain's concrete word under hard rule 1.
- `not refreshed: fetch failed` or `fast-forward failed`: read the quoted git error; a transient network failure clears at the next landing, and anything else goes to the captain as a blocker.

Once the cause is gone, `bin/fm-landed-sync.sh <project>` refreshes the clone and clears the report; nothing else needs acknowledging beyond the wake itself.
