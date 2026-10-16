---
name: tj-capacity-alerts
description: Load when tj-idle, tj-lane-refused or tj-capacity-unread blocks TETJET feeding, or when a tj-auto-capacity signal wakes this home; arm/disarm or inspect the durable liveness alerts without repairing, launching, stopping or clearing a lane.
---

# TETJET outcome alerts and capacity signal watcher

Owner: tj-auto-services `liveness` loop, every 10 min through the existing Nice=19 / idle-IO user timer. This is evidence, never admission or permission to launch, delete, repair, retry or clear a hold.

Use the installed package and settings in `data/tj-auto-services/state/.install-tjsvc`; never assume a version/path from an old note. New packages require independent review and explicit firstmate release, then the operator's drained, whole-package cutover. Never edit a sealed/live package in place.

## Alert meanings

- `blocked [key=tj-lane-refused]`: the filler reports `last_tick.tjpkg.broken` or `disabled` continuously observed for **more than 15 min**. It names the owner's matching refusal reasons from `fill.jsonl` (or explicitly says current-log/details were unreadable or absent); it streams that one log only for a pending notification so old refusals are not lost behind the tail. It posts once, survives checker/process/reboot restarts, and resolves only on a fresh explicit healthy `tjpkg` tick. The historical `refusals` hashes alone never open/reopen a blocker: the filler retains them after recovery. STOP ticks and stale/missing evidence never imply recovery.
- `blocked [key=tj-capacity-unread]`: fresh local filler status cannot be read. A fresh STOP tick explicitly names `filler stopped (STOP file)` even after its probe becomes stale; changing from other unknown evidence to STOP posts that cause once. Unknown is not free/healthy; the checker preserves open lane/idle episodes. Fresh readable evidence resolves this key, not the underlying lane automatically.
- `blocked [key=tj-idle]`: fresh free_slots >=1 and no **observed running-count rise** for >=60 min, using the explicitly approved inbox041 metric: sum of per-package `probe.launchers[].jobs` plus rolling `probe.sample.scopes`. It states the last-rise time (or none observed and the persisted observation baseline), count, sample time, and the filler's own queue-state why; null why with zero queued is named queue dry, STOP and active hold names are preserved. It repeats only when that stable cause changes (signed/decimal/scientific measurements normalised, full why still posted) or after 6 h, and resolves when a fresh probe shows a count rise. Baseline/last count/rise/delivery state survive restart; install needs an hour of observation before the first alarm. The same probe timestamp is never a new sample. This is NOT actual per-run start telemetry: equal-count churn and short runs between observations can be missed, while long continuing runs do not reset the timer. Package submissions, widths, offers and drivers are not starts. Do not overclaim the metric; real start-event telemetry is a later improvement.

Parent destination is the explicit `capacity.parent_notify` in the installed liveness config, not the local loop's HELD destination. Parent notification failure is retried without marking the alert delivered. Source owner files are read-only. Alert state is `state/liveness/capacity-state.json`; never delete/reset it to silence an alert. Notifications precede the atomic checkpoint: crash can repeat a line, never silently acknowledge an unwritten notification.

Look at `tjsvc status liveness`, then `state/liveness/out/`, the filler `state.json` / `fill.jsonl`, and its own STOP/hold/reasons. Fixes belong to their owners and follow normal review/install. Findings that block new TETJET work are escalated to the parent even while their fixes are being built/reviewed; a stalled install names the halted lane too.

## Capacity signal wake bridge

After package PASS + explicit release, FIRST the firstmate repository owner lands
this exact skill as tracked `.agents/skills/tj-capacity-alerts/SKILL.md`, and advances
THIS_HOME through its normal clean update path (including the pin4cdc helper
advance). Arm refuses absent/uncommitted/differing skill bytes and never installs
or overwrites it. This keeps the home clean for future updates and the skill
normally discoverable. Then the operator runs from the retained sealed package:

```sh
python3 -I -B liveness/capacity_watch.py --home /absolute/this/firstmate --dry-run arm
python3 -I -B liveness/capacity_watch.py --home /absolute/this/firstmate arm
```

`arm` verifies the already-committed skill, writes private `state/tj-capacity-alert-watch.check.sh`, and binds it through that home's `bin/fm-check-register.sh`. The custom-check id `tj-capacity-alert-watch` deliberately differs from producer task id `tj-auto-capacity` so producer task teardown cannot silently unregister it. The shim also pins its transitive Python reader bytes. It never starts/rearms a firstmate watcher itself: the already-running watcher consumes its registered custom checks. The first read replays complete existing signal lines (unconsumed backlog); future reads print one line per new complete LF-terminated signal line, then atomically checkpoint device/inode/offset/tail-hash in `state/tj-auto-capacity.cursor.json`. Partial lines wait; rotation or truncate+regrow replays the new file. A crash after output before checkpoint can repeat lines (at-least-once), but it never checkpoints before output. Concurrent cursor readers refuse under flock. Every reader refusal goes to stdout (the watcher discards stderr), so invalid cursor/oversize/unreadable input cannot silently swallow the signal. Do not run the reader manually as a diagnostic because doing so consumes pending wakes.

Re-arm/upgrade retains the cursor; it does not replay caught-up lines. Disarm only through the owner:

```sh
python3 -I -B liveness/capacity_watch.py --home /absolute/this/firstmate disarm
```

This invokes `fm-check-unregister.sh` for `tj-capacity-alert-watch`, retaining the source signal, cursor and tracked skill. No earlier ABC candidate was installed; if an operator finds a prior `tj-auto-capacity` check registration, stop and route its explicit owner-managed migration rather than leaving duplicate readers. Rollback in a drained window re-arms the retained prior reviewed reader if one exists, or disarms this new check. Never erase the signal or cursor, hand-edit trust files, auto-clear STOP/HELD, or change parent endpoints to work around an alert.

A torn/unknown/unreadable capacity alert checkpoint still fails closed as a liveness HOLD (including legacy G6): it is NOT automatically discarded or repaired. Escalate that local HELD evidence; preserve it for owner repair. This known limitation is separate from a broken C reader, which now prints a visible refusal. Parent appends are durable but live parent wake delivery must be confirmed by the parent-home owner; do not read another home's namespace to test it.

Local scratch test only: `python3 -B tests/test_capacity_alerts.py --firstmate-bin /absolute/this/firstmate/bin`. Run package validation through the heavy slot at nice19/idle IO; never use real producer state, parent statuses or TETJET in a test.
