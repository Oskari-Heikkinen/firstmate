# Disk room on a WSL laptop

On WSL the Linux root filesystem lives in a non-sparse `ext4.vhdx` file on the Windows drive.
`df /` reports the virtual disk's own size (1 TiB by default), so it overstates room, and space Linux frees stays allocated on the Windows drive until the file is compacted while WSL is not running.
This page covers the real-room monitor that reads the situation correctly and the one-time Windows install that returns freed space, at Windows start while its optional startup task is enabled and on demand through the reclaim-now step.
The agent procedure is the `disk-room` skill; `bin/fm-disk-room.sh` and `bin/fm-wsl-reclaim.ps1` own their exact commands in their headers.
A home that runs `bin/fm-disk-room.sh` under a pin declares itself as described in [`helper-consumers.md`](helper-consumers.md), so a Firstmate update waits for it to accept a new version.

## Real room

`bin/fm-disk-room.sh` treats real room as the smaller of the Windows drive's free space and Linux free space, each minus the writes running jobs have declared, with the Windows drive's figure also minus the shadow storage headroom and the swap file growth described below.
Slack inside the disk file is not counted as room: ext4 does not prefer blocks the file already holds, so a large new file grows the file even while slack exists.
The slack is reported separately, together with how much of it the next compaction would actually return.

A compaction can drop a 1 MiB block of the disk file only when every ext4 block inside it is free.
Free space scattered in holes smaller than 1 MiB between live data therefore stays allocated through any compaction, and through sparse mode too.
The monitor reads that fragmented free space from `/proc/fs/ext4/<device>/mb_groups` and subtracts it.
ext4's own metadata (inode tables, journal, bitmaps) also sits in the disk file's slack, because `df` counts it neither as used nor in its total, and no compaction returns it.
The monitor takes it as the root block device's size minus the `df` total and subtracts it too, so "reclaimable" means what a compaction can really give back, never more.
When that table, the device size, or the disk file cannot be read, the monitor reports reclaimable as unknown rather than guessing.

The margin is the room that must remain after a job's expected write, 20 GiB by default (`FM_DISK_ROOM_MARGIN`).
Sizes are binary (G = GiB), matching what Windows Explorer shows as GB.
`status` also reports an external SSD's room and which root fetched results use, read from the file [`docs/storage.md`](storage.md) describes.

### Shadow storage headroom

Windows restore points keep their copy-on-write data in the system drive's shadow storage (diff area).
The part already used shows up in the drive's free space, but the headroom left up to its cap is not yet taken and would otherwise be counted as room.
After each restore point, the first overwrite of any block inside the non-sparse `ext4.vhdx` makes `volsnap` copy the old block into the diff area.
The diff area therefore grows in 224 MiB steps until its cap binds, while Linux `df` and the disk file's size stay flat.
The monitor reserves that headroom, the cap minus what is already allocated, from the Windows drive's free space.

The monitor reads the cap and the allocated and used sizes live, without elevation, from `Win32_ShadowStorage` through `powershell.exe` (`FM_DISK_ROOM_POWERSHELL`; empty disables it), under a 20 second timeout, and caches the reading, or its failure, for 5 minutes.
Because the reading is live, the reservation shrinks as the diff area grows and returns to nearly the whole cap after a restore point starts a new, nearly empty diff area.
The `shadow storage:` status line ends with the source of its numbers, `live`, the last live reading with its time, `record`, or `none`, and `status --json` gives it as `shadow_reading` (`live`, `last-live`, `record`, or `none`).

