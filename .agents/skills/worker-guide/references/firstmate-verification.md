# Firstmate repository verification

Read this before your first push on a direct-push task that changes Firstmate's own repository.
Your brief's `# Definition of done` owns the process: the local checks between pushes, when and what you push to CI, how you handle a red run, and landing only a head whose exact-head CI branch run passed.
This file owns the lean pre-push review, the commit-message lines CI requires, waiting on your CI branch, and how a parity test reports.
`<task-id>` below is your task id, so your CI branch is `ci/<task-id>`, and `<owner>/<repo>` is the repository you push to.

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

## Waiting on your CI branch

Push the head with `git push origin HEAD:refs/heads/ci/<task-id>`.
If that plain push is refused because an earlier attempt left a head there that yours does not contain, delete your own CI branch with `git push origin --delete ci/<task-id>` and push again; never force it.
Then append `paused [at=<epoch>]: waiting on ci/<task-id> checks for {sha} until <YYYY-MM-DDTHH:MMZ>` and wait for the CI workflow's run on that exact commit within the same bound as the Definition of done's post-landing wait: re-list with `gh run list -R <owner>/<repo> --branch ci/<task-id> --commit <sha>` at most every 2 minutes until it appears, then `gh run watch <run-id> --exit-status --interval 120 -R <owner>/<repo>` (`tool-design` section 5 says why).
To stop at ready, or to refresh a ready branch, push to your task branch only a head whose CI branch run passed.

## Parity tests

A parity test, one that checks a new implementation against an old one, enumerates and never fails fast: it runs both over the whole fixture corpus plus a generated sweep across the dimensions where cases keep turning up (ordering, empty and missing fields, malformed input, offsets), prints one line per mismatching case (case id, field, old value, new value), and exits non-zero once at the end, so one red run lists every mismatch.

## After landing

Wait on the default branch's own checks exactly as the Definition of done says.
Running homes follow the `green` branch, which advances to your commit only once that main run passes, so a red main reaches no home; still fix it forward or revert it at once as the Definition of done says.
Once landed, also delete your CI branch: `git push origin --delete ci/<task-id>`.
Your Definition of done runs the helper landing gate before the landing push, and `direct-push-landing.md` says how to park while it holds.
Your brief's `bin/fm-helper-consumers.sh pending HEAD` line records any Firstmate helper version another home runs under a pin its consumers have not accepted yet and notes it for their review (`docs/helper-consumers.md`); it is quiet when nothing is declared.
