#!/usr/bin/env bash
# fm-safety-guard.sh - Firstmate's agent-free CI guards around its risky
# areas, run by the "Test coverage guard" job in .github/workflows/ci.yml.
#
# Two committed lists drive it:
#   tests/safety-core.list   the safety core: agent-free tests covering the
#                            risky areas, one repo-relative test path per line.
#   tests/risky-areas.list   each risky area's script globs and test globs, as
#                            `<area> script|test <glob>` lines; `*` in a glob
#                            also matches `/`. The lean pre-push review
#                            (bin/fm-lean-review.sh) reuses it.
# Both accept `#` comments and blank lines.
#
# Usage:
#   fm-safety-guard.sh core [--list <path>]
#     Fails when a safety-core entry is missing from the checkout, or is not
#     selected by any CI lane. It reads every whole lane bin/fm-test-run.sh
#     --list-lanes names; `fm-test-run.sh --check-coverage`, run in the same CI
#     job, proves each lane's CI shards partition that lane exactly. It also
#     validates tests/risky-areas.list: every area needs a script line and a
#     test line, and kind must be script or test.
#   fm-safety-guard.sh commits --before <sha> --head <sha> [--default-ref <ref>]
#     Judges every non-merge commit in <before>..<head>, oldest first, so a
#     push is judged commit by commit rather than by its tip. ci/** pushes,
#     pushes to main, and pull requests are handled the same way. When <before>
#     is empty, all zeros (a new branch), not a known commit, or not an
#     ancestor of <head> (a rewritten branch), the range starts at the merge
#     base of <default-ref> (default origin/main) and <head> instead.
#     Two rules, each with its own commit-message override line:
#       - Test-touch: a commit that changes a risky area's script must also add
#         or modify a test matching that area's test globs, or carry a
#         `no-test-needed: <reason>` line.
#       - Safety-core removal: a commit that drops an entry from
#         tests/safety-core.list (including deleting the file) must carry a
#         `safety-core-removal: <reason>` line.
#     The override line may sit anywhere in the message and needs a non-empty
#     reason. The risky areas come from the list at the range base, so a push
#     cannot weaken the rule it is judged by; the head's list is used only
#     when the base has none.
#   fm-safety-guard.sh receipts --before <sha> --head <sha> [--default-ref <ref>]
#     Judges the same range, with the same risky areas, for lean-review
#     receipts: every non-merge commit that changes a risky-area script must
#     carry a `Lean-Review: <receipt id>` commit trailer whose id matches that
#     commit's own diff. A missing trailer, or one naming a different diff,
#     fails, and there is no override line. Other commits need nothing.
#   fm-safety-guard.sh receipt-id <commit>
#     Prints <commit>'s receipt id, judged by the risky-area list at its parent
#     (or at the commit when the parent has none), and exits 1 printing nothing
#     when the commit changes no risky-area script. The id hashes only the part
#     of the diff whose files match an area glob, scripts and tests alike: each
#     file's modes, status, and path plus `git patch-id --stable` of that
#     partial patch. It ignores line numbers, blob ids, the parent, and the
#     message, so it survives a plain rebase and the amend that adds the
#     trailer, while any change to that part of the diff changes it.
#     bin/fm-lean-review.sh writes the trailer only after a passing review.
#
# Run it from inside the repository being judged. Exit status: 0 clean, 1 a
# rule violated (each violation is printed with its commit and remedy) or, for
# receipt-id, no risky script changed, 2 a usage or setup error.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_RUN="$SELF_DIR/fm-test-run.sh"
CORE_LIST=tests/safety-core.list
AREAS_LIST=tests/risky-areas.list
ZERO_SHA=0000000000000000000000000000000000000000
RECEIPT_KEY=Lean-Review

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-safety-guard: %s\n' "$*" >&2
  exit 2
}

# Strip comments and blank lines from list text on stdin.
list_entries() {
  sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' | awk 'NF'
}

# The commit message carries an override line `<key>: <non-empty reason>`.
has_override() { # <commit> <key>
  git log -1 --format=%B "$1" | grep -Eq "^[[:space:]]*$2:[[:space:]]*[^[:space:]]"
}

