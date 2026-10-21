# Alert stores

An alert store is a file a tool owns that says which of its alarms are active now.
The status-line blocker a supervisor sees is only a projection of that file: while an alarm is active and unacknowledged, its blocker is open, and nothing but the store changes that.
This document owns the store format, the registration format, the projection rule and the adoption steps.
[`bin/fm-alert-store.sh`](../bin/fm-alert-store.sh) runs the commands and its header owns their usage; [`bin/fm-alert-store-lib.sh`](../bin/fm-alert-store-lib.sh) owns the shared functions.

## Why

A tool that posts each alarm once loses it the moment anything closes the line.
A relaunch or resume note (`note [supersedes=...]`, written by `fm_status_supersede_blockers` in [`bin/fm-wake-lib.sh`](../bin/fm-wake-lib.sh)) closes every open `blocked` record, so a tool alarm raised in a session's status file could be muted minutes after it was raised, and the tool would never post it again.
An alert store turns the alarm into a level: the store says "active", and every tick puts the blocker back until the store says otherwise.

## Store format: `fm-alert-store/v1`

A store is one JSON object:

```json
{
  "schema": "fm-alert-store/v1",
  "store": "tj-capacity",
  "at": "2026-10-20T08:14:00Z",
  "revision": 3,
  "active": {
    "tj-capacity-unread": {
      "key": "tj-capacity-unread",
      "kind": "tj-capacity-unread",
      "subject": "tetjet",
      "reason": "fresh filler status cannot be read",
      "since": "2026-10-20T08:02:00Z",
      "detected_at": "2026-10-20T08:14:00Z",
      "evidence": {}
    }
  },
  "acks": {
    "tj-idle": {"by": "firstmate", "reason": "maintenance window", "at": "2026-10-20T07:00:00Z", "until": "2026-10-20T09:00:00Z"}
  },
  "events": [
    {"seq": 3, "at": "2026-10-20T08:02:00Z", "action": "raised", "key": "tj-capacity-unread", "alert": {}}
  ]
}
```

- `schema` is `fm-alert-store/v1`.
- `store` is the store id, a slug of `[A-Za-z0-9._-]` starting with a letter or digit; it equals the registration's file name.
- `at` is when the store was last written, UTC ISO 8601 with a `Z`.
- `revision` is a whole number that never decreases; every raise, clear and acknowledgement adds one.
- `active` maps each active alert key to its entry.
  A key is a decision-key slug, the same alphabet as `[key=...]` in a status line, because it becomes one.
  `reason` is the one-line text the blocker carries; the other entry fields are the tool's own.
- `acks` maps an active key to an acknowledgement with a required expiry `until` (UTC ISO 8601 with a `Z`, at most 7 days after `at`).
  An acknowledgement hides the key from the projection until `until`, then the key is projected again if it is still active.
  Readers enforce the limit too, so a tool writing its own store cannot exceed it: an acknowledgement whose `at` or `until` does not parse, whose `at` is in the future, or whose `until` is more than 604800 seconds after `at` hides nothing, and the tick reports it as a problem.
  Clearing a key drops its acknowledgement; an expired acknowledgement is dropped on the next write.
- `events` is the append-only history, oldest first, kept to the last 500 entries.
  `action` is `raised`, `cleared` or `acked`.
- Readers ignore fields they do not know.

The format generalises `tj-capacity-alerts/v1`, the store TETJET's capacity watch already writes (`active`, `events`, `revision`).
A `tj-capacity-alerts/v1` store is read as an `fm-alert-store/v1` store with no acknowledgements, so it can be registered unchanged; it cannot be acknowledged until its tool writes `fm-alert-store/v1`.

### Writing a store

Each store has exactly one writer, its owning tool.
The tool either calls `bin/fm-alert-store.sh assert|clear|sync|ack`, which take `<store>.lock` and replace the file through a temporary file and a rename, or writes its own file the same way: a complete JSON object written to a temporary file in the same directory, then renamed over the store.
A partly written store must never be visible, because an unreadable store holds every blocker it might own open and wakes on every tick.

Raise is level-triggered: `assert` on an active key changes only its `reason` and `detected_at` and writes no event, so a tool may assert its condition on every pass.
`clear` on an inactive key does nothing.
`sync` is the whole-set form for a tool that computes every alarm it owns on each pass: it takes a JSON object mapping each wanted key to its `kind`, `subject`, `reason`, `since` and `evidence`, raises the new keys, refreshes the active ones as `assert` does, and clears every active key the object lacks, with its acknowledgement, in one locked write.

## Registration: `fm-alert-registration/v1`

A store reaches a status file through a registration in the home that owns that status file:

```
<home>/state/alert-stores/<store-id>.reg
```

It is a `key=value` text file:

```
schema=fm-alert-registration/v1
store=tj-capacity
path=/home/me/tool-home/data/capacity/alerts.json
status=tetjet-mate.status
owner=tetjet-mate
```

