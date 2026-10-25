# Read-only supervision view primitives

This is the maintainer owner of the Python 3.9+ view-engine primitives in [`fm_view_engine.py`](../bin/fm_view_engine.py) and [`fm_view_status.py`](../bin/fm_view_status.py).
These modules are an **uninstalled foundation**, not a completed replacement for crew-state, wake drain or fleet snapshots.
Existing shell entrypoints remain selected without a new runtime dependency.
There is no production CLI, mode switch, service installer, health beacon, lease or watcher integration.
The [`supervision-views` skill](../.agents/skills/supervision-views/SKILL.md) owns the agent load trigger.

## Authority boundary

`Inputs` reads only an explicitly supplied canonical home and its identity-bound state root.
Task ids cannot contain path separators.
Regular-file reads are bounded, refuse final-component symlinks and special files, and check same-descriptor and final-path identity.
A changed metadata capture or root refuses the observation rather than attributing it to a replacement task.
A missing status file is an empty span; an existing unreadable or unsupported object is a failure, not an empty successful fold.
The native fold reads registered alert-store levels on every request, even when status bytes have not changed.
The shell classifier remains the parity oracle; it has not been replaced by these modules.

The transport admits `status-fold`, `crew-state` and `status-presentation` requests.
It cannot claim, acknowledge, append, retire, resume, publish a summary or alter custody.
It writes no authoritative state, including presentation cursors.
The calling transaction owner remains responsible for any presentation commit after successfully writing its output.
No client currently calls this transport from a production shell entrypoint.

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
The reply preserves request order and returns each row's captured endpoint/generation, new nonblank lines, unread informational lines, open decisions and a suggested `acknowledged_end`.
A suggestion has no acknowledgement effect: the invoking owner must still verify its original strong birth-time identity and commit only after the prepared output reaches stdout.
Device/inode pairs are observation checks and disposable index keys, never substitutes for those strong cursor identities.
The batch folds only through each captured endpoint, so concurrent appends remain unread for a subsequent presentation.
A missing, replaced or truncated input, changed prefix or changed metadata generation refuses the entire batch, without a partial successful result or cursor write.
Batches retain at most 64 MiB of captured status bytes and four MiB of metadata; oversized batches refuse for explicit legacy fallback rather than silently omitting rows.
Unsupported fields, duplicate JSON keys, nonfinite numbers, unsupported verbs and mismatched home/epoch refuse the request.
A response binds the same protocol, home, epoch and nonce, with `ok` and either `result` or a typed refusal message in `error`.
Requests and responses are limited to one MiB; regular input files are limited to four MiB.
These bounds are prototype limits, not a claim that every existing fleet input fits them.

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

## Verification and remaining migration

[`tests/fm-supervision-views.test.sh`](../tests/fm-supervision-views.test.sh) runs isolated real-socket, bounded-lane and legacy-fold comparison tests in CI.
It checks keyed transitions, correlation tokens, malformed time tags, terminal-task versus persistent-mate folds, protected tool blockers, incomplete final lines, invalid UTF-8, fresh tool levels without status changes, generation/root refusal, single-flight and timeout reservation.
Native crew-state cases also compare the legacy public CLI on identical isolated git repositories and captured fake no-mistakes/backend/forge responses.
They include fresh HEAD, daemon and semantic-pane negative controls without status changes, selected-run identity, gate authority, coarse dead-instrument outcomes and a backend no-lifecycle tripwire.
Captured-presentation tests compare unread rows, folded decisions, new-line spans and suggested contiguous endpoints against the existing shell presentation transaction APIs across all task kinds, classified/fully-presented combinations, partial lines and invalid UTF-8.
They also exercise append-bounded snapshots, whole-batch refusal on replacement/truncation/generation changes, fresh protected tool levels and batch single-flight/timeout fairness without writing a native cursor.
Separate initial/final-generation-barrier stalls saturate ordinary capacity with concurrent batches and prove both critical slots still admit status-fold observations.
It does not test against live endpoints or start a backend.

Production current-state compatibility routing, coupling native drain facts to the existing presentation transaction, snapshot composition, dirty-trigger publication and the complete existing parity matrix are not implemented by this foundation.
The focused native current-state tests are not the full existing crew-state matrix.
There is no P0 replay adapter or B0 performance acceptance yet.
Before an installed service or compatibility client is added, its owner must complete those migrations and the registration/actor/receipt requirements in [handoff coverage](handoff-coverage.md).
Production fallback and identity-bound service shutdown also remain future integration work.
Rollback of this uninstalled foundation is removal or non-use of the modules; no queue, cursor, custody or home mode changes to undo exist.
