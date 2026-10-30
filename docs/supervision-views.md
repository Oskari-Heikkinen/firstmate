# Read-only supervision view primitives

This is the maintainer owner of the Python 3.9+ view-engine primitives in [`fm_view_engine.py`](../bin/fm_view_engine.py) and [`fm_view_status.py`](../bin/fm_view_status.py).
These modules are an **uninstalled foundation**, not a completed replacement for crew-state, wake drain or fleet snapshots.
Existing shell entrypoints remain selected without a new runtime dependency.
There is an explicit immutable-code foreground lifecycle entrypoint, but no automatic launcher, mode switch, service installer, health beacon, lease or watcher integration.
The [`supervision-views` skill](../.agents/skills/supervision-views/SKILL.md) owns the agent load trigger.

## Authority boundary

`Inputs` reads only an explicitly supplied canonical home and its identity-bound state root.
Task ids cannot contain path separators.
Regular-file reads are bounded, refuse final-component symlinks and special files, and check same-descriptor and final-path identity.
A changed metadata capture or root refuses the observation rather than attributing it to a replacement task.
A missing status file is an empty span; an existing unreadable or unsupported object is a failure, not an empty successful fold.
The native fold reads registered alert-store levels on every request, even when status bytes have not changed.
The shell classifier remains the parity oracle; it has not been replaced by these modules.

The transport admits `status-fold`, `crew-state`, `status-presentation`, `drain-presentation`, `status-backstop` and `snapshot-tasks` requests.
It cannot claim, acknowledge, append, retire, resume, publish a summary or alter custody.
It writes no authoritative state, including presentation cursors.
The calling transaction owner remains responsible for any presentation commit after successfully writing its output.
The crew-state and drain entrypoints can use the explicit compatibility client below; without its socket selection they retain legacy behavior.

## Read protocol

The protocol id is `fm-supervision-views.v1`.
Each one-request connection carries a newline-terminated JSON object with exactly `schema`, `epoch`, `home`, `request`, `verb`, `timeout_ms` and `args`.
`schema` names the protocol, `epoch` is the owner-selected service incarnation, `home` is the canonical operational home and `request` is a bounded per-call nonce.
`timeout_ms` is a positive integer at most 30000.
The fold verb's arguments contain `task`, an optional explicit `kind`, and optional classifier vocabulary overrides.
The current-state verb accepts `task` and bounded `FM_CREW_STATE_NM_TIMEOUT`, `FM_CREW_STATE_RUNS_LIMIT` and `FM_CREW_STATE_NO_FORGE` options.
Its native run attribution and state mapping live in [`fm_view_runs.py`](../bin/fm_view_runs.py) and [`fm_view_crew.py`](../bin/fm_view_crew.py).
SQLite support is needed only for capped run inventories; an unavailable module returns an explicit inventory-reader unknown with the available ids, while complete overviews remain usable.
The native SQLite reader shares one elapsed bound across connection, lock waits, query execution and validation, with VM-progress interruption and per-query remaining lock budgets.
Unreliable filesystem stalls still retain their original bounded worker slot rather than spawning a replacement.
Fixed passive backend, custody, done-head and forge reads retain their existing owners through [`fm-view-adapter.sh`](../bin/fm-view-adapter.sh); the native engine does not duplicate those contracts.
Backend fallback currently admits tmux only, and remote endpoint reads remain legacy-owned.
A run-step observation that needs no backend probe can still be computed natively on other recorded backends.
An unsupported integration refuses for explicit legacy fallback, never an optimistic current-state answer.
A configured no-mistakes home resolver also remains legacy-owned unless an explicit `NM_HOME` overrides it; native code must not observe an ambient daemon or SQLite inventory instead of the resolved one.
The captured-presentation verb takes only `rows`, at most 256 objects with exactly `task`, `end`, `offset`, `identity`, `classified` and `fully_presented`.
Its classifier owner is [`fm_view_presentation.py`](../bin/fm_view_presentation.py).
The invoking presentation transaction supplies captured byte endpoints, contiguous presentation/classification offsets, device/inode pairs and the annotation's fully-presented flags.
Every offset is a nonnegative integer within the per-file bound, with `offset <= end`; booleans are not offsets.
The reply preserves request order and returns each row's captured endpoint/generation, new nonblank lines, unread informational lines, open decisions, its `observed_offset` and a suggested `acknowledged_end`.
The client requires an integer observed offset within the captured endpoint and rejects suggestions below it; the captured-offset API also requires exact equality to its caller-supplied offset.
A suggestion has no acknowledgement effect: the invoking owner must still verify its original strong birth-time identity and commit only after the prepared output reaches stdout.
Device/inode pairs are observation checks and disposable index keys, never substitutes for those strong cursor identities.
The client accepts the owner's current `strong:<inode>:<birth>` identity and its older device-bearing form without changing the original identity passed back for commit.
For the current form, native observation is limited to the state root's identity-bound filesystem: its predicted device/inode pair must match the independently captured regular file, otherwise the whole request refuses for legacy fallback.
A different-device mounted status file is not admitted by that current-form native path.
Persisted strong identities compare through the owner's device-independent equivalence, while weak identities retain their device.
The `drain-presentation` verb instead accepts rows with exactly `task`, `end`, `identity`, `strong_identity` and `fully_presented`.
[`fm_view_offsets.py`](../bin/fm_view_offsets.py) reads the existing presentation manifest once for that batch, and reads each task's classification marker without spawning a helper.
Its reply additionally carries `classification_markers` in request order, each with exactly `task` and `text`: null for an absent marker, otherwise the captured text with NULs and trailing newlines removed, bounded to 4096 bytes.
The client validates the complete count, binding, text type, normalization and bound before emitting any private marker-evidence records; its header owns that TSV encoding.
This evidence is not a classification receipt or acknowledgement and writes no record.
The original transaction supplies `strong_identity`; native code compares its persisted value, never upgrades it or substitutes a new identity proof.
A missing manifest with a legacy migration cursor refuses for its existing owner to migrate, while a missing row in an existing manifest starts at zero.
Malformed, unsupported or changing cursor state refuses the whole read before native selection.
The batch folds only through each captured endpoint, so concurrent appends remain unread for a subsequent presentation.
A missing, replaced or truncated input, changed prefix or changed metadata generation refuses the entire batch, without a partial successful result or cursor write.
Batches retain at most 64 MiB of captured status bytes and four MiB of metadata; oversized batches refuse for explicit legacy fallback rather than silently omitting rows.
The `status-backstop` verb accepts the same snapshot rows as `drain-presentation` but performs a separate fresh observation at the original late backstop boundary, never reusing earlier unread facts.
It reads the existing presentation manifest once and returns each captured task's reset-aware backstop offset, coherent status mtime, latest nonblank line and that line's byte endpoint, without writing a receipt.
Latest-line selection matches the legacy owner's final-64-KiB bound, incomplete-first-line exclusion, byte whitespace, CRLF, NUL and unfinished-last-line behavior.
Its ordinary-lane generation barriers, per-file and batch bounds, fresh manifest/status checks and all-or-nothing refusal retain the presentation transport's capacity rules.
Unsupported fields, duplicate JSON keys, nonfinite numbers, unsupported verbs and mismatched home/epoch refuse the request.
A response binds the same protocol, home, epoch and nonce, with `ok` and either `result` or a typed refusal message in `error`.
Requests and responses are limited to one MiB; regular input files are limited to four MiB.
These bounds are prototype limits, not a claim that every existing fleet input fits them.

