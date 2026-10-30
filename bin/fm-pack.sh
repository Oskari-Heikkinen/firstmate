#!/usr/bin/env bash
# fm-pack.sh - pack one finished, quiet directory tree (a unit) into one
# read-only SquashFS image on the external SSD (D:), verify it, and restore it.
# docs/storage.md "Packing cold data" owns when to pack and the retention rule;
# this header owns the mechanics.
#
# Usage:
#   fm-pack.sh pack [--root ROOT] TASK UNIT SRC
#       Pack the directory SRC as UNIT under fm-storage.sh's D: root for TASK
#       (ROOT tetjet-results, the default, or research):
#         1. census: files, logical bytes, and the bytes removing SRC would
#            free (a file counts only when all its hard links are inside SRC);
#         2. admission: fm-storage.sh bulk-root --name pack-UNIT with
#            --packaging logical + 1% + 1 MiB, held for this process only;
#         3. lists in R/.incoming: UNIT.members.sha256 (sha256sum of every
#            regular file, ./-relative, sorted) and UNIT.tree.tsv (kind, size,
#            mode, links, mtime, link target, path of every entry);
#         4. mksquashfs -comp gzip -keep-as-directory, so the image root holds
#            basename(SRC)/, then UNIT.sqfs.sha256;
#         5. the tree list again: any change to SRC since step 3 refuses;
#         6. verify (below) on the staged image;
#         7. UNIT.json, then commit: every file renamed from .incoming into R,
#            the image last but one and UNIT.json last;
#         8. release-bulk pack-UNIT, on success and on every failure.
#       Prints one line on success:
#         fm-pack-receipt/v1 image=PATH sha256=HEX files=N logical=BYTES frees=BYTES verified_at=EPOCH sidecar=PATH
#       Exit codes:
#         0   packed and verified, the unit committed;
#         1   refused after admission (SRC changed, the staged image failed
#             verify, a tool failed), nothing committed and this run's
#             staging removed;
#         2   usage or precondition refusal, nothing written: bad
#             arguments, a name SRC holds that the lists cannot carry (a
#             newline or a backslash), R equal to SRC or inside it, SRC inside
#             R/.incoming, no usable FUSE mount in the default mode, UNIT
#             already at R, or stale staging for UNIT in R/.incoming;
#         75  wait on disk room (D: unavailable, low room, or pack-UNIT
#             already reserved) or on the pack slot, nothing written;
#         143 or 130  stopped by SIGTERM (fm-pack.sh stop) or SIGINT before
#             the commit, this run's staging removed; a stop during the
#             commit is held until the unit is whole, then the run ends 0
#             (see "Stopping a holder").
#   fm-pack.sh verify IMAGE [--against SRC]
#       IMAGE is R/UNIT.sqfs with its sidecars beside it. Checks the image
#       sha256, then reads the image afresh: every member's sha256 and the
#       regular-file count must match UNIT.members.sha256. With --against, SRC
#       must also still match UNIT.tree.tsv, the check to repeat before an
#       owner removes the source. Exit 0 verified, 1 a mismatch, 2 misuse,
#       75 the pack slot stayed held.
#       verify, restore and release read a unit whose UNIT.json format is
#       fm-pack-unit/v1 or tj-fetch-arrival-unit/v2 (a lattice-research fetch
#       arrival, whose members list carries paths without ./), and refuse any
#       other or missing format with exit 2 before any work. An arrival unit's
#       tree list is not fm-pack's, so --against and release refuse it with 2.
#   fm-pack.sh verify-tar IMAGE --tar TAR --expect EXPECTATION.json
#       The G5-equivalent parity check of a transit tar against the image
#       built from it (docs/storage.md owns when a caller runs it). Read-only:
#       it extracts, writes and deletes nothing, and a pass is not permission
#       to delete the tar. bin/fm-pack-parity.py does the work:
#         1. EXPECTATION.json (at most 64 MiB), made by the caller from its
#            committed records, is one closed JSON object:
#              {"format": "fm-pack-tar-expectation/v1",
#               "tar_sha256": HEX, "image_sha256": HEX,
#               "layout": {"image_prefix": PREFIX, "tar_directories": DIRS},
#               "members": [{"name": NAME, "bytes": N, "sha256": HEX}, ...]}
#            HEX is 64 lowercase hex digits; at most 262144 members; each
#            NAME (and a non-empty PREFIX) is unique, relative, UTF-8, at most
#            4095 bytes, with no empty, . or .. component, no control
#            character or backslash, and is no other member's directory.
#            PREFIX is "" when the image root holds the members (a phase-D
#            sqfstar image) or the directory holding them (basename(SRC) for
#            a pack tree); DIRS is "none" or "ancestors" (the tar may carry
#            entries for its members' directories);
#         2. TAR, opened without following a link, is read once in 1 MiB
#            chunks: every byte, padding and trailing zeros included, feeds
#            its sha256, and every entry is parsed without extraction. Only
#            POSIX ustar and GNU headers with valid checksums, regular files
#            and, by DIRS, directories are admitted; one GNU long name (L,
#            GNU headers) or one PAX header (x, POSIX headers; keys path size
#            mtime atime ctime uid gid uname gname, each once) may precede an
#            entry, whose own header name must be a prefix of the long path,
#            and a header size may differ from a PAX size only as 0 above 8 GiB.
#            Links, other types, unsafe or duplicate names, non-zero padding,
#            a missing end-of-archive marker and any non-zero byte after it
#            are refused;
#         3. the tar's sha256 must equal tar_sha256, and its regular members
#            must be exactly the expected ones, with equal bytes and sha256;
#         4. IMAGE, opened the same way, must hash to image_sha256; then a
#            fresh view of that same opened file (a new squashfuse mount, or
#            unsquashfs -lln and -cat with FM_PACK_MOUNT=unsquashfs) must hold
#            exactly the expected members under PREFIX, their directories and
#            PREFIX's, and nothing else, with equal bytes and sha256;
#         5. after FM_PACK_TEST_BEFORE_RECHECK, each opened file and the name
#            it was opened by must still have the device, inode, size, mtime
#            and ctime it had when opened, so the caller binds the pass to
#            the inode it holds.
#       Prints one line on success, stderr empty apart from the pack slot's
#       one waiting line (see "Machine-wide pack slot" below):
#         fm-pack-tar-parity/v1 tar_sha256=HEX image_sha256=HEX members=N
#       Exit codes, stdout empty on every non-zero code:
#         0   parity holds;
#         1   one line fm-pack: refused: G5: CODE[: DETAIL], CODE one of
#             tar-digest, image-digest; tar- or image-extra-member,
#             -missing-member, -member-size, -member-digest, -identity-changed,
#             -read; tar-checksum, -header, -unsupported, -link, -directory,
#             -unsafe-name, -duplicate, -padding, -truncated, -trailing-data;
#             image-member-type; expectation-read; interrupted (SIGTERM or
#             SIGINT); internal-error;
#         2   one refusal line: misuse, an input missing or not a regular
#             file, or an invalid or unsupported expectation;
#         75  one line fm-pack: wait: storage-offline: REASON, only when an
#             input failed to open or read and fm-storage.sh health --volume d
#             then exited 75 with the line offline REASON; any other answer
#             keeps the exit 1 or 2 refusal, so unknown is never parity; or
#             the pack slot's fm-pack: wait: pack-slot-busy: line, before any
#             work.
#       It has no deadline of its own: the caller's timeout bounds a run, and
#       a run killed by SIGKILL can leave its squashfuse mount, as verify can.
#   fm-pack.sh restore IMAGE DEST
#       Check the image sha256, then fm-disk-room.sh run --name restore-UNIT
#       --expect-write <logical bytes> -- unsquashfs -d DEST IMAGE, then the
#       member check on DEST/basename(SRC). DEST must not exist yet. Exit 0
#       restored and checked, 75 refused for room or the pack slot stayed
#       held, 1 a failure, 2 misuse; a failed or stopped restore leaves what
#       it wrote in DEST.
#
#   fm-pack.sh release IMAGE SRC --accepted-by WHO [--note TEXT] [--ref FILE]...
#                      [--also PATH]... [--window SECONDS]
#       Delete one packed source (retention rule R2), run by the home that
#       owns it. SRC must be the source UNIT.json records, and must hold
#       neither IMAGE nor its sidecars. Every guard runs, cheapest first:
#         1. window: now >= verified_at + SECONDS (--window, else
#            FM_PACK_RELEASE_WINDOW, else 0, the zero window of R2);
#         2. acceptance: --accepted-by names who accepted that its readers
#            work from the image (letters, digits, . _ @ : / -); --note is
#            free text kept in the release record;
#         3. references: no --ref FILE contains SRC's path (fixed string);
#         4. mounts: no mount point (FM_PACK_MOUNTINFO, default
#            /proc/self/mountinfo) is SRC or inside it;
#         5. processes: no visible process has its cwd or an open file in
#            SRC or on an --also name. The scan reads every process under
#            FM_PACK_PROC; a process is hidden, and not seen, when reading it
#            is denied with EACCES (the kernel refuses this caller ptrace-read
#            access: another user's process, root's included, a non-dumpable
#            one, or one holding capabilities the caller lacks), and gone when
#            it exited or is a zombie; a file closed while read rereads the
#            process, at most three times. Any other error, a missing or
#            unreadable FM_PACK_PROC, or a scanner that fails refuses;
#         6. reservations: no live fm-disk-room reservation, Linux or D:
#            pool, is named UNIT, pack-UNIT or basename(SRC) (reservations
#            record no path, so a writer is caught by name or by step 5);
#         7. hard links: every name of a multi-link file in SRC is inside
#            SRC or named by an --also PATH (a regular file outside SRC);
#         8. verify: the same check as verify IMAGE --against SRC.
#       Then UNIT.release.json (fm-pack-release/v1, state releasing) is
#       written beside the image, SRC is renamed to .NAME.fm-pack-release in
#       its own parent (the same filesystem), its tree list is checked again
#       (any change renames it back and refuses), steps 4 and 5 run again on
#       the new name, it is removed with the --also names, SRC/STORED.md is
#       left naming the image, and the record is rewritten with state
#       released. One line per outcome goes to fm-pack-release.log beside
#       the image. Prints one line on success:
#         fm-pack-release/v1 image=PATH src=PATH freed=BYTES accepted_by=WHO released_at=EPOCH record=PATH
#       freed counts each released inode once by size, the --also names
#       included; GiB freed is freed / 1073741824. A failed or partial guard
#       read refuses with a named *-read-failed diagnostic, including a /proc
#       read that step 5 does not name as hidden or gone; no read failure is
#       interpreted as an empty result.
#       Exit codes:
#         0   released;
#         1   refused by a guard, nothing deleted; also a removal that failed
#             partway after the rename, the remainder kept at the aside path
#             stderr names and the record left in state releasing;
#         2   usage or precondition refusal, nothing deleted: bad arguments,
#             SRC not the recorded source, SRC holding the image, an
#             unreadable --ref, an --also PATH that is not a link of a file in
#             SRC, the unit already released, or an aside left by an earlier
#             run (rename it back to SRC, then release again);
#         75  wait, nothing deleted: the window has not passed, another
#             release of the unit holds its lock (a file in XDG_RUNTIME_DIR,
#             else TMPDIR, else /tmp), or the pack slot stayed held.
#
#   fm-pack.sh candidates --home HOME [--root ROOT]... [--timeout SECONDS]
#                         [--small SIZE]
#       Read-only report of HOME's pack candidates: it packs, releases and
#       writes nothing outside its own temp directory. A tree is each
#       directory directly under HOME/data, dot names included; a symlink, a
#       directory on another filesystem than HOME/data, and a name holding a
#       tab, newline or backslash are skipped and counted. Each tree is walked
#       once with find -xdev (same filesystem, no symlink followed) at nice 19
#       and idle I/O, under timeout SECONDS (default 900) per tree. NEWEST is
#       the newest mtime of any entry, the tree's own directory included; a
#       tree is listed when NEWEST is 7 or more whole days old. PACK comes from
#       the UNIT.json beside every UNIT.sqfs one directory under each ROOT's
#       verified D: directory (fm-storage.sh verify-bulk-root; default ROOTs
#       tetjet-results and research) whose fm-pack-unit/v1 source is the tree,
#       best first:
#         verified   a committed unit whose tree list the tree still matches
#                    (a second walk, bounded the same way);
#         releasing  a release started and did not finish;
#         released   released under R2;
#         changed    a committed unit, but the tree changed since;
#         none       no unit names the tree;
#         unknown    a ROOT is waiting, or a sidecar or the second walk could
#                    not be read (stderr names it).
#       tj-fetch-arrival-unit/v2 sidecars name no home tree and are passed
#       over; any other format, or a UNIT.sqfs without a readable UNIT.json,
#       leaves trees no unit names unknown rather than none.
#       Prints a header, a column line, then one tab-separated row per listed
#       tree, 30d+ before 7d+ before failed, larger first:
#         fm-pack-candidates/v1 home=HOME now=EPOCH small=BYTES listed=N recent=N skipped=N failed=N
#         bucket days allocated logical files small_pct newest pack tree
#       bucket is 30d+ or 7d+, or failed for a tree whose walk failed or timed
#       out (its other fields -, pack timeout or read-error). allocated is
#       du -sB1 -x's measure and logical the regular files' sizes, each inode
#       once; files counts regular-file names as find does; small_pct is the
#       share of them under --small (default 64K, a size in bytes or with
#       K, M or G); newest is UTC ISO-8601. recent counts trees walked and not
#       listed. By hand, for one tree: du -sB1 -x TREE;
#       find TREE -xdev -type f | wc -l;
#       find TREE -xdev -printf '%T@\n' | sort -n | tail -n 1.
#       Exit codes: 0 listed; 1 a walk failed or a pack state could not be
#       read (every row still printed); 2 misuse or an unreadable HOME/data;
#       75 otherwise when a ROOT is waiting (its wait: line on stderr).
#
#   fm-pack.sh stop [--wait SECONDS]
#       Ask the command holding the machine-wide pack slot (a pack, verify,
#       verify-tar, restore, release or fm-repack run) to stop at its next
#       safe point, and wait up to SECONDS (default 60) for it to end. It
#       reads the holder line, checks that the named pid still has the
#       recorded start time, sends SIGTERM to that pid only (its own steps
#       run in process groups it ends itself), then waits. Exit codes:
#         0   the slot was free, or the holder stopped;
#         1   refused, nothing signalled: the holder line names no pid and
#             start time, the pid is gone while the slot is still held (a
#             process it left inherited the lock), the pid's start time
#             differs (a reused pid), or the signal failed;
#         2   misuse, or the lock path is not a regular file;
#         75  one line fm-pack: wait: pack-slot-busy: the holder got SIGTERM
#             and still runs after SECONDS.
#
# Reading the image afresh: a new squashfuse -o ro mount on a temporary
# directory (fusermount3 -u afterwards). pack, verify and verify-tar refuse
# with exit 2 before any work when squashfuse, fusermount3 or a usable
# /dev/fuse is missing, unless FM_PACK_MOUNT=unsquashfs names the slow path.
# The UNIT.json verify_method field and verify's output name the path taken.
#
# UNIT.json (fm-pack-unit/v1) holds the source, its directory name, the owner
# home, task, root, counts, both sha256 values, the mksquashfs version, and
# packed_at and verified_at (epoch seconds), so an owner can read its
# release window from the sidecar.
#
# Only release deletes SRC, and only after every guard holds; pack, verify and
# restore never delete or rewrite it. fm-pack.sh keeps no index (the sidecars
# beside the image are the manifest), and pack and restore never remove
# anything they did not create in this run.
#
# Machine share: pack, verify, verify-tar, restore, release and candidates
# re-execute themselves once at nice 19 and idle I/O priority (ionice -c3,
# where ionice exists), so every step and every tool they run inherits both.
# On Linux they first build bin/fm-pack-retry.c with cc into a per-run
# directory (removed at exit), check that it loads and retries, and preload
# it into themselves and every tool, so a read, write, open or readdir that
# fails with ENOMEM is retried (docs/storage.md "Packing cold data" owns why);
# no cc, a failed build or a shim that does not load exits 2. Retried calls
# are summed in one stderr line at exit (fm-pack: retried N calls ...), and
# calls still failing after the shim's limit in one more (... still failed
# with ENOMEM ...); verify-tar prints them only when it exits non-zero.
#
# Machine-wide pack slot: each of those commands but candidates holds an
# exclusive flock on one lock file for the whole command, so one runs at a
# time on the machine. candidates only reads metadata under bounded walks, and
# a listing that waited out a multi-hour pack would be stale when it printed.
# A command that finds the slot taken prints one line and waits at most
# FM_PACK_SLOT_WAIT seconds (default 900; 0 does not wait):
#   fm-pack: waiting for the machine-wide pack slot LOCK (at most N s), held by HOLDER
# If the slot is still held then, it prints one more line and exits 75,
# having done nothing:
#   fm-pack: wait: pack-slot-busy: LOCK still held after N s by HOLDER; nothing done
# The holder truncates LOCK and writes one line, pid=PID start=TICKS
# started=EPOCH command=TEXT, which HOLDER quotes; TICKS is the pid's start
# time (field 22 of /proc/PID/stat), so stop can tell the holder from a reused
# pid. LOCK is FM_PACK_SLOT_LOCK, default $HOME/.cache/fm-pack/slot.lock,
# outside every home; anything there but a regular file exits 2. Another heavy D: tool
# (fm-repack) shares the slot by taking flock on the same file the same way,
# and closes it for any process that may outlive it, as fm-pack does for the
# squashfuse daemon. release takes its per-unit lock first and the slot
# second, because its last guard reads the whole image and its removal is
# heavy I/O; a holder of the slot never waits on a release's unit lock.
#
# Stopping a holder: from taking the slot on, SIGTERM and SIGINT stop the
# command at once, at a safe point, exiting 143 or 130 with one line
# (fm-pack: stopped by SIGTERM). Each long step (the walks, the hashing,
# mksquashfs, the member check, unsquashfs, the parity check) runs in its own
# process group, which the stop sends SIGTERM and, 5 s later, SIGKILL; the
# command's cleanup then runs as on any failure. Two sections finish first:
# pack's commit (from the first rename into R until the unit is whole) and
# release's removal (from the first removal until the record says released);
# a stop that arrives there is held, the section completes, the command
# exits 0 with its normal output and says on stderr that a stop arrived. A
# stop never leaves a unit half committed. A SIGKILL is not a stop: it can
# leave staging or a squashfuse mount, as before.
#
# Environment (all optional):
#   FM_PACK_MOUNT   mount (default): verify and verify-tar read the image
#                   through a fresh squashfuse mount; unsquashfs: for tests
#                   and hosts without FUSE, unsquashfs -lln for the entries
#                   and one unsquashfs -cat per member,
#                   each rereading the image tables, so roughly quadratic in
#                   the file count
#   FM_HOME         owner home recorded in UNIT.json (default this checkout)
#   FM_PACK_RELEASE_WINDOW  release's default window in seconds (0)
#   FM_PACK_NOW     candidates' clock in epoch seconds (default now), for tests
#   FM_PACK_MOUNTINFO  the mount table release reads (/proc/self/mountinfo)
#   FM_PACK_PROC    the process table release scans (/proc)
#   FM_DISK_ROOM_STATE  fm-disk-room's state directory, for release's
#                   reservation check (the same default as fm-disk-room.sh)
#   FM_PACK_SLOT_LOCK  the machine-wide pack slot's lock file
#   FM_PACK_SLOT_WAIT  seconds a command waits for the pack slot (900)
#   FM_PACK_RETRY_LIMIT  seconds the shim keeps retrying one call (600)
#   FM_PACK_TEST_BEFORE_RECHECK  test hook only: a command run by bash -c
#                   between packing and the source re-check, between
#                   release's rename aside and its re-check, and before
#                   verify-tar's identity re-check
#   FM_PACK_TEST_IN_COMMIT  test hook only: a command run by bash -c inside
#                   pack's commit section, before the first rename
#   FM_PACK_RETRY_TEST_EVERY  test hook only: the shim fails the first try
#                   of every Nth wrapped call in each process with ENOMEM
set -u
set -o pipefail

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NL=$'\n'

