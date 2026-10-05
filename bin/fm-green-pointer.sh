#!/usr/bin/env bash
# Advance Firstmate's green pointer branch to one commit whose CI passed.
#
# The pointer is the branch running homes follow instead of raw main
# (bin/fm-ff-lib.sh's origin base mode), so it must only ever name a commit on
# main whose CI run concluded success. .github/workflows/green-pointer.yml runs
# this from the repo's checkout after the CI workflow completes successfully on
# a push to main, passing that run's head commit.
#
# The pointer moves by fast-forward only, through a plain push that the server
# itself refuses unless it is a fast-forward, so it never moves backward, onto
# another line of history, or onto a commit this script was not handed:
#   - absent on the remote: created at <sha>.
#   - already at <sha>: nothing to do.
#   - already past <sha> (an older run completed after a newer one): left alone.
#   - behind <sha>: fast-forwarded to <sha>.
#   - on a line of history <sha> does not contain: refused with exit 1, so the
#     workflow fails visibly instead of the pointer being forced.
# A <sha> that is not on the remote's base branch is skipped, never published.
# A push refused because another completion moved the pointer first is
# re-evaluated against the new pointer, a bounded number of times.
#
# Usage: fm-green-pointer.sh <full-commit-sha> [--remote <name>] [--pointer <branch>] [--base <branch>]
#   Run inside a clone whose <remote> (default origin) it may push to.
#   --pointer defaults to green and --base to main.
set -eu

usage() {
  echo "usage: fm-green-pointer.sh <full-commit-sha> [--remote <name>] [--pointer <branch>] [--base <branch>]" >&2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ $# -ge 1 ] || { usage; exit 2; }
sha=$1
shift
remote=origin
pointer=green
base=main
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) [ $# -ge 2 ] || { usage; exit 2; }; remote=$2; shift 2 ;;
    --pointer) [ $# -ge 2 ] || { usage; exit 2; }; pointer=$2; shift 2 ;;
    --base) [ $# -ge 2 ] || { usage; exit 2; }; base=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

case "$sha" in
  *[!0-9a-f]*|'') echo "error: fm-green-pointer: '$sha' is not a full lowercase commit sha" >&2; exit 2 ;;
esac
[ "${#sha}" -eq 40 ] || [ "${#sha}" -eq 64 ] || {
  echo "error: fm-green-pointer: '$sha' is not a full commit sha" >&2
  exit 2
}
git check-ref-format --branch "$pointer" >/dev/null 2>&1 || { echo "error: fm-green-pointer: invalid pointer branch '$pointer'" >&2; exit 2; }
git check-ref-format --branch "$base" >/dev/null 2>&1 || { echo "error: fm-green-pointer: invalid base branch '$base'" >&2; exit 2; }
[ "$pointer" != "$base" ] || { echo "error: fm-green-pointer: the pointer cannot be the base branch itself" >&2; exit 2; }

base_ref="refs/remotes/$remote/$base"
pointer_ref="refs/remotes/$remote/$pointer"
attempt=0
while :; do
  attempt=$((attempt + 1))
  git fetch --quiet --no-tags --prune "$remote" "+refs/heads/*:refs/remotes/$remote/*"
  git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || {
    echo "error: fm-green-pointer: $remote/$base does not exist" >&2
    exit 1
  }
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null \
    || ! git merge-base --is-ancestor "$sha" "$base_ref"; then
    echo "green-pointer: skipped: $sha is not on $remote/$base"
    exit 0
  fi
  if old=$(git rev-parse --verify --quiet "$pointer_ref^{commit}"); then
    if [ "$old" = "$sha" ]; then
      echo "green-pointer: already at $sha"
      exit 0
    fi
    if git merge-base --is-ancestor "$sha" "$old"; then
      echo "green-pointer: skipped: $pointer is already at newer green commit $old"
      exit 0
    fi
    if ! git merge-base --is-ancestor "$old" "$sha"; then
      echo "error: fm-green-pointer: $remote/$pointer ($old) is not an ancestor of $sha; refusing to move it onto another line of history" >&2
      exit 1
    fi
    action="advanced $old..$sha"
  else
    action="created at $sha"
  fi
  # A plain push: the remote accepts it only as a fast-forward (or a creation).
  if git push --quiet "$remote" "$sha:refs/heads/$pointer"; then
    echo "green-pointer: $action"
    exit 0
  fi
  if [ "$attempt" -ge 3 ]; then
    echo "error: fm-green-pointer: push of $pointer to $sha was refused $attempt times" >&2
    exit 1
  fi
  echo "green-pointer: push refused; re-reading $remote/$pointer and retrying" >&2
done