The `snapshot-tasks` verb composes the local `tasks[]` rows through [`fm_view_snapshot.py`](../bin/fm_view_snapshot.py).
Its arguments are `observed_at`, integer `epoch`, positive integer `concurrency` and `task_timeout`, plus the same bounded crew `options` vocabulary as current-state reads.
After capture, one `snapshot-endpoint` adapter process observes the endpoint of every current local row, so the backend library graph starts once per snapshot rather than once per row; a row on a backend the adapter does not admit refuses the whole batch for legacy fallback, and a row with no batched observation refuses rather than inventing one.
Its reply contains `tasks` and an equally ordered `captures` array, each capture containing exactly `task`, raw decoded `meta`, raw decoded `status` (null when absent or discarded), and integer `status_mtime_ns` (null with absent status).
The shared regular-file reader captures mtime from the same verified descriptor as the bytes; raw capture strings use the protocol's lossless surrogateescape encoding.
The compatibility client validates capture count, task binding, status presence and timestamp types before staging any file in its invoking owner's empty, same-UID, mode-0700 nonsymlink capture directory.
It creates only task-id-bound metadata/status files with exclusive nonsymlink opens, preserves original status mtimes and verifies the directory identity before returning task JSON.
The unchanged legacy cross-home collector consumes those captured files for parent activity, fallback freshness and terminal generation checks; it never substitutes an uncaptured live status read.
These files are disposable transport owned and cleaned by the invoking snapshot, not a new durable artifact, service publication or acknowledgement.
A malformed capture or staging refusal invokes the complete legacy path before output; a partial private stage is discarded by that same existing cleanup owner.
It captures at most 256 selected metadata records (four MiB total) and their status spans (64 MiB total), then composes rows with a fixed ordinary-lane coroutine pool capped by both the request's concurrency and available worker count.
Per-task timeouts are at most 30 seconds; an exhausted lane, oversized response, timeout or unsupported integration refuses the whole native batch for legacy fallback before output.
Timed-out I/O still occupies its original worker slot; neither a timeout nor a subscriber disconnect creates replacement threads.
Selected local status bytes are shared by the row fold and current-state classifier rather than reopened for each field.
Fresh tool levels and external observations remain required, and only concurrent in-flight requests for the same inventory and arguments share a batch.
A pre-reply metadata barrier discards mutable status, decision, current-state, report and endpoint evidence for a replaced task while retaining its selected metadata and an explicit generation-changed unknown result.
A changed metadata capture within the legacy generation equivalence (equal nonempty `spawn_gen`, or byte-identical legacy metadata without a generation token) instead refuses the whole native batch for a complete legacy recapture before output.
This preserves strict Crew attribution barriers without turning ordinary same-generation metadata publication into a new unknown-state rule.
Remote secondmate rows do not probe endpoints; local endpoint reads remain in the fixed passive adapter and currently require tmux.
The socket must be inside an existing canonical, same-UID, mode-0700 directory.
Both peers verify the other's UID; unsupported peer-credential platforms refuse rather than silently weakening the check.
The socket is mode 0600.
A stale path is not automatically unlinked.
On exit the service removes only the socket inode it bound.
The private transport supplies no cross-UID or cross-home action authority.

## Admission and freshness

The engine has independently bounded ordinary and critical I/O lanes and a fixed connection limit.
There is no unbounded executor queue or worker-per-item scheduling.
A timed-out filesystem read still occupies its slot until it actually completes.
Caller cancellation therefore cannot create an unlimited population of abandoned reads.
The critical lane remains independent of hung ordinary work.
Every phase of a presentation batch, including its initial and pre-reply metadata generation barriers, uses ordinary capacity rather than the reserved critical slots.
Kernel syscalls on an unreliable filesystem cannot be forcibly cancelled by Python threads; capacity exhaustion returns a refusal, and this foundation must not be installed as authoritative supervision.

Only concurrent in-flight requests for the same argument set share a native fold.
A completed request is never a cached fresh answer.
The operation captures and rechecks task metadata and root identity, and reads external tool levels afresh.
A bounded disposable status-fold index remembers only a byte-verified local completed prefix, incomplete-line bytes, identity and fold version.
Append-only input reuses that prefix; replacement, truncation, changed kind/vocabulary or changed tool protection rebuilds it.
An incomplete final line is evaluated speculatively from its pre-line state, then replayed as a whole when more bytes arrive, so a partial note or key is never frozen into the index.
The index has fixed entry and byte limits and can be evicted or discarded without changing an outcome.
It is not a presentation cursor and writes no runtime record.
There is no monitoring timer, status-tail inference or cross-cycle verdict cache.
[`fm_view_process.py`](../bin/fm_view_process.py) bounds each passive child group and output stream, using pidfds to observe exit without reaping the leader before cleanup.
A parent that exits while a descendant holds a pipe open cannot strand the observation or orphan that process group.
Missing pidfd/nonreaping-wait support or a nondefault SIGCHLD handler refuses the native passive adapter.
The same process module provides the read-only `ProcessGeneration`/`ProcessPin` primitive used by the explicit foreground owner below.
It opens a pidfd before comparing the selected PID, procfs UID, boot identity and start ticks, then rejects an already-exited pinned incarnation even if a later numeric-PID observation matches.
The generation is an ephemeral in-memory observation, not a new durable owner format.
`wait_exit` waits on that descriptor within one fixed monotonic bound and observes actual kernel process exit without reaping or sending a signal.
A closed socket, returned executor shutdown or stopped process is not exit; a surviving non-daemon thread keeps the observation pending and timeout refuses.
This primitive does not validate home, code, actor, epoch, socket or lifecycle receipts and confers no service readiness or shutdown authority.
Those gates belong to the explicit foreground lifecycle owner below, not this observation primitive.
The native IPC and external-observation path are not yet admitted on non-Linux platforms; their unchanged legacy entrypoints remain selected.
No process-birth or CPU saving has been measured or claimed.

## Explicit compatibility clients

