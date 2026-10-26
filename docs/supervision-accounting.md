# Supervision accounting and reader-first bridge

This is the maintainer owner of the P0 measurement, replay and legacy reader contracts.
P0 changes no home mode and claims **zero process births/s saved**.
The command surface and exit codes belong to the header and help of [`fm-supervision-accounting.py`](../bin/fm-supervision-accounting.py).
The agent entry point is the [`supervision-accounting` skill](../.agents/skills/supervision-accounting/SKILL.md).

## Ownership and bounds

The Python 3.9+ standard-library tool is an explicitly invoked, finite task utility, not a check, daemon, notification service or recurring poller.
Outside its GitHub-CI-only calibration verb it never runs a supplied workload.
No verb discovers homes or endpoint namespaces, starts a backend, consumes a queue, writes a status input, acquires custody or activates a supervisor.
The separately authorized proc route enumerates machine process leaders and optionally reads exact owner-admitted tick-log paths, never home state or endpoint directories by discovery.
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
It verifies the published start ticks before attach, records the initial `/proc/<pid>/exe` link and cmdline with `proc-exe-cmdline` evidence, and never signals or changes a target's lifecycle.
Ptrace itself pauses tasks briefly and adds overhead; this is observational instrumentation, not a zero-impact measurement.
It requires a prior reviewed capture authorization, the dedicated live-capture opt-in guard, an explicit attach acknowledgement, Linux pidfds and existing ptrace permission.
The dedicated guard is independent of general live-test opt-ins; the utility refuses capture by default.
`probe` reads tool availability, policy and the calling process's effective capabilities without attempting ptrace or starting any profiler.
With Linux Yama scope 1, an unrelated tracer ordinarily needs `CAP_SYS_PTRACE` in the target's user namespace or a target-established `PR_SET_PTRACER` grant, plus dumpability and LSM permission.
The tool neither requests elevation nor installs software nor changes target ptrace policy.
Absence of a tracer or privilege is a refusal for the owner to route, never permission for an implicit fallback.
The separately selected unprivileged route below reports its sampling gaps rather than impersonating a fork/exec trace.
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

The importer handles process forks, execve/execveat executable paths and argv, failed syscalls, interleaved unfinished/resumed calls and ordinary exits.
It splits syscall operands outside quoted C strings and nested containers, decoding escaped bytes rather than searching for an argv bracket inside a path.
It sorts completed syscalls by entry timestamp and original entry-line ordinal so even tied timestamps put a vfork/clone child's birth before its exec.
Unknown syntax, unresolved executable/argv evidence, unmatched calls and unknown parent identities are explicit loss counters.
Linux `processes` includes task/thread births; threads are included in the exclusive total and also reported as a separate dimension.
The machine counter includes untraced work and the tracer itself; it is a cross-check, not an attribution source.
Strace has no simultaneous all-root attachment barrier and does not retroactively capture existing descendants.
Consequently this collector always declares an attachment gap and **cannot by itself certify a complete B0**.
It is useful for bounded caller attribution and for exposing contradictions, not for erasing unobserved work.
A complete exclusively attributed B0 needs independently reviewed evidence covering fork/exec and startup losses, plus a certified fleet inventory.
Neither this strace route alone nor the unprivileged route below supplies that evidence.
No summary's process labels are converted into such evidence.

## Unprivileged machine baseline and its irreducible gap

The explicit proc route reads Linux procfs and optional owner-admitted tick logs using the current unprivileged uid, with no additional dependency, external command, attach, target signal, policy write, workload or standing process.
Root and any nonzero effective capability set are refused, even if those privileges would not be needed.
It does not invoke strace, perf, BPF, audit or sudo, and it has no option to select a privileged route or execute an arbitrary command.
It needs its own live opt-in and an owner-published, single-machine local manifest; remote entries, shared root PIDs and absent roots are refused.
Roots must match published PID/start-tick generations during the initial scan.
The code roots disambiguate script hints only after a published root establishes a provisional home; shared code paths alone never assign a home.
The first scan checks roots but does not claim that the owners published every running supervisor.
Manifest completeness is still an authority assertion, not something procfs can prove.

