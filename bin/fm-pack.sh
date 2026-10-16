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
#       Exit 0 committed; 75 wait (D: unavailable, low room, or pack-UNIT
#       already reserved), nothing written; 1 refused after admission (SRC
#       changed, the image failed verify, a tool failed), nothing committed and
#       this run's staging removed; 2 misuse, a name SRC holds that the lists
#       cannot carry (a newline or a backslash), UNIT already at R, or stale
#       staging for UNIT in R/.incoming.
#   fm-pack.sh verify IMAGE [--against SRC]
#       IMAGE is R/UNIT.sqfs with its sidecars beside it. Checks the image
#       sha256, then reads the image afresh: every member's sha256 and the
#       regular-file count must match UNIT.members.sha256. With --against, SRC
#       must also still match UNIT.tree.tsv, the check to repeat before an
#       owner removes the source. Exit 0 verified, 1 a mismatch, 2 misuse.
#   fm-pack.sh restore IMAGE DEST
#       Check the image sha256, then fm-disk-room.sh run --name restore-UNIT
#       --expect-write <logical bytes> -- unsquashfs -d DEST IMAGE, then the
#       member check on DEST/basename(SRC). DEST must not exist yet. Exit 0
#       restored and checked, 75 refused for room, 1 a failure, 2 misuse.
#
# Reading the image afresh: a new squashfuse -o ro mount on a temporary
# directory (fusermount3 -u afterwards) when /dev/fuse is usable, else
# unsquashfs -lln for the count and unsquashfs -cat per member. The UNIT.json
# verify_method field and verify's output name the path taken.
#
# UNIT.json (fm-pack-unit/v1) holds the source, its directory name, the owner
# home, task, root, counts, both sha256 values, the mksquashfs version, and
# packed_at and verified_at (epoch seconds), so an owner can read its
# rollback window from the sidecar.
#
# fm-pack.sh never deletes or rewrites SRC, keeps no index (the sidecars beside
# the image are the manifest), and never removes anything it did not create in
# this run. Heavy steps run at nice 19 and idle I/O priority.
#
# Environment (all optional):
#   FM_PACK_MOUNT   auto (default): mount when usable, else unsquashfs;
#                   off: always unsquashfs; require: mount or fail
#   FM_HOME         owner home recorded in UNIT.json (default this checkout)
#   FM_PACK_TEST_BEFORE_RECHECK  test hook only: a command run by bash -c
#                   between packing and the source re-check
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

# tree_list DIR: the tree list of DIR on stdout (docs/storage.md step 4).
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

# check_members_mount IMAGE DIR MEMBERS: 0 match, 1 mismatch, 3 cannot mount.
check_members_mount() {
  local img=$1 dir=$2 members=$3 count rc
  MNT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pack-verify.XXXXXX") || return 3
  if ! squashfuse -o ro "$img" "$MNT" 2>/dev/null; then
    rmdir "$MNT"; MNT=''
    return 3
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
  local img=$1 dir=$2 members=$3 line want path got count n=0
  count=$(unsquashfs -no-wildcards -lln "$img" "$dir" 2>/dev/null | grep -c '^-') || count=0
  [ "$count" = "$(wc -l <"$members")" ] || { note "the image holds $count files, the members list $(wc -l <"$members")"; return 1; }
  while IFS= read -r line; do
    n=$((n + 1))
    want=${line:0:64} path=${line:66}
    [[ $want =~ ^[0-9a-f]{64}$ ]] && [ "${line:64:2}" = '  ' ] && [ "${path:0:2}" = './' ] ||
      { note "members line $n is malformed"; return 1; }
    got=$(heavy unsquashfs -no-wildcards -cat "$img" "$dir/${path#./}" 2>/dev/null | sha256sum; exit "${PIPESTATUS[0]}") || got=''
    [ "${got%% *}" = "$want" ] || { note "$path: FAILED"; return 1; }
  done <"$members"
}

# check_members IMAGE DIR MEMBERS: sets METHOD; 0 match, 1 mismatch.
METHOD=''
check_members() {
  local mode=${FM_PACK_MOUNT:-auto} rc
  case "$mode" in auto|off|require) ;; *) die "FM_PACK_MOUNT must be auto, off or require" ;; esac
  if [ "$mode" != off ] && mount_usable; then
    METHOD=mount
    check_members_mount "$@"; rc=$?
    [ "$rc" != 3 ] && return "$rc"
    [ "$mode" = require ] && { note "squashfuse could not mount $1"; return 1; }
    note "squashfuse could not mount $1; reading it with unsquashfs"
  elif [ "$mode" = require ]; then
    note "no usable /dev/fuse, squashfuse and fusermount3"; return 1
  fi
  METHOD=unsquashfs
  check_members_unsquashfs "$@"
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
  [ -d "$src" ] && [ ! -L "$src" ] || die "$src is not a real directory"
  src=$(cd -P -- "$src" && pwd -P) || die "cannot resolve $src"
  dir=${src##*/}
  [ -n "$dir" ] || die "cannot pack /"
  case "$src" in *"$NL"*|*\\*) die "$src: a newline or backslash in the path" ;; esac
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

# load_image IMAGE: sets IDIR, IUNIT, IJSON, IMEMBERS after checking the sidecars.
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
  IDIRNAME=$(sidecar dir "$IJSON") || die "$IJSON has no dir"
}

cmd_verify() {
  local against=''
  [ "$#" -ge 1 ] || die "verify needs IMAGE"
  need unsquashfs sha256sum jq
  load_image "$1"; shift
  if [ "${1:-}" = --against ]; then
    [ "$#" = 2 ] || die "--against needs SRC"
    against=$2
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

case "${1:-}" in
  pack) shift; cmd_pack "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