[`fm-view-client.py`](../bin/fm-view-client.py) is a bounded one-request client for an already owner-managed service.
Its header owns invocation and the captured-row TSV interface.
Selection requires explicit `FM_VIEW_SOCKET`, `FM_VIEW_EPOCH` and canonical `FM_HOME`; no config file, home mode or service is changed by a read.
Without explicit selection, existing entrypoints do not require Python.
Unsupported input roots, captured crew overrides, custom classifier/read seams, missing transport or typed service refusals keep the legacy route and report the refusal to stderr.
A successful crew-state read returns before loading the legacy observation graph.
The drain still owns annotation rendering, strong-identity capture, cursor/marker mutation, actor eligibility, preparation, stdout and cursor commit.
With explicit native selection on Linux, its existing classifier owner can capture up to 256 eligible status endpoints and strong birth-time identities in one GNU-stat call, preserving glob order and outbound-parent-channel exclusion.
This optional batch never substitutes the service's device/inode observation identity for the owner's strong identity.
Unsupported platforms, custom size/identity readers, larger or incompatible inventories, partial stat failure, nonregular inputs or malformed rows refuse atomically before output and recapture the entire snapshot through the unchanged legacy owner.
Without explicit selection, the ordinary legacy snapshot is unchanged.
It asks once for native captured annotation lines, unread/open-decision facts and suggested endpoints before printing any status annotation or section, keeping divergence, capped branch outcomes and backstop policy/receipt assignment with their existing owners.
After the actual enrichment delay, the annotation owner admits the whole captured inventory against one fresh bounded strong-identity snapshot from its existing GNU-stat reader, covering direct and historical rows before any annotation output.
Every captured task must still be present, regular, readable and nonsymlink, with its original strong identity and at least its captured byte endpoint; changed inventory, unsupported readers/platforms or malformed/uncertain evidence refuses the entire selection.
Growth beyond a captured endpoint remains admitted but is not presented by this snapshot.
On refusal, all captured annotation groups are discarded and the complete existing legacy annotation reader runs on the same snapshot rather than partially repairing native rows.
Raw wakes remain intact; the existing legacy cursor-lookup refusal still stops the annotation loop at a missing path, so later unrelated rows can be omitted too.
This guard never reads a span or cursor, writes a record or changes the status-section and acknowledgement owners; admitted annotations still consume their captured lines without per-row span/cursor reopens.
The existing signature owner then observes up to 256 historical-only regular-file signatures in one fresh GNU-stat call and reads their reported markers in shell.
The batch shares the ordinary signature parser and encoder, never reuses the earlier presentation capture, and never consults owned-append coverage to suppress an annotation.
Direct rows retain priority and first-seen queue order.
An empty annotation manifest does not load the classifier for path admission.
Every nonempty captured selection needs that existing classifier owner for its fresh path guard; the historical filter itself still returns an empty historical inventory unchanged without an additional load or signature batch.
Unsupported readers/platforms, nonregular or unreadable paths and malformed or incomplete captures discard the entire optional filter before annotation output and run the original per-row replay checks with an explicit diagnostic.
Missing or malformed reported markers remain unreported, preserving the historical warning and every raw wake.
Before native selection, the existing presentation owner independently validates every suggested task/identity/endpoint against its captured snapshot and current cursor manifest under the held presentation lock.
That guard reads the cursor once for the whole batch, rejects missing, duplicate, foreign, malformed or regressive suggestions, and preserves the existing identity/size-reset and legacy-migration boundaries.
A service's claimed observed offset is not sufficient authority to rewind the owner's cursor.
The cursor floor, backstop receipt and commit batch share a bounded nonsymlink regular-file manifest read and project persisted identities through the existing shell identity owner before comparing them.
Binary, oversized, changing or nonregular manifests refuse the optional batch; canonicalization never rewrites the manifest or grants a new mutation owner.
The drain also validates the private client's sorted task groups and complete ordered classification-marker evidence before native selection, so malformed private output falls back to the complete legacy presentation before any annotation or section is printed.
After annotations, at the original acknowledgement-preparation boundary under the held presentation lock, the existing owner rereads every evidenced marker with its existing text reader, validates present markers through its existing parser and compares their normalized bytes.
Unchanged supported evidence retains native suggestions without per-row subprocesses.
Changed, unreadable, malformed, nonregular, symlink or unsupported evidence discards the entire native acknowledgement batch and runs the complete original legacy acknowledgement preparation on the same captured snapshot before any status-section output or commit.
The existing bytewise encoder's 512-byte limit or unavailable bytewise support is unsupported here, never permission to retain stale suggestions.
This late fallback does not replay annotations, replace captured unread/open facts, partially commit endpoints or introduce another writer.
The reported signature and classified offset remain distinct: reported-only changes can alter annotation suppression, whereas the late classified position governs absorption at its original phase.
At the original main-only backstop phase, the existing owner first checks that the captured inventory still has its exact live endpoints and original strong identities with one bounded snapshot.
Only actual native presentation selection attempts the separate fresh backstop read.
Before selecting any returned row, the shell independently rechecks the whole ordered inventory, every receipt against its current locked manifest, and every original strong identity, exact endpoint and returned mtime against another fresh bounded GNU-stat capture.
The optional mtime packet uses the existing snapshot reader and identity composer; neither Python device/inode pairs nor service-claimed receipts acquire cursor authority.
Malformed, regressive, missing, uncertain or changed facts discard the entire optional result for the complete original backstop loop with an explicit diagnostic, never partial repair.
Growth beyond a captured endpoint still defers its backstop, unlike captured unread presentation.
Outcome-store locking, index rebuild/validation, relevance/reserved-key policy, byte caps, receipt assignment and post-stdout commit remain the existing owners.
The admitted native path does not invoke per-row backstop cursor, identity, mtime or latest-span helpers.
Ordinary legacy selection never attempts these reads.
A failed native read falls back before the prepared status sections reach stdout.
Native observation device/inode pairs never replace the original strong identity passed to the commit owner.
A failed stdout leaves the presentation cursor untouched, and concurrent appends past the captured endpoints remain unread.
Only after successful stdout and actual native selection, the existing shell commit owner can capture current strong identities and sizes afresh with the same bounded GNU-stat reader and linearly join its cursor/backstop records once for the whole batch.
It stages the identical four-column manifest and retains the same atomic replacement, selected order, backstop resets and original captured endpoints; newly arrived rows are not consumed.
Unsupported or uncertain captures and strict packet-admission refusals discard the entire private batch and invoke the complete original commit path with an explicit diagnostic.
Ordinary legacy selection never attempts this optimization, and selected-row replacement, deletion, symlink or past-end failure still preserves the previous manifest for retry.
The fleet snapshot can select the same explicit client once for all local task rows, before legacy per-task capture or composition.
Its backlog parser, contribution collector, cross-home ledger/cache collector and summary/publication owners remain unchanged; the read service cannot write their output or retire a dirty trigger.
A refused native batch invokes the entire legacy task capture/composition path before any snapshot output.
The native path no longer invokes per-row cursor/marker-offset helpers, and its optional commit, annotation and fresh backstop batches remove repeated identity/size/cursor, historical-signature and latest-span reads when admitted, but still pays the legacy transaction and passive-adapter graphs.
It is not a completed hot-path migration or a performance acceptance claim.

