---
name: secondmate-coordination
description: Load before routing work or a request to a secondmate, relaying an approval, fact or result between homes or to a worker, and on any corr-marked [fm-from-firstmate] message or REPOST REQUIRED - answering it, deferring it, or moving its inbox .msg to handled/. Also load before retrying an fm-send that failed or printed a WARNING, sending work to a parked worker, and appending a parent-channel status line. Holds what counts as a reply, the one-line rule, and the send-once and pickup mechanics.
user-invocable: false
metadata:
  internal: true
---

# secondmate-coordination

Why this skill exists: it prevents unanswered marked requests (R12, P10), resent steers (R13), mail stranded in a parked inbox (R17), truncated multi-line status replies (R22), and relays made from memory (P11).
Each of those recurred because the rule lived in a memory note that was not loaded when the mistake was made.

The same contract has two ends: the main firstmate routes and sends marked requests, and a secondmate answers them on its parent channel.
Both ends use the same helpers, so this one skill covers both.
[`docs/secondmate-parent-channel.md`](../../../docs/secondmate-parent-channel.md) owns which outcomes scripts publish and which lines wake the parent.
Creating, seeding or retiring a secondmate home belongs to `secondmate-provisioning`, and arming a watch belongs to `process-event-sources`.

## Routing work to a secondmate

Route by the registered scope of each home, not by which project a file sits in.
Relay the request in the operator's own words, plus only the context the mate cannot see: which run, which report, a described screenshot, an earlier answer.
Let the owning mate draft the plan.
Designing the split, the scope, the test list or the options yourself replaces the mate's judgement with yours, and the operator has rejected that more than once.
`AGENTS.md` section 7 owns the routing rule itself.

## What counts as a reply to a marked request

A marked request carries `[fm-from-firstmate]` and a `corr=<id>` token, and the parent records a pending reply for it before delivery.
[`bin/fm-pending-reply-lib.sh`](../../../bin/fm-pending-reply-lib.sh) settles that record only from a line on the asked task's own parent status channel that carries the exact token; chat, transport success and a moved `.msg` never count.
When the request turn ends with no such line, the parent sends one `REPOST REQUIRED` recovery about two minutes later (its header names the grace setting), then escalates once.

So every marked request gets one correlated line, and the secondmate charter that `bin/fm-brief.sh` generates states the rule.
What that line is depends on where the work stands when the turn ends:

| Situation at turn end | The correlated line |
|---|---|
| The work is done | The answer itself, or a one-line pointer to a doc under `data/` |
| A heads-up that asks for a reply only if affected | `note` with `not affected: <why>` or `noted` |
| You dispatched a worker, armed a watch, relayed an approval, or deferred a landing | One `working:` line naming what you wait on and where the answer will come from |
| The request needs only uptake confirmation (`expect=ack`) | `bin/fm-secondmate-report.sh --receipt <corr_id>` |

A dispatch or a watch is not an answer, because the guard cannot see either.
A correlated `working:` line settles the guard, so nothing reminds you of the answer you still owe: put the token in the wait's own record (the worker's brief, the watch's action, a keyed status line) so the final answer can carry the same `corr=<id>`.
Never append `working:` only to say a request has started; the one turn-end line above is the exception.

Append the line before, or in the same command as, moving the request's `.msg` into `handled/`.
Every recurrence so far moved the message first and meant to reply later.
[`references/reply-cases.md`](references/reply-cases.md) walks through the recurring cases and the recovery from a `REPOST REQUIRED`.

## Status lines are one line

The parent reads each appended line as one event, and only the first line of a multi-line append reaches it.
Keep every status line, correlated or not, to a single line.
Put a long answer in a file under the home's `data/` and point to it by absolute path, or use the report helper's `--doc` form.
[`bin/fm-secondmate-report.sh`](../../../bin/fm-secondmate-report.sh) appends the note it is given as is, so hand it a one-line note.

A status line is a wake event, not current state.
Only a `resolved` line carrying an open decision's or blocker's exact key closes it, and a relaunch closes nothing.

## Relay only what you just read

Before relaying a fact, a result, a head, a URL or an approval, re-read its source: the status line, the report, the CI run or the PR record.
Copy the head and the URL from that record rather than from memory or an earlier summary.
A relay from memory is how a stale head or an approval for the wrong car reaches a worker.
If the source no longer says what you were going to relay, relay what it says now.

## Sending with fm-send

Send once, and act on [`bin/fm-send.sh`](../../../bin/fm-send.sh)'s own exit status.
A clean send can print `WARNING` lines or nothing at all, so a loop whose test is `grep -v WARNING` treats success as failure and resends forever.
The only failure worth an automatic retry is the one that says the task metadata could not be locked; test fm-send's status directly (`${PIPESTATUS[0]}` when its output is piped), never a filter's.
If duplicates went out, they differ only in their `at=` stamp: remove the extra unhandled copies from that inbox before the worker reads them, and say so.

## Mail for a parked worker

A worker parked on an `inbox:<task>` condition wakes only after the supervisor runs `bin/fm-park.sh pickup <task>`; ordinary mail never grants pickup.
fm-send says so when it records mail for a suspended task: "text is not pickup authority".
After sending actionable work to such a worker, run the pickup in the same turn.
For urgent work, [`bin/fm-park.sh`](../../../bin/fm-park.sh)'s header owns `resume` and what to do with the captured result afterwards.
Mail that is purely for information needs no pickup, and old messages in a busy worker's inbox are not a reason to wake it.
Shared keyed answers use fm-send's fan-out form, which runs the pickup itself.

## Before a restart or session end

A restart loses whatever was only in the conversation.
Before one, check that every marked request taken up this session has its correlated line on the parent channel, and that every deferred answer has a recorded owner (a worker, a watch, a held task) that carries its token.
Answer or record anything that does not; a later session cannot reconstruct an obligation that exists only in this chat.
When a wake drain's output is captured to a file, capture stderr too (`2>&1`): [`bin/fm-wake-drain.sh`](../../../bin/fm-wake-drain.sh) prints its `WAKE_ACK_REQUIRED` line there, and an ack command read back from a stdout-only capture is empty, acks nothing, and leaves the wake to be presented again.
How the session start itself drains wakes belongs to `session-start-recovery`.
