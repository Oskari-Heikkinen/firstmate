---
name: alert-store
description: Load before raising, clearing or acknowledging a tool alarm through an alert store, before adopting or registering a store for a status file, before changing bin/fm-alert-store.sh or bin/fm-alert-store-lib.sh, and on a check alert-stores wake. A tool alarm is a level held in its owner's store; the status blocker is only its projection, re-posted every watcher tick and never closed by a relaunch.
user-invocable: false
metadata:
  internal: true
  sources:
    - path: docs/alert-store.md
      sha256: 5f10cec2d90178a00c27fe460d5d436241d978daf727aa1e31dd7a2c83c56312
---

# alert-store

## Goal and operating principle

A tool alarm must stay visible until its cause is gone, whatever else happens to the status stream.
The store is the only truth: the tool asserts the condition on every pass and clears it only when the condition is gone.
The `blocked [key=<key>]` line is a projection of the store, re-posted by the watcher's tick when it is missing and closed by the tick when the store clears or acknowledges it.
A relaunch or resume note never closes a key a registered store holds, and an unreadable store or invalid registration holds everything it might own.
[docs/alert-store.md](../../../docs/alert-store.md) owns the formats, the projection rule and the adoption steps.

## How it works

- `bin/fm-alert-store.sh assert|clear|ack` write a store under its lock; `register|unregister` write or remove `state/alert-stores/<store-id>.reg`, and unregister closes the store's open blockers; `tick` re-posts and closes blockers.
- `bin/fm-watch.sh` runs the tick at the start of its slow-check step whenever `state/alert-stores/` exists; nothing is armed per home.
- `bin/fm-classify-lib.sh` asks `_fm_decision_key_protected`, which asks `fm_alert_store_holds`, before a supersede note closes a blocker.

## Adopting a store

1. Keep the alarm state in a store: the `tj-capacity-alerts/v1` file a tool already writes, or `fm-alert-store/v1` through `bin/fm-alert-store.sh assert <store> <id> <key> <reason>` and `clear <store> <id> <key> <reason>`.
2. Write `state/alert-stores/<store-id>.reg` into the home whose status file the alarm belongs in, with `schema=fm-alert-registration/v1`, `store=`, `path=` (absolute), `status=<name>.status` and `owner=`, through a temporary file and a rename.
3. Stop counting on one-shot posts; the tick restores a muted blocker within one `FM_CHECK_INTERVAL`.

## On a `check: alert-stores` wake

Each part of the wake is one problem the tick saw, and it repeats every tick until fixed.

- An invalid registration: fix or remove the `.reg` file the line names; it belongs to the owner it names.
- An unreadable store: the owner's tool must write it again; every key it might hold stays open meanwhile, which is the safe state.
  Do not delete or rewrite a store you do not own to silence it.
- An ignored acknowledgement: the store holds an ack the format does not allow, so the alarm stays posted; the owner's tool must rewrite it within the limit.
- A missing status file: the registration names a session that no longer exists; tell the owner, or remove the registration when the alarm source is retired.
- After a store outage, a blocker the store never named may stay open in the incremental fold; close each leftover with a plain `resolved [key=<key>]` line.
- `state/alert-stores.log` holds the history of re-posts, closes and problems.

## Acknowledging an alarm

An acknowledgement hides an active alarm until a stated expiry, after which the tick posts it again if it is still active.
Use `bin/fm-alert-store.sh ack <store> <id> <key> <seconds> <by> <reason>` with at most 604800 seconds, only on an `fm-alert-store/v1` store, and only when the alarm's owner or the captain asked for the quiet period.
Closing the blocker by hand does not acknowledge anything: the next tick re-posts it.

## Refuse

- Posting an alarm once and treating the status line as its state; the line is a projection and anything can close it (docs/alert-store.md "Why").
- Clearing a store key to quiet a wake while the condition still holds; acknowledge with an expiry instead (projection rule).
- An acknowledgement without an expiry, or a longer one than the format allows (store format, `acks`).
- Treating an unreadable or unknown store, or a registration that fails to parse, as empty, or skipping either without a problem line (projection rule: unknown holds).
- Protecting a key by its spelling instead of by registration, or adding store keys to the reserved prefixes (registration section).
- A second writer for one store, or a write that is not a full temporary file renamed over the store (writing a store).
- Arming the tick as a per-home custom check, or adding a scan of anything beyond `state/alert-stores/*.reg` (the tick).
- Editing `.agents/skills/tj-capacity-alerts/SKILL.md` to adopt a store; its bytes are pinned by the tool that arms it.

## Review

1. Does every alarm a change raises live in a store that is asserted while the condition holds and cleared only when it is gone?
2. Does any path close or omit a store-held blocker other than the tick's clear or acknowledgement close?
3. Does an unreadable or invalid store or registration both keep its keys protected and print a problem line on every tick?
4. Is a key the store never named still folded exactly as an ordinary decision?
5. Is the format change recorded once, in docs/alert-store.md, with readers still ignoring unknown fields?
6. Do the tests drive the public command and the decision folds, not the source bytes?
