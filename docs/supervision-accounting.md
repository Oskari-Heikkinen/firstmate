# Supervision accounting and reader-first bridge

This is the maintainer owner of the P0 measurement, replay and legacy reader contracts.
P0 changes no home mode and claims **zero process births/s saved**.
The command surface and exit codes belong to the header and help of [`fm-supervision-accounting.py`](../bin/fm-supervision-accounting.py).
The agent entry point is the [`supervision-accounting` skill](../.agents/skills/supervision-accounting/SKILL.md).

## Ownership and bounds

The Python 3.9+ standard-library tool is an explicitly invoked, finite task utility, not a check, daemon, notification service or recurring poller.
It never discovers homes or endpoints, runs a supplied workload, starts a backend, consumes a queue, writes a status input, acquires custody or activates a supervisor.
The invoking task owner reads its stdout/artifacts and routes success or refusal through the task's existing status path.
Exit 2 means refused or invalid input, not an empty successful observation.
No unattended actor is installed and no live handoff fragment or receipt is published in P0.
Publishing these artifacts through an automated home-to-home stage later requires the registration and receipts in [handoff coverage](handoff-coverage.md).

Inputs are regular, nonsymlink files of at most 64 MiB.
Special files are refused without blocking.
Arrays and strings have additional bounds in the schemas.
JSON duplicate keys, unsupported formats and unknown schema fields are refused, rather than interpreted as the nearest supported version.
Capture output must be on a reliable local filesystem; bounds do not promise recovery from a kernel or filesystem that cannot complete an ordinary syscall.
Capture creates a fresh private directory, never overwrites evidence, and retains a started record even if finalization is interrupted.
Command arguments may be sensitive; real traces and fleet manifests are private task evidence, never tracked fixtures.

## Owner-published fleet manifest

[`fleet-manifest-v1.schema.json`](supervision-accounting/fleet-manifest-v1.schema.json) is the machine-readable field owner.
Each home owner supplies its own canonical home/state identity, machine, code identity, harness/backend/session, parent route, configuration digest, timers, tasks with spawn/park/custody identities, source registrations/results/claims, custom checks, unsupported integrations and explicitly admitted capture roots.
Tasks with nonempty park tokens are the park count; tasks, sources and checks are counted from their complete arrays, not independently supplied counters.
An empty array is an explicit owner assertion of none, not an unknown.
Unknown inventory must remain unpublished or incomplete, not be replaced with empty arrays to pass validation.
A submitting owner can publish an incomplete one-home manifest with `certified_complete: false`.
The enrolling authority merges published entries and certifies completeness only against its authoritative enrollment registry, including remote homes.
The validator checks structure, unique identities and enrollment equality, not the truth or authenticity of an owner's assertion.
It does not scan homes, stat the published state roots or contact remote machines.
A remote owner captures on its own machine; the laptop collector refuses an entry marked remote.

## Capture and its limits

The optional Linux collector uses installed `strace` to attach only to the selected home's explicit PID/start-tick roots and follow their subsequent fork/exec descendants.
There is no arbitrary command-execution argument.
It verifies the published start ticks before attach, records the observed initial argv, and never signals or changes a target's lifecycle.
Ptrace itself pauses tasks briefly and adds overhead; this is observational instrumentation, not a zero-impact measurement.
It requires a prior reviewed capture authorization, the dedicated live-capture opt-in guard, an explicit attach acknowledgement, Linux pidfds and existing ptrace permission.
The dedicated guard is independent of general live-test opt-ins; the utility refuses capture by default.
`probe` reads tool availability, policy and the calling process's effective capabilities without attempting ptrace or starting any profiler.
With Linux Yama scope 1, an unrelated tracer ordinarily needs `CAP_SYS_PTRACE` in the target's user namespace or a target-established `PR_SET_PTRACER` grant, plus dumpability and LSM permission.
The tool neither requests elevation nor installs software nor changes target ptrace policy.
Absence of a tracer or privilege is a refusal for the owner to route, never permission to fall back to a lossy PID-poll sampler.
The probe does not prove ptrace permission or PID identity across the attach race; a changed or dying root can invalidate the capture.

The configured recording window is 1-300 seconds with at most 64 MiB per tracer output file.
It takes `/proc/stat`'s `processes` counter and wall/monotonic boundaries before starting and after stopping the tracer.
Each boundary also brackets the counter read and records machine CPU ticks and load; final metadata records collector/tracer user/system time and tracer peak RSS.
A pidfd readiness wait costs no recurring child births and does not run a polling loop.
At the deadline it interrupts its own unreaped tracer, allows two seconds for detach, then kills only that tracer PID and allows two seconds for exit.
An interrupted or failed collector also cleans up its own tracer, not a target process group.
The starting and finished metadata retain the exact argv, roots, byte/duration bounds, exit status and SHA-256 seals.
No target launch/stop/restart, profiler installation, broad signal or service administration is performed.
A collector failure or output cap preserves its evidence and refuses success.

