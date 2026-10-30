# Direct-push push races, helper acceptance and post-landing check wait

Read this when a direct-push landing push is refused or succeeds, or the helper landing gate holds it.
Your Definition of done names the wait bound, what a red check means, and when you may report the landed `done:`; this file bounds push races and says how to wait.

## Push races

Lost push races are governed by this bound instead of the general rule to stop after hitting the same obstacle twice: after 5 refused pushes, append `blocked [at=<epoch>]: lost the push race 5 times; {what keeps landing}` and stop instead of looping.
A lost race whose rebase was clean and left an already-green patch unchanged (an equal `git patch-id --stable`) follows the landing rule in force for your task, which your Definition of done or firstmate's latest landing instruction states; unless that rule lets the rebased head land on its earlier run, it gets a new exact-head run before the next push, a `ci/<task-id>` run on a Firstmate-repository task.

## Helper acceptance wait

When `bin/fm-helper-consumers.sh check-land` exits 3, the head lands helper bytes a declared consumer has not accepted, and its records name each helper, version and consumer; [`docs/helper-consumers.md`](../../../../docs/helper-consumers.md) "The landing gate" owns the contract.
Do not push, and do not poll: park on the gate itself.
Write the park handoff with `## Waiting for` set to `cmd:<this worktree's absolute path>/bin/fm-helper-consumers.sh check-land --condition <base> <head>`, where `<base>` and `<head>` are the full commit ids of `origin/<default-branch>` and `HEAD` the gate just checked, then park with the park command your launch instructions name.
That condition exits 0 once every named consumer has accepted those bytes, 1 while one still holds, and any other status wakes firstmate as an error.
When the park resumes you, go back to the landing loop step your Definition of done names.
Never pass `--allow-helper-break` or `--allow-break` yourself: breaking a consumer is the operator's own command.

## Post-landing check wait

Decide from the push triggers in the workflow files you already inspected before landing, counting their `paths` and `paths-ignore` filters against the files your change touched, whether your push runs checks; an empty first run listing is not evidence of none, and only when no workflow triggers on that push is there nothing to wait for.
Otherwise, first append `paused [at=<epoch>]: waiting on {default-branch} checks for {sha} until <YYYY-MM-DDTHH:MMZ>`, with the UTC deadline set to now plus the wait bound, so the long wait is not mistaken for a wedge; the landed `done:` or `blocked:` you append after the wait ends that pause.
Then wait for those checks on your pushed commit in one bounded blocking wait within that bound: re-list with `gh run list -R <owner>/<repo> --commit <sha>`, naming the repository you pushed to, at most every 2 minutes until the runs for that commit appear, then watch each with `gh run watch <run-id> --exit-status --interval 120 -R <owner>/<repo>`, all within the same bound (`tool-design` section 5 says why).
Judge each workflow your push triggered on its own: one that completed on your own commit counts from that run.
For each workflow whose run on your commit was cancelled or never created because a later push to the default branch superseded it, follow within the same bound the newest `origin/<default-branch>` commit containing yours that has a completed, not cancelled, run of that same workflow, and treat that run as its check on your change.
Count a workflow green only from such a completed run of that same workflow, never from other workflows' runs or from a commit that did not run it.