## Immutable code preparation

[`fm-view-bundle.py`](../bin/fm-view-bundle.py) prepares code for read-service integration without installing an actor, starting a service or changing home selection.
Its header owns invocation, bounds and exit handling; the invoking owner must consume and route any refusal through its existing status/wake path.
[`fm_view_bundle.py`](../bin/fm_view_bundle.py) owns the fixed dependency closure and the `fm-view-bundle.v1` manifest.
The closure includes every native reader and the admitted fixed passive adapter's conditional library graph and tmux backend sibling set, not just Python modules.
Non-tmux passive integrations remain unsupported; preparation grants no new backend capability.
An added reader dependency must update that closure and its relocated-code behavior tests before it is admitted.
Only parent directories derived from that fixed member set are admitted, including the shared lifecycle registry/receipt schemas; arbitrary directories remain unsupported.

Preparation reads regular tracked blobs from a full pinned Git commit, never copies the mutable working tree and refuses dirty tracked source.
Git observation groups reuse the bounded passive-process owner, with a shared 120-second Git preparation deadline and no more than 20 seconds per command.
Inherited Git repository/config injection and replace refs are ignored, and repository hooks/fsmonitor callbacks are disabled for these reads.
The existing private owned canonical store must be outside the operational home and every Git checkout, including pool copies.
A version is published by same-filesystem staging, fsync and atomic nonreplacing rename; unsupported publication primitives refuse.
Existing versions are only verified and reused, never repaired, overwritten or pruned.
Only this invocation's unpublished identity-matching staging directory is disposable.
These are local bounded code objects, not lifecycle receipts, registered actors or health evidence.

The manifest is a canonical sorted-key ASCII JSON object terminated by one newline, with exactly `schema`, pinned `commit`, pinned `tree` and sorted `files`.
Each file row has exactly `path`, Git `mode` (`100644` or `100755`), integer `bytes` and lowercase SHA256 `sha256`.
The SHA256 of the complete manifest bytes is the version directory name and the caller's expected content identity.
Files are owned single-link regular objects with mode 0400 (nonexecutables) or 0500 (executables); version directories are 0500 and the manifest is 0400.
Verification rejects duplicate/unknown manifest fields, unsupported schemas, traversal, missing/extra files, links, special files, mode/count/byte-bound violations, mismatched hashes and changed read identities.
It reads no code from the version being checked and does not import that version as part of verification.
The manifest is content binding, not a signature or authority to run arbitrary code: the invoking launch owner must select an already trusted reviewed identity.
Preparing code neither registers nor starts a production actor; the explicit foreground tool below separately revalidates the selected bundle.

## Read-primitive preflight

[`fm-view-capabilities.py`](../bin/fm-view-capabilities.py) inspects a selected immutable bundle without installing, publishing or starting anything.
Its header owns invocation and exit handling; its invoking owner must consume refusal through its existing status/wake path and retain the complete legacy read selection.
[`fm_view_capabilities.py`](../bin/fm_view_capabilities.py) owns its ephemeral `fm-view-capabilities.v1` response, and [`fm_view_protocol.py`](../bin/fm_view_protocol.py) is the single owner of the engine's admitted verbs and transport/lane limits.
The response has exactly `schema`, `scope`, `home`, `roots`, `bundle`, `python`, `platform`, `features`, `read_protocol`, `verbs`, `bounds` and `authority`.
`scope` is `read-only-primitives`; `roots` binds the observed home/state device-inode pairs, and `bundle` binds its canonical path, manifest identity and pinned commit/tree.
`python` names the minimum and running version; `features` reports successful local peer-UID, pidfd, nonreaping-wait and default-SIGCHLD checks, while `bounds` names the shared primitive limits.
`authority` explicitly sets `installed`, `monitoring`, `identity_bound_shutdown` and `transactions` false.
These observations are not a home lease, health beacon, actor registration, signal target or service-readiness record.

Before emitting any output, inspection verifies every immutable member, checks that its inspector and protocol bytes match this inspector, and requires the store to be outside the operational home and every Git checkout.
A different inspector/protocol refuses rather than borrowing a newer implementation's capabilities; an old version remains inspectable using its own matching tools.
It probes only its own PID with signal0 and a nonreaping self-wait, and uses a private unbound socket pair for peer-UID verification.
Missing Python/kernel facilities, actual syscall refusals, a nondefault SIGCHLD handler, mismatched credentials or changed root identities refuse without successful stdout.
Inspection creates no child, listener, capability file, registry record or receipt, and never dynamically imports an inspected member to discover capabilities.
Like the bundle verifier, the selected inspector and its ordinary modules must themselves be trusted code; self-inspection is not a signature or authority to execute an arbitrary object.
The response is synchronous observation for its invoking owner, not a durable handoff to publish or reuse as fresh evidence.
The explicit foreground owner below must separately apply its lifecycle gates; this inspector grants none of them.
No recurring actor or home mode is introduced by inspection.

## Reader-first lifecycle contracts

[`fm_view_lifecycle.py`](../bin/fm_view_lifecycle.py) owns the initial `fm-view-lifecycle.v1` request and `fm-view-owner.v1` structural record readers used by the explicit foreground owner.
[`fm-view-lifecycle.py`](../bin/fm-view-lifecycle.py) exposes bounded inspection and planned-fragment/candidate-receipt construction; its header owns invocation and input-file requirements.
No command publishes its output, commits a receipt, starts or stops a process, binds a socket, installs an actor or selects a home mode.
A structurally valid record explicitly carries no readiness or signal authority: the inspector deliberately does not verify the selected process, code, socket or root against live state.
Its invoking owner consumes refusal through its existing wake path.

Candidate fragments use home-scoped protocol and process-actor identities, caller-supplied bounds/retry/retention policy and `planned: true`.
They are data for the owning home's future publisher, never an installation declaration from this tool.
The public handoff validator and schemas remain the only registry/receipt grammar owners; they are included in the immutable closure rather than reimplemented or borrowed from a newer checkout.
The first wire version has no historical version-zero writer; an unknown version is refused, with only its common identity envelope read to construct a `version-unsupported` candidate receipt.
A stop request binds its complete selected owner snapshot; a start request cannot claim replacement authority.
Generated receipts bind the canonical request digest, but are only candidate bytes until the owning stage persists them immutably through its declared outbox.
The inspector neither allocates receipt sequence numbers nor provides replay/idempotency admission; the separate internal journal below supplies those primitives without effect authority.
Malformed or unreadable payloads cannot manufacture a valid record identity for a refusal receipt.

