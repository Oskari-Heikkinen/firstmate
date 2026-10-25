# Read-only supervision view primitives

This is the maintainer owner of the Python 3.9+ view-engine primitives in [`fm_view_engine.py`](../bin/fm_view_engine.py) and [`fm_view_status.py`](../bin/fm_view_status.py).
These modules are an **uninstalled foundation**, not a completed replacement for crew-state, wake drain or fleet snapshots.
Existing shell entrypoints remain selected without a new runtime dependency.
There is no service launcher, mode switch, service installer, health beacon, lease or watcher integration.
The [`supervision-views` skill](../.agents/skills/supervision-views/SKILL.md) owns the agent load trigger.

## Authority boundary

`Inputs` reads only an explicitly supplied canonical home and its identity-bound state root.
Task ids cannot contain path separators.
Regular-file reads are bounded, refuse final-component symlinks and special files, and check same-descriptor and final-path identity.
A changed metadata capture or root refuses the observation rather than attributing it to a replacement task.
A missing status file is an empty span; an existing unreadable or unsupported object is a failure, not an empty successful fold.
The native fold reads registered alert-store levels on every request, even when status bytes have not changed.
The shell classifier remains the parity oracle; it has not been replaced by these modules.

The transport admits `status-fold`, `crew-state`, `status-presentation`, `drain-presentation` and `snapshot-tasks` requests.
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
Fixed passive backend, custody, done-head and forge reads retain their existing owners through [`fm-view-adapter.sh`](../bin/fm-view-adapter.sh); the native engine does not duplicate those contracts.
Backend fallback currently admits tmux only, and remote endpoint reads remain legacy-owned.
A run-step observation that needs no backend probe can still be computed natively on other recorded backends.
An unsupported integration refuses for explicit legacy fallback, never an optimistic current-state answer.
The captured-presentation verb takes only `rows`, at most 256 objects with exactly `task`, `end`, `offset`, `identity`, `classified` and `fully_presented`.
Its classifier owner is [`fm_view_presentation.py`](../bin/fm_view_presentation.py).
The invoking presentation transaction supplies captured byte endpoints, contiguous presentation/classification offsets, device/inode pairs and the annotation's fully-presented flags.
Every offset is a nonnegative integer within the per-file bound, with `offset <= end`; booleans are not offsets.
The reply preserves request order and returns each row's captured endpoint/generation, new nonblank lines, unread informational lines, open decisions, its `observed_offset` and a suggested `acknowledged_end`.
The client requires an integer observed offset within the captured endpoint and rejects suggestions below it; the captured-offset API also requires exact equality to its caller-supplied offset.
A suggestion has no acknowledgement effect: the invoking owner must still verify its original strong birth-time identity and commit only after the prepared output reaches stdout.
Device/inode pairs are observation checks and disposable index keys, never substitutes for those strong cursor identities.
The `drain-presentation` verb instead accepts rows with exactly `task`, `end`, `identity`, `strong_identity` and `fully_presented`.
[`fm_view_offsets.py`](../bin/fm_view_offsets.py) reads the existing presentation manifest once for that batch, and reads each task's classification marker without spawning a helper.
The original transaction supplies `strong_identity`; native code compares its persisted value, never upgrades it or substitutes a new identity proof.
A missing manifest with a legacy migration cursor refuses for its existing owner to migrate, while a missing row in an existing manifest starts at zero.
Malformed, unsupported or changing cursor state refuses the whole read before native selection.
The batch folds only through each captured endpoint, so concurrent appends remain unread for a subsequent presentation.
A missing, replaced or truncated input, changed prefix or changed metadata generation refuses the entire batch, without a partial successful result or cursor write.
Batches retain at most 64 MiB of captured status bytes and four MiB of metadata; oversized batches refuse for explicit legacy fallback rather than silently omitting rows.
Unsupported fields, duplicate JSON keys, nonfinite numbers, unsupported verbs and mismatched home/epoch refuse the request.
A response binds the same protocol, home, epoch and nonce, with `ok` and either `result` or a typed refusal message in `error`.
Requests and responses are limited to one MiB; regular input files are limited to four MiB.
These bounds are prototype limits, not a claim that every existing fleet input fits them.

The `snapshot-tasks` verb composes the local `tasks[]` rows through [`fm_view_snapshot.py`](../bin/fm_view_snapshot.py).
Its arguments are `observed_at`, integer `epoch`, positive integer `concurrency` and `task_timeout`, plus the same bounded crew `options` vocabulary as current-state reads.
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
It asks once for native captured annotation lines, unread/open-decision facts and suggested endpoints before printing any status annotation or section, keeping divergence, capped branch outcomes and the latest-outcome backstop with their existing owners.
The annotation renderer consumes those captured lines without reopening each span or cursor; historical replay suppression remains with its existing signature owner.
Before native selection, the existing presentation owner independently validates every suggested task/identity/endpoint against its captured snapshot and current cursor manifest under the held presentation lock.
That guard reads the cursor once for the whole batch, rejects missing, duplicate, foreign, malformed or regressive suggestions, and preserves the existing identity/size-reset and legacy-migration boundaries.
A service's claimed observed offset is not sufficient authority to rewind the owner's cursor.
The drain also validates the private client's sorted task groups before native selection, so malformed annotation facts fall back before any annotation or section is printed.
A failed native read falls back before the prepared status sections reach stdout.
Native observation device/inode pairs never replace the original strong identity passed to the commit owner.
A failed stdout leaves the presentation cursor untouched, and concurrent appends past the captured endpoints remain unread.
The fleet snapshot can select the same explicit client once for all local task rows, before legacy per-task capture or composition.
Its backlog parser, contribution collector, cross-home ledger/cache collector and summary/publication owners remain unchanged; the read service cannot write their output or retire a dirty trigger.
A refused native batch invokes the entire legacy task capture/composition path before any snapshot output.
The native path no longer invokes per-row cursor/marker-offset helpers, but still pays the legacy snapshot, commit and historical-signature reads.
It is not a completed hot-path migration or a performance acceptance claim.