die() { printf 'fm-pack: %s\n' "$*" >&2; exit 2; }
fail1() { printf 'fm-pack: %s\n' "$*" >&2; exit 1; }
note() { printf 'fm-pack: %s\n' "$*" >&2; }
usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }

need() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "$t is not installed"; done
}

# prepare ARGS: re-execute once at nice 19 and idle I/O, with the ENOMEM
# retry shim preloaded on Linux (see "Machine share" above); then, in the
# re-executed process, own the run directory and the exit report.
RUN='' CMD=${1:-} CLEANUP=''
prepare() {
  local so err
  if [ "${FM_PACK_SELF:-}" = "$$" ]; then
    RUN=${FM_PACK_RUN:-}
    unset FM_PACK_SELF FM_PACK_RUN
    trap finish EXIT
    return 0
  fi
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/fm-pack-run.XXXXXX") || die "cannot create a run directory"
  if [ "$(uname -s)" = Linux ]; then
    so=$RUN/fm-pack-retry.so
    case "$so" in *[[:space:]:]*) rm -rf -- "$RUN"; die "the run directory $RUN cannot be preloaded from (a space or colon)" ;; esac
    command -v cc >/dev/null 2>&1 || { rm -rf -- "$RUN"; die "cc is not installed; it builds the ENOMEM retry shim $BIN/fm-pack-retry.c"; }
    if ! err=$(nice -n 19 cc -O2 -shared -fPIC -o "$so" "$BIN/fm-pack-retry.c" -ldl 2>&1); then
      rm -rf -- "$RUN"; die "cannot build the ENOMEM retry shim: ${err%%"$NL"*}"
    fi
    if ! LD_PRELOAD=$so FM_PACK_RETRY_TEST_EVERY=1 FM_PACK_RETRY_LIMIT=5 FM_PACK_RETRY_LOG=$RUN/probe.log \
      cat /dev/null || [ ! -s "$RUN/probe.log" ]; then
      rm -rf -- "$RUN"; die "the ENOMEM retry shim did not load or retry"
    fi
    export LD_PRELOAD="$so${LD_PRELOAD:+ $LD_PRELOAD}"
  fi
  export FM_PACK_SELF=$$ FM_PACK_RUN=$RUN FM_PACK_RETRY_LOG=$RUN/retry.log
  if command -v ionice >/dev/null 2>&1; then exec nice -n 19 ionice -c3 -t "$BASH" "$0" "$@"; fi
  exec nice -n 19 "$BASH" "$0" "$@"
}