[`proc-v1.schema.json`](supervision-accounting/proc-v1.schema.json) owns the replayable raw envelope.
A fresh private output directory contains an incomplete started record, the raw samples with their pinned manifest, and the derived report.
Success stdout supplies content digests and the total bytes; the task owner must preserve that receipt with the artifacts.
Offline accounting reproduces the report without touching a home or starting a process.
Synthetic fixture provenance remains explicit and cannot certify B0.
Duration is explicitly 1-300 seconds, samples are spaced by at least one second with no catch-up scans, and each scan admits at most 32,768 leaders.
A final scan has at most two seconds of slack, and a process-local real-time alarm bounds the entire invocation to duration plus five seconds, including validation, accounting and output.
Alarm expiry is fatal, not a recoverable unreadable PID or unavailable hint, even during the final task read.
The reliable-local-filesystem caveat in Ownership and bounds still applies.
The explicit byte cap is an aggregate cap over all three files, at most 64 MiB, not a cap per sample.
The default is 8 MiB, well below 1 GiB; cap, identity, scan or deadline refusal leaves incomplete evidence and exit 2, never a successful baseline.
No raw sample is published if the in-memory recording cannot fit the cap.
Private command arguments are retained only in the task evidence directory.

### What is measured

`/proc/stat`'s `processes` delta is the exact machine-wide count of task births between the two kernel counter reads, including nonleader threads, every uid, workload and the collector's startup-adjacent activity if it falls inside the window.
Wall/monotonic boundaries and uptime brackets are recorded; counter reads are not an atomic process-table barrier.
Busy machine CPU is the delta of user, nice, system, irq, softirq and steal ticks.
Idle and iowait are excluded and guest/guest_nice are not added a second time.
CPU percent uses one logical core as 100%, never the number of CPUs as the denominator.
Machine rates use the measured monotonic window, not the requested sleep duration.

One in-process scan reads each visible process leader's stat, cmdline and executable, and rereads stat to reject reuse during that read.
PID plus start ticks identifies a process generation; no bare-PID history is reused.
The observed process-birth lower bound counts each distinct observed leader whose start tick is definitely inside the machine window once.
The initial and final uptime brackets deliberately exclude uncertain boundary jiffies, including proc uptime's centisecond truncation at high HZ.
Existing processes establish startup inventory but are not new births.
Nonleader threads are not enumerated and remain in the birth residual.
The observed user/system CPU lower bound sums only nondecreasing own-time deltas between observations of the same generation, all inside the machine window.
Leader stat CPU aggregates that thread group; threads are not sampled separately, and child CPU is never added.
Single-observation processes contribute no measured CPU delta.
A denied executable/cmdline hint does not discard readable stat CPU; it is counted separately and leaves no direct family hint.
The leader inventory sees only the current PID namespace and proc mount permissions, not a proved machine-wide visible PID set; invisible namespaces and hidepid restrictions also remain in the residual.
Using a long-lived parent's `cutime/cstime` would double-count sampled descendants, credit reaping-time work performed before the window and erase source boundaries, so this route does not use those counters.

### Exclusive provisional partition, not measured supervision attribution

Each observed leader birth belongs to exactly one provisional home/family bucket, fixed at first observation.
Each own-CPU delta belongs to exactly one provisional bucket; if the two endpoint hints differ, that interval goes to unattributed rather than moving earlier work to the later executable.
These partitions reconcile exactly to the observed lower bounds, not to complete machine supervision.
Every recognized family here is a mutable cmdline hint, including watch, crew-state, wake-drain, fleet-snapshot, spawn and control.
Nearest observed ancestry to an identity-matched published root is also provisional: a parent may have exited, reparented, execed, or been replaced between reads.
An unchanged hint cannot exclude an unseen intermediate exec.
The report therefore separates the provisional table from `exclusive_measured_supervision_by_home_family`, which is explicitly null.
It does not manufacture entries, caller edges, invocation counts or lifecycle actions from proc cmdlines.
Other supervision families and unrecognized wrappers remain unattributed even provisionally.
There is **no family with complete exclusive measured attribution** under this route.

The births residual is machine task births minus observed leader births, not machine births minus supervision.
It includes short-lived leaders that exist entirely between scans, nonleader threads, unreadable/racing PIDs and boundary-tick births.
The CPU residual is machine busy ticks minus observed own-time deltas; it includes before-first/after-last-observation CPU, unseen exits, unreadable tasks and unsampled work, including interrupt/steal time not represented by process CPU.
The observed part itself includes workload and collector CPU and is not all supervision either.
Unreadable/vanished PID samples, single-observation identities and observed hint changes are counted independently; they are observations of loss, not counts to add to the residual.
Unseen short-lived tasks, intermediate execs and reparentings have unknown cardinality, not zero.
Clock quantization and non-atomic counter reads can contradict a small window; negative arithmetic residuals are preserved, never clipped.
Startup coverage is a finite sequential inventory, not historical exec coverage or a simultaneous all-process barrier.