## Verification and remaining migration

[`tests/fm-supervision-views.test.sh`](../tests/fm-supervision-views.test.sh) runs isolated real-socket, bounded-lane and legacy-fold comparison tests in CI.
It checks keyed transitions, correlation tokens, malformed time tags, terminal-task versus persistent-mate folds, protected tool blockers, incomplete final lines, invalid UTF-8, fresh tool levels without status changes, generation/root refusal, single-flight and timeout reservation.
Native crew-state cases also compare the legacy public CLI on identical isolated git repositories and captured fake no-mistakes/backend/forge responses.
They include fresh HEAD, daemon and semantic-pane negative controls without status changes, selected-run identity, gate authority, coarse dead-instrument outcomes and a backend no-lifecycle tripwire.
Captured-presentation tests compare unread rows, folded decisions, new-line spans and suggested contiguous endpoints against the existing shell presentation transaction APIs across all task kinds, classified/fully-presented combinations, partial lines and invalid UTF-8.
They also exercise append-bounded snapshots, whole-batch refusal on replacement/truncation/generation changes, fresh protected tool levels and batch single-flight/timeout fairness without writing a native cursor.
Separate initial/final-generation-barrier stalls saturate ordinary capacity with concurrent batches and prove both critical slots still admit status-fold observations.
Real public entrypoint fixtures additionally compare native/legacy drain rendering and committed cursor bytes, failed-stdout retry, append during observation, epoch-refusal fallback and captured-crew override fallback.
Queued-signal fixtures also compare full annotation bytes and committed cursor bytes, including whitespace, invalid UTF-8, repeated latest lines and an append after native capture.
A renderer tripwire refuses any attempted cursor/span reopen when captured annotation facts are supplied.
A real-client corruption fixture reverses its annotation groups after a successful socket read and requires complete legacy output and cursor parity, detecting validation that happens only after native selection.
The presentation parity matrix also exercises native offset batching against those same real owner-written cursor and marker records.
Additional cases cover missing manifests/rows, legacy migration refusal, identity/size reset, malformed and replaced cursors, fresh offsets without status changes and the new verb's ordinary-lane generation barriers.
Real-client regressions corrupt the service's observed offset or suggested endpoint, then separately corrupt successful client output after its reply checks, requiring full legacy output/cursor parity and an explicit refusal diagnostic for regressive, duplicate, missing, foreign, identity-mismatched and past-end suggestions.
They require an observed native call to prevent a silent legacy-only pass.
The suite does not test against live endpoints or start a backend.

Native task-row snapshot tests compare complete legacy rows (before the public composer's backlog enrichment) across task kinds, timestamp/decision histories, reports, remote rows and missing worktrees, plus captured append boundaries and metadata replacement that discards every mutable surface.
Real-client tests retain whole public JSON equality, including parent activity, original status-mtime freshness and metadata-bound terminal evidence after status bytes and mtime change beyond the native capture barrier.
Malformed capture bindings/counts/presence/timestamp types and occupied, public-mode or symlink staging directories must refuse before native selection and preserve complete legacy fallback without writing a protected target.
They include a fresh semantic-pane negative control without status changes, unsupported backend refusal, bounded inventory/file rejection, prefix-related task-id ordering, real-client whole-snapshot equality/fallback, batch single-flight and a timed-out subscriber while both ordinary workers are held and critical folds still complete.
Separate real-client atomic same-generation metadata-rewrite cases exercise initial and final barriers and require complete legacy recapture, updated PR/decision fields and an explicit refusal diagnostic; actual replacement-generation evidence discard is tested independently.
A real summary-refresh fixture holds native composition while a newer trigger arrives, verifies the first atomic ledger contains only its captured decision, and requires the surviving pending marker to produce the newer decision on the next refresh.
Full snapshot/publication parity, service lifecycle registration and the complete existing parity matrix are not implemented by this foundation.
The same CI entrypoint also runs the existing complete [`fm-crew-state.test.sh`](../tests/fm-crew-state.test.sh) case pool with its assertions unchanged, selecting a real native socket/client for each suite-owned isolated request through [`crew_matrix.py`](../tests/fixtures/supervision-views/crew_matrix.py).
Its fixture refuses any state root outside that suite's temporary tree and uses each case's existing fake adapters, not live endpoints.
Only the declared unsupported integration refusals and missing client interpreter retain the original legacy executable; every native selection and fallback reason is counted, zero native coverage fails, and any unexpected refusal fails instead of silently converting coverage to legacy.
The default legacy matrix remains independently selected by its existing CI tier.
This matrix execution is a behavior gate, not evidence that all integrations are implemented natively or that the performance contract passed.
There is no P0 replay adapter or B0 performance acceptance yet.
Before an installed service or compatibility client is added, its owner must complete those migrations and the registration/actor/receipt requirements in [handoff coverage](handoff-coverage.md).
Identity-bound service shutdown remains future integration work; compatibility refusals already fall back to legacy before presentation commits.
Rollback of this uninstalled foundation is removal or non-use of the modules; no queue, cursor, custody or home mode changes to undo exist.