# finish: the command's cleanup, the retry report, then the run directory.
# shellcheck disable=SC2329 # Registered as the EXIT trap in prepare.
finish() {
  local rc=$? report
  [ -z "$CLEANUP" ] || "$CLEANUP"
  if [ -n "$RUN" ] && [ -s "$RUN/retry.log" ] && { [ "$CMD" != verify-tar ] || [ "$rc" != 0 ]; }; then
    report=$(awk '{ n++; split($5, w, "="); if (w[2] + 0 > m) m = w[2] + 0; c[$3]++
        if ($6 == "result=gave-up") g++ }
      END { for (k in c) s = s (s == "" ? "" : ", ") k " " c[k]
        printf "fm-pack: retried %d calls that failed with ENOMEM (%s), the longest for %d ms\n", n, s, m
        if (g) printf "fm-pack: %d calls still failed with ENOMEM after the retry limit\n", g }' "$RUN/retry.log")
    [ -z "$report" ] || printf '%s\n' "$report" >&2
  fi
  [ -z "$RUN" ] || rm -rf -- "$RUN"
}

# slot_lock_to VAR: the pack slot's lock path; exit 2 when something other
# than a regular file stands there, since opening a FIFO would hang.
slot_lock_to() {
  local __lock=${FM_PACK_SLOT_LOCK:-${HOME:-/tmp}/.cache/fm-pack/slot.lock}
  [ ! -e "$__lock" ] || [ -f "$__lock" ] || die "the pack slot $__lock is not a regular file"
  printf -v "$1" '%s' "$__lock"
}

# slot_holder_to VAR LOCK: the holder line LOCK holds (empty when unnamed),
# read in the shell and bounded, never through a pipe or subshell.
slot_holder_to() {
  local __line=''
  if [ -f "$2" ]; then { IFS= read -r -n 4096 __line <"$2"; } 2>/dev/null; fi
  printf -v "$1" '%s' "$__line"
}

# proc_start_to VAR PID: the start time of PID in clock ticks since boot
# (field 22 of /proc/PID/stat), the half of an exec-stable identity a pid
# alone lacks; 1 when the process is gone or /proc cannot answer.
proc_start_to() {
  local __stat='' __f=()
  [[ $2 =~ ^[1-9][0-9]*$ ]] || return 1
  { IFS= read -r __stat <"/proc/$2/stat"; } 2>/dev/null || [ -n "$__stat" ] || return 1
  read -r -a __f <<<"${__stat##*) }"
  [[ ${__f[19]:-} =~ ^[0-9]+$ ]] || return 1
  printf -v "$1" '%s' "${__f[19]}"
}

# Stopping (see "Stopping a holder"): every slot holder ends a long step in
# the background through run_stoppable, so on_stop, its INT and TERM trap,
# runs at once rather than after the step; between hold_stops and
# release_stops a stop is only recorded, so a commit finishes whole.
PACK_CHILD='' STOPS_HELD='' STOP_STATUS=''

# run_stoppable CMD...: run CMD in its own process group with stdin from
# /dev/null and wait for it; returns CMD's status. Only after take_slot, whose
# traps end the group: without them a stop would leave the step running.
run_stoppable() {
  local rc
  set -m
  ( set +m; "$@" ) </dev/null &
  PACK_CHILD=$!
  set +m
  # A wait a trapped signal interrupts returns above 128 with the step alive.
  while :; do
    wait "$PACK_CHILD" 2>/dev/null; rc=$?
    if [ "$rc" -le 128 ] || ! kill -0 "$PACK_CHILD" 2>/dev/null; then break; fi
  done
  PACK_CHILD=''
  return "$rc"
}

# on_stop STATUS: end the running step's process group (TERM, KILL after
# 5 s), then exit STATUS so the EXIT trap's cleanup runs.
# shellcheck disable=SC2329 # Registered as the INT and TERM trap in take_slot.
on_stop() {
  local guard
  if [ -n "$STOPS_HELD" ]; then STOP_STATUS=${STOP_STATUS:-$1}; return 0; fi
  trap '' INT TERM
  if [ -n "$PACK_CHILD" ]; then
    kill -TERM -- "-$PACK_CHILD" 2>/dev/null
    ( sleep 5; kill -KILL -- "-$PACK_CHILD" 2>/dev/null ) </dev/null >/dev/null 2>&1 7>&- 8>&- &
    guard=$!
    wait "$PACK_CHILD" 2>/dev/null
    kill -KILL -- "-$PACK_CHILD" 2>/dev/null
    kill "$guard" 2>/dev/null
    PACK_CHILD=''
  fi
  if [ "$1" = 130 ]; then note "stopped by SIGINT"; else note "stopped by SIGTERM"; fi
  exit "$1"
}

hold_stops() { STOPS_HELD=1; }

# release_stops: end hold_stops; 0 when a stop arrived while held.
release_stops() {
  STOPS_HELD=''
  [ -n "$STOP_STATUS" ]
}

# take_slot TEXT: hold the machine-wide pack slot on fd 7 until exit, waiting
# at most FM_PACK_SLOT_WAIT seconds with one line while another holder has it,
# then exit 75 (see "Machine-wide pack slot"). From here INT and TERM stop the
# command through on_stop.
take_slot() {
  local lock wait=${FM_PACK_SLOT_WAIT:-900} holder start rc
  [[ $wait =~ ^[0-9]{1,7}$ ]] || die "FM_PACK_SLOT_WAIT must be whole seconds, not $wait"
  need flock
  slot_lock_to lock
  mkdir -p -- "${lock%/*}" || die "cannot create the directory of the pack slot $lock"
  exec 7>>"$lock" || die "cannot open the pack slot $lock"
  trap 'on_stop 130' INT
  trap 'on_stop 143' TERM
  if ! flock -n 7; then
    slot_holder_to holder "$lock"
    note "waiting for the machine-wide pack slot $lock (at most $wait s), held by ${holder:-a holder that has not named itself}"
    run_stoppable flock -w "$wait" -E 75 7; rc=$?
    case "$rc" in
      0) ;;
      75)
        slot_holder_to holder "$lock"
        note "wait: pack-slot-busy: $lock still held after $wait s by ${holder:-a holder that has not named itself}; nothing done"
        exit 75 ;;
      *) die "cannot take the pack slot $lock" ;;
    esac
  fi
  proc_start_to start "$$" || start=''
  printf 'pid=%s start=%s started=%s command=%s\n' "$$" "$start" "$(date +%s)" "$*" >"$lock" ||
    note "cannot name this holder in $lock"
}

# ---------------------------------------------------------------- stop

