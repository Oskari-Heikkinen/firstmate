# Disk room on a WSL laptop

On WSL the Linux root filesystem lives in a non-sparse `ext4.vhdx` file on the Windows drive.
`df /` reports the virtual disk's own size (1 TiB by default), so it overstates room, and space Linux frees stays allocated on the Windows drive until the file is compacted while WSL is not running.
This page covers the real-room monitor that reads the situation correctly and the one-time Windows install that returns freed space, at Windows start while its optional startup task is enabled and on demand through the reclaim-now step.
The agent procedure is the `disk-room` skill; `bin/fm-disk-room.sh` and `bin/fm-wsl-reclaim.ps1` own their exact commands in their headers.
A home that runs `bin/fm-disk-room.sh` under a pin declares itself as described in [`helper-consumers.md`](helper-consumers.md), so a change to the script lands on Firstmate's default branch only after it accepts the new version.

## Real room

`bin/fm-disk-room.sh` treats real room as the smaller of the Windows drive's free space and Linux free space, each minus the writes running jobs have declared, with the Windows drive's figure also minus the shadow storage headroom and the swap file growth described below.
Slack inside the disk file is not counted as room: ext4 does not prefer blocks the file already holds, so a large new file grows the file even while slack exists.
The slack is reported separately, together with how much of it the next compaction would actually return.

A compaction (diskpart `compact vdisk`, which cannot read ext4) drops only the 1 MiB blocks that the disk file's own block allocation table (BAT) already marks as not present, unmapped or zero, then shrinks the file.
Linux's view of free space does not decide it: a block stays in the file until a discard from Linux unmaps the whole block.
So "reclaimable by compaction" is read from the BAT alone, by `bin/fm-vhdx-bat.py`: the disk file's length minus its present blocks and its fixed header area.
The read is read-only, about 9 MiB for a 1 TiB disk, and cached for 5 minutes.
The figure can only under-promise, because blocks unmapped after the reading are not counted, and no block becomes compactable without being unmapped first.
When the BAT cannot be read, reclaimable is reported as unknown, and nothing is promised in its place.
Only the distro's disk file is read; Docker Desktop's `docker_data.vhdx` is compacted too but not counted.

The status line also shows the slack's Linux-side readings, which never feed the reclaimable figure, the advice or the alerts.
Free space scattered in holes smaller than 1 MiB between live data (from `/proc/fs/ext4/<device>/mb_groups`) shares its blocks with live data, so no compaction returns it.
ext4's own metadata (inode tables, journal, bitmaps; the root block device's size minus the `df` total) sits in the slack too, because `df` counts it neither as used nor in its total, and no compaction returns it either.
The rest of the slack is free space Linux holds no data in that the BAT may still mark present, so it is not reclaimable until a discard covers each whole block.

A line `after a trim: about N GiB more` estimates that last part, read-only: the 1 MiB blocks the BAT holds present although ext4's free-space buddies (`mb_groups`) cover each of them whole.
The reclaim-now step trims the distro root just before it shuts WSL down, which unmaps those blocks so its compaction can drop them too.
The figure is per ext4 block group, counting the whole free blocks less those the BAT already holds absent in that group, so it is a lower bound; it assumes ext4 fills the virtual disk from its first byte with standard 128 MiB groups, as WSL's root does.
It is informational only: it never adds to "reclaimable by compaction", the advice or the alerts, because the startup task does not trim, a trim can fail, and ext4 skips block groups an earlier trim in the same boot already covered even when online discard has left blocks present there since.
`status --json` gives it as `trim_reclaimable`, null when `mb_groups` or the BAT cannot be read.

