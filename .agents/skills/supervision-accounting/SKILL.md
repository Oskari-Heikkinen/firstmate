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
- A live capture needs the owning home's explicit, reviewed, bounded ordinary-workload authorization and published root identities; the dedicated default-refusing live guard's header owns its controls.
- Missing tools, elevation, ptrace grants or a changed capture route require a separate decision; never install or elevate implicitly.
- Read the CLI result and artifacts and report success/refusal through the existing task status owner; do not leave an unobserved artifact or add a poller.
- Preserve raw evidence, losses, contradictory residuals and synthetic provenance.
- Code never certifies B0, even from self-asserted complete inputs; review of real capture evidence is required and no P0 saving is claimed.
- Publish only owner-attested inventory, not inferred foreign endpoint state.
- The bridge does not activate a resident mode or assert that running readers/callbacks are already capable.
- Keep real fleet data and traces in private task evidence; only synthetic fixtures belong in git.
