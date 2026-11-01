# Waits and parking

Your brief's status rule says when to declare a `paused:` wait; this file says how to tag that declaration and when to wait live or park.

## Tagging a declared wait

Firstmate may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
When you know when the wait clears, include `until <YYYY-MM-DDTHH:MMZ>` (UTC) for a recheck at that time.
When a machine can check the wait, add one `[wait=<kind>:<arg>]` tag before the colon (`heavy:<job-id>`, `until:<YYYY-MM-DDTHH:MMZ>`, `merge-result:<head-sha>`, `receipt:<absolute-path>` or `file:<absolute-path>`, `inbox:<task-id>`, or `process:<pid>:<start>:<UTC>`): firstmate's monitoring then stays silent while it holds and wakes when it stops holding, and the tag outranks any prose ETA.
`fm-worker-status.sh` warns when it records a pause with no tag or a tag nothing can check; an uncheckable tag wakes firstmate as lapsed, so fix the tag rather than ignoring the warning.

## Declaring a long command

Declare a long foreground command (a mutation run, a long build, a large fetch) with the process kind, so firstmate treats its quiet pane as waiting only while that command runs.
Start the command in the background of the same shell call, print its tag with `fm-worker-status.sh --process-tag <pid> <UTC|+seconds>`, append the `paused` line with that tag, and then `wait` for the command in that call.
The time is your upper bound for the command; past it, or once the command ends, the wait stops holding and firstmate's wedge alarm applies as usual.
For example: `cmd & pid=$!; tag=$(fm-worker-status.sh --process-tag "$pid" +3600); fm-worker-status.sh <status> <config> "paused $tag [at=<epoch>]: mutation run"; wait "$pid"`, with the status command your brief names.

## Live wait or park

Decide by when you expect the wait on an external result (a run, a merge, a review, another team) to clear.
A wait you expect to clear in less than your home's live-wait threshold (60 minutes unless `fm-park.sh --help`, "Live waits", says how it was changed) is waited live, because a resumed session re-reads its whole context and costs more than a live wait that short.
For your own inbox, append `paused [wait=inbox:<your-task-id>] [at=<epoch>]: <what you wait for>` and end your turn.
For an adopted merge-queue handoff, follow the merge-queue skill: its adapter declares and settles the live wait, with no competing waiter.
For any other condition, run `fm-park.sh await <your-task-id> <condition>`, with your brief's `FM_HOME` prefix, as a command whose exit wakes you (in the background on Claude, in the foreground elsewhere): it declares the wait for you and exits 0 when the condition holds or 3 when the threshold passes, and then you park.
Park a wait you expect to take at least the threshold, a current continuous live wait that just reached the threshold, or when firstmate or the memory guard asks you to park (add `--requested`), which bypasses estimate policy but not the custody and handoff safety checks in `fm-park.sh --help`.
Park refuses, installing nothing, when you park yourself without `--expect <UTC|+seconds>` or expect the condition in less than the threshold, and its message says how to wait live instead.

## Parking

Write a handoff file outside tracked content with sections `## Goal`, `## Done`, `## Waiting for` (one condition), and `## Next steps`.
Prefer a built-in condition over a script of your own, because each has a tested checker: `merge-result:<head40>` (the merge queue's result for a handed-over head), `heavy:<job-id>` (a heavy-slot job ending), `gh-run:<owner/repo>:<run-id>` (a GitHub Actions run completing), `pr-merged:<github-pr-url>`, and `file:<absolute-path>` or its alias `receipt:<absolute-path>`.
Use `cmd:<absolute-executable-or-PATH-name> [args]` only when none fits: its arguments split on whitespace, and it must exit 0 when done, 1 while waiting, and anything else only for a real error.
Then run the exact `fm-park.sh` command your brief names, with `--handoff <file>`, optional `--when <condition>` to select/check the same condition the handoff must name, and `--expect` with when you expect it to hold.
For a rate-limited `cmd:` check, use park's runner-owned cadence option described in [`bin/fm-park.sh`](../../../../bin/fm-park.sh)'s header instead of hand-writing timestamps or returning false between queries.
That header owns the precheck and error behaviour; fix a broken condition rather than retrying.
It stops this session and starts a fresh one with your handoff when the condition holds; a wait that passes its deadline (hours for the cross-home kinds) wakes your supervisor instead. Its `--help` has the details.
Read that help before asserting optional relocation safety for copy-free suspension; never return or allocate your copy by hand.
