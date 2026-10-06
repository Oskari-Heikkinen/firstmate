---
name: disk-inventory
description: >-
  Agent-only procedure for machine disk housekeeping through the read-only
  bin/fm-disk-inventory.sh scan and its KEEP / REMOVE / other-homes tables.
  Load before any disk-space, housekeeping, or leftover-copy inventory, and when
  relaying or acting on a data/housekeeping/inventory-*.md file.
user-invocable: false
metadata:
  internal: true
---

# disk-inventory

The captain's standing rule is that mechanical chores like this are done by software, not by an agent session.
`bin/fm-disk-inventory.sh` builds the inventory a scout used to assemble by hand: sizes, owners, live-process checks, clean-and-landed checks, and the KEEP / REMOVE / other-homes tables.
Its header and `--help` own every check, flag, and the output path rule; do not restate them elsewhere.

## When it runs

- On demand: run it whenever disk space, leftover copies, or housekeeping comes up, instead of measuring by hand.
- Periodically, only where this home opted in: the example user timer in `docs/configuration.md` "Disk inventory" runs it nightly.
  Nothing schedules it by default, so absence of a fresh inventory file is normal, not a failure.
- It is slow on big homes (it sizes every scanned directory at nice 19 and idle I/O), so run it as a background job and wait for its exit rather than polling.

## What it emits

- One new Markdown file, by default `data/housekeeping/inventory-<date>.md` in the selected home; it never overwrites an earlier inventory.
- The path it wrote is its only stdout line; `--stdout` prints the report instead of writing it.
- Its `Scan limits` section names checks that timed out or could not be read; incomplete safety scans leave no REMOVE proposals.

## What agents no longer do by hand

- Do not run `du` sweeps, read every home's task records, test copies for clean-and-landed state, or check live processes to build this table; run the script.
- Do not re-derive a REMOVE verdict: every REMOVE row already passed every safety check the script's header lists, and anything uncertain is in KEEP with its reason.

## Deletion stays a captain decision

The inventory deletes, moves, and changes nothing, and a REMOVE row is a proposal, not approval.
Relay the REMOVE total and the notable rows to the captain in plain words, and delete nothing until the captain approves those specific items.
Remove approved pool slots through `treehouse`, never `rm`, so the pool's own records stay consistent.
Other homes' rows go to those homes' owners; never act on another home's data.