cmd_stop() {
  local wait=60 lock line pid start started now deadline
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) [ "$#" -ge 2 ] && [[ $2 =~ ^[0-9]{1,7}$ ]] || die "--wait needs whole seconds"; wait=$2; shift 2 ;;
      *) die "unknown stop argument: $1" ;;
    esac
  done
  need flock
  slot_lock_to lock
  [ -e "$lock" ] || { printf 'fm-pack: stop: the pack slot is free (%s does not exist)\n' "$lock"; exit 0; }
  exec 9<"$lock" || die "cannot open the pack slot $lock"
  if flock -n 9; then
    printf 'fm-pack: stop: the pack slot %s is free\n' "$lock"; exit 0
  fi
  slot_holder_to line "$lock"
  pid=${line#pid=} pid=${pid%% *} start=${line#* start=} start=${start%% *}
  case "$line" in
    pid=*' start='*' started='*' command='*) ;;
    *) fail1 "stop: refused: the holder of $lock has not named itself as pid=PID start=TICKS (${line:-an empty line}); nothing signalled" ;;
  esac
  [[ $pid =~ ^[1-9][0-9]*$ ]] && [[ $start =~ ^[0-9]+$ ]] ||
    fail1 "stop: refused: the holder line of $lock names no pid and start time ($line); nothing signalled"
  proc_start_to now "$pid" ||
    fail1 "stop: refused: the named holder pid $pid is gone, yet $lock is still held, by a process that inherited it; nothing signalled"
  [ "$now" = "$start" ] ||
    fail1 "stop: refused: pid $pid started at $now ticks, not the holder's $start; nothing signalled"
  kill -TERM "$pid" 2>/dev/null || fail1 "stop: refused: cannot signal the holder pid $pid; nothing signalled"
  started=${line#* command=}
  note "stop: sent SIGTERM to the pack slot holder pid $pid ($started); it stops at its next safe point"
  deadline=$(( $(date +%s) + wait ))
  while proc_start_to now "$pid" && [ "$now" = "$start" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || {
      note "wait: pack-slot-busy: the holder pid $pid got SIGTERM and is still running after $wait s"; exit 75; }
    sleep 0.2
  done
  printf 'fm-pack: stop: the pack slot holder pid %s stopped\n' "$pid"
}

valid_unit() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# tree_list DIR: the tree list of DIR on stdout (pack step 3 above).
TREE_FORMAT='%y\t%s\t%m\t%n\t%T@\t%l\t%p\n'
# shellcheck disable=SC2329 # Run by name through run_stoppable.
tree_list() {
  (cd "$1" && find . -xdev -printf "$TREE_FORMAT" | LC_ALL=C sort -t$'\t' -k7)
}

# tree_matches DIR LIST: capture the complete listing before comparing bytes.
# A process substitution would hide a failed producer, even on equal output.
tree_matches() {
  local tmp rc
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-pack-tree.XXXXXX") || { note "tree-read-failed: cannot create scratch"; return 1; }
  if run_stoppable tree_list "$1" >"$tmp"; then
    cmp -s "$tmp" "$2"; rc=$?
    [ "$rc" -le 1 ] || note "tree-read-failed: comparing $1 with $2"
  else
    note "tree-read-failed: $1"; rc=1
  fi
  rm -f -- "$tmp"
  return "$rc"
}

# members_list DIR: sha256sum lines of every regular file under DIR, sorted.
# shellcheck disable=SC2329 # Run by name through run_stoppable.
members_list() {
  (cd "$1" && set -o pipefail && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --)
}

# members_check DIR MEMBERS: 0 when every line of MEMBERS matches under DIR.
# shellcheck disable=SC2329 # Run by name through run_stoppable.
members_check() { (cd "$1" && sha256sum --quiet --strict -c -- "$2"); }

# census DIR -> "FILES LOGICAL FREES"
census() {
  find "$1" -xdev -type f -printf '%n %i %s\n' | awk '{n++; L+=$3; if ($1==1) F+=$3; else {c[$2]++; k[$2]=$1; s[$2]=$3}}
    END {for (i in c) if (c[i]==k[i]) F+=s[i]; printf "%.0f %.0f %.0f\n", n, L, F}'
}

# sidecar FIELD JSON -> the field's value
sidecar() { jq -er --arg f "$1" '.[$f]' "$2"; }

mount_usable() {
  [ -c /dev/fuse ] && [ -r /dev/fuse ] && [ -w /dev/fuse ] &&
    command -v squashfuse >/dev/null 2>&1 && command -v fusermount3 >/dev/null 2>&1
}

MNT=''
unmount_verify() {
  [ -n "$MNT" ] || return 0
  fusermount3 -u "$MNT" 2>/dev/null || fusermount3 -uz "$MNT" 2>/dev/null
  rmdir "$MNT" 2>/dev/null
  MNT=''
}

# check_members_mount IMAGE DIR MEMBERS: 0 match, 1 mismatch or no mount.
# shellcheck disable=SC2329 # Called by name through check_members.
check_members_mount() {
  local img=$1 dir=$2 members=$3 count expected rc
  MNT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pack-verify.XXXXXX") || return 1
  # The daemon may outlive a killed run, so it must not inherit the slot.
  if ! squashfuse -o ro "$img" "$MNT" 2>/dev/null 7>&-; then
    rmdir "$MNT"; MNT=''
    note "squashfuse could not mount $img"; return 1
  fi
  if [ ! -d "$MNT/$dir" ] || [ -L "$MNT/$dir" ]; then
    note "the image holds no directory $dir"; unmount_verify; return 1
  fi
  rc=0
  run_stoppable members_check "$MNT/$dir" "$members" || rc=1
  if [ "$rc" = 0 ]; then
    if ! count=$(cd "$MNT/$dir" && find . -type f -printf '.\n' | wc -l) ||
      ! expected=$(wc -l <"$members"); then
      note "member-count-read-failed: $img or $members"; rc=1
    elif [ "$count" != "$expected" ]; then
      note "the image holds $count files, the members list $expected"; rc=1
    fi
  fi
  unmount_verify
  return "$rc"
}

# check_members_unsquashfs IMAGE DIR MEMBERS: 0 match, 1 mismatch.
# shellcheck disable=SC2329 # Called by name through check_members.
check_members_unsquashfs() {
  local img=$1 dir=$2 members=$3 line want path got count expected manifest n=0 bare=''
  [ "${IFORMAT:-}" = tj-fetch-arrival-unit/v2 ] && bare=1
  count=$(unsquashfs -no-wildcards -lln "$img" "$dir" | awk '/^-/ {n++} END {print n+0}') ||
    { note "member-count-read-failed: $img"; return 1; }
  expected=$(wc -l <"$members") || { note "member-count-read-failed: $members"; return 1; }
  [ "$count" = "$expected" ] || { note "the image holds $count files, the members list $expected"; return 1; }
  manifest=$(cat -- "$members") || { note "member-list-read-failed: $members"; return 1; }
  [ "$expected" != 0 ] || [ -n "$manifest" ] || return 0
  while IFS= read -r line; do
    n=$((n + 1))
    want=${line:0:64} path=${line:66}
    if [ "${path:0:2}" = './' ]; then path=${path#./}; elif [ -z "$bare" ]; then path=''; fi
    [[ $want =~ ^[0-9a-f]{64}$ ]] && [ "${line:64:2}" = '  ' ] && [ -n "$path" ] ||
      { note "members line $n is malformed"; return 1; }
    got=$(unsquashfs -no-wildcards -cat "$img" "$dir/$path" | sha256sum) ||
      { note "member-read-failed: $path"; return 1; }
    [ "${got%% *}" = "$want" ] || { note "$path: FAILED"; return 1; }
  done <<<"$manifest"
  [ "$n" -eq "$expected" ] || { note "member-list-read-failed: $members"; return 1; }
}

# pack_mode: sets METHOD from FM_PACK_MOUNT; exits 2 on an unknown value.
METHOD=''
pack_mode() {
  METHOD=${FM_PACK_MOUNT:-mount}
  case "$METHOD" in mount|unsquashfs) ;; *) die "FM_PACK_MOUNT must be mount or unsquashfs, not $METHOD" ;; esac
}

# need_reader: pack_mode, then exit 2 when the mount path cannot run here.
need_reader() {
  pack_mode
  [ "$METHOD" = unsquashfs ] || mount_usable ||
    die "no usable FUSE mount (squashfuse, fusermount3 and a usable /dev/fuse) to verify through; FM_PACK_MOUNT=unsquashfs names the slow path"
}

# check_members IMAGE DIR MEMBERS: 0 match, 1 mismatch.
check_members() { "check_members_$METHOD" "$@"; }

