# Owner notices

`fm-owner-notice/v1` carries one notice per key from a producer process to the owner home that bound it.
The producer writes an envelope into an outbox it owns, the owner takes custody of the exact bytes and writes a receipt, and the producer reads the receipt to learn the answer.
A receipt means the owner holds the notice; delivery is not consumption or acceptance.
This document owns the protocol, the formats, the state layout, the answer table, the exit codes, the lock order, the crash table, retention, the trust assumption and the test seams.
[`bin/fm-owner-notice.sh`](../bin/fm-owner-notice.sh) is the owner front and its header owns the owner commands; [`bin/fm-owner-notice-client.py`](../bin/fm-owner-notice-client.py) is the producer client and its docstring owns the producer commands.
[`bin/fm_owner_notice_format.py`](../bin/fm_owner_notice_format.py) holds the shared formats and durable I/O, and [`bin/fm_owner_notice_store.py`](../bin/fm_owner_notice_store.py) is the owner engine.
The `owner-notice` skill says when agents run each command.

## Scope of this version

This version is the protocol core: bind, a manual ingest, consume, the acknowledgements, retire, purge, show, list and the producer client.
There is no automatic runner, so envelopes are ingested when the owner runs `fm-owner-notice.sh ingest <id>`.
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
| `.bindings.lock/`, `<id>/.lock/`, `.alarm-sync.lock/` | front | Mutation and independent alarm-projection locks of the shared bounded lock helper |
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

The engine runs a mutating command only with `--lock <dir>` whose recorded owner pid is its parent's; otherwise it refuses with 70 `lock-not-held`.
When a command reports `lists_stale`, the front rebuilds both lists from `bindings/*` under the bindings lock after it releases the binding lock.

## Alarms

After every mutating command the front syncs the `owner-notice` alert store, `state/owner-notices/alert-store.json`, to the wanted set the engine's `alarms` command derives from disk.
The store is rewritten on every sync, and each alarm is a level raised once per occurrence; `docs/alert-store.md` owns the store format.
The levels in this version:
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

`reconcile` runs in every `ingest-staged`, and the owner can run it alone with `fm-owner-notice.sh reconcile <id>`.

## Retention

Retention runs inside `ingest-staged`, under the binding lock.
- `handled/K.notice` is deleted 30 days after its `consumed` receipt, which keeps the digests.
- A `current/` entry moves to `archive/<yyyy-mm>/K.json` 7 days after its `consumed` receipt, or 7 days after `.acked/K` for a refused key, subject to the Live membership ordering and outstanding-obligation guards.
- Receipts are kept for the binding's lifetime, so a query after a prune keeps working; a long-lived binding is rotated by binding a new id.
- The producer prunes recorded envelopes, and `outbox-backlog` fires above 4,096 entries.

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

The regression suite is [`tests/fm-owner-notice.test.sh`](../tests/fm-owner-notice.test.sh).