Without a supplied model the route yields a reproducible **incomplete unprivileged machine baseline** and says `incomplete-unprivileged-attribution`, even with complete enrollment and zero visible read errors.
Two workloads can have identical snapshots but different source families for arbitrarily many short-lived children; a machine fork total cannot distinguish them.
Fully exclusive measured attribution remains unavailable for every family.
The explicit model route below supports acceptance defined in terms of CI per-tick costs and observed live record rates, not measured live source attribution.
No estimate is silently substituted for measurement and no output automatically certifies B0.
All claimed savings remain zero.

### CI per-tick model with live rates and exact machine cross-check

[`proc-model-v1.schema.json`](supervision-accounting/proc-model-v1.schema.json) owns the optional model specification; its sealed tick readings are part of the proc raw envelope.
The capture CLI accepts that specification explicitly and the offline CLI reproduces both measured and modeled tables from the raw envelope alone.
There is no implicit model, historical constant, configured-cadence rate, discovered log path or synthetic live workload.
A specification supplies one profile for each admitted home/family, the exact manifest code/configuration pins, a definition of its tick unit, the CI evidence URL/digest, and calibrated exclusive totals for births, user CPU nanoseconds and system CPU nanoseconds over a positive number of CI ticks.
Additional families such as park checks, guards, arms and hosts are data, not new classifier branches.
Every missing home/six-leading-family pair is listed, and additional supervision is explicitly unmodeled unless supplied.
The tool cannot infer completeness of the profile set from procfs or enrollment.

`exclusive-home-family-v1` means each CI birth and CPU interval is allocated to exactly one home/family, including that family's entry and children but excluding work allocated to another profile, even when nested.
An inclusive watcher cost plus a separately modeled nested crew-state cost is invalid evidence.
Use the existing trace accounting CLI's exclusive births and per-invocation table for traced CI calibration, with matching tick counts; obtain user/system CPU from a CI measurement that covers the same exclusive scope, including reaped children without counting them twice.
The calibration artifact's SHA-256 must seal the retained counts, workload/shape, code/configuration, tick definition, startup treatment, attribution method and CPU evidence, not merely a prose assertion of tracing availability.
A multi-tick calibration divides its totals by its tick count; it is not interpreted as cost per one tick.
The URL and digest are provenance references for review, not network-fetched or authenticated by this utility.
Calibration must be refreshed at each code/configuration/work-mix change and compared at each rewrite stage on matched replay and tick units.
Synthetic calibration is allowed only in synthetic offline recordings, not live capture or a real recording.

Live rates are measured only from explicitly admitted append-only regular logs inside each published canonical home.
Each LF-terminated line containing the literal UTF-8 selector counts once, irrespective of multiple matches on that line; nonmatching and unfinished lines are not ticks.
The owner must attest that those lines represent the calibrated unit exactly once, not retries, duplicate debug messages, or a sample of a faster loop.
The utility reads each log twice, around the machine sampling window, retaining the complete bounded bytes, SHA-256, file identity and monotonic read brackets for replay.
It refuses symlinked path components, shared paths or aliased file identities, nonregular files, changed identity, rewritten/truncated prefixes, mismatched pins, or more than 64 KiB per reading.
These reads share the existing invocation deadline and aggregate output cap; the format admits at most 128 profiles.
Log rotation or unreadability refuses the capture rather than turning unknown into zero ticks.
An old partial line completed by the second read counts as one completion.
A quiet log measures zero, not the configured cadence.

Not every existing source has a countable record: an overwritten watcher beacon is not a tick counter, a cycle-exit log is not every inner watcher iteration, and host/arm/park loops do not necessarily log each tick.
Likewise crew-state, drain, snapshot, spawn and control entries cannot be counted from mutable proc cmdlines or from unrelated status changes.
For each of those uninstrumented units the live invocation/tick rate is unavailable and its modeled cost must remain uncovered, unless an owner supplies an existing countable record and matching CI unit.
The collector does not add instrumentation, write a counter into a home, treat an observed beacon transition as every tick, or divide by configured sleeps to manufacture that rate.
Missing real calibrations or live tick records are evidence still to obtain, not a reason to run a privileged route or mark a partial model complete.

