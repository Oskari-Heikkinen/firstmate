Mode: Pi extension background wake.

When this session owns supervision, in either posture:
1. Initial process cycle only: make the one required `fm_watch_arm_pi` call; if startup already owned the fleet lock, this is an ownership-based no-op.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   After that the extension owns every cycle: do not call `fm_watch_arm_pi` again for ordinary work or ordinary wakes, and never run `bin/fm-watch-arm.sh` through Pi's bash tool, because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
2. A watcher notification that reports a missing, failed, or unhealthy cycle says how to repair it: drain queued wakes, then follow its text.
3. The supervision branch ([docs/pi-supervision-branch.md](../pi-supervision-branch.md)) takes eligible wakes; this conversation still receives what the branch cannot take and every watcher-failure alarm.
   A merged fleet event is already handled: MAIN must not re-drain, re-run, or acknowledge it, and whether to mention its outcome to the captain is MAIN's judgment.
4. A captain-facing branch outcome arrives as one hidden supervision processing request listing each `[seq N, recorded <age> ago] task: summary` it covers.
   That request is the one turn in which MAIN processes the outcome, starting from the task's current state because the outcome is what was true when it was recorded: give the captain a visible response where one is due, answer or escalate a decision, act on a blocker or failure, or record that no further action is needed.
   The reply covers only the still-open outcomes, as if the settled ones, such as a decision since answered or a PR since merged, had never been listed.
   Then call the `fm_branch_processed` tool with the highest sequence the request listed, exactly once; only that call closes the outcome, and an unacknowledged sequence is presented again at the next run boundary and at session start.
   The persisted transcript entry is already captain-visible, so do not re-emit it verbatim, but it never replaces a captain-facing outcome response required by `AGENTS.md` section 9.
   Regression example - keep verbatim and never condense away: `[seq 41] claude-mod: implementation complete, ready for review` requires relaying a captain-facing outcome response, not just `Captain, shipshape.`.
   A merge ask with no URL that leans on the dim anchor violates `AGENTS.md` section 9.
5. Before MAIN steers, controls lifecycle, or cleans up a task, claim its lease with `bin/fm-lease.sh claim <task>` and release it afterwards; a refused claim means the branch is acting on that task right now.
