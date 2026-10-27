---
name: tool-design
description: Load first, before reading code or exploring the repository, whenever a task asks you to design, build or change a tool, script, helper, service, watcher, timer, check or automation - including a quick throwaway poller or CI wait loop - or to add or change a parser, cursor, lock, alarm or alert, an outcome or result value, or a setting or margin the operator can override. Holds the general rules every tool follows - failures and unknown state raise an alarm once per occurrence, successes are reported, no silent sinks, data-driven and lightweight with per-tick cost bounded by new input, shared helpers reused rather than rebuilt, safe to rerun and stop, the machine shared, and landing with its skill. Use it even for a one-line change to an existing helper.
user-invocable: false
metadata:
  internal: true
---

# tool-design

General principles for every tool.
A tool's own brief or protocol wins on any conflict; record the deviation in its docs.

Why this skill exists: prose rules stated only in the abstract did not stop the same fail-open read, per-tick alarm or hand-rolled helper from recurring (root causes R3 and R4), and stages failed closed with no alarm on their outcome, so a refusal or a run that never started stayed silent (R7).
[`references/evidence.md`](references/evidence.md) lists the fixes behind each added rule.

When briefing a worker to build or change a tool in any repository, name this file by absolute path in the home's checkout and tell the worker to read it before designing, because a worker outside the Firstmate repository cannot see Firstmate's skill index.

## 1. Failures raise an alarm by themselves

- When a tool fails, refuses work, or cannot tell whether it is healthy, it raises an alarm that reaches firstmate through its wake path (a status line or a registered check), without anyone polling for it.
- The alarm says what failed, where the evidence is, and what has to happen next.
- Unknown or unreadable state counts as a failure, never as healthy.
  Treat "absent" and "present but empty, unreadable, non-regular, partial or erroring" as different results: only a truly missing file may take a default, and a `grep` exit 2, a killed or timed-out reader, or a blank first line is a failed reading that refuses.
- The other direction holds too: a healthy but empty state (nothing queued, no tasks, an empty log) is not an alarm.
- Raise each alarm once per occurrence as a level in an alert store (`bin/fm-alert-store.sh`, owned by the `alert-store` skill), not as an event re-sent every tick, and close it only on a recorded clear or acknowledgement.
- Every stage has an outcome alarm, so a refusal or a run that never started is not silent; an alarm stays quiet while its subject is in a declared wait or pause.
- An operator override lives in a config file the tool reads on every run, never in a value baked into a generated check or hand-edited into one, and a present but empty, unreadable or unparsable override file is a failed reading that names the file, never a silent fall back to the default.
- A cause must never mute its own alarm: when whatever stops work also hides the alarm that would notice the stop, report the cause itself.
- A notice that fails to send is retried, and it never counts as delivered until it actually is.

## 2. Successes are reported too

- A finished job or step that someone acts on next sends a success notice the same way, so follow-up work starts without anyone checking by hand.

## 3. No silent sinks

- Every signal, record, or refusal a tool writes has a registered reader that wakes an agent; a file nobody reads is a bug.
- A tool that has been idle or refusing work for longer than its stated limit says so.

## 4. Flexible, so new work needs no new feature

- Describe what varies as data (a config entry, a job or rule description, a plug-in command), so supporting a new kind of job, file, or project is a new entry, not a code change.
- Keep the core small and generic, and keep project-specific behaviour out of it.
- Before adding a feature for one case, check whether a general option would cover the whole family of cases.

## 5. Lightweight

- Prefer a small script on top of existing Firstmate helpers over a new service, daemon, or dependency.
- Do one job well and compose with other tools, rather than growing one tool to do everything.
- A loop pays its per-tick work for every item on every tick in every home that runs it, so inside a supervision cycle, park tick or check, answer what one `stat` or file read answers in the shell rather than with a `$(...)`, pipeline or helper call per item: the `_to` out-variable readers such as `fm_meta_get_to` and `fm_file_text_to`, and `bin/fm-path-lib.sh` for `dirname` and `basename`.
- Prove each such replacement matches the command it replaces in `tests/fm-fork-free-helpers.test.sh`.
- Bound per-tick cost by the new input since the last tick, not by the size of the history, and test with aged, large fixtures, because a reader that rescans a growing log gets slower every day it runs.
- Before writing a parser, cursor, lock, outcome list, wake or atomic write, search the repository for the shared helper and reuse or extend it; keep one outcome table per vocabulary, so a new value is added in one place.
- Poll an outside service from one loop per thing waited on, at an interval its shared limits allow, and name the target on every call rather than relying on a default.
- For GitHub that means `-R <owner>/<repo>` on every `gh` call, because a copy can carry more than one GitHub remote, and polls at least 2 minutes apart, because every `gh` call made with the same account draws on one API rate limit and `gh run watch` refreshes every 3 seconds unless given `--interval`.

## 6. A log anyone can read

- Keep an append-only log with one plain-language line per event: UTC time, what happened, why, and what happens next.
- Log waits, skips, and refusals, not only starts and ends, so that "nothing happened" also has a reason.
- A firstmate reading the log cold should be able to understand the tool's state without opening its code.

## 7. Safe to rerun, safe to stop

- Make tools idempotent and guarded: a rerun, crash, or restart never doubles work, loses work, or deletes something unverified.
- When a check fails, refuse and name what is missing, rather than guessing or carrying on.
- Judge whether a peer is alive from the progress beacons it writes, not from a fixed grace window, because machine load stretches every window.
- Reuse an existing lock helper rather than hand-rolling a new mkdir or pid-file lock, take several locks only in one documented order, and record process ownership by an exec-stable identity (pid plus start time from `/proc`, never the command line, which changes across exec, or `$$`, which every subshell shares).
- Create temp files only inside a per-run directory that a sweep or teardown owns, so a killed run leaves nothing in live state; an EXIT trap does not run on SIGKILL or a deadline kill.
- Long work runs in steps that each save a checkpoint, so it can stop for more urgent work and resume later without losing anything.

## 8. Share the machine

- Declare what the work needs (CPU, RAM, disk, I/O), and use the machine fully within its safety limits: the memory gate, `bin/fm-disk-room.sh`, and the heavy slot.
- Background work runs at `nice 19` and `ionice -c3`.
- When there is no room, wait and log why, rather than overcommitting.

## 9. Lands with its skill and protocol

- A tool lands together with the skill that tells agents when it runs, how to use it, what signals it emits, and what they no longer do by hand.
- A record or signal that crosses homes or machines follows a written, versioned protocol.
