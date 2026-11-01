# Owner notices

`fm-owner-notice/v1` carries one notice per key from a producer process to the owner home that bound it.
The producer writes an envelope into an outbox it owns, the owner takes custody of the exact bytes and writes a receipt, and the producer reads the receipt to learn the answer.
A receipt means the owner holds the notice; delivery is not consumption or acceptance.
This document owns the protocol, the formats, the state layout, the answer table, the exit codes, the lock order, the crash table, retention, the trust assumption and the test seams.
[`bin/fm-owner-notice.sh`](../bin/fm-owner-notice.sh) is the owner front and its header owns the owner commands; [`bin/fm-owner-notice-client.py`](../bin/fm-owner-notice-client.py) is the producer client and its docstring owns the producer commands.
[`bin/fm_owner_notice_format.py`](../bin/fm_owner_notice_format.py) holds the shared formats and durable I/O, and [`bin/fm_owner_notice_store.py`](../bin/fm_owner_notice_store.py) is the owner engine.
The `owner-notice` skill says when agents run each command.

## Scope of this version

This version includes the protocol core and owner automation.
A healthy owner watcher starts a singleton runner when active or straggler bindings exist; `fm-owner-notice.sh ingest <id>` remains available for a bounded manual pass.
It runs on Linux only, because process identity, the parent-death signal and the filesystem check read `/proc`.

## Files and sides

| File | Side | Role |
|---|---|---|
| `bin/fm_owner_notice_format.py` | shared | Canonical JSON, the key and id grammars, the deterministic envelope, the binding, receipt and config schemas, process identity, the durable I/O primitives and the test seams; standard library only |
| `bin/fm-owner-notice-client.py` | producer | `submit`, `query`, `pending`, `prune`; imports only the format module |
| `bin/fm-owner-notice.sh` | owner | Takes the locks, runs the engine, appends and fsyncs the wake, repairs the binding lists and syncs the alert store |
| `bin/fm_owner_notice_store.py` | owner | The engine: `bind-inspect`, `bind`, `stage`, `ingest-staged`, `reconcile`, `consume`, `ack-refusal`, `ack-vanished`, `retire`, `purge`, `show`, `list`, `alarms`, `status`; it mutates only under a lock its parent holds |
| `bin/fm-handoff-actors.py` | owner | `valid-actor <actor>` checks a producer actor against the one actor grammar, `ACTOR_RE` |

## Owner state layout

Everything lives under `<owner>/state/owner-notices/`.

| Path | Writer | Content |
|---|---|---|
| `bindings/<id>.json` | `bind` | The immutable binding, created exclusively and kept forever, so ids stay reserved |
| `bindings/<id>.retiring` | `retire` | Created in retire phase 1 and removed if retire refuses |
| `bindings/<id>.retired` | `retire` | Created in retire phase 2 and never deleted |
| `.bindings.list` | front | Active bindings, one `<id>\t<outbox>` per line, rebuilt from `bindings/*` under the bindings lock |
| `.retired.list` | front | Retired bindings in their straggler window, `<id>\t<outbox>\t<retired_at>` |
| `.bindings.lock/`, `.runner.lock/`, `<id>/.lock/`, `.alarm-sync.lock/` | front | Mutation, runner-lifetime and independent alarm-projection locks of the shared bounded lock helper |
| `.runner-attempt`, `.runner-starting/`, `.runner` | watcher, front | Attempted-start history, starting identities and the installed runner (see Attempted-start history) |
| `.runner-beat` | runner | `pid`, `starttime`, `epoch` and `attempt`; optional `drained=yes` witnesses a complete successful final projection after demand withdrawal |
| `.runner-respawns` | watcher via engine's durable writer | Consecutive pre-beat failures and last exit code; mtime anchors respawn backoff across watcher restarts; bounded single-line reader rejects partial, oversized, NUL-containing or nonregular records |
| `<id>/.children` | runner | Lines `role pid starttime pgid started_at run`, one per stat, stage or ingest child; durable before release |
| `.children` | runner | The same record for the independent home-wide alarm-projection child; the next runner reads it for adoption, so all blocked bindings cannot mute their own stalls |
| `.stall` | runner | Projection failure/stall occurrence; runner recovery reads it, and the watcher health reader treats it as an automation failure even with fresh loop beats |
| `<id>/.stall` | runner | Lines `role since run`, for `stat`, `fg`, `stage` or `ingest`; first occurrence retained until that role completes |
| `<id>/.automation` | runner | `busy` and `failures` maps keyed by owning work role; independent counters/reasons and first occurrence epochs |
| `.quarantine` | runner | Scope-to-`{reason,since}` map for `binding:<id>`, `routing`, `foreground`, `projection`; shared reader supplies owner-side diagnosis and first occurrence until revalidation |
| `<id>/.seen` | runner | Last fully processed outbox `mtime_ns` outside the timestamp slack |
| `<id>/.beat` | runner | `writer=runner`, epoch, runner/watcher identities, attempt token, outbox mtime and first `dirty_since` (or `-`) |
| `<id>/.retention-at` | runner maintenance | Last completed daily retention epoch |
| `runner-alert-store.json` | watcher | `owner-notice-runner` progress and respawn levels |
| `.fg-children/<pid>-<starttime>` | front | One record per bounded outbox child of `bind`, `retire` or `ingest`, created before the child is released |
| `alert-store.json` | front | The `owner-notice` alert store (see Alarms) |
| `<id>/custody/<key>.notice` | engine | The exact validated envelope bytes |
| `<id>/handled/<key>.notice` | engine | Consumed custody |
| `<id>/receipts/<key>/<seq>.json` | engine | Append-only receipts; the outcome is inside the file |
| `<id>/.live-keys` | engine | Required bounded live-obligation membership (see Live membership), published before the first receipt |
| `<id>/current/<key>.json` | engine | Validated flat current-state projection, written as `pending` before the first receipt; membership lets reconcile discover a missing file |
| `<id>/archive/<yyyy-mm>/<key>.json` | engine | `current/` entries moved out by retention |
| `<id>/.announced/<key>` | front | Created after the key's wake row is durable |
| `<id>/.acked/<key>` | engine | Created by `ack-refusal`; it takes the key's refusal levels out of the wanted set |
| `<id>/.ingest-cache` | engine | Outbox `(name, inode, ctime_ns)` entries already processed; a pure cache, rebuildable from `current/` |
| `<id>/.outbox-index` | engine | `fm-owner-notice-outbox-index/v1` (see Outbox index) |
| `<id>/.outbox-status` | engine | The last stage's refusal code and backlog flag with their first `since` |
| `<id>/.tmp/<run>/` | stage child | Staged envelope copies and `manifest.json`; removed by `reconcile` once the stage identity is gone |
| `<id>/log` | front, engine | One plain line per event: UTC time, what, why, next; rotated at 1 MiB, keeping 4 |

`bind` creates `<id>/` and `custody/`, `handled/`, `receipts/`, `current/`, `archive/`, `.announced/`, `.acked/` and `.tmp/`, an explicit empty live inventory and a healthy empty last-stage status record, durably before it publishes the binding.

## Producer layout

The outbox is a directory the producer owns, named absolutely in the binding.
It holds `<key>.envelope.json`, `.tmp/` with per-call temp files named `<pid>-<starttime>-<rand>`, and `.receipts/<key>.json`, the producer's copy of the owner receipt it verified.
Ingest never reads dot entries.

## Binding

`fm-owner-notice.sh bind` writes `fm-owner-notice-binding/v1` with these fields:
- `binding_id`, matching `[a-z0-9][a-z0-9._-]{0,127}`;
- `recipient_home`, from the `.fm-secondmate-home` marker or `main`, never from input;
- `owner_home_path`, the realpath of the owner `FM_HOME`, and `machine_id`, from `/etc/machine-id`;
- `producer_actor`, which `bin/fm-handoff-actors.py valid-actor` must accept, and `producer_uid`;
- `outbox`, `outbox_dev` and `outbox_ino`;
- `kinds`, `max_bytes` (at most 65,536) and `consume_bound_seconds` (required);
- `envelope_versions: [1]`, `receipt_versions: [1]` and `created_at`.

`binding_sha256` is the canonical digest of the record, and `bind` prints it.
The outbox is inspected in a bounded child with no lock held (see Bounded failure); the bindings lock is taken only afterwards, to record the device and inode that child found, and every stage re-checks them.
`bind` refuses with exit 65 and one of these codes:
- `outbox-overlaps-owner`: the outbox is, is inside, or is an ancestor of `state/owner-notices/`, or is an ancestor of `state/`;
- `outbox-not-directory`, `outbox-symlink` (by `lstat`), `outbox-owner` (not owned by `producer_uid`);
- `outbox-filesystem`: the type mountinfo gives for its device is not ext4, xfs, btrfs, tmpfs or overlay, or cannot be read;
- `actor-invalid`, `binding-conflict` (the id exists with other fields) and `binding-retired`.

