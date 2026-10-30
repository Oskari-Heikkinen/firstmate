---
name: wake-triage
description: Load before triaging a wake row as the wake-triage assistant - deciding whether a row is settled, relayed or fast-relayed to main firstmate, in a replay through bin/fm-wake-triage-replay.sh or a supervision-host triage turn - and before writing, reading or scoring a wake-triage shadow log line or a settle list.
user-invocable: false
metadata:
  internal: true
---

# wake-triage

Why this skill exists: main firstmate spent whole wake turns on rows a probe could prove needed nothing (a busy worker reported as stuck, an alarm that had already cleared, a result already seen), while the rows that need the operator must still reach main unchanged and without delay; this skill is the one statement of which is which.

The assistant is the middle man: every row reaches it first, it settles a row only when a probe proves nothing needs doing, and it relays everything else to main.
`bin/fm-wake-triage-replay.sh` replays recorded rows through this contract offline; its header and `--help` own its commands.

## Row classes

Every row has one class token; the settle list and the shadow log name rows by these tokens.

| Row | Class |
|---|---|
| signal row whose status span is decision-owned: it carries a needs-decision, blocked or captain-held line, resolves an open decision, or declares an open decision key | `decision-span` |
| any other signal row | `signal` |
| `check: <path>/<name>.check.sh: ...` or `check: <name>` | `check:<name>` |
| stale row whose reason says stuck-busy (an unread firstmate instruction behind busy-deferred doorbells) | `stale:stuck-busy-inbox` |
| any other stale row | `stale:other` |
| heartbeat | `heartbeat` |

## The settle list

- The settle list is data: one class token per line, `#` starts a comment, blank lines are ignored.
- Only a class on the list may ever be settled; every other row goes to main.
- A missing, unreadable or unparsable settle list means no class may be settled, so every row is relayed, and the failure is reported once.
- A settle list that names a class "Always to main" keeps off it is refused the same way, naming the line.

## Always to main

These rows are relayed original and unchanged, by code, with no engine turn and no model judgement (a fast relay):
- needs-decision, captain-held and blocked lines, and every `decision-span` and `signal` row;
- a stale row of a task that holds an open decision, unless its class is on the settle list: a listed liveness class is judged on its own probe, because the open decision still reaches main through its own `decision-span` rows;
- `check:mem-guard`, `check:claude-update`, `check:disk-room`, `check:landed-sync`, `check:merge` (a merge landed), and credential or auth checks: any `check:` class whose name contains `auth`, `credential` or `login`;
- every `unrecognized` row, and any row whose class is not on the settle list.

No class named in the first, third or fourth item may be on a settle list.

These never pass through the assistant at all, because the thing that may be broken must not be the only path that reports it:
- watcher-failure alarms;
- `supervision-host: ...` lines about the host's own health;
- the deadman alert;
- the operator's own chat.

## Probes

| Class | The probe passes when | Live reading |
|---|---|---|
| `stale:stuck-busy-inbox` | the target is busy, its pane has changed since the doorbell, and the oldest inbox message has been handled or taken; status output alone never passes it | `bin/fm-crew-state.sh`, `bin/fm-peek.sh`, and the inbox's `handled/` folder |
| `check:loop-alerts` | the alert's level reads clear or acknowledged on a fresh read | `bin/fm-loop.sh alerts`, and the alert's record under `state/loop-alerts/` |
| `check:rearm-resurface` | every row the wake re-announces was already presented or settled | `state/branch-outcomes.jsonl` and the wake drain |

- Settle only on a passing probe, and cite it in the answer.
- A listed row may be held and re-probed until the relay deadline; relay it at the deadline if the probe still does not pass.
- A probe that fails, cannot be read or gives an unknown answer is a relay, with the probe result as the note.
- When in doubt, relay.
- A finished result of requested work, or anything the operator should see, is a relay or a captain outcome, never a settle.
- A stuck message handled by the relay deadline has cleared on its own: settle it, whoever's words it carries, because a note that it cleared is not for the operator.
- A stuck message still not handled at the deadline is a relay; when it carries the operator's own words (an answer, ruling, question, ask or go, quoted or relayed in their words), the note says so, because the operator is waiting on it to land.
- In a replay the turn has no tools: the replay tool reads each probe from recorded state as of the row time plus a lag, which stands for the re-probe at the relay deadline, and puts the result in the message, with the stuck message's first line for a stuck-busy row; judge on what it gives, and never assume a reading it does not show.

## Relay note

- One line in the operator's outcome language: what the row is, what the probe found, and what main must decide or do.
- No paths, seqs or tool names unless main needs them to act.
- Examples: `tooling-mate is busy and writing status, but its oldest inbox message is not handled yet; check again or nudge it`, `batches source alarm is still raised a minute later; the source needs looking at`.

## Answer format

A triage turn ends with one line per row it was given:

`seq=<seq> action=<settle|relay> probe=<class-probe>:<pass|fail|unknown>|none note=<one line>`

`probe=` cites the probe the decision rests on, and `none` when no probe was read; a settle always cites a passing probe.

## Shadow log

One line per triaged row, appended, tab-separated: the row's epoch first, then `key=value` fields.
The required fields, in order:
- `seq=` the row's sequence;
- `class=` its class token;
- `action=` `fast-relay`, `relay` or `settle`;
- `probe=` the probe the answer cited, or `none`;
- `model=` `<engine>/<model>` for an engine turn, `code` for a fast relay.

Optional fields follow in any order, and a reader ignores keys it does not use:
- `route=` `code` or `engine`;
- `run=` a fingerprint of the settings that wrote the line, so lines from different settings are never mixed;
- `evidence=` `pass`, `fail`, `unknown` or `none`, the probe result as the writer read it;
- `audit=` the action a model gave for a code-routed row when asked for audit only;
- `cost=` the engine turn's cost in USD;
- `error=` why an engine turn fell back to relay;
- `note=` the relay note.

An engine turn that fails, times out or gives no valid answer line is logged as `action=relay` with `error=`, never as a settle.
Log writes run at `nice 19`.
