---
name: disk-room
description: Load before a 1 GiB+ write to the WSL Linux disk, on a disk-room or storage alert or the Windows drive filling, and before proposing space reclaim.
---

# disk-room

On WSL the Linux disk is a non-sparse `ext4.vhdx` on the Windows drive, so `df /` overstates room and space Linux frees stays reserved on C: until the file is compacted.
[`docs/disk-room.md`](../../../docs/disk-room.md) owns the contract; `bin/fm-disk-room.sh`'s header owns the commands, sizes, and exit codes.

## What runs by itself once the captain has installed it

- The startup compaction task is installed but disabled on this laptop, so nothing compacts the disk files at Windows start; freed space comes back to C: only through the reclaim-now step in `docs/disk-room.md`. Re-running `fm-wsl-reclaim.ps1 -Install` re-enables the task, so disable it again afterwards.
- In a home that registered the watcher check, `fm-disk-room.sh watch-line` stays silent until real room is under the margin (the home's `config/disk-room-margin`, 20 GiB by default), then produces one notification, repeated only after a further 5 GiB drop or 6 hours.
  The same check prints one "storage alert" line when a growth or runway alert starts or clears; `docs/disk-room.md` owns the thresholds.

Check the install with `fm-disk-room.sh status`: a `last compaction:` line shows the most recent compaction, which with the startup task disabled is the last reclaim-now run.

## How agents use it

- Read room with `fm-disk-room.sh status`, never with raw `df /` or `df /mnt/c` arithmetic.
- Before a job that writes 1 GiB or more, admit it with `fm-disk-room.sh run --name <job> --expect-write <size> -- <command>`, which refuses with exit 75 when the room left after that write would fall under the margin, and otherwise holds a reservation for the command's lifetime so concurrent admissions see it.
  For a job spread over several processes, use `check --expect-write` plus `reserve`/`release` instead.
- Use a measured or stated expected write (for example about 20 GiB per TETJET close-out slice), rounded up; when unknown, say so and ask the job's owner rather than guessing low.
- A refusal is a wait, not a failure: hold the job and report the refusal line to firstmate.
- To move a finished, rarely read tree to D:, pack it with `bin/fm-pack.sh pack TASK UNIT SRC`; [`docs/storage.md`](../../../docs/storage.md#packing-cold-data) owns the command and the retention rule.
- Retention rule R2: the home that owns a packed source, on D: or Linux, releases it with `bin/fm-pack.sh release` as soon as the pack verifies (zero window since 2026-10-18), and the command refuses unless its verify, acceptance, reference, mount-use and hard-link guards hold; [`docs/storage.md`](../../../docs/storage.md#retention-rule-r2) owns the rule.

## What a low reading means and who acts

- "a compaction would reclaim about N GiB" - the space is already free inside Linux, after fragmented free space and ext4's own metadata are subtracted; the captain runs the reclaim-now step in `docs/disk-room.md`, which also stops every WSL process, so firstmate parks the fleet first.
- "reclaimable by compaction unknown" - the disk file, its fragmented free space, or the ext4 metadata size could not be read; run `fm-disk-room.sh status`, fix the named reading, and do not promise the captain a compaction result until it reads.
- "data must be freed or moved" - compaction cannot help (the slack is fragmented free space sharing 1 MiB disk blocks with live data, or ext4's own metadata); bring the captain the owning task's numbers and options, and delete nothing without the captain's word.
- "shadow storage cycling" - Windows restore points are filling the shadow storage up to its cap and deleting older ones; report it to the captain with the rest of the reading, and change no restore-point or shadow storage setting.
- "source last live reading at <time>", "source record", or "source none" on the `shadow storage:` line - the live shadow storage reading failed, so the reservation comes from the newer of the last good live reading and the elevated record, or is missing; say so with the reading and its time, since room can then be overstated after a restore point.
- "swap file:" line - the WSL swap file's remaining growth up to its configured size is reserved from the Windows drive; a large reservation there is room that Linux swapping will take, and changing `.wslconfig` is the captain's call.
- "cannot measure" - a reading failed; investigate the named reading before trusting any floor.
- "storage alert" - Linux growth, C: or D: runway, or a mandatory D: substitution crossed its threshold; read `fm-disk-room.sh growth` (and `fm-usage-report.sh report` for what uses the tier) and relay the alert with that reading to the captain, who decides any retention, move, or compaction, and run none of them.

Firstmate relays only low readings, in the captain's terms; above the margin, disk is not news.

## No longer done by hand

- Fixed C: floors such as "C: free >= 55 GB" or "45 GB": use `check`/`run` with the job's expected write.
- Treating disk file size minus Linux used as reclaimable: neither fragmented free space nor ext4's own metadata is, and `status` already subtracts both.
- Proposing `wsl --manage <distro> --set-sparse true --allow-unsafe`: Microsoft gates it for potential data corruption, and it would not recover fragmented slack.
- Hand-written diskpart sequences, `fstrim`, or `drop_caches` runs: online discard on `/` and the reclaim-now step cover them.
- Every Windows, root, elevation, or WSL-shutdown step still goes to the captain as the exact command from `docs/disk-room.md`; no agent runs one.
