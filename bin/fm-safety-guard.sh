#!/usr/bin/env bash
# fm-safety-guard.sh - Firstmate's two agent-free CI guards around its risky
# areas, run by the "Test coverage guard" job in .github/workflows/ci.yml.
#
# Two committed lists drive it:
#   tests/safety-core.list   the safety core: agent-free tests covering the
#                            risky areas, one repo-relative test path per line.
#   tests/risky-areas.list   each risky area's script globs and test globs, as
#                            `<area> script|test <glob>` lines; `*` in a glob
#                            also matches `/`. The pre-push review reuses it.
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
#
# Run it from inside the repository being judged. Exit status: 0 clean, 1 a
# rule violated (each violation is printed with its commit and remedy), 2 a
# usage or setup error.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_RUN="$SELF_DIR/fm-test-run.sh"
CORE_LIST=tests/safety-core.list
AREAS_LIST=tests/risky-areas.list
ZERO_SHA=0000000000000000000000000000000000000000

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

run_commits() {
  local before='' head='' default_ref=origin/main base areas_src areas c subject bad=0
  local changed scripts tests area script_globs test_globs touched removed has_test f area_names count=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --before) [ $# -ge 2 ] || die "--before needs a sha"; before=$2; shift 2 ;;
      --head) [ $# -ge 2 ] || die "--head needs a sha"; head=$2; shift 2 ;;
      --default-ref) [ $# -ge 2 ] || die "--default-ref needs a ref"; default_ref=$2; shift 2 ;;
      *) usage; exit 2 ;;
    esac
  done
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
  areas=$(git show "$areas_src:$AREAS_LIST" | list_entries)
  validate_areas "$areas" || die "$AREAS_LIST at $areas_src is invalid"
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
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
