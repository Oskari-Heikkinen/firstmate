# External SSD for fetched results

On a WSL laptop whose Windows drive is nearly full, fetched results belong on an external SSD when one is plugged in, with the Windows drive as the fallback.
`bin/fm-storage.sh` detects the SSD, prepares it, and publishes the choice in one machine-local file that every fetcher reads; its header owns the exact commands and environment settings.
Plugging the SSD in is the only step anyone takes after the one-time setup below.

## One-time setup

1. Mount rule (root, once): WSL mounts drives only when the distro starts, so a drive plugged in later gets no `/mnt/<letter>` until the laptop restarts or root mounts it.
   A narrow sudoers rule lets the check mount exactly `mount -t drvfs <L>: /mnt/<l> -o uid=<uid>,gid=<gid>` (and `umount /mnt/<l>`, `umount -l /mnt/<l>`) for letters D to H without a password, with the matching `/mnt/<l>` folders created; see [Mount rule](#mount-rule).
   Without it everything still works except that a hot-plugged SSD reads as `not-mounted` until the next restart.
2. Timer (user, no root): `bin/fm-storage.sh install-timer --fallback <C: template> --notify <status file>` writes `~/.config/lattice-storage/storage.conf` and enables `fm-storage.timer`, which runs `check` every 5 minutes at `Nice=19` with idle IO.
   The fallback template is the directory fetched results use today, with `{task}` in place of the task name.

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
5. First time only: create `<L>:\lattice-data\tetjet-results` and `<L>:\lattice-data\archive`, write the marker `lattice-data\.lattice-storage-id` holding the volume id, and measure sequential write speed with one 1 GiB temp file (deleted after); a failed measurement is retried on the next check.
6. Probe a small write, then publish the results-root file atomically.

Each change of state appends one `note [at=<epoch>]: SSD storage <state>: ...` line to the notification file; an unchanged state never notifies twice, and the first reading of an absent SSD is a silent baseline.
`bin/fm-disk-room.sh status` also reports the SSD's free and total space and which root is active.

## The results-root file (`lattice-storage-results-root/v1`)

Path: `~/.config/lattice-storage/results-root`, written only by `fm-storage.sh check`, atomically.

Line 1 is the only line a fetcher needs: the absolute directory template for fetched results, containing `{task}`.
Line 2 is exactly `format=lattice-storage-results-root/v1`.
Later lines are `key=value` facts: `active` (`ssd` or `c`), `state`, `reason`, `checked_at`, `fallback`, and for a found SSD `ssd_letter`, `ssd_id`, `ssd_fs`, `ssd_free_bytes`, `ssd_total_bytes`, `write_mib_s`, plus `ssd_marker` and `archive` when active.

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
| `unreadable` | the Windows listing failed or timed out on 3 consecutive checks; until then a failed check keeps the last published state and root and does not notify, and any readable listing resets the count |

Every state except `ok` has `active=c` and line 1 equal to `fallback`.
A format that changes line 1's meaning uses a new file name, never a new `format=` value in this file.

## Reader rules

On every fetch, before choosing the destination, a reader either runs `bin/fm-storage.sh root <task>` or applies the same rules itself:

1. A missing or unreadable file, or line 2 other than the v1 format: use the C: path.
2. Line 1 must be an absolute path containing `{task}`; replace `{task}` with the task name.
3. When `active=ssd`, also require `checked_at` no older than 30 minutes and the `ssd_marker` file present (so an empty `/mnt/<l>` folder on the Linux disk is never mistaken for the SSD); otherwise use the C: path.
4. Never move what is already on either side; a fetch finishes where it started.

On any doubt, use the C: path: it is always correct, just fuller.
