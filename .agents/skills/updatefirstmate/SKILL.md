---
name: updatefirstmate
description: Load on /updatefirstmate or any request to update or pull the latest firstmate, before running bin/fm-update.sh or bin/fm-secondmate-restart.sh, and when fm-update prints held-for-helper, skipped, reread-firstmate, restart-secondmates or nudge-secondmates lines.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Why this skill exists: pinned helper consumers hold updates on byte changes, and the agent cannot itself run the override that breaks a pin, so held updates stalled with no clear hand-over (root cause R6, problem P13).

Self-update firstmate in place.
Firstmate is its own repo, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
The pull follows origin's `green` branch, which only ever names a `main` commit whose CI passed; on a remote without one it follows `origin/main` and says so (`bin/fm-ff-lib.sh` owns that choice).
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

Pulling the files is only half of it.
Updating files alone does not refresh a running conversation's native instruction cache or previously loaded skill text.
Deliberately supplying current text can refresh the operating instructions without reloading that cache; [`session-start re-emit mechanics`](../../../docs/sessionstart-nudge.md#re-emit-mechanics) owns the supported refresh path, with [`post-start instruction-refresh verification`](../../../docs/verification/supervision.md#post-start-instruction-refresh) recording its proven scope.
The primary's re-read below supplies current `AGENTS.md` text, not a native reload of every previously loaded skill.
Replacing the agent is still required to re-resolve launch-time wiring - turn-end hooks, harness flags, per-harness feature switches - which an instruction-text refresh does not change.

That is why **every live second mate is restarted after a successful update, including one that was already on the target commit.**
Launch-time wiring is not derivable from a file diff, so an unchanged tracked surface is not evidence the running agent is already on the current behavior.
The only live mates that do not restart are the ones whose home the update pass had to skip, and the ones whose runtime cannot prove a restart; the updater keeps both cases honest and neither is reported as a reload.

The primary update is fast-forward only, while each secondmate uses the same guarded convergence path plus one narrow recovery for squash-merged local history.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, and never stashes.
A clean secondmate divergence advances with `reset --keep` only when a three-way tree proof shows its complete local result is already present at the target, which recognizes squash-merged contributions without discarding unique content.
Every other dirty, diverged, offline, or wrong-branch target is skipped and reported, and a genuine divergence leaves a durable `state/.secondmate-update-reconcile/<id>.pending` record that future bootstrap and update passes surface until convergence clears it.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch to origin's `green` pointer, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `reconciled redundant divergence <old>..<new>` / `already current` / `skipped: <reason>`), followed by three action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `restart-secondmates: fm-<id>...|none`
   - `nudge-secondmates: fm-<id>...|none`

   The two second-mate sets are disjoint and the script owns the split; do not re-derive it.
   `restart-secondmates:` carries every live mate the pass left on the latest commit, whether it advanced or was already there.
   A mate reaches neither set only because its home was skipped, because it has no live endpoint recorded here, or because its endpoint was positively classified as dead or missing.
   A skipped genuine divergence still requires attention through its durable reconciliation record; the other two cases need no update action from you.
   When it also printed `held-for-helper: <helper>@<version> awaiting <consumer>...`, nothing moved because a home that runs that helper under a pin has not accepted the new version yet, or its declaration is malformed (`awaiting malformed declaration <name>`) and must be fixed first ([`docs/helper-consumers.md`](../../../docs/helper-consumers.md)).
   Every landing is gated on acceptance, so apart from a malformed declaration a held pass means a version reached the default branch around the landing gate (a bypass), past an operator's landing break, before its consumer declared itself, or before the gate existed: it is a fault to chase, never a wait to offer.
   Relay it to the captain naming the consumer's declared owner and whether it was a bypass or a break, chase that owner's acceptance round for this version (ask the owner when you know of none), and rerun the update when the `helper-accepted <helper>@<sha12>: rerun the update` note arrives in `state/helper-unaccepted.status`; only the armed check sends it, so if the main home has not run `bin/fm-helper-consumers.sh alarm --arm`, arm it now.
   The note is per helper version, so a rerun can hold again on another helper; chase that one the same way.
   Rerun with `--allow-helper-break <consumer>` only on the captain's explicit word to update anyway; that consumer's work then waits until it accepts.
   The line ends with when the hold limit lets a pass proceed (`proceeds past the hold limit from <utc>`), or why no limit applies (`no hold limit: <reason>`); say which in the relay.
   A rerun after that time deploys the version without the captain's word and prints `helper-consumers: ... deployed unaccepted by <consumer>`; the helper-unaccepted alarm raises it to that consumer's owner, so relay that line to the owner's home, and if the update also printed that the alarm is not armed, arm it ([`docs/helper-consumers.md`](../../../docs/helper-consumers.md#the-hold-limit) owns the limit).
   A `no hold limit` reason naming a file or log is a failed reading to fix, not a wait.
   In Claude's auto mode the permission classifier refuses an agent-run `--allow-helper-break`, so once the operator chooses to update anyway, hand over the exact line to run, `! bin/fm-update.sh --allow-helper-break <consumer>`, and continue from its output instead of retrying the command yourself.
   A held pass records itself in the hold log and the pass that advances clears it, so never keep your own tally of holds; because landings are gated, the record is a `bypass`, which raises the unaccepted-version alarm at once, unless an operator's landing break covers the version: `bin/fm-helper-consumers.sh holds --windows` says how long each hold has lasted, and a `hold-log: not written:` line means that record is missing and must be reported.
   A version left unaccepted past the limit raises the `helper-unaccepted` alarm to main and to the consumer's owner by itself, once the main home has run `bin/fm-helper-consumers.sh alarm --arm`; chase that owner's review when it fires, and rerun the update on its `helper-accepted` note rather than before ([`docs/helper-consumers.md`](../../../docs/helper-consumers.md) owns the limit and routing).

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) and apply that current text in place of the earlier Firstmate instruction copy before further work.
   This supplies current instructions; it does not reset the native cache, refresh all previously loaded skills, or change launch-time settings.
   When it printed `reread-firstmate: no`, the tracked instruction surface did not advance in this pass - skip the re-read.