The importer handles process forks, exec argv, failed syscalls, interleaved unfinished/resumed calls and ordinary exits.
It sorts completed syscalls by their entry timestamps so a vfork child's exec is not mistaken for an orphan before its parent's return.
Unknown syntax, unresolved argv, unmatched calls and unknown parent identities are explicit loss counters.
Linux `processes` includes task/thread births; threads are included in the exclusive total and also reported as a separate dimension.
The machine counter includes untraced work and the tracer itself; it is a cross-check, not an attribution source.
Strace has no simultaneous all-root attachment barrier and does not retroactively capture existing descendants.
Consequently this collector always declares an attachment gap and **cannot by itself certify a complete B0**.
It is useful for bounded caller attribution and for exposing contradictions, not for erasing unobserved work.
A complete B0 needs an independently sealed fork/exec capture with declared startup coverage and loss counters, plus a certified fleet inventory.
No summary's process labels are converted into such evidence.

## Exclusive accounting

[`trace-v1.schema.json`](supervision-accounting/trace-v1.schema.json) owns the normalized event shape.
Process identities are capture-local generations, not bare reusable PIDs.
Seeds establish ancestry and initial executable ownership but are not counted as new births or in-window entries.
A birth first inherits its nearest known executable-entry family.
Its first recognized direct script exec assigns that birth to that script family exactly once.
Subsequent recognized execs in the same process change the owner of future descendants and add entries, but do not invent another birth or move that first direct-entry allocation.
This rule makes every observed birth belong to one and only one family.
Entries, caller edges, thread counts, origin ancestry and births are separate dimensions and must never be added together.

A recognized entry requires an exact admitted absolute script path, directly executed or passed as the script operand to a supported shell invocation.
A script name in sourced text, `bash -c`, an environment string or a descendant's unrelated argv is not an entry.
The caller is the executable owner immediately before that exec, including an inherited owner where applicable.
Shared code roots are disambiguated by the seed's owner-published home, not by searching a filesystem.
Relative script paths, unrecognized shell options and unavailable argv cannot establish direct script entry.
Such descendants retain the proven ancestry allocation; unavailable ancestry remains unattributed.
`spawn` entries and explicit mutating control subcommands are separately labelled lifecycle entries; this is an entry classification, not proof that an external action completed.
Neither high spawn-labelled births nor library sourcing alone proves a restart storm.
Repeated snapshot-to-crew edges expose repeated read paths, but do not prove erroneous duplicate requests without the sealed request trace.

The exclusive table always includes an unattributed bucket.
The residual is the machine counter delta minus observed births.
It is retained even when negative; negative residuals are contradictions, never clipped to zero.
Positive residual is outside the explicitly attached descendant trees and, where declared, attachment/loss gaps; it is not all supervision and not a saving.
Completeness is false on losses, unattributed births or a negative residual.
No code sets a B0-eligibility or certification verdict, even when inputs assert nonsynthetic provenance, complete capture and certified enrollment.
Every accounting report explicitly leaves B0 pending reviewed real capture, because self-asserted JSON flags and matching content hashes cannot prove provenance or authority.
Only review of actual capture evidence can certify B0; the report must also explain the residual's measured sources and scope before claiming exclusive fleet savings.

## Replay corpus

[`replay-v1.schema.json`](supervision-accounting/replay-v1.schema.json) owns the corpus envelope, pinned manifest, event trace, request clock and external-response fields.
Queue, status and claim records are sealed base64 bytes, not parsed/reformatted state.
The loader validates each seal and returns exactly those bytes, including invalid UTF-8, duplicate keys inside an opaque claim, partial lines and missing final newlines.
It neither materializes files under a home nor executes requests, adapters or lifecycle operations.
Adapter stdout/stderr are bounded captured responses on the same request/generation clock, not commands to run.
Requests and response timestamps must fit the trace and request order; duplicate record names or request ids refuse the corpus.
This establishes the pinned-input loader for later legacy/candidate classifier comparison, not a second classifier or an already-implemented resident replay engine.

The deterministic fixture builder in [`tests/fixtures/supervision-accounting/fixture.py`](../tests/fixtures/supervision-accounting/fixture.py) generates six- and thirty-crew corpora with fixed records and request clocks.
Its high-cost composition and cheap counterpart differ only by synthetic helper descendants on the same input schedule.
Those counts test accounting, not laptop performance or actual historical per-call savings.
Both are explicitly synthetic and cannot serve as real B0 evidence.
Contradictory machine totals and lossy inputs are preserved in the same public-interface regression.

