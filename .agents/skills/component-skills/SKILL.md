---
name: component-skills
description: Load before changing the component map tools, the component hook, review injection or a repo's docs/component-map.json. One map per repo is the only path-to-skill source; the hook informs on every touch and never guesses or blocks, and every review path gets the touched components' Review checks.
user-invocable: false
metadata:
  internal: true
  sources:
    - path: docs/component-map.md
      sha256: e648230068fadcb2c40b72fe436ba83343075b4cfa405b51b0dc5c2b13653e80
    - path: bin/fm-component-map.sh
      sha256: e7ef850b82cce060ffa57ec512efdbb666387867f986c4242391499b30e554c6
    - path: bin/fm-component-map.py
      sha256: e6d09b94f9f29ae40b4ea34b00b93c3195089313a132e656b4d324d7af7d918e
    - path: bin/fm-lean-review.sh
      sha256: cdb2b6e7d7b1db33ecce337746a13ca947377419499775d74051f007b160e470
---

# component-skills

## Goal and operating principle

Every agent that touches a mapped path gets that component's goals, and every review of a change gets that component's review checks, without depending on the model choosing a skill from its description.
One map per repo, `docs/component-map.json` (schema `component-map/v1`), is the only path-to-skill source; the hook, the brief section, the review-pack resolver and the coverage check all read it and nothing else.
`bin/fm-component-map.sh` is its one reader (`check`, `touched`, `review-pack`, `drift`), and `docs/component-map.md` owns the schema, the skill shape and the pin format.
The hook informs and never blocks: it injects the matched skill's `## Goal and operating principle` and its path once per session and again after compaction, stays silent on unmapped paths, and fails open on bad input or a missing map.
Review checks reach reviewers as prompt text, because dedicated reviewers run with project skills off.
Each component skill pins its defining sources by sha256 in `metadata.sources`, and a drift check names any skill whose source changed so its owner updates the skill.
This mechanism is owned here; each skill's contents belong to its component's owner.

## Refuse

- A second path-to-skill list anywhere: in the hook, a brief template, a review script, skill `paths:` frontmatter or `.claude/rules` (architecture skills plan section 3 item 1; the one-owner rule in `firstmate-coding-guidelines`).
- Guessing a component from file names or similarity when the map has no match (the plan's C3 goal: "never guesses").
- Denying or delaying a tool call until a skill is read (plan open question 4: inject only).
- Failing closed on malformed hook input or a missing map, or reporting a malformed map more than once (plan section 3 item 2).
- Letting a failing or partial `review-pack` block or fail the lean review instead of warning and running Q1-Q4 without Q5 (`bin/fm-lean-review.sh` header).
- Injecting the whole skill, or injected text over the harness's context cap (plan open question 3: the goal section plus the path).
- Relying on description triggering alone, or on skills loading inside a reviewer that runs without project settings (plan sections 3 and 4).
- Weakening any rule `check` enforces so a map passes: accepting unknown keys, letting a non-provisional glob match no tracked file, leaving a tracked file under `roots` in no component, allowing more than six components on one path or a goal section over 1,500 characters; or marking a component `provisional`, narrowing or dropping `roots` to silence a no-match or coverage error (`docs/component-map.md` "Repository map", "Component roots", "Provisional components" and the skill-shape table; `bin/fm-component-map.sh` header).
- Re-pinning a hash to silence drift without reading the source delta and updating the skill (plan section 5 "Update path").
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
7. Does the drift check flag a changed or vanished pinned source and stay silent when nothing changed?
8. Does `check` still refuse an unknown key, a non-provisional glob matching no tracked file, an uncovered tracked file under `roots`, a path claimed by more than six components and a goal section over 1,500 characters, and is every `provisional` flag or `roots` change justified by code that has not landed rather than by a failing check?
9. Would the component-map and hook tests fail, through the public commands, if this behaviour broke?
10. Would a new repo or component need only a map row and a skill, not a code change?
11. If a source pinned in this skill's `metadata.sources` changed, does every rule here still hold, and are the pins updated in the same change?