### Immutable lifecycle decisions

[`fm_view_journal.py`](../bin/fm_view_journal.py) supplies the explicit foreground owner's internal transaction API, not an intake daemon, launcher or installer.
Its invoking owner must check declared-actor admission before using it and route every refusal through its existing wake path.
All roots, the private outbox staging directory and the owning home's validated nonplanned fragment must already exist; this API creates no root or registration.
The stage's private canonical input and outbox must be disjoint beneath the selected state root.
Its new journal-only nonblocking flock serializes only this stage's receipt writers, never a legacy writer, watcher, queue, presentation, source or custody transaction.
[`fm_view_lock.py`](../bin/fm_view_lock.py) is the shared private-anchor owner for this journal and the service singleton.
The persistent single-link mode-0600 lock anchor is not a process owner or health record and is never unlinked or recovered by PID.
Before opening or creating that anchor, the shared owner pins its private parent directory and checks the descriptor's mode, UID and identity against the caller's already selected parent incarnation.
Anchor creation is relative to that verified descriptor, so pathname replacement cannot create an anchor in a successor tree; the final root/anchor barriers still refuse changed observations.
Failed construction or context entry closes acquired descriptors and releases its lock without removing the anchor or suppressing the original failure.
The parent descriptor is also retired on successful construction.
The start owner takes its separate service singleton before any journal construction or admission; stop intake never takes the live singleton, and no journal transaction spans an external effect or wait.

Intake selects a filename `<record>.<attempt>.json`, with the existing bounded token grammar for `record` and a positive decimal attempt within the declared retry limit.
A valid payload must match that filename's identity, selected home and stage owner.
An unknown version reads only its common bound envelope and produces `version-unsupported`; malformed or unreadable payloads produce `input-invalid` using the filename identity rather than partially trusted JSON.
An invalid filename cannot supply a receipt identity and refuses synchronously to its invoking owner.
Receipts retain the shared handoff grammar, with the owner's `input-sha256` extension binding exact input bytes or the explicit value `unreadable` when no complete bounded regular read succeeded.
The shared candidate constructor additionally binds canonical request bytes; neither extension grants process authority.

Each decision validates before writing, fsyncs a private `.tmp` file, publishes with nonreplacing rename and fsyncs both directories, then rechecks roots, lock anchor and exact published inode/bytes before returning success.
Incomplete staging refuses another publication for owner reconciliation rather than accumulating files or deleting uncertain evidence.
Existing receipts are never edited or replaced; only this invocation's identity-matching unpublished staging file can be removed.
The journal scans at most 1024 entries and eight MiB of receipt bytes per transaction, with the lifecycle reader's per-file limit, and refuses the whole history on malformed, foreign, misnamed, unbound or discontinuous decisions.
It has no recurring scan or polling loop.

A first decision has sequence 1 and is `accepted` or `refused`; only matching accepted input can transition to sequence 2, `done` or a declared refusal.
A replay returns the existing immutable decision with `fresh: false`, not another acceptance or permission to retry an effect.
Accepted-without-completion after a crash is ambiguous: the foreground owner must verify the effect, not repeat it.
A retry is the next attempt after a prior refusal, never after acceptance, completion or `effect-failed`, which may represent an ambiguous effect.
A failed publication or directory fsync never returns success; if rename committed before failure, the next transaction discovers that original decision and cannot treat it as fresh.
These primitives alone validate no actor, capability, code, socket or process, and do not prove actual exit.

The internal `ServiceSingleton` primitive binds canonical home/state/runtime identities and serializes starts across all runtime directories of that one home with the persistent state-root `.view-service.lock` anchor.
Its boundary is independent of the journal and every legacy transaction; admission creates no service, socket, owner record, receipt or health evidence.
The explicit foreground owner retains that descriptor through actual process exit after effects begin, including surviving non-daemon observation threads; leaving a context or closing a listener is not that proof.
The foreground owner below is responsible for trusted immutable code selection, declared-actor admission, reader capability publication, live root/socket/epoch/process revalidation, service-singleton lifetime and receipt-before-effect ordering.
It must also prove actual generation-pinned process exit and preserve replacement paths on cleanup.
A candidate receipt or structurally matching PID is not permission to bypass any of those gates.
The read-only `ProcessPin` primitive remains distinct from this wire reader and from that effect owner.

## Explicit foreground lifecycle owner

[`fm-view-service.py`](../bin/fm-view-service.py) invokes [`fm_view_service.py`](../bin/fm_view_service.py) synchronously from an already trusted immutable bundle.
Its header owns invocation, fixed runtime names, output and exit handling.
It neither installs nor commissions itself, creates roots, publishes a registry fragment, chooses a home mode or repairs a previous service.
Its invoking home owner must consume every output and the eventual process exit and route failures through its existing wake path; there is no autonomous recovery or independent health claim.
The immutable closure includes the shared actor checker and its schema/IO dependencies.
A mutable checkout or nonisolated interpreter refuses before actor or lifecycle writes.
The selected contract must be a canonical private file in this home's published registry, not a candidate or planned stage.
The existing actor install check must return declared against that exact published fragment; none, grandfathered and foreign declarations do not grant admission.

The journal's shared bounded filename/payload reader first supplies a read-only selection without a lock anchor or decision.
A start acquires the service singleton before constructing or admitting through the journal, then passes that same descriptor to the foreground owner.
A contended start refuses synchronously without a journal anchor, receipt, ready or runtime effect, preserving the original service.
Stop intake remains separate and never takes the live singleton.
Locked admission independently matches that exact preliminary selection, including its raw-input fingerprint, before publishing any decision; an input replaced between stop selection and admission therefore cannot become an unlocked start.
Malformed and unknown-version inputs retain filename-bound refusals through that same reader, never an operation-only second parser.
Acceptance still precedes every runtime publication, bind or signal, with fresh request/receipt revalidation at the effect boundary.
After its required admission boundary, terminal replay returns only historical results without a new ready or effect, and accepted-without-completion replay refuses as ambiguous without rewriting its history.
The runtime pins its selected private directory descriptor before any creation; bounded publication and socket bind are relative to that descriptor, with namespace rechecks as additional refusals.
It never unlinks an existing runtime object to make startup work.
Fresh primitive capabilities must match the selected digest and are published immutably before bind; they remain observations, not a monitoring lease.
Owner publication binds roots, code, capabilities, epoch, start request, actual process generation and socket identity.
Clients are accepted only after those startup gates; ready output additionally requires the completed start receipt.
The read transport, classifier modules and existing transaction owners are unchanged.