Identical fields on a live id are a replay that prints the same digest.
The binding file is created exclusively; on `EEXIST` it is compared, never replaced.

The producer's client config (`fm-owner-notice-client-config/v1`) pins `binding_id`, `binding_sha256`, `recipient_home`, `owner_home_path`, `machine_id`, `producer_actor`, the outbox and the client closure digests.
It names no receipts path: the client derives every owner path from `owner_home_path` and `binding_id`.
An unknown config field is a usage error, exit 2.

## Envelope

`fm-owner-notice/v1` is canonical JSON with `schema`, `binding_id`, `binding_sha256`, `notice_key`, `kind`, `payload_sha256` and `payload_b64`.
It carries no timestamp, so its bytes are a pure function of the binding, key, kind and payload, and the client can recompute `envelope_sha256`.
`notice_key` uses the id grammar, the file name must be `<notice_key>.envelope.json`, and idempotency compares `payload_sha256` plus `kind`.
Canonical means sorted keys, no whitespace, no duplicate keys, and bytes equal to their own canonical form.

## Receipts

Each receipt is `receipts/<K>/<seq>.json`, created exclusively, so the file name alone keeps seq unique.
`seq` is one more than the highest present, allocated under the binding lock; on `EEXIST` the engine lists again and retries once, and a second `EEXIST` is 70 `seq-collision` with its alarm.

Every receipt carries `schema` (`fm-owner-notice-receipt/v1`), `seq`, `outcome`, `binding_id`, `binding_sha256`, `recipient_home`, `owner_home_path`, `machine_id`, `producer_actor`, `notice_key`, `recorded_at` and `note` ("Delivery is not consumption or acceptance.").

| `outcome` | Extra fields | Meaning |
|---|---|---|
| `delivered` | `kind`, `payload_sha256`, `envelope_sha256`, `envelope_bytes` | The owner holds exactly these bytes; the digests come from the custody bytes read back after their fsync |
| `consumed` | `kind`, `payload_sha256`, `envelope_sha256`, `delivered_seq` | The owner consumed the delivered receipt `delivered_seq` names, which must exist with equal digests |
| `refused`, `scope: "digest"` | `code`, `kind`, `payload_sha256`, `envelope_sha256` | A parsed, digest-verified envelope was refused: `key-conflict`, `kind-not-allowed`, `binding-mismatch` or `version-unsupported`; final for that key and digest |
| `refused`, `scope: "key"` | `code`, and `envelope_sha256` when bytes were read | No verified digest: `unsafe-file`, `oversize`, `malformed`, `digest-mismatch`, `name-key-mismatch` or `binding-retired`; final for the key, whatever digest a later query names |

A key-scoped refusal can never be undone: a producer whose key is deterministic recovers under a new binding id.

## Commit boundary

Every exclusive create on either side (an envelope, a producer record, custody, a receipt, a binding, a marker) writes its bytes to a temp in that side's `.tmp/`, fsyncs it, links it to its name, fsyncs the name's directory, and only then unlinks the temp, which is the commit; the temp's directory is fsynced after.
So a single-link name is always one whose directory entry is durable.
Until the commit the name has two links, and its other link is the publisher's temp: a reader that finds that temp treats the name as in progress, never as unsafe and never as an answer.
If temp lookup finds nothing, the reader revalidates the same opened inode once: a now-single-link inode committed during lookup and is safe to read; a remaining extra link is foreign and stays `unsafe-file`.
An error inspecting the temp directory or an entry is unknown publication state (`in-progress`), never evidence of a foreign hardlink.
A publisher killed before its commit leaves its temp linked; the next call on that side finishes it by fsyncing the directory that holds the name and then unlinking the temp, so the commit is never taken before the name is durable.
A directory created on the way is fsynced into its parent on every call, so an interrupted parent fsync is finished by the next one.

## The answer function

`submit` and `query` answer from one function over the caller's key K, kind T and payload digest P, and what it reads.
Rows are checked in order and the first match wins; R means the binding is retired or retiring.

| # | Condition | State | Exit |
|---|---|---|---|
| 1 | The config, the binding file or the owner `state/` is missing, unreadable or unmapped | `unavailable` (names the path) | 69 |
| 2 | The owner tree is writable from this process, or protected only by mode bits | `unavailable` `owner-tree-writable` / `owner-tree-writable-by-mode` | 69 |
| 3 | The binding does not hash to the pin, or names another home path, machine, actor or outbox | `unknown` `binding-mismatch` | 70 |
| 4 | R, and `<id>/receipts/` is missing (purged) | `unknown` `binding-retired` | 70 |
| 5 | Not R, and `receipts/` or the outbox is missing, unreadable or unmapped | `unavailable` (names the path) | 69 |
| 6 | `receipts/K/` is unreadable, or a receipt there is malformed, of an unaccepted version, misnamed, names another identity field or an `envelope_sha256` that is not the deterministic envelope's, or is a `consumed` receipt with no matching `delivered_seq`; or a receipt for (P, T) whose envelope digest cannot be verified (`envelope-unverifiable`) | `unknown` | 70 |
| 7 | A `delivered` receipt for (P, T) and a `consumed` receipt for it | `consumed` | 0 |
| 8 | A `delivered` receipt for (P, T) | `delivered` | 0 |
| 9 | A key-scoped `refused` receipt | `refused` with its code | 65 |
| 10 | A `delivered` receipt for another digest | `key-conflict` (names both digests) | 65 |
| 11 | A digest-scoped `refused` receipt for (P, T) | `refused` with its code | 65 |
| 12 | A digest-scoped `refused` receipt for another digest only | `key-conflict` | 65 |
| 13 | No committed receipt answers, and a receipt is not yet committed or the outbox envelope for K is (P, T) | `pending` | 75 |
| 14 | No receipt; the outbox envelope for K is another digest | `key-conflict` | 65 |
| 15 | No receipt; the outbox envelope is unreadable or not a regular file | `unknown` | 70 |
| 16 | No receipt, no envelope, and R | `unknown` `binding-retired` | 70 |
| 17 | No receipt, no envelope, and `.receipts/K.json` exists | `unknown` `owner-record-missing` | 70 |
| 18 | No receipt, no envelope, no producer record | `absent` | 3 |

Rows 7 and 8 come before the refusal rows, so a later conflicting refusal never hides the caller's own delivery.
A receipt still in progress (see "Commit boundary") is never an answer, so rows 7 to 12 read only committed receipts.
The envelope digest is checked against the deterministic envelope the client rebuilds from the payload; with `--payload-sha256` the client takes the payload from its own outbox envelope when that envelope matches (P, T), and otherwise accepts only a receipt byte-equal to its own `.receipts/K.json`, so a digest-only query never answers 0 from an unverified receipt.
A digest-scoped `binding-mismatch` or `version-unsupported` refusal hashes the rejected envelope, which the client cannot rebuild, so its `envelope_sha256` is not checked and it answers row 11 or 12.
When R holds and the outbox is missing, rows 13 to 15 read it as no envelope.
`absent` means only that there is no record here, never proof of never-sent.

## Producer commands

`submit` checks rows 1 to 3, reads the payload once (at most `max_bytes`), and answers from rows 4 to 12 and 17 when any applies, creating nothing.
On a retired or retiring binding it exits 69 `binding-retired` before any create.
Otherwise it publishes `K.envelope.json` as "Commit boundary" says; on `EEXIST` it answers from rows 13 to 15, waiting up to 5 s for an envelope still in progress and answering `pending` after that.
`created: true` in its output means this call's link made the envelope.
A stale temp is removed only when the pid and start time in its name no longer name a live process.
When a receipt answers rows 7 to 11, the client records the verified receipt bytes in `.receipts/K.json` exclusively; an existing copy that differs is 70.
`--wait-seconds N` (at most 120) polls `receipts/K/` once a second until the answer is no longer `pending`.

`query` applies the table and records as `submit` does, and never creates an envelope or a receipt.
`pending` lists every outbox envelope without a `delivered` or `consumed` receipt for its own digest.
`prune --key K` (or `--all-recorded`) unlinks an envelope only when `.receipts/K.json` verifies against its digest, and refuses with 65 `not-recorded` otherwise; it never touches owner files.
`pending` lists an envelope still in progress as `pending`, and `prune` answers 75 `pending` for it (`--all-recorded` keeps it), after the same 5 s wait.

## Ingest

Ingest has two halves: a stage that alone touches the outbox and holds no lock, and `ingest-staged`, which holds the binding lock and touches only owner files.

The stage runs in a bounded recorded child:
1. It opens the outbox with `O_DIRECTORY|O_NOFOLLOW`; a symlink is refused as `outbox-symlink`, a device and inode other than the binding's as `outbox-identity-changed`, a filesystem off the allowlist as `outbox-filesystem`, and any other failure as `outbox-unreadable`.
2. It records the outbox `mtime_ns`, lists it on the fd skipping dot entries, and skips entries whose `(name, inode, ctime_ns)` from an `lstat` on the fd is in `.ingest-cache`.
   The ctime is part of the key because a removed envelope's inode is often reused by its replacement, and only an entry whose ctime is more than 2 s older than the listing, by the filesystem's clock, enters the cache, so a replacement within the same clock tick is never skipped.
