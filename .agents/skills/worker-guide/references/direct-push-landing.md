# Direct-push post-landing check wait

Read this after your direct-push landing push succeeds.
Your Definition of done names the wait bound, what a red check means, and when you may report the landed `done:`; this file says how to wait.

Decide from the push triggers in the workflow files you already inspected before landing, counting their `paths` and `paths-ignore` filters against the files your change touched, whether your push runs checks; an empty first run listing is not evidence of none, and only when no workflow triggers on that push is there nothing to wait for.
Otherwise, first append `paused [at=<epoch>]: waiting on {default-branch} checks for {sha} until <YYYY-MM-DDTHH:MMZ>`, with the UTC deadline set to now plus the wait bound, so the long wait is not mistaken for a wedge; the landed `done:` or `blocked:` you append after the wait ends that pause.
Then wait for those checks on your pushed commit in one bounded blocking wait within that bound: re-list with `gh run list --commit <sha>` until the runs for that commit appear, then watch each with `gh run watch <run-id> --exit-status`, all within the same bound.
Judge each workflow your push triggered on its own: one that completed on your own commit counts from that run.
For each workflow whose run on your commit was cancelled or never created because a later push to the default branch superseded it, follow within the same bound the newest `origin/<default-branch>` commit containing yours that has a completed, not cancelled, run of that same workflow, and treat that run as its check on your change.
Count a workflow green only from such a completed run of that same workflow, never from other workflows' runs or from a commit that did not run it.
