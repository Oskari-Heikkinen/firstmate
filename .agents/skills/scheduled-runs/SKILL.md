---
name: scheduled-runs
description: Load before adding, changing, pausing, resuming, or reviewing a scheduled run, when a scheduled-run task (sched-<name>-<slot>) or its inbox note arrives in a home, before writing its run summary, and on a scheduled-run notification or paused-after-failures blocked line.
user-invocable: false
metadata:
  internal: true
---

# scheduled-runs

Load this before adding, changing, pausing, resuming, or reviewing a schedule, when a scheduled-run task arrives in a home, before writing that run's summary file, and when a scheduled-run notification or a paused-after-failures blocked line reaches you.

`bin/fm-schedule.sh` is the automation: its header and `--help` own the commands, the timer, and the scan steps.
The "Scheduled runs" section of [`docs/configuration.md`](../../../docs/configuration.md#scheduled-runs) owns the schedule file, the run record, the filed task, the scheduler's own outcomes, and the run-summary format.
This skill owns only how agents use them.

## What agents no longer do by hand

- Remember a recurring job, or keep it alive with a date hold, a condition wait, a cron entry, or an ad hoc script timer: a schedule file replaces all of them.
- File the recurring task in the backlog, wake the home for it, or work out when it is next due: the scan does that, once per slot, idempotently.
- Re-file a skipped slot, burst-run missed slots after downtime, or count failures: the scan skips while the previous task is open, catches up once, and pauses after two failed runs in a row.
- Chase a run's outcome or write the result notification: the scan reads the run summary after the task closes and sends exactly one line to the main firstmate.
- Edit a run record under `state/schedules/` to reset or un-pause a schedule: use `bin/fm-schedule.sh resume <home-area> <name>`.

## Approval and authority

A schedule exists only on the captain's approval of that schedule: what it files, in which home, and on what calendar.
Record who approved it and when in the file's `approval` key; never add, widen, or re-time a schedule from your own judgment or another home's request.
Pausing, resuming after a fix, or removing a schedule is likewise the captain's decision, relayed through the main firstmate.
The main home installs the one timer (`bin/fm-schedule.sh install-timer`) once; a second mate never installs or removes it.

A scheduled run is captain-routed work, not self-started work.
A home that receives one dispatches it like any other approved task in its backlog, within that home's charter.

## Adding or changing a schedule

1. Write the task's brief text to a file in the owning home, then `config/schedules.d/<name>.conf` in that home, in the format `docs/configuration.md` owns.
2. Run `bin/fm-schedule.sh validate --home <that home>`; a refused file is never fired and never guessed at, so fix it rather than working around it.
3. Run `bin/fm-schedule.sh list` and check the row's next run is the slot the captain approved.

A new or changed calendar fires nothing at once; the first run is the next slot.

## When a scheduled-run task arrives

The home's inbox note names the schedule and the task id `sched-<name>-<YYYYMMDDHHMM>`, and the task body names the exact run-summary path.
Dispatch it as an ordinary task, and brief the worker to write that run summary before the task closes.
The run itself writes the summary, because only it knows the time used and why it stopped; the scheduler only reads it.
A run that writes none is still reported, as "no run summary" with the task's open and close times, and a `failed` or invalid summary counts toward the pause.

## Writing the run summary

Write one `schema=fm-schedule-result/v1` file at the path the task body names, with the fields `docs/configuration.md` lists.
Use `outcome=cut-short` with the specific `cut_reason` whenever a rule stopped the run early, so the notification says which rule cut it; explain `other` in `note`.
A consumer whose own report has different field names maps them once, as the TETJET mapping in that section shows, rather than inventing new keys.

## Reading the views

`bin/fm-schedule.sh list` (or `--json`) prints, and the fleet board's Scheduled runs panel shows, the same columns: Name, Home, What, Next run, Last run, Result, State.
Times are in this machine's local time.
Result shows the last closed run (complete, cut short with its reason, failed, or no run summary, with time used, budget and carried-over count), or `open (<state>)` while its task is open.
State is `scheduled`, `filed`, `running`, `paused-after-failures`, or `refused` for an invalid file, plus `skipped-open <n>` and `caught-up (<n> missed)` when they apply.
`list` changes nothing; it is safe to run at any time.

## Handling a notification or a pause

A run notification is one line for the main firstmate to relay to the captain as it is; no reply or action is owed unless it shows a problem.
A `skipped-open` line means the previous run is still open: look at that task, not at the schedule.
A paused-after-failures blocked line means two runs in a row failed or could not be filed: find the cause from the run records and the tasks, report it, and resume only once the captain agrees the cause is fixed.
