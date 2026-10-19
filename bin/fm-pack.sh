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
#             already reserved), nothing written.
#   fm-pack.sh verify IMAGE [--against SRC]
#       IMAGE is R/UNIT.sqfs with its sidecars beside it. Checks the image
#       sha256, then reads the image afresh: every member's sha256 and the
#       regular-file count must match UNIT.members.sha256. With --against, SRC
#       must also still match UNIT.tree.tsv, the check to repeat before an
#       owner removes the source. Exit 0 verified, 1 a mismatch, 2 misuse.
#       verify, restore and release read a unit whose UNIT.json format is
#       fm-pack-unit/v1 or tj-fetch-arrival-unit/v2 (a lattice-research fetch
#       arrival, whose members list carries paths without ./), and refuse any
#       other or missing format with exit 2 before any work. An arrival unit's
#       tree list is not fm-pack's, so --against and release refuse it with 2.
#   fm-pack.sh restore IMAGE DEST
#       Check the image sha256, then fm-disk-room.sh run --name restore-UNIT
#       --expect-write <logical bytes> -- unsquashfs -d DEST IMAGE, then the
#       member check on DEST/basename(SRC). DEST must not exist yet. Exit 0
#       restored and checked, 75 refused for room, 1 a failure, 2 misuse.
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
#            SRC or on an --also name;
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
#       included; GiB freed is freed / 1073741824.
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
#         75  wait, nothing deleted: the window has not passed, or another
#             release of the unit holds its lock (a file in XDG_RUNTIME_DIR,
#             else TMPDIR, else /tmp).
#
# Reading the image afresh: a new squashfuse -o ro mount on a temporary
# directory (fusermount3 -u afterwards). pack and verify refuse with exit 2
# before any work when squashfuse, fusermount3 or a usable /dev/fuse is
# missing, unless FM_PACK_MOUNT=unsquashfs names the slow path. The UNIT.json
# verify_method field and verify's output name the path taken.
#
# UNIT.json (fm-pack-unit/v1) holds the source, its directory name, the owner
# home, task, root, counts, both sha256 values, the mksquashfs version, and
# packed_at and verified_at (epoch seconds), so an owner can read its
# release window from the sidecar.
#
# Only release deletes SRC, and only after every guard holds; pack, verify and
# restore never delete or rewrite it. fm-pack.sh keeps no index (the sidecars
# beside the image are the manifest), and pack and restore never remove
# anything they did not create in this run. Heavy steps run at nice 19 and
# idle I/O priority.
#
# Environment (all optional):
#   FM_PACK_MOUNT   mount (default): verify through a fresh squashfuse mount;
#                   unsquashfs: for tests and hosts without FUSE, unsquashfs
#                   -lln for the count and one unsquashfs -cat per member,
#                   each rereading the image tables, so roughly quadratic in
#                   the file count
#   FM_HOME         owner home recorded in UNIT.json (default this checkout)
#   FM_PACK_RELEASE_WINDOW  release's default window in seconds (0)
#   FM_PACK_MOUNTINFO  the mount table release reads (/proc/self/mountinfo)
#   FM_DISK_ROOM_STATE  fm-disk-room's state directory, for release's
#                   reservation check (the same default as fm-disk-room.sh)
#   FM_PACK_TEST_BEFORE_RECHECK  test hook only: a command run by bash -c
#                   between packing and the source re-check, and between
#                   release's rename aside and its re-check
set -u

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NL=$'\n'

die() { printf 'fm-pack: %s\n' "$*" >&2; exit 2; }
fail1() { printf 'fm-pack: %s\n' "$*" >&2; exit 1; }
note() { printf 'fm-pack: %s\n' "$*" >&2; }
usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }

heavy() {
  if command -v ionice >/dev/null 2>&1; then nice -n 19 ionice -c3 -t "$@"; else nice -n 19 "$@"; fi
}

need() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "$t is not installed"; done
}

valid_unit() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# tree_list DIR: the tree list of DIR on stdout (pack step 3 above).
tree_list() {
  (cd "$1" && find . -xdev -printf '%y\t%s\t%m\t%n\t%T@\t%l\t%p\n' | LC_ALL=C sort -t$'\t' -k7)
}

