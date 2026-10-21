---
name: handoff-coverage
description: Load before building or changing anything that hands a record across a home, machine or process boundary (a new artifact type, a stage, a timer, service or custom check that reads or writes handoff records), before publishing or editing a handoff-registry/v1 fragment or writing handoff-receipt/v1 receipts, and when a handoff coverage alarm names your home.
user-invocable: false
metadata:
  internal: true
---

# handoff-coverage

Load this before building or changing anything that hands a record across a home, machine or process boundary, before publishing a fragment or writing receipts, and when a coverage alarm names your home.

[`docs/handoff-coverage.md`](../../../docs/handoff-coverage.md) owns the formats, file locations, routing, checks and compatibility rules.
`bin/fm-handoff-validate.py` checks fragments, receipts and outboxes; its header owns the commands and exit codes.
This skill owns only when an agent or home must act, and how.

## When you must publish a fragment

- Your home owns an artifact type that crosses a home, machine or process boundary: you own its protocol, so it lives in a fragment under your home's `state/handoff-registry/`.
- You add, remove, rename or reorder a stage, change a bound, retry limit, code, place, outbox, version range or cleanup, or add a dated constant: publish a new revision of the fragment that declares it.
- You install a timer, service, cron job or custom check that reads or writes handoff records: name it in its stage's `actors`, or it raises `undeclared-actor`.
- A stage another home owns belongs to your protocol: declare it in your fragment with that home as `owner`, and tell its owner which outbox to write.

Publish atomically (temporary dot name in the same folder, then rename), raise `revision`, and run `bin/fm-handoff-validate.py fragment <file>` before the rename.
A fragment with `"example": true` is never loaded; never mark a live fragment that way.

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

## What the coverage checks alarm on

The doc's "Coverage checks" table is the full list; in short:

- a record whose type no protocol lists (`unregistered-type`), or a receipt naming a protocol, stage, code or version no fragment declares (`unregistered-receipt`);
- a record sitting in an input place past the stage's `accepted` bound with no receipt (`no-receipt`);
- a receipt still `accepted`, `held` or `waiting` past its bound, a refusal open 4 h, or retries past `retry_limit` (`open-past-bound`);
- any receipt with `holds_all` (`lane-fault`, to main at once);
- an unreadable or unparseable fragment, outbox, place or sync stamp, an unknown `format`, or a synced copy older than `max_lag` (`source-unreadable`, `sync-stale`);
- a timer, service, cron job or custom check no stage names (`undeclared-actor`);
- a dated rule 14, 7 or 1 days out or past its date (`dated-rule`);
- a home's watcher heartbeat older than 2 ticks (`watcher-silent`).

An alarm stays active while its condition holds, so notes and status lines cannot close it: fix the cause, or acknowledge it in the alert store if you own it.

## Never

- Never put routing, bounds or codes in code instead of the fragment; changing a route is a fragment revision, not a code change.
- Never add a closed field by hand; information beyond the closed fields goes in `ext` under your own home's name.
- Never write receipts for a stage your home does not own, or point two stages at one outbox.
