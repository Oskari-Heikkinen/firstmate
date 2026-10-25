---
name: component-skills
description: Load before changing the component map tools, the component hook, review injection or a repo's docs/component-map.json. One map per repo is the only path-to-skill source; the hook informs on every touch and never guesses or blocks, and every review path gets the touched components' Review checks.
user-invocable: false
metadata:
  internal: true
  sources:
    - path: docs/component-map.md
      sha256: 462693da0651576c1868a7864a55a2902f9c782f03385cf4418ec3aa67248dd6
    - path: bin/fm-component-map.sh
      sha256: 299f07ae24496b90e11de3803565b229b7225a206948cf066ff77e4f3c839d8f
    - path: bin/fm-component-map.py
      sha256: 6c52c2829189fa348de94e880842e4f63e2e6ee4b46d0366233f4bedf30325ad
    - path: docs/component-skills.md
      sha256: 4340ae5dc58083a4ccc691dfc7614ffbd072c1fd4cf28869ce995263227a9dab
    - path: bin/fm-component-check.sh
      sha256: 08974b6c091859d8ab3aaf35480c0ceb75d2198c8cd68fae13fde2d2359c4f1f
    - path: bin/fm-component-spawn-lib.sh
      sha256: 8cff6ca011203c0631df69d4ffb5602cf86d433c2219b6b5f5b28f5eaaf48aed
    - path: bin/fm-component-drift.sh
      sha256: 28f4a051931f4daa11582aa8ba0238b8ce188d19777d44ade361373489317800
    - path: bin/fm-lean-review.sh
      sha256: 3fab912ec49bcb2d0255aa6b03d17c7cfc10a633d98c68ccbe1c237abdf5318e
    - path: bin/fm-rereview-brief.sh
      sha256: ea7b845531d394253c06f2bd75bdb823170a0c6c2b8c0f64c1e7aa01411f7d50
    - path: .agents/skills/independent-rereview/SKILL.md
      sha256: 1d749d8c07bf0a041de7eb555f0804b89f50e445f5b0d30e72cd42da1bd25595
---

# component-skills

## Goal and operating principle

Every agent that touches a mapped path gets that component's goals, and every review of a change gets that component's review checks, without depending on the model choosing a skill from its description.
One map per repo, `docs/component-map.json` (schema `component-map/v1`), is the only path-to-skill source; the hook, the brief section, the review-pack resolver and the coverage check all read it and nothing else.
`bin/fm-component-map.sh` is its one reader (`check`, `touched`, `goal`, `review-pack`, `drift`), and `docs/component-map.md` owns the schema, the skill shape and the pin format.
The hook informs and never blocks: it injects the matched skill's `## Goal and operating principle` and its path once per session and again after compaction, stays silent on unmapped paths, and fails open on bad input or a missing map.
Review checks reach reviewers as prompt text, because dedicated reviewers run with project skills off.
Each component skill pins its defining sources by sha256 in `metadata.sources`, and a drift check names any skill whose source changed; a daily timer run of `bin/fm-component-drift.sh` keeps one item per drifted skill in its owner home.
This mechanism is owned here; each skill's contents belong to its component's owner.

## Refuse

- A second path-to-skill list anywhere: in the hook, a brief template, a review script, skill `paths:` frontmatter or `.claude/rules` (architecture skills plan section 3 item 1; the one-owner rule in `firstmate-coding-guidelines`).
- Guessing a component from file names or similarity when the map has no match (the plan's C3 goal: "never guesses").
- Denying or delaying a tool call until a skill is read (plan open question 4: inject only).
- Failing closed on malformed hook input or a missing map, exiting 2 on any failure, or reporting a malformed map more than once (plan section 3 item 2; `docs/component-skills.md` "Output contract").
- Parsing a map or a skill inside the hook instead of through `bin/fm-component-map.sh` `touched` and `goal` (`docs/component-skills.md` "Purpose and boundary").
- A Bash sweep that takes git's index lock or re-reads every dirty path's content instead of the batched status, size and mtime fingerprint (`docs/component-skills.md` "Shipped mechanism").
- Launching a spawned review whose pack cannot run, passing a review without reporting an unavailable checklist as a finding, or letting a pack failure stop the lean review from asking Q1-Q4 or still give the commit a receipt (`docs/component-map.md` "Review paths"; `bin/fm-lean-review.sh` and `bin/fm-spawn.sh` headers).
- Injecting the whole skill, or injected text over the harness's context cap (plan open question 3: the goal section plus the path; `docs/component-skills.md` keeps it under 9,500 characters).
- Relying on description triggering alone, or on skills loading inside a reviewer that runs without project settings (plan sections 3 and 4).
- Weakening any rule `check` enforces so a map passes: accepting unknown keys, letting a non-provisional glob match no tracked file, leaving a tracked file under `roots` in no component, allowing more than six components on one path or a goal section over 1,500 characters; or marking a component `provisional`, narrowing or dropping `roots` to silence a no-match or coverage error (`docs/component-map.md` "Repository map", "Component roots", "Provisional components" and the skill-shape table; `bin/fm-component-map.sh` header).
- Re-pinning a hash to silence drift without reading the source delta and updating the skill (plan section 5 "Update path").
- Running the cross-home drift check as an agent task or a remembered command instead of the timer-run `bin/fm-component-drift.sh`, detecting drift other than through `drift`, a second open item for one skill, or an owner registry beside `metadata.owner` (`docs/component-map.md` "Drift run"; `bin/fm-component-drift.sh` header).
- A project-, repo- or component-specific branch in the hook, resolver or checker code (tool-design rule 4).
- Editing another repo's tracked settings to install the hook (plan section 3 item 3).
- Wording injected text as commands rather than facts (plan section 3 item 2).

## Review

Answer each check PASS or FINDING.

1. Is the repo's `docs/component-map.json` still the only place a path is tied to a skill?
2. Does an unmapped path or a repo without a map stay silent, a malformed map report once, and no outcome deny a tool call?
3. Is each component injected once per session, again after compaction, and separately for a subagent, with a path in two components injecting both?
4. Is the injected text the goal section plus the skill path, phrased as facts, and under the size cap?
5. Does every review path (self-review, lean review, no-mistakes, non-author review briefs) receive the Review checks of every touched component?
6. Is every supported harness reached by the hook or by brief injection, with the gap for hook-less harnesses closed by the brief?
7. Does the drift check flag a changed or vanished pinned source and stay silent when nothing changed, and does the drift run file one item per drifted skill in its owner home, rewrite it on a changed drift and file nothing on an unchanged run?
8. Does `check` still refuse an unknown key, a non-provisional glob matching no tracked file, an uncovered tracked file under `roots`, a path claimed by more than six components and a goal section over 1,500 characters, and is every `provisional` flag or `roots` change justified by code that has not landed rather than by a failing check?
9. Would the component-map and hook tests fail, through the public commands, if this behaviour broke?
10. Would a new repo or component need only a map row and a skill, not a code change?
11. If a source pinned in this skill's `metadata.sources` changed, does every rule here still hold, and are the pins updated in the same change?