For each profile, the observed log count delta divided by its measured log-read interval is the live record rate.
That interval encloses, but is slightly wider than, the machine window because sequential reads cannot form an atomic barrier.
The report publishes the before/after skew; extrapolating the rate to the machine interval is explicitly part of the model.
Estimated births and user/system CPU equal CI cost per tick times record rate times machine-window duration.
The model-derived table is exclusive by declared home/family scope; duplicate pairs and repeated records are refused, but exclusivity of the underlying CI experiment and semantic tick-unit match remain review obligations.
Observed lower bounds and provisional hints are never added to model estimates: that would count the same work twice.

The model is checked against the **same exact machine task-birth delta and busy CPU denominator** as the proc report, with rational arithmetic before presentation rounding.
`machine_minus_model_residual` is machine total minus model estimate, separately from the measured machine-minus-observed residual.
A negative birth or CPU residual sets `model-total-contradiction`; negative values are preserved and a small observed lower bound cannot excuse an oversized model.
A nonnegative residual says `nonnegative-not-proof`, not that the model explained the machine.
Positive residual includes unmodeled supervision, ordinary workload, collector overhead and model error; it is not all supervision and no bucket is inferred from it.
No statistical error bound is claimed: unseen callers, live work mix, CI/runtime differences and observation skew remain explicit uncertainties.
Per-tick costs also do not recover resident startup or partial in-flight boundary work; the startup inventory/history qualifications above remain unchanged.

With a supplied model, `pending-reviewed-model-baseline` is a request for evidence review under a model-based acceptance contract, not certification or permission to promote P1-P5.
Review must establish coverage of every enrolled home's relevant source families, calibrated exclusive costs, actual tick-unit equivalence, startup treatment and an explained residual; a list of missing profiles blocks complete fleet acceptance.
The measured exclusive supervision table remains null, even if all named profiles exist and both cross-checks are nonnegative.
Reports distinguish no-model incompleteness, pending model review, and a contradicted model without widening collection privileges.

## CI calibration, opt-in tick journals and retrospective reconciliation

The attribution input shape is owned by [`attribution-v1.schema.json`](supervision-accounting/attribution-v1.schema.json), and the sealed calibration payload by [`calibration-v1.schema.json`](supervision-accounting/calibration-v1.schema.json).
The tool validates every tick-count and reconciliation output against [`tick-counts-v1.schema.json`](supervision-accounting/tick-counts-v1.schema.json) and [`reconciliation-v1.schema.json`](supervision-accounting/reconciliation-v1.schema.json) before publication.
These are finite task artifacts, not an automated cross-home publishing stage or a new installed actor.
The invoking task owner consumes success/refusal and retains evidence through its existing status path.

### Calibration evidence

Calibration executes a trusted fixture plan only on a GitHub-hosted Linux Actions runner, using installed strace and GNU time, with the clean checkout exactly matching the GitHub run revision before and after measurement.
The separate [calibration workflow](../.github/workflows/supervision-calibration.yml) installs those CI-only dependencies explicitly and retains evidence on failure too.
No local profiler, workload, privilege change or implicit calibration fallback is enabled.
Each paired repeat reconstructs two fresh isolated states from the same sealed fixture files; explicit home/state/data/config/project overrides must all name that phase's private scratch tree.
The retained plan binds family, tick unit, revision, configuration pin, work-mix digest, argv, environment and qualification.
A work-mix digest seals the canonical fixture-file array; configuration and unit equivalence with deployment remain owner/reviewer assertions, not facts inferred from a matching digest.