# outside_src R SRC: exit 2 when R is SRC or inside it, or SRC is inside R/.incoming.
outside_src() {
  case "$1/" in "$2"/*) die "the D: root $1 is $2 or inside it; pack a tree outside its own results root" ;; esac
  case "$2/" in "$1/.incoming/"*) die "$2 is inside the staging of the D: root $1" ;; esac
}

# image_sha_ok DIR UNIT
image_sha_ok() { (cd "$1" && sha256sum --quiet --strict -c -- "$2.sqfs.sha256"); }

# ---------------------------------------------------------------- pack

R='' I='' UNIT='' RESERVED='' COMMITTED='' STAGED=()

pack_cleanup() {
  local f
  unmount_verify
  if [ -z "$COMMITTED" ]; then
    for f in "${STAGED[@]}"; do rm -f -- "$f"; done
    [ -n "$I" ] && rmdir "$I" 2>/dev/null
  fi
  [ -n "$RESERVED" ] && "$BIN/fm-disk-room.sh" release-bulk "pack-$UNIT" >/dev/null 2>&1
  RESERVED=''
}

cmd_pack() {
  local root=tetjet-results task src dir files logical frees packaging out rc ext f
  local recheck image_sha members_sha packed_at verified_at version owner json
  if [ "${1:-}" = --root ]; then
    [ "$#" -ge 2 ] || die "--root needs a name"
    root=$2; shift 2
  fi
  [ "$#" = 3 ] || die "pack needs TASK UNIT SRC"
  task=$1 UNIT=$2 src=$3
  valid_unit "$UNIT" || die "UNIT must be letters, digits, . _ - and not start with . _ -"
  need mksquashfs unsquashfs sha256sum jq
  need_reader
  [ -d "$src" ] && [ ! -L "$src" ] || die "$src is not a real directory"
  src=$(cd -P -- "$src" && pwd -P) || die "cannot resolve $src"
  dir=${src##*/}
  [ -n "$dir" ] || die "cannot pack /"
  case "$src" in *"$NL"*|*\\*) die "$src: a newline or backslash in the path" ;; esac
  take_slot "fm-pack pack $task $UNIT $src"
  R=$("$BIN/fm-storage.sh" verify-bulk-root --root "$root" "$task"); rc=$?
  case "$rc" in
    0) ;;
    75) exit 75 ;;
    *) exit 2 ;;
  esac
  outside_src "$(realpath -m -- "$R")" "$src"
  out=$(find "$src" -xdev \( -name "*$NL*" -o -name '*\\*' \) -print -quit)
  [ -z "$out" ] || die "$src holds a name with a newline or backslash, which the lists cannot carry"

  read -r files logical frees < <(census "$src")
  [ -n "$frees" ] || die "census of $src failed"
  packaging=$(( logical + logical / 100 + 1048576 ))

  CLEANUP=pack_cleanup
  R=$("$BIN/fm-storage.sh" bulk-root --root "$root" "$task" --name "pack-$UNIT" \
    --download 0 --expanded 0 --packaging "$packaging" --pid "$$"); rc=$?
  case "$rc" in
    0) RESERVED=1 ;;
    75) exit 75 ;;
    *) exit 2 ;;
  esac
  [ -n "$R" ] || exit 2
  outside_src "$(realpath -m -- "$R")" "$src"
  for ext in sqfs sqfs.sha256 members.sha256 tree.tsv json; do
    [ ! -e "$R/$UNIT.$ext" ] && [ ! -L "$R/$UNIT.$ext" ] || die "$R/$UNIT.$ext exists; a unit is never overwritten"
    [ ! -e "$R/.incoming/$UNIT.$ext" ] && [ ! -L "$R/.incoming/$UNIT.$ext" ] ||
      die "stale staging $R/.incoming/$UNIT.$ext from an earlier run; its owner removes it"
  done
  mkdir -p -- "$R/.incoming" || fail1 "cannot create $R/.incoming"
  I=$R/.incoming
  STAGED=("$I/$UNIT.members.sha256" "$I/$UNIT.tree.tsv" "$I/$UNIT.sqfs" "$I/$UNIT.sqfs.sha256" "$I/$UNIT.json" "$I/$UNIT.recheck.tsv")

  run_stoppable members_list "$src" >"$I/$UNIT.members.sha256" || fail1 "hashing $src failed"
  run_stoppable tree_list "$src" >"$I/$UNIT.tree.tsv" || fail1 "listing $src failed"
  [ "$(wc -l <"$I/$UNIT.members.sha256")" = "$files" ] || fail1 "$src changed during the census"

  packed_at=$(date +%s)
  run_stoppable mksquashfs "$src" "$I/$UNIT.sqfs" -noappend -keep-as-directory -one-file-system -comp gzip -no-xattrs \
    -processors 2 -mem 512M -quiet -no-progress >&2 || fail1 "mksquashfs failed"
  sync -f "$I/$UNIT.sqfs" 2>/dev/null || sync
  (cd "$I" && sha256sum -- "$UNIT.sqfs" >"$UNIT.sqfs.sha256") || fail1 "hashing the image failed"

  if [ -n "${FM_PACK_TEST_BEFORE_RECHECK:-}" ]; then bash -c "$FM_PACK_TEST_BEFORE_RECHECK"; fi
  recheck=$I/$UNIT.recheck.tsv
  run_stoppable tree_list "$src" >"$recheck" || fail1 "listing $src again failed"
  cmp -s "$recheck" "$I/$UNIT.tree.tsv" || fail1 "$src changed while it was packed; nothing committed"
  rm -f -- "$recheck"

  image_sha_ok "$I" "$UNIT" || fail1 "the staged image does not match its sha256"
  check_members "$I/$UNIT.sqfs" "$dir" "$I/$UNIT.members.sha256" || fail1 "the staged image failed verify; nothing committed"
  verified_at=$(date +%s)

  image_sha=$(cut -d' ' -f1 <"$I/$UNIT.sqfs.sha256")
  members_sha=$(sha256sum <"$I/$UNIT.members.sha256" | cut -d' ' -f1)
  version=$(mksquashfs -version 2>/dev/null | head -n1)
  owner=${FM_HOME:-$(cd "$BIN/.." && pwd)}
  json=$I/$UNIT.json
  jq -n --arg unit "$UNIT" --arg task "$task" --arg root "$root" --arg source "$src" --arg dir "$dir" \
    --arg owner "$owner" --arg image "$R/$UNIT.sqfs" --arg image_sha "$image_sha" --arg members_sha "$members_sha" \
    --arg method "$METHOD" --arg version "$version" --argjson files "$files" --argjson logical "$logical" \
    --argjson frees "$frees" --argjson image_bytes "$(stat -c %s -- "$I/$UNIT.sqfs")" \
    --argjson packed "$packed_at" --argjson verified "$verified_at" \
    '{format: "fm-pack-unit/v1", unit: $unit, task: $task, root: $root, source: $source, dir: $dir,
      owner_home: $owner, files: $files, logical_bytes: $logical, frees_bytes: $frees, image: $image,
      image_bytes: $image_bytes, image_sha256: $image_sha, members_sha256: $members_sha,
      packed_at: $packed, verified_at: $verified, verify_method: $method, mksquashfs: $version}' >"$json" ||
    fail1 "writing $json failed"

  # A stop during the commit is held until the unit is whole, then reported.
  hold_stops
  if [ -n "${FM_PACK_TEST_IN_COMMIT:-}" ]; then bash -c "$FM_PACK_TEST_IN_COMMIT"; fi
  for f in sqfs.sha256 members.sha256 tree.tsv sqfs json; do
    mv -n -- "$I/$UNIT.$f" "$R/$UNIT.$f" && [ ! -e "$I/$UNIT.$f" ] || fail1 "committing $UNIT.$f failed"
    COMMITTED=partial
  done
  COMMITTED=1
  sync -f "$R/$UNIT.json" 2>/dev/null || sync
  rmdir "$I" 2>/dev/null
  pack_cleanup
  if release_stops; then note "a stop arrived during the commit of $UNIT; the unit was committed whole first"; fi
  printf 'fm-pack-receipt/v1 image=%s sha256=%s files=%s logical=%s frees=%s verified_at=%s sidecar=%s\n' \
    "$R/$UNIT.sqfs" "$image_sha" "$files" "$logical" "$frees" "$verified_at" "$R/$UNIT.json"
}

# ---------------------------------------------------------------- verify, restore

# load_image IMAGE: sets IDIR, IUNIT, IJSON, IMEMBERS, IFORMAT after checking
# the sidecars and the unit format.
load_image() {
  local img=$1 ext
  case "$img" in *.sqfs) ;; *) die "IMAGE must be a UNIT.sqfs file" ;; esac
  [ -f "$img" ] || die "$img is not a file"
  IDIR=$(cd -P -- "$(dirname -- "$img")" && pwd -P) || die "cannot resolve $img"
  IUNIT=$(basename -- "$img" .sqfs)
  for ext in sqfs.sha256 members.sha256 tree.tsv json; do
    [ -f "$IDIR/$IUNIT.$ext" ] || die "$IDIR/$IUNIT.$ext is missing"
  done
  IJSON=$IDIR/$IUNIT.json IMEMBERS=$IDIR/$IUNIT.members.sha256
  IMG=$IDIR/$IUNIT.sqfs
  IFORMAT=$(sidecar format "$IJSON") || die "$IJSON has no format"
  case "$IFORMAT" in
    fm-pack-unit/v1|tj-fetch-arrival-unit/v2) ;;
    *) die "$IJSON has the unknown format $IFORMAT" ;;
  esac
  IDIRNAME=$(sidecar dir "$IJSON") || die "$IJSON has no dir"
}

cmd_verify() {
  local against=''
  [ "$#" -ge 1 ] || die "verify needs IMAGE"
  need unsquashfs sha256sum jq
  need_reader
  load_image "$1"; shift
  if [ "${1:-}" = --against ]; then
    [ "$#" = 2 ] || die "--against needs SRC"
    against=$2
    [ "$IFORMAT" = fm-pack-unit/v1 ] || die "--against reads fm-pack's own tree list; $IJSON is $IFORMAT"
  elif [ "$#" != 0 ]; then
    die "unknown verify argument: $1"
  fi
  take_slot "fm-pack verify $IMG"
  CLEANUP=unmount_verify
  image_sha_ok "$IDIR" "$IUNIT" || fail1 "$IMG does not match $IUNIT.sqfs.sha256"
  check_members "$IMG" "$IDIRNAME" "$IMEMBERS" || fail1 "$IMG failed the member check ($METHOD)"
  if [ -n "$against" ]; then
    [ -d "$against" ] || fail1 "$against is not a directory"
    tree_matches "$against" "$IDIR/$IUNIT.tree.tsv" || fail1 "$against no longer matches $IUNIT.tree.tsv"
  fi
  printf 'fm-pack: verified %s (%s files, %s)%s\n' "$IMG" "$(wc -l <"$IMEMBERS")" "$METHOD" "${against:+, source unchanged}"
}

cmd_verify_tar() {
  need python3
  need_reader
  [ "$METHOD" = mount ] || need unsquashfs
  take_slot "fm-pack verify-tar $*"
  run_stoppable python3 "$BIN/fm-pack-parity.py" --reader "$METHOD" --storage-tool "$BIN/fm-storage.sh" "$@"
}

cmd_restore() {
  local dest logical
  [ "$#" = 2 ] || die "restore needs IMAGE DEST"
  need unsquashfs sha256sum jq
  pack_mode
  load_image "$1"
  dest=$2
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || die "$dest exists; restore never writes into an existing path"
  [ -d "$(dirname -- "$dest")" ] || die "the parent of $dest does not exist"
  logical=$(sidecar logical_bytes "$IJSON") || die "$IJSON has no logical_bytes"
  take_slot "fm-pack restore $IMG $dest"
  image_sha_ok "$IDIR" "$IUNIT" || fail1 "$IMG does not match $IUNIT.sqfs.sha256"
  run_stoppable "$BIN/fm-disk-room.sh" run --name "restore-$IUNIT" --expect-write "$logical" -- \
    unsquashfs -no-progress -quiet -d "$dest" "$IMG" >&2
  case $? in
    0) ;;
    75) exit 75 ;;
    *) fail1 "unsquashfs into $dest failed" ;;
  esac
  run_stoppable members_check "$dest/$IDIRNAME" "$IMEMBERS" || fail1 "$dest failed the member check"
  printf 'fm-pack: restored %s into %s/%s and checked %s files\n' "$IMG" "$dest" "$IDIRNAME" "$(wc -l <"$IMEMBERS")"
}

# ---------------------------------------------------------------- release

REL_SRC='' REL_ASIDE='' REL_RECORD='' REL_PENDING='' REL_MOVED='' REL_IMAGE_SHA=''

# shellcheck disable=SC2329 # Called through CLEANUP by finish.
release_cleanup() {
  unmount_verify
  if [ -n "$REL_MOVED" ]; then
    if mv -n -T -- "$REL_ASIDE" "$REL_SRC" 2>/dev/null && [ ! -e "$REL_ASIDE" ]; then
      note "renamed $REL_ASIDE back to $REL_SRC"
    else
      note "could not rename $REL_ASIDE back to $REL_SRC; it holds the whole source, rename it back by hand"
      REL_PENDING=''
    fi
    REL_MOVED=''
  fi
  [ -n "$REL_PENDING" ] && rm -f -- "$REL_RECORD"
  REL_PENDING=''
}