3. It takes new entries oldest first by `(mtime_ns, name)`, at most 256 per run, and copies each with a no-follow, bounded, regular-single-link read; a non-regular entry is recorded as `unsafe-file` and an over-cap one as `oversize`, with nothing read.
An entry whose second link is the producer's uncommitted temp is `in-progress`: it gets no receipt and is not cached, so a later run takes it once the producer commits.
An entry still in progress 60 s after its link, by the filesystem's clock (its ctime), is recorded as stuck and raises `outbox-in-progress`; it is still never refused.
4. It writes `manifest.json` with the full name list, the per-entry results, the `cap_hit` and `backlog` (more than 4,096 names) flags, and its own identity.

A stage refusal is recorded in `<id>/.outbox-status`, and `ingest` exits 65 with that code.

`ingest-staged` validates each staged copy: canonical JSON, name against key, binding id and digest, kind, version, the decoded payload size and the payload digest.
Each failure is a refusal of the scope the receipts table gives.
It then routes by the receipts already present for the key, which is the only place that decides whether custody may be touched:
- a key-scoped refusal, or a `delivered` receipt for the same digest, is a replay and writes nothing new;
- a `delivered` receipt or only refusals for another digest gives a digest-scoped `key-conflict` refusal, and custody is not touched;
- no receipt goes on to custody.

Custody is created exclusively from the validated bytes; on `EEXIST` equal bytes go on and different bytes are replaced durably.
The engine reads custody back after its fsync; when the bytes differ from the validated ones it writes no receipt and raises `custody-mismatch:<K>`, so the next run replaces custody.
Otherwise it writes the `delivered` receipt from the read-back bytes, then updates `current/K.json` and `.ingest-cache`, which after a complete listing also drops the names the listing no longer holds.
After the entries it writes the outbox index, runs `reconcile` and applies retention, and the front then announces.

## Live membership

`<id>/.live-keys` is canonical `fm-owner-notice-live/v1` with exactly `schema`, `binding_id` and `keys` (sorted unique valid key strings).
It is owner-local membership evidence, not a receipt or acceptance authority; the shared format validator owns its parsing for all readers.
The read and write limit is 16 MiB; reaching it refuses new membership with 70 `membership-full` rather than truncating the set.
Missing, unreadable, non-regular, oversized or invalid membership is 70 `membership-unreadable` on mutation and an incomplete alarm snapshot, never an empty inventory or an automatic rebuild.
An empty inventory explicitly created by a new bind is healthy.
A bind replay validates the existing layout and live sources read-only under the bindings lock, never reinitializes missing membership or recreates missing directories while its binding exists, and never reaps that binding's temps without its lock.
An existing pre-inventory binding must be explicitly migrated or its verified inventory restored before use.
When the binding is missing, `bind` refuses with 70 `unknown-surviving-tree` unless the owner tree is absent or provably pristine: only empty standard directories, optional validated empty membership and an optional initial empty outbox-status record.
Any surviving receipt, projection, custody, archive, acknowledgement, temp or unexpected record, or an unreadable/nonregular layout, prevents reinitialization even if the inventory is missing.
This check reads only the fixed layout and at most one child per directory, not receipt history.
A surviving tree needs verified restoration or explicit bounded restartable inventory repair, never implicit `bind` recovery.
This uninstalled core does not automatically migrate older homes or scan receipt history to repair membership.

Under the binding lock, an initial projection is durable before membership, which is durable before a key's first receipt or problem record.
Every locked engine context preflights the union of live members and current filenames before any custody change, receipt append, acknowledgement, announce, retention or retirement decision, including replay and direct-engine entry points.
It requires real current and receipt root directories, valid projection filenames and records, and each final projection's supporting receipts, without enumerating lifetime receipt keys or archives.
A final projection must still be witnessed by its named receipt and any delivery predecessor or conflict refusal it records; nonempty but inconsistent partial history is unknown too.
A valid crash-stale projection may lag newly appended receipts, and a genuinely initial pending projection needs no receipt yet.
A missing live-member projection or an invalid existing projection refuses mutation: a problem and its timestamp can exist only there, so rebuilding from receipts alone could silently lose an obligation.
Restore verified projections and receipt history before retrying; neither a staged replacement envelope nor remaining receipts authorize reconstruction of lost final truth or problem history.
Reconcile then refreshes valid stale projections from receipts.
A crash between initial projection and membership leaves a discoverable valid pending record; a crash between membership and receipt leaves that same valid record, so both replay without treating unknown state as empty.
A missing required directory is unknown and must be restored, not silently recreated as empty.

Retention judges refreshed receipt truth, not a crash-stale terminal projection, and removes membership only after the key is announced, consumed or refusal-acknowledged, its retention period elapsed, and its terminal archive is durable.
Any remaining refusal/problem also requires its acknowledgement.
Archive publication copies the validated record rather than hardlinking it, so a crash cannot make the current file fail the single-link reader.
Membership removal precedes current unlink; a crash between them leaves an extra current file that replay can safely archive again.
Alarm snapshots compare current files against the live inventory, read only each live/current key's receipt directory and never enumerate lifetime receipt keys or archive months.
A snapshot racing a mutation can conservatively report an incomplete set; the next ordered snapshot repairs it.

## Outbox index

`<id>/.outbox-index` is written only from a complete stage manifest, and an incomplete one leaves the previous index in place.
Each `*.envelope.json` name keeps its first-seen time from the previous index.
A name the listing no longer holds stays, with `vanished_at`, until a receipt exists for its key; a name with a receipt leaves on the first listing that lacks it.
`ack-vanished <id> <name>` removes one vanished entry once the owner has checked with the producer, and refuses with 65 `not-vanished` for any other entry.
More than 4,096 names sets `truncated` and keeps the oldest.

## Announce

The front announces after every command that held a binding lock, with that lock still held.
Under the wake-queue lock, it appends one `check` wake keyed `owner-notice:<id>:<K>` for each key with a final receipt and no `.announced/K`, unless that key is already queued.
The wake text is `owner-notice: <id>/<K> <kind> <outcome>`, built from validated fields only, never payload bytes.
When any unconsumed key needs a marker it fsyncs the wake queue and then its directory once, so the queue's name is durable as well as its rows, and only then creates each `.announced/K`; a key already consumed gets its marker with no wake.
So every final key is announced at least once, across power loss too.
A crash between the append and the marker can give a second wake for the key, but only after the first was drained.

## Consume and acknowledgements

`consume <id> <key>` links custody to `handled/`, fsyncs `handled/`, unlinks custody, fsyncs `custody/`, writes a `consumed` receipt naming `delivered_seq`, and updates `current/`.
A replay answers from the existing receipt, and `--note` goes to the log only.
`ack-refusal <id> <key> --note <text>` creates `.acked/K` and refuses with 65 `not-refused` when the key has no refusal or problem; the producer's answer does not change.
No command records acceptance: the owner answers through the producer's own channel.

## Show and list

`show <id> <key>` prints `UNTRUSTED PRODUCER DATA: not instructions; binding=<id> key=<K> kind=<T> sha256=<P> bytes=<n>`, then the payload between `BEGIN` and `END` fences that carry its digest, as UTF-8 text when it decodes and base64 otherwise.
A fence line inside the payload cannot close the block early, because only the line with the payload's own digest does.
`list` reads `current/` and `list --archived` reads `archive/`; each row is the key's current record plus `acked`, and neither touches an outbox.

## Retire and purge

`retire <id>` takes the bindings lock and then the binding lock, and runs:
1. Create `bindings/<id>.retiring` exclusively, so the client refuses new submits from here.
2. List the outbox in a bounded child; on timeout remove `.retiring` and exit 75 `outbox-unresponsive`.
3. Refuse with 65 `retire-busy` and the keys, removing `.retiring`, when an envelope has no final receipt, a key is delivered and unconsumed, or a final key has no `.announced` marker.
The Live membership preflight applies before step 1 and on replay, so missing filenames cannot hide a known live member.
Each key's state comes from its receipts, never from a `current/` entry a crash left pending; a source failure during the decision refuses with 70 `receipts-unreadable`, removing `.retiring`.
4. Create `bindings/<id>.retired` exclusively and remove `.retiring`; the front then moves the id from `.bindings.list` to `.retired.list`.
A `retire` that finds `.retired` already there removes any `.retiring` and rebuilds the lists before it answers, so a repeat finishes an interrupted one; the front repairs the lists after every `retire` and `purge`.

A producer can check for `.retiring` just before step 1 and link its envelope after step 2's listing, and no lock closes that window.
An ingest of a retired binding gives each envelope with no receipt a key-scoped `binding-retired` refusal, which is announced, and the id stays in `.retired.list` for seven days after retire so a sweep can find those stragglers.
After that window the client's row 4 is the only guard, and it holds because `.retired` is never deleted.

