---
name: supervision-accounting
description: "Load before running, calibrating or judging the supervision accounting collector (tick logs, strace or proc-only capture, fleet manifests, replay corpora, B0/P0 claims), and before using the legacy reader capability/fence APIs."
user-invocable: false
metadata:
  internal: true
---

# Supervision accounting

Why this skill exists: supervision savings claimed from estimates or records not bound to real capture did not hold up (root causes R4, R5; problem class P4).

[`docs/supervision-accounting.md`](../../../docs/supervision-accounting.md) owns the P0 formats, accounting rules, collector limits and inert legacy bridge.
The Python utility's header and help own its exact CLI.
Load `lean-supervision` and `tool-design` before changing or running the collector.
Load `lean-review` before judging results; High risk applies to supervision continuity and fencing.

- Probe read-only availability first; it never proves ptrace permission.
- Run no profiler or synthetic workload merely to see whether capture works.
- A live capture needs the owning home's explicit, reviewed, bounded ordinary-workload authorization and published root identities; the dedicated strace live guard's header owns its controls, and the utility header owns the separate proc-only opt-in.
- Proc-only sampling is explicitly selected, never an implicit fallback; its optional CI-per-tick model uses only exact owner-admitted append-only tick logs and stays separate from measured machine totals and observed lower bounds.
- Route `incomplete-unprivileged-attribution`, `pending-reviewed-model-baseline` and `model-total-contradiction` through evidence review even when recording succeeds; the owning doc defines coverage, startup and residual obligations for model-based acceptance.
- Preserve missing profiles and unavailable live tick records as gaps, not configured-cadence estimates; no model-derived rate is measured live supervision attribution and no positive residual is all supervision.
- Real-home CI plans must be selected from the reviewed tracked template path, never produced by relabelling default synthetic costs. CI calibration executes only reviewed isolated fixtures on an exact clean GitHub revision; traced births and separately untraced matched CPU repeats must prove the same units and boot. Trace-minus-untraced CPU is a signed diagnostic, not a correction or confidence interval; fixture costs are not deployment costs without matching unit, shape, configuration and exclusive scope.
- Journal v3 records carry boot identity and cross-generation stream sequence; old boots and lost whole generations cannot become current complete ticks. Legacy v1/v2 is unavailable, not upgraded; owners still attest clock-namespace equivalence.
- Tick logging is opt-in and adds no polling process; the owning doc defines its two-slot bounds, invalidation marker and accepted frozen-producer loss across two concurrent-journal rotations, which every report using the records must repeat.
- Existing actors pick up an opt-in only at their documented boundary; do not restart or inspect foreign actors to obtain records, clear a recording invalidation automatically or treat missing historic logs as recoverable by cadence.
- Missing tools, elevation, ptrace grants or a changed capture route require a separate decision; never install or elevate implicitly.
- Read the CLI result and artifacts and report success/refusal through the existing task status owner; do not leave an unobserved artifact or add a poller.
- Preserve raw evidence, losses, contradictory residuals and synthetic provenance.
- Code never certifies B0, even from self-asserted complete inputs; review of real capture evidence is required and no P0 saving is claimed.
- Publish only owner-attested inventory, not inferred foreign endpoint state.
- The bridge does not activate a resident mode or assert that running readers/callbacks are already capable.
- Keep real fleet data and traces in private task evidence; only synthetic fixtures belong in git.