The start owner releases that same singleton only on pre-effect failure or non-effect replay; once effects can begin it deliberately has no Python close path.
The kernel alone releases its descriptor on actual process exit, including interpreter shutdown while non-daemon observation threads remain alive.
Closing the listener, returning executor shutdown or returning the foreground command does not release that admission.
No legacy watcher, presentation, queue, custody, source or lease boundary is substituted.
Stop revalidates the exact selected owner, original completed start input/receipt, fresh capabilities, roots and socket, opens a pidfd before checking process generation, and verifies actual listener peer PID/UID against that pin.
It repeats the live bindings after receipt/request revalidation, signals TERM only through that pidfd and waits within the original operation deadline for actual kernel exit.
SIGSTOP, ignored TERM and surviving threads therefore refuse a successful shutdown; there is no automatic SIGKILL, numeric-PID or process-group fallback.
Normal cleanup addresses only this invocation's still-matching owner/socket in its pinned runtime; replacement objects are preserved and reported, and a changed root refuses cleanup.
Capabilities, requests and immutable receipts remain retained for their owning protocol; a new incarnation requires explicit fresh runtime/epoch selection rather than stale-object removal.
The ephemeral `fm-view-service-result.v1` stream distinguishes ready/owner, historical receipt results, verified exited results and `foreground-return` with `exited: false` and explicit per-object cleanup outcomes.
It is consumed synchronously by the invoking owner, never as an authoritative watcher beacon or new recurring alarm store.
No live installation, home selection, complete hot-path migration or B0 performance acceptance follows from this entrypoint.

## Verification and remaining migration

[`tests/fm-supervision-views.test.sh`](../tests/fm-supervision-views.test.sh) runs isolated real-socket, bounded-lane and legacy-fold comparison tests in CI.
Its public bundle CLI cases additionally exercise pinned old/new versions, full verification and idempotent concurrent publication, dirty/missing/symlink/oversized source refusal, unsafe stores, invalid identities/manifests and immutable existing-version refusal without repair.
Lifecycle-contract cases exercise the public inspector CLI, public registry/receipt validation, independent malformed-field and stop-binding controls, unknown-version envelope refusal, bounded hostile file shapes and process/socket/record-effect tripwires.
A relocated contract-reader control hides its source checkout, verifies a planned candidate through the bundled shared schema owner, then corrupts that schema alone and requires explicit refusal rather than borrowing another copy.
Each damaged-member control first verifies an independent intact version, so an unrelated corrupt member cannot make that check vacuous.
Public capability-CLI controls compare the complete response, relocate matching inspectors while hiding their source checkout, forbid child creation and compare all home/store entries and bytes before and after inspection.
Independent unsupported-symbol and actual syscall/peer-UID refusals require empty stdout, while corrupt bundles, mismatched inspector versions, unsafe roots and probe-time replacement of each root refuse without modifying retained originals.
Both old and new immutable versions remain inspectable with their own matching tools.
Relocated-code controls hide their source checkout and require complete passive packet equality across all five fixed operations, a native fold and unchanged home records; these are code-closure controls, not proof of every successful custody/forge branch or a service lifecycle gate.
Read-only process-pin cases exercise real exec-stable identity, parent-owned unreaped exit, PID/start/UID/boot mismatches, descriptor retirement, a real non-daemon thread surviving simulated socket/executor cleanup, SIGSTOP, and exit between pidfd acquisition and generation validation.
They refuse unsupported facilities and malformed, partial, oversized, missing, symlink and nonregular identity reads without any signal or reaping effect.
The fixture alone owns child teardown; these are kernel-observation controls, not service-stop or lifecycle-receipt acceptance.
It checks keyed transitions, correlation tokens, malformed time tags, terminal-task versus persistent-mate folds, protected tool blockers, incomplete final lines, invalid UTF-8, fresh tool levels without status changes, generation/root refusal, single-flight and timeout reservation.
Native crew-state cases also compare the legacy public CLI on identical isolated git repositories and captured fake no-mistakes/backend/forge responses.
They include fresh HEAD, daemon and semantic-pane negative controls without status changes, selected-run identity, gate authority, coarse dead-instrument outcomes and a backend no-lifecycle tripwire.
Captured-presentation tests compare unread rows, folded decisions, new-line spans and suggested contiguous endpoints against the existing shell presentation transaction APIs across all task kinds, classified/fully-presented combinations, partial lines and invalid UTF-8.
They also exercise append-bounded snapshots, whole-batch refusal on replacement/truncation/generation changes, fresh protected tool levels and batch single-flight/timeout fairness without writing a native cursor.
Separate initial/final-generation-barrier stalls saturate ordinary capacity with concurrent batches and prove both critical slots still admit status-fold observations.
Real public entrypoint fixtures additionally compare native/legacy drain rendering and committed cursor bytes, failed-stdout retry, append during observation, epoch-refusal fallback and captured-crew override fallback.
Queued-signal fixtures also compare full annotation bytes and committed cursor bytes, including whitespace, invalid UTF-8, repeated latest lines and an append after native capture.
A renderer tripwire supplies a real strong-identity snapshot and refuses any attempted cursor/span reopen on the admitted path.
Annotation path-admission cases require one whole-inventory stat and no per-row identity/size/span/cursor helpers, admit captured-end growth, and refuse deletion, rotation, truncation, symlinks, unreadable/nonregular paths, incomplete/malformed/error captures and malformed inventories without output or record mutation.
Real-client actual-enrichment controls pin deletion both after a successful nonempty native capture and before its status read, separating whole legacy annotation fallback from early native refusal.
They cover direct and historical rows and compare complete output/cursor bytes against the legacy owner at the same annotation-time input while preserving ordered raw wakes.
Deleted-middle-path controls explicitly retain the legacy one-annotation boundary; separate deleted-last-path controls require both unrelated annotations in order.
An intentionally incomplete unaffected native group must also be discarded on late deletion or malformed/error admission captures, detecting partial repair or output before whole-batch validation.
The original delayed-deletion queue case and actual-delay append/classified-marker regression remain unchanged.
A real-client corruption fixture reverses its annotation groups after a successful socket read and requires complete legacy output and cursor parity, detecting validation that happens only after native selection.
The presentation parity matrix also exercises native offset batching against those same real owner-written cursor and marker records.
Strong-snapshot capture tests compare every output byte with the legacy owner in C and UTF-8 locales, including unavailable birth time, growth, rotation, empty/nonregular inputs and parent-channel bindings.
They require one stat invocation for the entire admitted inventory, zero for an empty inventory, and no partial output on malformed, short, extra, nonregular, symlink-swapped or deleted inputs; unsupported overrides and oversized inventories retain legacy admission rather than truncating.
A real native-service/client drain case also requires full output and committed-cursor equality after both successful batching and malformed-stat whole-snapshot recapture, while the nonselected legacy CLI never attempts that batch.
Presentation-commit cases compare complete manifests with the legacy owner under C/UTF-8 for old/new/missing cursors, ordering, carried/acknowledged/reset backstops, growth beyond the selected endpoint and newly arrived unselected rows.
They require one fresh stat for the admitted inventory with per-row identity/size/backstop readers forbidden, preserve the old cursor and protected target on selected-row rotation/deletion/truncation/symlink or past-end acknowledgement, and retain complete legacy fallback for malformed captures or cursor packets.
The real-client whole-drain case observes successful nonempty native reads for both normal commit batching and a separately corrupted commit-time capture, requiring identical full output/cursor bytes and no batch attempt by ordinary legacy selection.
Historical-signature cases compare complete signatures against the original owner in C/UTF-8, including empty files, unavailable birth time, mode changes, growth and same-size replacement.
They require one stat for an admitted inventory, none for an empty inventory, and atomic refusal on malformed, short, extra, nonregular, symlink-swapped, deleted, oversized or custom-reader inputs.
Real-client drain fixtures compare full output and cursor bytes across new/old/missing/malformed markers, owned growth and mixed direct/historical duplicate keys, requiring successful nonempty native reads and forbidding per-row signature commands on the admitted path.
Separate malformed/error captures require the complete legacy replay filter, while ordinary legacy selection never attempts the batch.
A controlled real enrichment-delay fixture changes either the status bytes or marker after native capture and requires the same late-observed suppression decision and captured-end cursor as legacy.
The classified-marker update in that original regression remains at its actual post-native delay seam, not replaced by a reported-only edit or moved ahead of observation.
Separate real-client controls cover unchanged admission, reported-only edits, classified advances/regressions, deletion, malformed/unreadable/nonregular markers and the bounded encoder's unsupported case.
On every late-fallback control, a deliberately conservative valid suggestion for another unchanged task must also be discarded, distinguishing whole-batch legacy acknowledgement preparation from per-row repair.
Malformed service evidence and corrupted successful-client evidence must instead cause complete legacy presentation before annotation output, with full output/cursor equality.
A late-fallback failed-stdout control preserves the previous cursor and requires a fresh successful retry.
Standalone captured-renderer cases retain cursor/span tripwires, require no classifier load for empty/direct-only inventories, exercise historical lazy loading and print complete stderr on failure.
The fork-free-helper suite compares late marker evidence against the original normalized text reader in its interpreter/locale matrix and forbids per-row spawned commands on the supported path.
The original late-reader and independent early-swap regressions remain separate.
Backstop cases compare complete late latest-event/receipt facts with the original public shell APIs across the 64-KiB boundary, whitespace, CRLF, NUL, invalid UTF-8, partial lines and old/reset/missing cursor rows without record mutation.
Independent shell-guard controls require a single stat and no per-row readers, and reject malformed/duplicate/missing/reordered facts, changed receipts, mtime, endpoints, identities and incomplete/error captures before selection.
Real-client full-drain controls require a successful nonempty backstop RPC, fresh same-size status text after the initial capture, whole stdout/cursor parity and per-row stat/latest-reader tripwires.
Malformed service replies and valid but incorrect receipts/mtimes must discard every returned row, including an independently poisoned unaffected row; a separate post-read same-size rewrite must reach complete legacy fallback.
The existing full drain/queue matrices keep empty queues, delayed signals, actor exclusion, failed stdout/retry, bounded history, receipt failures and outcome-index refusal/rebuild coverage.
Backstop initial/final-generation stalls must leave both critical slots available; repeated calls must reread a changed receipt without any status change.
The capture/commit fixture's existing five-field stat tripwire remains scoped to those phases, not the distinct six-field backstop mtime captures.
These invocation assertions are mechanism checks, not a B0 performance result.
Additional cases cover missing manifests/rows, legacy migration refusal, identity/size reset, malformed and replaced cursors, fresh offsets without status changes and the new verb's ordinary-lane generation barriers.
Real-client regressions corrupt the service's observed offset or suggested endpoint, then separately corrupt successful client output after its reply checks, requiring full legacy output/cursor parity and an explicit refusal diagnostic for regressive, duplicate, missing, foreign, identity-mismatched and past-end suggestions.
They require an observed native call to prevent a silent legacy-only pass.
The suite does not test against live endpoints or start a backend.