`purge <id>` deletes a retired binding's tree 365 days after the later of its retire and its last receipt, and refuses with 65 `not-retired` or `purge-too-early` before then; it is a cleanup action that asks the operator first.
`bindings/<id>.json` and `.retired` stay, so a purged binding answers 70 `binding-retired`.
`alarms` and `status` skip a purged binding, whose tree is gone by design, so it never makes the alarm set incomplete; `status` lists it as `purged`.

## Locking

Each binding has one lock, `<id>/.lock`, taken by the front with the shared bounded lock helper and a 5 s wait; busy exits 75 and names the holder on stderr.
Every owner-side write of a binding takes it: ingest-staged, consume, the acknowledgements, reconcile, retire, retention and the announce step.
`.bindings.lock` guards `.bindings.list` and `.retired.list` for `bind`, `retire`, `purge` and the list repair.

The lock order is the runner lock, then the bindings lock, then the binding lock, then the wake-queue lock, and a path never takes them in reverse.
The front releases all mutation locks before taking the separate bounded `.alarm-sync.lock`, which spans alarm snapshot creation through alert-store publication.
Only the alert-store lock may nest beneath that projection lock; no path takes a mutation or wake lock while holding it.
This prevents an older complete snapshot from erasing levels from a newer incomplete snapshot.
No lock is held across a syscall on a producer path, except that `retire` lists the outbox in its bounded child while it holds its locks, so that hold is at most `OUTBOX_IO_BOUND` plus 5 s.

Every engine mutation checks the authority for its phase.
Binding/protocol commands require `--lock <dir>` whose recorded owner pid is the engine's parent; otherwise they refuse with 70 `lock-not-held`.
`reserve-run` and `runner-count` require that parent to hold this home's watcher lock.
Before either `start-run` phase, the engine proves that its actual front is a live child of the healthy, identity-matched watcher, then the shared writer verifies the reserved attempt token.
The pre-install `.runner-starting` evidence needs no runner lock: it must exist before the front waits for that lock.
`start-run --install` additionally proves that this front owns `.runner.lock`, including its recorded process start identity, before writing `.runner`.
`runner-loop` uses the same installed-phase authority, accepts only the actual runner mutex (including a home-path alias to it), checks its supplied watcher identity against the native reader, and requires the installed pid/starttime/watcher tuple to name its actual front.
The native watcher/lock readers own those proofs; their whole command has a 10-second bound and 5-second kill grace, and the process-parent snapshot is rechecked afterward.
When a command reports `lists_stale`, the front rebuilds both lists from `bindings/*` under the bindings lock after it releases the binding lock.

## Alarms

After every public/manual mutating command the front syncs the `owner-notice` alert store, `state/owner-notices/alert-store.json`, to the wanted set the engine's `alarms` command derives from disk.
Only internal `maintain` and `ingest-staged` fronts whose actual pid/starttime match the binding's durable `ingest` child record for that run defer projection to the independent runner projector.
The shared child-record reader owns this authorization; an absent or nonmatching slot grants no deferral, and a malformed record refuses before mutation and projects `automation-unreadable`.
`FM_OWNER_NOTICE_RUNNER_BATCH` is discarded and grants no authority; even a manual call to an internal verb projects normally without the matching live record.
The store is rewritten on every sync, and each alarm is a level raised once per occurrence; `docs/alert-store.md` owns the store format.
The levels in this version:
- per binding automation: `outbox-stalled`, `ingest-stalled` from the durable role records, `ingest-busy` after three busy answers, `ingest-failed` on an unsuccessful child, and `automation-unreadable` when their records cannot be read;
- per binding: `outbox-unreadable`, `outbox-identity-changed`, `outbox-symlink`, `outbox-filesystem` and `outbox-backlog` from the last stage, `binding-unreadable`, `receipts-unreadable`, `current-unreadable` (`current/` is missing or cannot be listed), `membership-unreadable`, `status-unreadable` (the required last-stage record), `routing-unreadable` (fallback membership cannot be established), and `current-backlog` (more than 3,072 entries in `current/`);
- per key: `outbox-in-progress` while the envelope stays in progress past 60 s, until a complete listing no longer finds it so, `refused` and `unsafe-file` until `.acked/K`, `custody-mismatch`, `orphan-custody` and `seq-collision` until `.acked/K` or a later delivery, `unannounced` past 15 s after the final receipt, `unconsumed` past `consume_bound_seconds`, and `current-unreadable` and `receipts-unreadable` for an entry that cannot be read.

A source that cannot be read is unknown, never empty: missing required directories, missing member projections, schema/type/identity-invalid current records and invalid receipt sources raise their own levels and mark the wanted set incomplete.
Every live/current key is judged from validated receipt truth, including identity, consumed-to-delivered linkage and the Live membership projection witnesses, even when its current projection parses.
On an incomplete set the front asserts each wanted level and clears nothing, so an unknown source never clears a live level; the whole-set sync runs only on a complete set.
List repair likewise keeps an unreadable binding's existing list lines, but refuses before replacing either list if either fallback is missing, unreadable or malformed.

Each alert key is `<level>.<first 20 hex of the sha256 of binding and key>`, and its evidence names the readable `<level>:<id or key>`.
An empty outbox is healthy; absent routing lists can be rebuilt only when all primary bindings are readable.
A never-bound owner root containing only front scratch, child and lock directories is healthy-empty even if `bindings/` has not been created; any surviving authoritative state makes a missing `bindings/` unknown instead.
Malformed binding filenames and unreadable binding enumeration return named `binding-unreadable` errors from `status` and `list`, and an incomplete alarm snapshot.
Routing maintenance after committed `ingest`, `reconcile`, `retire`, `purge` or `bind` never replaces or rolls back the operation result.
On failure the engine/front emits the full committed result on stdout, then a named JSON diagnostic on stderr, and exits 70.
The stdout `exit` remains the committed operation's outcome, not the process exit; `lists_stale` names both lists for repair when their membership is unknown.
The diagnostic names the committed `binding_id`, the failed `list` path, and `source_binding_id` when a different unreadable binding forced fallback; its code is `routing-unreadable` or `routing-write-failed`.
After the source is repaired, the next refresh rebuilds the lists; callers must check the process exit and must not treat the preserved result as a healthy routing verdict.

## Trust assumption

Receipts are trustworthy only to a producer that cannot write the owner tree and that runs the pinned client bytes from a path it cannot write.
The client checks the first half on every call, for `state/`, `state/owner-notices/` and `bindings/`, and for `<id>/receipts/` when it exists: an exclusive create of a probe file there must fail with `EROFS`.
A create that succeeds is removed at once and answers 69 `owner-tree-writable`; `EACCES` or `EPERM` answers 69 `owner-tree-writable-by-mode`, because the same uid can change mode bits back; any other errno answers 70.
The check protects against a misconfigured producer, not one that rewrites the client; that half is a deployment pin, so every producer runs with the owner tree on a read-only mount.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | `delivered` or `consumed` for the caller's digest, or an owner command that succeeded or replayed |
| 2 | usage or config error, including an unknown config field and a refused test seam |
| 3 | `absent` (query only) |
| 65 | a refusal, `key-conflict`, `not-recorded`, `retire-busy`, `not-refused`, `not-vanished`, `not-retired`, `purge-too-early` or a `bind` refusal; the JSON line carries `code` |
| 69 | unavailable: a pinned path missing or unreadable (named), `owner-tree-writable`, `owner-tree-writable-by-mode`, or `binding-retired` on submit |
| 70 | unknown or inconsistent state, including `binding-retired` on query, `lock-not-held`, `seq-collision` and `retired-unreadable` |
| 75 | client: `pending`; owner front: `busy` or `outbox-unresponsive` |

Any other code, including 1 from an uncaught exception, 124 or 137 from a caller's timeout, or a signal, is unknown and never success.

## Bounded failure

A client call makes at most one payload read, four probe creates, one listing of `receipts/K/`, one envelope create and one record create, and waits only with `--wait-seconds`.
A kill mid-call leaves at most the call's own temp file, possibly still linked to the envelope or record it was publishing, which the next call commits.
Every owner syscall on an outbox runs in a child made by one spawn operation: the child gets its own process group and the parent-death signal, and blocks on a start pipe until the front has made its `.fg-children` record durable.
The front waits at most `OUTBOX_IO_BOUND` = 10 s, then kills the child and exits 75 `outbox-unresponsive`; a child that survives the kill keeps its record.

## Crash and durability table

Each row names a write, what a crash right after it leaves, how readers answer, and what repairs it.
The spy id is the fsync the test spy logs for it.

