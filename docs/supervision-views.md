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

The transport admits only `status-fold` requests.
It cannot claim, acknowledge, append, retire, resume, publish a summary or alter custody.
It writes no authoritative state, including presentation cursors.
The calling transaction owner remains responsible for any presentation commit after successfully writing its output.
No client currently calls this transport from a production shell entrypoint.

## Read protocol

The protocol id is `fm-supervision-views.v1`.
Each one-request connection carries a newline-terminated JSON object with exactly `schema`, `epoch`, `home`, `request`, `verb`, `timeout_ms` and `args`.
`schema` names the protocol, `epoch` is the owner-selected service incarnation, `home` is the canonical operational home and `request` is a bounded per-call nonce.
`timeout_ms` is a positive integer at most 30000.
The sole verb's arguments contain `task`, an optional explicit `kind`, and optional classifier vocabulary overrides.
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
Kernel syscalls on an unreliable filesystem cannot be forcibly cancelled by Python threads; capacity exhaustion returns a refusal, and this foundation must not be installed as authoritative supervision.

Only concurrent in-flight requests for the same argument set share a native fold.
A completed request is never a cached fresh answer.
The operation captures and rechecks task metadata and root identity, and reads external tool levels afresh.
There is no timer, polling loop, status-tail inference or cross-cycle verdict cache.
No process-birth or CPU saving has been measured or claimed.

## Verification and remaining migration

[`tests/fm-supervision-views.test.sh`](../tests/fm-supervision-views.test.sh) runs isolated real-socket, bounded-lane and legacy-fold comparison tests in CI.
It checks keyed transitions, correlation tokens, malformed time tags, terminal-task versus persistent-mate folds, protected tool blockers, incomplete final lines, invalid UTF-8, fresh tool levels without status changes, generation/root refusal, single-flight and timeout reservation.
It does not test against live endpoints or start a backend.

Native current-state attribution, native drain presentation, snapshot composition, dirty-trigger publication and the complete existing parity matrix are not implemented by this foundation.
There is no HEAD/daemon/pane negative-control proof, P0 replay adapter or B0 performance acceptance yet.
Before an installed service or compatibility client is added, its owner must complete those migrations and the registration/actor/receipt requirements in [handoff coverage](handoff-coverage.md).
Production fallback and identity-bound service shutdown also remain future integration work.
Rollback of this uninstalled foundation is removal or non-use of the modules; no queue, cursor, custody or home mode changes to undo exist.