Native task-row snapshot tests compare complete legacy rows (before the public composer's backlog enrichment) across task kinds, timestamp/decision histories, reports, remote rows and missing worktrees, plus captured append boundaries and metadata replacement that discards every mutable surface.
Real-client tests retain whole public JSON equality, including parent activity, original status-mtime freshness and metadata-bound terminal evidence after status bytes and mtime change beyond the native capture barrier.
Malformed capture bindings/counts/presence/timestamp types and occupied, public-mode or symlink staging directories must refuse before native selection and preserve complete legacy fallback without writing a protected target.
They include a fresh semantic-pane negative control without status changes, unsupported backend refusal, bounded inventory/file rejection, prefix-related task-id ordering, real-client whole-snapshot equality/fallback, batch single-flight and a timed-out subscriber while both ordinary workers are held and critical folds still complete.
Separate real-client atomic same-generation metadata-rewrite cases exercise initial and final barriers and require complete legacy recapture, updated PR/decision fields and an explicit refusal diagnostic; actual replacement-generation evidence discard is tested independently.
Whole public home-summary JSON and the atomically published ledger are compared against legacy with a pinned primary-readiness wall timestamp and unchanged real elapsed-time calls.
The real-client fixture requires nonempty native task observations, compares every summary field without normalization, retains an empty-child parity control and establishes a backlog-owned working child with isolated Git and passive endpoint inputs before requiring nonempty active-child parity.
It checks changed decisions on a fresh publication and retains complete fallback on epoch refusal.
A separate native-composition timeout fixture preserves the previous ledger bytes and owed trigger, then requires a fresh retry to publish a complete legacy-equal updated ledger.
A real summary-refresh fixture also holds native composition while a newer trigger arrives, verifies the first atomic ledger contains only its captured decision, and requires the surviving pending marker to produce the newer decision on the next refresh.
Live service lifecycle registration and promotion of this foundation remain incomplete.
The same CI entrypoint also runs the existing complete [`fm-crew-state.test.sh`](../tests/fm-crew-state.test.sh) case pool with its assertions unchanged, selecting a real native socket/client for each suite-owned isolated request through [`crew_matrix.py`](../tests/fixtures/supervision-views/crew_matrix.py).
Its fixture refuses any state root outside that suite's temporary tree and uses each case's existing fake adapters, not live endpoints.
Only the declared unsupported integration refusals, missing client interpreter and the explicitly marked legacy fake-interpreter timeout seam retain the original legacy executable; every native selection and fallback reason is counted, zero native coverage fails, and any unexpected refusal fails instead of silently converting coverage to legacy.
Separate real-SQLite exclusive-lock and expensive-query cases compare whole native/legacy current-state output within the read bound, require available-id preservation, and prove fresh recovery after releasing the lock without changing status bytes.
The complete case pool also exercises missing SQLite through the real socket/client, requiring capped-inventory unknowns and complete-inventory gate retention rather than a transport exception.
The default legacy matrix remains independently selected by its existing CI tier.
The same entrypoint additionally selects isolated native services for every existing fleet-snapshot/view and drain/open-decision case through [`view_matrix.py`](../tests/fixtures/supervision-views/view_matrix.py).
Those matrices keep their existing assertions, collect all independent case failures, count successful RPC verbs/nonempty items and explicit fallback reasons, and fail on unexpected refusals or zero native coverage, including an empty-batch-only pass.
The declared non-tmux snapshot endpoint and over-bound status-line paths remain explicitly counted legacy fallbacks, with real-client whole-output/cursor parity regressions for these refusals.
Seven cases whose assertions specifically require the legacy persistent fold cache or shell read-probe run that owner explicitly and are counted as legacy-only, never native coverage.
A separate resident real-client lifecycle regression compares complete output and presentation cursors through repeated growth, resolution, truncation, same-size rotation and a kind change without status mutation; it also requires native calls and proves obsolete legacy fold caches are neither authoritative nor rewritten by the native read.
The wrapper passes the original stdout descriptor directly to the shell owner so failed-output regressions cannot accidentally commit before a buffered wrapper write fails.
A no-request path is disclosed separately, not counted as native coverage; these include early lock/validation refusals that never reach read selection.
The snapshot's legacy fold-cursor, fake-copy race and byte-probe assertions additionally require real-client pre-RPC refusal and complete legacy fallback, never native cursor coverage.
Separate resident append cases compare whole public snapshot output without native writes to the legacy snapshot cursor.
Current-state parity also covers explicit no-run answers, positive daemon-running evidence and no-checks/no-CI markers that cannot promote a reported green claim.
Device-renumber cases retain whole drain/cursor parity, independent corrupt-client rewind refusal, receipt preservation and descriptor device/inode checks.
The complete existing [`fm-wake-queue.test.sh`](../tests/fm-wake-queue.test.sh) case pool also selects this isolated drain wrapper, retaining concurrent append/ack, actor exclusion, recovery generations, interruption and lock/claim assertions with all independent cases collected before its summary.
The wrapper forwards interruption signals to its actual shell child and the lock-boundary test verifies that direct parent relation rather than confusing wrapper and transaction-owner PIDs.
The original late Perl-reader symlink-swap case retains every assertion through its legacy owner and is counted separately, not as native coverage.
A separate real-client early-swap regression injects at the native regular-file reader and requires its actual nonsymlink refusal plus complete output parity with legacy on that same early-swap input, ordered raw rows, equal annotation counts and no target disclosure.
It also probes the legacy cursor API before and after the swap: a regular file must be accepted and the early symlink must refuse, independently of output parity.
That early cursor refusal precedes the historical annotation in legacy too; the original late-reader case still requires that annotation.
Only the existing explicit delayed-deletion fixture's identity-change refusal is admitted as an early matrix race fallback, never a native success or arbitrary-error exception.
Deletion after successful native capture instead reaches the annotation-time whole-selection fallback above; its explicit legacy annotation diagnostic is not native annotation proof.
Its default legacy selection remains independently exercised by the existing CI tier.
This matrix execution is a behavior gate, not evidence that all integrations are implemented natively or that the performance contract passed.
There is no P0 replay adapter or B0 performance acceptance yet.
Before an installed service or compatibility client is added, its owner must complete those migrations and the registration/actor/receipt requirements in [handoff coverage](handoff-coverage.md).
Identity-bound shutdown is confined to the explicit foreground owner above; compatibility refusals already fall back to legacy before presentation commits.
The journal API's CI cases cover immutable replay and completion, filename-bound malformed/unknown/unreadable input, independent root/anchor replacement, failed-entry descriptor retirement and same-anchor reacquisition, serialization, bounded history, failed writes/rename/fsync and single-guard counterfactuals without any service, signal, socket or authoritative record effect.
Service-singleton cases additionally cover cross-process and cross-runtime contention, independence from the journal, opaque healthy anchor bytes, unsafe roots and anchor types, failed-entry descriptor retirement after root/anchor replacement, same-original-anchor reuse and independent selected-root/namespace counterfactuals.
Both public constructors have existing-anchor and first-creation before/after-parent-open replacement controls requiring untouched successor trees, descriptor retirement before reuse and same-original-anchor reacquisition when one survives.
Independent selected-parent/privacy guard and descriptor-relative-creation counterfactuals keep the later root/anchor barriers intact; failed parent observation, interruption, anchor open and parent close also require descriptor retirement.
These are mutex-admission controls, not proof of a foreground service lifetime, receipt-before-effect ordering or identity-bound shutdown.
A separate isolated foreground stage prepares its actual immutable dependency closure and exercises the public service command with real fixture-owned processes and sockets.
It witnesses durable acceptance and capability publication at the actual bind, refuses actor/receipt/bind failures without ready, validates public lifecycle receipts and preserves queue/status/custody bytes and the ordinary legacy selection.
Competing-start cases require no new journal receipt or anchor even for a first-use outbox, unchanged runtime and preservation of the original live service; reverting only pre-journal singleton admission must fail those same no-write oracles.
Public start and stop accepted-without-completion controls require explicit nonzero ambiguous refusal, no new ready/effect and unchanged immutable history; reverting only that guard must fail the same public exit oracle.
A separate stop-to-start input replacement at the preliminary/locked-read seam refuses before any receipt, and reverting only that selection fence must fail its same public refusal oracle.
Terminal done and refused replay remain separately covered, and a stop replay must not contend with the original live singleton.
Wrong process generations, live listener identity, epoch, capability, start receipt, root or socket bindings refuse stop without signalling a separately owned process.
Stopped, TERM-ignoring and non-daemon-thread processes prove actual-exit refusal and singleton retention after foreground return; only fixture teardown restores or forcibly retires those children.
Runtime constructor and publication replacement controls retain successor trees, retire descriptors and require the same preservation oracle to fail when only descriptor-relative creation is reverted.
These fixture results do not authorize a live service, actor installation or home mode.
Rollback of this uninstalled foundation is removal or non-use of the modules; no queue, cursor, custody or home mode changes to undo exist.