# rel_log TEXT: one line in fm-pack-release.log beside the image.
rel_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$IDIR/fm-pack-release.log" 2>/dev/null ||
    note "cannot append to $IDIR/fm-pack-release.log"
}

# rel_refuse CODE REASON: log the refusal or wait, then exit CODE.
rel_refuse() {
  local code=$1; shift
  note "$*; nothing deleted"
  if [ "$code" = 75 ]; then rel_log "waits $IUNIT $REL_SRC: $*; nothing deleted, release again later"
  else rel_log "refused $IUNIT $REL_SRC: $*; nothing deleted"; fi
  exit "$code"
}

# mounts_in PATH: mount points at PATH or under it, from the mount table.
mounts_in() {
  awk -v p="$1" '{ m = $5; gsub(/\\040/, " ", m); gsub(/\\011/, "\t", m); gsub(/\\134/, "\\", m)
    if (m == p || index(m, p "/") == 1) print m }' "${FM_PACK_MOUNTINFO:-/proc/self/mountinfo}"
}

# procs_in PATH [NAME...]: "pid<TAB>path" of each visible process whose cwd or
# open file is PATH, under it, or one of the NAMEs. The header's step 5 owns
# which processes are hidden or gone; every other read error fails the scan.
procs_in() {
  python3 - "${FM_PACK_PROC:-/proc}" "$@" <<'PY'
import errno, os, sys, time
root, path, names = sys.argv[1], sys.argv[2], set(a for a in sys.argv[3:] if a)

def gone(d):
    # ENOENT on the process directory itself is the kernel's answer that it exited.
    try:
        os.stat(d)
    except FileNotFoundError:
        return True
    return False

def zombie(d):
    try:
        with open(d + '/stat') as f:
            state = f.read().rsplit(')', 1)[1].split()[0]
    except FileNotFoundError:
        return False
    return state in ('Z', 'X')

def links(d, out):
    out.append(os.readlink(d + '/cwd'))
    # The scanner's own descriptors are its listing and its pipes, never SRC.
    if d == own:
        return
    for fd in os.listdir(d + '/fd'):
        out.append(os.readlink(d + '/fd/' + fd))

own = root + '/' + str(os.getpid())
hits = set()
try:
    for pid in os.listdir(root):
        if not pid.isdigit():
            continue
        d = root + '/' + pid
        for attempt in range(3):
            targets = []
            try:
                links(d, targets)
                break
            except OSError as e:
                # The kernel denies this caller ptrace-read access: the process
                # is another user's, non-dumpable or more privileged. What was
                # read before the denial is still checked.
                if e.errno == errno.EACCES:
                    break
                if e.errno != errno.ENOENT:
                    raise
                if gone(d) or zombie(d):
                    break
                # A file closed while it was read: read the live process again.
                err = e
                time.sleep(0.05)
        else:
            raise err
        for t in targets:
            if t.endswith(' (deleted)'):
                t = t[:-len(' (deleted)')]
            if t == path or t.startswith(path + '/') or t in names:
                hits.add(pid + '\t' + t)
except OSError as e:
    print('fm-pack: process scan: %s: %s' % (e.filename, e.strerror), file=sys.stderr)
    sys.exit(1)
for h in sorted(hits):
    print(h)
PY
}

# in_use PATH [NAME...]: refuse when PATH or under it is a mount point, or a
# process uses PATH, a path under it, or a NAME.
in_use() {
  local p=$1 tab=${FM_PACK_MOUNTINFO:-/proc/self/mountinfo} out
  [ -r "$tab" ] || rel_refuse 1 "cannot read the mount table $tab"
  [ -r /proc/self/fd ] || rel_refuse 1 "cannot read /proc to find the processes that use $p"
  out=$(mounts_in "$p") || rel_refuse 1 "mount-table-read-failed: $tab"
  out=${out%%$'\n'*}
  [ -z "$out" ] || rel_refuse 1 "$out is a mount point at or inside $p"
  out=$(procs_in "$@") || rel_refuse 1 "process-scan-read-failed: ${FM_PACK_PROC:-/proc} for $p"
  out=${out%%$'\n'*}
  [ -z "$out" ] || rel_refuse 1 "process ${out%%$'\t'*} ($(cat "${FM_PACK_PROC:-/proc}/${out%%$'\t'*}/comm" 2>/dev/null)) uses ${out#*$'\t'}"
}

# reference_clear PATH FILE: grep's 1 means absent, every other failure refuses.
# Do not use -q: it can return success before encountering a later read error.
reference_clear() {
  local rc
  grep -F -- "$1" "$2" >/dev/null; rc=$?
  case "$rc" in
    0) rel_refuse 1 "$2 still names $1" ;;
    1) return 0 ;;
    *) rel_refuse 1 "reference-read-failed: $2" ;;
  esac
}

# reservation_directory DIR: 0 = readable directory, 3 = proven absent,
# 1 = unknown/error. A failed metadata predicate is never proof of absence.
reservation_directory() {
  local d=$1 parent pattern found rc
  [ ! -L "$d" ] || return 1
  if [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ]; then return 0; fi
  case "$d" in
    */*) parent=${d%/*}; [ -n "$parent" ] || parent=/ ;;
    *) parent=. ;;
  esac
  [ "$parent" != "$d" ] || return 1
  reservation_directory "$parent"; rc=$?
  case "$rc" in 3) return 3 ;; 0) ;; *) return 1 ;; esac
  # Match the literal child, including glob metacharacters or newlines, and
  # consume the complete enumeration before accepting its empty result.
  pattern=${d##*/}
  pattern=${pattern//\\/\\\\}; pattern=${pattern//\*/\\*}
  pattern=${pattern//\?/\\?}; pattern=${pattern//\[/\\[}
  found=$(find "$parent" -mindepth 1 -maxdepth 1 -name "$pattern" -printf '.') || return 1
  [ -z "$found" ] || return 1
  return 3
}

# reservation_listing DIR DEPTH: only a proven absent directory is empty.
reservation_listing() {
  local rc
  reservation_directory "$1"; rc=$?
  case "$rc" in 3) return 0 ;; 0) ;; *) return 1 ;; esac
  find -L "$1" -mindepth 1 -maxdepth "$2" -print
}

# reservations_named NAME...: each live fm-disk-room reservation file, Linux or
# D: pool, named one of NAMEs (a pid that exists, or a ttl not yet passed).
reservations_named() {
  local dir f n pid expires t listing live
  dir=${FM_DISK_ROOM_STATE:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/fm-disk-room}
  t=$(date +%s) || return 1
  listing=$(reservation_listing "$dir/reservations" 1 && reservation_listing "$dir/reservations-d" 2) || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for n in "$@"; do
      [ "${f##*/}" = "$n" ] || continue
      [ -f "$f" ] || return 1
      pid=$(sed -n 's/^pid=//p' "$f") && expires=$(sed -n 's/^expires=//p' "$f") || return 1
      if [ -n "$pid" ]; then
        [[ $pid =~ ^[0-9]+$ ]] || return 1
        live=$(find /proc -mindepth 1 -maxdepth 1 -type d -name "$pid" -print) || return 1
        [ -n "$live" ] || continue
      elif [ -n "$expires" ]; then
        [[ $expires =~ ^[0-9]{1,10}$ ]] || return 1
        [ "$t" -ge "$((10#$expires))" ] && continue
      fi
      printf '%s\n' "$f"
    done
  done <<<"$listing"
}

# links SRC [ALSO...]: "files FILES", "freed BYTES" (each inode once), then
# "out N PATH" for a multi-link file with N names neither in SRC nor in ALSO,
# and "bad PATH" for an ALSO that is no link of a file in SRC.
links() {
  local src=$1 a; shift
  {
    find "$src" -xdev -type f -printf 'i\t%D:%i\t%n\t%s\t%p\n' || return 1
    for a in "$@"; do stat -c $'a\t%d:%i\t%h\t%s\t%n' -- "$a" || return 1; done
  } | awk -F'\t' '
    $1 == "i" { files++; if (!($2 in size)) { size[$2] = $4; nl[$2] = $3; path[$2] = $5 } ins[$2]++; next }
    { if ($2 in size) oth[$2]++; else print "bad\t" $5 }
    END { for (k in size) { freed += size[k]; left = nl[k] - ins[k] - oth[k]; if (left > 0) print "out\t" left "\t" path[k] }
      printf "files\t%.0f\nfreed\t%.0f\n", files, freed }'
}

# release_record STATE FILES FREED [RELEASED_AT]: write UNIT.release.json.
release_record() {
  local tmp=$REL_RECORD.tmp
  jq -n --arg unit "$IUNIT" --arg image "$IMG" --arg image_sha "$REL_IMAGE_SHA" \
    --arg src "$REL_SRC" --arg state "$1" --arg accepted "$REL_ACCEPTED" --arg note "$REL_NOTE" \
    --arg refs "$REL_REFS" --arg also "$REL_ALSO" --arg owner "${FM_HOME:-$(cd "$BIN/.." && pwd)}" \
    --argjson window "$REL_WINDOW" --argjson verified "$REL_VERIFIED" --argjson files "$2" --argjson freed "$3" \
    --argjson released "${4:-null}" \
    '{format: "fm-pack-release/v1", unit: $unit, image: $image, image_sha256: $image_sha, src: $src,
      state: $state, accepted_by: $accepted, note: $note, refs: ($refs | split("\n") | map(select(. != ""))),
      also: ($also | split("\n") | map(select(. != ""))), owner_home: $owner, window_seconds: $window,
      verified_at: $verified, files: $files, freed_bytes: $freed, released_at: $released}' >"$tmp" &&
    mv -f -- "$tmp" "$REL_RECORD"
}

