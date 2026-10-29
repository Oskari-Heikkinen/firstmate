---
name: disk-room
description: Load before a 1 GiB+ write to the WSL Linux disk, before reading free space or proposing space reclaim, and whenever fm-disk-room output, a disk-room hold, a storage alert or a runway alert appears - including one quoting a margin or C: floor that looks wrong - or the Windows drive is filling.
---

# disk-room

Why this skill exists: a disk default silently replaced the home's own margin and floor files, so writes were held or allowed against numbers nobody set (root causes R2 and R9, problems P12 and P23).

On WSL the Linux disk is a non-sparse `ext4.vhdx` on the Windows drive, so `df /` overstates room and space Linux frees stays reserved on C: until the file is compacted.
[`docs/disk-room.md`](../../../docs/disk-room.md) owns the contract; `bin/fm-disk-room.sh`'s header owns the commands, sizes, and exit codes.

## What runs by itself once the captain has installed it

- The startup compaction task is installed but disabled on this laptop, so nothing compacts the disk files at Windows start; freed space comes back to C: only through the reclaim-now step in `docs/disk-room.md`. Re-running `fm-wsl-reclaim.ps1 -Install` re-enables the task, so disable it again afterwards.
- In a home that registered the watcher check, `fm-disk-room.sh watch-line` stays silent until real room is under the margin (the home's `config/disk-room-margin`, 20 GiB by default), then produces one notification, repeated only after a further 5 GiB drop or 6 hours.
  The same check prints one "storage alert" line when a growth or runway alert starts or clears; `docs/disk-room.md` owns the thresholds, and the C: runway floor is the home's `config/disk-room-c-free-min` (100 GiB by default), which the alert line quotes.
- A hold or alert quoting the built-in 20 GiB margin or 100 GiB floor, or any margin other than the home's `config/disk-room-margin`, means the file is missing or unreadable, or the waiter or armed check still carries an `FM_DISK_ROOM_MARGIN` override.
  Fix that before acting: it is a configuration fault, not a disk shortage, and relaying it as low room sends the operator after space that is not missing.

Check the install with `fm-disk-room.sh status`: a `last compaction:` line shows the most recent compaction, which with the startup task disabled is the last reclaim-now run.

## How agents use it

- Read room with `fm-disk-room.sh status`, never with raw `df /` or `df /mnt/c` arithmetic.
- Before a job that writes 1 GiB or more, admit it with `fm-disk-room.sh run --name <job> --expect-write <size> -- <command>`, which refuses with exit 75 when the room left after that write would fall under the margin, and otherwise holds a reservation for the command's lifetime so concurrent admissions see it.
  For a job spread over several processes, use `check --expect-write` plus `reserve`/`release` instead.
- For recurring comparable jobs, opt into job-kind history on admission and execution as the script header describes; execution records storage write bytes, and admission refuses a declaration below that kind's high.
  Use history for an omitted declaration only for comparable inputs; a new kind still needs a measured or stated expected write, rounded up, and known larger inputs need a larger declaration.
  When neither history nor a stated write exists, ask the job's owner rather than guessing low.
  A recording failure holds further typed jobs of that kind; investigate the named attempt and use the header's evidence-backed recovery procedure, never delete the hold merely to resume admission.
- A refusal is a wait, not a failure: hold the job and report the refusal line to firstmate.
- To see how much of the `fragmented` figure a home's cold trees hold, list them in its `config/repack-trees` and read `bin/fm-repack.sh plan --home <home>`; it is read-only, and its block estimate needs a root-run sample, which the operator takes.
  `fm-repack.sh run` rewrites those trees and is never scheduled: run it on a live home only on the operator's word, and treat its exit 75 as a hold, like any admission refusal.
- To move a finished, rarely read tree to D:, pack it with `bin/fm-pack.sh pack TASK UNIT SRC`; [`docs/storage.md`](../../../docs/storage.md#packing-cold-data) owns the command and the retention rule.
- For packed-source release, follow [retention rule R2 in `docs/storage.md`](../../../docs/storage.md#retention-rule-r2).
- A home that pins `fm-disk-room.sh` pins its consumer interface, not its bytes, and runs the self-test for that version before trusting a new copy; `docs/disk-room.md` "Consumer interface" owns the rule.
  A helper-consumer declaration still accepts exact bytes ([`docs/helper-consumers.md`](../../../docs/helper-consumers.md)), so a byte change with an unchanged interface still holds the update until that consumer accepts the new copy; `updatefirstmate` owns that hold.

## What a low reading means and who acts

- "a compaction would reclaim about N GiB" - the disk file's own block table already holds no data for that space, so a compaction returns at least about that much; the captain runs the reclaim-now step in `docs/disk-room.md`, which also stops every WSL process, so firstmate parks the fleet first.
- "after a trim: about N GiB more" on the status line - free 1 MiB blocks the disk file still holds; the reclaim-now step trims before compacting so it can return some or all of this on top of the reclaimable figure, but the figure is an estimate and never a promise (a trim can fail, or skip groups an earlier trim in the same boot covered); quote reclaimable as what compaction returns and this as a possible extra.
- "reclaimable by compaction unknown" - the disk file or its block table could not be read; run `fm-disk-room.sh status`, fix the named reading, and do not promise the captain a compaction result until it reads.
- "data must be freed or moved" - compaction cannot help, because the disk file's block table holds under 5 GiB of space it already marks free, whatever the slack looks like from Linux; bring the captain the owning task's numbers and options, and delete nothing without the captain's word.
- "shadow storage cycling" - Windows restore points are filling the shadow storage up to its cap and deleting older ones; report it to the captain with the rest of the reading, and change no restore-point or shadow storage setting.
- "source last live reading at <time>", "source record", or "source none" on the `shadow storage:` line - the live shadow storage reading failed, so the reservation comes from the newer of the last good live reading and the elevated record, or is missing; say so with the reading and its time, since room can then be overstated after a restore point.
- "swap file:" line - the WSL swap file's remaining growth up to its configured size is reserved from the Windows drive; a large reservation there is room that Linux swapping will take, and changing `.wslconfig` is the captain's call.
- "cannot measure" - a reading failed; investigate the named reading before trusting any floor.
- "storage alert" - Linux growth, C: or D: runway, or a mandatory D: substitution crossed its threshold; read `fm-disk-room.sh growth` (and `fm-usage-report.sh report` for what uses the tier) and relay the alert with that reading to the captain, who decides any retention, move, or compaction, and run none of them.

Firstmate relays only low readings, in the captain's terms; above the margin, disk is not news.
The compaction (reclaim-now) ask goes to the captain only on a low reading from the watch-line margin path.
A "later" or "not now" answer is final for that reading: nothing is held, re-dated, or recorded as a deferred captain call.
The next low reading asks again under the monitor's existing notification cadence.

## No longer done by hand

- Fixed C: floors such as "C: free >= 55 GB" or "45 GB": use `check`/`run` with the job's expected write.
- Treating disk file size minus Linux used, or any figure worked out from Linux's view, as reclaimable: only the disk file's block table says what a compaction returns, and `status` reads it.
- Proposing `wsl --manage <distro> --set-sparse true --allow-unsafe`: Microsoft gates it for potential data corruption, and it would not recover fragmented slack.
- Hand-written diskpart sequences, `fstrim`, or `drop_caches` runs: the reclaim-now step trims the distro root and then compacts, so no agent trims or compacts by hand.
- Every Windows, root, elevation, or WSL-shutdown step still goes to the captain as the exact command from `docs/disk-room.md`; no agent runs one.