| Side | Write point | Spy id | State left | Reader answer | Repair |
|---|---|---|---|---|---|
| client | temp write | `c-temp-fsync` | own temp in `.tmp/` | as before | a later call removes it once its identity is dead |
| client | envelope link, before its commit | `c-envelope-dirsync` | envelope linked to its temp | the stage leaves it `in-progress`; `pending` | the next client call finishes the commit (`c-finish-sync`) |
| client | envelope commit | `c-temp-dirsync` | envelope, durable | `pending` | a resubmit is idempotent |
| client | `.receipts/K.json` | `c-record-dirsync` | recorded | from the owner receipt | none |
| client | prune unlink | - | envelope gone, record kept | rows 7 and 8 | none |
| owner | `bind` | `o-binding-dirsync`, `o-mkdir-parent` | no binding, or a complete one with every directory | not bound or bound | re-run `bind` |
| owner | list replace | `o-list-dirsync` | old or new list | - | the front rebuilds both lists |
| owner | stage copies | - | partial `.tmp/<run>/` | - | `reconcile` removes it once the stage identity is gone |
| owner | any owner create, before its commit | the create's own id | name linked to its temp in `.tmp/` | in progress: a receipt answers `pending` | the next owner command finishes the commit (`o-finish-sync`) |
| owner | custody create or replace | `o-custody-dirsync` | custody, no receipt | `pending` | the next run stages again, fsyncs `custody/` again when the bytes are equal, and replaces custody if needed |
| owner | custody read-back mismatch | - | custody, no receipt, `custody-mismatch` | `pending` | the next run replaces custody |
| owner | custody with no receipt and no envelope | - | orphan custody | `absent` or `owner-record-missing` | `reconcile`, when a complete manifest lacks K, validates the custody bytes and writes `delivered`, or raises `orphan-custody:<K>` |
| owner | initial projection, then live membership add | `o-current-dirsync`, `o-membership-dirsync` | valid pending projection, possibly not yet a member | no receipt yet | replay enrolls the valid projection before creating a receipt |
| owner | receipt create | `o-receipt-dirsync` | receipt, stale `current/` | from `receipts/` | `reconcile` rebuilds `current/K.json` |
| owner | `current/` replace | `o-current-dirsync` | stale cache | correct | validation finds the receipt |
| owner | wake append | `o-wakequeue-fsync`, `o-wakequeue-dirsync` | queued row, no marker | - | the next announce sees the key queued and writes the marker only |
| owner | `.announced/K` | `o-announced-dirsync` | complete | - | none |
| owner | refusal receipt, before announce or sync | `o-receipt-dirsync` | refusal on disk | `refused` or `key-conflict` | the next command announces and syncs |
| owner | alert-store sync lost | - | level missing | - | the next sync derives the full set again |
| owner | consume link | `o-handled-dirsync` | custody and handled | `delivered` | `reconcile` unlinks custody and writes `consumed` |
| owner | consume unlink | `o-custody-unlink-dirsync` | handled only | `delivered` | `reconcile` writes `consumed` |
| owner | `consumed` receipt | `o-receipt-dirsync` | stale `current/` | `consumed` | `reconcile` rebuilds it |
| owner | `.acked/K` | `o-acked-dirsync` | acked | unchanged | none |
| owner | `.retiring` | `o-retiring-dirsync` | submits refused, not retired | rows 4 and 16 on submit | the next `retire`, or `reconcile` once it is older than `OUTBOX_IO_BOUND` + 60 s |
| owner | `.retired`, before the lists | `o-retired-dirsync` | retired, `.retiring` left, still listed | R | the next `retire` removes `.retiring`, and the front rebuilds both lists |
| owner | archive copy, before membership removal | `o-archive-dirsync` | in `current/` and `archive/`, still a live member | `list --archived` dedupes | retention finishes membership removal and unlink |
| owner | live membership removal, before current unlink | `o-membership-dirsync` | terminal archive durable, extra current file | safe redundant projection | retention archives again and finishes unlink |
| owner | `.outbox-index` replace | `o-index-dirsync` | old or new index | - | the next complete stage |
| owner | `.fg-children` record | `o-fgchild-dirsync` | a record, the child blocked or gone | - | a child whose front died reads EOF on its start pipe and exits |
| owner | root `.children` projection record | `o-children-dirsync` | recorded projector, blocked on release or live | watcher still judges progress independently | the next runner adopts the identity before starting any projector; dead identities are removed, survivors retained |
| owner | root `.stall` projection failure | `o-runner-dirsync` | unresolved projection failure even if its child died | watcher health reports failure, independently of fresh beats | only a successful subsequent projection clears it; stopping, reaping or restarting alone does not clear it |
| owner | `.quarantine` replace | `o-quarantine-dirsync` | old or new scope occurrences | unknown sources still alarm through shared readers | revalidate each scope; preserve its first epoch, and never overwrite malformed ledger bytes |
| owner | final `.runner-beat` with `drained=yes` | `o-runner-dirsync` | absent witness or complete witness | missing witness requires another bounded final projection | accept only against the latest attempt and currently validated empty demand; it is completion, never live-process presence |

`reconcile` runs in every `ingest-staged`, and the owner can run it alone with `fm-owner-notice.sh reconcile <id>`.

## Retention

Retention runs inside `ingest-staged`, under the binding lock.
- `handled/K.notice` is deleted 30 days after its `consumed` receipt, which keeps the digests.
- A `current/` entry moves to `archive/<yyyy-mm>/K.json` 7 days after its `consumed` receipt, or 7 days after `.acked/K` for a refused key, subject to the Live membership ordering and outstanding-obligation guards.
- Receipts are kept for the binding's lifetime, so a query after a prune keeps working; a long-lived binding is rotated by binding a new id.
- The producer prunes recorded envelopes, and `outbox-backlog` fires above 4,096 entries.

## Owner automation

Owner automation requires Python 3.11+ with working standard-library SQLite `Connection.setlimit` and `getlimit`, including the LENGTH and SQL_LENGTH limits.
This prerequisite applies to every existing owner tree, including an otherwise idle U1 tree; the quiet healthy-idle baseline requires a supported automation runtime.
The runner entry points and alarm publisher refuse unsupported owner runtimes rather than operating without allocation limits.
The shared capability probe in `fm_owner_notice_runtime.py` checks only the interpreter and an in-memory connection, never owner records or the publication database.
The watcher probes on activation and each slow sweep, caches the verdict on fast ticks, and re-probes after a failed operation to detect interpreter replacement between sweeps.
An unsupported runtime holds `runner-runtime-unavailable` in `runner-alert-store.json`, naming its version and required APIs, never a queue/store repair cause.
The existing native shell alert-store writer raises/clears this prerequisite level independently of SQLite; it does not enqueue a third FIFO key or sync away either existing key.
Unsupported activation and every slow/forced probe reconcile the level under the native store lock, preserving its occurrence and acknowledgement while the cause holds; a changed cause updates its reason.
A healthy cold activation only caches capability, so FIFO admission never waits on runtime-level cleanup; its first slow sweep performs that cleanup.
A supported replacement clears an earlier watcher's runtime level even if it never observed the outage itself.
The complete native reconciliation runs in a child under `FM_CHECK_TIMEOUT` (default 30 seconds) and 5-second kill grace, then returns to the same watcher; native lock acquisition remains bounded by 10 seconds.
The exec-style timeout helper is isolated in a subshell so an idle reconciliation cannot replace the watcher or skip unrelated slow checks.
After acquiring the store lock, the writer verifies the current watcher PID and captured start identity so an old surviving command cannot overwrite its replacement's diagnosis.
A missing store is not an idle shortcut while its writer lock exists: a first publication may already be in flight.
When the store is valid and the runtime key is absent, clearing does not rewrite unrelated levels or acknowledgements.
A publication failure emits a bounded fallback check with the actual runtime cause and native-writer exit status; repair retries on the next probe and reports level reconciliation separately from runtime recovery.
A recovered runtime probe emits one recovery check in the watcher that observed the outage and resumes normal source validation.
An unclassifiable or failed probe also refuses, explicitly reporting an unavailable interpreter version instead of inventing a supported runtime or a queue fault.
The probe reply is bounded before shell substitution and must be one LF-terminated line without NUL/CR or extra records; truncation and a nonzero exit cannot grant `ready`.
No legacy-compatible idle classifier is used.
Manual owner projection reports unavailable automation readers through an incomplete `automation-unreadable` snapshot with subject `runtime`, preserving existing levels without importing or opening the automation queue.
Only automation-specific sources are skipped: binding, protocol routing, outbox, custody, receipt, refusal, announcement and consumption derivation still runs and raises newly discovered protocol levels.
The unconditional U1 `wanted_lists` check retains fallback membership diagnosis when a binding is unreadable; it is distinct from the gated automation `read_routes` check.
Readable empty or nonempty fallback lists are not a routing alarm, and repairing them removes the wanted routing row without clearing an already-held row while the overall snapshot remains incomplete.
Manual core operations and the pure start-history reader retain their existing authorization and compatibility; this prerequisite does not change the producer client's runtime or its two-file closure.

