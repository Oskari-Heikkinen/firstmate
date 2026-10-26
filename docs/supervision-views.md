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
SQLite support is needed only for capped run inventories; an unavailable module returns an explicit inventory-reader unknown with the available ids, while complete overviews remain usable.
The native SQLite reader shares one elapsed bound across connection, lock waits, query execution and validation, with VM-progress interruption and per-query remaining lock budgets.
Unreliable filesystem stalls still retain their original bounded worker slot rather than spawning a replacement.
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
Its reply additionally carries `classification_markers` in request order, each with exactly `task` and `text`: null for an absent marker, otherwise the captured text with NULs and trailing newlines removed, bounded to 4096 bytes.
The client validates the complete count, binding, text type, normalization and bound before emitting any private marker-evidence records; its header owns that TSV encoding.
This evidence is not a classification receipt or acknowledgement and writes no record.
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
With explicit native selection on Linux, its existing classifier owner can capture up to 256 eligible status endpoints and strong birth-time identities in one GNU-stat call, preserving glob order and outbound-parent-channel exclusion.
This optional batch never substitutes the service's device/inode observation identity for the owner's strong identity.
Unsupported platforms, custom size/identity readers, larger or incompatible inventories, partial stat failure, nonregular inputs or malformed rows refuse atomically before output and recapture the entire snapshot through the unchanged legacy owner.
Without explicit selection, the ordinary legacy snapshot is unchanged.
It asks once for native captured annotation lines, unread/open-decision facts and suggested endpoints before printing any status annotation or section, keeping divergence, capped branch outcomes and the latest-outcome backstop with their existing owners.
The annotation renderer consumes those captured lines without reopening each span or cursor.
At annotation time, after any enrichment delay, its existing signature owner can observe up to 256 historical-only regular-file signatures in one fresh GNU-stat call and read their reported markers in shell.
The batch shares the ordinary signature parser and encoder, never reuses the earlier presentation capture, and never consults owned-append coverage to suppress an annotation.
Direct rows retain priority and first-seen queue order.
An empty historical inventory returns its unchanged manifest without loading the classifier or attempting a signature batch; a nonempty inventory loads the existing classifier owner before invoking its reader.
Unsupported readers/platforms, nonregular or unreadable paths and malformed or incomplete captures discard the entire optional filter before annotation output and run the original per-row replay checks with an explicit diagnostic.
Missing or malformed reported markers remain unreported, preserving the historical warning and every raw wake.
Before native selection, the existing presentation owner independently validates every suggested task/identity/endpoint against its captured snapshot and current cursor manifest under the held presentation lock.
That guard reads the cursor once for the whole batch, rejects missing, duplicate, foreign, malformed or regressive suggestions, and preserves the existing identity/size-reset and legacy-migration boundaries.
A service's claimed observed offset is not sufficient authority to rewind the owner's cursor.
The drain also validates the private client's sorted task groups and complete ordered classification-marker evidence before native selection, so malformed private output falls back to the complete legacy presentation before any annotation or section is printed.
After annotations, at the original acknowledgement-preparation boundary under the held presentation lock, the existing owner rereads every evidenced marker with its existing text reader, validates present markers through its existing parser and compares their normalized bytes.
Unchanged supported evidence retains native suggestions without per-row subprocesses.
Changed, unreadable, malformed, nonregular, symlink or unsupported evidence discards the entire native acknowledgement batch and runs the complete original legacy acknowledgement preparation on the same captured snapshot before any status-section output or commit.
The existing bytewise encoder's 512-byte limit or unavailable bytewise support is unsupported here, never permission to retain stale suggestions.
This late fallback does not replay annotations, replace captured unread/open facts, partially commit endpoints or introduce another writer.
The reported signature and classified offset remain distinct: reported-only changes can alter annotation suppression, whereas the late classified position governs absorption at its original phase.
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
The native path no longer invokes per-row cursor/marker-offset helpers, and its optional commit and annotation batches remove repeated identity/size/cursor and historical-signature reads when admitted, but still pays the legacy transaction and passive-adapter graphs and latest-outcome backstop reads.
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
Service lifecycle registration and promotion of this foundation remain incomplete.
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
The complete existing [`fm-wake-queue.test.sh`](../tests/fm-wake-queue.test.sh) case pool also selects this isolated drain wrapper, retaining concurrent append/ack, actor exclusion, recovery generations, interruption and lock/claim assertions with all independent cases collected before its summary.
The wrapper forwards interruption signals to its actual shell child and the lock-boundary test verifies that direct parent relation rather than confusing wrapper and transaction-owner PIDs.
The original late Perl-reader symlink-swap case retains every assertion through its legacy owner and is counted separately, not as native coverage.
A separate real-client early-swap regression injects at the native regular-file reader and requires its actual nonsymlink refusal plus complete output parity with legacy on that same early-swap input, ordered raw rows, equal annotation counts and no target disclosure.
It also probes the legacy cursor API before and after the swap: a regular file must be accepted and the early symlink must refuse, independently of output parity.
That early cursor refusal precedes the historical annotation in legacy too; the original late-reader case still requires that annotation.
Only the existing explicit delayed-deletion fixture's identity-change refusal is admitted as a matrix race fallback, never a native success or arbitrary-error exception.
Its default legacy selection remains independently exercised by the existing CI tier.
This matrix execution is a behavior gate, not evidence that all integrations are implemented natively or that the performance contract passed.
There is no P0 replay adapter or B0 performance acceptance yet.
Before an installed service or compatibility client is added, its owner must complete those migrations and the registration/actor/receipt requirements in [handoff coverage](handoff-coverage.md).
Identity-bound service shutdown remains future integration work; compatibility refusals already fall back to legacy before presentation commits.
Rollback of this uninstalled foundation is removal or non-use of the modules; no queue, cursor, custody or home mode changes to undo exist.
