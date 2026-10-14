# Waits and parking

Your brief's status rule says when to declare a `paused:` wait; this file says how to tag that declaration and when to park instead.

## Tagging a declared wait

Firstmate may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
When you know when the wait clears, include `until <YYYY-MM-DDTHH:MMZ>` (UTC) for a recheck at that time.
When a machine can check the wait, add one `[wait=<kind>:<arg>]` tag before the colon (`heavy:<job-id>`, `until:<YYYY-MM-DDTHH:MMZ>`, `merge-result:<head-sha>`, or `receipt:<absolute-path>`): firstmate's monitoring then stays silent while it holds and wakes when it stops holding, and the tag outranks any prose ETA.

## Parking

When the wait is on an external result that will take a while (a run, a merge, a review, another team), park instead of idling.
Write a handoff file outside tracked content with sections `## Goal`, `## Done`, `## Waiting for` (one condition: `file:<absolute-path>`, `pr-merged:<github-pr-url>`, or `cmd:<absolute-executable-or-PATH-name> [args]`), and `## Next steps`.
Then run the exact `fm-park.sh` command your brief names, with `--handoff <file>`.
It stops this session and starts a fresh one with your handoff when the condition holds; its `--help` has the details.
Read that help before asserting optional relocation safety for copy-free suspension; never return or allocate your copy by hand.