Launch tracing counts the script's entry birth and its descendant task births, including threads.
GNU time reports command-subtree user/system CPU, including reaped children, in a separate untraced matched repeat.
Traced CPU is retained only as a paired diagnostic, not multiplied into the live CPU model: excluding the tracer process itself does not remove tracee-side instrumentation effects.
A fixture with another recognized supervision family nested in its subtree is refused rather than assigning inclusive CPU to two families.
This is an isolated-scope calibration method, not an exclusive CPU splitter for arbitrary nested live workloads.
Birth counts must agree across traced repeats; the CPU model uses untraced readings and retains their repeat spread, with 10 ms quantization per component explicitly reported.
The signed traced-minus-untraced CPU range per paired repeat is retained, including negative differences; it is not a statistical error bound or an exact tracer-overhead correction.
Freshly generated journal records must prove the same positive planned tick count in both phases, with no other family/unit in that scope; preseeded instrumentation files are refused.
Costs divide by the sum of actual calibrated ticks, not just the number of repeats.
Command startup remains in that average rather than being silently removed, so an invocation fixture cannot certify a resident steady-tick cost without matching startup treatment.
The outer canonical-JSON SHA-256 envelope seals all metadata and retained raw trace/CPU evidence; it detects content changes, not provenance forgery or operator authority.
Replay validates the closed payload, inner trace seals, recomputed births, CPU evidence, repeat count and deterministic birth agreement.

The default synthetic plan measures empty-home crew-state, drain and contribution-input snapshot invocations, a first-iteration queued-result watcher wake, a stable-identity host wait interval and admission-refusal spawn/control invocations.
The host fixture calls the actual bounded interval, including periodic identity and boundary checks and two native half-second waits, without activating an arm, watcher or engine.
Source/FIFO setup remains in its average; readiness, changed-identity and engine work are excluded.
The watcher fixture includes startup/watchdog/close and is not a quiet steady iteration price; spawn/control refusal costs are not successful lifecycle prices.
The spawn fixture supplies explicit delivery operands to reach its invalid-id refusal and skips the pre-spawn watcher guard; it prices neither successful spawning nor that guard.
Every remaining registry family is explicitly unavailable rather than priced from help output or configured cadence.
These synthetic-shape costs cannot price real captures.

For a deployment calibration, the workflow dispatch `plan` input selects an already tracked, reviewed `ci/supervision-plans/NAME.json` template on that exact revision.
The offline `prepare-calibration-plan` verb resolves only explicit revision and checkout tokens, validates seals, and requires every registry family per home, including explicit unavailable rows.
The CI builder refuses untracked, symlinked or escaping selections; it never reads a live home or changes the template's synthetic flag, configuration or work-mix pins.
A real plan must already declare nonsynthetic provenance, owner-supplied home/configuration pins and reviewed representative fixture bytes, units, startup treatment and complete exclusive scope.
The same CI measurement and sealed replay checks apply to selected plans; there is no permissive second calibrator.
No deployment plan or live-home configuration is supplied by the default fixture builder, and missing owner evidence remains a gap.
Each command is bounded to 30 seconds, the measurement phase to five minutes, repeats to nine and profiles to 32; aggregate trace/stdout/stderr/CPU and fixture bytes are capped at 16 MiB.
An interrupted or failed command kills only its own private CI process group and retains incomplete evidence.
Plans must be finite fixtures without escaping/daemonized children, never live-home commands.

### Tick recording without a new polling process

Logging is disabled by default and landing enables it in no home.
`config/supervision-tick-logging` opts in existing actors when they start and short commands when invoked; `FM_SUPERVISION_TICKS=1` enables and `0` disables explicitly.
Linux with Bash's microsecond `EPOCHREALTIME`, readable proc uptime and the kernel boot UUID is required for this recording route; unsupported clocks or boot identity refuse instrumentation while legacy supervision continues.
No interpreter or new dependency is added to ordinary monitoring.
The logger lives with the existing shell bridge in [`fm-supervision-lib.sh`](../bin/fm-supervision-lib.sh), whose header owns the shell API.
All successful appends use shell builtins only: no date, stat, helper process, new poller, timer or standing reader.
No sleep, grace, liveness verdict, queue custody or delivery deadline changes.

`fm-supervision-tick.v3` is one LF-terminated ASCII TSV row: format, family, unit, kernel boot UUID, writer generation (`PID:startup-wall-seconds`), sequence, wall epoch seconds with six fractional digits, proc uptime seconds with two fractional digits, and phase.
`start` is not a tick; `tick` and the first retained `rotate` row count once.
Owned sequences are positive and monotonically increasing across all generations, including start rows, with the last sequence durably recorded in the bounded cursor after each append.
A failed cursor update invalidates the cohort instead of permitting a later generation to reuse its sequence.
Concurrent `entry` rows have sequence one and a fresh timestamped generation per append.
The wall stamp is not a proof of process start identity; proc uptime provides the separate boot-clock coordinate.
The UUID is read with builtins once at owned-loop initialization or per concurrent append, so an earlier boot's identical uptime interval cannot be counted as current work.
Legacy v1/v2 records lack boot identity or cross-generation continuity and remain unavailable rather than being silently upgraded.
Readers preserve raw bytes, unfinished lines, startup qualifications, sequence gaps and rotation loss instead of deriving rates from configured sleeps.

