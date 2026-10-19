# Firstmate repository verification

Read this before your first push on a direct-push task that changes Firstmate's own repository.
Your brief's `# Firstmate repository verification` section keeps the rules that stay inline: no local suite, the `ci/<task-id>` push, and landing only a head whose CI branch run passed.
`<task-id>` below is your task id, so your CI branch is `ci/<task-id>`.

## Lean pre-push review

Before you push any commit that changes a script matched by `tests/risky-areas.list`, it must pass the lean pre-push review, a separate read-only reviewer call whose header in `bin/fm-lean-review.sh` owns the questions (four, plus Q5 architecture conformance when the commit touches a component-map path), the verdict, and the receipt.
Right after making each such commit, write your Captain's intent text to a file outside the worktree and run `bin/fm-lean-review.sh --intent-file <that file>`; a pass adds the `Lean-Review:` receipt trailer to that commit, and other commits need no review.
On FIX findings, amend the fix into that same commit and review again.
If the review itself errors, run it once more and treat a second error as a blocker.
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

Once the local checks pass, push the rebased head with `git push origin HEAD:refs/heads/ci/<task-id>`.
If that plain push is refused because an earlier attempt left a head there that yours does not contain, delete your own CI branch with `git push origin --delete ci/<task-id>` and push again; never force it.
Then append `paused [at=<epoch>]: waiting on ci/<task-id> checks for {sha} until <YYYY-MM-DDTHH:MMZ>` and wait for the CI workflow's run on that exact commit within the same bound as the Definition of done's post-landing wait: re-list with `gh run list --branch ci/<task-id> --commit <sha>` until it appears, then `gh run watch <run-id> --exit-status`.
A red run means fix, commit, and go back to landing-loop step 1; a lost push race that makes you rebase also means a new CI branch run.
To stop at ready, or to refresh a ready branch, push to your task branch only a head whose CI branch run passed.

## After landing

Wait on the default branch's own checks exactly as the Definition of done says.
Running homes follow the `green` branch, which advances to your commit only once that main run passes, so a red main reaches no home; still fix it forward or revert it at once as the Definition of done says.
Once landed, also delete your CI branch: `git push origin --delete ci/<task-id>`.
Your brief's `bin/fm-helper-consumers.sh pending HEAD` line records any Firstmate helper version another home runs under a pin its consumers have not accepted yet and notes it for their review (`docs/helper-consumers.md`); it is quiet when nothing is declared.