# stored_md RELEASED_AT: the stub left at SRC's old place.
stored_md() {
  cat <<MD
# Stored in a packed image

This directory was packed into an image and released by fm-pack.sh release.

- image: $IMG
- image sha256: $REL_IMAGE_SHA
- record: $REL_RECORD
- accepted by: $REL_ACCEPTED
- released at: $(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ)

Restore it with \`bin/fm-pack.sh restore $IMG DEST\`.
MD
}

REL_ACCEPTED='' REL_NOTE='' REL_REFS='' REL_ALSO='' REL_WINDOW=0 REL_VERIFIED=0

cmd_release() {
  local given src recorded ref a out now released files freed state
  local refs=() also=() names=()
  [ "$#" -ge 2 ] || die "release needs IMAGE SRC"
  need unsquashfs sha256sum jq flock python3
  need_reader
  load_image "$1"
  [ "$IFORMAT" = fm-pack-unit/v1 ] || die "release reads fm-pack's own tree list; $IJSON is $IFORMAT"
  given=$2; shift 2
  REL_WINDOW=${FM_PACK_RELEASE_WINDOW:-0}
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --accepted-by) REL_ACCEPTED=$2 ;;
      --note) REL_NOTE=$2 ;;
      --ref) refs+=("$2") ;;
      --also) also+=("$2") ;;
      --window) REL_WINDOW=$2 ;;
      *) die "unknown release argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$REL_ACCEPTED" ] || die "release needs --accepted-by WHO: no acceptance, no release"
  [[ $REL_ACCEPTED =~ ^[A-Za-z0-9._@:/-]+$ ]] || die "--accepted-by must be letters, digits, . _ @ : / -"
  case "$REL_NOTE" in *"$NL"*) die "--note must be one line" ;; esac
  [[ $REL_WINDOW =~ ^[0-9]{1,10}$ ]] || die "the window must be whole seconds, not $REL_WINDOW"
  REL_WINDOW=$((10#$REL_WINDOW))
  REL_VERIFIED=$(sidecar verified_at "$IJSON") && [[ $REL_VERIFIED =~ ^[0-9]+$ ]] || die "$IJSON has no verified_at"
  recorded=$(sidecar source "$IJSON") || die "$IJSON has no source"

  [ -d "$given" ] && [ ! -L "$given" ] || die "$given is not a real directory"
  src=$(cd -P -- "$given" && pwd -P) || die "cannot resolve $given"
  [ "$src" = "$recorded" ] || die "$src is not the source $IJSON records ($recorded)"
  case "$IDIR/" in "$src"/*) die "$src holds the image $IMG; a release never removes its own image" ;; esac
  REL_SRC=$src
  REL_ASIDE=$(dirname -- "$src")/.${src##*/}.fm-pack-release
  REL_RECORD=$IDIR/$IUNIT.release.json
  out=$(find "$IDIR" -mindepth 1 -maxdepth 1 -name "$IUNIT.release.json" -print) ||
    rel_refuse 1 "release-state-read-failed: $IDIR"
  if [ -n "$out" ]; then
    state=$(jq -r .state "$REL_RECORD" 2>/dev/null)
    [ "$state" != releasing ] || die "$REL_RECORD is in state releasing: a removal stopped partway, what is left is at $REL_ASIDE"
    die "$IUNIT is already released ($REL_RECORD)"
  fi
  out=$(find "$(dirname -- "$src")" -mindepth 1 -maxdepth 1 -name ".${src##*/}.fm-pack-release" -print) ||
    rel_refuse 1 "release-state-read-failed: parent of $src"
  [ -z "$out" ] || die "$REL_ASIDE is left from an earlier release; rename it back to $src, then release again"
  for ref in "${refs[@]}"; do
    [ -f "$ref" ] && [ -r "$ref" ] || die "--ref $ref is not a readable file"
    REL_REFS+=$ref$NL
  done
  for a in "${also[@]}"; do
    [ -f "$a" ] && [ ! -L "$a" ] || die "--also $a is not a regular file"
    a=$(realpath -e -- "$a") || die "cannot resolve --also $a"
    case "$a" in "$src"/*) die "--also $a is inside $src" ;; *"$NL"*) die "--also $a: a newline in the path" ;; esac
    case "$NL$REL_ALSO" in *"$NL$a$NL"*) continue ;; esac
    REL_ALSO+=$a$NL names+=("$a")
  done

  # The lock lives on Linux: D:'s 9p mount need not support flock.
  exec 8>>"${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/fm-pack-release.$IUNIT.lock" || die "cannot open the release lock for $IUNIT"
  flock -n 8 || rel_refuse 75 "another release of $IUNIT holds its lock"
  take_slot "fm-pack release $IMG $src"
  CLEANUP=release_cleanup

  now=$(date +%s)
  [ "$now" -ge $((REL_VERIFIED + REL_WINDOW)) ] ||
    rel_refuse 75 "the release window of $REL_WINDOW s ends at $((REL_VERIFIED + REL_WINDOW)), $((REL_VERIFIED + REL_WINDOW - now)) s from now"
  for ref in "${refs[@]}"; do
    reference_clear "$src" "$ref"
    [ "${given:0:1}" != / ] || [ "$given" = "$src" ] || reference_clear "$given" "$ref"
  done
  in_use "$src" "${names[@]}"
  out=$(reservations_named "$IUNIT" "pack-$IUNIT" "${src##*/}") || rel_refuse 1 "reservation-read-failed: $IUNIT"
  out=${out%%$'\n'*}
  [ -z "$out" ] || rel_refuse 1 "the reservation $out is live"
  out=$(links "$src" "${names[@]}") || rel_refuse 1 "link-census-read-failed: $src"
  [ -n "$out" ] || rel_refuse 1 "the hard-link census of $src failed"
  a=$(printf '%s\n' "$out" | sed -n 's/^bad\t//p') || rel_refuse 1 "link-accounting-read-failed: $src"
  a=${a%%$'\n'*}
  [ -z "$a" ] || die "--also $a is not a link of a file in $src"
  a=$(printf '%s\n' "$out" | sed -n 's/^out\t//p') || rel_refuse 1 "link-accounting-read-failed: $src"
  a=${a%%$'\n'*}
  [ -z "$a" ] || rel_refuse 1 "${a#*$'\t'} has ${a%%$'\t'*} more hard-link name(s) outside $src; name each with --also to release them too"
  files=$(printf '%s\n' "$out" | sed -n 's/^files\t//p') && [[ $files =~ ^[0-9]+$ ]] ||
    rel_refuse 1 "link-accounting-read-failed: $src files"
  freed=$(printf '%s\n' "$out" | sed -n 's/^freed\t//p') && [[ $freed =~ ^[0-9]+$ ]] ||
    rel_refuse 1 "link-accounting-read-failed: $src freed"

  image_sha_ok "$IDIR" "$IUNIT" || rel_refuse 1 "$IMG does not match $IUNIT.sqfs.sha256"
  check_members "$IMG" "$IDIRNAME" "$IMEMBERS" || rel_refuse 1 "$IMG failed the member check ($METHOD)"
  REL_IMAGE_SHA=$(cut -d' ' -f1 <"$IDIR/$IUNIT.sqfs.sha256") && [[ $REL_IMAGE_SHA =~ ^[0-9a-f]{64}$ ]] ||
    rel_refuse 1 "image-hash-read-failed: $IUNIT.sqfs.sha256"
  tree_matches "$src" "$IDIR/$IUNIT.tree.tsv" || rel_refuse 1 "$src no longer matches $IUNIT.tree.tsv"

  REL_PENDING=1
  release_record releasing "$files" "$freed" || rel_refuse 1 "cannot write $REL_RECORD"
  mv -n -T -- "$src" "$REL_ASIDE" 2>/dev/null
  [ -d "$REL_ASIDE" ] && [ ! -e "$src" ] || rel_refuse 1 "cannot rename $src aside to $REL_ASIDE"
  REL_MOVED=1
  if [ -n "${FM_PACK_TEST_BEFORE_RECHECK:-}" ]; then bash -c "$FM_PACK_TEST_BEFORE_RECHECK"; fi
  tree_matches "$REL_ASIDE" "$IDIR/$IUNIT.tree.tsv" || rel_refuse 1 "$src changed while it was renamed aside"
  in_use "$REL_ASIDE" "${names[@]}"

  # Once removal starts, a stop is held until the record says released.
  hold_stops
  REL_MOVED='' REL_PENDING=''
  if ! rm -rf --one-file-system -- "$REL_ASIDE"; then
    note "removing $REL_ASIDE failed partway; what is left stays there and $REL_RECORD stays in state releasing"
    rel_log "failed $IUNIT $src: removing $REL_ASIDE stopped partway; the image verified, the remainder stays there"
    exit 1
  fi
  for a in "${names[@]}"; do
    rm -f -- "$a" || {
      note "removing the hard-link name $a failed; $REL_RECORD stays in state releasing"
      rel_log "failed $IUNIT $src: removed the source but not the hard-link name $a"
      exit 1
    }
  done
  released=$(date +%s)
  { mkdir -- "$src" && stored_md "$released" >"$src/STORED.md"; } ||
    note "cannot leave $src/STORED.md; the release itself is complete"
  release_record released "$files" "$freed" "$released" || note "cannot rewrite $REL_RECORD as released"
  rel_log "released $IUNIT $src: freed $freed bytes ($(awk -v b="$freed" 'BEGIN { printf "%.2f", b / 1073741824 }') GiB), accepted by $REL_ACCEPTED"
  if release_stops; then note "a stop arrived during the removal of $src; the release was finished first"; fi
  printf 'fm-pack-release/v1 image=%s src=%s freed=%s accepted_by=%s released_at=%s record=%s\n' \
    "$IMG" "$src" "$freed" "$REL_ACCEPTED" "$released" "$REL_RECORD"
}

# ---------------------------------------------------------------- candidates

CAND_TMP=''
CAND_TIMEOUT=900
CAND_FAILED=0 CAND_UNREAD=0 CAND_WAIT=0 CAND_GAP=0

# shellcheck disable=SC2329 # Run through CLEANUP by finish.
cand_cleanup() { [ -z "$CAND_TMP" ] || rm -rf -- "$CAND_TMP"; }

# cand_index ROOT...: CAND_TMP/units gets one STATE<TAB>TREE_LIST<TAB>SOURCE
# line per fm-pack-unit/v1 unit; a waiting ROOT sets CAND_WAIT, an unreadable
# sidecar or listing sets CAND_UNREAD and CAND_GAP (a unit may be missing).
cand_index() {
  local root out rc base list img json line fmt src state
  : >"$CAND_TMP/units" || fail1 "cannot write $CAND_TMP/units"
  list=$CAND_TMP/images
  for root in "$@"; do
    out=$("$BIN/fm-storage.sh" verify-bulk-root --root "$root"); rc=$?
    case "$rc" in
      0) ;;
      75) CAND_WAIT=1; continue ;;
      *) exit 2 ;;
    esac
    base=${out%/\{task\}}
    [ "$base/{task}" = "$out" ] && [ -d "$base" ] || { note "candidates: $root: unexpected root $out"; CAND_UNREAD=1 CAND_GAP=1; continue; }
    if ! timeout "$CAND_TIMEOUT" find "$base" -mindepth 2 -maxdepth 2 -name '*.sqfs' -type f -print0 >"$list"; then
      note "candidates: listing the units under $base failed"; CAND_UNREAD=1 CAND_GAP=1; continue
    fi
    while IFS= read -r -d '' img; do
      json=${img%.sqfs}.json
      if ! line=$(jq -er '.format + "\t" + (.source // "" | tostring)' "$json" 2>/dev/null); then
        note "candidates: unreadable sidecar $json"; CAND_UNREAD=1 CAND_GAP=1; continue
      fi
      fmt=${line%%$'\t'*} src=${line#*$'\t'}
      case "$fmt" in
        fm-pack-unit/v1) ;;
        tj-fetch-arrival-unit/v2) continue ;;
        *) note "candidates: unknown unit format $fmt in $json"; CAND_UNREAD=1 CAND_GAP=1; continue ;;
      esac
      state=committed
      if [ -e "${img%.sqfs}.release.json" ]; then
        state=$(jq -er .state "${img%.sqfs}.release.json" 2>/dev/null) || state=''
        case "$state" in released|releasing) ;; *) state=unreadable ;; esac
      fi
      printf '%s\t%s\t%s\n' "$state" "${img%.sqfs}.tree.tsv" "$src" >>"$CAND_TMP/units"
    done <"$list"
  done
}

# cand_unchanged TREE TREE_LIST: 0 the tree matches the list, 1 it differs,
# 2 the walk or the comparison failed.
cand_unchanged() {
  local raw=$CAND_TMP/tree.raw sorted=$CAND_TMP/tree.tsv
  (cd "$1" && timeout "$CAND_TIMEOUT" find . -xdev -printf "$TREE_FORMAT") >"$raw" 2>/dev/null || return 2
  LC_ALL=C sort -t$'\t' -k7 "$raw" >"$sorted" || return 2
  cmp -s "$sorted" "$2"
  case "$?" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# cand_pack TREE: sets CAND_PACK to the pack column for TREE (see the header).
CAND_PACK=''
cand_pack() {
  local tree=$1 state list src best='' rank=9 r
  while IFS=$'\t' read -r state list src; do
    [ "$src" = "$tree" ] || continue
    case "$state" in
      committed)
        cand_unchanged "$tree" "$list"
        case "$?" in
          0) state=verified ;;
          1) state=changed ;;
          *) note "candidates: re-walking $tree against $list failed"; state=unknown ;;
        esac ;;
      unreadable) note "candidates: unreadable release record beside $list"; state=unknown ;;
    esac
    case "$state" in verified) r=0 ;; releasing) r=1 ;; released) r=2 ;; changed) r=3 ;; *) r=4 ;; esac
    [ "$r" -ge "$rank" ] || { rank=$r best=$state; }
  done <"$CAND_TMP/units"
  if [ "$best" = unknown ]; then CAND_UNREAD=1; fi
  if [ -z "$best" ]; then
    if [ "$CAND_GAP" = 1 ] || [ "$CAND_WAIT" = 1 ]; then best=unknown; else best=none; fi
  fi
  CAND_PACK=$best
}

cmd_candidates() {
  local home='' small=65536 now data datadev roots=() line kind dev tree name out err rc
  local alloc logical files smallc newest days bucket label listed=0 recent=0 skipped=0 pct
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
      --root) [ "$#" -ge 2 ] || die "--root needs a name"; roots+=("$2"); shift 2 ;;
      --timeout)
        [ "$#" -ge 2 ] && [[ $2 =~ ^[1-9][0-9]{0,5}$ ]] || die "--timeout needs whole seconds"
        CAND_TIMEOUT=$2; shift 2 ;;
      --small)
        [ "$#" -ge 2 ] && [[ $2 =~ ^[1-9][0-9]{0,8}[KMG]?$ ]] || die "--small needs a size in bytes or with K, M or G"
        small=${2%[KMG]}
        case "$2" in
          *K) small=$((small * 1024)) ;;
          *M) small=$((small * 1048576)) ;;
          *G) small=$((small * 1073741824)) ;;
        esac
        shift 2 ;;
      *) die "candidates takes --home HOME [--root ROOT]... [--timeout SECONDS] [--small SIZE]" ;;
    esac
  done
  [ -n "$home" ] || die "candidates needs --home HOME"
  [ "${#roots[@]}" -gt 0 ] || roots=(tetjet-results research)
  now=${FM_PACK_NOW:-$(date +%s)}
  [[ $now =~ ^[0-9]{1,12}$ ]] || die "FM_PACK_NOW must be epoch seconds"
  need find jq timeout sort awk
  [ -d "$home" ] || die "$home is not a directory"
  home=$(cd -P -- "$home" && pwd -P) || die "cannot resolve $home"
  CAND_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pack-candidates.XXXXXX") || fail1 "cannot create a temp directory"
  CLEANUP=cand_cleanup
  trap 'exit 130' INT
  trap 'exit 143' TERM
  : >"$CAND_TMP/rows" || fail1 "cannot write $CAND_TMP/rows"
  data=''
  if [ -e "$home/data" ] || [ -L "$home/data" ]; then
    [ -d "$home/data" ] || die "$home/data is not a directory"
    data=$(cd -P -- "$home/data" && pwd -P) || die "cannot resolve $home/data"
    datadev=$(find "$data" -maxdepth 0 -printf '%D') && [ -n "$datadev" ] || die "cannot read $data"
    find "$data" -mindepth 1 -maxdepth 1 -printf '%y %D %f\0' >"$CAND_TMP/trees" || die "cannot list $data"
  else
    : >"$CAND_TMP/trees"
  fi
  cand_index "${roots[@]}"

  while IFS= read -r -d '' line; do
    kind=${line%% *} line=${line#* }
    dev=${line%% *} name=${line#* }
    case "$kind" in d) ;; l) skipped=$((skipped + 1)); continue ;; *) continue ;; esac
    case "$name" in *$'\t'*|*$'\n'*|*\\*) note "candidates: skipped a tree name holding a tab, newline or backslash"; skipped=$((skipped + 1)); continue ;; esac
    tree=$data/$name
    [ "$dev" = "$datadev" ] || { skipped=$((skipped + 1)); continue; }
    out=$CAND_TMP/walk err=$CAND_TMP/walk.err
    timeout "$CAND_TIMEOUT" find "$tree" -xdev -printf '%y %n %i %s %b %T@\n' 2>"$err" |
      awk -v small="$small" '
        { first = 1
          if ($1 != "d" && $2 > 1) { if ($3 in seen) first = 0; else seen[$3] = 1 }
          if (first) { alloc += $5 * 512; if ($1 == "f") logical += $4 }
          if ($1 == "f") { files++; if ($4 < small) smallc++ }
          if (NR == 1 || $6 > newest) newest = $6 }
        END { printf "%.0f %.0f %.0f %.0f %.0f\n", alloc, logical, files, smallc, int(newest) }' >"$out"
    rc="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
    if [ "$rc" != "0 0" ] || ! read -r alloc logical files smallc newest <"$out" || [ -z "$newest" ]; then
      CAND_FAILED=$((CAND_FAILED + 1))
      case "${rc%% *}" in 124) label=timeout ;; *) label=read-error ;; esac
      note "candidates: walking $tree failed ($label): $(head -n 1 "$err" 2>/dev/null)"
      printf '2\t0\tfailed\t-\t-\t-\t-\t-\t-\t%s\t%s\n' "$label" "$tree" >>"$CAND_TMP/rows"
      continue
    fi
    days=$(( (now - newest) / 86400 ))
    if [ "$days" -lt 7 ]; then recent=$((recent + 1)); continue; fi
    if [ "$days" -ge 30 ]; then bucket=0 label=30d+; else bucket=1 label=7d+; fi
    cand_pack "$tree"
    if [ "$files" -gt 0 ]; then pct=$(awk -v s="$smallc" -v f="$files" 'BEGIN { printf "%.1f", 100 * s / f }'); else pct=0.0; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$bucket" "$alloc" "$label" "$days" "$alloc" \
      "$logical" "$files" "$pct" "$(date -u -d "@$newest" +%Y-%m-%dT%H:%M:%SZ)" "$CAND_PACK" "$tree" >>"$CAND_TMP/rows"
    listed=$((listed + 1))
  done <"$CAND_TMP/trees"

  printf 'fm-pack-candidates/v1 home=%s now=%s small=%s listed=%s recent=%s skipped=%s failed=%s\n' \
    "$home" "$now" "$small" "$listed" "$recent" "$skipped" "$CAND_FAILED"
  printf 'bucket\tdays\tallocated\tlogical\tfiles\tsmall_pct\tnewest\tpack\ttree\n'
  LC_ALL=C sort -t$'\t' -k1,1n -k2,2nr -k11 "$CAND_TMP/rows" | cut -f3- || fail1 "cannot sort the rows"
  if [ "$CAND_FAILED" -gt 0 ] || [ "$CAND_UNREAD" = 1 ]; then exit 1; fi
  [ "$CAND_WAIT" = 0 ] || exit 75
}

# One block, read whole before it runs, so an update of this file during a
# long command cannot change what the running command reads next.
{
  case "${1:-}" in
    pack|verify|verify-tar|restore|release|candidates) prepare "$@" ;;
  esac
  case "${1:-}" in
    pack) shift; cmd_pack "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    verify-tar) shift; cmd_verify_tar "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    release) shift; cmd_release "$@" ;;
    candidates) shift; cmd_candidates "$@" ;;
    stop) shift; cmd_stop "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
  exit
}
