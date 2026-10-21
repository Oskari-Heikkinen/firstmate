# Dated-rule schedule (dated-rule-schedule/v1)

A dated rule is a change that takes effect on a date: a grace period that ends, a reader that retires, a constant that flips.
Written into code as a constant, such a date reaches nobody until it fires (I9).
`dated-rule-schedule/v1` keeps every dated rule of a home in one schedule, gives each rule an owner who is alarmed 14, 7 and 1 days before its date, makes a moved date a reviewed new row, and sends a rule that keeps slipping to main.
Code reads a rule's date with a lookup instead of holding it.

This document owns the format, the chain rules, the alarms and the lookup.
The schema is `docs/handoff-coverage/dated-rule-schedule-v1.schema.json` and a worked example is `docs/handoff-coverage/examples/research.schedule.json`.
[`bin/fm_dated_rules.py`](../bin/fm_dated_rules.py) is the one implementation of the rules below; `bin/fm-handoff-validate.py schedule` checks files with it, and [`bin/fm-dated-rules.py`](../bin/fm-dated-rules.py) (run as `bin/fm-dated-rules.sh`) raises the alarms and answers lookups.
The format generalises tetjet-mate's `xp-route-schedule/v1`; [What xp-route-schedule/v1 keeps](#what-xp-route-schedulev1-keeps) lists what does not map.

## Files

| What | Where | Written by | Read by |
|---|---|---|---|
| Schedule | `<home>/state/dated-rules/<name>.json` | the home's publisher, atomically | `fm-dated-rules.sh check` and `lookup`, `fm-handoff-validate.py schedule` |
| Reader state | `<home>/state/dated-rules/.reader-state.json` | `fm-dated-rules.sh check` | the same, on its next pass |
| Owner alarms | `<home>/state/dated-rules.alerts.json`, store `dated-rules`, registered for `state/dated-rules.status` | `fm-dated-rules.sh check` | the alert-store tick in the home |
| Main escalations | `<home>/state/dated-rules.escalated.json`, store `dated-rules-<home>`, registered for the home's parent channel | `fm-dated-rules.sh check` | the alert-store tick in the parent home (local) or this home (remote) |
| Log | `<home>/state/dated-rules.log` | `fm-dated-rules.sh check` | people |

A home's schedule is one or more files, for example one per publishing tool; the folder holds nothing else.
Every row in a home's schedule is owned by that home, so the alarms are raised where the owner is and no home writes another home's schedule.
A rule that another home must act on is still owned by the home that moves its date; that home names the other in `what`.

Publish a file the way a fragment is published: write it whole to a temporary name starting with `.` in the same folder, check it with `bin/fm-handoff-validate.py schedule <file>` (exit 0), then rename it over `<name>.json`.
Raise `revision` by one and set `published_at` on every publish.

## Format

### Top level