The watcher's fast cycle examines only owner-side routing/publication hints and its own unreaped children.
It checks `kill -0` before `wait`, never waits on a live child, never stats an outbox, and performs no per-binding calls.
An invalid/nonregular routing list still requests the runner's diagnostic path; it is not mistaken for healthy empty routing, and symlinks are checked before any following file test.
A spawn runs at nice 19 and idle I/O priority where `ionice` is available.
The runner front refuses unless its actual parent is the pid the shared `fm_watcher_healthy` check identifies for this home.
It holds `.runner.lock` through the shared bounded helper, with a 30 s acquisition bound, checks its launching watcher's health every 15 s, and stops its Python loop when that watcher disappears or changes identity.
Stop signals the loop first, waits at most 5 s, then sends KILL without an unbounded wait.
The loop's exit path signals recorded process groups first, waits at most 2 s, then KILLs survivors and retains their records for adoption.

All outbox calls run in children of the common recorded-spawn operation, never in the watcher or the runner's main thread.
The child has its own process group and Linux parent-death signal and is blocked on a start pipe until its pid/start-time record is durable.
The same operation covers foreground bind, retire and manual ingest.
Every engine child, including the loop and ingest engines, also dies with its immediate shell front on Linux, so a dead recorded shell cannot leave an unrecorded descendant mutating a reclaimed binding lock.
The shell supplies an internal `FM_OWNER_NOTICE_FRONT_PID` pin for each engine invocation to reject a parent already lost before engine initialization; nested fronts discard inherited pins before supplying their own.
A restart adopts live records before scheduling replacements; process identity excludes zombies.
No binding gets another child of a role while that role's recorded identity lives.
A live foreground record prevents both stat and stage for its binding; after 10 s it raises the binding's foreground stall.

Each binding has one persistent stat worker with request/answer pipes and a 5 s response bound.
An unanswered request is abandoned and KILLed without stopping other bindings; no binding beat is written for it.
A successful stat writes the binding beat and clears `stat` and `fg` stall records.
A changed mtime or the 300 s full sweep schedules a stage; retired bindings are staged on full sweeps for their seven-day straggler window.
One stage/ingest sequence runs per binding, and child exit wakes the `select` loop instead of waiting for the next 15 s tick.
Both stage and ingest receive TERM at their recorded start plus 60 s and KILL at plus 65 s, including after adoption.
A child still alive then adds a stall whose `since` is its original start, not adoption or signal time.
The stall remains through child disappearance and replacements and clears only after a successful stage/ingest sequence.
Stat stalls retain the first request time (adoption time for an inaccessible inherited request pipe).

A busy ingest retains its staged run and retries next tick; the third consecutive busy result in that command's streak raises `ingest-busy`.
Only the same command's non-busy answer resets its streak, never another role's success.
The `.automation` JSON has `busy` entries for `maintain` or `ingest-staged` (`count`, `since`), and `failures` entries for `stat`, `stage`, `maintain` or `ingest-staged` (`reason`, `since`).
Empty maps are healthy; malformed records, including the unreleased scalar draft format, are unknown and alarm rather than receiving guessed ownership.
Each failure retains its first epoch until its own recovery: bound-identity stat, successful maintenance, or successful ingest (which also completes its preceding stage cycle).
Aggregate `ingest-failed` and `ingest-busy` remain held while any owning role still requires them; another role's success cannot clear them or reset their occurrence.
An ingest-slot stall from maintenance (`run=-`) clears only on maintenance success; a staged-ingest stall clears only on successful ingest.
The next cap-hit run starts immediately, oldest-first staging prevents starvation, and `.seen` advances only for a complete non-cap-hit manifest whose captured mtime predates listing by more than 2 s.
A recent/equal/future mtime stays dirty and is staged again, with the ingest cache avoiding repeated opens.
Maintenance reconciles and announces at start and every 300 s, sharing the binding's ingest slot; retention runs once a day and inside successful ingests.
The internal front entry is `maintain <id>`; its binding lock and alarm-projection rules are described under Alarms above. There is no standalone `retention <id>` front command. The existing locked engine retention operation and retention through maintenance/ingestion remain available; this unit adds no public manual-retention API.
Start projection follows the announce pass; an unavailable maintenance pass (its own failure/busy result or a stalled occupied stage/ingest slot) is deferred, not a reason to suppress its stall alarm.
A stat failure alone does not make maintenance unavailable and cannot bypass this ordering.
The home-wide snapshot-through-sync child has its own recorded slot so it remains runnable when every binding has a stalled child.
Its failed exit or deadline stall leaves root `.stall`, which the watcher health reader treats as a failure even when `.runner-beat` remains fresh; a blocked projector cannot mute its own alarm.
A nonzero exit, incomplete source set or unknown adopted completion does not stop the runner or cancel binding children: projection retains the root failure and retries no sooner than the next runner interval.
After the initial reconcile/announce pass, a failed projection releases the start gate as `start-sync-deferred`, so it cannot indefinitely prevent delivery; a stalled initial projector releases that gate when its failure is detected.
Stage, ingest and maintenance failures likewise retry on a bounded interval rather than spinning at child-exit speed.
Root child ownership uses the same adoption, deadline, stop and identity-gone cleanup rules as binding children, and a root stall clears only after a successful, complete projection.
Projection uses the same independent serializer and incomplete-set preservation as foreground commands.

