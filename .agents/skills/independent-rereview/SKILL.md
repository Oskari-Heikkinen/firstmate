---
name: independent-rereview
description: >-
  Agent-only procedure for commissioning the short independent re-review after a builder landed fixes for an earlier independent review's findings.
  Load before briefing that re-review scout.
user-invocable: false
metadata:
  internal: true
---

# independent-rereview

This skill owns when and how firstmate commissions a re-review of landed fixes.
[`bin/fm-rereview-brief.sh`](../../../bin/fm-rereview-brief.sh)'s header owns its flags, extraction rules, refusals, and the filled brief's content.

## When it runs

Use it once a builder has landed fixes for the findings of a completed independent review report, typically a cutover review whose verdict named fixes, and the next step is a short check that those findings closed.
It is not for a first review, a fresh full review, or a review the captain has not asked for; section 7's delivery-path rules still decide whether any independent review is warranted.

## How to use it

1. Collect the first review's task id or report path, the landed commit, and every candidate file the cutover would install.
   The commit must already be present in the project clone; the script only reads that clone and never fetches.
2. Run `bin/fm-rereview-brief.sh <new-task-id> <repo> --first <review> --commit <sha> --file <path>...`, adding `--heavy-slot` when this home has a heavy-slot helper, `--context` for facts the report cannot supply (such as the live copy's path and digest), and `--spec` for task-specific read-only boundaries (such as a live directory never to touch).
3. On success it prints `filled: <brief path>`; read the brief once, then resolve dispatch and spawn it through the usual scout path.
4. A refusal names what it could not find: a missing, duplicated, or empty Verdict or Findings section, an absent report, an unknown commit, or a candidate path that is not a file at that commit.
   It writes nothing on refusal, so fix the input or ask the first reviewer's report owner rather than hand-writing the brief around the gap.

## What agents no longer do by hand

Do not copy the first report's verdict and findings into a brief, compute candidate digests, or retype the read-only, heavy-run, and report-shape rules.
Do not summarize the findings in place of the report's own words; the script quotes them verbatim so the re-reviewer checks exactly what the first review found.
