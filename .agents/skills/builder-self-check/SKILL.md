---
name: builder-self-check
description: Load first, before reading the code, when you start a fix round that answers review findings (a FAIL verdict, a re-review or a lean pre-push review) or start implementing a brief's fix, guard, refusal, alarm, parser, reader, kit or helper; and load it again, before checking git state, when you are about to report READY, write a ship or completion report, push for review or hand off any change you built. Holds the builder's own checks, so review finds nothing the builder could have found - one revert-counterfactual per new guard, unknown state read both ways, the adversarial-input list for readers, a read-only live probe, each finding restated as a class with its siblings fixed, every restatement of a changed contract updated, and evidence from the exact clean head. Use it even for a one-line fix or a change whose tests already pass.
user-invocable: false
metadata:
  internal: true
---

# builder-self-check

Why this skill exists: fixes closed the reviewer's counterexample instead of its class, and guards shipped without proof that they ever fire (root cause R5); the live-system, adversarial-input and exact-head checks lived only on the reviewer side, so each one cost a review round (R1).
Run these checks yourself before a handoff, because every gap a reviewer finds first costs a full round of waiting, and the same input shapes were found one round at a time on change after change.

This skill owns the builder side only.
`lean-review` owns what review checks and how verdicts work, `tool-design` owns how an alarm, reader or helper should behave, and `firstmate-shell-tests` owns the shell and test traps in the Firstmate fork.

## 1. Prove each new guard with one revert-counterfactual

For every new or changed guard, refusal, alarm or check, revert just that guard, run its test, see it fail, and restore it.
One run per guard is enough; mutant sets stay with the nightly job, which gates nothing, so do not bring them into a handoff.
A test that still passes with the guard reverted proves nothing about the guard, usually because its fixture trips several refusals at once.
Give each guard its own fixture in which every other guard passes and only that one fires, and assert the observable refusal (exit status, message, no side effect).
Record the counterfactual in the handoff: which guard, which test, and that it failed with the guard reverted.

## 2. Read unknown state both ways

For every new read of a file, record, command result or service answer, test both directions:

- an unknown, unreadable, partial or erroring answer is a failure that refuses or alarms, never a default or a healthy verdict;
- a healthy but empty state (no tasks, an empty log, nothing queued) is not an alarm.

`tool-design` section 1 owns the rule; this is the check that you tested both halves.

## 3. Probe readers with the adversarial-input list

Before handing off anything that reads a file, record or log, run it against each shape that applies:

- missing, empty, and whitespace-only;
- mode 000 (unreadable), a dangling symlink, a directory, and a FIFO where a file is expected;
- NUL bytes, no trailing newline, and a partial last line;
- truncated and then regrown to the same or a larger size;
- huge (enough to cross argv, memory or per-tick cost limits);
- killed mid-write, leaving a partial or temporary file;
- run with SIGPIPE ignored, as GitHub runners start processes;
- stock macOS bash 3.2.

Also build fixtures from the shapes the real system holds: an old record version, aged or large data, and a foreign `PATH` such as a systemd unit's.

## 4. Probe the live system read-only

Before READY, run the change against the real inputs it will meet - current record versions, a unit's real environment, real directory sizes - in a mode that writes nothing.
A fixture encodes what you believe the input looks like; the live read is what catches the belief being wrong.
If no read-only mode exists, say so in the handoff instead of skipping the probe silently.

## 5. Fix rounds: fix the class, not the instance

When review or the lean pre-push review returns findings:

1. Restate each finding as a class (what kind of mistake) before touching code.
2. Scan the siblings: the same file, the same helper family, and every other copy of the pattern.
3. List the scan in the fix packet - the places checked and what each one needed.
4. Give the fix code the same rigor as new code, including its revert-counterfactual.
5. Re-run the reviewer's own probe, not only your tests.

Fix the whole finding list in one batch, mapping each row to a fix or an explicit deferral.

## 6. Update every restatement of a changed contract

When a change alters a contract - a format, an outcome value, a flag, a documented behavior - grep the repository for its other statements (docs, skills, usage comments, tests that assert prose, pinned component sources) and update or remove each one in the same change.
`firstmate-coding-guidelines` owns the one-owner rule this enforces.

## 7. Evidence comes from the exact clean head

Rerun the required checks on the clean, committed head you are handing off, and cite that head's sha.
A run from an earlier head, from a dirty tree, or from before a rebase is not evidence for this head.
In the Firstmate fork, the CI branch run on the exact head is that evidence; the brief's verification reference owns how to get it.