The runner's recorded projection child registers `owner-notice` and `owner-notice-runner` with their same-named owner status files, through the existing native initializer/registration helpers.
Registration, status preparation and projection share that child's recorded identity, deadline and root failure scope; a malformed store or unavailable registration/status source cannot abort the runner before independent binding work begins.
Unknown bytes are preserved. A complete successful projection confirms and caches that runner's registration pass; a failed, incomplete or unknown projection invalidates the cache, so bounded retries revalidate registration as well as projection. Replacement starts without that cache.
Manual `sync-alarms` stays independent of automation registration; there is no ambient batching flag, new public entry or alternate alarm writer.
The latter holds `runner-beat-stale`, `runner-respawn-failing` and the native runtime prerequisite `runner-runtime-unavailable`.
The watcher slow sweep uses the shared attempted-start reader below and a 65 s progress bound, and reads held levels through `fm_alert_store_active_keys` (including acknowledgements).
It queues alarm observations; the publisher below applies only actual held-state transitions.
The internal `runner-health` command emits independently validated words: loop `fresh|stale|unknown|drained|idle`, projection `clear|failed|unknown`, and demand `work|empty|unknown`.
The combined level clears only for `fresh clear work` or `drained clear empty`; fresh empty-demand work keeps an existing level until its final projection, without inventing a new failure.
Unknown demand never grants an empty-home completion.
`idle` is a validated no-history/no-work baseline under the supported [automation runtime](#owner-automation), not a claim of runner presence.
With no wanted or held notice levels, no held runner levels and valid zero failure history, it reserves no attempt and raises no alarm, including on an existing U1 owner tree.
Held levels or unfinished history still request cleanup.
Before an empty-demand cleanup runner starts, the watcher preserves held levels without inventing a stale occurrence; a new stale-loop alarm requires its own live child to be genuinely overdue.
Projection/source failures remain independently alarmed.
The watcher sends TERM once per own child only for explicit stale loop progress after the age bound, never for failed/unknown projection, unknown loop state, a young successor or another watcher's runner.
That recovery action is independent of the held alarm transition, so an earlier projector alarm cannot mask later actual loop staleness.
A pre-beat exit increments `.runner-respawns`; retries back off by 30, 60, 120, 240 and then 300 s (the check interval cap), surviving watcher restarts.
Configuration or reservation refusal, and an unreadable or unwritable exit history, defer the next attempt by one check interval.
The retry gate precedes configuration as well as reservation, so an unsupported owner runtime does not fork or log a refusal on every fast tick.
The post-configuration gate still honors a backoff newly loaded from durable failure history.
Three consecutive failures raise `runner-respawn-failing`; actual progress can reset the durable count, but the source-recovery fence below separately owns clearance without waiting for a healthy runner to exit.
Start grace alone never resets a failure streak.
Unreadable failure history is never overwritten or cleared merely because a later runner progressed or exited; repair that source first.

### Runner source recovery

`fm_owner_notice_recovery.py` owns the owner-only `fm-owner-notice-runner-recovery/v1` record at `owner-notices/.runner-recovery`.
The watcher is its sole writer under the existing watcher lock; private engine `runner-recovery` operations use the existing durable publisher and `o-recovery-dirsync` barrier.
The public front has no recovery command, and count, attempt, beat and FIFO formats are unchanged.
The record is canonical JSON, bounded to 8 KiB, with exactly `schema`, `phase`, `sources` and `candidate`.
`phase` is `pending`, `ready` or `cleared`.
`sources` is a nonempty map over the fixed vocabulary `configuration`, `reservation`, `counter-read`, `counter-write`, `failed-start`; each row has integer `since`, a single-line reason of at most 512 characters, boolean `repaired` and `observed`, the attempt/beat/identity snapshot at refusal (or explicit `unknown` when that source cannot be read).
`candidate` is null or `{attempt, baseline, identity}`: the reserved token, the SHA-256 of the canonicalized validated baseline beat fields (null if absent), and its matching `{attempt,pid,starttime}` identity when installed progress already exists (otherwise null).

A refused source preserves its first occurrence, marks that source unrepaired and invalidates the candidate before the assertion enters the unchanged alarm FIFO.
Only a successful operation on that source marks it repaired; neither zero count, a recent prior beat, startup grace nor replacement does so.
After every recorded source is repaired, the watcher captures its progress baseline.
A later beat must differ from that baseline and match the candidate's reserved attempt, installed PID and start identity before the phase becomes ready.
A new successful reservation replaces an obsolete candidate with the new attempt's baseline; completion before any installed beat is possible only when that reserved attempt subsequently publishes matching progress.
The comparison observes ordering rather than comparing wall clocks, so a repeated same-second beat waits conservatively and clock movement cannot turn an old baseline into progress.
A later refusal cancels ready proof before any new clearance.

Counter writes are retried as operations even when the old counter reads zero, and final clearance always requires a successful zero-count publication.
Active and exited progress share the recovery fence; historical final-drain health cannot clear it.
Pending recovery keeps empty-demand cleanup eligible, while a validated healthy empty owner with no failure remains quiet.
The record remains ready until its clear is durably admitted to the existing FIFO; only then is it marked cleared, retaining its bounded proof.
A crash before admission retries the ready clear, and a crash after admission but before acknowledgement safely repeats the same FIFO action.
A pending clear still owns completion while its native level remains held; this is not a fresh failure.

Unknown, partial, oversized or nonregular recovery state is unresolved, preserved, and visible through the runner failure and `automation-unreadable` recovery diagnosis.
A missing or completed sidecar with an unattributed held or queued assertion initializes conservative source revalidation, never healthy absence.
Replacement revalidates the persisted fence and sources without changing attempted-start grace.
If reservation proof is required, a successful fresh attempt is necessary; deleting recovery history is not a repair.
There is no second alarm writer or producer access to this record.
The U4 owner-runtime closure includes `fm_owner_notice_recovery.py` and this owner-side state format; the producer's two-file closure is unchanged.

### Scoped quarantine and final drain

A malformed binding, routing/binding mismatch, `.children`, `.stall`, `.automation`, `.seen` or outbox index quarantines that binding, not independent work.
A malformed routing list withholds new binding work; malformed foreground ownership withholds new producer I/O because its affected binding is unknown.
Owner-side projection remains runnable in either case.
An invalid stat reply fails only its known stat worker.
Failed/invalid stage results belong to that stage cycle.
Malformed root child/stall records block projection spawning, not binding work; the watcher reads those sources independently and alarms even when no projector can run.
A malformed quarantine ledger is itself unknown, is never overwritten, and keeps final completion blocked; the watcher and projection diagnose it through the shared reader.

Quarantine retains known children and their original identities/deadlines, drains their bounded output and reaps without claiming success.
It does not replace children or overwrite unreadable ownership/status records.
Each loop revalidates owner-side sources before resuming a scope; a known live child missing from a purported repaired record still refuses.
Overdue actions resume from original deadlines, not repair time.
The runner publishes scope transitions only, preserving `since`; `automation-unreadable` holds while a scope remains unknown.
U1's normal, authoritative list repair can fix a readable routing mismatch; quarantine never guesses replacement ownership.

### Runner alarm publication

`fm_owner_notice_alarm.py` owns the internal `fm-owner-notice-runner-alarm/v1` format.
It is not a producer notice, consumer receipt API or installed service.
Python's standard-library SQLite supplies atomic commits and WAL snapshots; the module alone owns its schema/readers:

- `.runner-alarms.sqlite3`: `user_version=1`, exact native schema, home-bound metadata, monotone last acknowledged cursor/digest, separate writer and advance failure/first-occurrence pairs, and pending requests (`seq`, key, assert/clear, reason, observed epoch).
  The only keys are `runner-beat-stale` and `runner-respawn-failing`.
  Rollback journals are foreign to this native WAL format and refuse before SQLite can recover unknown bytes.
- `.runner-alarms.pending`: an advisory `pending\n` hint, never queue truth.
  Slow sweeps repair missing/stale hints.
- `.runner-alarm-publisher.lock`: an existing, empty, single-linked kernel lease.
  Initialization syncs the lease through the shared `fsync_file` observer (`o-alarm-lease-fsync`) and its parent before publishing the queue.
  Losing it is unknown state, not permission to create a second publisher.
- `.runner-alarm-publication/result`: a canonical, 8 KiB-bounded `fm-owner-notice-runner-publication/v1` record with exactly `schema`, `seq`, `request_sha256`, `outcome` (`published|failed`), `reason` and observed `at`.
  The digest binds the entire request **and owner root**.
  Its dedicated `.tmp` contains only common-formatter scratch; unrelated members refuse recovery.

Only the real lock-authorized watcher mutates SQLite.
It durably enqueues before reporting acceptance and rechecks authority at commit.
Repeated observations collapse only against the last pending action for that key: assert/clear/assert remains three transitions.
Admission validates the current head and same-key tail and refuses a sequence that would reuse an acknowledged request, before committing or publishing the pending hint.
Admission never acquires the publisher lease.
WAL mode is established in the initial private database before publication; stopped read-only snapshots therefore cannot block later admission.
SQL lock waits use a 1 s timeout and the VM progress handler uses a 1 s budget, separate from external writer time.
These time bounds and SQL result clipping are not allocation guards.
Before any statement, schema or value read, every queue connection (including initialization) installs and verifies `SQLITE_LIMIT_LENGTH=16384` and `SQLITE_LIMIT_SQL_LENGTH=4096` through the public API.
The value/row bound accommodates the complete metadata row, including its root, both failure strings and cursor/digest; the SQL bound also covers stored schema text.
An unavailable or ineffective limit refuses; there is no older-runtime or unbounded fallback.
These are per-value/row and SQL-input limits, not a whole-process RSS guarantee.

The watcher first consumes a committed result under the lease, then dispatches at most one oldest request.
Internal `advance` returns `idle|pending <whole-bound> <kill-grace>`; 75 means an occupied lease, 70 an unknown/failed operation.
Publishers open SQLite read-only and close it before any alert-store operation.
They return through the separate durable result slot, not a database write transaction.
Result consumption requires an exact head/digest, or the exact already-acknowledged cursor/digest after a crash between SQL commit and result removal.
A failed result never removes its request.
Failed advancement has its own retained occurrence: neither successful publication nor cleanup of a different phase clears it.

Publication uses the existing alert-store writer, CLI and active-key reader.
The runner and publisher share conditional store initialization under the native writer lock, through the initializer described in `docs/alert-store.md`.
Existing native stores must belong to the expected id and retain their exact bytes, including ACKs; registration does not substitute for initialization.
Status-file preparation creates only genuine absence without clobbering a concurrent winner, refuses symlinks/nonregular or inaccessible targets, and never appends through an existing path.
ACKed keys remain held.
Already-held assertions and already-absent clears never invoke their writer.
A crash after write but before result/acknowledgement rechecks the held state without refreshing the occurrence.
Producer-side held snapshots cannot suppress an opposite transition already pending.
Accepted requests survive watcher replacement; the inherited kernel lease also excludes a surviving old writer descendant.

Fast ticks service pending work even without binding demand and never wait for the publisher.
Each register/read/write phase uses the common process-group timeout: ingest bound (normally 60 s), then kill grace (5 s).
The entire dispatch uses that same helper with `3 * (ingest-bound + kill-grace) + kill-grace` (normally 200 s), followed by its kill grace.
Independently, the watcher verifies PID/starttime and sends one TERM then one KILL if the wrapper itself stalls.
Busy leases retry on the runner interval; failed dispatches retry on the check interval.
There is no retry-count or queue-size discard; work is bounded to head/tail/metadata, and logical storage grows with undelivered requests, not delivered history.

The independent owner projection diagnoses retained failures, overdue accepted work and unknown queue/result/lease/log sources as `automation-unreadable` for `publisher`.
Direct check fallback covers admission, advancement or dispatch failure.
A healthy empty advance or successful publication re-arms that fallback for a later occurrence.
Repair the source, never erase requests or force acknowledgement.
Missing queue is healthy only without a hint/result obligation.
Initialization uses durable no-replace publication: a young live formatter publication with valid empty WAL state and no prior cursor/work is pending, not a false alarm; dead, old, foreign or work-bearing partial initialization is unknown and preserved.
The shared watcher metadata writer validates its state/root/temp directories before using a temp path.
Private SQLite initialization scratch uses the common owner temp identity prefix, so ordinary owner sweeps preserve a live initializer and own its dead scratch cleanup.
Deeply nested malformed JSON is a format refusal, not an uncaught recursion failure.
Result reasons must be Unicode scalar text; the byte bound accommodates the worst-case JSON encoding of a valid 512-character reason.

The future U4 native companion/closure must include this publisher, its SQLite/result formats, native dependencies and the Owner automation runtime prerequisite above.
U2 does not install that companion or modify a live handoff registry.

### Final drain and delivery bounds

Valid empty routing alone is not recovery from an existing obligation.
The watcher retains a bounded final-drain runner when there is held or unfinished work until a complete successful owner-side projection is witnessed, including after watcher restart and with no new binding.
With the supported [automation runtime](#owner-automation), a validated healthy idle owner needs no such runner; both active-key stores use the shared reader, including acknowledged held levels, before choosing that quiet baseline.
The owner-only `sync-alarms` command returns `{"complete":true}` or `{"complete":false}` after successful publication; a partial snapshot still preserves levels but cannot certify a final drain.
The `sync-alarms` front returns exactly one newline-terminated canonical JSON object, `{"complete":true}` or `{"complete":false}`. Its child reader consumes that one line framing before validating the canonical object; on-disk canonical JSON still has no newline.
Malformed, missing, partial, concatenated or extra-line projection results are failures, not completion; only boolean `complete` is accepted.
The final loop beat adds `drained=yes` only after all known binding/foreground work has ended, scope sources are valid, and that final projection completes.
Incomplete or failed projections continue bounded retries.
The health reader accepts that witness only for the latest installed attempt, matching front identity, currently validated empty demand, no root child/stall, and an empty valid quarantine ledger.
New work invalidates completion and starts normal scheduling.
This resolves runner/root failures through actual work rather than clearing levels because a list became empty.
Protocol levels still derive from their own receipts and sources; a final drain never clears them indiscriminately.

Under auto-arm the runner exits after the handling-successor watcher closes, so there is no finite delivery bound during the rest of the owner turn.
Steady-state delivery figures are conditional design bounds, not execution or observation guarantees: 140 s from submit for an idle binding, 245 s behind an in-flight run, plus at most 20 s per busy retry and 120 s per extra cap-hit run.
Handover adds up to 22 s plus the first full sweep (125 s); the slow path is 425 s before serialization.
A consumer's pending-attention level keeps its original age and clears only on its verified exact receipt, never merely because a turn explains the delay.

## Attempted-start history

`bin/fm_owner_notice_runtime.py` owns the automation capability/limit setup and start-history reader and writer primitives.
The watcher and the handoff adapter call `runner_start_status(root, beat=None, now=None, spawned=None, bound=65)` rather than parsing start records themselves.
`root` is the absolute owner-notices directory; `beat` is a validated beat mapping (including its `attempt` token), or `None` only for genuine absence.
`spawned` is optionally `{pid, starttime, token}`, supplied only by the launching watcher before the front publishes its starting record; the reader independently checks that identity.
The result contains `live`, `pid`, `starttime`, `started_at`, `token`, `previous`, `first_start` and `grace`.
Unreadable, nonregular, malformed or partial records raise an exception, never an empty or healthy verdict.

Before each spawn the singleton watcher durably reserves an attempt in `.runner-attempt` with `token=<32 lowercase hex> previous=<prior token or -> spawned_at=<epoch>` and a trailing newline.
A prior installed record without attempted-start history is represented by `previous=legacy`, never first-start evidence.
Only the last two tokens are retained, so cost is independent of restart history.
A reservation is history only and never establishes a live runner.
It survives a failed fork, death before the front starts, death while waiting for the runner lock, and death of the launching watcher itself.
The front's `.runner-starting/<pid>-<starttime>` adds `pid` and `starttime` to that attempt record before waiting for the runner lock.
After acquiring the lock the front publishes `.runner` with `pid`, `starttime`, `watcher_pid`, `started_at`, `attempt`, `prev_attempt`, `prev_pid` and `prev_starttime`.
The installed record survives exit; removing dead starting records never removes the attempted-start history.
A runner beat carries `attempt` as well as its process identity and epoch.

The reader grants grace only for the latest attempted start, with a verified live identity younger than `bound`, and either no beat on the first-ever attempt or a beat from the immediately preceding attempt.
Neither a missing beat nor a missing installed runner alone proves first start.
A second consecutive attempt without a beat cannot renew grace, including before installation and before the front publishes any process record.
An older still-live front cannot grant grace for a newer failed attempt.
For a missing-index exception the adapter also requires `first_start`; the token itself is never liveness evidence.
The regression is [`tests/fm-owner-notice-start.test.sh`](../tests/fm-owner-notice-start.test.sh).

## Test seams

Every seam is inert unless `FM_OWNER_NOTICE_TEST_ROOT` is set and every path the process touches, and every path a seam names, is under it; otherwise a set seam is refused with exit 2.
The root must also not be `/` and must hold a regular file `.fm-owner-notice-test-root`, which only a test world creates, so a leaked environment variable alone never turns a seam on in a real home.
- `FM_OWNER_NOTICE_FAULT=<item>[,<item>...]`, where an item is one of:
  - `<a>:<b>:kill`, `<a>:<b>:pause=<fifo>` or `<a>:<b>:errno=<E>` at a fault point, once per process; a pause appends `<point> <pid>` to `<fifo>.reached` and blocks until the fifo is opened for writing;
  - `seq:stale=<n>` (the first seq allocation returns n), `seq:stale-always=<n>` (every allocation does) `ingest-cap=<n>`, `membership-write-bound=<bytes>` (isolated write-cap test; production stays 16 MiB), `cache-slack=<s>` (the 2 s cache slack) and `in-progress-settle=<s>` (the 60 s in-progress bound);
  - `probe-errno:<dir>:<E>`, the errno the client's probe of `state`, `owner-notices`, `bindings` or `receipts` reports;
  - `mountinfo=<file>`, read in place of `/proc/self/mountinfo`;
  - `no-pdeathsig:<role>`, `child-ignore-term:<role>` and `unkillable:<role>` for the recorded children.
- The fault points: `submit:after-check`, `submit:before-link`, `submit:after-create`, `submit:after-record`, `prune:after-unlink` and `query:commit-wait` (each retry while a live submit's envelope is uncommitted) in the client; `bind:before-create`, `bind:after-create`, `stage:after-listing`, `stage:after-fstat`, `stage-entry:before-route`, `ingest:after-custody-fsync`, `ingest:after-receipt`, `ingest:after-refusal`, `consume:after-handled-link` (before the `handled/` fsync), `consume:after-link`, `consume:after-unlink`, `consume:after-receipt`, `retire:after-check`, `retire:after-retired` and `retention:after-archive-link` in the engine, and `child:bind`, `child:retire` and `child:ingest` inside a recorded outbox child before it does any work, so a pause there stands in for a hung outbox; `membership:after-add` and `membership:after-remove` in the engine; `announce:after-append` and `alarms:after-snapshot` in the front; `publication:before-temp-lookup` and `publication:before-temp-stat` in the shared reader; `<dir-spy-id>:after-link` and `<dir-spy-id>:after-dirsync` inside every exclusive create, before its directory fsync and before its commit, such as `c-envelope-dirsync:after-link` or `o-receipt-dirsync:after-dirsync`; and `<id>:after-mkdir` after each directory a durable mkdir creates.
- `FM_OWNER_NOTICE_FSYNC_SPY=<log>`: every fsync appends `<spy-id> <path> <monotonic-ns>`; an exclusive create also logs `link`, `commit` and `create` for its name, a replace logs `rename`, and finishing a dead publisher's temp logs its directory fsync as `c-finish-sync` or `o-finish-sync`.
- `FM_OWNER_NOTICE_OPEN_COUNT=<log>`: the stage and the engine append `<role> <open|read|scandir> <path>` for every path they open.
- `FM_OWNER_NOTICE_NOW=<epoch>`: the clock the engine and client read.

The protocol regression suite is [`tests/fm-owner-notice.test.sh`](../tests/fm-owner-notice.test.sh); automation is exercised by [`tests/fm-owner-notice-watch.test.sh`](../tests/fm-owner-notice-watch.test.sh).
Automation fault points include `runner-loop:pause=<fifo>`, `runner-loop:ignore-term`, `run:exit=<code>` and `run:check-delay=<seconds>`.
Publication fault points are `alarm-initialize:prepared`, `alarm-reader:snapshot`, `alarm-publisher:after-write`, `alarm-advance:after-commit` and `alarm-advance:after-unlink`, for live scratch ownership, read-only admission, whole-worker bounds and result/cursor replay.
Test-root-only numeric seams `runner-loop-seconds`, `stat-bound`, `stage-bound`, `ingest-bound`, `kill-grace`, `outbox-io-bound`, `runner-lock-wait`, `full-sweep`, `stage-duration` and `ingest-duration` scale fixture bounds or work durations.
Role-scoped survival seams apply at the common spawn operation to every foreground and runner origin; `unkillable` additionally suppresses every explicit signal to that role.
Deadline fixtures separate TERM, KILL, stall insertion and persisted occurrence time; signal delivery need not imply instantaneous identity disappearance.
The Linux/glibc stat-block shim releases all later intercepted calls in the released process only, not future stat workers, so foreground recovery cannot accidentally clear a later stat stall.