# members_list DIR: sha256sum lines of every regular file under DIR, sorted.
members_list() {
  (cd "$1" && set -o pipefail && find . -xdev -type f -print0 | LC_ALL=C sort -z | heavy xargs -0 -r sha256sum --)
}

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
check_members_mount() {
  local img=$1 dir=$2 members=$3 count rc
  MNT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pack-verify.XXXXXX") || return 1
  if ! squashfuse -o ro "$img" "$MNT" 2>/dev/null; then
    rmdir "$MNT"; MNT=''
    note "squashfuse could not mount $img"; return 1
  fi
  if [ ! -d "$MNT/$dir" ] || [ -L "$MNT/$dir" ]; then
    note "the image holds no directory $dir"; unmount_verify; return 1
  fi
  rc=0
  (cd "$MNT/$dir" && heavy sha256sum --quiet --strict -c -- "$members") || rc=1
  if [ "$rc" = 0 ]; then
    count=$(cd "$MNT/$dir" && find . -type f | wc -l)
    [ "$count" = "$(wc -l <"$members")" ] || { note "the image holds $count files, the members list $(wc -l <"$members")"; rc=1; }
  fi
  unmount_verify
  return "$rc"
}

# check_members_unsquashfs IMAGE DIR MEMBERS: 0 match, 1 mismatch.
check_members_unsquashfs() {
  local img=$1 dir=$2 members=$3 line want path got count n=0 bare=''
  [ "${IFORMAT:-}" = tj-fetch-arrival-unit/v2 ] && bare=1
  count=$(unsquashfs -no-wildcards -lln "$img" "$dir" 2>/dev/null | grep -c '^-') || count=0
  [ "$count" = "$(wc -l <"$members")" ] || { note "the image holds $count files, the members list $(wc -l <"$members")"; return 1; }
  while IFS= read -r line; do
    n=$((n + 1))
    want=${line:0:64} path=${line:66}
    if [ "${path:0:2}" = './' ]; then path=${path#./}; elif [ -z "$bare" ]; then path=''; fi
    [[ $want =~ ^[0-9a-f]{64}$ ]] && [ "${line:64:2}" = '  ' ] && [ -n "$path" ] ||
      { note "members line $n is malformed"; return 1; }
    got=$(heavy unsquashfs -no-wildcards -cat "$img" "$dir/$path" 2>/dev/null | sha256sum; exit "${PIPESTATUS[0]}") || got=''
    [ "${got%% *}" = "$want" ] || { note "$path: FAILED"; return 1; }
  done <"$members"
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
image_sha_ok() { (cd "$1" && heavy sha256sum --quiet --strict -c -- "$2.sqfs.sha256"); }

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

  trap pack_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
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

  members_list "$src" >"$I/$UNIT.members.sha256" || fail1 "hashing $src failed"
  tree_list "$src" >"$I/$UNIT.tree.tsv" || fail1 "listing $src failed"
  [ "$(wc -l <"$I/$UNIT.members.sha256")" = "$files" ] || fail1 "$src changed during the census"

  packed_at=$(date +%s)
  heavy mksquashfs "$src" "$I/$UNIT.sqfs" -noappend -keep-as-directory -one-file-system -comp gzip -no-xattrs \
    -processors 2 -mem 512M -quiet -no-progress >&2 || fail1 "mksquashfs failed"
  sync -f "$I/$UNIT.sqfs" 2>/dev/null || sync
  (cd "$I" && sha256sum -- "$UNIT.sqfs" >"$UNIT.sqfs.sha256") || fail1 "hashing the image failed"

  if [ -n "${FM_PACK_TEST_BEFORE_RECHECK:-}" ]; then bash -c "$FM_PACK_TEST_BEFORE_RECHECK"; fi
  recheck=$I/$UNIT.recheck.tsv
  tree_list "$src" >"$recheck" || fail1 "listing $src again failed"
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

  for f in sqfs.sha256 members.sha256 tree.tsv sqfs json; do
    mv -n -- "$I/$UNIT.$f" "$R/$UNIT.$f" && [ ! -e "$I/$UNIT.$f" ] || fail1 "committing $UNIT.$f failed"
    COMMITTED=partial
  done
  COMMITTED=1
  sync -f "$R/$UNIT.json" 2>/dev/null || sync
  rmdir "$I" 2>/dev/null
  pack_cleanup
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
  trap unmount_verify EXIT
  image_sha_ok "$IDIR" "$IUNIT" || fail1 "$IMG does not match $IUNIT.sqfs.sha256"
  check_members "$IMG" "$IDIRNAME" "$IMEMBERS" || fail1 "$IMG failed the member check ($METHOD)"
  if [ -n "$against" ]; then
    [ -d "$against" ] || fail1 "$against is not a directory"
    cmp -s <(tree_list "$against") "$IDIR/$IUNIT.tree.tsv" || fail1 "$against no longer matches $IUNIT.tree.tsv"
  fi
  printf 'fm-pack: verified %s (%s files, %s)%s\n' "$IMG" "$(wc -l <"$IMEMBERS")" "$METHOD" "${against:+, source unchanged}"
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
  image_sha_ok "$IDIR" "$IUNIT" || fail1 "$IMG does not match $IUNIT.sqfs.sha256"
  "$BIN/fm-disk-room.sh" run --name "restore-$IUNIT" --expect-write "$logical" -- \
    nice -n 19 unsquashfs -no-progress -quiet -d "$dest" "$IMG" >&2
  case $? in
    0) ;;
    75) exit 75 ;;
    *) fail1 "unsquashfs into $dest failed" ;;
  esac
  (cd "$dest/$IDIRNAME" && heavy sha256sum --quiet --strict -c -- "$IMEMBERS") || fail1 "$dest failed the member check"
  printf 'fm-pack: restored %s into %s/%s and checked %s files\n' "$IMG" "$dest" "$IDIRNAME" "$(wc -l <"$IMEMBERS")"
}

