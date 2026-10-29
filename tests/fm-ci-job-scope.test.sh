#!/usr/bin/env bash
# fm-ci-job-scope.sh: the source closure follows literal `.` and `source` names
# transitively (after `&&`, in tests/ and bin/backends/, from a subdirectory),
# skips dynamic sources and comments; a ci/** diff outside the scope skips,
# a change to a root or a transitive library runs, a non-ci ref always runs; a
# missing root, a missing sourced file or an unreadable base is unknown, never
# skip; no root is a usage error.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-job-scope)
SCOPE="$ROOT/bin/fm-ci-job-scope.sh"
REPO="$TMP_ROOT/repo"
ROOTS="bin/fm-root.sh tests/fm-root.test.sh"

fm_git_init_commit "$REPO"
mkdir -p "$REPO/bin/backends" "$REPO/tests"
cat > "$REPO/bin/fm-root.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/fm-a-lib.sh
. "$SCRIPT_DIR/fm-a-lib.sh"
# . "$SCRIPT_DIR/fm-comment-lib.sh"
load() { . "$1"; }
SH
cat > "$REPO/bin/fm-a-lib.sh" <<'SH'
[ -f "$SCRIPT_DIR/fm-b-lib.sh" ] && . "$SCRIPT_DIR/fm-b-lib.sh"
SH
cat > "$REPO/bin/fm-b-lib.sh" <<'SH'
source "$SCRIPT_DIR/backends/fm-adapter.sh"
SH
printf 'adapter=1\n' > "$REPO/bin/backends/fm-adapter.sh"
printf 'comment=1\n' > "$REPO/bin/fm-comment-lib.sh"
printf 'other=1\n' > "$REPO/bin/fm-other.sh"
cat > "$REPO/tests/fm-root.test.sh" <<'SH'
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SH
printf 'lib=1\n' > "$REPO/tests/lib.sh"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qm fixture

scope() {
  # shellcheck disable=SC2086 # ROOTS is a fixed space-separated root list.
  (cd "$REPO" && bash "$SCOPE" "$@" $ROOTS)
}

# change <branch> <path>: a branch off main that appends a line to <path>.
change() {
  git -C "$REPO" checkout -q -b "$1" main
  printf 'changed=1\n' >> "$REPO/$2"
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qam "change $2"
}

expected='bin/backends/fm-adapter.sh
bin/fm-a-lib.sh
bin/fm-b-lib.sh
bin/fm-root.sh
tests/fm-root.test.sh
tests/lib.sh'
assert_equals "$expected" "$(scope --list)" 'scope list'
pass 'the scope follows literal sources transitively and skips dynamic ones and comments'

out=$(cd "$REPO/bin" && bash "$SCOPE" --list fm-root.sh 2>&1) && rc=0 || rc=$?
assert_equals 1 "$rc" 'relative root from a subdirectory'
assert_contains "$out" 'unknown: root fm-root.sh is not a file' 'relative root from a subdirectory'
assert_equals 4 "$(cd "$REPO/bin" && bash "$SCOPE" --list bin/fm-root.sh | grep -c .)" 'subdirectory list'
pass 'roots resolve from the work tree top, not the current directory'

change unrelated bin/fm-other.sh
assert_equals 'skip: none of the 1 changed paths is in the 6-file scope' "$(scope --base main)" 'unrelated change'
change commented bin/fm-comment-lib.sh
assert_equals 'skip: none of the 1 changed paths is in the 6-file scope' "$(scope --base main)" 'comment-only name'
pass 'a change outside the scope skips, and a commented-out source is not in it'

change transitive bin/backends/fm-adapter.sh
assert_equals 'run: bin/backends/fm-adapter.sh changed and is in the 6-file scope' "$(scope --base main --ref refs/heads/ci/x)" 'transitive change'
change testlib tests/lib.sh
assert_equals 'run: tests/lib.sh changed and is in the 6-file scope' "$(scope --base main --ref refs/heads/ci/full/x)" 'test library change'
git -C "$REPO" checkout -q unrelated
assert_equals 'run: bin/backends/fm-adapter.sh changed and is in the 6-file scope' "$(scope --base main --head transitive)" '--head ref'
pass 'a change to a transitively sourced library runs on any ci/** branch'

assert_equals 'run: refs/heads/main is not a ci/** branch' "$(scope --base main --ref refs/heads/main)" 'main ref'
pass 'a push outside ci/** always runs, whatever changed'

assert_equals "unknown: cannot diff missing-ref...HEAD in $REPO" "$(scope --base missing-ref)" 'missing base'
out=$(scope --base main bin/fm-gone.sh) && rc=0 || rc=$?
assert_equals "0:unknown: root bin/fm-gone.sh is not a file in $REPO" "$rc:$out" 'missing root'
git -C "$REPO" checkout -q -b deleted main
git -C "$REPO" rm -q bin/fm-b-lib.sh
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qm 'drop b'
assert_equals 'unknown: bin/fm-a-lib.sh sources fm-b-lib.sh, which is not a file in any of: bin bin/backends tests' "$(scope --base main)" 'missing sourced file'
out=$(scope --list) && rc=0 || rc=$?
assert_equals 1 "$rc" 'missing sourced file under --list'
pass 'a missing root, sourced file or base is unknown, never skip'

out=$(cd "$REPO" && bash "$SCOPE" --base main 2>&1) && rc=0 || rc=$?
assert_equals 2 "$rc" 'no root'
assert_contains "$out" 'name at least one root path' 'no root'
out=$(cd "$REPO" && bash "$SCOPE" --bogus bin/fm-root.sh 2>&1) && rc=0 || rc=$?
assert_equals 2 "$rc" 'unknown option'
pass 'usage errors exit 2'
