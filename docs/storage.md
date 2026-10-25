# External SSD for fetched results

On a WSL laptop whose Windows drive is nearly full, new large fetched results must explicitly request mandatory D: admission.
Every other caller also writes only to the external SSD: when it is not usable, writers wait, and no command names a C: or Linux fallback.
`bin/fm-storage.sh` detects the SSD, prepares it, and publishes the choice in one machine-local file that every fetcher reads; its header owns the exact commands and environment settings.
Plugging the SSD in is the only step anyone takes after the one-time setup below.

## One-time setup

1. Mount rule (root, once): WSL mounts drives only when the distro starts, so a drive plugged in later gets no `/mnt/<letter>` until the laptop restarts or root mounts it.
   A narrow sudoers rule lets the check mount exactly `mount -t drvfs <L>: /mnt/<l> -o uid=<uid>,gid=<gid>` (and `umount /mnt/<l>`, `umount -l /mnt/<l>`) for letters D to H without a password, with the matching `/mnt/<l>` folders created; see [Mount rule](#mount-rule).
   Without it everything still works except that a hot-plugged SSD reads as `not-mounted` until the next restart.
2. Timer (user, no root): `bin/fm-storage.sh install-timer --notify <status file>` writes `~/.config/lattice-storage/storage.conf` and enables `fm-storage.timer`, which runs `check` every 5 minutes at `Nice=19` with idle IO.
   The removed `--fallback` option exits 2, `FM_STORAGE_FALLBACK` is ignored, and a `fallback=` line left in an older `storage.conf` is ignored, so none of them can bring back a C: destination.

## Mount rule

The rule is installed once by hand; no script installs it.
Save these five lines in a file inside WSL (for example `~/lattice-storage.sudoers`), with `<user>`, `<uid>` and `<gid>` replaced by the WSL user's name and the output of `id -u` and `id -g`:

```
<user> ALL=(root) NOPASSWD: /usr/bin/mount -t drvfs D\: /mnt/d -o uid\=<uid>\,gid\=<gid>, /usr/bin/umount /mnt/d, /usr/bin/umount -l /mnt/d
<user> ALL=(root) NOPASSWD: /usr/bin/mount -t drvfs E\: /mnt/e -o uid\=<uid>\,gid\=<gid>, /usr/bin/umount /mnt/e, /usr/bin/umount -l /mnt/e
<user> ALL=(root) NOPASSWD: /usr/bin/mount -t drvfs F\: /mnt/f -o uid\=<uid>\,gid\=<gid>, /usr/bin/umount /mnt/f, /usr/bin/umount -l /mnt/f
<user> ALL=(root) NOPASSWD: /usr/bin/mount -t drvfs G\: /mnt/g -o uid\=<uid>\,gid\=<gid>, /usr/bin/umount /mnt/g, /usr/bin/umount -l /mnt/g
<user> ALL=(root) NOPASSWD: /usr/bin/mount -t drvfs H\: /mnt/h -o uid\=<uid>\,gid\=<gid>, /usr/bin/umount /mnt/h, /usr/bin/umount -l /mnt/h
```

Install it once from a normal (not admin) PowerShell, with `<distro>` the WSL distro name (`wsl -l`) and `<file>` the file's absolute WSL path:

```
wsl -d <distro> -u root -- sh -c 'visudo -c -f <file> && install -m 0440 -o root -g root <file> /etc/sudoers.d/lattice-storage && mkdir -p /mnt/d /mnt/e /mnt/f /mnt/g /mnt/h'
```

Check it from WSL with `sudo -n -l`: the five lines are listed and no password is asked.
Undo it with `wsl -d <distro> -u root -- rm /etc/sudoers.d/lattice-storage`.

## What a check does

1. List Windows volumes and disks with `powershell.exe Get-Volume` and `Get-Disk` (no admin, 30 s limit per attempt, up to 3 attempts 5 s and 15 s apart, because WSL interop can fail briefly under load); `powershell.exe` comes from `FM_STORAGE_POWERSHELL`, else `PATH`, else `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/`, so the timer finds it without WSL interop on its `PATH`.
2. The SSD is a lettered volume other than C:, Fixed or Removable, of at least 1.5 TB; once set up, its remembered volume id wins, so a small USB stick is never picked.
3. NTFS or exFAT is usable; a RAW, unformatted, or other filesystem is reported and nothing is ever written to it, because formatting needs the captain.
4. Mount it through the rule with `sudo -n` when `/mnt/<l>` is not mounted; a refusal is `not-mounted`, never a password prompt.
5. Create `<L>:\lattice-data\tetjet-results`, `<L>:\lattice-data\research` and `<L>:\lattice-data\archive` when missing; first time only, write the marker `lattice-data\.lattice-storage-id` holding the volume id, and measure sequential write speed with one 1 GiB temp file (deleted after); a failed measurement is retried on the next check.
6. Probe a small write, then publish the results-root file atomically.

When the listing fails, the check first proves the remembered SSD without Windows: the remembered letter's `/mnt/<l>` is in the mount table, its marker names exactly the remembered volume id, its device number equals the published `ssd_device`, and a small write probe in `lattice-data` succeeds and is removed.
When all four pass, the check continues as above with free and total space from the mount's statfs, publishes `state=ok` with `ssd_identity=marker`, and its reason says the identity came from the marker; any readable listing or such a check resets the unreadable count.
When any of them fails, the check counts as unreadable and its reason names the failed check.

Each change of state appends one `note [at=<epoch>]: SSD storage <state>: ...` line to the notification file; an unchanged state never notifies twice, and the first reading of an absent SSD is a silent baseline.
`bin/fm-disk-room.sh status` also reports the SSD's free and total space and which root is active.

## The results-root file (`lattice-storage-results-root/v1`)

Path: `~/.config/lattice-storage/results-root`, written only by `fm-storage.sh check`, atomically.

Line 1 is the only line a fetcher needs: in state `ok` the absolute directory template for fetched results, containing `{task}`; in every other state the word `unavailable`, which no reader rule accepts as a directory.
Line 2 is exactly `format=lattice-storage-results-root/v1`.
Later lines are `key=value` facts: `active` (`ssd`, or `c` meaning no usable SSD), `state`, `reason`, `checked_at`, and for a found SSD `ssd_letter`, `ssd_id`, `ssd_fs`, `ssd_free_bytes`, `ssd_total_bytes`, `write_mib_s`, plus `ssd_marker`, `archive`, and `ssd_device` (the Linux filesystem device number) when active, and `ssd_identity=marker` when the identity came from the marker because the Windows listing failed.
Readers treat that `ok` exactly like any other.

| state | meaning |
|---|---|
| `ok` | SSD usable; line 1 is `/mnt/<l>/lattice-data/tetjet-results/{task}` |
| `absent` | no SSD in Windows (a stale mount of a removed SSD is released unless another volume now holds its letter) |
| `not-mounted` | SSD in Windows but not mounted in WSL and the rule is missing or refused |
| `stale-mount` | SSD removed but its mount could not be released |
| `full` | SSD free space under the minimum (50 GiB, `min_free`) |
| `raw` | RAW, unformatted, or unsupported filesystem; nothing written |
| `unwritable` | folders, marker, or the write probe failed |
| `ambiguous` | several large volumes and none is the remembered SSD, or the marker names another volume |
| `unreadable` | the Windows listing failed or timed out, and the marker check failed, on 3 consecutive checks; until then a failed check keeps the last published state and root and does not notify, and any readable listing resets the count |

Every state except `ok` has `active=c` and line 1 `unavailable`; writers wait until a check publishes `ok`.
A file written by an older `fm-storage.sh` may still carry a `fallback=` key and a C: line 1 in those states; readers ignore `fallback=` and treat any state but `ok` as a wait.
A format that changes line 1's meaning uses a new file name, never a new `format=` value in this file.
Line 1 still means the one directory to write to, or none: a v1 reader's rule 2 already refuses `unavailable`, so it keeps this file name.

## Reader rules

On every fetch, before choosing the destination, a reader either runs `bin/fm-storage.sh root <task>` or applies the same rules itself:

1. A missing or unreadable file, or line 2 other than the v1 format: wait.
2. Require `active=ssd` and `state=ok`; otherwise wait.
3. Line 1 must be an absolute path containing `{task}`; replace `{task}` with the task name.
4. Also require `checked_at` no older than 30 minutes and the `ssd_marker` file present (so an empty `/mnt/<l>` folder on the Linux disk is never mistaken for the SSD); otherwise wait.
5. Never move what is already on either side; a fetch finishes where it started.

On any doubt `root` exits 75 with one `wait:` reason on stderr and prints no path, using the refusal tokens of [Mandatory bulk admission](#mandatory-bulk-admission); a reader treats exit 75 as wait, never as a cue to pick its own C: or Linux path.
These rules are not admission for a new D:-required delivery.

Every worker Firstmate launches starts with `LATTICE_STORAGE_TOOL` set to the absolute path of the launching home's `bin/fm-storage.sh`, because that script is not on a worker's `PATH` and lattice-research resolves its storage tool from this variable.
`bin/fm-spawn.sh`'s header owns when the export is carried.

## Mandatory bulk admission

For a **new** large delivery, use the publisher's integrated interface:

```sh
bin/fm-storage.sh bulk-root TASK --name DELIVERY --download 4G --expanded 20G --packaging 8G --pid "$$"
```

The command prints only the verified D: destination on success and holds a reservation through the existing disk-room owner.
All three sizes are required, can be zero, and describe bytes that coexist at the peak: downloaded bytes, expanded **allocated** bytes (including exFAT allocation inflation), and the packaging duplicate.
Do not supply compressed or logical tree size as the expanded allocation estimate.
Use a unique delivery name and persist the successful root in the existing delivery pin before writing payloads.
Keep incomplete payloads beside the destination on D:, not in a Linux temporary directory.
Additional Linux scratch must have its own ordinary disk-room reservation.
The default D: margin is 50 GiB after all outstanding D: reservations; `FM_DISK_ROOM_BULK_MARGIN` overrides it.
Reserve any other simultaneous allowance, such as a recovery archive, in that same pool.

| exit | result |
|---|---|
| `0` | stdout contains exactly the D: root, with the complete peak reserved |
| `75` | no root on stdout and one `wait:` reason on stderr; do not start or substitute C: |
| `2` | invalid command/options/size or inability to write admission records; no delivery should start |

Waiting callers may retry when the concrete unavailable condition clears.
Storage refusal reason tokens are `missing-publication`, `invalid-publication`, `storage-unavailable: <state>: <published reason>`, `wrong-volume`, `wrong-filesystem`, `stale-publication`, `wrong-root`, `missing-marker`, `wrong-volume-identity`, `wrong-mount-identity`, and `wrong-filesystem-identity`.
Capacity refusals use `cannot-measure-D`, `insufficient-space: <room details>`, or `reservation-exists: <name>`.
A live reservation name is never silently replaced by a new bulk admission.

Mandatory verification requires a fresh non-future v1 publication, active/ok D:, NTFS or exFAT, the expected non-symlink results directory, matching publication/marker/remembered volume IDs, a live D: DrvFS/9p mount, and the current device matching the published `ssd_device` while differing from Linux root and C:.
An old publication without `ssd_device` must be refreshed with the existing `check` command before mandatory admission.
Mandatory verification reads only the state, identity and freshness facts; it never takes line 1 alone as permission to write.
Verification is read-only and does not mount, initialize, probe, or create D: directories.
A copied marker in an empty Linux-backed `/mnt/d` cannot authorize bulk.
This is admission, not protection against unplug during a write: the writer must preserve its root and handle I/O errors without fallback.

`bin/fm-storage.sh verify-bulk-root TASK` exposes the same read-only verification without a reservation, with exits 0/75/2 as above; its output alone does not admit a write.
`bin/fm-disk-room.sh reserve-bulk DELIVERY --task TASK --download SIZE --expanded SIZE --packaging SIZE [--pid PID] [--ttl SECONDS]` is the underlying admission interface and prints the same root.
Both use the publisher configuration; `FM_STORAGE_RESULTS_ROOT` overrides its publication, and disk-room's existing `FM_DISK_ROOM_RESULTS_ROOT` takes precedence for disk-room admission.
The integrated `bulk-root` options must start with `TASK --name DELIVERY`.

PID reservations lapse when that exact process exits; without a PID they expire after `--ttl` (default 43200 seconds).
Choose an owner process that remains alive for the entire delivery, or explicitly maintain an adequate TTL across multi-process jobs.
After completion or abandonment, release with `bin/fm-disk-room.sh release-bulk DELIVERY`, which works even with D: unplugged.
The disk-room watcher check alerts when D: runway after these reservations falls under its floor or when mandatory bulk substituted Linux storage; [disk-room.md](disk-room.md#growth-and-runway-alerts) owns those alerts.
The existing reservation owner stores D: pools under `reservations-d/<filesystem-device>` in its existing state directory, apart from the unchanged Linux/C: `reservations` pool.
Every admission is serialized by the existing owner lock, reads actual D: free space, and subtracts only that filesystem's live D: reservations.
The full reservation remains charged even as written bytes reduce free space, conservatively counting those bytes twice until release.
No new index or service is involved.

Already-started deliveries must use their recorded root, including C: pins, without reselecting or rewriting them through this interface.
This change does not automatically classify existing callers as bulk or deploy consumer changes.
Regression coverage is in `tests/fm-storage.test.sh` and `tests/fm-disk-room.test.sh`.

## Named roots

`root`, `verify-bulk-root` and `bulk-root` take `--root ROOT`, written before TASK, naming one directory under `/mnt/d/lattice-data`:

| ROOT | D: directory | `root --root ROOT` checks |
|---|---|---|
| `tetjet-results` (default) | `tetjet-results/TASK` (line 1's template) | the reader rules |
| `research` | `research/TASK` | the same checks as `verify-bulk-root --root research` |

Any other name exits 2.
Without `--root`, every command and its output is unchanged.
The results-root file is unchanged: line 1 stays the `tetjet-results` template, and every root shares its D: publication, marker, mount and device checks; the named root's own directory must exist as a real directory on that device.
The check creates `research` beside `tetjet-results`, so it exists after the first check that runs this version.

No form falls back: on anything but a verified D: each exits 75 with one `wait:` reason and prints no path.
A writer whose records pin the D: root calls `verify-bulk-root --root research TASK`, or `bulk-root --root research TASK --name ...` to also reserve its peak; `root --root research TASK` gives the same answer as `verify-bulk-root`.

`bulk-root --root research` verifies the research directory, admits the peak through `fm-disk-room.sh reserve-bulk` in the same D: reservation pool as `tetjet-results`, and prints the research directory.

## Packing cold data

A finished directory tree that no reader opens often (a unit) can live on D: as one read-only SquashFS image instead of many small files.
`bin/fm-pack.sh`'s header owns the steps, the sidecar fields and the exit codes; this section owns when to use it and the retention rule.

```sh
bin/fm-pack.sh pack [--root ROOT] TASK UNIT SRC
bin/fm-pack.sh verify D_ROOT/UNIT.sqfs [--against SRC]
bin/fm-pack.sh restore D_ROOT/UNIT.sqfs DEST
bin/fm-pack.sh release D_ROOT/UNIT.sqfs SRC --accepted-by WHO [--note TEXT] [--ref FILE]... [--also PATH]...
```

`pack` admits its packaging peak through `bulk-root --name pack-UNIT`, so it waits with exit 75 on anything but a verified D: with room, and writes nothing then.
It lists and hashes SRC, builds the image in `D_ROOT/.incoming`, refuses with exit 1 if SRC changed while it was packed, verifies the staged image, and only then renames the image and its sidecars into `D_ROOT`.
It always releases its reservation and prints one `fm-pack-receipt/v1` line on success.
A unit is never overwritten: an existing `UNIT.sqfs` or stale staging for UNIT exits 2.

Each image keeps four sidecars beside it: `UNIT.sqfs.sha256`, `UNIT.members.sha256`, `UNIT.tree.tsv` and `UNIT.json` (`fm-pack-unit/v1`).
They are the whole manifest; there is no index.
`verify` and `restore` also read lattice-research fetch-arrival units (`tj-fetch-arrival-unit/v2`), which `verify --against` and `release` refuse; any other unit format is refused.
`UNIT.json` records `packed_at` and `verified_at` in epoch seconds.

`verify` checks the image sha256, then reads the image afresh through a new squashfuse mount and compares every member.
Without squashfuse, fusermount3 and a usable `/dev/fuse`, `pack` and `verify` refuse with exit 2 before any work; `FM_PACK_MOUNT=unsquashfs` reads each member with its own `unsquashfs -cat` instead, which is roughly quadratic in the file count and meant for tests and hosts without FUSE.
`pack` also refuses with exit 2 when the D: root is SRC or inside it, or SRC is inside its `.incoming`.
`--against SRC` also requires SRC to still match the tree list.
`restore` unpacks into a new DEST behind an ordinary `fm-disk-room.sh run` admission for the logical size and checks every member there.
Packing is cheap to undo: the source stays where it is until its owner releases it under R2.

### Retention rule R2

The home that owns the data releases a packed source as soon as its pack verifies, with `fm-pack.sh release`, the only Firstmate command that deletes a packed source.
This holds for raw D: trees and for Linux copies alike, and needs no per-unit approval.
`release` deletes SRC only when every guard holds, else it refuses and deletes nothing.
Every filesystem read feeding a guard or its receipt must complete successfully: a failed or partial census, listing, accounting or use check is unknown, not empty, even when its output matches the expected tree.
Such a failure names the failed check, leaves the whole source (renaming it back if necessary), and writes no released receipt.
The guards are:
1. `pack` committed the unit, and the image and SRC pass the same check as `fm-pack.sh verify UNIT.sqfs --against SRC`, run just before the removal.
2. The owner home has accepted that its readers work from the image (mounted or restored), recorded with `--accepted-by` and an optional `--note`.
3. No reference the owner names with `--ref` (a ledger tree literal, a delivery pin) still contains SRC's path.
4. Nothing inside SRC is a mount point, the working directory or an open file of a live process, or held by a live disk-room reservation for the unit.
5. Every hard-link name of a file in SRC is inside SRC or released in the same call with `--also`, so the bytes the receipt reports are really freed.
6. The release window has passed; it is zero, so a verified pack is releasable at once.

The window is configurable (`--window`, or `FM_PACK_RELEASE_WINDOW` in seconds) and keeps the `verified_at` plus window check when it is non-zero.
It was 7 days (604800 seconds) until the storage ruling of 2026-10-18 set it to zero to free space fast; returning to a non-zero window is a new decision.

`release` renames SRC aside in its own parent, re-checks the tree list, removes it, and leaves `SRC/STORED.md` naming the image.
It prints one `fm-pack-release/v1` receipt line with the bytes freed, writes `UNIT.release.json` beside the image, and appends one line per release, refusal or wait to `fm-pack-release.log` there, so owners report GiB freed per release from the receipt or the record.
`bin/fm-pack.sh`'s header owns the guards' exact checks, the record fields and the exit codes.

A single copy on D: is accepted for now; there is no second copy of the image.
R2 covers the `tetjet-results` trees, `moved/`, the `linux-cold-archive` mirror, `tetjet-prep` once released, and Linux sources packed to D:.

Regression coverage is in `tests/fm-pack.test.sh`.