# True when <path> matches one of the newline-separated globs in <globs>.
path_matches() { # <path> <globs>
  local path=$1 glob
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2053 # the right side is a deliberate glob
    [[ $path == $glob ]] && return 0
  done <<<"$2"
  return 1
}

validate_areas() { # <areas text>
  local bad=0 area kind glob extra areas a
  while read -r area kind glob extra; do
    if [ -z "$glob" ] || [ -n "$extra" ]; then
      printf 'fm-safety-guard: %s: malformed line "%s %s %s %s"\n' "$AREAS_LIST" "$area" "$kind" "$glob" "$extra" >&2
      bad=1
      continue
    fi
    case "$kind" in
      script|test) ;;
      *) printf 'fm-safety-guard: %s: area %s has unknown kind "%s"\n' "$AREAS_LIST" "$area" "$kind" >&2; bad=1 ;;
    esac
  done <<<"$1"
  areas=$(awk '{ print $1 }' <<<"$1" | LC_ALL=C sort -u)
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    awk -v a="$a" '$1 == a && $2 == "script" { f = 1 } END { exit !f }' <<<"$1" \
      || { printf 'fm-safety-guard: %s: area %s has no script line\n' "$AREAS_LIST" "$a" >&2; bad=1; }
    awk -v a="$a" '$1 == a && $2 == "test" { f = 1 } END { exit !f }' <<<"$1" \
      || { printf 'fm-safety-guard: %s: area %s has no test line\n' "$AREAS_LIST" "$a" >&2; bad=1; }
  done <<<"$areas"
  [ -n "$areas" ] || { printf 'fm-safety-guard: %s names no areas\n' "$AREAS_LIST" >&2; bad=1; }
  return "$bad"
}

run_core() {
  local list=$CORE_LIST tmp lane entry bad=0 areas
  while [ $# -gt 0 ]; do
    case "$1" in
      --list) [ $# -ge 2 ] || die "--list needs a path"; list=$2; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  [ -f "$list" ] || die "safety-core list $list not found (run from the repository root)"
  [ -f "$AREAS_LIST" ] || die "risky-area list $AREAS_LIST not found (run from the repository root)"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-safety-guard.XXXXXX") || die "mktemp failed"
  # shellcheck disable=SC2064 # expand tmp now
  trap "rm -rf '$tmp'" EXIT

  : >"$tmp/selected"
  "$TEST_RUN" --list-lanes >"$tmp/lanes" || die "fm-test-run.sh --list-lanes failed"
  while IFS= read -r lane; do
    case "$lane" in
      *-[0-9]*of[0-9]*) continue ;; # a CI shard of a whole lane listed separately
    esac
    "$TEST_RUN" --list --lane "$lane" >>"$tmp/selected" || die "fm-test-run.sh --list --lane $lane failed"
  done <"$tmp/lanes"

  list_entries <"$list" >"$tmp/core"
  [ -s "$tmp/core" ] || { printf 'fm-safety-guard: %s names no tests\n' "$list" >&2; bad=1; }
  while IFS= read -r entry; do
    if [ ! -f "$entry" ]; then
      printf 'fm-safety-guard: safety-core test %s is missing\n' "$entry" >&2
      bad=1
    elif ! grep -Fxq -- "$entry" "$tmp/selected"; then
      printf 'fm-safety-guard: safety-core test %s is not selected by any CI lane\n' "$entry" >&2
      bad=1
    fi
  done <"$tmp/core"

  areas=$(list_entries <"$AREAS_LIST")
  validate_areas "$areas" || bad=1
  [ "$bad" -eq 0 ] || return 1
  printf 'fm-safety-guard: %s safety-core tests present and selected by CI; risky areas valid\n' "$(wc -l <"$tmp/core" | tr -d ' ')"
}

# Print the safety-core entries at <commit>, nothing when the list is absent.
core_at() { # <commit>
  git cat-file -e "$1:$CORE_LIST" 2>/dev/null || return 0
  git show "$1:$CORE_LIST" | list_entries | LC_ALL=C sort -u
}

