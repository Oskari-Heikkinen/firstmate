---
name: crew-briefs
description: Load before scaffolding, filling or editing a ship, scout or review brief with bin/fm-brief.sh and spawning it with bin/fm-spawn.sh - choosing its delivery mode, yolo posture, branch prefix or base branch, filling Captain's intent or Firstmate spec - and when the operator changes what a running task must deliver, since that change goes into the brief before it is relayed. Holds which flags fit which landing path, what the scaffold already says, and what the dispatcher still has to add. A routine steer, a relaunch or a model choice is not brief work.
user-invocable: false
metadata:
  internal: true
---

# crew-briefs

Why this skill exists: it prevents workers ranking options by development time (R2, P17), a train-landed ship pushing around its merge queue because its launch brief pre-authorized landing (R18), and tool work in another repo built without the tool-design skill (R29).
Each one happened because the knowledge sat where the dispatcher or the worker did not look at the moment of writing or reading the brief.

[`bin/fm-brief.sh`](../../../bin/fm-brief.sh)'s header owns the flags, kinds and placeholders, and [`bin/fm-spawn.sh`](../../../bin/fm-spawn.sh)'s header owns the delivery contract it checks at launch.
This skill owns how a ship's delivery mode and `yolo` posture are resolved at intake and how the two task subsections are filled.

## Scaffold, then fill

Pick the kind first: a ship (with `--mode`) delivers a change, a scout delivers a report, and either becomes a review with `--review-range <base>...<head>`.
How much review a change needs, and how to brief an independent one, belong to `lean-review` and `independent-rereview`.
Pass `--herdr-lab` whenever the task will drive Herdr lifecycle commands, because the scaffold cannot read the task text you fill in later.
A home's `config/brief-include.md` is appended to every brief as its own section, so standing home additions go there rather than into each brief.

Fill `## Captain's intent` with only the operator's own ask and stated boundaries, unparaphrased, plus the substance of any report, decision or PR those words refer to, with no speaker label or direct address.
Never widen it: the reviewer reads that subsection as acceptance criteria, so widening it widens the review.
Fill `## Firstmate spec` with only the build instructions that ask needs; extra generalization or hardening is follow-up work to note, not scope.
Keep every safety section the scaffold wrote, including the ship brief's worktree-isolation assertion.

## What the scaffold already says

Every ship and scout brief's Rules carry two lines the dispatcher no longer has to remember:

- The only criteria for judging options: how well they work (safety included), future-proofing and maintainability, never development time, effort, size or rollout cost.
  It is in every brief because a brief has no planner, evaluator or reviewer kind to gate it on, and the workers who write decision packets never load the home's preferences.
  Do not ask in the spec for an effort or time estimate as a ranking factor; it would contradict that rule.
- A pointer to the tool-design skill by absolute path in this home's checkout, for any task that builds or changes a tool, script, service, watcher or automation.
  A worker in another repo cannot see Firstmate's skill index, so that path is the only way it finds the skill.

## Delivery mode and yolo posture

Resolve each ship's mode and `yolo` posture at intake: a current explicit operator instruction wins, then the project's registry entry; an unregistered project ships `no-mistakes` with `yolo` off.
On a `no-mistakes-prod-only` project, product-facing, mixed, or uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
fm-brief.sh never reads the project registry for the mode; pass it explicitly.
`--yolo` belongs to fm-spawn.sh, not the brief, and decides only whether landing is pre-authorized.

Spawn a ship with `--yolo off` whenever its project lands through a merge queue or merge train.
With `on`, the launch brief gets a "Current landing authority" section saying it supersedes every earlier instruction and that landing is pre-authorized.
A worker relaunched after a park reads that section from disk and obeys it over the spec's stop-at-ready line and over any steer, because a steer does not survive a relaunch and the launch brief does.
A relaunch reuses the recorded posture, so a ship already spawned with `on` keeps it: raise that as a blocker before anything relaunches it rather than relying on a steer.
`merge-queue` owns handing the ready head to the queue.

`--branch-prefix` and `--base-branch` follow the project's standing preference, which firstmate resolves at intake and passes explicitly; their header entries say where each is refused.

## A mid-task change of the ask

Append the operator's new words to the brief's `## Captain's intent`, without a label or address, then relay them to the worker with `bin/fm-send.sh`.
The brief is updated as well as the worker because a steer is lost on a relaunch and the brief is what a relaunched worker reads.
If the worker is parked on its inbox, the relay itself picks it up; `secondmate-coordination` owns that and the send-once rule.
