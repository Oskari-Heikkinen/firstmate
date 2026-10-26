---
name: tj-capacity-alerts
description: "Load when tj-idle, tj-lane-refused or tj-capacity-unread blocks TETJET feeding or a tj-auto-capacity signal wakes this home, and before relaying, acting on or silencing one of those alerts: what each means, and why none permits a launch, repair or reset."
user-invocable: false
metadata:
  internal: true
---

# TETJET capacity alerts

Why this skill exists: a capacity alert read as permission, or silenced by resetting its state, hides the stall it reports, and a stage that fails without an alarm goes unseen for hours (root causes R7, R1; problem class P19).

The TETJET capacity service's liveness checker raises these alerts from the capacity filler's own records.
They are evidence, never admission or permission to launch, delete, repair, retry or clear a hold.
The service's install, thresholds, probe fields and arming steps are private operating detail; when this home has a local TETJET operations skill, load it alongside this one for them.

## Alert meanings

- `blocked [key=tj-lane-refused]`: the filler has reported its package lane broken or disabled for longer than the checker's threshold.
  It names the filler's own matching refusal reasons, or says plainly that they were unreadable or absent.
  It posts once, survives checker, process and reboot restarts, and resolves only on a fresh, explicitly healthy lane tick.
  Old refusal records alone never open or reopen it, and a STOP tick or stale or missing evidence never implies recovery.
- `blocked [key=tj-capacity-unread]`: fresh filler status cannot be read.
  A stop through the filler's STOP file is named as such, and a change from other unknown evidence to STOP posts that cause once.
  Unknown is not free or healthy, so open lane and idle episodes stay open.
  Fresh readable evidence resolves this key, not the underlying lane.
- `blocked [key=tj-idle]`: free slots exist and no rise in the observed running count has been seen for longer than the checker's threshold.
  It states the last rise (or that none was observed), the count, the sample time and the filler's own reason its queue waits; an empty queue with no reason is named queue dry, and STOP and active hold names are kept.
  It repeats only when that cause changes or after a long interval, and resolves when a fresh sample shows a rise.
  The count is a sampled metric, not per-run start telemetry: equal-count churn and short runs between samples can be missed, and package submissions or offers are not starts, so do not overclaim it.

## Handling an alert

- Read the service's liveness status and output first, then the filler's own state, refusal log, STOP and hold reasons; source owner files are read-only.
- Never delete or reset the alert state, erase the signal or its cursor, hand-edit trust files, auto-clear STOP or HELD, or change the parent destination to quiet an alert.
  The checker notifies before it checkpoints, so a crash can repeat a line but never silently acknowledge one.
- A torn, unknown or unreadable alert checkpoint fails closed as a liveness HOLD; escalate that evidence and preserve it for the owner's repair rather than discarding it.
- Fixes belong to their owners and follow normal review and install.
  Findings that block new TETJET work go to the parent even while their fixes are being built or reviewed, and a stalled install names the halted lane too.
- The capacity signal reaches this home through a registered custom check whose reader consumes pending wakes, so never run that reader by hand as a diagnostic.
  Arming, disarming, upgrading and rolling it back go only through the service owner's own tool.
- Whether the parent home received a wake is for that home's owner to confirm; do not read another home's namespace to test it.
- Tests use scratch state only: never real producer state, parent statuses or TETJET.