# Resolve a pushed range into RANGE_HEAD, RANGE_BASE, and RANGE_AREAS (the
# validated risky-area entries at the base, or at the head when the base has
# none), as the header describes for `commits`; prints the judged range.
resolve_range() { # <before> <head> <default-ref>
  local before=$1 head=$2 default_ref=$3 base areas_src
  [ -n "$head" ] || die "--head is required"
  head=$(git rev-parse --verify --quiet "$head^{commit}") || die "head $head is not a known commit"

  base=''
  if [ -n "$before" ] && [ "$before" != "$ZERO_SHA" ] \
    && git rev-parse --verify --quiet "$before^{commit}" >/dev/null \
    && git merge-base --is-ancestor "$before" "$head"; then
    base=$(git rev-parse "$before^{commit}")
  else
    git rev-parse --verify --quiet "$default_ref^{commit}" >/dev/null \
      || die "cannot judge a push without a usable --before: $default_ref is not a known commit"
    base=$(git merge-base "$default_ref" "$head") || die "$default_ref and $head share no history"
  fi
  printf 'fm-safety-guard: judging %s..%s\n' "$base" "$head"

  if git cat-file -e "$base:$AREAS_LIST" 2>/dev/null; then
    areas_src=$base
  elif git cat-file -e "$head:$AREAS_LIST" 2>/dev/null; then
    areas_src=$head
  else
    die "$AREAS_LIST exists at neither $base nor $head"
  fi
  RANGE_AREAS=$(git show "$areas_src:$AREAS_LIST" | list_entries)
  validate_areas "$RANGE_AREAS" || die "$AREAS_LIST at $areas_src is invalid"
  RANGE_HEAD=$head RANGE_BASE=$base
}

# Print the receipt id of <commit> judged by <areas> (the header's receipt-id
# owns what it covers), or nothing when the commit changes no risky script.
receipt_id() { # <commit> <areas>
  local c=$1 areas=$2 globs script_globs f risky=0
  local -a files=()
  globs=$(awk '{ print $3 }' <<<"$areas")
  script_globs=$(awk '$2 == "script" { print $3 }' <<<"$areas")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    path_matches "$f" "$globs" || continue
    files+=("$f")
    if path_matches "$f" "$script_globs"; then risky=1; fi
  done < <(git diff-tree --root --no-commit-id -r --no-renames --name-only "$c")
  [ "$risky" -eq 1 ] || return 0
  {
    printf 'fm-lean-review receipt v1\n'
    git --literal-pathspecs diff-tree --root --no-commit-id -r --no-renames --raw "$c" -- "${files[@]}" \
      | awk -F '\t' '{ split($1, m, " "); print m[1], m[2], m[5], $2 }'
    git --literal-pathspecs diff-tree --root --no-commit-id -r --no-renames -p "$c" -- "${files[@]}" \
      | git patch-id --stable | awk '{ print $1 }'
  } | git hash-object --stdin
}

# Print the risky-area entries a review of <commit> is judged by: the list at
# its parent, or at the commit itself when the parent has none or it is a root.
areas_for_commit() { # <commit>
  local src
  if git cat-file -e "$1^:$AREAS_LIST" 2>/dev/null; then
    src="$1^"
  elif git cat-file -e "$1:$AREAS_LIST" 2>/dev/null; then
    src=$1
  else
    die "$AREAS_LIST exists at neither $1 nor its parent"
  fi
  git show "$src:$AREAS_LIST" | list_entries
}

