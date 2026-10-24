# Handoff coverage protocol (handoff-coverage/v1)

A handoff is any record that crosses a home, machine or process boundary: an experiment request, a result pack, a cutover record, a brief.
`handoff-coverage/v1` makes every handoff covered by construction.
Each artifact type is a registered protocol with an ordered chain of stages, every stage writes a receipt for every decision, and a watcher in every home joins the two to alarm on anything that is refused, stuck, unread or undeclared.

This document owns these formats and the rules that bind them:

- `handoff-registry/v1`, the fragment in which a home declares the protocols it owns ([Registry fragment](#registry-fragment-handoff-registryv1));
- `handoff-receipt/v1`, one stage's outcome for one record ([Receipts](#receipts-handoff-receiptv1));
- `handoff-actors/v1` and `handoff-actor-inventory/v1`, the install check's declarations and the `undeclared-actor` source ([Installed tools](#installed-tools));
- how the coverage checks use alert stores, whose format `fm-alert-store/v1` generalises `tj-capacity-alerts/v1` and is owned by [docs/alert-store.md](alert-store.md) ([Alert store](#alert-store)).

The machine-checkable schemas are `docs/handoff-coverage/handoff-registry-v1.schema.json`, `docs/handoff-coverage/handoff-receipt-v1.schema.json` and `docs/handoff-coverage/handoff-actors-v1.schema.json`.
`bin/fm-handoff-validate.py` checks files against them plus the cross-field rules a schema cannot express; its header owns the commands and exit codes.
Worked examples are in `docs/handoff-coverage/examples/`, and every one of them validates in CI (`tests/fm-handoff-coverage.test.sh`).
The skill `.agents/skills/handoff-coverage/SKILL.md` tells an agent when it must publish a fragment or write receipts.

The watcher that reads these files is `bin/fm-handoff-watch.sh` ([Watcher](#watcher-fm-handoff-watch)); its header owns the commands and arming.
The shared installer check is `bin/fm-handoff-actors.py` ([Installed tools](#installed-tools)).
Dated rules live in each owner's schedule, `dated-rule-schedule/v1`, which [docs/dated-rule-schedule.md](dated-rule-schedule.md) owns.

## Words

- **Home**: a Firstmate home identity such as `tetjet-mate` or `lattice-research-mate`, matching `[a-z0-9][a-z0-9-]{0,63}`.
  `main` is the main Firstmate home and `tooling-mate` owns this protocol; both are route targets in every protocol.
- **Protocol**: one artifact type's handoff contract: its record types, its stage chain, its cleanup and its dated rules.
- **Stage**: one owner's step in the chain, with an input place, a receipt outbox, bounds and refusal codes.
- **Record**: one handoff item, named by a stable id (`record`) that every stage of the chain uses, such as a request id.
- **Attempt**: one try of one stage at one record; a retry or a refile is the next attempt.
- **Place**: a folder a stage reads records from.
- **Outbox**: a folder a stage writes its receipts to, and nothing else.
- **Fragment**: one file of `handoff-registry/v1` published by one home.
- **Registry**: the union of every home's fragments.

## Files and locations

| What | Where | Written by | Read by |
|---|---|---|---|
| Fragment | `<home>/state/handoff-registry/<name>.json` | the owning home's publisher, atomically | every home's watcher, installers, `fm-handoff-validate.py` |
| Receipt | `<outbox>/<YYYYMMDDTHHMMSS.ffffffZ>-<receipt_id>.json` | the stage owner, atomically, before its decision takes effect | the watcher (the outbox's registered reader), the next stage if it wants |
| Receipt staging | `<outbox>/.tmp/` | the stage owner | nobody |
| Sync stamp | `<synced folder>/.synced-at` | the sync job that copies a synced place or outbox | the watcher |
| Alerts | an `fm-alert-store/v1` store per alarm target, registered in that target's `state/alert-stores/` (see [Alert store](#alert-store)) | the watcher | the alert-store tick in the target home |
| Actor declarations | `<home>/state/handoff-actors/*.json` (`handoff-actors/v1`) | `bin/fm-handoff-actors.py` | the install check and the actor inventory in every home |
| Coverage reports | `<home>/state/handoff-watch/coverage/<YYYY-MM-DD>.txt` and its `state.json` | the watcher's weekly pass | the home's owner (see [Measurement](#measurement)) |

`<home>` is the home's root folder.
A home may publish several fragment files, for example one per publishing tool; each file carries its own `publisher` and `revision`.
Paths inside a fragment are absolute, so a reader never resolves them against its own working folder.

## Registry fragment (`handoff-registry/v1`)

A fragment declares the protocols its home owns.
The xp chain S1-S9 is worked as `docs/handoff-coverage/examples/xp-chain.fragment.json`; it is marked `"example": true` and its paths are placeholders.

### Top level

| Field | Type | Required | Meaning |
|---|---|---|---|
| `format` | `"handoff-registry/v1"` | yes | the format and its major version |
| `home` | home | yes | the publishing home; every protocol in the file is owned by it |
| `publisher` | text, 1-200 | yes | the tool or skill that wrote the file, so a reader knows whom to ask |
| `revision` | integer >= 1 | yes | raised on every publish of this file; a reader keeps the highest revision it has seen |
| `published_at` | UTC time | yes | when this revision was written |
| `example` | boolean | no | `true` marks a teaching file; a watcher never loads a fragment with `example: true` |
| `protocols` | array of protocol | yes | may be empty while a home has nothing to declare |
| `ext` | extensions | no | see [Extensions](#extensions-and-unknown-fields) |

### Protocol

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | name | yes | unique across the whole registry |
| `owner` | home | yes | must equal the fragment's `home` |
| `title` | text, 1-200 | yes | one line a person reads in an alarm |
| `schema` | text | yes | where the record schema lives, as `<repo or home>:<path>` |
| `record_types` | array of text, >= 1, unique | yes | the values of a place's `type_field` that belong to this protocol, such as `xp-contract/v0`; `unregistered-type` alarms on any other value |
| `versions` | range | yes | the record versions any stage of the protocol may write |
| `senders` | array of home, >= 1 | yes | the homes that file into the first stage; the sender route when a receipt names none |
| `first_stage` | name | yes | the stage where a change is refused, with a receipt, before anything downstream sees it; must be a stage of this protocol |
| `stages` | array of stage, >= 1 | yes | the chain; array order is chain position |
| `cleanup` | protocol cleanup | yes | retention for the whole chain |
| `dated_rules` | array of dated rule | no | every dated constant the protocol depends on |
| `ext` | extensions | no | |

A name matches `[a-z0-9][a-z0-9._-]{0,63}`.
A range is `{"min": <int >= 0>, "max": <int >= 0>}` with `min <= max`, in record major versions.

### Stage

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | name | yes | unique within the protocol |
| `owner` | home | yes | the home whose watcher raises this stage's alarms and whose tool writes its receipts; may differ from the protocol owner |
| `accepts` | range | yes | the record versions the stage reads |
| `writes` | range | no | the versions it hands to the next stage; absent for a stage that hands nothing on |
| `input` | place | yes | where its records arrive |
| `outbox` | outbox | yes | where its receipts go; never the same folder as any input place, except at a stage a [receipt adapter](#receipt-adapters) reads |
| `bounds` | bounds | yes | the longest each non-terminal state may last |
| `retry_limit` | integer 0-1000 | yes | how many attempts after the first the stage may make on one record before `open-past-bound` fires |
| `codes` | map of code to code entry | yes | every refusal and hold code the stage may write; may be `{}` |
| `cleanup` | stage cleanup | yes | what happens to an input record once the stage is done with it |
| `actors` | array of actor, unique | no | the timers, services, checks and processes that run the stage, so `undeclared-actor` can tell them from strays |
| `planned` | boolean | no | `true` for a stage that is declared but not yet running; `no-receipt` stays quiet for it |
| `ext` | extensions | no | |

`bounds` has three required durations:

- `accepted`: the longest a record may sit in the input place with no receipt, and the longest an `accepted` receipt may stay current;
- `waiting`: the furthest `until` may be from the receipt's `written_at`;
- `held`: the longest a `held` receipt may stay current.

`refused` has no per-stage bound: it routes at once and reaches main once it has been open 4 h (see [Routing and alarm targets](#routing-and-alarm-targets)).
A duration is `<1-6 digits><s|m|h|d>` with no leading zero, such as `15m` or `7d`.

An actor is `<kind>:<name>` with kind one of `systemd-timer`, `systemd-service`, `fm-check`, `cron` or `process`, such as `systemd-timer:tj-sched.timer` or `fm-check:handoff-watch`.

### Places, outboxes and reach

A place is:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `path` | absolute path | yes | the folder, as this machine sees it |
| `reach` | reach | yes | how this machine sees it |
| `match` | glob, no `/` | no | which top-level entries are records; default every non-dot entry |
| `type_field` | field name | no | the top-level JSON field naming the record's type, such as `schema_version`, `format` or `kind`; without it `unregistered-type` cannot check the place |

An outbox has only `path` and `reach`.

`reach` is `{"kind": "local"}` for a folder on this machine, or `{"kind": "synced", "source": "<host>:<path>", "max_lag": "<duration>"}` for a local copy of a folder elsewhere.
`source` and `max_lag` are required for `synced` and forbidden for `local`.
The job that keeps a synced copy writes the UTC time of its last complete sync, one line, to `<path>/.synced-at` after each pass.
A missing or unreadable stamp is `source-unreadable`; a stamp older than `max_lag` is `sync-stale`.

Readers list only the top level of a place or outbox, never recurse, and skip dot entries.

### Codes

`codes` maps each code a stage may write in a `refused` or `held` receipt to a code entry:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `fix_owner` | home | yes | the home that can fix the cause; the alarm goes there |
| `holds_all` | boolean | yes | `true` when this code stops more than its own record, which makes it a lane fault |
| `stops` | text | when `holds_all` | what the fault stops, in one line, for the alarm; forbidden otherwise |
| `what` | text | yes | what the code means |
| `ext` | extensions | no | |

A code matches `[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`.
A key ending in `*` declares a family: `offer-refused:*` covers `offer-refused:no-slot`.
A receipt's code resolves to the exact key if there is one, else to the longest family that matches.

`version-unsupported` is reserved.
Any stage may refuse a record whose version is outside its `accepts` with it, without declaring it; it routes to the sender.
Declaring it, or a family that covers it, is a finding.

### Cleanup

Each stage's `cleanup` says what happens to an input record once its current receipt is `done`:

- `{"action": "delete", "after": "<duration>"}`;
- `{"action": "move", "after": "<duration>", "to": "<absolute path>"}`, which is how a stage hands a record to the next stage's place;
- `{"action": "keep"}`, for a stage whose input is another tool's ledger; `after` and `to` are forbidden.

The protocol's `cleanup` is `{"stage": <name>, "receipts_after": <duration>, "records_after": <duration>}`.
`stage` names the stage whose `done` ends the chain for a record; it must be a stage of the protocol.
Once a record's `stage` receipt is `done`, its receipts may be deleted after `receipts_after` and every kept copy of the record after `records_after`.
Receipts are never deleted before that, so the watcher always has the current receipt of an open record.

### Dated rules

A dated rule replaces a dated constant in code (I9):

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | name | yes | the rule id in the owner's [dated-rule schedule](dated-rule-schedule.md); unique within the protocol |
| `owner` | home | yes | the home that alarms are routed to and that moves the date |
| `date` | `YYYY-MM-DD` | yes | the UTC date the rule takes effect: the rule's effective date in that schedule |
| `what` | text | yes | what happens on that date |
| `ext` | extensions | no | |

The owner's schedule is the source of the date: `dated-rule` alarms for a rule it declares come from the schedule reader, and a fragment entry whose date differs from the schedule's raises `unlinked` for the owner ([Fragment links](dated-rule-schedule.md#fragment-links)).
Only a fragment rule that no schedule of its owner declares is alarmed by the watcher from the fragment's `date`, 14, 7 and 1 days before it and every tick after it.
Moving a date is a reviewed new row in the schedule, then a new fragment revision with the new date.

### Publishing a fragment

- Write the whole file to a temporary name in `<home>/state/handoff-registry/`, fsync it, then rename it over `<name>.json`, so a reader sees the old revision or the new one and never part of one.
  Temporary names start with `.`, so readers skip them.
- Raise `revision` by one on every publish, and set `published_at`.
- Validate before the rename: `bin/fm-handoff-validate.py fragment <file>` exits 0.
  A watcher that reads an invalid fragment keeps the last valid revision and raises `source-unreadable` against the home until a valid one lands.
- A protocol lives in exactly one fragment of its owner's home.
  Its stages may be owned by other homes: the protocol owner declares them and the stage owners write their receipts.

## Receipts (`handoff-receipt/v1`)

A receipt is one stage's outcome for one record, attempt and transition.
Every decision is receipted, successes included (I2).
Worked receipts are `receipt-refused.json` (a filing refusal), `receipt-held-lane-fault.json` (an `intake-*` lane fault with `holds_all`), `receipt-waiting.json` (an admission wait on `disk:/mnt/d` with its `until`) and `receipt-done.json` in `docs/handoff-coverage/examples/`.

### Fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `format` | `"handoff-receipt/v1"` | yes | |
| `receipt_id` | 16 lowercase hex | yes | random per receipt; part of the file name |
| `written_at` | UTC time with exactly 6 fractional digits | yes | when the decision was made; part of the file name |
| `protocol` | name | yes | a registered protocol id |
| `version` | integer >= 0 | yes | the record version the stage read |
| `stage` | name | yes | a stage of that protocol |
| `home` | home | yes | the writer; must be the stage's `owner` |
| `record` | 1-256 non-space characters | yes | the record's stable id |
| `attempt` | integer >= 1 | yes | which try of this stage at this record |
| `seq` | integer >= 1 | yes | which transition within the attempt |
| `state` | `accepted`, `refused`, `held`, `waiting` or `done` | yes | |
| `code` | code | for `refused` and `held` | a declared code or `version-unsupported`; forbidden otherwise |
| `holds_all` | boolean | no | must agree with the code's entry; `true` makes the receipt a lane fault |
| `stops` | text | when `holds_all` is `true` | what the fault stops; forbidden otherwise |
| `reason` | token, `[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}` | for `waiting` | the binding constraint, such as `memory`, `disk:<volume>` or `room:<volume>:<class>`; forbidden otherwise |
| `until` | UTC time | for `waiting` | when the stage decides again; after `written_at` and no later than `written_at` plus the stage's `waiting` bound; forbidden otherwise |
| `sender` | home | no | the home that sent this record, when it is not the previous stage's owner |
| `input` | text | no | the record's file name in the input place, when it is not `<record>.json` |
| `detail` | text, 1-1000 | no | one plain sentence for the alarm |
| `evidence` | text | no | a path or id that shows the cause |
| `ext` | extensions | no | |

### States

- `accepted`: the stage took the record and is working on it.
  It must be followed by another receipt within the `accepted` bound.
- `refused`: the stage will not process this attempt; the record is quarantined and nothing else is (I7).
  It stays open until a later attempt at the same record and stage, or an acknowledgement in the alert store, closes it.
- `held`: the stage cannot process the record now for a reason the `fix_owner` must clear; it will retry.
  Each retry is the next attempt, so the retry count is `attempt - 1` and `retry_limit` bounds it.
- `waiting`: the stage is waiting on a named, expected constraint and decides again by `until`.
- `done`: the stage finished with the record and handed it on, or ended the chain.
  `done` is the only terminal state.

A record's current receipt at a stage is the one with the highest `(attempt, seq)`.
Two receipts with the same `(record, stage, attempt, seq)` are a finding.
A stage writes `seq` 1 for the first transition of each attempt and raises it on each later one; it writes the next `attempt` when it, or a refile, tries again.

### Writing a receipt

The outbox pattern: the receipt is in place before the decision takes effect anywhere else.

1. Build the receipt and validate it (`bin/fm-handoff-validate.py receipt --fragment <fragment> <file>` in tests; a stage may check its own fields inline).
2. Write it to `<outbox>/.tmp/<final name>`, fsync it, then rename it to `<outbox>/<final name>`; the rename stays inside the outbox's file system.
3. Only then act on the decision: move the record on, quarantine it, or wait.

If the write fails, the stage does not act; `no-receipt` or `source-unreadable` then reports the stage.
A receipt never changes after its rename; a new transition is a new receipt.

The final name is `<written_at as YYYYMMDDTHHMMSS.ffffffZ>-<receipt_id>.json`, such as `20261021T102005.000000Z-3f9c2a7b1d4e6a80.json`.
Names sort in written order, so a reader keeps a cursor: the last name it processed.
Because clocks on two writers can disagree, a reader rescans the names from 5 minutes before its cursor each tick and drops the ones it has already seen.
`bin/fm-handoff-validate.py outbox <dir>` checks every name against its content and reports any non-dot entry that is not a receipt.

## Routing and alarm targets

Routing is data (I3).
A `refused` or `held` receipt routes to:

- the code's `fix_owner`, within 10 minutes;
- the sender, within 15 minutes: the receipt's `sender`, else the previous stage's owner, else the protocol's `senders` (for the first stage);
- main within 10 minutes when the code `holds_all` (a lane fault);
- main once a refusal or hold has been open 4 h.

`version-unsupported` routes to the sender and to the protocol owner.
A record or receipt no fragment covers reaches tooling-mate within 10 minutes and main at 1 h.
These targets are protocol constants, not fragment fields; the watcher implements them.
Each alarm's store entry says which target it is for and when it is due there (`role` and `deliver_by` in [Alert store](#alert-store)), and [Measurement](#measurement) reports each delivery against them.
Delivery is retried until it is delivered.

## Coverage checks

Each check reads only the fields named here, so any stage or type declared this way is covered without a code change.

| Check | Fires when | Reads | Alarm to |
|---|---|---|---|
| `unregistered-type` | a record in a declared place has a `type_field` value that no protocol lists in `record_types` | `input.path`, `input.match`, `input.type_field`, `record_types` | tooling-mate and the stage owner |
| `unregistered-receipt` | a receipt names a protocol, stage, code or version no fragment declares, or its `home` is not the stage owner | the receipt, the registry | the writer's home and tooling-mate |
| `no-receipt` | a record has been in a stage's input place longer than `bounds.accepted` with no receipt for that stage, unless the stage is `planned` | `input`, `outbox`, `bounds.accepted`, `planned` | the stage owner |
| `open-past-bound` | the current receipt is `accepted`, `held` or `waiting` past its bound (`waiting` past `until`), `refused` for 4 h, or `attempt - 1` exceeds `retry_limit` | `bounds`, `retry_limit`, the receipts | the `fix_owner` (the stage owner for `accepted` and `waiting`); main at 4 h |
| `lane-fault` | the current receipt has `holds_all: true` | `codes.<code>.holds_all`, `stops` | main, at once, naming `stops` |
| `source-unreadable` | a fragment, outbox, place or sync stamp cannot be read or parsed, or a receipt or fragment has an unknown `format` | every declared path | the owner of the path; never silent |
| `sync-stale` | a synced copy's `.synced-at` is older than `max_lag` | `reach` | the stage owner |
| `undeclared-actor` | a user timer, service, cron job or Firstmate custom check is running that no stage lists in `actors` | `actors`, the [actor inventory](#actor-inventory-and-undeclared-actor) | tooling-mate and the installing home |
| `dated-rule` | a dated rule is 14, 7 or 1 days out, or past its date; it slipped twice (main) | the owner's schedule ([docs/dated-rule-schedule.md](dated-rule-schedule.md#alarms)), linked from `dated_rules` | the rule's `owner`; main for the second slip |
| `watcher-silent` | a home's watcher heartbeat is older than 2 ticks | the `handoff-watch` protocol | main |

The watcher's heartbeat is itself a registered protocol, `handoff-watch`, owned by tooling-mate with one stage per home; its receipts are the heartbeat and Firstmate's existing watcher reads them (I10).
That protocol id is reserved for it.

### What a new stage must declare

Every item is a field in its protocol owner's fragment, and nothing else is needed:

| Requirement | Field |
|---|---|
| protocol id and accepted version range | `protocols[].id`, `stages[].accepts` |
| stage name and its position in the chain | `stages[].name`, its index in `stages` |
| owner home | `stages[].owner` |
| input place and receipt outbox, each local or synced(source, max_lag) | `stages[].input`, `stages[].outbox`, their `reach` |
| a bound per non-terminal state, and a retry limit | `stages[].bounds`, `stages[].retry_limit` |
| refusal codes, each with a `fix_owner` | `stages[].codes.<code>.fix_owner` |
| whether a code `holds_all` | `stages[].codes.<code>.holds_all`, `stops` |
| cleanup | `stages[].cleanup` |
| what runs it | `stages[].actors` |

### What a new artifact type must declare

| Requirement | Field |
|---|---|
| its id and schema | `protocols[].id`, `schema`, `record_types` |
| its stage chain | `stages`, each declared as above |
| its first stage, where a change is refused | `first_stage` |
| its retention and cleanup | `protocols[].cleanup`, each stage's `cleanup` |
| any dated rules | `dated_rules` |
| who sends it | `senders` |

## Installed tools

Every installer refuses a tool unless a protocol covers it (I1).
A tool here is anything that runs on its own: a Firstmate custom check, a systemd user timer or service, a cron job or a long-running process.
One shared check decides, and `undeclared-actor` catches what an installer that skipped the check left behind.
`bin/fm-handoff-actors.py` implements both; its header owns the commands, the output line and the exit codes, and `bin/fm-handoff-actors-lib.sh` wraps it for shell installers.

### The install check

An installer asks `fm-handoff-actors.py check --home <home> <actor>` before it installs, where the actor is named as in a stage's `actors` (`<kind>:<name>`, such as `fm-check:disk-room` or `systemd-timer:tj-sched.timer`).
It installs only on exit 0.
The verdict is the first of these that holds:

| Verdict | Holds when | Installs |
|---|---|---|
| `declared` | a stage in a fragment the home sees lists the actor in `actors` | yes |
| `none` | a `handoff-actors/v1` file declares the actor `none`: it reads and writes no handoff record | yes |
| `grandfathered` | the actor was installed before the check existed, or is a Firstmate built-in | yes |
| `unknown` | none of the above, and a fragment, declaration file or unit listing could not be read | no (exit 3) |
| `refused` | none of the above | no (exit 1) |

The homes a home sees are the ones `fm-handoff-watch` reads: itself, its local parent, the homes they list in `data/secondmates.md`, and `config/handoff-homes`.
A custom check runs in one home, so only a stage whose `owner` is that home, or that home's own declarations, cover a `fm-check:` actor.
User units are machine-wide, so a stage or declaration in any home the caller sees covers a `systemd-timer:` or `systemd-service:` actor.
A service is also covered by the timer of the same name (`systemd-service:x.service` by `systemd-timer:x.timer`), since the timer starts it.
A tool that reads or writes handoff records is declared in its stage's `actors`, never as `none`.

`bin/fm-check-register.sh <id> [--from <staged-file>] [--no-handoff <reason>]` runs the check for `fm-check:<id>` before it binds the trust record, and refuses with exit 1 otherwise.
`--no-handoff <reason>` first records the `none` declaration, for a check that touches no handoff record.
Other installers adopt the check by calling it themselves:

- a shell installer sources `bin/fm-handoff-actors-lib.sh` and installs only when `fm_handoff_actor_install_check <home> <state> <actor>` returns 0, logging `FM_HANDOFF_ACTOR_WHY` otherwise;
- any other installer runs `bin/fm-handoff-actors.py check --home <home> <actor>` and installs only on exit 0;
- either declares a tool that touches no handoff with `fm_handoff_actor_declare_none` or `fm-handoff-actors.py declare --home <home> --none --reason <text> <actor>`, and a tool that does by listing it in its stage's `actors` and republishing the fragment.

Every verdict is appended to `<home>/state/handoff-actors/log` with the reason and whether the install proceeds.

### Grandfathering

Nothing installed before the check existed stops, and nothing armed stops on update.
On its first call in a home, the check writes a one-time snapshot of what is installed there and grandfathers every entry in it:

- `state/handoff-actors/grandfathered.json` lists the home's registered custom checks;
- `state/handoff-actors/grandfathered-units.json` lists the machine's active user and transient units, written only in the machine's anchor home (the home with no local parent).

Each snapshot is written once, never replaced, and only after its own listing succeeded, so a machine whose user units cannot be listed still grandfathers its checks and takes the unit snapshot on a later call.
Re-registering a grandfathered check, as every arm command does on update, therefore succeeds.
Firstmate's own built-in checks and timers are grandfathered in code (`BUILTIN` in `bin/fm-handoff-actors.py`), so a fresh home arms them too.
[Firstmate's own handoffs](#firstmates-own-handoffs) are registered now, but their only actor is the watcher itself (`fm-check:handoff-watch`), so `BUILTIN` stays until each built-in is listed in a stage.
A grandfathered actor appears as such in the inventory, so the coverage line can count it; it is never alarmed.
Retiring a grandfathered tool and installing it again later needs no new declaration while its snapshot entry stays; an owner who declares it removes the entry by hand.

### Declaration files (`handoff-actors/v1`)

Every `*.json` file in `<home>/state/handoff-actors/` (dot files excepted) is a declaration file, schema `docs/handoff-coverage/handoff-actors-v1.schema.json`.
`declared.json` is written by `fm-handoff-actors.py declare` and `undeclare`, under a lock and atomically; the snapshots are the two `grandfathered*.json` files.
Every object is closed, and an unreadable or invalid file is a problem that makes every actor it might cover `unknown`.

| Field | Type | Meaning |
|---|---|---|
| `format` | `"handoff-actors/v1"` | this format |
| `publisher` | string | the tool that wrote the file |
| `revision` | integer from 1 | raised on every change |
| `published_at` | UTC timestamp | when this revision was written |
| `actors[].actor` | actor, with an optional trailing `*` | the actor, or with `*` every actor starting with what precedes it |
| `actors[].handoff` | `none` or `grandfathered` | reads and writes no handoff, or installed before the check |
| `actors[].reason` | string, 1-300 characters | why, in one line |
| `actors[].since` | UTC timestamp | when the declaration was made |

### Actor inventory and `undeclared-actor`

`fm-handoff-actors.py list --home <home>` prints the home's inventory as one JSON document, format `handoff-actor-inventory/v1`, which is the source the watcher reads for `undeclared-actor`.

| Field | Meaning |
|---|---|
| `format` | `"handoff-actor-inventory/v1"` |
| `home`, `home_path` | the home id and its folder |
| `anchor` | whether this home lists the machine's units |
| `actors[]` | one row per installed actor: `actor`, `scope` (`home` or `machine`), `state`, and `why` (the evidence, with the covering file's path) |
| `problems[]` | one `{subject, what}` per input that could not be read |

A row's `state` is `declared`, `none`, `grandfathered`, `undeclared` (the install check would refuse it) or `unknown`.
The installed actors are the home's registered custom checks (a `state/<id>.check.sh` with its `state/<id>.check-trust` binding) and, in the anchor home only, the active user timers and services: transient units and units whose unit file is under the user's home, from one read-only `systemctl --user list-units` and one `systemctl --user show`.
Units shipped by the distribution are not inventoried.
A machine without `systemctl` has no units; a `systemctl` that fails is a problem.
The exit is 3 when `problems` is not empty, else 1 when any row is `undeclared`, else 0.

The watcher raises `undeclared-actor` for each `undeclared` row, with subject the actor, to tooling-mate and the inventory's home, and `source-unreadable` for each problem.
A check bound by hand or a unit started around an installer is therefore alarmed on the watcher's next tick.
The inventory reuses each file's parse while its size, inode and mtime are unchanged and reruns `systemctl --user show` only when the active unit list changed (cache `state/handoff-actors/.cache.json`), so a tick with no change costs one `list-units`.
Each change in the undeclared set is logged once to `state/handoff-actors/log`.

### Not yet covered

- `cron:` and `process:` actors can be declared and checked, but the inventory does not list crontabs or processes yet.
- Firstmate's own timer installers do not call the check; their units are covered by `BUILTIN`.
- The TETJET service installer and the research timers adopt the check through their owners.
- `fm-handoff-watch` raises `undeclared-actor` from this inventory once it runs `list` on its tick; until then an owner runs `list` by hand.

## Alert store

The coverage checks raise their alarms as levels in alert stores (I5).
[docs/alert-store.md](alert-store.md) owns the store format `fm-alert-store/v1` (which generalises `tj-capacity-alerts/v1`), the registration `fm-alert-registration/v1`, the projection onto status lines and the acknowledgement rules; none of it is repeated here.
This section says only how the coverage checks fill it.

- **Writer.** The watcher is each store's one writer, through `bin/fm-alert-store.sh sync`, which makes the store's active set equal the alarms it wants for that target in one write.
  It asserts every alarm on every pass while its condition holds and clears it only when the condition is gone, so a relaunch or note cannot close it.
- **Store and key spelling.** The store id is `handoff-watch.<watching home>`, its file is `<watching home>/state/handoff-watch/stores/<target>.json`, and its registration in the target home names the status file `handoff-watch.status`, which the watcher creates empty when it is missing.
  A key is `hw-<kind>-<subject>[-<variant>]`, with each `/` and unsafe character in the subject turned into `-`; a subject that loses characters this way, or a key over 128 characters, ends in a 12-character digest instead.
- **One store per target.** A registration binds a store to one status file, so an alarm reaches each target in the [Alarm to](#coverage-checks) column through a store registered in that target's home (`<target home>/state/alert-stores/<store-id>.reg`).
  The watcher writes that registration itself, as data, the way the alert-store doc allows a tool in another home to.
- **Entry fields.** `key` is one stable slug per check and subject, so re-asserting it is idempotent; it never starts with a reserved prefix (`pending-reply-`, `handoff-pickup-`, `handoff-tj-`).
  `kind` is the check name from the coverage-check table, such as `lane-fault`.
  `subject` names what the alarm is about: `<protocol>/<stage>/<record>` for a record, `<protocol>/<stage>` for a stage, or the path for `source-unreadable` and `sync-stale`.
  `reason` is the one-line blocker text: the receipt's `detail` when it has one, and for `lane-fault` it names the code's `stops`.
  `since` is when the condition began (the receipt's `written_at`, or when the record arrived), and `evidence` holds the receipt or file path.
  `role` is the target's part in the alarm: `fix-owner`, `sender`, `owner` (the stage, protocol or rule owner, tooling-mate, or the home that reads a stale sync) or `main` (a lane fault, a silent watcher, or an escalation).
  `deliver_by` is when the target must have heard of it: the time the alarm became due plus 10 minutes, or 15 minutes for `sender`.
  An alarm becomes due when its condition crosses its bound: at `since` for a receipt or record, at the bound's end for `no-receipt`, `open-past-bound` and `sync-stale`, two intervals after the last heartbeat for `watcher-silent`, and 4 h or 1 h after it opened for main's escalation.
  An alarm rerouted to main for an unseen target keeps that target's role.
  Both fields are written when the key is raised; an entry raised before they existed has neither and is not judged.
- **Acknowledgement.** Only the alarm's target acknowledges it, with `bin/fm-alert-store.sh ack`; the acknowledgement always has an `until` of at most 7 days, after which the alarm is projected again if its condition still holds.
  An acknowledgement of an open `refused` receipt closes the refusal for the 4 h rule until then.

## Watcher (`fm-handoff-watch`)

`bin/fm-handoff-watch.sh` runs one pass every `FM_CHECK_INTERVAL` (300 s by default) as a Firstmate watcher check, once a home arms it; its header owns `tick`, `check`, `arm` and `disarm`.
A pass is niced, idle I/O and capped below the check timeout, and it reads only declared folders, never a tree walk.

**Homes it reads.**
A watcher reads this home, its local parent (`.fm-secondmate-parent`), every local home either of them lists in `data/secondmates.md`, and every line `<home id> <absolute path>` in either's `config/handoff-homes`.
A home on another machine is read through a synced copy listed in `config/handoff-homes`; nothing is fetched across machines.
With `--root DIR`, used by drills, every folder under `DIR` named like a home id is that home and nothing else is read.

**What it evaluates.**
It reads the fragments of every home it sees, but checks only the stages this home owns, the dated rules of the protocols this home owns that their owner's schedule does not declare, and the heartbeats it watches, so each alarm has one writer.
A fragment that turns invalid, or whose `revision` goes back, raises `source-unreadable` for its home and the last valid revision stays in use.
A protocol declared in two fragments keeps the first by home and file name, and raises `source-unreadable` with variant `duplicate` to tooling-mate and both homes.
Outboxes and places are rescanned by modification time, and a receipt is read once; per-stage cursors stay in `state/handoff-watch/stages/`.

**Kinds it raises.**
Besides the checks in [Coverage checks](#coverage-checks), the routing in [Routing and alarm targets](#routing-and-alarm-targets) is raised as kind `refused` or `held` for the current receipt of a record, to the code's `fix_owner` and the sender (the sender and the protocol owner for a reserved code such as `version-unsupported`).
`open-past-bound` is raised for an `accepted`, `held` or `waiting` receipt past its bound, and with variant `retries` past `retry_limit`.
`undeclared-actor` is not raised yet; the watcher does not run the [actor inventory](#actor-inventory-and-undeclared-actor) on its tick yet.
While any source of a stage cannot be read, that stage's earlier alarms are kept, since their conditions are unknown, not gone.

**Escalation and acknowledgement.**
Main is added to a `refused`, `held` or `open-past-bound` alarm once it has been open 4 h from its receipt's `written_at`; an acknowledgement in any of the watcher's stores of a `refused` or `held` key stops that for its `until`.
Main is added to an `unregistered-type` or `unregistered-receipt` alarm 1 h after the watcher first saw it.
An acknowledgement is bounded by the alert-store limit of 7 days for every code; no code has a shorter maximum.

**Delivery.**
An alarm for a home this machine does not see goes to main, its reason prefixed with the intended target.
When main is not seen either, or a store or registration cannot be written, the pass prints one line per occurrence, which wakes the arming home through the watcher check.
Every raise and clear is appended to `state/handoff-watch/log`.

**Weekly coverage.**
The first pass stamps `state/handoff-watch/coverage/state.json`; the first pass 7 days after the stamp writes the home's [coverage line](#measurement) to `state/handoff-watch/coverage/<YYYY-MM-DD>.txt` (keeping the 8 newest), appends it to the log as `coverage: <line>`, prints it with the report's path, which wakes the home once a week through the watcher check, and stamps again.
That pass reads only what changed since the stamp: the home's `state/alert-stores.log` from the byte offset it kept, the stores' events since the stamp, the raises still pending at the last pass, the owned stages' state files, and one run of the actor inventory.
A failure prints one line once per distinct message and never fails the pass.

**Heartbeat.**
Each pass ends by writing one `handoff-receipt/v1` receipt of protocol `handoff-watch`, stage and record set to the home id, to `state/handoff-watch/heartbeat/`, keeping only the newest.
Main's watcher raises `watcher-silent` for any home whose heartbeat folder exists and whose newest heartbeat is older than two intervals (`FM_HANDOFF_WATCH_SILENT_AFTER` seconds, default twice `FM_CHECK_INTERVAL`); every other watcher does the same for main's heartbeat, with variant `seen-by-<home>`.
`disarm` removes the heartbeat, so a disarmed watcher is not read as silent, and unregisters its stores so their blockers close.
Tooling-mate's `handoff-watch` fragment, published by `bin/fm-handoff-firstmate.py` ([Firstmate's own handoffs](#firstmates-own-handoffs)), declares each home's heartbeat folder as that stage's outbox; the watcher never evaluates that protocol as a chain.

**Latency.**
A condition is seen at the next pass and projected at the target home's next alert-store tick, so a target hears of it within about two intervals, 10 minutes at the default.
[Measurement](#measurement) says how close each delivery came.
A killed watcher is seen once its heartbeat is two intervals old, at main's next pass, and projected at main's next tick: up to four intervals, 20 minutes at the default; a home that needs 10 minutes sets `FM_HANDOFF_WATCH_SILENT_AFTER` or a shorter interval.

## Measurement

`bin/fm-handoff-measure.py` reads the records the watcher and the alert stores already write and writes nothing; its header owns the usage.

**Time to notice.**
`fm-handoff-measure.py notice --home <home> [--since T] [--until T]` lists every `handoff-watch.*` alarm raised for that home in the window (default the last 7 days).
For each raise in a store registered in the home it takes the event time (the entry's `since`), the delivery (the first `re-posted alert <key>` line of that store in the home's `state/alert-stores.log` after the raise and before the key cleared or was acknowledged), and the entry's `deliver_by`.
The outcome is `met` (delivered by `deliver_by`), `missed` (delivered after it), `undelivered` (not delivered, and `deliver_by` has passed), `pending` (not delivered yet, still in time), `cleared before delivery`, or `no target` (an entry without `deliver_by`).
One summary line per check kind gives the counts and the median and longest time to notice.
A store that kept only its newest 500 events, from inside the window, is named in a note.
The exit is 1 when an alarm missed or was not delivered, 3 when a store or registration could not be read, else 0.

**Coverage line.**
`fm-handoff-measure.py coverage --home <home>` prints the line the watcher's weekly pass writes, for the 7 days before `--now`:

- the protocols the home owns, from the watcher's fragment cache (`handoff-watch` is not counted);
- the stages it owns: those with a receipt in the week, and those with none, each idle stage saying `idle since <last receipt>`, `never had a receipt`, or `has no watcher state`; planned stages are counted apart;
- the undeclared actors from [the actor inventory](#actor-inventory-and-undeclared-actor);
- the week's time to notice.

The detail lines below it list each part and every alarm.
The exit is 1 when a stage is idle, an actor is undeclared or an alarm missed, 3 when a source could not be read.

**Adoption.**
Nothing new is armed: a home that runs `fm-handoff-watch.sh arm` gets the weekly line from its next pass on, and an owner runs `notice` or `coverage` by hand for any window.
The command runs under nice 19 and idle I/O.

## Firstmate's own handoffs

`bin/fm-handoff-firstmate.py` publishes `<home>/state/handoff-registry/firstmate.json`, the fragment of the handoffs Firstmate itself makes; its header owns usage.
`docs/handoff-coverage/examples/firstmate.fragment.json` is that fragment for tooling-mate with one local secondmate.
Each protocol is owned by the home that sends, because only that home's watcher can read the records, which live in its own `state/`.

| Protocol | Stage | Record | Done when | Codes | Bounds |
|---|---|---|---|---|---|
| `fm-brief.<home>` | `launch` | a launched task's `state/<id>.meta` | its `state/<id>.status` has a line | none | `accepted` 2h |
| `fm-corr.<home>` | `reply.<secondmate>`, one per local secondmate | a marked `fm-send` request (its `state/pending-replies/<corr>`), or an unmarked message in `state/<secondmate>.inbox/` | the pending reply is `resolved`, or the message moved to `handled/` | `unacked`, `reply-missed` (fix: the secondmate), `delivery-unknown` (fix: the sender) | `accepted` 24h, `held` 4h, `retry_limit` 1 |
| `fm-status.<home>` | `status.<secondmate>`, one per local secondmate | an open keyed `needs-decision` or `blocked` line in `state/<secondmate>.status` | the key is resolved | none | `accepted` 7d |
| `handoff-watch` (tooling-mate only) | one per home it sees | that home's watcher heartbeat | see [Watcher](#watcher-fm-handoff-watch) | none | not evaluated |

The existing tools stay the only writers of these records: `fm-spawn`, `fm-send` with `bin/fm-pending-reply-lib.sh`, `bin/fm-task-inbox-lib.sh`, and the status-append path.
The bounds are backstops behind that enforcement, not new limits: the pending-reply ladder already sends REPOST REQUIRED and escalates on its own clock, and the watcher only raises what that ladder has given up on, or what has sat open far longer than any ladder step.
A secondmate on another machine (a `(host: ...)` entry in `data/secondmates.md`) gets no stage yet.

**Adopting it.**
A home's owner runs `bin/fm-handoff-firstmate.py publish --home <home>` and then `bin/fm-handoff-watch.sh arm`, and runs `publish` again whenever a secondmate is added or retired; an unchanged publish writes nothing.
Tooling-mate's publish also declares each home's heartbeat folder, so it reruns `publish` when a home joins or leaves.

### Receipt adapters

A stage whose `ext` holds `<owner>.receipt-adapter` has no receipt files: the watcher calls that adapter in `bin/fm_handoff_adapters.py` instead of reading the outbox, and it skips the stage's `no-receipt` check, because the adapter reads the input place itself.
An adapter only reads; it turns each record's current state into one `handoff-receipt/v1` document whose `evidence` is the record file, and the watcher validates it like any receipt.
Each file is parsed once per size, inode and mtime, and the status fold runs once per changed status file, never once per line.
Such a stage's outbox may be the same folder as its input place, since nothing is written there.

| Adapter | Reads | Maps |
|---|---|---|
| `corr-request` | `state/pending-replies/<corr>` with that `task_id`, and the secondmate's inbox messages | `resolved` is `done`; an open ladder phase is `accepted`, attempt 2 once recovery was sent; `escalated` after delivery is `held` `reply-missed`; `escalated` with no delivery is `held` `delivery-unknown`; the message named in the inbox's `.escalated` is `held` `unacked` |
| `first-status` | each `state/<id>.meta` and its `state/<id>.status` | `accepted` at the meta's mtime until the status file is not empty, then `done` |
| `status-decisions` | `state/<secondmate>.status`, folded by `status_open_decisions` in `bin/fm-classify-lib.sh` | each open key is `accepted` at its line's `[at=]`; keys the pending-reply and handoff tools reserve are skipped |

An adapter name the watcher does not know raises `source-unreadable` on the stage's outbox path.
An incomplete or invalid adapter read retains the stage's earlier observations and alarms; it never treats unknown state as resolution.
A receipt returned for another protocol/stage, or a repeated record identity in one adapter result, is invalid.

#### Native observation adapters

These readers are selected by the same `<owner>.receipt-adapter` key, for example `tetjet-mate.receipt-adapter=native-tj-step`.
They observe native decisions, not a service's entire lifecycle: declaring its actor against a terminal output does not cover unobserved inputs, waits or failures before that output exists.
They never execute a native tool, read an artefact named inside a record, rehash results, write a checkpoint, or modify the native writer's files.
A native file in an ordinary outbox remains invalid; there is no format auto-detection or fallback adapter.

| Adapter | Native version -> receipt version | Record identity | Native outcome -> receipt |
| --- | --- | --- | --- |
| `native-tj-handoff` | `schema=tj-handoff/v1` -> 1 | Native `id`; REQUEST ACCEPTED/REFUSED instead share `request:<subject>:<full artefact.sums_sha256>` | REQUEST REFUSED and FAIL -> `refused` with `native-refused`; REQUEST ACCEPTED, PASS, READY FOR LAUNCH, READY FOR HELPER REVIEW, READY FOR KIT REVIEW, BATCH CUT, REQUEST ALL CUT, REQUEST SUPERSEDED, REQUEST WITHDRAWN and BATCH ABANDONED -> `done` for publication of that decision only, not its subject's launch or completion |
| `native-tetjet-collected` | `schema=tetjet-collected/v1` -> 1 | `batch:<batch_id>` for `tj-package`/`rolling-slice`; `request:<request_id>:<request_sha256>` for `request` | Batch `verification.verdict=PASS` -> `done` for verified collection, irrespective of experimental exits or incomplete labels; request `complete=true` with `outcome=collected`, `partly-withdrawn` or `withdrawn` -> `done`, preserving the outcome rather than calling withdrawal collection |
| `native-tj-step` | `schema=tj-step-receipt/v1` -> 1 | Native filename, which distinguishes invocations of one subject/phase | `rc=null` -> `accepted` from `started` (unknown outcome, not proof the child is alive); WAIT -> `held` `native-wait`; otherwise nonzero rc or REFUSE/FAIL/BLOCKED -> `held` `native-failed`; otherwise rc=0 -> `done` for wrapper completion only |
| `native-manifest-verified` | `schema_version=lattice-manifest-verified/v1` -> 1 | SHA256 of the JSON array `[item, manifest]` | `result=pass` -> `done` for the recorded verification, not verification of current bytes |
| `native-capacity-cursor` | Exact legacy unversioned `dev`, `ino`, `offset`, `tail` shape -> 0 | SHA256 of the JSON array `[absolute cursor path]` | A matching signal identity, in-range offset and matching checkpoint-tail SHA256 -> `done` at EOF, otherwise `accepted` while bytes remain, including an unfinished line; this proves stdout checkpointing, not downstream acknowledgement |

Unknown native versions, kinds, result words, malformed shapes and unsupported outcomes are `source-unreadable`, never ignored or mapped to the nearest version.
The step reader knows result words LAUNCH-STARTED, RELAUNCHED, FETCHED-VERIFIED, MOVED-ASIDE, UPLOAD-ONLY, DRY-RUN, READY-CHECK, REFUSE, FAIL, BLOCKED and WAIT, plus null.
A successful DRY-RUN, UPLOAD-ONLY or READY-CHECK is wrapper completion, never a launch.
The manifest writer emits only `pass`, and the collected batch writer emits only `PASS`; another result is a problem, not an invented refusal state.
The collector's `tetjet-queue-snapshot.v1` is reference label metadata (`jobs[].slice_id`), not a stage outcome, so it has no receipt adapter.
Native cursor format additions are unknown versions/shapes until explicitly supported.

**Observation bounds.**
Each stage reads only its declared input directory's top level, selecting `input.match` (default `*.json`), never recursing or following source symlinks.
Dot entries are skipped unless the match explicitly starts with a dot, so a `.pc-archive.VERIFIED.json` needs that explicit match and each collected `requests/` directory needs its own stage.
A declared missing or unreadable directory is a problem, not an idle success.
At most 4096 matching entries and 1 MiB per JSON record are admitted, with at most 16 MiB of changed JSON reads per stage per pass; excess is a reported source problem and retried on later ticks, not silent truncation.
Every retained selected record is considered regardless of age.
JSON parsing and mapping (including errors) are cached by inode, size, mtime and ctime; the cache stores only small mapped observations, not whole native documents.
The cursor reader requires `input.match` to name one exact `.cursor.json` file (no glob), reports its absence as a problem, and reads only its sibling `.signal`, checking identity and size each pass and at most 256 bytes immediately before the offset.
A nonzero checkpoint must follow a complete newline-terminated signal line.
A missing, rotated, truncated or digest-mismatched signal requires the native writer's replay and is a problem until then; the adapter never resets it.

**Coordinates, timing and gaps.**
These are current-state observations, not an immutable receipt history: attempt is 1, seq is 1 for accepted and 2 otherwise, and receipt ext `<owner>.native-attempts-known=false` explicitly says native retries are not observed.
The mandatory fragment `retry_limit` and bounds must be the owner's observation alarm policy, never a claim that an absent native limit exists.
Keeper DEFER_S and ROOM_S are repeated recheck intervals, not maximum waits or retry counts, and none of these readers covers keeper logs, liveness state, ledger wait journals, fetch receipts or archive progress state.
A step WAIT without an explicit native deadline is held, not waiting with an invented `until`.
Receipt times come from handoff `created_at`, collection `recorded_at` (not an older backfill's `verified_at`), step `started`/`ended`, manifest `verified_at`, or cursor mtime.
The source file is always the evidence; native outcome remains in detail and `<owner>.native-outcome` ext.
Native refusal/hold codes must be declared in the fragment, whose code entry alone supplies routing and lane scope.
For shared request decision identities the latest native timestamp wins; conflicting states at the same timestamp are a problem because filename ordering cannot prove decision order.
Other duplicate identities are problems.

**Retention.**
Queue and collection outputs are write-once, step pending records are replaced at completion, and manifest/cursor records expose only the current replacement.
Pruning an observed unresolved record reports a source problem and retains its last observation without a TTL; pruning a terminal record drops it from the adapter cache.
An adapter attached after records were pruned cannot reconstruct them, and an unseen transition cannot be inferred from disappearance.
The one native writer must keep unresolved records and allow a watcher pass to observe terminal transitions; otherwise historical coverage is explicitly incomplete.
The regression entry point is `tests/fm-handoff-firstmate.test.sh`, including its native cases and the sanitized native verification probe fixture.

## Compatibility and versioning

### Closed fields

Every object in both formats is closed: a field this document does not define is a finding, so a misspelled field cannot silently do nothing.
A reader that meets an unknown `format` value refuses the file and raises `source-unreadable`; it never ignores it.

### Extensions and unknown fields

Information a home needs beyond the closed fields goes in `ext`, which the fragment top level, protocols, stages, code entries, dated rules and receipts all allow.
An `ext` key is `<home>.<name>`, owned by the home before the dot; a home writes only keys under its own name.
An `ext` value is a string, number or boolean, so `ext` reads as `key=value`.
Readers ignore every `ext` key they do not know, the rule the merge queue's HANDOFF and RESULT receipts already follow.
Firstmate's watcher reads one stage key, `<owner>.receipt-adapter`, which names the [receipt adapter](#receipt-adapters) that reads the stage's records.
One key is read by Firstmate itself: a stage's `<home>.loop-source` declares loop-view sources for that home's `bin/fm-loop.sh`, in the format [docs/configuration.md](configuration.md#loop-sources-configloop-sources) gives.

### Versions

- The format version is the major in `format`.
  Adding, removing or retyping a closed field, or changing what one means, is a new major (`handoff-registry/v2`) with its own schema file.
- Readers move first: every reader accepts the new major before any writer writes it.
  Information that can wait for the next major goes in `ext` until then.
- Record versions follow the same rule inside a protocol (I8).
  A stage's `writes` must fall inside the next stage's `accepts`: a writer version is admitted only when its reader declares it, and a reader raises `accepts.min` only when its writer no longer writes older versions.
  `bin/fm-handoff-validate.py fragment` refuses a chain that breaks this.
- A record whose version a stage does not accept is refused at that stage with `version-unsupported`, so the change is refused at the first stage with a receipt rather than drifting downstream.

## The new pipeline under this protocol

Each seam of the new pipeline lands in these fields; `examples/xp-chain.fragment.json` shows S1-S9.

| Seam | Stage (owner) | Where it lands |
|---|---|---|
| S1 | filing (lattice-research-mate) | stage `filing`; each `filing_check` finding code is a code with its own `fix_owner`; the capability publisher is a named stage with an owner, and `capability-unpublished` routes to it |
| S2 | compile, submit (research), READY (tetjet-mate) | one stage each; READY refusals are a `ready-refused:*` family routed by code |
| S3 | offer, scheduler intake (tetjet-mate) | `offer-refused:*` is `held` with `retry_limit` and `bounds.held`; `intake-*` has `holds_all: true` and `stops` |
| S4 | admission and lease, `xp-start-authority/v1` (tetjet-mate) | `waiting` receipts whose `reason` names the constraint and whose `until` is inside `bounds.waiting` |
| S5 | kind execution, `lattice-kind/v2` (tetjet-mate, kind authors) | `accepts` declares the kind versions the runner reads; filing refuses a newer version with `version-unsupported` until it does |
| S6 | attempt receipt and reaper (tetjet-mate) | `reap-refused` has `holds_all: true` |
| S7 | phase D arrival (tetjet-mate) | refusal codes routed to the producer; room waits are `waiting` with `reason` `room:<volume>:<class>` |
| S8 | collect and audit (research) | stage `collect`, which is also `cleanup.stage` |
| S9 | reconciler, not installed | `planned: true` until installed; `undeclared-actor` reports it if it is installed without being declared |
| Cutover records | `xp-cutover-record/v1`, `xp-started-lines/v1`, `xp-release-set/v1`, `xp-route-schedule/v1` | each a protocol with its own chain; `xp-started-lines` gets a `waiting` bound |
| Adapters | old-to-new adapters | each a stage with an owner; its receipts count its use, and its retirement is a dated rule |
| Tool alarms | TETJET liveness (`tj-idle`, `tj-lane-refused`, `tj-capacity-unread`) | entries in the alert store |
| Workbench | lattice-mate readers of research outputs | stages whose `accepts` declares the versions they read; unknown input is refused with `version-unsupported` |
| Firstmate | briefs, `fm-send` corr requests, status lines (each home; the `handoff-watch` heartbeat is tooling-mate's) | protocols whose stages adapt the existing records (REPOST REQUIRED, keyed lines); see [Firstmate's own handoffs](#firstmates-own-handoffs) |

Reused blocks land here:

- the `tj-capacity-alerts/v1` alert-file shape becomes `fm-alert-store/v1` ([docs/alert-store.md](alert-store.md));
- the launch-check rule that every undecided outcome is an alert becomes `source-unreadable` and the refusal of an unknown `format`;
- ap-v2.1's per-id alarm after a threshold, where every hold names what it stops, becomes `retry_limit` with `open-past-bound`, and `stops`;
- the merge queue's receipts, whose readers ignore unknown `key=value`, become the `ext` rule;
- `xp-route-schedule/v1`, with alarms at 14, 7 and 1 days and escalation after two slips, becomes `dated-rule-schedule/v1` rows linked from `dated_rules` ([what does not map](dated-rule-schedule.md#what-xp-route-schedulev1-keeps)).

## Open points owners must settle

- **Cross-home stage declarations.** A protocol owner declares stages that other homes own, and the stage owner need not confirm them: the owner's watcher checks every stage declared with its home as owner, so a wrong declaration shows as `no-receipt` to that owner.
- **Refusal closure.** A later attempt closes a refusal for good; an alert-store acknowledgement closes it only until its `until`, at most 7 days for every code ([Watcher](#watcher-fm-handoff-watch)).
- **Alarm keys and store ids.** Settled in [Alert store](#alert-store).
- **Fragment discovery.** A home on another machine is read through a synced copy listed in `config/handoff-homes` ([Watcher](#watcher-fm-handoff-watch)).
- **Record ids across stages.** The chain assumes one stable `record` id from filing to collect; a stage that renames records records the old id in `ext` until its owner settles a field for it.
