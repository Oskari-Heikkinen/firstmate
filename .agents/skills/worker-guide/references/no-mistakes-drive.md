# Driving no-mistakes

Read this before you start no-mistakes for a Firstmate-dispatched ship.
Your Definition of done keeps the rules that stay inline: the ask-user escalation, the `--yes` ban, and the ready report.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.

## What `--intent` may carry

When starting no-mistakes, pass `--intent` as only your brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
A `# Current no-mistakes intent contract` section in your launch instructions names the exact words authorized for `--intent` and supersedes the brief's other wording about it.

## Driving the run

Your Definition of done names this home's drive shape: foreground or backgrounded.
Declare the wait using the brief's status-reporting rule before the drive call you wait on.

Foreground: drive the run with ONE foreground `no-mistakes axi run` and let it block.
It bounds its own hold for you: `--wait` (default 8m) exists precisely so a harness with a ten-minute command cap gets a structured return instead of being killed mid-hold.
Never background a wait, and never arm a timer to stand in for one: a backgrounded call returns in milliseconds, so it does not wait at all, and every timer left behind fires later as a paid wake for nothing.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - that is not a failure: reattach at once by re-running `no-mistakes axi run` without flags, and issue the same foreground call again, one at a time, until a gate or outcome comes back.

Backgrounded: one drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way.

In either shape, if a reattach refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
Where the pipeline's ci step runs (every forge except a Gerrit task that skips it), only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome; once checks are green a reattach returns `checks-passed` immediately.

## When a pipeline block is real

A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error; reattach and keep going rather than reporting the pipeline blocked.
Before you append `blocked:` about the pipeline, run `no-mistakes daemon status` and `no-mistakes axi status`.
If the daemon socket refuses connections or is missing, append `blocked [at=<epoch>]: {the daemon error}` and stop even when the local run record still says running or fixing, because that record can be stale after the daemon exits.
A run record failed with a daemon error is also a real block.
Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep going.
Never stop, restart, or update the daemon yourself; your brief's shared-infrastructure rule says why.
