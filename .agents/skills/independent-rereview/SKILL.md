---
name: independent-rereview
description: Load before briefing any independent review of a builder's change, including the re-review of fixes landed for an earlier review's findings.
user-invocable: false
metadata:
  internal: true
---

# independent-rereview

This skill owns how firstmate briefs an independent reviewer, and when and how it commissions a re-review of landed fixes.
[`bin/fm-rereview-brief.sh`](../../../bin/fm-rereview-brief.sh)'s header owns its flags, extraction rules, refusals, and the filled brief's content.

## Every reviewer brief

Scaffold every independent reviewer's brief with `bin/fm-brief.sh ... --review-range <base>...<head>` naming the change under review, so the spawn appends the review checklists of the components it touches (`docs/component-map.md` "Review paths").
Name the base the builder started from and the head it reported ready, as revisions origin carries.
`bin/fm-rereview-brief.sh` passes the range itself.

## When a re-review runs

Use this procedure only when the delivery path requires a re-review of a real blocker/major or a higher-risk changed behavior; apply `lean-review` before commissioning it.
A low-risk PASS with minors alone does not commission another round.
It is not for a first review or a fresh full review, and this skill commissions no review the captain has not asked for; section 7's delivery-path rules still decide whether any independent review is warranted.

## How to use it

1. Collect the first review's task id or report path, the landed commit, and the candidate files under review.
   The commit must already be present in the project clone; the script only reads that clone and never fetches.
2. Run `bin/fm-rereview-brief.sh` with the first report, commit, and candidate files; its `--help` owns the flags for the fix range, heavy slot, context, and read-only boundaries.
   Select its explicit `--cutover` mode only for an actual cutover review; the default is a closure-and-delta review, not a cutover gate.
3. On success it prints `filled: <brief path>`; read the brief once, then resolve dispatch and spawn it through the usual scout path.
4. A refusal names what it could not find: a missing, duplicated, or empty Verdict or Findings section, an absent report, an unknown commit or base, a root commit without `--base`, or a candidate path that is not a file at that commit.
   It writes nothing on refusal, so fix the input or ask the first reviewer's report owner rather than hand-writing the brief around the gap.

## What agents no longer do by hand

Do not copy the first report's verdict and findings into a brief, compute candidate digests, or retype the read-only, heavy-run, and report-shape rules.
Do not summarize the findings in place of the report's own words; the script quotes them verbatim so the re-reviewer checks exactly what the first review found.
