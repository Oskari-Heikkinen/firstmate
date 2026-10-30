#!/usr/bin/env bash
# Tests for bin/fm-helper-equiv.sh: the call-equivalence report for two
# versions of a pinned helper (docs/helper-consumers.md "Consumer call sets").
#
# The guarantees under test:
#   - A missing call-set file refuses, naming it; a malformed one refuses,
#     naming its file and line; so do an unknown version and an --out that is
#     not empty.
#   - Identical versions give zero rows.
#   - A changed rc, stdout, stderr or state is a row per call and state, and the
#     exit code stays 0; a timed-out call and an old result that changes
#     between its two runs are unknown rows, never equal.
#   - On this repository's history, bin/fm-disk-room.sh 5dc9f146 -> b536047d
#     reproduces the policy-state differences of its acceptance review from the
#     fixture call set, and 7b3daf1c -> 5dc9f146 gives zero rows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EQ="$ROOT/bin/fm-helper-equiv.sh"
FX="$ROOT/tests/fixtures/helper-equiv"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-helper-equiv-tests)

# A repo whose bin/tool.sh is version A at commit a and version B at commit b.
# Each version answers `rc`, `out`, `err`, `touch` and `slow`; `rand` prints a
# fresh random number, so its result is never stable.
REPO="$TMP_ROOT/repo"
fm_git_init_commit "$REPO"
mkdir -p "$REPO/bin"
write_tool() {  # <rc> <out> <err> <file>
  cat > "$REPO/bin/tool.sh" <<EOF
#!/bin/sh
case "\$1" in
  rc) exit $1 ;;
  out) echo "$2" ;;
  err) echo "$3" >&2 ;;
  touch) echo x > "\$HOME/$4" ;;
  slow) sleep 30 ;;
  rand) od -An -N8 -tu8 /dev/urandom ;;
  env) echo "\$MODE \$EXTRA" ;;
esac
EOF
  chmod +x "$REPO/bin/tool.sh"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "tool $1"
  git -C "$REPO" rev-parse HEAD
}
CA=$(write_tool 0 same same a)
CB=$(write_tool 3 changed changed b)

CALLS="$TMP_ROOT/tool.calls"
cat > "$CALLS" <<'EOF'
schema=fm-helper-calls/v1
consumer=tool
helper=bin/tool.sh
env=MODE=base
state=one
state=two MODE=other
timeout=2
call=rc
call=out
call=err
call=EXTRA=x\sy env
call=touch
EOF

equiv() {  # <out-dir> <args>...: run a report; sets OUT and RC
  local dir=$1
  shift
  RC=0
  OUT=$(cd "$REPO" && "$EQ" report --out "$dir" "$@" 2>&1) || RC=$?
}

test_refusals() {
  equiv "$TMP_ROOT/r1" --calls "$TMP_ROOT/missing.calls" --old "$CA" --new "$CB"
  expect_code 2 "$RC" "missing call set"
  assert_contains "$OUT" "equiv: refused: call set not found: $TMP_ROOT/missing.calls" "a missing call set is named"
  [ ! -e "$TMP_ROOT/r1" ] || fail "a refusal wrote the output directory"

  printf 'schema=fm-helper-calls/v1\nconsumer=bad\nhelper=bin/tool.sh\ncall=rc\nwhat=1\n' > "$TMP_ROOT/bad.calls"
  equiv "$TMP_ROOT/r2" --calls "$TMP_ROOT/bad.calls" --old "$CA" --new "$CB"
  expect_code 2 "$RC" "malformed call set"
  assert_contains "$OUT" "$TMP_ROOT/bad.calls:5: unknown key what" "a malformed line is named by file and line"

  printf 'schema=fm-helper-calls/v1\nconsumer=other\nhelper=bin/tool.sh\ncall=rc\n' > "$TMP_ROOT/named.calls"
  equiv "$TMP_ROOT/r3" --calls "$TMP_ROOT/named.calls" --old "$CA" --new "$CB"
  expect_code 2 "$RC" "consumer that is not the file stem"
  assert_contains "$OUT" "does not match the file name named.calls" "consumer= must match the file name"

  equiv "$TMP_ROOT/r4" --calls "$CALLS" --old sha256:00000000 --new "$CB"
  expect_code 2 "$RC" "unknown sha256"
  assert_contains "$OUT" "no bin/tool.sh with sha256 00000000" "an unknown version is named"

  mkdir -p "$TMP_ROOT/r5" && : > "$TMP_ROOT/r5/x"
  equiv "$TMP_ROOT/r5" --calls "$CALLS" --old "$CA" --new "$CB"
  expect_code 2 "$RC" "non-empty out"
  assert_contains "$OUT" "output directory exists and is not empty" "a non-empty --out refuses"
  pass "missing, malformed and unresolvable inputs refuse, naming them"
}