3. **Restart every second mate the updater named.**
   Pass the whole `restart-secondmates:` list to one command (skip this step entirely when it says `none`):
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-secondmate-restart.sh <fm-id>...
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is automatic and needs no per-mate confirmation from the captain.
   Local and remote mates go in the same list; the command owns the transport, the profile each replacement runs on, and the wait.

   It asks every listed mate first to write down the open work it holds only in its conversation, and restarts one only after that mate's own answer comes back.
   A mate that is mid-turn queues the request behind that turn.
   That is the whole point of the step, so do not work around it: it is what keeps a captain call the mate had formed but never registered from being lost with the conversation.
   Its header owns the request, the bound, and the two knobs that change them.

   Read its per-mate lines and its closing `summary:` line as the outcome:
   - `restarted: <id>` - that mate is now genuinely running the current instructions and launch-time settings.
   - `nudged: <id>: <reason>` - the restart was not safe, so the mate got a re-read message instead and keeps its existing conversation and launch-time settings.
     Supplying current instruction text is not proof of a native cache or settings reload; never report one of these as a clean reload.
   - `unreached: <id>: <reason>` - no safe running outcome could be confirmed, including an ambiguous relaunch result.

4. **Send the re-read message to the rest.**
   For every target on the `nudge-secondmates:` line (do nothing when it says `none`), send the one-line re-read steer:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   These are the mates that are on the latest bytes but could not be restarted provably, so the steer is the most this pass can honestly do for them.
   It is a gentle steer, not an interruption: the mate already got a safe tracked-files fast-forward, and the steer never forces, tears down, or discards its work.
   Never describe one of these as reloaded; its agent is still running the wiring it launched with.

5. **Report to the captain in plain outcomes, in one line where you can.**
   Summarize what landed in `AGENTS.md` section 9's outcome form and the chat style in `data/captain-shared.md`, without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Firstmate and both second mates are now on the latest."
   Say plainly when a mate got the message rather than a clean reload, and why - never let a partial reload read as a full one.
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Guarded convergence only.**
  A dirty, offline, non-default, or uniquely diverged target is skipped and reported, never forced or stashed.
  Only a clean secondmate divergence whose complete local result is already present upstream may move without ancestry, and `reset --keep` still refuses conflicting working-tree changes.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Nothing with work in it is disrupted.**
  A local or remote second mate gets a tracked-files fast-forward only when its own checkout is safe to advance, and a mate whose home was skipped is not restarted either.
  A restart replaces that mate's agent in the same home and endpoint after its open work is written down; it is never a teardown and never forced.
  Its crewmates keep running in their own endpoints, and every durable record - backlog, held captain calls, unread status, unhandled instructions - is re-presented to the replacement at startup.
  A restart refused before it is attempted leaves that mate on the re-read path; once a relaunch is attempted, any failed or ambiguous result is reported as unknown rather than attributed to either incarnation.