- `store` equals the file name without `.reg`.
- `path` is the absolute path of the store.
- `status` is the status file's name in the same `state/` directory, ending in `.status`.
- `owner` names who writes the store, for the log and for whoever reads a problem line.

Registration is data alone: a tool in another home writes this file itself with a temporary file and a rename, and needs nothing else from this home.
`bin/fm-alert-store.sh register` and `unregister` are a convenience that do the same thing.
Ownership comes from the registration, not from how a key is spelled: any key a registered store holds is protected, whatever its prefix.

## The projection rule

For each registration, the wanted set is every key in `active` without an unexpired acknowledgement.

- A wanted key must be open as `blocked [key=<key>]` in the bound status file.
- A supersede note never closes a blocker whose key a registered store for that status file holds in `active`, acknowledged or not (`_fm_decision_key_protected` in [`bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh)), and the relaunch and resume writers leave it out of the keys they name.
  This is checked when the note is folded, and the incremental fold keeps that verdict; a store that raises a key after the note was folded is covered by the tick, and one that clears or acknowledges a key is closed by the tick.
  A store that was unreadable when a note was folded leaves every blocker of its status file open in the incremental fold even after it reads again; that errs toward a visible blocker, and a plain `resolved [key=<key>]` line closes each leftover.
- When a registered store cannot be read (missing, not JSON, unknown schema, a key that is not a slug, or no `jq`), every key is treated as held, so a relaunch can never mute an alarm the store might hold.
  An invalid registration holds every key of its status file the same way, and of every status file in that `state/` when it does not name one.
- A key the store has never named (not active, not acknowledged, not in an event) is left alone: it opens and closes exactly as it did before stores existed.
- Reserved key prefixes (`pending-reply-`, `handoff-pickup-`, `handoff-tj-`) keep their own protection and vocabulary rule.

A store-held blocker still counts among the task's own open decisions (`status_own_open_decisions`), so pending-reply recovery and the retry ring keep leaving the task alone while it is open, as for any other blocker.

## The tick

The watcher ([`bin/fm-watch.sh`](../bin/fm-watch.sh)) runs `bin/fm-alert-store.sh tick` first in its existing slow-check step, every `FM_CHECK_INTERVAL` (default 300 seconds), bounded by `FM_CHECK_TIMEOUT`, whenever `state/alert-stores/` exists.
No arming step exists, so a registration can never sit unread behind a check nobody installed.
For each registration the tick:

1. Reads the registration, the store and the bound status file.
2. Folds the status file with the incremental decision fold, which reads only the bytes appended since its cursor.
3. Appends `blocked [key=<key>] [at=<epoch>]: <key>: <reason> (alert store <id>)` for every wanted key the fold does not hold open as `blocked`.
4. Appends `resolved [key=<key>] [at=<epoch>]: <key>: cleared in alert store <id>`, or `...: <key>: acknowledged by <by> until <until> in alert store <id>`, for every open blocker the store has named but no longer wants.

The note begins with the key and a colon, so a key under a reserved prefix passes that prefix's vocabulary rule.
An appended line is ordinary new status, so the watcher's signal scan wakes on it the same way it would on the tool's own line.
An alarm muted between ticks is therefore back within one tick.

The tick never scans directories beyond `state/alert-stores/*.reg`, reads each store once with `jq`, and holds a lock so two ticks never run together.
A tick that cannot take that lock within 10 seconds checks nothing and prints a problem line saying so.
A tick the watcher's check timeout kills, or one that stops early, is a problem too: the watcher's tick ends with a completion line, and a tick without it is reported as not finished.

### Problems and the log

Each problem (an invalid registration, an unreadable store, an ignored acknowledgement, a missing status file, a failed append) is one stdout line on every tick until it is gone.
The watcher queues those lines as one `check: alert-stores: <problem>; <problem>` wake and wakes on it after the other slow checks, so a broken store cannot starve them.

`state/alert-stores.log` is append-only plain language, one UTC-stamped line per event: a registration, a re-posted or closed alarm, and a problem when the set of problems changes.
A quiet tick writes nothing.

## Adopting a store

A tool that raises alarms in a firstmate status file adopts a store in three steps:

1. Keep the alarm state in a store: either the `tj-capacity-alerts/v1` file it already writes, or `fm-alert-store/v1` through `bin/fm-alert-store.sh assert` and `clear` (or the same shape written atomically by the tool).
   Assert the condition on every pass and clear it only when the condition is gone.
2. Write the registration into the home whose status file it posts to: `state/alert-stores/<store-id>.reg`, naming the store's absolute path and that status file.
3. Stop relying on one-shot posts: the tick re-posts the blocker while the store holds it, and closes it when the store clears or acknowledges it.
   The tool may still post its own first line for a faster wake.

To stop, run `bin/fm-alert-store.sh unregister <store-id>`: it removes the registration and appends a `resolved` line for every open blocker the store has named, so none outlives it.
A tool that removes its `.reg` file itself must close its blockers the same way.
The [alert-store skill](../.agents/skills/alert-store/SKILL.md) says what to do on a `check: alert-stores` wake and how to acknowledge an alarm.