Each good live reading is also kept as the last good live reading, which a failed reading never overwrites.
When the live reading fails or times out, the newer of the last good live reading and the elevated record is the fallback.
The last good live reading reserves its cap minus its allocated size, and the line says `source last live reading at <time>, no live reading now`.
The record reserves the cap minus the recorded used size.
A last good live reading older than 7 days is treated like a stale record below and reserves its whole cap.
The elevated script from the install below writes that record, `C:\ProgramData\firstmate\shadow-storage.txt`, at every `-Install` and reclaim-now run, and at every Windows start while the startup task is enabled.
The task runs the copy the install made in `C:\ProgramData\firstmate\`, so an install made before this record existed never writes it; re-run `fm-wsl-reclaim.ps1 -Install` elevated to update that copy.
A record older than 7 days, or no record at all, leaves the used size unknown; the monitor then reserves the whole cap, the larger of the record's cap and `FM_DISK_ROOM_SHADOW_MAX` (for example `10G`), because a too-large reservation only makes room read low.
With neither a capped record nor `FM_DISK_ROOM_SHADOW_MAX`, nothing is reserved and room reads as before; a record of shadow storage without a cap reserves nothing unless `FM_DISK_ROOM_SHADOW_MAX` bounds it.
On every reading the monitor also counts `volsnap` System events 25, 33, and 36 of the last 7 days, which need no elevation, and warns that the shadow storage is cycling, deleting restore points at its cap, when any occurred.

### Swap file growth

WSL keeps its swap file, `swap.vhdx`, on the Windows drive and grows it as Linux swaps, up to the configured swap size, while Linux `df` and the disk file stay flat.
The monitor reserves that remaining growth, the swap size minus the swap file's current length, from the Windows drive's free space.
The swap size is `swap=` in the `[wsl2]` section of the Windows `.wslconfig`; `swap=0` means no swap file and nothing is reserved.
When `swap=` is unset, the size is WSL's default of a quarter of the VM's memory rounded up to a whole GiB, with the memory taken from `memory=` or else from Linux `MemTotal`.
The swap file is `swapFile=` when set, else the newest `%TEMP%\<guid>\swap.vhdx` in the Windows user folder, looked up again after each VM boot so one left behind by an unclean WSL exit gives way to the new one; a swap file that cannot be found counts as empty, so the whole size is reserved, and a `swapFile=` on another drive reserves nothing here.
The `.wslconfig` is the one beside the disk file's Windows user folder (`FM_DISK_ROOM_WSLCONFIG`; empty disables the reservation).
Everything is read as files through the drive mount, so no Windows process starts.
The `swap file:` status line names where the size came from, and `status --json` gives `swap_reserved`, `swap_source`, `swap_size`, and `swap_file_size`.

## Admitting big writes

A job that writes 1 GiB or more runs through `fm-disk-room.sh run --name <job> --expect-write <size> -- <command>`.
It is admitted only when the room left after its write stays at or above the margin, and it holds a reservation for its lifetime so other admissions and the watcher see its pending write.
A refusal exits 75 with one line naming the room and whether a compaction would help.
`check --expect-write`, `reserve`, and `release` cover jobs that span several processes.
Mandatory D: bulk uses the separate per-filesystem admission interface documented in [storage.md](storage.md#mandatory-bulk-admission), leaving this Linux/C: admission unchanged.

This replaces fixed floors on raw Windows free space, which either stop a job that still has room or admit one whose own write breaks the margin.

## Watcher check

A home that should hear about low room arms the standing watcher check with `bin/fm-disk-room.sh arm`, which writes `state/disk-room.check.sh` with the `FM_DISK_ROOM_*` settings in force and binds it with `bin/fm-check-register.sh`; `bin/fm-disk-room.sh disarm` retires it.
`watch-line` prints nothing while real room is at or above the margin.
Under the margin it prints one line with the real room, the declared writes, and the next step, and repeats only after a further 5 GiB drop or 6 hours; a failed reading prints a "cannot measure" line at most every 6 hours.
It reads only `df`, one `stat` of the disk file through `/mnt/c`, `mb_groups`, the live shadow storage reading, the last good live reading, the shadow storage record, the `.wslconfig`, the kernel boot id, and one `stat` of the swap file.
It starts PowerShell for the live reading at most once every 5 minutes, failures included, under a 20 second timeout, because PowerShell times out when Windows is short of memory.
It runs `wevtutil.exe` for the event count at most once an hour, under a 20 second timeout.

## Growth and runway alerts

The same watcher check also reports storage growth and runway, from readings that already exist: the data-gate sampler's `samples.jsonl` (Linux and C: used bytes every 5 minutes, read only from its tail), `df` of the Windows drive and the verified D: results directory, the disk file's length, and the live reservations.
It raises an alert when any of these holds:

- Linux used grew faster than 0.5 GiB/day over the last week (`FM_DISK_ROOM_GROWTH_MAX`), judged only from at least six days of samples whose newest is under 2 hours old;
- the Windows drive has under 100 GiB actually free (`FM_DISK_ROOM_C_FREE_MIN`), before reservations, shadow storage headroom, and swap file growth;
- D: has under 50 GiB free after its live bulk reservations (`FM_DISK_ROOM_D_FREE_MIN`), measured live when the publication's D: device is mounted and otherwise from the last published reading;
- mandatory D: bulk substituted Linux storage: a D: reservation pool sits on the Linux disk or C:, or the D: mount path's `lattice-data` folder sits on the Linux disk, where writes to a pinned D: root land once D: is not mounted.

Each threshold takes a size or `off`.
`watch-line` prints one `storage alert:` line when an alert starts or clears, joined to the low-room line with ` | ` when both speak, and never repeats a standing alert; a bad threshold is reported once.
An unknown reading, such as too few or stale samples, leaves the last state in place.
The C: alert may say how much a compaction could return, but nothing here schedules, triggers, or runs a compaction or a WSL shutdown; the captain runs the reclaim-now step.
The growth figure includes approved software installs and intentionally kept datasets, so a jump is attributed from the owners' records, never from a recursive scan.

`bin/fm-disk-room.sh growth` is the read-only report: Linux used and C: used change over the last day and week, C: free, the disk file's length and D: free with their daily and weekly change, D: and Linux/C: reservations, each alert's state, and the thresholds in force.
The disk file and D: changes come from a history of at most 200 hourly entries that `watch-line` keeps in its state directory, so they read unknown until the armed check has run for a day.

## Usage report

`bin/fm-usage-report.sh` holds read-only usage readouts that write, reserve, and schedule nothing and never walk a tree.
`d-line` prints one D: days-to-full line computed only from the `growth` report: D: free, the last day's and last week's rate, and at each falling rate the days until D: is full and that date.
A window the growth report reads as unknown stays unknown, a window whose free space did not fall reads `not filling`, and an unmeasured D: reads unknown, so the line never estimates.
The script's `--help` owns its exact output and exit codes.

## Reclaim (one-time Windows install)

`bin/fm-wsl-reclaim.ps1` is run by a Windows administrator; nothing in this repo runs elevated or as root on its own.
From an elevated Windows PowerShell, while the distro is running:

```
powershell -NoProfile -ExecutionPolicy Bypass -File \\wsl.localhost\<distro>\<path-to-firstmate>\bin\fm-wsl-reclaim.ps1 -Install
```

The install:

- copies the script to `C:\ProgramData\firstmate\`, restricted so only Administrators and SYSTEM can change it;
- records the distro's disk file and Docker Desktop's `docker_data.vhdx` (leave Docker out with `-NoDocker`);
- registers the "Firstmate WSL compact at startup" task, which runs as SYSTEM at every Windows start, compacts each recorded file that nothing holds open, and records the shadow storage cap and used size;
- records the shadow storage once right away.

No trim step is needed: the distro root is mounted with online `discard`, so blocks Linux frees are already unmapped for compaction.

While the startup task is enabled, a WSL or Docker start during the few minutes of startup compaction fails with the file in use and can simply be retried.
Each compaction run appends to `C:\ProgramData\firstmate\wsl-compact.log` and rewrites `wsl-compact-last.txt`, which `fm-disk-room.sh status` shows as `last compaction:`.
`-Plan` (the default, no elevation needed) shows the resolved files, their sizes, sparse flags, whether they are in use, and the last result.

### Disabling the startup task

The startup task is optional.
From an elevated Windows PowerShell, `Disable-ScheduledTask -TaskName 'Firstmate WSL compact at startup'` disables it and `Enable-ScheduledTask -TaskName 'Firstmate WSL compact at startup'` turns it back on.
This laptop runs with the task installed but disabled.
Re-running `-Install` re-registers the task enabled, so run `Disable-ScheduledTask` again after any reinstall.
With it disabled:

- freed space returns to the Windows drive only through the reclaim-now step below;
- `last compaction:` advances only on reclaim-now runs;
- the shadow storage record is refreshed only by `-Install` and `-Now`, so when the live reading fails 7 days after both the last good live reading and the record the monitor treats them as stale and reserves the whole cap, which makes room read lower, never higher, until the next reclaim-now.

### Reclaim now

When the monitor says a compaction would help and the startup task is disabled or a restart is not convenient, the captain parks the work running in WSL and runs, elevated:

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\firstmate\fm-wsl-reclaim.ps1 -Now
```

It runs `wsl --shutdown`, compacts every recorded file, prints the before and after sizes, and starts the distro again (`-NoRestart` leaves it stopped).
Because it shuts WSL down, any `.wslconfig` change waiting for a restart takes effect in the same step, and the script prints the memory line now in effect.

### Uninstall

`fm-wsl-reclaim.ps1 -Uninstall`, elevated, removes the task and the ProgramData script, file list, and shadow storage record, and keeps the logs.
Compaction changes no data inside the disk, so there is nothing else to roll back.

## Limits

- Sparse mode (`wsl --manage <distro> --set-sparse true`) is not used: WSL 2.5.6 and later require `--allow-unsafe` for it because of potential data corruption, a sparse file cannot be compacted by diskpart, and it frees space at the same 1 MiB granularity.
- Fragmented free space that already exists stays allocated; only moving bulk data off the disk or re-importing the distro rewrites it.
- A reservation counts its whole expected write until the job exits, while the part already written also shows as used space, so room reads low (never high) while a reserved job runs.
- The monitor is WSL-aware but works anywhere: without a Windows drive mount it measures the Linux filesystem alone.
