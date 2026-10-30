---
name: landed-sync
description: "Load on a `check: landed-sync <project>` wake, when the main home's project clone is behind, dirty, diverged or off its default branch after a landing, or when a stale git lock blocks a clone refresh."
user-invocable: false
metadata:
  internal: true
---

# landed-sync

Why this skill exists: work started from a main clone left behind after a landing, and hand repairs of a dirty clone or a stale lock can destroy work the clone still holds (root causes R2, R1; problem classes P21, P15).

Load this on any `check: landed-sync <project>` wake.

`bin/fm-landed-sync.sh` is the automation, and its header and `--help` own the exact behavior, the report kinds, and the lock-age threshold.
It refreshes the main home's clone of a project only through `bin/fm-fleet-sync.sh`, so the clone is fast-forwarded and never forced, stashed, or discarded.

## When it runs

No agent runs it by hand after a landing; every landing path calls it:

- A recorded PR merge, whether this home merged it or its merge poll saw it, starts it in the background.
- Task cleanup runs it last, after releasing its project and control locks, so a slow remote never holds up a spawn, park pickup or slot return in that project; this covers direct-push and merge-queue landings too.
- A merge-queue landing whose cleanup refuses runs it after reporting the refusal, so the main clone is current even then.

A secondmate's landing refreshes the main home's clone as well as its own, and reports only into the main home.

## Handling a wake

The wake names one problem with the main home's clone; it is reported once and not repeated until a later refresh succeeds.

- `not refreshed: on ...` (a dirty, diverged, or off-default clone): the clone may hold real work.
  Tell the captain which clone is behind and why, and change nothing in it without the captain's concrete word under hard rule 1.
- `stale git lock ... left in place`: a git lock file no process holds, older than the threshold, is blocking the clone, typically left by a crash or reboot.
  Tell the captain its path and age.
  Never remove it yourself; removing it is a project operation that needs the captain's concrete word under hard rule 1.
- `not refreshed: fetch failed` or `fast-forward failed`: read the quoted git error; a transient network failure clears at the next landing, and anything else goes to the captain as a blocker.
  `fetch failed: timed out after <n>s`, `refresh timed out after <n>s` and `refresh lock wait timed out after <n>s` mean the remote or another refresh of the same clone did not finish within its bound; treat a single one as a transient network failure, and a repeated one as a blocker naming the remote.

Once the cause is gone, `bin/fm-landed-sync.sh <project>` refreshes the clone and clears the report; nothing else needs acknowledging beyond the wake itself.