The watcher and host use independently owned two-slot streams at `state/.supervision-watch-ticks.{0,1}.tsv` and `state/.supervision-host-ticks.{0,1}.tsv`, with a bounded slot/stream-sequence cursor sidecar per stream.
The existing singleton/host ownership, not the logger, serializes writer generations.
Each slot has a strict 64 KiB cap, and builtin redirection rotates to the other slot without a subprocess, retaining the previous slot.
A new generation starts in the alternate slot, not by appending under its predecessor's sequence.
The APIs refuse malformed caps, slots, symlinks, special files and an append inherited by a different process.
The APIs are not safe as a shared-writer lock or as an ownership protocol.

Short crew-state, drain, snapshot, spawn and control commands append one entry after home resolution; spawn/control help and earlier gate/home-resolution refusals are outside this unit.
Snapshot mode and transaction work mix still require matching calibration; an invocation counter is not a claim of equal cost for all requests.
Reconcile calls, owner-guard checks, condition polls and attached-arm polls also use the concurrent journal because their producers can overlap.
It is `state/.supervision-entries.tsv`, with `state/.supervision-entries.previous.tsv` as the other retained slot.
The watcher obtains its size in the stat process already needed for home-summary age, then performs one rename when the default 4 MiB threshold is reached; the existing pass is the only rotation reader.
An existing active journal is maintained even when that watcher's recording flag is off, so producer-specific overrides cannot leave it unbounded behind an otherwise running watcher.
`FM_SUPERVISION_ENTRY_MAX_BYTES` can select 4 KiB through 16 MiB for that threshold.
The concurrent journal's bound is a threshold plus growth until the next watcher pass, not a hard instantaneous cap; there is no such growth bound while that watcher is stopped or delayed.
Rotation never truncates the shared inode.
The retained-path size bound also does not bound disk space held by frozen open unlinked inodes.

**Accepted measurement limit: a concurrent producer frozen between its O_APPEND open and write across two watcher rename rotations can silently lose its line.**
This applies to every producer of that journal, including concurrent polling actors, not just ordinary short requests.
No writer-lifetime assumption, per-record acknowledgement or zero-loss proof is claimed.
Every reconcile result repeats this limit next to its counts and residual; it must accompany any capture report that uses those counts.
An ordinary late append after only one rename still lands in the retained previous inode.
The regression demonstrates both that retained case and the deliberately accepted loss case.

An instrumentation failure invalidates the current recording cohort through `state/.supervision-ticks.error`, without stopping or certifying the supervisor.
Marker-publication failure is silent on caller stderr, including closed or captured stderr; existing ticks retry the durable invalidation and the existing watcher remains its delivery owner.
The existing watcher queues one invalidation notice per cohort through its ordinary slow-check step, not at the head of every monitoring pass; it is a recording failure, not a task status or a new supervisor-health predicate.
It writes `state/.supervision-ticks.error-seen` only after durable queue publication, so a failed enqueue is retried and an already queued notice does not keep cutting monitoring cycles short.
The queued notice may ride along with another ordinary wake; normal queue replay and acknowledgement still own delivery.
The recording owner preserves the marker and receipt, repairs the cause, then archives both before deliberately beginning a new cohort and accepting rates.
Offline journal inputs must explicitly attest the absence of that invalidation; missing or positive error state leaves the family unavailable.
They also declare owned-loop versus concurrent records; an owned loop without startup/retention evidence is unavailable, not a quiet zero.
Failed owned-loop writers retry invalidation delivery on their existing ticks; an I/O failure is not turned into a healthy zero stream after recovery.
No code clears an invalidation automatically, enables logging remotely or restarts an actor to pick it up.
Other loops and entrypoints without these exact records remain uncovered, not inferred from source labels or configured cadence.

### Saved records and same-window arithmetic

