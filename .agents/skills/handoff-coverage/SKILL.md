---
name: handoff-coverage
description: Load before building or changing anything that hands a record across a home, machine or process boundary (a new artifact type, a stage, a timer, service or custom check that reads or writes handoff records), before publishing or editing a handoff-registry/v1 fragment, a dated-rule-schedule/v1 schedule or handoff-receipt/v1 receipts, before writing a dated constant into code, and when a handoff coverage or dated-rule alarm names your home.
user-invocable: false
metadata:
  internal: true
---

# handoff-coverage

Load this before building or changing anything that hands a record across a home, machine or process boundary, before publishing a fragment or writing receipts, and when a coverage alarm names your home.

[`docs/handoff-coverage.md`](../../../docs/handoff-coverage.md) owns the formats, file locations, routing, checks and compatibility rules.
[`docs/dated-rule-schedule.md`](../../../docs/dated-rule-schedule.md) owns the dated-rule schedule, its alarms and the lookup.
`bin/fm-handoff-validate.py` checks fragments, receipts, outboxes and schedules; its header owns the commands and exit codes.
`bin/fm-handoff-watch.sh` is the watcher that raises the coverage alarms; its header owns the commands and arming.
This skill owns only when an agent or home must act, and how.

## When you must publish a fragment

- Your home owns an artifact type that crosses a home, machine or process boundary: you own its protocol, so it lives in a fragment under your home's `state/handoff-registry/`.
- You add, remove, rename or reorder a stage, change a bound, retry limit, code, place, outbox, version range or cleanup, or add a dated constant: publish a new revision of the fragment that declares it.
- You install a timer, service, cron job or custom check that reads or writes handoff records: name it in its stage's `actors`, or the install check refuses it and, if installed around the check, it raises `undeclared-actor`.
- A stage another home owns belongs to your protocol: declare it in your fragment with that home as `owner`, and tell its owner which outbox to write.

Publish atomically (temporary dot name in the same folder, then rename), raise `revision`, and run `bin/fm-handoff-validate.py fragment <file>` before the rename.
A fragment with `"example": true` is never loaded; never mark a live fragment that way.

## Firstmate's own handoffs

Briefs, marked `fm-send` requests and secondmate status lines are registered by `bin/fm-handoff-firstmate.py`, never by hand; the doc's "Firstmate's own handoffs" section owns what it declares.

- To adopt it in a home, run `bin/fm-handoff-firstmate.py publish --home <home>`, then `bin/fm-handoff-watch.sh arm`.
- Rerun `publish` after adding or retiring a secondmate (and, in tooling-mate, after a home joins or leaves); an unchanged publish writes nothing.
- Its stages read the existing records through receipt adapters (`bin/fm_handoff_adapters.py`): never write receipt files for them, and never add a second writer of a pending reply, inbox message or status line to feed the watcher.
- A new adapter is a reader only, is named in the stage's `<owner>.receipt-adapter` ext key, and reads each file once per change.

## When you install a tool

Every installer runs the shared install check before it installs a timer, service, cron job or custom check, and installs only on exit 0; the doc's "Installed tools" section owns the rules and grandfathering.

- `bin/fm-check-register.sh <id>` runs it for you; add `--no-handoff <reason>` for a check that reads and writes no handoff record.
- A shell installer sources `bin/fm-handoff-actors-lib.sh` and calls `fm_handoff_actor_install_check <home> <state> <actor>`; anything else runs `bin/fm-handoff-actors.py check --home <home> <actor>`.
- A tool that touches no handoff is declared with `bin/fm-handoff-actors.py declare --home <home> --none --reason <text> <actor>`; a tool that does is named in its stage's `actors`, never declared `none`.
- A refusal is not a fault to work around: declare the tool, or do not install it.
  Never write a trust record, unit or crontab by hand to get past it; `bin/fm-handoff-actors.py list` reports that as `undeclared-actor`.

## When you must write receipts

- Your home owns a stage: it writes one receipt for every decision on every record, successes included, to the stage's declared outbox.
- Write to `<outbox>/.tmp/`, then rename to the final name, and only then let the decision take effect; if the write fails, do not act.
- `refused` and `held` carry a declared code; `waiting` carries `reason` and an `until` inside the stage's `waiting` bound; a code declared `holds_all` carries `holds_all: true` and its `stops` line.
- A version your stage does not accept is refused with `version-unsupported`, never guessed at or read as the nearest version.
- A retry or refile is the next `attempt`; a later transition within one attempt is the next `seq`.
- Never edit, rename or delete a receipt after it lands; retention cleanup is the protocol's `cleanup`.

