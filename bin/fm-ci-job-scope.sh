#!/usr/bin/env bash
# fm-ci-job-scope.sh - decide whether a path-scoped CI job runs on a push.
#
# A workflow's `paths:` filter applies to the whole workflow, not to one job,
# so a job that only proves something about a few files asks this script in a
# small job of its own and runs only when the answer is not skip.
#
# The scope is the given roots plus every file they source, followed
# transitively. A line that runs `.` or `source` (at the start of the line or
# after `;`, `&&`, `||`, `{`, `(`, `!`, `then`, `do` or `else`) names each
# literal `<name>.sh` or `<name>.bash` it contains; each name resolves to every
# existing file of that name in the sourcing file's own directory, bin/,
# bin/backends/ and tests/. A source with no literal file name (`. "$1"`,
# `. "$adapter"`) is not followed: the caller picks that file at run time.
# Over-selecting only makes the job run, so the rules err that way.
#
# The changed paths are `git diff --name-only --no-renames <base>...<head>`,
# both sides of a rename included, in the work tree that holds the current
# directory.
#
# With --ref, a ref outside refs/heads/ci/ (a main push) always runs, with no
# diff: the scope only trims ci/** pushes.
#
# Prints exactly one line on stdout and exits 0:
#   run: <ref> is not a ci/** branch
#   run: <path> changed and is in the <n>-file scope
#   skip: none of the <k> changed paths is in the <n>-file scope
#   unknown: <what could not be read>
# unknown means the answer could not be computed: a root or a literally named
# sourced file is missing, or the diff failed. A caller runs the job on unknown
# and raises a warning naming the line, so a broken scope never hides the job.
#
# Usage:
#   fm-ci-job-scope.sh [--ref <pushed-ref>] [--base <ref>] [--head <ref>] <root>...
#                        decide; --base defaults to origin/main, --head to HEAD
#   fm-ci-job-scope.sh --list <root>...
#                        print the scope, one repo-relative path per line, or
#                        the unknown line and exit 1
#   fm-ci-job-scope.sh --help
# Exit: 0 with a decision line, 1 for a --list that cannot be computed, 2 for a
# usage error.
set -u

SELF="${BASH_SOURCE[0]}"

usage() {
  sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "$SELF"
}

die_usage() {
  printf 'fm-ci-job-scope: %s\n' "$1" >&2
  exit 2
}

BASE=origin/main
HEAD_REF=HEAD
PUSHED_REF=
LIST=0
ROOTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage '--base needs a ref'; BASE=$2; shift 2 ;;
    --head) [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage '--head needs a ref'; HEAD_REF=$2; shift 2 ;;
    --ref) [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage '--ref needs a ref'; PUSHED_REF=$2; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ "$#" -gt 0 ]; do ROOTS+=("$1"); shift; done ;;
    -*) die_usage "unknown option: $1" ;;
    *) ROOTS+=("$1"); shift ;;
  esac
done
[ "${#ROOTS[@]}" -gt 0 ] || die_usage 'name at least one root path'

if [ "$LIST" -eq 0 ] && [ -n "$PUSHED_REF" ]; then
  case "$PUSHED_REF" in
    refs/heads/ci/*) ;;
    *) printf 'run: %s is not a ci/** branch\n' "$PUSHED_REF"; exit 0 ;;
  esac
fi

unknown() {
  printf 'unknown: %s\n' "$1"
  [ "$LIST" -eq 0 ] || exit 1
  exit 0
}

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || unknown 'the current directory is not in a git work tree'
cd "$TOP" || unknown "cannot enter the work tree $TOP"

SOURCE_LINE='(^|[;&|{(!]|then|do|else)[[:space:]]*(\.|source)[[:space:]]+[^[:space:]]'

# SCOPE holds one repo-relative path per line, framed by newlines so a lookup
# is one case match; QUEUE holds the paths still to read.
NL='
'
SCOPE=$NL
QUEUE=
COUNT=0

add() {
  case "$SCOPE" in *"$NL$1$NL"*) return 0 ;; esac
  SCOPE="$SCOPE$1$NL"
  QUEUE="$QUEUE$1$NL"
  COUNT=$((COUNT + 1))
}

for root in "${ROOTS[@]}"; do
  root=${root#./}
  [ -f "$root" ] || unknown "root $root is not a file in $TOP"
  add "$root"
done

while [ -n "$QUEUE" ]; do
  file=${QUEUE%%"$NL"*}
  QUEUE=${QUEUE#*"$NL"}
  case "$file" in */*) dir=${file%/*} ;; *) dir=. ;; esac
  dirs=$dir
  for d in bin bin/backends tests; do
    [ "$d" = "$dir" ] || dirs="$dirs $d"
  done
  lines=$(grep -E "$SOURCE_LINE" "$file") || {
    [ "$?" -eq 1 ] || unknown "cannot read $file"
    continue
  }
  names=$(printf '%s\n' "$lines" | grep -oE '[A-Za-z0-9_.-]+\.(sh|bash)' | LC_ALL=C sort -u) || continue
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    found=0
    for d in $dirs; do
      [ -f "$d/$name" ] || continue
      path=$d/$name
      path=${path#./}
      add "$path"
      found=1
    done
    [ "$found" -eq 1 ] || unknown "$file sources $name, which is not a file in any of: $dirs"
  done <<< "$names"
done

if [ "$LIST" -eq 1 ]; then
  printf '%s' "${SCOPE#"$NL"}" | LC_ALL=C sort
  exit 0
fi

changed=$(git diff --name-only --no-renames "$BASE...$HEAD_REF" 2>/dev/null) \
  || unknown "cannot diff $BASE...$HEAD_REF in $TOP"
total=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  total=$((total + 1))
  case "$SCOPE" in
    *"$NL$path$NL"*)
      printf 'run: %s changed and is in the %s-file scope\n' "$path" "$COUNT"
      exit 0
      ;;
  esac
done <<< "$changed"
printf 'skip: none of the %s changed paths is in the %s-file scope\n' "$total" "$COUNT"