Retrospective counting reads only the supplied saved proc envelope and owner-published sealed log bytes, never a current home or a discovered path.
A profile supplies either one sealed record or explicit sealed fragments, allowing both retained slots to be replayed without rewriting their contents.
Owner metadata must state full retained window coverage, code/configuration pins, work mix, exact tick unit and source semantics.
Missing owner evidence, stale window coverage or changed pins produce an unavailable row, not a zero-cost modelled family.
Generic adapters support epoch-first TSV, timestamped status lines and JSON timestamps, including the successful-spawn publication's explicit epoch field.
Those narrower successful-spawn and watcher-cycle-close units must not be called every spawn attempt or every watcher inner tick.

The instrumented TSV adapter partitions a shared record by exact family and unit, admits only the capture's boot UUID, and checks both generation-local and stream-wide sequence continuity.
An owned stream requires retained evidence at or before the window start, so losing whole earlier generations cannot become a confident undercount.
A concurrent stream likewise requires a retained current-boot entry at or before the window start, independently of owner coverage attestation; no matching-family entry is necessary to prove a quiet unit if another concurrent unit establishes that shared prefix.
A journal without any evidence from the current boot is unavailable, not zero; current-boot records from other units can establish a quiet concurrent counter.
Shared fragments must have identical content seals, and other adapter types may not share a record.
A removed prefix inside the requested interval, duplicate/missing sequence or invalidation prevents modelling that profile.
Instrumented counts use conservative proc-uptime brackets from the capture, excluding ambiguous edge jiffies; generic adapters use the capture's wall interval.
Both publish the exact measured monotonic duration as their denominator and retain the wall-minus-monotonic discrepancy.
The report also publishes the journal count-bracket duration and denominator excess: excluded edge jiffies bias the rate downward relative to full-window counts, with no finite bound on missed edge events or their model cost.
Centisecond boot-clock quantization, startup and in-flight boundary work remain explicit uncertainties, not recovered events.
A shared boot UUID does not itself prove a shared time namespace; the owner still attests clock-coordinate equivalence.

For each compatible family, reconciliation multiplies the repeated CI per-tick mean by the counted unit records, without mixing observed proc lower bounds into the estimate.
The report prints a modelled covered subtotal, never measured supervision, with per-family evidence, spread and qualifications.
With no compatible family the modelled subtotal is null, not a measurement of zero supervision.
Machine-minus-covered-subtotal births and busy CPU are explicit, with negative residuals preserved as contradictions and positive residuals never allocated to supervision by subtraction.
Retrospective coverage includes every admitted home crossed with the accounting tool's complete `SOURCE_FAMILIES` registry, shared by the CI plan builder and exposed by `source-families`, plus explicitly supplied additional families.
Missing instrumented families therefore remain unavailable even when both input lists omit them; complete enrollment of any additional families remains a review obligation.
Calibration revision/configuration/work-mix pins must match the admitted workload, and tick rates must belong to the exact machine window rather than another capture.
No output certifies B0, claims savings or authorizes a later capture or performance promotion.

## Exclusive accounting

[`trace-v1.schema.json`](supervision-accounting/trace-v1.schema.json) owns the normalized event shape.
Process identities are capture-local generations, not bare reusable PIDs.
Seeds establish ancestry but are not counted as new births or in-window entries.
Every event carries an `executable` path and `exec_evidence`: births require empty executable/argv with `none`, execs require `execve` or `execveat`, and seeds require `proc-exe-cmdline`.
A seed's cmdline is mutable, so any family inferred from it is only a reported `seed_ownership` hint, never proof of a script entry.
`seed_cmdline_hints` counts such provisional owners and prevents a complete attached-tree verdict while any are present.
Missing executable/evidence fields are refused rather than inferred from argv.
A birth first inherits its nearest known executable-entry family.
Its first recognized direct script exec assigns that birth to that script family exactly once.
Subsequent recognized execs in the same process change the owner of future descendants and add entries, but do not invent another birth or move that first direct-entry allocation.
This rule makes every observed birth belong to one and only one family.
Entries, caller edges, thread counts, origin ancestry and births are separate dimensions and must never be added together.

