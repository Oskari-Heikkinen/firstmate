# Direct-push push races and post-landing check wait

Read this when a direct-push landing push is refused or succeeds.
Your Definition of done names the wait bound, what a red check means, and when you may report the landed `done:`; this file bounds push races and says how to wait.

## Push races

Lost push races are governed by this bound instead of the general rule to stop after hitting the same obstacle twice: after 5 refused pushes, append `blocked [at=<epoch>]: lost the push race 5 times; {what keeps landing}` and stop instead of looping.

## Post-landing check wait

Decide from the push triggers in the workflow files you already inspected before landing, counting their `paths` and `paths-ignore` filters against the files your change touched, whether your push runs checks; an empty first run listing is not evidence of none, and only when no workflow triggers on that push is there nothing to wait for.
Otherwise, first append `paused [at=<epoch>]: waiting on {default-branch} checks for {sha} until <YYYY-MM-DDTHH:MMZ>`, with the UTC deadline set to now plus the wait bound, so the long wait is not mistaken for a wedge; the landed `done:` or `blocked:` you append after the wait ends that pause.
Then wait for those checks on your pushed commit in one bounded blocking wait within that bound: re-list with `gh run list -R <owner>/<repo> --commit <sha>`, naming the repository you pushed to, at most every 2 minutes until the runs for that commit appear, then watch each with `gh run watch <run-id> --exit-status --interval 120 -R <owner>/<repo>`, all within the same bound (`tool-design` section 5 says why).
Judge each workflow your push triggered on its own: one that completed on your own commit counts from that run.
For each workflow whose run on your commit was cancelled or never created because a later push to the default branch superseded it, follow within the same bound the newest `origin/<default-branch>` commit containing yours that has a completed, not cancelled, run of that same workflow, and treat that run as its check on your change.
Count a workflow green only from such a completed run of that same workflow, never from other workflows' runs or from a commit that did not run it.
