#!/usr/bin/env bash
# fm-repack.sh - rewrite the cold files of a home's listed trees in one
# time-ordered batch, so they sit together in whole 1 MiB blocks instead of
# holding partly used ones open. docs/disk-room.md "Repacking cold trees" owns
# why and when; this header owns the mechanics. Linux and ext4 only.
#
# Usage:
#   fm-repack.sh plan --home HOME [--sample FILE]
#       Read-only. Prints one line per tree and one for all trees as one batch:
#       files, bytes, and the 1 MiB blocks a run would empty, estimated by the
#       F1 method from FILE, a root-run block sample (lines "bitmaps read: N
#       partly used 1 MiB blocks" and "sample block B mib M holes H"); without
#       --sample that estimate prints as unknown. A last line counts skips.
#   fm-repack.sh run --home HOME [--max-bytes SIZE]
#       Rewrites every candidate of every listed tree as one batch, oldest
#       mtime first, under one fm-disk-room.sh admission sized to the batch
#       and under fm-io-cap --strict. --max-bytes (bytes, or with K, M, G, T)
#       takes only the oldest candidates up to SIZE. Nothing schedules a run.
#       A run holds the one machine-wide pack slot it shares with fm-pack.sh
#       (a flock on ~/.cache/fm-pack/slot.lock, taken after the home's lock)
#       from before its scan until its batch ends. While another pack or
#       repack holds it, the run waits at most FM_PACK_SLOT_WAIT seconds,
#       saying so once with the holder's line, then exits 75. Line 1 of the
#       slot names the holder in fm-pack.sh's format, so `fm-pack.sh stop`
#       stops a run too.
#   fm-repack.sh baseline --home HOME [--at EPOCH]
#       Records EPOCH (default now) in HOME/state/fm-repack/baseline: files
#       whose inode last changed at or before it are skipped, because a
#       re-import just wrote them densely.
#
# Trees: HOME/config/repack-trees, one directory per line, absolute,
# relative to HOME, or ~/; blank lines and # comments ignored. A missing or
# empty file means nothing to do. A line that is not a directory, or is
# inside a state/ directory, refuses the whole command. Agent transcripts are
# covered only when the file lists their directory.
#
# Candidates: regular files with mtime 7 days old or more, size above 0, one
# link, owned by the running user, on the tree's own filesystem, not already
# repacked. Skipped and counted: directories named state, .git directories,
# a bare repository's objects directory, SQLite files with a -wal or
# -journal beside them (and those -wal, -journal and -shm files), files
# opened by any process (a write lease is refused), files whose size, mtime
# or ctime changes before the exchange, files with inode flags such as
# immutable or append-only, and files whose directory refuses a new file.
#
# Per file (run): copy to a temporary name in the same directory, fsync, set
# owner, mode, xattrs, atime and mtime, fsync, compare every byte and that
# metadata, then exchange the two names atomically (renameat2
# RENAME_EXCHANGE) and remove the temporary name, which now holds the
# original. A crash at any point leaves the path holding the original or the
# verified copy; the next run removes the temporary file it journalled. A
# rerun is a no-op for files already repacked (inode plus mtime ledger).
#
# Exit codes:
#   0   done, or nothing to do;
#   1   a file failed (an I/O error, a copy that differs) and the batch
#       stopped there, the batch did not start, or it was stopped by a signal;
#       every path holds its original or its verified copy;
#   2   usage, configuration or precondition refusal, nothing written;
#   75  held, nothing written: admission refused the batch's write, another
#       run for this home holds the lock, or the pack slot stayed held.
#
# Stopping (run): SIGTERM or SIGINT before the batch starts ends the run at
# once, after any recovery in progress, with "stopped by SIG...; nothing was
# written" and exit 1. During the batch, which runs in its own process group,
# the run forwards SIGTERM to that group; the batch stops at its next file
# boundary and reports "interrupted", and 20 s later the group is killed,
# which the per-file protocol survives like a crash.
#
# Every command runs at nice 19 and ionice -c3; without ionice it refuses.
#
# State, all under HOME/state/fm-repack/: lock; log (append-only, one UTC
# line per run, hold, refusal, recovery and non-routine skip); repacked.tsv
# (inode, mtime_ns of every copy, compacted after a complete scan);
# journal.jsonl (temporary names in flight); baseline; run-<epoch>-<pid>/
# (this run's batch list, removed when the run reports).
#
# Environment (all optional):
#   FM_REPACK_NOW         epoch to treat as now (tests);
#   FM_REPACK_DISK_ROOM   fm-disk-room.sh to admit with (default: beside this);
#   FM_IO_CAP             fm-io-cap command (default: fm-io-cap on PATH);
#   FM_PACK_SLOT_LOCK     the machine-wide pack slot's lock file (tests);
#   FM_PACK_SLOT_WAIT     seconds to wait for the pack slot before exit 75
#                         (default 900; 0 does not wait);
#   FM_REPACK_TEST_CRASH  before-swap or after-swap: exit there with no
#                         cleanup (tests);
#   FM_REPACK_TEST_DURING_COPY  command run with the path after the copy,
#                         before the compare (tests).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'fm-repack: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
  plan|run|baseline) ;;
  -h|--help|help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
[ "$(uname -s)" = Linux ] || die "runs only on Linux (needs file leases and renameat2)"
command -v python3 >/dev/null 2>&1 || die "needs python3"
command -v ionice >/dev/null 2>&1 || die "needs ionice: every repack runs at idle I/O priority"

exec nice -n 19 ionice -c3 python3 -I "$SCRIPT_DIR/fm-repack.py" "$@"
