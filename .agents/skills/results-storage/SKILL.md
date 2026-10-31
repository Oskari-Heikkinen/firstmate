---
name: results-storage
description: "Load before writing experiment results or other bulk output, choosing where result bytes go, packing or releasing a cold tree, on an exit-75 storage wait, and before changing bin/fm-storage.sh, bin/fm-pack.sh, docs/storage.md or their tests."
user-invocable: false
metadata:
  internal: true
  sources:
    - path: docs/storage.md
      sha256: 3e0f14467191fb0f02e18f438778b5fbb382581d049ca30ba8ab6a37872af779
    - path: bin/fm-storage.sh
      sha256: 035a87a5a19fb7521ce5a5b757bd89232a3c1fb24d2010feb9800bc0eaaaf86d
    - path: bin/fm-pack.sh
      sha256: 3a8121bd023592f8f45c80a4cdee11d0ba0883588077d1993e78e8721de8524b
    - path: bin/fm-pack-retry.c
      sha256: 3eeff66fcf5e63e6ab6fd0da33d75f66d7df0b197e6b822ae4614c5527dfcf5b
    - path: bin/fm-pack-parity.py
      sha256: c442741709dd706b6010d9036414163e48c283588419078d5426ce4cd4aef4f2
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

- `docs/storage.md`: the results-root file `lattice-storage-results-root/v1`, the states, the reader rules, mandatory bulk admission, named roots, the class map and site roots, D: health, the draft `fm-storage/v2` consumer contract with its C: terms, when to pack, and retention rule R2.
- `bin/fm-storage.sh` header: commands, files, environment.
- `bin/fm-spawn.sh` header: when a worker launch carries `LATTICE_STORAGE_TOOL`, the absolute path workers resolve `fm-storage.sh` from, since it is not on their `PATH`.
- `bin/fm-pack.sh` header: pack, verify, verify-tar (the G5-equivalent tar/image parity check), restore and release steps, the read-only candidates report and its pack states, sidecar fields, the release guards' exact checks, exit codes, the ENOMEM retry shim (`bin/fm-pack-retry.c`), and the machine-wide pack slot another heavy D: tool shares, with its bounded wait and the `stop` verb that ends a holder at a safe point.
- `bin/fm-storage-roots.py` header: `site-config` and `health`, their ordered checks, codes and environment.
- `docs/disk-room.md` and `bin/fm-disk-room.sh`: the reservation pools, the token admissions and `admission-status` behind `fm-storage/v2`, and the runway alerts this component admits through.

## Long-term-correct patterns

- A new destination is data the publisher resolves (a named root in `docs/storage.md`), not a directory a caller builds.
- A new fact for readers is a new `key=value` line; a change to what line 1 means is a new file name.
- A new state is a row in the `docs/storage.md` table, a once-per-change notification, and a test through the public command.
- A new unit or record format is read through an explicit allowlist of format names, and everything else is refused before any work.
- Heavy steps run at `nice 19` and idle I/O, one at a time machine-wide through the pack slot, and finish inside existing helpers, with no new service or index.
- A slot waiter gives up after a bounded wait with exit 75, and a slot holder stops at a safe point on `fm-pack.sh stop`, so an idle or long pack never holds up an install, update or landing.

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
- Reading a `verify-tar` pass as authority to delete a tar or a source, building its expectation from the tar or image it checks rather than from committed records, or weakening the whole-tar digest or the member comparison in either direction (`bin/fm-pack.sh` header, verify-tar).
- Making `--interface` claim `fm-storage/v2` from a build whose `tests/fm-storage-v2.test.sh` has not passed, calling the contract final before the reviewed phase-D design, or letting a v2 command act before its class map and site policy exist (`docs/storage.md` "fm-storage/v2 (draft)").
- Resolving a v2 class to a root anywhere but `site-config`, or a v2 admission with a caller-chosen `--root` (`docs/storage.md` "Class map and site roots").
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
10. Would `tests/fm-storage.test.sh`, `tests/fm-pack.test.sh` or `tests/fm-pack-parity.test.sh` fail, through the public commands, if this behaviour broke?
11. Would a new root, data family or unit format need only a data or allowlist entry, not a new code branch?
12. Do heavy steps still run at `nice 19` and idle I/O, inside the machine-wide pack slot, with no new service, daemon or index, and does every slot wait stay bounded and every holder stoppable without a half-committed unit?
13. If a source pinned in this skill's `metadata.sources` changed, does every rule here still hold, and are the pins updated in the same change?
