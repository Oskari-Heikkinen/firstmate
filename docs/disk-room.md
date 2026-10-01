# Disk room on a WSL laptop

On WSL the Linux root filesystem lives in a non-sparse `ext4.vhdx` file on the Windows drive.
`df /` reports the virtual disk's own size (1 TiB by default), so it overstates room, and space Linux frees stays allocated on the Windows drive until the file is compacted while WSL is not running.
This page covers the real-room monitor that reads the situation correctly and the one-time Windows install that returns freed space automatically.
The agent procedure is the `disk-room` skill; `bin/fm-disk-room.sh` and `bin/fm-wsl-reclaim.ps1` own their exact commands in their headers.

## Real room

`bin/fm-disk-room.sh` treats real room as the smaller of the Windows drive's free space and Linux free space, each minus the writes running jobs have declared, with the Windows drive's figure also minus the shadow storage headroom described below.
Slack inside the disk file is not counted as room: ext4 does not prefer blocks the file already holds, so a large new file grows the file even while slack exists.
The slack is reported separately, together with how much of it the next compaction would actually return.

A compaction can drop a 1 MiB block of the disk file only when every ext4 block inside it is free.
Free space scattered in holes smaller than 1 MiB between live data therefore stays allocated through any compaction, and through sparse mode too.
The monitor reads that fragmented free space from `/proc/fs/ext4/<device>/mb_groups` and subtracts it, so "reclaimable" means what a compaction can really give back.
When that table or the disk file cannot be read, the monitor reports reclaimable as unknown rather than guessing.

The margin is the room that must remain after a job's expected write, 20 GiB by default (`FM_DISK_ROOM_MARGIN`).
Sizes are binary (G = GiB), matching what Windows Explorer shows as GB.
`status` also reports an external SSD's room and which root fetched results use, read from the file [`docs/storage.md`](storage.md) describes.

### Shadow storage headroom

Windows restore points keep their copy-on-write data in the system drive's shadow storage (diff area).
The part already used shows up in the drive's free space, but the headroom left up to its cap is not yet taken and would otherwise be counted as room.
After each restore point, the first overwrite of any block inside the non-sparse `ext4.vhdx` makes `volsnap` copy the old block into the diff area.
The diff area therefore grows in 224 MiB steps until its cap binds, while Linux `df` and the disk file's size stay flat.
The monitor reserves that headroom, the cap minus what is already used, from the Windows drive's free space.

Reading the cap and the used size needs elevation, so the elevated task from the install below records both in `C:\ProgramData\firstmate\shadow-storage.txt` at every Windows start, install, and reclaim.
A record older than 7 days, or no record at all, leaves the used size unknown; the monitor then reserves the whole cap, taken from the record or from `FM_DISK_ROOM_SHADOW_MAX` (for example `10G`), because a too-large reservation only makes room read low.
With neither a record nor `FM_DISK_ROOM_SHADOW_MAX`, nothing is reserved and room reads as before.
Without a fresh record the monitor also counts `volsnap` System events 25, 33, and 36 of the last 7 days, which need no elevation, and warns that the shadow storage is cycling, deleting restore points at its cap, when any occurred.

## Admitting big writes

A job that writes 1 GiB or more runs through `fm-disk-room.sh run --name <job> --expect-write <size> -- <command>`.
It is admitted only when the room left after its write stays at or above the margin, and it holds a reservation for its lifetime so other admissions and the watcher see its pending write.
A refusal exits 75 with one line naming the room and whether a compaction would help.
`check --expect-write`, `reserve`, and `release` cover jobs that span several processes.

This replaces fixed floors on raw Windows free space, which either stop a job that still has room or admit one whose own write breaks the margin.

## Watcher check

A home that should hear about low room arms the standing watcher check with `bin/fm-disk-room.sh arm`, which writes `state/disk-room.check.sh` with the `FM_DISK_ROOM_*` settings in force and binds it with `bin/fm-check-register.sh`; `bin/fm-disk-room.sh disarm` retires it.
`watch-line` prints nothing while real room is at or above the margin.
Under the margin it prints one line with the real room, the declared writes, and the next step, and repeats only after a further 5 GiB drop or 6 hours; a failed reading prints a "cannot measure" line at most every 6 hours.
It reads only `df`, one `stat` of the disk file through `/mnt/c`, `mb_groups`, and the shadow storage record, and never starts PowerShell, which times out when Windows is short of memory.
Without a fresh shadow storage record it runs `wevtutil.exe` for the event count at most once an hour, under a 20 second timeout.

## Automatic reclaim (one-time Windows install)

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

A WSL or Docker start during the few minutes of startup compaction fails with the file in use and can simply be retried.
Each run appends to `C:\ProgramData\firstmate\wsl-compact.log` and rewrites `wsl-compact-last.txt`, which `fm-disk-room.sh status` shows as `last compaction:`.
`-Plan` (the default, no elevation needed) shows the resolved files, their sizes, sparse flags, whether they are in use, and the last result.

### Reclaim now

When the monitor says a compaction would help and a restart is not convenient, the captain parks the work running in WSL and runs, elevated:

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
