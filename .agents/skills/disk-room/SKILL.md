---
name: disk-room
description: Agent-only procedure for laptop disk space on WSL. Load before starting or admitting a job expected to write 1 GiB or more to the Linux disk (including /tmp), on a "disk room low" or "disk room: cannot measure" notification, when anyone reports the Windows drive filling, and before proposing a compaction, sparse mode, or deletion to free space. Owns how agents read real room, admit big writes, what the automatic reclaim does, and which manual steps are retired.
---

# disk-room

On WSL the Linux disk is a non-sparse `ext4.vhdx` on the Windows drive, so `df /` overstates room and space Linux frees stays reserved on C: until the file is compacted.
[`docs/disk-room.md`](../../../docs/disk-room.md) owns the contract; `bin/fm-disk-room.sh`'s header owns the commands, sizes, and exit codes.

## What runs by itself once the captain has installed it

- The startup compaction task is installed but disabled on this laptop, so nothing compacts the disk files at Windows start; freed space comes back to C: only through the reclaim-now step in `docs/disk-room.md`.
- In a home that registered the watcher check, `fm-disk-room.sh watch-line` stays silent until real room is under the margin (20 GiB by default), then produces one notification, repeated only after a further 5 GiB drop or 6 hours.

Check the install with `fm-disk-room.sh status`: a `last compaction:` line shows the most recent compaction, which with the startup task disabled is the last reclaim-now run.

## How agents use it

- Read room with `fm-disk-room.sh status`, never with raw `df /` or `df /mnt/c` arithmetic.
- Before a job that writes 1 GiB or more, admit it with `fm-disk-room.sh run --name <job> --expect-write <size> -- <command>`, which refuses with exit 75 when the room left after that write would fall under the margin, and otherwise holds a reservation for the command's lifetime so concurrent admissions see it.
  For a job spread over several processes, use `check --expect-write` plus `reserve`/`release` instead.
- Use a measured or stated expected write (for example about 20 GiB per TETJET close-out slice), rounded up; when unknown, say so and ask the job's owner rather than guessing low.
- A refusal is a wait, not a failure: hold the job and report the refusal line to firstmate.

## What a low reading means and who acts

- "a compaction would reclaim about N GiB" - the space is already free inside Linux; the captain runs the reclaim-now step in `docs/disk-room.md`, which also stops every WSL process, so firstmate parks the fleet first.
- "reclaimable by compaction unknown" - the disk file or its fragmented free space could not be read; run `fm-disk-room.sh status`, fix the named reading, and do not promise the captain a compaction result until it reads.
- "data must be freed or moved" - compaction cannot help (the slack is fragmented free space sharing 1 MiB disk blocks with live data); bring the captain the owning task's numbers and options, and delete nothing without the captain's word.
- "shadow storage cycling" - Windows restore points are filling the shadow storage up to its cap and deleting older ones; report it to the captain with the rest of the reading, and change no restore-point or shadow storage setting.
- "cannot measure" - a reading failed; investigate the named reading before trusting any floor.

Firstmate relays only low readings, in the captain's terms; above the margin, disk is not news.

## No longer done by hand

- Fixed C: floors such as "C: free >= 55 GB" or "45 GB": use `check`/`run` with the job's expected write.
- Treating disk file size minus Linux used as reclaimable: fragmented free space is not, and `status` already subtracts it.
- Proposing `wsl --manage <distro> --set-sparse true --allow-unsafe`: Microsoft gates it for potential data corruption, and it would not recover fragmented slack.
- Hand-written diskpart sequences, `fstrim`, or `drop_caches` runs: online discard on `/` and the reclaim-now step cover them.
- Every Windows, root, elevation, or WSL-shutdown step still goes to the captain as the exact command from `docs/disk-room.md`; no agent runs one.
