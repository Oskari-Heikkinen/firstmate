---
name: captain-hold-lifecycle
description: Load before treating an investigation, scout report, or review as complete, before holding or deferring a decision (including a "later" or "not now" answer), when recording or routing the operator's answer, before recording time-boxed authority, a temporary rule or an open condition ("until X is live", "for this week"), and on any RECORD DIVERGENCE line.
user-invocable: false
metadata:
  internal: true
---

# Captain-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the captain.
The one primitive is an ordinary backlog task held for the captain through `bin/fm-captain-hold.sh hold`; its identity is the task id, and that wrapper owns the deterministic mechanics this policy relies on.
The agent performs the semantic inventory because scripts must not infer captain calls from report prose, visual-review artifacts, terminal output, or chat.

Why this skill exists: open decisions and time-boxed authority were written as prose with no owner or end condition, so they outlived their reason, or work waited on a go that was already given (root causes R8 and R7, problems P17 and P18).

## Policy

Every unresolved question that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a captain-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
The originating investigation or review is never its own inventory entry, so hold a separate task for the call and pass `--origin <origin-id>` so `complete` can check it.
Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
After inventorying the whole report and review surface, run `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` only when the reviewed surface leaves nothing waiting on the captain.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; secondmate-owned work registers in that secondmate home's backlog, and a question already held anywhere is never re-registered as a second row.
Do not close a captain-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
Holding the work item the question gates is safe for exactly that reason: cleanup keeps such a row open with the finished work's deliverable recorded and returns it to the queue, so it still reads as the captain's own call.
Only `answer` with the captain's words or an evidence-backed `reconcile close` may resolve it.

Never close anything the captain owns without recording what he actually said: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes a question-shaped call, while `--release` frees a captain-gated work item to proceed.
A merge approval uses that existing release path because approval permits the merge to proceed; cleanup closes the work only after it lands and records what shipped.
Closing a held row at merge approval instead records completion before landing, so the backlog claims completion before the work actually ships.
When the answer changes what a task must build, follow `AGENTS.md` section 7's mid-task ask rule to preserve the captain's words in the brief and steer the worker.
Except for compaction (reclaim-now) asks, whose answer handling belongs to the [`disk-room` skill](../disk-room/SKILL.md#what-a-low-reading-means-and-who-acts), when the captain says "later", that is an answer too: re-hold with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` so the item leaves the live Captain's Call and resurfaces on its date, instead of leaving a live-looking call or fabricating a closure.
"A keyed answer resolves its matching captain-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a captain answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or resolves anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no captain-held task both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the direct command above.
One answer value is reserved and closes nothing: `reconcile` means "go re-check reality", never "the captain answered", so the shared intake refuses it from every channel and creates nothing.
A bound captured source uses a separate seam: its adapter omits reconcile from keyed answers and emits the selected task id through `reconciles`, the generic runner feeds that into `reconcile-requests`, and the intake verifies the source binding and the local captain-held task before filing the durable re-check request.
That source-created request is yours to work off in the turn that receives it: `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` records the EVIDENCE and closes a moot call, while `reconcile note <id> --note-file <path>` annotates a genuinely active call and leaves it held.
Both outcomes refuse unless that task still has the pending request created by the captain's selection, so neither is a standalone way to mutate a captain call.
A normal captain answer also retires any pending request because the call is settled, including close, release, and idempotent replay paths.
A retirement failure makes the command fail without reversing the already-durable answer, close, or note, and `reconcile list` keeps the surviving request visible for retry.
`reconcile list` names every request still outstanding.
Never use `answer` for an evidence-only moot call: `answer` records what the captain said, while `reconcile close` records verified evidence.
A captain-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the captain actually gave.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A call may carry a decision packet, attached with `bin/fm-captain-hold.sh packet <id> --packet-file <path>`: the question, options, recommendation, authority, evidence and run ids, prerequisite work with its owner, and, only under a default authority, a deadline and default.
Name the authority the call actually falls under; only a call within research's standing authority (`research-standing`) or a quoted standing budget (`budget.<id>`, whose default and deadline must be the budget's own) carries a default, and the command refuses a deadline or default on any other packet, which keeps waiting for an explicit answer.
Open an over-budget call with `bin/fm-budget.sh open-gate`, never by hand; while the budget is in shadow mode it only logs what it would open (docs/budgets.md).
Run `bin/fm-captain-hold.sh apply-defaults` on each supervision heartbeat; nothing applies a default otherwise.
An applied default is recorded as `defaulted`, never as an answer and never in anyone's words, and stays reversible: when the captain's words change it, record them with `reverse`, which logs a new outcome rather than editing the default.
Every outcome - answered, deferred, reconciled, defaulted, reversed - is appended once to the decision log that `log` prints, and `packets` lists open calls' packets with their age.

A captain call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the captain - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a captain call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the captain ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the captain's to answer.
Reconcile it with what actually happened - `answer` when the captain's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the captain's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## Time-boxed authority and open conditions

Authority or a rule given for a bounded time or until a condition ("until the new train is live", "while the quota is short", "for this week") is an open condition, and an open condition needs an owner that checks it.
Record it as a captain-held backlog task whose reason names the condition and what changes when it ends, with `--until <date>` when the bound is a date, and point to that task from wherever the authority itself is recorded.
Never record it as prose alone in a preference or learnings file: prose has no clock, so it keeps granting or blocking after its condition has passed.
When the condition ends, close the task through this owner with the evidence or the operator's words, and retire the authority in the same step; the `stow` skill owns archiving the superseded entry's exact words.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain, and find the task each one gates.
3. Hold that task - or create one captain-held task for the review's open questions - with a concise reason carrying the question and options.
4. Run `complete` with the full captain-held inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section, in `AGENTS.md` section 9's escalation form and the chat style in `data/captain-shared.md`; do not use the word hold in captain chat.
6. Close each call only through `answer` (or a channel that feeds `answers`), close a source-requested moot call through evidence-backed `reconcile close`, record a still-active reconciliation through `reconcile note`, use `--until` for deferrals covered by the policy above, or confirm a channel already closed it.
7. On each heartbeat run `apply-defaults`, and record words that change an applied default with `reverse`.
8. Confirm Bearings reflects the outcome: answered or reconciled-moot calls leave Captain's Call, released work resumes, active reconciliations remain held, and deferred calls sit in Charted Next with their date.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, completion attestation, retry behavior, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
