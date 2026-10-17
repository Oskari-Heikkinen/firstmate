# Loop status

The loop status command shows where every open experiment request stands, raises an alert when one stalls, and measures lead time, by reading the loop's existing records.
[`bin/fm-loop.sh`](../bin/fm-loop.sh) runs it and its header owns usage; [`bin/fm-loop.py`](../bin/fm-loop.py) owns the stage rules and alert conditions.
The "Loop sources" section of [docs/configuration.md](configuration.md#loop-sources-configloop-sources) owns the config file that names the sources and thresholds.

## Commands

- `bin/fm-loop.sh status [--json] [--all]` prints each open request's stage, age in that stage, last event and the reason it waits, then the open TETJET capacity alerts and the open loop alerts.
  `--all` also lists closed and fully analysed requests.
- `bin/fm-loop.sh alerts` prints one line per unacknowledged loop alert and nothing otherwise.
- `bin/fm-loop.sh alerts --new` prints only alerts newly raised since it last reported them; see "Watcher check".
- `bin/fm-loop.sh ack <alert-id>` acknowledges one alert.
- `bin/fm-loop.sh leadtime [--json] [--weeks N]` prints lead times per request family and per week.
- `bin/fm-loop.sh arm` and `bin/fm-loop.sh disarm` install and remove the watcher check.

Every run is niced to 19, idle I/O class, and capped at 60 seconds; `alerts --new` is capped at the watcher's `FM_CHECK_TIMEOUT` less 5 seconds.

## What it reads

Every source is only read: nothing is woken, consumed or acknowledged, and no command that changes a record is called.

- Submit receipts (`<id>.submit.json`): the request id, its family (`task`), its digest, when it was filed and which request it replaces.
- The hand-off queue (`tj-handoff/v1` records): intake decisions, supersede and withdraw records, all-cut records, launch packages (`READY FOR LAUNCH` and `BATCH CUT`) and abandoned packages.
- The operator's pickup log: when the operator took a package.
- Collected records (`tetjet-collected/v1`): when a request was collected, and whether fully.
- Batch registrations and analyses under `~/lattice-batches`: when a batch was registered and analysed, and any analysis refusal without a `resolved_utc`.
- The TETJET snapshot (`tetjet-queue-snapshot.v1`): when a package started and ended, and its state note.
- The ledger catalog, opened read-only: the first run start per batch.
- Captain-held backlog rows (`(hold-kind: captain)`), matched by task id against the request's family or id.
- Parked tasks' `.meta` files whose `park_when` names a request id.
- The last 256 KiB of the TETJET status file, for the latest line per capacity alert key.

A source that is missing or unreadable is listed on the sources line; what it feeds reads as unknown, and the command still succeeds.
A source named in the config file that is missing, or any source that exists but cannot be read, also raises a `source-unreadable` alert.

## Stages

A request's stage is the furthest point its records reach, in this order:

- `filed`: submitted, no intake decision yet.
- `refused`: the intake gate refused it and no later request replaces it; the reason is the gate's first reason.
- `accepted`: accepted, no launch package yet; a captain hold on its family is named.
- `launch-ready`: a package names it, and the operator has not taken it.
- `taken`: the operator took the package, and no start is recorded.
- `running`: the package started (snapshot, catalog or registration) and has not ended; the reason is the snapshot's state note.
- `ended`: the package ended and is not collected.
- `collected`: collected, and a batch is not registered.
- `registered`: registered, and a batch is not analysed.
- `analysis-refused`: a batch's analysis was refused and the refusal is unresolved.

A request is no longer open once it is superseded, withdrawn, replaced before any package, or collected with every batch analysed.
A request with a collected record is collected only when that record says `fully_collected`; an older request without one counts as collected once every package is.
Abandoned packages are ignored.

## Alerts

Each condition below is one durable record, `<home>/state/loop-alerts/<alert-id>.json`, where the id is the condition and its subject.

- `no-collection--loop`: no collection for `no_collection_hours` (default 24) while a request is launch-ready, taken, running or ended.
- `no-package--<request>`: accepted with no launch package for `accepted_no_package_hours` (default 12).
- `no-analysis--<batch>`: collected with no registration or analysis for `collected_no_analysis_hours` (default 6).
- `analysis-refused--<batch>`: an unresolved analysis refusal for an open request, raised at once.
- `park-on-closed--<task>--<request>`: a parked task's condition names a superseded or withdrawn request.
- `source-unreadable--<source>`: see "What it reads".

`status` and `alerts` both sync the records.
An alert prints until it is acknowledged, even after its condition clears; the line then says when it cleared.
An acknowledged alert stays quiet while its condition holds, and is raised again if the condition clears and later recurs.
While any source raises `source-unreadable`, no alert clears: its condition is unknown, not gone, so a source that comes back does not raise again what it hid.
`<home>/state/loop-alerts/log` gets one line per raise, clear and acknowledgement, with the time, what happened and what happens next.

## Watcher check

`alerts --new` is the mode a standing watcher check runs, so firstmate wakes once per newly opened alert and never for alerts already open.
It prints one line per alert occurrence it has not reported yet, in the same format as `alerts`, and nothing otherwise.
An occurrence is the alert id with the raise it belongs to: a raise again after a clear is a new occurrence and prints again.
An acknowledged alert never prints, and neither does `source-unreadable`, so a missing or unreadable source never makes the check print; `status` and `alerts` still show it.
An alert raised and cleared between two runs still prints once, marked cleared.

`<home>/state/loop-alerts/reported.cursor` records the last reported occurrence per alert.
The first run in a home, with no cursor, records every current alert as reported and prints nothing, and the log says so.
Lines print before the cursor moves, so an interrupted run can repeat a line but never loses one; an unreadable cursor prints one line and is reseeded.
The run is capped at `FM_CHECK_TIMEOUT` less 5 seconds (25 by default); a failure or timeout prints one line, once per distinct failure, kept in `<home>/state/loop-alerts/check-failure` until a run succeeds.

`bin/fm-loop.sh arm` installs the check in a home: it seeds the cursor when none exists, writes `<home>/state/loop-alerts.check.sh` to run `alerts --new` for that home, and binds it with `bin/fm-check-register.sh loop-alerts`, so the home's running watcher runs it every `FM_CHECK_INTERVAL`.
Rerunning `arm` is safe: it neither reseeds a cursor nor rewrites an unchanged shim.
`bin/fm-loop.sh disarm` unregisters it with `bin/fm-check-unregister.sh loop-alerts` and removes the cursor, so a later `arm` seeds afresh.
Neither writes outside the home's `state/`.

To install it in a home, from that home's checkout:

1. Write `config/loop-sources` naming the home's sources (see "Loop sources" in [docs/configuration.md](configuration.md#loop-sources-configloop-sources)).
2. Run `bin/fm-loop.sh status --home <home>` and confirm the sources line reads every source as expected.
3. Run `bin/fm-loop.sh arm --home <home>`; it prints `armed: state/loop-alerts.check.sh`.
4. Run `bin/fm-loop.sh alerts --new --home <home>`; it prints nothing while no new alert has opened.

A check line wakes firstmate as `check: <home>/state/loop-alerts.check.sh: <alert line>`; the `loop-status` skill says what to do with it.

TETJET's own capacity alerts (`tj-lane-refused`, `tj-idle`, `tj-capacity-unread`) are shown beside the stages when their latest status line is `blocked`, and are never raised again here; tetjet-mate owns them.

## Lead time

`leadtime` prints, per family of accepted requests, the median and longest time from `REQUEST ACCEPTED` to the first launch package, the median time to the first collected batch (the first result), and how many accepted requests still have no package.
A family is the submit's `task`, or the request id without its trailing `-<number>`.

It then prints, per ISO week in which a stage started, the median hours and count for each stage of each request's first package: filing to gate, gate to package, package to operator, operator to start, start to end, end to collected, and collected to analysis.
Each week also counts submits and refiles (submits that replace an earlier request).
Report, decision and idea-to-verdict times have no source yet and are listed as not read.

Behavioral verification lives in `tests/fm-loop.test.sh`.
