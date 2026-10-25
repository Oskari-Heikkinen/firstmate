---
name: supervision-accounting
description: Load before collecting, importing or judging a supervision birth trace, validating an owner fleet manifest or replay corpus, or using the legacy reader capability/fence APIs.
user-invocable: false
metadata:
  internal: true
---

# Supervision accounting

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
- Missing tools, elevation, ptrace grants or a changed capture route require a separate decision; never install or elevate implicitly.
- Read the CLI result and artifacts and report success/refusal through the existing task status owner; do not leave an unobserved artifact or add a poller.
- Preserve raw evidence, losses, contradictory residuals and synthetic provenance.
- Code never certifies B0, even from self-asserted complete inputs; review of real capture evidence is required and no P0 saving is claimed.
- Publish only owner-attested inventory, not inferred foreign endpoint state.
- The bridge does not activate a resident mode or assert that running readers/callbacks are already capable.
- Keep real fleet data and traces in private task evidence; only synthetic fixtures belong in git.