## Adding a new stage

Declare every row of "What a new stage must declare" in the doc in the protocol owner's fragment: name and position, owner, `accepts` (and `writes` if it hands records on), input place and outbox with their reach, all three bounds, `retry_limit`, every code with its `fix_owner` and `holds_all`, cleanup and actors.
Readers move first: the next stage must accept everything the new stage writes before the new stage writes it, and the validator refuses a chain that breaks this.
A stage that is declared but not yet running is `planned: true`; drop the flag when it starts.

## Adding a new artifact type

Pick a protocol id no fragment uses, then declare its `schema`, `record_types`, `versions`, `senders`, `first_stage`, its stages as above, its `cleanup` and any `dated_rules`.
The first stage is where an unsupported change is refused, with a receipt.
Put a dated rule in `dated_rules`, never as a date constant in code.

## Dated rules

- A date your code acts on is a row in your home's schedule, `state/dated-rules/<name>.json`, owned by your home; the code reads it with `bin/fm-dated-rules.sh lookup <rule>` (or the library's `lookup`) and treats a failed lookup as the stricter behaviour.
- The fragment's `dated_rules` entry names the rule id and carries its effective date.
- To move a date, add a row with the new date, `replaces` the old row and a `review` mark from whoever reviewed the move; never edit the old row's date. Then revise the fragment with the new date.
- When the rule holds, set its newest row's `state` to `in-force`; when it is dropped, `withdrawn`.
- Run `bin/fm-handoff-validate.py schedule --fragment <your fragment> <schedule>` before the rename.
- A second slip escalates to main; only main records `main_decision` on the row.

## What the coverage checks alarm on

The doc's "Coverage checks" table is the full list; in short:

- a record whose type no protocol lists (`unregistered-type`), or a receipt naming a protocol, stage, code or version no fragment declares (`unregistered-receipt`);
- a record sitting in an input place past the stage's `accepted` bound with no receipt (`no-receipt`);
- a receipt still `accepted`, `held` or `waiting` past its bound, a refusal open 4 h, or retries past `retry_limit` (`open-past-bound`);
- any receipt with `holds_all` (`lane-fault`, to main at once);
- an unreadable or unparseable fragment, outbox, place or sync stamp, an unknown `format`, or a synced copy older than `max_lag` (`source-unreadable`, `sync-stale`);
- a timer, service, cron job or custom check no stage names (`undeclared-actor`, not raised until the installer inventory lands);
- a dated rule 14, 7 or 1 days out or past its date, a move without review, a broken chain or an unreadable schedule, a fragment entry that disagrees with the schedule, and a second slip, to main (`dated-rule`, raised by `bin/fm-dated-rules.sh check` for a rule in its owner's schedule, and by the watcher only for a fragment rule no schedule declares);
- a home's watcher heartbeat older than 2 ticks (`watcher-silent`).

A refusal or hold is also raised to its `fix_owner` and sender as kind `refused` or `held`.
Each alarm is a level in an alert store ([docs/alert-store.md](../../../docs/alert-store.md)), so notes and status lines cannot close it while its condition holds: fix the cause, or, if it was routed to you, acknowledge it with a bounded expiry as the `alert-store` skill says.

## Running the watcher

A home that owns a stage or a protocol, and main, run the watcher: `bin/fm-handoff-watch.sh arm` once in that home, which runs a first pass and binds the watcher check.
Run `bin/fm-handoff-watch.sh tick` to see a change take effect at once; drills use `tick --root <scratch root>` and never arm anything or touch a live home.
`bin/fm-handoff-watch.sh disarm` stops it, closes the blockers it posted and removes its heartbeat; disarm only a watcher that is being retired.
An alarm reaches you as a `blocked` line in your `state/handoff-watch.status`; `state/handoff-watch/log` in the watching home holds every raise and clear.
A printed `handoff-watch: ... cannot be delivered` line means an alarm has no reachable target: fix the home list or the target's `state/` folder.

## Never

- Never put routing, bounds or codes in code instead of the fragment; changing a route is a fragment revision, not a code change.
- Never add a closed field by hand; information beyond the closed fields goes in `ext` under your own home's name.
- Never write receipts for a stage your home does not own, or point two stages at one outbox.
- Never arm the watcher in a scratch copy or run a drill against a live home's state.
