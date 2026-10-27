---
name: lean-review
description: Load first, before reading the branch or briefing anyone, when you plan, brief, run or judge any review of a change - an independent review, a re-review of the fixes for earlier findings, a review round, a PR review, a rehearsal or a landing check - when you write up a review verdict or decide whether a draft PASS is final, and when you decide how much review or evidence (sealed test results, a rehearsal) a change needs. Holds review depth by risk, one-round reviews, what a reviewer must not wait for, and when a verdict is final.
user-invocable: false
metadata:
  internal: true
---

# lean-review

Goal: catch every defect that matters in as few rounds, reruns and waiting hours as possible; the costly failures are a defect that reaches main or a live run, and a review that waits or repeats work that proves nothing new.
Judge findings and options only on correctness and safety, future-proofing and maintainability; development time, effort and size are never a reason for or against anything.

Why this skill exists: findings were written as single instances, so builders closed the counterexample and the next round found its sibling, and review ceremony (seals, repeated runs, extra rounds) was added one incident at a time (root cause R5).
`builder-self-check` owns the checks a builder runs before handing a change to review.

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
- Write each finding as its class first (what kind of mistake), then the instance found, then the evidence, and name the sibling places the builder must check for the same class; a finding stated only as an instance gets that instance fixed and its siblings found one round later.
- The builder fixes the whole list in one batch, mapping each row to a fix or an explicit deferral, and the reviewer reviews that one delta.

## Do not wait, do not repeat

- Where the path has reviewers, every ready item gets one at once and independent pieces build in parallel; critical-path work goes first in shared test slots.
- Post a draft verdict when the light pass ends, so the builder starts fixing; a draft may list findings at any point, but say PASS only after your own probes have finished, because a draft PASS that turns into a FAIL sends the builder to land the wrong head.
  Heavy results follow as an addendum that can only add findings, and a PASS is final only after it.
- Verify the builder's sealed results (tree hash of the exact head, pinned interpreter and pins digest, slot-written job id and rc, output hashes) instead of re-running them; run your own probes, with no mutation testing.
- Evidence is proportionate: ask for no seals, manifests or attestation paperwork beyond what the change's risk needs; where the path does require a seal, a missing or mismatched one fails the packet.
- Take the heavy ticket at READY, so the queue wait overlaps the reading.
- The one rehearsal is the landing gate's own run on the candidate, started at ready and repeated only if the code or main moved.
- Full mutant sets run only in the nightly job, which gates nothing; a nightly finding is fixed forward.
- No check runs twice on the same inputs: a head that already passed a gate is not re-run through the same gate, and a set whose inputs did not change is not re-run; cite the earlier result instead.

## Verdicts

- FAIL needs at least one major; a test gap that would let a wrong result through is a major.
- For each new or changed guard, refusal or alarm, check that some test fails with only that guard reverted; a fixture that trips several refusals at once proves none of them, and that gap is a major.
- Otherwise PASS with minors; batch their closure in the author's delta and proportionate checks.
  For low-risk changes the independent review ends after that one round; commission another only for a real blocker or major, not merely to re-confirm minors.
  Higher-risk changed behavior keeps the delivery path's required delta checks.
- A re-review checks closures plus the delta (`bin/fm-rereview-brief.sh` for landed fixes), not a fresh full review, and asks whether the builder's sibling scan for each finding's class was done and listed.
- Review never grants merge authority; apply `AGENTS.md` section 1 to the exact ready head and route a qualifying head immediately under its existing authority.
- A red head, or one whose required check has not reported, never lands.