test_identical_versions_give_zero_rows() {
  local sha
  sha=$(git -C "$REPO" show "$CB:bin/tool.sh" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
  equiv "$TMP_ROOT/same" --calls "$CALLS" --old "sha256:${sha:0:12}" --new "$CB"
  expect_code 0 "$RC" "identical versions"
  assert_contains "$OUT" "0 differences, 0 unknown" "identical versions: outcome line"
  assert_grep "No differences and no unknowns" "$TMP_ROOT/same/report.md" "identical versions: report says so"
  assert_no_grep "| one |" "$TMP_ROOT/same/report.md" "identical versions: no rows"
  assert_grep "Old: sha256 $sha, from commit $CB" "$TMP_ROOT/same/report.md" "a sha256 prefix resolves to its commit"
  pass "identical versions give zero rows"
}

test_differences_are_rows() {
  local r="$TMP_ROOT/diff/report.md"
  equiv "$TMP_ROOT/diff" --calls "$CALLS" --old "$CA" --new "$CB"
  expect_code 0 "$RC" "a report with differences still exits 0"
  assert_contains "$OUT" "8 differences, 0 unknown" "outcome line counts rows"
  assert_grep "| one | 1 | rc | rc | differs | 0 | 3 |" "$r" "rc difference"
  assert_grep "| two | 2 | out | stdout | differs | line 1: same | line 1: changed |" "$r" "stdout difference, per state"
  assert_grep "| one | 3 | err | stderr | differs | line 1: same | line 1: changed |" "$r" "stderr difference"
  assert_grep "| one | 5 | touch | state | differs | 1 only here, e.g. sandbox/home/a file " "$r" "state difference"
  assert_no_grep "| 4 |" "$r" "an equal call has no row"
  [ "$(cat "$TMP_ROOT/diff/captures/two/004-new.out")" = "other x y" ] || fail "state and call environment reach the helper"
  pass "differences are one row per call, state and aspect"
}

test_unknown_is_never_equal() {
  local r="$TMP_ROOT/unknown/report.md"
  {
    printf 'schema=fm-helper-calls/v1\nconsumer=unk\nhelper=bin/tool.sh\ntimeout=1\n'
    printf 'call=slow\ncall=rand\ncall=out\n'
  } > "$TMP_ROOT/unk.calls"
  equiv "$TMP_ROOT/unknown" --calls "$TMP_ROOT/unk.calls" --old "$CA" --new "$CA"
  expect_code 0 "$RC" "a report with unknowns still exits 0"
  assert_grep "| default | 1 | slow | rc | unknown: timed out after 1s |" "$r" "a timed-out call is unknown"
  assert_grep "| default | 2 | rand | stdout | unknown: unstable, the old version differed between two runs |" "$r" "an unstable result is unknown"
  assert_no_grep "| default | 3 |" "$r" "a stable equal call has no row"
  assert_no_grep "No differences and no unknowns" "$r" "unknowns are not reported as equal"
  pass "a timed-out or unstable call is unknown, never equal"
}

# bin/fm-disk-room.sh's own history, read with git; the helper is never run
# from the checkout or against a real home.
test_disk_room_history() {
  local r
  if ! git -C "$ROOT" cat-file -e 'aab24c50^{commit}' 2>/dev/null || ! git -C "$ROOT" cat-file -e '8cb9c467^{commit}' 2>/dev/null; then
    printf 'skip: disk-room history: commits 8cb9c467 and aab24c50 are not in this clone (fetch full history to run)\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'skip: disk-room history: jq is not installed\n'
    return 0
  fi
  RC=0
  OUT=$(cd "$ROOT" && "$EQ" report --calls "$FX/disk-room.calls" --old sha256:5dc9f146 --new sha256:b536047d \
    --out "$TMP_ROOT/accept4" 2>&1) || RC=$?
  expect_code 0 "$RC" "accept4 pair"
  assert_contains "$OUT" "0 unknown" "accept4 pair has no unknowns"
  r="$TMP_ROOT/accept4/report.md"
  assert_no_grep "| absent | 7 |" "$r" "absent policy: status --json unchanged"
  assert_no_grep "| absent | 9 |" "$r" "absent policy: check unchanged"
  assert_grep "| absent | 4 | --interface v3 | rc | differs | 1 | 0 |" "$r" "v3 is served"
  assert_grep '"admission":"off","c\_terms\_mode":"off","host\_c\_reserved":0,"pagefile\_reserved":0,"c\_terms":null}' "$r" "legacy policy: status --json gains keys (F1)"
  assert_grep "| strict | 9 | check --expect-write 100G | rc | differs | 1 | 0 |" "$r" "strict policy admits more (F2)"
  assert_grep "| strict | 19 | FM\_DISK\_ROOM\_HOST= status --json | stderr | differs | (no output) | line 1: fm-disk-room: host-c:mount: host drive is not mounted |" "$r" "strict policy refuses SSD-only calls (F3)"
  assert_grep "| strict | 2 | --interface v1 | rc | differs | 0 | 1 |" "$r" "strict policy stops serving v1 (F9)"
  assert_grep "| strict | 5 | --self-test v1 | rc | differs | 0 | 1 |" "$r" "strict policy fails the v1 self-test (F9)"
  assert_no_grep "| absent | 5 | --self-test v1 | rc |" "$r" "absent policy: the v1 self-test still passes"
  assert_grep "| unreadable | 8 | check --expect-write 95G | rc | differs | 0 | 2 |" "$r" "an unreadable policy fails every measure (F4)"

  RC=0
  OUT=$(cd "$ROOT" && "$EQ" report --calls "$FX/disk-room.calls" --old sha256:7b3daf1c --new sha256:5dc9f146 \
    --out "$TMP_ROOT/accept3" 2>&1) || RC=$?
  expect_code 0 "$RC" "accept3 pair"
  assert_contains "$OUT" "0 differences, 0 unknown" "7b3daf1c -> 5dc9f146 answers every call identically"
  pass "disk-room history reproduces its acceptance reviews"
}

test_refusals
test_identical_versions_give_zero_rows
test_differences_are_rows
test_unknown_is_never_equal
test_disk_room_history

echo "# all fm-helper-equiv tests passed"