# ---------------------------------------------------------------- release

REL_SRC='' REL_ASIDE='' REL_RECORD='' REL_PENDING='' REL_MOVED=''

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
# open file is PATH, under it, or one of the NAMEs.
procs_in() {
  local p=$1; shift
  find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) \
    -printf '%p\t%l\n' 2>/dev/null |
    awk -F'\t' -v p="$p" -v names="$(printf '%s\n' "$@")" '
      BEGIN { n = split(names, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") x[a[i]] = 1 }
      { t = $2; sub(/ \(deleted\)$/, "", t)
        if (t == p || index(t, p "/") == 1 || (t in x)) { split($1, q, "/"); print q[3] "\t" t } }' |
    LC_ALL=C sort -u
}

# in_use PATH [NAME...]: refuse when PATH or under it is a mount point, or a
# process uses PATH, a path under it, or a NAME.
in_use() {
  local p=$1 tab=${FM_PACK_MOUNTINFO:-/proc/self/mountinfo} out
  [ -r "$tab" ] || rel_refuse 1 "cannot read the mount table $tab"
  [ -r /proc/self/fd ] || rel_refuse 1 "cannot read /proc to find the processes that use $p"
  out=$(mounts_in "$p" | head -n1)
  [ -z "$out" ] || rel_refuse 1 "$out is a mount point at or inside $p"
  out=$(procs_in "$@" | head -n1)
  [ -z "$out" ] || rel_refuse 1 "process ${out%%$'\t'*} ($(cat "/proc/${out%%$'\t'*}/comm" 2>/dev/null)) uses ${out#*$'\t'}"
}

# reservations_named NAME...: each live fm-disk-room reservation file, Linux or
# D: pool, named one of NAMEs (a pid that exists, or a ttl not yet passed).
reservations_named() {
  local dir f n pid expires t
  dir=${FM_DISK_ROOM_STATE:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/fm-disk-room}
  t=$(date +%s)
  for f in "$dir"/reservations/* "$dir"/reservations-d/*/*; do
    [ -f "$f" ] || continue
    for n in "$@"; do
      [ "${f##*/}" = "$n" ] || continue
      pid=$(sed -n 's/^pid=//p' "$f"); expires=$(sed -n 's/^expires=//p' "$f")
      if [ -n "$pid" ]; then
        [ -d "/proc/$pid" ] || continue
      elif [ -n "$expires" ] && [ "$t" -ge "$expires" ] 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$f"
    done
  done
}

# links SRC [ALSO...]: "files FILES", "freed BYTES" (each inode once), then
# "out N PATH" for a multi-link file with N names neither in SRC nor in ALSO,
# and "bad PATH" for an ALSO that is no link of a file in SRC.
links() {
  local src=$1 a; shift
  {
    find "$src" -xdev -type f -printf 'i\t%D:%i\t%n\t%s\t%p\n'
    for a in "$@"; do stat -c $'a\t%d:%i\t%h\t%s\t%n' -- "$a"; done
  } | awk -F'\t' '
    $1 == "i" { files++; if (!($2 in size)) { size[$2] = $4; nl[$2] = $3; path[$2] = $5 } ins[$2]++; next }
    { if ($2 in size) oth[$2]++; else print "bad\t" $5 }
    END { for (k in size) { freed += size[k]; left = nl[k] - ins[k] - oth[k]; if (left > 0) print "out\t" left "\t" path[k] }
      printf "files\t%.0f\nfreed\t%.0f\n", files, freed }'
}

# release_record STATE FILES FREED [RELEASED_AT]: write UNIT.release.json.
release_record() {
  local tmp=$REL_RECORD.tmp
  jq -n --arg unit "$IUNIT" --arg image "$IMG" --arg image_sha "$(cut -d' ' -f1 <"$IDIR/$IUNIT.sqfs.sha256")" \
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
- image sha256: $(cut -d' ' -f1 <"$IDIR/$IUNIT.sqfs.sha256")
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
  need unsquashfs sha256sum jq flock
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
  if [ -e "$REL_RECORD" ]; then
    state=$(jq -r .state "$REL_RECORD" 2>/dev/null)
    [ "$state" != releasing ] || die "$REL_RECORD is in state releasing: a removal stopped partway, what is left is at $REL_ASIDE"
    die "$IUNIT is already released ($REL_RECORD)"
  fi
  [ ! -e "$REL_ASIDE" ] && [ ! -L "$REL_ASIDE" ] ||
    die "$REL_ASIDE is left from an earlier release; rename it back to $src, then release again"
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
  trap release_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  now=$(date +%s)
  [ "$now" -ge $((REL_VERIFIED + REL_WINDOW)) ] ||
    rel_refuse 75 "the release window of $REL_WINDOW s ends at $((REL_VERIFIED + REL_WINDOW)), $((REL_VERIFIED + REL_WINDOW - now)) s from now"
  for ref in "${refs[@]}"; do
    ! grep -qF -- "$src" "$ref" || rel_refuse 1 "$ref still names $src"
    [ "${given:0:1}" != / ] || [ "$given" = "$src" ] || ! grep -qF -- "$given" "$ref" || rel_refuse 1 "$ref still names $given"
  done
  in_use "$src" "${names[@]}"
  out=$(reservations_named "$IUNIT" "pack-$IUNIT" "${src##*/}" | head -n1)
  [ -z "$out" ] || rel_refuse 1 "the reservation $out is live"
  out=$(links "$src" "${names[@]}")
  [ -n "$out" ] || rel_refuse 1 "the hard-link census of $src failed"
  a=$(printf '%s\n' "$out" | sed -n 's/^bad\t//p' | head -n1)
  [ -z "$a" ] || die "--also $a is not a link of a file in $src"
  a=$(printf '%s\n' "$out" | sed -n 's/^out\t//p' | head -n1)
  [ -z "$a" ] || rel_refuse 1 "${a#*$'\t'} has ${a%%$'\t'*} more hard-link name(s) outside $src; name each with --also to release them too"
  files=$(printf '%s\n' "$out" | sed -n 's/^files\t//p')
  freed=$(printf '%s\n' "$out" | sed -n 's/^freed\t//p')

  image_sha_ok "$IDIR" "$IUNIT" || rel_refuse 1 "$IMG does not match $IUNIT.sqfs.sha256"
  check_members "$IMG" "$IDIRNAME" "$IMEMBERS" || rel_refuse 1 "$IMG failed the member check ($METHOD)"
  cmp -s <(tree_list "$src") "$IDIR/$IUNIT.tree.tsv" || rel_refuse 1 "$src no longer matches $IUNIT.tree.tsv"

  REL_PENDING=1
  release_record releasing "$files" "$freed" || rel_refuse 1 "cannot write $REL_RECORD"
  mv -n -T -- "$src" "$REL_ASIDE" 2>/dev/null
  [ -d "$REL_ASIDE" ] && [ ! -e "$src" ] || rel_refuse 1 "cannot rename $src aside to $REL_ASIDE"
  REL_MOVED=1
  if [ -n "${FM_PACK_TEST_BEFORE_RECHECK:-}" ]; then bash -c "$FM_PACK_TEST_BEFORE_RECHECK"; fi
  cmp -s <(tree_list "$REL_ASIDE") "$IDIR/$IUNIT.tree.tsv" || rel_refuse 1 "$src changed while it was renamed aside"
  in_use "$REL_ASIDE" "${names[@]}"

  REL_MOVED='' REL_PENDING=''
  if ! heavy rm -rf --one-file-system -- "$REL_ASIDE"; then
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
  printf 'fm-pack-release/v1 image=%s src=%s freed=%s accepted_by=%s released_at=%s record=%s\n' \
    "$IMG" "$src" "$freed" "$REL_ACCEPTED" "$released" "$REL_RECORD"
}

case "${1:-}" in
  pack) shift; cmd_pack "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  release) shift; cmd_release "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
