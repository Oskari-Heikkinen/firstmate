---
name: results-storage
description: "Load before writing experiment results or other bulk output, choosing where result bytes go, packing or releasing a cold tree, on an exit-75 storage wait, and before changing bin/fm-storage.sh, bin/fm-pack.sh, docs/storage.md or their tests."
user-invocable: false
metadata:
  internal: true
  sources:
    - path: docs/storage.md
      sha256: 0b17e3efae60441437eccaaa0ccfbe9b971ce22a9089523f251813f9b6997a4a
    - path: bin/fm-storage.sh
      sha256: 2d131e1be58ff12ddf0e9465271a4d769443cb7afa33a2020493a3c796677f6c
    - path: bin/fm-pack.sh
      sha256: 655e88facdb5bc35584a79f2c1aa9bd3fb554c324899c6199edee41b55121d3a
---

# results-storage

Why this skill exists: bulk results written wherever each writer chose filled the laptop's C: and Linux disks (root causes R9, R1; problem class P23).

## Goal and operating principle

Result bytes leave the laptop's C: and Linux disk for good, and every byte kept on D: can be verified and found again.
One publisher, `fm-storage.sh check`, proves the SSD and atomically writes one versioned results-root file; every writer gets its directory from `root`, `verify-bulk-root` or `bulk-root`, never from a path of its own.
Doubt is a wait: any state that is not proven `ok` exits 75 with one `wait:` reason, and no command names a C: or Linux fallback.
A new large delivery reserves its whole peak in the disk-room D: pool before it writes, and an already-started delivery keeps its recorded root.
A cold tree becomes one verified read-only image whose sidecars are its whole manifest, and only `fm-pack.sh release`, with every R2 guard holding, deletes its source.
Each rule has one owner: `docs/storage.md` for formats, states, reader rules and R2, each script's header for its commands, fields and exit codes.

## Where each rule lives

- `docs/storage.md`: the results-root file `lattice-storage-results-root/v1`, the states, the reader rules, mandatory bulk admission, named roots, when to pack, and retention rule R2.
- `bin/fm-storage.sh` header: commands, files, environment.
- `bin/fm-spawn.sh` header: when a worker launch carries `LATTICE_STORAGE_TOOL`, the absolute path workers resolve `fm-storage.sh` from, since it is not on their `PATH`.
- `bin/fm-pack.sh` header: pack, verify, restore and release steps, sidecar fields, the release guards' exact checks, exit codes.
- `docs/disk-room.md` and `bin/fm-disk-room.sh`: the reservation pools and the runway alerts this component admits through.

## Long-term-correct patterns

- A new destination is data the publisher resolves (a named root in `docs/storage.md`), not a directory a caller builds.
- A new fact for readers is a new `key=value` line; a change to what line 1 means is a new file name.
- A new state is a row in the `docs/storage.md` table, a once-per-change notification, and a test through the public command.
- A new unit or record format is read through an explicit allowlist of format names, and everything else is refused before any work.
- Heavy steps run at `nice 19` and idle I/O and finish inside existing helpers, with no new service or index.

## Refuse

- A C: or Linux fallback in any form: a default path, mapping exit 75 or any non-zero `root` exit to another directory, or reviving `--fallback`, `FM_STORAGE_FALLBACK` or `fallback=` (`docs/storage.md` opening rule and reader rules).
- Writing to or formatting a RAW, unformatted or non-NTFS/exFAT volume, picking any volume other than the remembered volume id by size or letter, prompting for a password when mounting, or widening the mount rule beyond `mount -t drvfs <L>: /mnt/<l>` and its `umount` lines for D to H (`docs/storage.md` "What a check does" steps 2-4 and "Mount rule": "formatting needs the captain", a refusal is `not-mounted`; `bin/fm-storage.sh` `mount_ssd`).
- Treating an unreadable listing, a missing marker, a stale `checked_at`, a missing `ssd_device` or any unknown state as usable (reader rules 1-4; tool-design rule 1: unknown is a failure, never healthy).
- Taking line 1 alone as permission for a bulk write, or authorizing bulk from a marker in an empty Linux-backed `/mnt/d` (`docs/storage.md` "Mandatory bulk admission").
- Changing what line 1 means under the same file name, or writing the results-root file from anywhere but `check` (`docs/storage.md` "The results-root file").
- Moving, reselecting or rewriting the root of a delivery that already started, including C: pins (reader rule 5; "Already-started deliveries must use their recorded root").
- Writing a new large delivery without a `bulk-root` reservation, estimating the expanded peak from compressed or logical size, or staging incomplete payloads in a Linux temp directory (`docs/storage.md` "Mandatory bulk admission").
- Silently replacing a live reservation name (`docs/storage.md`: "A live reservation name is never silently replaced").
- Deleting a packed source anywhere but `fm-pack.sh release`, skipping or weakening an R2 guard, or deleting before `verify --against` passes (`docs/storage.md` "Retention rule R2"; `bin/fm-pack.sh` header).
- Changing the release window default without a recorded decision (`docs/storage.md`: "The default window is zero; changing it requires a new recorded decision").
- Overwriting a committed unit, reusing stale staging, or reading an unknown unit format leniently (`bin/fm-pack.sh` header exit 2 cases).
- Adding an index, catalog or second manifest beside the sidecars (`docs/storage.md`: "They are the whole manifest; there is no index").
- Changing an exit code, a `wait:` token or a receipt line consumers parse without a versioned format and a note to those consumers.
- Writing a new absolute storage path into a record where a root name and a relative location would do.
- Notifying on every check instead of once per state change, or muting a notification (`docs/storage.md` "What a check does"; tool-design rules 1 and 3).

## Review

Answer each check PASS or FINDING.

1. Does every changed path end in a verified D: location or an exit 75 with exactly one `wait:` reason, with no C: or Linux destination anywhere?
2. Does every unknown, unreadable, stale or unproven reading lead to a wait or a refusal, never to a write?
3. Is the results-root file still written only by `check`, atomically, with line 1's v1 meaning unchanged?
4. Does volume selection still honour the remembered volume id, write nothing to and never format a volume that is not NTFS or exFAT, and mount only through `sudo -n` within the five-line D-H rule, reading a refusal as `not-mounted`?
5. Does a new delivery path reserve its whole peak before writing and release its reservation on success and on every failure?
6. Does every deletion go through `fm-pack.sh release`, with every R2 guard run and `verify --against` passing just before removal?
7. Are exit codes, `wait:` tokens, receipt lines and sidecar formats unchanged, or changed through a new versioned format with every consumer named?
8. Is each new fact stated once in its owner (`docs/storage.md` or the script header) and only cross-referenced elsewhere?
9. Does each state change notify once, and is every wait, refusal and release logged with its reason?
10. Would `tests/fm-storage.test.sh` or `tests/fm-pack.test.sh` fail, through the public commands, if this behaviour broke?
11. Would a new root, data family or unit format need only a data or allowlist entry, not a new code branch?
12. Do heavy steps still run at `nice 19` and idle I/O, with no new service, daemon or index?
13. If a source pinned in this skill's `metadata.sources` changed, does every rule here still hold, and are the pins updated in the same change?
