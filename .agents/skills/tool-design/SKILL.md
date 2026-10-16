---
name: tool-design
description: Load before designing, building, or changing any tool, script, service, watcher, or automation.
---

# tool-design

General principles for every tool.
A tool's own brief or protocol wins on any conflict; record the deviation in its docs.

## 1. Failures raise an alarm by themselves

- When a tool fails, refuses work, or cannot tell whether it is healthy, it raises an alarm that reaches firstmate through its wake path (a status line or a registered check), without anyone polling for it.
- The alarm says what failed, where the evidence is, and what has to happen next.
- Unknown or unreadable state counts as a failure, never as healthy.
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

## 6. A log anyone can read

- Keep an append-only log with one plain-language line per event: UTC time, what happened, why, and what happens next.
- Log waits, skips, and refusals, not only starts and ends, so that "nothing happened" also has a reason.
- A firstmate reading the log cold should be able to understand the tool's state without opening its code.

## 7. Safe to rerun, safe to stop

- Make tools idempotent and guarded: a rerun, crash, or restart never doubles work, loses work, or deletes something unverified.
- When a check fails, refuse and name what is missing, rather than guessing or carrying on.
- Long work runs in steps that each save a checkpoint, so it can stop for more urgent work and resume later without losing anything.

## 8. Share the machine

- Declare what the work needs (CPU, RAM, disk, I/O), and use the machine fully within its safety limits: the memory gate, `bin/fm-disk-room.sh`, and the heavy slot.
- Background work runs at `nice 19` and `ionice -c3`.
- When there is no room, wait and log why, rather than overcommitting.

## 9. Lands with its skill and protocol

- A tool lands together with the skill that tells agents when it runs, how to use it, what signals it emits, and what they no longer do by hand.
- A record or signal that crosses homes or machines follows a written, versioned protocol.
