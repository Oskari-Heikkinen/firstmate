# Handoff coverage protocol (handoff-coverage/v1)

A handoff is any record that crosses a home, machine or process boundary: an experiment request, a result pack, a cutover record, a brief.
`handoff-coverage/v1` makes every handoff covered by construction.
Each artifact type is a registered protocol with an ordered chain of stages, every stage writes a receipt for every decision, and a watcher in every home joins the two to alarm on anything that is refused, stuck, unread or undeclared.

This document owns three formats and the rules that bind them:

- `handoff-registry/v1`, the fragment in which a home declares the protocols it owns ([Registry fragment](#registry-fragment-handoff-registryv1));
- `handoff-receipt/v1`, one stage's outcome for one record ([Receipts](#receipts-handoff-receiptv1));
- the alert store the coverage checks raise into, which generalises `tj-capacity-alerts/v1` and whose format is owned by its own document ([Alert store](#alert-store)).

The machine-checkable schemas are `docs/handoff-coverage/handoff-registry-v1.schema.json` and `docs/handoff-coverage/handoff-receipt-v1.schema.json`.
`bin/fm-handoff-validate.py` checks files against them plus the cross-field rules a schema cannot express; its header owns the commands and exit codes.
Worked examples are in `docs/handoff-coverage/examples/`, and every one of them validates in CI (`tests/fm-handoff-coverage.test.sh`).
The skill `.agents/skills/handoff-coverage/SKILL.md` tells an agent when it must publish a fragment or write receipts.

The watcher that reads these files (`fm-handoff-watch`), the shared installer check and the dated-rule schedule are later work items.
This document fixes what they read; it does not specify how they run.

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
| Alerts | the alert store (see [Alert store](#alert-store)) | the watcher | the status-line projection, the routed homes |

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
| `outbox` | outbox | yes | where its receipts go; never the same folder as any input place |
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
| `id` | name | yes | unique within the protocol |
| `owner` | home | yes | the home that alarms are routed to and that moves the date |
| `date` | `YYYY-MM-DD` | yes | the UTC date the rule takes effect |
| `what` | text | yes | what happens on that date |
| `ext` | extensions | no | |

`dated-rule` alarms the owner 14, 7 and 1 days before `date` and every tick after it while the row stays.
Moving a date is a new fragment revision with the new date.

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
| `undeclared-actor` | a user timer, service, cron job or Firstmate custom check is running that no stage lists in `actors` | `actors` | tooling-mate and the installing home |
| `dated-rule` | a dated rule is 14, 7 or 1 days out, or past its date | `dated_rules` | the rule's `owner` |
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

## Alert store

The coverage checks raise their alarms into the shared alert store, which generalises `tj-capacity-alerts/v1` (active entries, an event list and a revision) into level-asserted alarms (I5).
Its format, location and acknowledgement rules are owned by its own document and are not repeated here.

## Compatibility and versioning

### Closed fields

Every object in both formats is closed: a field this document does not define is a finding, so a misspelled field cannot silently do nothing.
A reader that meets an unknown `format` value refuses the file and raises `source-unreadable`; it never ignores it.

### Extensions and unknown fields

Information a home needs beyond the closed fields goes in `ext`, which the fragment top level, protocols, stages, code entries, dated rules and receipts all allow.
An `ext` key is `<home>.<name>`, owned by the home before the dot; a home writes only keys under its own name.
An `ext` value is a string, number or boolean, so `ext` reads as `key=value`.
Readers ignore every `ext` key they do not know, the rule the merge queue's HANDOFF and RESULT receipts already follow.

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
| Firstmate | briefs, `fm-send` corr requests, status lines (tooling-mate) | protocols whose stages adapt the existing receipts (REPOST REQUIRED, keyed lines) |

Reused blocks land here:

- the `tj-capacity-alerts/v1` alert-file shape becomes the [alert store](#alert-store);
- the launch-check rule that every undecided outcome is an alert becomes `source-unreadable` and the refusal of an unknown `format`;
- ap-v2.1's per-id alarm after a threshold, where every hold names what it stops, becomes `retry_limit` with `open-past-bound`, and `stops`;
- the merge queue's receipts, whose readers ignore unknown `key=value`, become the `ext` rule;
- `xp-route-schedule/v1`, with alarms at 14, 7 and 1 days, becomes `dated_rules`.

## Open points owners must settle

- **Cross-home stage declarations.** A protocol owner declares stages that other homes own; whether a stage owner must also confirm its stages in its own fragment is for tooling-mate and the stage owners to settle with the watcher work.
- **Refusal closure.** A later attempt or an alert-store acknowledgement closes a refusal; whether an acknowledgement needs an expiry per code is for the alert store's owner.
- **Dated-rule slips.** Moving a date is a new revision; whether a slip needs a review step, as `xp-route-schedule/v1` does, is for the schedule work.
- **Fragment discovery.** Every home's watcher reads the fragments of every home on its machine; how it finds homes on another machine, if any are added, is for the watcher work.
- **Record ids across stages.** The chain assumes one stable `record` id from filing to collect; a stage that renames records records the old id in `ext` until its owner settles a field for it.
