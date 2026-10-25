---
name: lean-review
description: Load before planning, briefing, running or judging any review of a change - independent review, re-review, review round, PR review, rehearsal or landing check - and when deciding how much review a change needs.
user-invocable: false
metadata:
  internal: true
---

# lean-review

Goal: catch every defect that matters in as few rounds, reruns and waiting hours as possible; the costly failures are a defect that reaches main or a live run, and a review that waits or repeats work that proves nothing new.
Judge findings and options only on correctness and safety, future-proofing and maintainability; development time, effort and size are never a reason for or against anything.

## Depth by risk

Set the tier at intake, from what breaks if the change is wrong, not from its size or location:

- **High** - live data or experiments, landing gates, merge, cleanup or discard paths, storage, security, cross-home contracts, anything irreversible: heavy checks without mutation testing.
- **Normal** - code, tests, fixtures and config: a light pass; heavy runs only for what the light pass cannot reach.
- **Low** - no executable or machine-read byte changes (wording, docs, comments): a light check by a non-author where the path has reviewers, otherwise the path's own checks.

When unsure, take the higher tier; tests, fixtures and config are at least Normal.
The tier sets depth inside the delivery path, which owns rigor once it runs.
Add an independent reviewer only where the path includes one or the operator asked; on a no-mistakes project the path's review is the review, and if more seems needed, ask rather than stack a reviewer onto it.
Destructive, irreversible and security-sensitive steps still go to the operator at any tier.

## One round catches everything

- Run every check to the end, with no fail-fast; record a stage whose input is missing as skipped, with the reason.
- The reviewer keeps going after a blocker and posts one verdict with every finding, labelling any that may only show after a fix.
- Each run writes one error list: stage, evidence, cause class (real defect, test defect, environment, flaky) and shared-cause group.
- The builder fixes the whole list in one batch, mapping each row to a fix or an explicit deferral, and the reviewer reviews that one delta.

## Do not wait, do not repeat

- Where the path has reviewers, every ready item gets one at once and independent pieces build in parallel; critical-path work goes first in shared test slots.
- Post a draft verdict when the light pass ends, so the builder starts fixing; heavy results follow as an addendum that can only add findings, and a PASS is final only after it.
- Verify the builder's sealed results (tree hash of the exact head, pinned interpreter and pins digest, slot-written job id and rc, output hashes) instead of re-running them; run your own probes, with no mutation testing.
- A missing or mismatched seal fails the packet.
- Take the heavy ticket at READY, so the queue wait overlaps the reading.
- The one rehearsal is the landing gate's own run on the candidate, started at ready and repeated only if the code or main moved.
- Full mutant sets run only in the nightly job, which gates nothing; a nightly finding is fixed forward.

## Verdicts

- FAIL needs at least one major; a test gap that would let a wrong result through is a major.
- Otherwise PASS with minors, which close in one light follow-up (read the delta, light tests) with no new heavy round unless non-test code changes.
- A re-review checks closures plus the delta (`bin/fm-rereview-brief.sh` for landed fixes), not a fresh full review.
- Review never grants merge authority: landing authority is the operator's word or the project's `yolo` posture (`AGENTS.md` sections 1 and 7), and a recorded standing go applies only within the scope it names.
- A red head, or one whose required check has not reported, never lands.
