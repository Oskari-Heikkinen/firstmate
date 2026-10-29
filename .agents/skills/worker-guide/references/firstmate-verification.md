# Firstmate repository verification

Read this before your first push on a direct-push task that changes Firstmate's own repository.
Your brief's `# Firstmate repository verification` section keeps the rules that stay inline: no local suite, the `ci/<task-id>` push, and landing only a head whose CI branch run passed.
This file owns every rule below for how often and what you push to CI and how you handle its result; what must pass before a landing is your Definition of done's.
`<task-id>` below is your task id, so your CI branch is `ci/<task-id>`, and `<owner>/<repo>` is the repository you push to.

## Between pushes

Between pushes run only the seconds-long local checks, `bash -n`, single-file `shellcheck`, and `bin/fm-lint.sh` on the files you touched, never a local test suite, because CI runs the suite.

## Lean pre-push review

Before you push any commit that changes a script matched by `tests/risky-areas.list`, it must pass the lean pre-push review, a separate read-only reviewer call whose header in `bin/fm-lean-review.sh` owns the questions (four, plus Q5 architecture conformance when the commit touches a component-map path), the verdict, and the receipt.
Review only the batch commit you will push, never an intermediate one: squash a build or fix round's work into that one commit first, so one receipt covers it.
Then write your Captain's intent text to a file outside the worktree and run `bin/fm-lean-review.sh --intent-file <that file>`; a pass adds the `Lean-Review:` receipt trailer to that commit, a commit that already carries its matching receipt is not reviewed again, and other commits need no review.
On FIX findings, amend the fix into that same commit and review again.
If the review itself errors, run it once more and treat a second error as a blocker.
Report any `fm-lean-review: warning:` line the review prints in your ready report.
On a DECIDE finding, append a `needs-decision` status line naming it and stop, then re-run with firstmate's answer added to the intent file.
Never judge your own finding or write the trailer by hand.
A plain rebase keeps a receipt valid, but a conflict resolution or any later edit to a reviewed commit's risky-area files needs a fresh review.

## Commit-message lines CI requires

CI judges every commit you push, not only the tip, through `bin/fm-safety-guard.sh`, whose header owns the rules:
- a commit that changes a script matched by `tests/risky-areas.list` must also add or change a test in that area, or carry a `no-test-needed: <reason>` line in its message when the change truly needs none;
- a commit that drops an entry from `tests/safety-core.list` must carry a `safety-core-removal: <reason>` line;
- a commit that changes such a risky-area script must carry the lean review's matching `Lean-Review:` receipt, which has no override.

Add the line to that commit before you push it.

## Pushing to CI

Push a head to CI only when you will act on its result; to checkpoint or back up work, commit locally or push your `fm/<task-id>` branch.
Never push a tree that already has a CI run, outside the `ci/full/<task-id>` exception below: when `git rev-parse HEAD^{tree}` equals the tree of a head you pushed before (`gh run list -R <owner>/<repo> --branch ci/<task-id> --json headSha,url` lists them), cite that head's run instead.
Push a head that may land only to `ci/<task-id>`, never to `ci/full/<task-id>`, because a green `ci/<task-id>` run is the landing proof and its plan job runs the full layout by itself when the change needs it ([`docs/fm-test-portable-shards.md`](../../../../docs/fm-test-portable-shards.md) owns the layouts); the one exception is a landing candidate whose `ci/<task-id>` plan summary says it ran the changed-area `ci` layout while your brief explicitly requires a full-suite pass, and then you push that same head to `ci/full/<task-id>` once.
Push a mutant head, the head with one guard reverted, to its own `ci/<task-id>-mutant-<name>` branch only for a guard whose test is new or changed in this round, and for a mutant whose guard and tests did not change, cite its earlier run instead.
Rebase only when a conflict forces it or once for the landing candidate, never between fix rounds; when you expect a round to be the last, rebase it onto current `origin/<default-branch>` before its push, so that run is the landing candidate's.

## Waiting on your CI branch

Push the head with `git push origin HEAD:refs/heads/ci/<task-id>`.
If that plain push is refused because an earlier attempt left a head there that yours does not contain, delete your own CI branch with `git push origin --delete ci/<task-id>` and push again; never force it.
Then append `paused [at=<epoch>]: waiting on ci/<task-id> checks for {sha} until <YYYY-MM-DDTHH:MMZ>` and wait for the CI workflow's run on that exact commit within the same bound as the Definition of done's post-landing wait: re-list with `gh run list -R <owner>/<repo> --branch ci/<task-id> --commit <sha>` at most every 2 minutes until it appears, then `gh run watch <run-id> --exit-status --interval 120 -R <owner>/<repo>` (`tool-design` section 5 says why).
To stop at ready, or to refresh a ready branch, push to your task branch only a head whose CI branch run passed.

## A red run

On a red run, run `bin/fm-ci-errors.sh --out <your task data folder>/ci-errors/<run-id> <run-id>` once the run has finished and read its whole `errors.md` before you change anything: its header owns how it reads every failed job and every failing test in every shard and how it classes each row (real, flaky, infra, or unknown).
Read the job log the list saved for each unknown row and decide that row's class yourself; if the tool refuses, build the same list by hand from `gh run view <run-id> -R <owner>/<repo> --log-failed` and, in each failed shard, every `FM_TEST_END ... exit=` line whose exit is not 0.
Fix every real row, whether it is a real bug or a test defect, in one commit, give it the lean pre-push review above when that applies, and push it once; that push is the only new run the round makes.
An infra row is a job that never got a runner (the Darwin calibration job included), was cancelled before its first step, or lost its runner mid-job, and an infra-only red run gets no new push: run `gh run rerun <run-id> --failed -R <owner>/<repo>` once, and if the same job fails the same way again, append `blocked:` naming the run URL.
A flaky row is a test on `tests/known-flakes.list`: when flaky rows are a run's only failures and your change does not touch what they test, treat them as infra and name the run URL in your status line, so the flake fix gets the evidence.

## Parity tests

A parity test, one that checks a new implementation against an old one, enumerates and never fails fast: it runs both over the whole fixture corpus plus a generated sweep across the dimensions where cases keep turning up (ordering, empty and missing fields, malformed input, offsets), prints one line per mismatching case (case id, field, old value, new value), and exits non-zero once at the end, so one red run lists every mismatch.

## After landing

Wait on the default branch's own checks exactly as the Definition of done says.
Running homes follow the `green` branch, which advances to your commit only once that main run passes, so a red main reaches no home; still fix it forward or revert it at once as the Definition of done says.
Once landed, also delete your CI branch: `git push origin --delete ci/<task-id>`.
Your brief's `bin/fm-helper-consumers.sh pending HEAD` line records any Firstmate helper version another home runs under a pin its consumers have not accepted yet and notes it for their review (`docs/helper-consumers.md`); it is quiet when nothing is declared.