A recognized entry requires the kernel exec pathname to equal an admitted absolute script path, or a supported absolute shell pathname with that script as its operand.
Supported shell executable paths are `/bin/bash`, `/usr/bin/bash`, `/bin/sh` and `/usr/bin/sh`; argv[0] is never executable identity.
Direct script execution is recognized even with an alternate argv[0].
Supported shell options are combinations of `-e`, `-u`, `-x`, `-v` and the `--` separator; command/stdin modes, operand-taking or unknown options cannot establish script entry.
Relative executable paths and fd-relative/empty execveat paths retain their evidence but cannot establish entry without resolved executable identity.
A script name in sourced text, `bash -c`, an environment string or a descendant's unrelated argv is not an entry.
The caller is the executable owner immediately before that exec, including an inherited owner where applicable.
Shared code roots are disambiguated by the seed's owner-published home, not by searching a filesystem.
Relative script paths, unrecognized shell options and unavailable argv cannot establish direct script entry.
Such descendants retain the proven ancestry allocation; unavailable ancestry remains unattributed.
Entries retain `target` separately from `action`.
Control uses its actual `<task-id> <interrupt|exit|relaunch>` positional grammar; missing target/verb is `call_shape: malformed`, and unsupported verbs are `unknown`, never lifecycle entries.
Spawn labels its target and spawn/relaunch/restore action; other families label read/observe/drain/snapshot work rather than treating a task id as a verb.
The lifecycle label identifies a recognized spawn/control entry shape, not full CLI validation, admission or proof that an external action completed.
Neither high spawn-labelled births nor library sourcing alone proves a restart storm.
Repeated snapshot-to-crew edges expose repeated read paths, but do not prove erroneous duplicate requests without the sealed request trace.

The exclusive table always includes an unattributed bucket.
The residual is the machine counter delta minus observed births.
It is retained even when negative; negative residuals are contradictions, never clipped to zero.
Positive residual is outside the explicitly attached descendant trees and, where declared, attachment/loss gaps; it is not all supervision and not a saving.
Completeness is false on losses, provisional seed ownership, unattributed births or a negative residual.
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
An absent, symlinked, nonregular, malformed, NUL-containing, unterminated, unsupported-mode or stale record refuses.
The shell reader uses a NUL delimiter and a 64-byte cap before its exact comparison, so Bash cannot silently discard binary bytes; every valid record is shorter than that cap.
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
Proc regressions additionally replay synthetic multi-home samples with shared code roots, boundary ambiguity, CPU and birth contradictions, PID reuse, re-exec, read losses and every provisional family.
CI exercises a one-second proc capture against its already-running test process, with no launched workload; privileged CI containers assert the refusal instead of claiming unprivileged live coverage.
The public CLI counterfactual requires the new proc mode, exact machine denominator and null measured-attribution verdict, so removing the route or treating hints as proof fails the regression.
Model regressions replay sealed multi-home tick records, non-unit calibration divisors, all named families and an additional family, missing coverage, wider-window rates, partial lines, zero ticks, code/configuration mismatch, shared records, aliases, loss and tampering.
Independent birth and CPU overestimate cases leave the observed lower bound consistent while requiring negative model residuals and `model-total-contradiction`; removing the model-total check fails them.
The CI-only collector integration reads a static fixture tick log, measures zero new ticks, and reproduces the recorded report offline without launching a tick-generating workload.
An otherwise-valid admitted FIFO tick record must refuse with the nonregular-record diagnostic within a bounded subprocess, not publish an empty zero-tick report.
The separate [`proc-bounds-fixture-v1.schema.json`](supervision-accounting/proc-bounds-fixture-v1.schema.json) admits only explicitly synthetic guard probes with closed, small clock/limit/pause, read-region and credential inputs.
That fixture-only command exercises the same process-local real-time alarm, per-scan deadline, task-count guard and credential validator as live capture, without reading procfs, writing evidence or running a workload.
Paired positive/negative fixtures require the exact refusal for each guard; removing any guard makes its negative case succeed and fails the regression.
The read-region probe runs the real per-PID reader and scan exception handlers over synthetic bytes, delivering the process-local alarm deterministically during the last PID of the final scan at stat, stat reread, cmdline or executable lookup.
Every expiry must exit 2 with the deadline diagnostic and no success stdout; the ordinary pause probe separately checks real timer scheduling.
Credential cases independently test root with zero effective capabilities and nonroot with nonzero effective capabilities, requiring their respective diagnostics and no success output, without requesting or changing privileges.
Fixture controls have no live flags or environment inputs, cannot be included in a closed live manifest, and the synthetic probe format is refused as a live manifest or raw recording.
The fixture pause is capped at 200ms and its task array at sixteen items; it is not an alternate live capture source.
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