run_receipt_id() {
  local c areas id
  [ $# -eq 1 ] || { usage; exit 2; }
  c=$(git rev-parse --verify --quiet "$1^{commit}") || die "$1 is not a known commit"
  areas=$(areas_for_commit "$c") || exit 2
  validate_areas "$areas" || die "$AREAS_LIST for $c is invalid"
  id=$(receipt_id "$c" "$areas") || die "could not hash $c"
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

run_receipts() {
  local before='' head='' default_ref=origin/main c subject want have bad=0 count=0 reviewed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --before) [ $# -ge 2 ] || die "--before needs a sha"; before=$2; shift 2 ;;
      --head) [ $# -ge 2 ] || die "--head needs a sha"; head=$2; shift 2 ;;
      --default-ref) [ $# -ge 2 ] || die "--default-ref needs a ref"; default_ref=$2; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  resolve_range "$before" "$head" "$default_ref"

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    count=$((count + 1))
    want=$(receipt_id "$c" "$RANGE_AREAS") || die "could not hash $c"
    [ -n "$want" ] || continue
    reviewed=$((reviewed + 1))
    have=$(git log -1 --format="%(trailers:key=$RECEIPT_KEY,valueonly)" "$c")
    if ! grep -Fxq -- "$want" <<<"$have"; then
      subject=$(git log -1 --format='%h %s' "$c")
      if [ -n "$(tr -d '[:space:]' <<<"$have")" ]; then
        printf 'fm-safety-guard: %s carries a %s receipt for a different diff (want %s)\n' "$subject" "$RECEIPT_KEY" "$want" >&2
      else
        printf 'fm-safety-guard: %s changes a risky script without a %s receipt\n' "$subject" "$RECEIPT_KEY" >&2
      fi
      printf '  run bin/fm-lean-review.sh on that commit and push only after it passes\n' >&2
      bad=1
    fi
  done < <(git rev-list --reverse --no-merges "$RANGE_BASE..$RANGE_HEAD")

  [ "$bad" -eq 0 ] || return 1
  printf 'fm-safety-guard: %s commit(s) judged, %s risky one(s) carry a matching lean-review receipt\n' "$count" "$reviewed"
}

run_commits() {
  local before='' head='' default_ref=origin/main base areas c subject bad=0
  local changed scripts tests area script_globs test_globs touched removed has_test f area_names count=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --before) [ $# -ge 2 ] || die "--before needs a sha"; before=$2; shift 2 ;;
      --head) [ $# -ge 2 ] || die "--head needs a sha"; head=$2; shift 2 ;;
      --default-ref) [ $# -ge 2 ] || die "--default-ref needs a ref"; default_ref=$2; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
  resolve_range "$before" "$head" "$default_ref"
  head=$RANGE_HEAD base=$RANGE_BASE areas=$RANGE_AREAS
  area_names=$(awk '{ print $1 }' <<<"$areas" | LC_ALL=C sort -u)

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    count=$((count + 1))
    subject=$(git log -1 --format='%h %s' "$c")
    changed=$(git diff-tree --root --no-commit-id -r --no-renames --name-status "$c")
    # Any change counts for a script; only an added or modified file counts as
    # touching a test, so deleting a test never satisfies the rule.
    scripts=$(awk -F '\t' '{ print $2 }' <<<"$changed")
    tests=$(awk -F '\t' '$1 == "A" || $1 == "M" { print $2 }' <<<"$changed")

    if ! has_override "$c" no-test-needed; then
      while IFS= read -r area; do
        script_globs=$(awk -v a="$area" '$1 == a && $2 == "script" { print $3 }' <<<"$areas")
        test_globs=$(awk -v a="$area" '$1 == a && $2 == "test" { print $3 }' <<<"$areas")
        touched=''
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          if path_matches "$f" "$script_globs"; then touched="$touched $f"; fi
        done <<<"$scripts"
        [ -n "$touched" ] || continue
        has_test=0
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          if path_matches "$f" "$test_globs"; then has_test=1; break; fi
        done <<<"$tests"
        if [ "$has_test" -eq 0 ]; then
          printf 'fm-safety-guard: %s changes %s risky script(s):%s\n' "$subject" "$area" "$touched" >&2
          printf '  add or change a test matching: %s\n' "$(paste -sd ' ' - <<<"$test_globs")" >&2
          printf '  or explain in the commit message: no-test-needed: <reason>\n' >&2
          bad=1
        fi
      done <<<"$area_names"
    fi

    removed=$(LC_ALL=C comm -23 <(core_at "$c^" 2>/dev/null) <(core_at "$c"))
    if [ -n "$removed" ] && ! has_override "$c" safety-core-removal; then
      printf 'fm-safety-guard: %s drops safety-core test(s) from %s: %s\n' "$subject" "$CORE_LIST" "$(paste -sd ' ' - <<<"$removed")" >&2
      printf '  restore them, or explain in the commit message: safety-core-removal: <reason>\n' >&2
      bad=1
    fi
  done < <(git rev-list --reverse --no-merges "$base..$head")

  [ "$bad" -eq 0 ] || return 1
  printf 'fm-safety-guard: %s commit(s) keep risky-area tests and the safety core\n' "$count"
}

case "${1:-}" in
  core) shift; run_core "$@" ;;
  commits) shift; run_commits "$@" ;;
  receipts) shift; run_receipts "$@" ;;
  receipt-id) shift; run_receipt_id "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