## Legacy capability and fencing bridge

The existing [`fm-supervision-lib.sh`](../bin/fm-supervision-lib.sh) owns the shell APIs.
`fm_supervision_reader_capabilities` returns `fm-supervision-readers.v1`, `legacy-pid-cycle.v1` and `legacy-epoch-check.v1`.
These describe the reader APIs in that library, not an assertion that every running hook or mutating callback is epoch-capable.
`fm_supervision_activation_supported` accepts only that protocol, legacy mode and explicitly known requirements.
Every resident mode, virtual-cycle requirement, unknown protocol and unknown capability is refused in P0.
Nothing writes capability or mode files at runtime, and existing PID-bound readers keep their existing behavior.
No Python dependency is added to ordinary supervision.

The optional `fm_supervision_fence_check` accepts an explicit enable bit, expected epoch and owner record path.
Disabled (`0`) returns without reading even an absent or special-file path.
Enabled (`1`) requires one LF-terminated record, with no second line, of the form `fm-supervision-owner.v1<TAB>legacy<TAB><epoch>`.
The epoch is canonical positive decimal with at most 18 digits and must exactly equal the callback's captured epoch.
An absent, symlinked, nonregular, malformed, unsupported-mode or stale record refuses.
The check writes nothing and uses no external commands.
No existing producer enables it or changes callbacks in P0.
A check alone is not a handover transaction: a future callback must invoke it **under the same existing commit lock** that protects the mutation and the reviewed epoch selection, not before a slow observation or outside the boundary.
The bridge is intentionally unused until that wiring is complete; it must not be advertised as a completed cutover gate.

### Commit-boundary integration obligations

There is no new lock and no optimistic mode-file flip.
The boundary families a later cutover must cover are:

- Wake append/claim/ack: the existing wake queue transaction owner, with actor/grant scopes retained.
- Status presentation: its existing presentation/cursor boundary, retaining byte identities and concurrent append behavior.
- Source claims/results/executor transfer: source ownership before extension ownership, preserving the existing source-to-extension lock order and registration/result identities.
- Park resume/release/restore and lifecycle actions: their existing source/task/custody transaction owners, never a global monitoring lock across an external command.
- Cycle close and beacon health: the exact cycle generation and legacy singleton owner; a new virtual cycle cannot reuse a resident PID as cycle identity.

An arm must never hold or wait on the watch singleton lock to learn that a cycle ended.
P0 adds no contention to any of these boundaries.
Before resident activation, the owning ship must enumerate every mutating callback, fence each at its commit boundary, prove a single short epoch-selection boundary against old writers, drain or retain in-flight effects, and test prepared/quiesce/fence/rescan recovery.
Callbacks not safely integrated remain legacy custodians and block activation of their source.
An old running reader is still old even if its checkout has this library; capability advertisement must come from the running instance and later have registered readers/receipts.
Current queue, status, claim, close and custody identities remain authoritative and are never rewritten by this bridge.

## Verification and rollback

[`tests/fm-supervision-accounting.test.sh`](../tests/fm-supervision-accounting.test.sh) is the CI regression entry point for the public CLI, sealed byte reads, exact synthetic ownership, caller edges, lifecycle-vs-sourcing distinction, contradictions, loss refusal, manifest validation, collector bounds and inert legacy fence APIs.
It uses fake trace inputs and a fake tracer, never a live endpoint or actual ptrace.
The default-refusing [`fm-supervision-accounting-live.test.sh`](../tests/fm-supervision-accounting-live.test.sh) guard exercises the real collector, importer, ptrace/pidfd cleanup and strace format against only an explicitly supplied owner manifest during ordinary workload.
Its header owns the opt-in environment, output and duration arguments.
It neither starts a workload nor acquires privilege; missing prerequisites or an empty/incompatible trace fail rather than producing a live PASS.
The guard is in the live tier and never runs on a default CI push or this laptop without its separate prerequisite and reviewed-capture go.
Real capture syntax/permissions and overhead remain pending until that guard has passed on the reviewed bounded ordinary-workload trace; synthetic success cannot substitute for that evidence.
Keep existing continuity, host, guard, queue, source and custody suites as the legacy oracle.
All supported harness/backend paths retain legacy mode without an additional runtime dependency or altered deadline.
A new mode is unsupported regardless of harness, so no harness-rendered signal or backend lifecycle assumption is introduced here.

Rollback removes or leaves unused the accounting utility and bridge APIs.
It does not restore old queue/status/claim bytes, stop a running worker, clear a lock, restart a watcher or switch a home.
No safety cut or process saving is attributed to this phase.