| Field | Type | Required | Meaning |
|---|---|---|---|
| `format` | `"dated-rule-schedule/v1"` | yes | |
| `home` | home | yes | the home that owns every row in this file |
| `publisher` | text | yes | the tool or person that writes this file |
| `revision` | integer ≥ 1 | yes | raised by one on every publish |
| `published_at` | UTC timestamp | yes | |
| `example` | boolean | no | `true` marks a worked example; a live home never holds one |
| `rows` | array of row | yes | |
| `ext` | extensions | no | `<home>.<name>` keys, as in [handoff coverage](handoff-coverage.md#extensions-and-unknown-fields) |

### Row

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | name | yes | the row's id, unique in the home; convention `<rule>.<n>` |
| `rule` | name | yes | the rule this row dates; every row of one rule shares it |
| `owner` | home | yes | the home alarmed for this row; equals the file's `home` |
| `date` | `YYYY-MM-DD` | yes | the UTC date the rule takes effect, from 00:00Z |
| `what` | text | yes | what changes on that date |
| `state` | `scheduled`, `in-force` or `withdrawn` | yes | see [States](#states) |
| `replaces` | row id | no | the row whose date this row moves; absent on the rule's first row |
| `review` | mark | when `replaces` is set | who reviewed the move, when, and the record of it |
| `main_decision` | mark | no | main's decision to let a rule that slipped twice stand at this row's date |
| `ext` | extensions | no | |

A mark is `{"by": text, "at": UTC timestamp, "ref": text}`; `ref` names the review record or decision.
Every object is closed: a field this document does not define is a finding.

### States

- `scheduled`: the date is set and the rule is not yet confirmed in force.
- `in-force`: the owner confirms the rule holds; alarms stop.
- `withdrawn`: the rule will not take effect; alarms stop, and a lookup reports `withdrawn` so callers keep the old behaviour.

Only the newest row of a rule may be `in-force` or `withdrawn`, and such a row is never replaced: a rule that is in force or withdrawn changes again only as a new rule id.

## Moving a date

A row never changes its date.
Moving a rule is a new row with the new date, `replaces` naming the row it moves, and a `review` mark; the old row stays as history.
This settles the handoff-coverage open point on dated-rule slips: every move needs a review step.

- The rows of a rule form one chain: one first row, each later row replacing the one before, all in one file.
- A move without `review` does not take effect.
  Readers keep the newest reviewed row (the effective row), and the unreviewed row raises its own alarm until it is reviewed or removed.
  A later date therefore never arrives by accident: until review, the earlier date stands and keeps alarming.
- A slip is a reviewed move to a later date.
  The second slip of the same rule escalates to main, and the escalation stays until main records `main_decision` on the effective row or the rule is in force or withdrawn.
  Each further slip is a new row without a decision, so it escalates again.
- The reader keeps the most slips it has seen per rule in its reader state, so removing old rows does not lower the count.

`bin/fm-handoff-validate.py schedule` reports a broken chain and an unreviewed move as findings, so neither should be published; the reader still handles both.

## Alarms

`fm-dated-rules.sh check` runs in the watcher's slow-check step (`bin/fm-watch.sh`) whenever `state/dated-rules/` or one of its stores exists, just before the alert-store tick, so an alarm it raises is projected onto the status file in the same pass.
It skips the whole pass when the UTC date and the stat of every input (schedule files, this home's fragments, both stores, both registrations, the parent records and the schema) match its last pass.
It writes a store only when the wanted set changes, through `bin/fm-alert-store.sh sync` under the store lock.
When `state/dated-rules/` is removed, the next pass unregisters both stores, which closes their blockers, and deletes them.
The coverage watcher (`bin/fm-handoff-watch.sh`) leaves a fragment's dated rule to this check once the owner's schedule declares it, so each dated-rule alarm has one writer.
An owner silences an alarm only by changing the schedule; `bin/fm-alert-store.sh ack` hides one for at most 7 days.

| Key | Raised when | Store |
|---|---|---|
| `dated-rule.<row>.14d` | the effective row is `scheduled` and its date is 8 to 14 days away | owner |
| `dated-rule.<row>.7d` | 2 to 7 days away | owner |
| `dated-rule.<row>.1d` | 1 day away | owner |
| `dated-rule.<row>.due` | the date is today or past and the row is still `scheduled` | owner |
| `dated-rule.<row>.unreviewed` | a row moves the rule without a `review` mark | owner |
| `dated-rule.<rule>.broken` | the rule's rows do not form one chain | owner |
| `dated-rule.file.<file>.unreadable` | a schedule file is not JSON, fails the schema or the file rules, is an example, or is not a `.json` file | owner |
| `dated-rule.<id>.unlinked` | a dated rule in this home's own fragment, owned by this home, names no rule here or a date other than the rule's effective date (the coverage watcher checks fragments in other homes) | owner |
| `dated-rule.<row>.escalated` | the rule has slipped twice or more and the effective row has no `main_decision` | main |

`kind` is `dated-rule` and `subject` is the rule id, or the file for `unreadable` and `unlinked`.
A rule 14 days out is therefore raised on the first pass of that UTC day, and the key changes at 7 and 1 days, so each step is a fresh blocker.

Main escalations go through the home's parent channel: for a local secondmate, the store is registered in the parent home's `state/alert-stores/dated-rules-<home>.reg` for `<home>.status` there; for a remote one, in this home for `parent-replies.status`.
A main home keeps both kinds in its own `dated-rules` store, and so does a secondmate whose parent record cannot be read, with a reason saying main could not be reached and a problem line on every pass.

Problem lines (an unreadable schema, a store or registration it cannot write) are printed on every pass until they are gone, queued as a `check: dated-rules: <problem>` wake and woken on with the alert-store tick's problems.
A pass that does not end with `dated-rules check: complete` is a problem too.

## Fragment links

A [handoff-registry/v1](handoff-coverage.md#dated-rules) fragment's dated rule points at the schedule: its `id` is the rule id in the schedule of its `owner`, and its `date` is that rule's effective date.
So a moved date shows as `unlinked` until the fragment is revised with the new date.
This check raises it for the fragments in the owner's own home; for a fragment published in another home, the coverage watcher of the protocol's owner raises `unlinked` to that home and the rule's owner.

`bin/fm-handoff-validate.py schedule --fragment <fragment> <schedule>...` checks every dated rule in the fragments whose owner has a schedule in the call.

## Lookup

Code that depends on a dated rule reads its date at run time instead of holding a constant:

```
FM_HOME=<home> <firstmate>/bin/fm-dated-rules.sh lookup prep-grace-end
2026-10-27 scheduled prep-grace-end.1
```

`--json` prints the resolved row: `rule`, `row`, `date`, `state`, `owner`, `what`, `slips`, `pending` (unreviewed rows after the effective one) and `paths`.
Python code can load the library by path and call it directly:

```python
spec = importlib.util.spec_from_file_location("fm_dated_rules", "<firstmate>/bin/fm_dated_rules.py")
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)
row = rules.lookup("<home>", "prep-grace-end")
```

The rule is in force when the UTC date is on or after `date` and `state` is not `withdrawn`.
The lookup exits 1 (`NotDeclared`) when no schedule declares the rule and 3 (`Unknown`) when the rule cannot be resolved or any schedule file of the home cannot be read, since that file could hold the rule or a newer row of it.
A caller treats both as "no date" and fails closed: it applies the stricter behaviour and reports the failure, never the lenient one.

## What xp-route-schedule/v1 keeps

`xp-route-schedule/v1` is tetjet-mate's schedule for retiring old experiment routes; it stays its owner's format.
These parts of it do not map onto a row and stay with it:

- `spans` (rollback window, deprecate and sunset offsets, replacement lookback, quiet days): its dates are offsets from a cutover; a row holds one absolute date, so its publisher computes the dates and writes rows.
- Fire conditions and facts: an xp date fires only when its conditions hold and a missing fact counts as failing; a row has no conditions, and `in-force` is the owner's confirmation.
- `previous` and `successor` (a sha256 chain between whole schedule versions, bound in `xp-release-set/v1`): rows chain through `replaces` inside one file, and a schedule file is not content-addressed.
- `route`, `old_route` and the retire, deprecate and sunset steps per route: one rule per step and route, with the route in `what` or `ext`.
- The slip log kept by the publisher outside the document: here the reader keeps the slip high-water mark; both escalate after two slips.
- `apply()` writing into a capability: a row carries no effect; the code that reads the lookup applies it.