The margin is the room that must remain after a job's expected write, 20 GiB by default.
A home sets it durably in `config/disk-room-margin`, and `FM_DISK_ROOM_MARGIN` overrides that for one run; [`configuration.md`](configuration.md#disk-room-margin-configdisk-room-margin) owns the format, precedence, and inheritance.
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
For recurring comparable jobs, add a stable job kind to `run` and `check` so admission checks the declaration against that kind's recorded high, or uses history when no declaration is supplied.
An unseen kind still needs an explicit declaration, an understated one is refused, and corrupt history or an unresolved recording failure fails closed rather than trusting a stale high.
The tool records Linux-accounted storage writes from the command and waited-for descendants, including failed attempts; this is not logical output size or a peak-space guarantee.
The script header owns the kind options, history and pending-attempt formats, queries, evidence-backed recovery, measurement limits, and error handling.
Consumers must group comparable inputs and keep declaring larger known writes rather than treating a historical high as a bound.
Legacy calls without a kind keep their original exec and declaration behavior.
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
- ext4's fragmented free space (free space in buddies under 1 MiB, which shares a disk-file block with live data, so the disk file keeps it and a compaction cannot return it) grew faster than the home's fragmented growth limit over the last week, judged only from at least six days of hourly history whose newest entry is under 2 hours old; the limit is 1 GiB/day unless the home's `config/disk-room-fragmented-max-per-day` or `FM_DISK_ROOM_FRAGMENTED_MAX` sets it, and [`configuration.md`](configuration.md#disk-room-fragmented-growth-limit-configdisk-room-fragmented-max-per-day) owns the format, precedence, and inheritance;
- the Windows drive has less actually free than the home's C: free floor, before reservations, shadow storage headroom, and swap file growth; the floor is 100 GiB unless the home's `config/disk-room-c-free-min` or `FM_DISK_ROOM_C_FREE_MIN` sets it, and [`configuration.md`](configuration.md#disk-room-c-free-floor-configdisk-room-c-free-min) owns the format, precedence, and inheritance;
- D: has under 50 GiB free after its live bulk reservations (`FM_DISK_ROOM_D_FREE_MIN`), measured live when the publication's D: device is mounted and otherwise from the last published reading;
- mandatory D: bulk substituted Linux storage: a D: reservation pool sits on the Linux disk or C:, or the D: mount path's `lattice-data` folder sits on the Linux disk, where writes to a pinned D: root land once D: is not mounted.

Each threshold takes a size or `off`.
`watch-line` prints one `storage alert:` line when an alert starts or clears, joined to the low-room line with ` | ` when both speak, and never repeats a standing alert; a bad threshold is reported once.
An unknown reading, such as too few or stale samples, leaves the last state in place.
The C: alert may say how much a compaction could return, but nothing here schedules, triggers, or runs a compaction or a WSL shutdown; the captain runs the reclaim-now step.
The growth figure includes approved software installs and intentionally kept datasets, so a jump is attributed from the owners' records, never from a recursive scan.

`bin/fm-disk-room.sh growth` is the read-only report: Linux used and C: used change over the last day and week, C: free, the disk file's length and D: free with their daily and weekly change, the fragmented free space with its daily, weekly and two-week change, D: and Linux/C: reservations, each alert's state, and the thresholds in force.
The disk file, D: and fragmented changes come from a history of at most 400 hourly entries (at least 16 days) that `watch-line` keeps in its state directory, so they read unknown until the armed check has run for a day.
Each entry holds the time, the disk file's length, C: free, D: free, D: reservations and the fragmented free bytes, with `-` for a reading that failed; entries written before the fragmented column existed have five fields and still read, without a fragmented value.
`watch-line` writes the hourly entry even when a threshold is bad, so the history has no gap while the alerts cannot be evaluated.

## Allocator settings

`bin/fm-ext4-alloc-trial.sh` answers whether an ext4 allocator setting slows the growth of fragmented free space, measured on a scratch loop image and never on a live filesystem.
For each setting it formats a fresh image, sets that setting only on the image's own loop device, replays a seeded workload shaped like this machine's writes, reads the image's `mb_groups` after every round through `fm-disk-room.sh mb-groups` (the same parser as the fragmented reading above), and prints one table.
A setting passes when its fragmented growth is under 10% of the default's without more than twice the default's allocation time; the table's `answer:` line names each setting that passes.
The script's header owns its options, refusals, cleanup, results format, and exit codes.

It runs as root, so the operator runs it; no agent does.
It refuses `/`, anything on `/mnt`, system directories, network and FUSE filesystems, and any directory that is not empty, all before it checks for root.
As root it then refuses a scratch directory or results directory that a user other than root could swap, so both are made with `sudo`.
The image is sparse and mounted with discard, but its blocks are allocated on the filesystem that holds the scratch directory, so on the WSL Linux disk it can grow the disk file by up to the image size until the next compaction.
Admit it like any other big write, with an empty scratch directory and a results file outside it:

```
sudo mkdir -p /var/tmp/fm-ext4-trial/scratch
bin/fm-disk-room.sh run --name ext4-alloc-trial --expect-write 8G -- \
  sudo bin/fm-ext4-alloc-trial.sh run --dir /var/tmp/fm-ext4-trial/scratch --results /var/tmp/fm-ext4-trial/results.tsv
```

`bin/fm-ext4-alloc-trial.sh table /var/tmp/fm-ext4-trial/results.tsv` prints the table again from the results file.
Allocator values set on the loop device vanish with it, so a trial never changes the live root's settings; applying a setting to the live disk is a separate decision for the operator.
The test suite runs a smaller trial of every default setting on GitHub's Linux runners, where `sudo -n` works, and prints its table in the CI log.

## Usage report

`bin/fm-usage-report.sh` holds read-only usage readouts that write, reserve, and schedule nothing and never walk a tree.
`d-line` prints one D: days-to-full line computed only from the `growth` report: D: free, the last day's and last week's rate, and at each falling rate the days until D: is full and that date.
A window the growth report reads as unknown stays unknown, a window whose free space did not fall reads `not filling`, and an unmeasured D: reads unknown, so the line never estimates.

`report` answers what is using each tier and when it is full, from existing records only: lattice-data `catalog.jsonl` per store, the cold archive's `MANIFEST.tsv` and `MANIFEST.packed.tsv` with their pack sidecars, the TETJET pack index and census, `tetjet-collected/v1` receipts, the research `catalog.sqlite` kept steps, and the `growth` report.
Each row is one tier (Linux, C:, D:), owner, kind, and age bucket with its item count, logical bytes, and allocated bytes, and each tier's heading gives its free space and days to full at the last day's and last week's rate.
A size a record does not hold, such as a pack image's allocation, prints `unknown` and makes its row's sum `unknown`, never an estimate.
A path several records name counts once, under the first source in that order, and a raw tree the records name counts only while that one path still stands; nothing else touches the disk.
Sources that live in another home, the TETJET pack index, census, and receipts, are read only when their environment variables name them, and the report lists every source as read, absent, unreadable, or not configured.
The script's `--help` owns its exact output, its environment, and its exit codes.

## Repacking cold trees

ext4 packs small files into partly used 1 MiB blocks, and a compaction returns only whole free 1 MiB blocks, so space freed inside a partly used block stays allocated on the Windows drive; the `fragmented` figure in `fm-disk-room.sh status` is that space.
`bin/fm-repack.sh` rewrites the files of a home's cold trees, oldest first, in one batch from one process pinned to one CPU, so the copies land together in whole blocks and the blocks the originals shared can empty.
It covers only the trees the home lists in `config/repack-trees`, and [`configuration.md`](configuration.md#repack-trees-configrepack-trees) owns that file's format.
A file is a candidate when it has not changed for 7 days, is a regular file with one link owned by the running user, and has not been repacked already.
`state` directories, `.git` directories, bare repository object directories, SQLite databases with a `-wal` or `-journal` file, open files, and files that change during the copy are skipped and counted.

`plan` is read-only: it prints each tree's files and bytes and the 1 MiB blocks a run would empty, and without a block sample that estimate prints as unknown.
The estimate takes a sample of the disk's partly used 1 MiB blocks with each block's free 4 KiB blocks, counts a sampled block as emptied when the tree's files hold all of its used blocks, scales the count by the number of partly used blocks over the sample size, and gives a 95% Wilson interval.
Taking the sample reads the filesystem's block bitmaps, which needs root, so it is an operator step.
`run` admits the whole batch once through `fm-disk-room.sh run --expect-write` and runs it under `fm-io-cap --strict`, so a refusal holds the batch with exit 75 and nothing is written.
`run` also holds the one machine-wide pack slot it shares with `fm-pack.sh`, so only one pack or repack writes at a time; it waits a bounded time while another holds the slot and then exits 75 having written nothing, and every command runs at `nice 19` and idle I/O priority.
`fm-pack.sh stop`, or a TERM to `run`, stops a run before its batch with nothing written, or during it at the next file boundary; the `bin/fm-repack.sh` header's "Stopping (run)" owns the details.
Each file is copied beside itself, fsynced, given the original's owner, mode, xattrs, and times, compared byte for byte, and then exchanged with the original in one atomic rename, so a crash leaves each path holding the original or a verified copy.
A write lease, which the kernel grants only while no other process has the file open and breaks when one opens it, is held through the copy and the exchange, so a file open anywhere is skipped and an open during the copy or the exchange keeps the original.
A process that looks up the path just before the exchange and opens it just after the last lease check gets the original after it is unlinked, so its writes would be lost; that window is microseconds wide, and the 7-day rule keeps it to files nobody has written for a week.
`baseline` marks the files a fresh distro import wrote, so the first run after an import does not rewrite data that is already dense.
Nothing schedules a run: no timer, unit, or watcher check starts `fm-repack.sh`, and the script header owns its commands, state files, exit codes, and test seams.

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

The distro root is mounted with online `discard`, so most blocks Linux frees are unmapped for compaction as they are freed.
A 1 MiB block freed in pieces at different times can still stay present, because no single discard covered all of it.
The reclaim-now step trims first, so it returns such blocks too; the startup task runs before the distro starts and does not trim, so it returns only what the reclaimable figure counts.

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

The compaction (reclaim-now) ask goes to the captain only when the watch-line margin path reports low room, as the [`disk-room` skill](../.agents/skills/disk-room/SKILL.md#what-a-low-reading-means-and-who-acts) owns.
A "later" or "not now" answer is final for that reading: nothing is held, re-dated, or recorded as a deferred captain call; the next low reading asks again under the monitor's existing notification cadence.
A growth or runway alert alone is not a compaction ask.

When a low reading says a compaction would help and the startup task is disabled or a restart is not convenient, the captain parks the work running in WSL and runs, elevated:

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\firstmate\fm-wsl-reclaim.ps1 -Now
```

It runs `fstrim -v /` as root inside the distro (bounded to 10 minutes), then `wsl --shutdown`, compacts every recorded file, prints the before and after sizes, and starts the distro again (`-NoRestart` leaves it stopped).
A failed or unavailable trim does not stop the compaction; `wsl-compact-last.txt` records it as `trim=ok`, `failed`, or `not-run` with a one-line `trim_detail`, and `last compaction:` ends with the trim result.
When `wsl.exe` never ran `fstrim` (it failed, timed out, or could not start), `trim_detail` ends with the manual step: run `sudo fstrim -v /` in the distro from a normal shell, then `-Now`.
Because it shuts WSL down, any `.wslconfig` change waiting for a restart takes effect in the same step, and the script prints the memory line now in effect.

### Uninstall

`fm-wsl-reclaim.ps1 -Uninstall`, elevated, removes the task and the ProgramData script, file list, and shadow storage record, and keeps the logs.
Compaction changes no data inside the disk, so there is nothing else to roll back.

## Re-importing the distro

A `wsl --export` and `wsl --import` writes every file densely, which returns the fragmented free space a compaction cannot.
It also gives every file a new inode and birth time, so every status cursor that stores a file identity would reset and the first session start would rescan every status log from the start.
`bin/fm-reimport-rekey.sh` carries those cursors across, once per home:

1. Park the fleet and end the session, so no cursor moves.
2. Before the export, run `bin/fm-reimport-rekey.sh record` in each home.
3. Export, import and start the distro; the operator runs every Windows and WSL step.
4. Before the first session start, run `bin/fm-reimport-rekey.sh apply` in each home, then start the session.

`apply` rekeys a cursor only when its log is still at the same path with the same size and the same bytes up to the cursor, and leaves every other cursor to the normal reset, which rescans that one log.
It refuses while a session, watcher or away daemon holds the home's locks, and a second run changes nothing.
The script header lists the cursor families it covers, the record format, each outcome and the exit codes; its log is `state/.reimport-rekey.log`.

## Consumer interface

`fm-disk-room.sh --interface` prints the latest consumer interface this copy serves, now `fm-disk-room-interface/v3`, while an explicit version query can confirm v1 or v2 support.
A consumer that pins this script accepts exact bytes through the helper-consumer gate: every change to the bytes, with or without a new interface version, waits for each declared consumer to accept that exact version, as [`helper-consumers.md`](helper-consumers.md) owns.
The interface version does not accept anything by itself.
It is a compatibility signal for the consumer's review of each new version, which checks the calls the consumer makes against the version it pins, and it marks a change that drops a pinned version as a planned migration.

The script header is the authoritative list of commands, exit codes, fields with units, and measurement limits for each interface.
V2 adds opt-in job-kind write history and v3 adds the storage admission site policy and token admissions.
Without a policy file, untyped v1 commands, JSON fields, and the v1 and v2 self-tests remain supported unchanged.
An incompatible change requires a new version and removal of support for the broken version; additive functionality may advertise a new latest version while retaining older supported versions.
Human-readable wording not listed in the header may change within a version.

Strict C: terms are a cross-major change for v1 and v2 consumers.
While the storage admission site policy (`FM_DISK_ROOM_POLICY`, by default `config/storage-admission` in the margin's home) sets `c-terms=strict`, or is present but unreadable, `--interface v1|v2` and `--self-test v1|v2` exit 1, and the commands a v1 or v2 consumer calls read the strict C: terms, which can admit more than the older terms.
- The trigger is writing such a policy file for a copy that a v1 or v2 consumer runs.
- The owner of the migration is each such consumer's declared `owner=`, which moves the consumer's calls and self-test to v3 and accepts that version through its own review.
- Readers move first: write the strict policy only after every v1 or v2 consumer of that copy has moved, under [`handoff-coverage.md`](handoff-coverage.md#versions)'s versioning rule.

Before trusting a new copy, a consumer runs the self-test for its pinned version.
CI already runs every served version's self-test on any change to this script or a file it pins, as [`helper-consumers.md`](helper-consumers.md#the-contract-self-test-gate) owns.
Each supported version has a hermetic probe using temp state and Linux-only readings, without Windows processes or reservations outside that temp state.
A probe fails explicitly if its required measurement is unavailable.

A consumer that pins bytes may run them as `bash -c TEXT PATH ARG...`, with PATH the file it hashed.
The script then finds its sibling helpers beside PATH, never in the working directory, and runs `bin/fm-vhdx-bat.py` only from bytes matching the digest embedded in `fm-disk-room.sh`, so a pin on `fm-disk-room.sh` covers the reader and a missing or changed reader leaves reclaimable unknown.
`--self-test` works in that mode too and probes the same bytes.

`tests/fm-disk-room.test.sh` checks every interface through the executable, including failed writers, capacity boundaries, unreadable counters, concurrent attempts, append failures and recovery, corrupt history, and the unchanged v1 contract.

## Limits

- Sparse mode (`wsl --manage <distro> --set-sparse true`) is not used: WSL 2.5.6 and later require `--allow-unsafe` for it because of potential data corruption, a sparse file cannot be compacted by diskpart, and it frees space at the same 1 MiB granularity.
- Fragmented free space that already exists stays allocated until the files around it are rewritten: moving bulk data off the disk, [re-importing the distro](#re-importing-the-distro), or repacking cold trees with `fm-repack.sh`.
- A reservation counts its whole expected write until the job exits, while the part already written also shows as used space, so room reads low (never high) while a reserved job runs.
- The monitor is WSL-aware but works anywhere: without a Windows drive mount it measures the Linux filesystem alone.
