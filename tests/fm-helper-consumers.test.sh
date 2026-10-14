#!/usr/bin/env bash
# Tests for bin/fm-helper-consumers.sh: declared consumers of Firstmate helpers
# that another home runs under a pin (docs/helper-consumers.md).
#
# The guarantees under test:
#   - Declarations parse strictly; a malformed one is reported by name, accepts
#     nothing, and holds every change to a declared helper until --allow-break
#     names it; no declarations at all is silent.
#   - check-advance holds a helper change that a consumer accepting the current
#     version has not accepted, advances an accepted one, lets --allow-break
#     through with a record, advances past a consumer that already waits, and
#     ignores a helper whose bytes do not change or that lives in another checkout.
#   - pending writes one record and one read-only review artefact per version,
#     files one note to the root home, stays quiet for another repository, and
#     with a range considers only helpers that changed in it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HC="$ROOT/bin/fm-helper-consumers.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-helper-consumers-tests)

sha_of() { printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}'; }
V1=$(sha_of $'echo v1\n')
V2=$(sha_of $'echo v2\n')

# new_world <name>: a repo with bin/helper.sh at "echo v1" (commit C1) and a
# second commit C2 that changes it to "echo v2"; the checkout stays at C1. Also
# a home with state/. Echoes the world dir; C1 and C2 are in <w>/c1 and <w>/c2.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/decl"
  fm_git_init_commit "$w/repo"
  mkdir -p "$w/repo/bin"
  printf 'echo v1\n' > "$w/repo/bin/helper.sh"
  printf 'echo other\n' > "$w/repo/bin/other.sh"
  git -C "$w/repo" add -A
  git -C "$w/repo" commit -qm c1
  git -C "$w/repo" rev-parse HEAD > "$w/c1"
  printf 'echo v2\n' > "$w/repo/bin/helper.sh"
  git -C "$w/repo" commit -qam c2
  git -C "$w/repo" rev-parse HEAD > "$w/c2"
  git -C "$w/repo" reset -q --hard "$(cat "$w/c1")"
  printf '%s\n' "$w"
}

# declare <w> <id> <helper> [<sha>...]
declare_consumer() {
  local w=$1 id=$2 helper=$3 sha
  shift 3
  {
    printf '%s\n' 'schema=fm-helper-consumer/v1' "consumer=$id" 'owner=other-mate' "helper=$helper"
    for sha in "$@"; do printf 'accept=%s\n' "$sha"; done
  } > "$w/decl/$id.conf"
}

hc() {  # <w> <args>...
  local w=$1
  shift
  FM_HELPER_CONSUMERS="$w/decl" FM_HELPER_VERSIONS="$w/versions" FM_HOME="$w/home" "$HC" "$@"
}

test_no_declarations_is_silent() {
  local w out rc=0
  w=$(new_world none)
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")" 2>&1) || rc=$?
  expect_code 0 "$rc" "check-advance with no declarations"
  assert_equals "" "$out" "check-advance with no declarations prints nothing"
  out=$(hc "$w" pending --repo "$w/repo" "$(cat "$w/c2")" 2>&1) || rc=$?
  expect_code 0 "$rc" "pending with no declarations"
  assert_equals "" "$out" "pending with no declarations prints nothing"
  [ ! -e "$w/versions" ] || fail "pending wrote a record with no declarations"
  pass "no declarations: check-advance and pending are silent no-ops"
}

test_malformed_declarations_hold_declared_helpers() {
  local w out rc=0
  w=$(new_world malformed)
  declare_consumer "$w" good "$w/repo/bin/helper.sh" "$V1"
  printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=typo' 'owner=x' "helper=$w/repo/bin/helper.sh" 'acept=abc' > "$w/decl/typo.conf"
  printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=someone-else' 'owner=x' "helper=$w/repo/bin/helper.sh" > "$w/decl/renamed.conf"
  printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=relative' 'owner=x' 'helper=bin/helper.sh' > "$w/decl/relative.conf"
  printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=badsha' 'owner=x' "helper=$w/repo/bin/helper.sh" 'accept=XYZ' > "$w/decl/badsha.conf"

  out=$(hc "$w" list 2>&1) || rc=$?
  expect_code 1 "$rc" "list with a malformed declaration"
  assert_contains "$out" "malformed: $w/decl/typo.conf: unknown key 'acept'" "an unknown key is named"
  assert_contains "$out" "malformed: $w/decl/renamed.conf: consumer= 'someone-else' does not match the file name" "a mismatched consumer id is named"
  assert_contains "$out" "malformed: $w/decl/relative.conf: helper= must be an absolute path" "a relative helper is named"
  assert_contains "$out" "malformed: $w/decl/badsha.conf: accept= must be a lowercase sha256" "a bad sha is named"
  assert_contains "$out" "consumer good owner other-mate" "a valid declaration is still listed"
  assert_contains "$out" "$w/repo/bin/helper.sh live ${V1:0:12} accepts" "the live version's state is shown"

  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 3 "$rc" "a change to a declared helper holds"
  assert_contains "$out" "malformed"$'\t'"$w/decl/typo.conf" "check-advance reports malformed declarations"
  assert_contains "$out" "hold"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"good" "the valid consumer holds"
  assert_contains "$out" "unproven"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"badsha,relative,renamed,typo" \
    "the hold names every malformed declaration"

  declare_consumer "$w" good "$w/repo/bin/helper.sh" "$V1" "$V2"
  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 3 "$rc" "a malformed declaration holds even when every valid consumer accepts"
  assert_not_contains "$out" "hold"$'\t' "an accepting valid consumer is not reported"

  rc=0
  out=$(hc "$w" check-advance --allow-break typo --allow-break renamed --allow-break relative \
    "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 3 "$rc" "one malformed declaration left unnamed still holds"
  assert_contains "$out" "unproven"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"badsha" \
    "a malformed declaration named by --allow-break no longer holds"
  rc=0
  out=$(hc "$w" check-advance --allow-break typo --allow-break renamed --allow-break relative --allow-break badsha \
    "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 0 "$rc" "naming every malformed declaration releases the hold"
  assert_not_contains "$out" "unproven" "a released malformed declaration is still reported as unproven"

  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c1")") || rc=$?
  expect_code 0 "$rc" "an advance that changes no declared helper is not held by a malformed declaration"

  # Alone, a malformed declaration still holds the helper its own lines name.
  rm -f "$w/decl/good.conf" "$w/decl/renamed.conf" "$w/decl/relative.conf" "$w/decl/badsha.conf"
  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 3 "$rc" "a lone malformed declaration holds its own helper"
  assert_contains "$out" "unproven"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"typo" "the lone hold names its file"
  pass "malformed declarations are reported by name, accept nothing, and hold declared helpers"
}

test_check_advance_outcomes() {
  local w out rc
  w=$(new_world outcomes)
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"
  declare_consumer "$w" waiter "$w/repo/bin/helper.sh" "$(sha_of 'older')"

  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 3 "$rc" "a consumer accepting only the current version holds"
  assert_contains "$out" "hold"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"holder" "the hold names the consumer and target"
  assert_contains "$out" "waiting"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"waiter" "a consumer that already waits is reported"

  rc=0
  out=$(hc "$w" check-advance --allow-break holder "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 0 "$rc" "--allow-break releases the hold"
  assert_contains "$out" "break"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"holder" "the override is recorded"

  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1" "$V2"
  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 0 "$rc" "an accepted target advances"
  assert_not_contains "$out" "holder" "an accepting consumer is not reported"

  declare_consumer "$w" holder "$w/repo/bin/other.sh" "$(sha_of $'echo other\n')"
  rm -f "$w/decl/waiter.conf"
  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 0 "$rc" "a helper whose bytes do not change never holds"
  assert_equals "" "$out" "an unchanged helper is not reported"

  declare_consumer "$w" holder "$TMP_ROOT/elsewhere/bin/helper.sh" "$V1"
  mkdir -p "$TMP_ROOT/elsewhere/bin"
  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")") || rc=$?
  expect_code 0 "$rc" "a helper outside the checkout never holds it"

  rc=0
  hc "$w" check-advance "$w/repo" no-such-rev >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown target revision is an error, which ff_target treats as a hold"
  pass "check-advance holds, advances, overrides, and reports exactly as declared"
}

test_pending_records_once_and_files_one_note() {
  local w out record notes
  w=$(new_world pending)
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"

  out=$(hc "$w" pending --repo "$w/repo" "$(cat "$w/c2")")
  record="$w/versions/helper.sh/$V2"
  assert_contains "$out" "helper-pending: bin/helper.sh version ${V2:0:12} recorded at $record, awaiting holder" "the record is reported"
  assert_contains "$out" "helper-pending: note filed to " "the note is reported"
  [ -f "$record/pending.json" ] || fail "no pending.json"
  [ -f "$record/note-filed" ] || fail "no note-filed marker"
  assert_equals "$V2" "$({ sha256sum 2>/dev/null || shasum -a 256; } < "$record/helper.sh" | awk '{print $1}')" \
    "the artefact holds the exact pending bytes"
  [ ! -w "$record/helper.sh" ] || fail "the review artefact is writable"
  assert_grep '"schema": "fm-helper-version/v1"' "$record/pending.json" "the record names its schema"
  assert_grep "\"sha256\": \"$V2\"" "$record/pending.json" "the record names the version"
  assert_grep "\"commit\": \"$(cat "$w/c2")\"" "$record/pending.json" "the record names the commit"
  assert_grep "\"accepts\": [\"$V1\"]" "$record/pending.json" "the record carries what the consumer accepts now"
  assert_grep "since $(cat "$w/c1")" "$record/pending.json" "the record diffs against the accepted version's commit"
  notes=$(find "$w/home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals 1 "$notes" "one note is filed to the root home"
  grep -q "Firstmate helper bin/helper.sh has a new version ${V2:0:12}" "$w/home/state/inbox"/*.note \
    || fail "the note does not name the helper version"

  out=$(hc "$w" pending --repo "$w/repo" "$(cat "$w/c2")")
  assert_equals "" "$out" "a second run for the same version is silent"
  notes=$(find "$w/home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals 1 "$notes" "a second run files no second note"
  pass "pending writes one record, one read-only artefact, and one note per version"
}

test_pending_range_and_repository_filters() {
  local w out
  w=$(new_world pending-filters)
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$(sha_of 'older')"

  out=$(hc "$w" pending --repo "$w/repo" "$(cat "$w/c2")..$(cat "$w/c2")")
  assert_equals "" "$out" "a range that does not change the helper records nothing"
  [ ! -e "$w/versions" ] || fail "a no-change range wrote a record"

  git -C "$w/repo" remote add origin https://github.com/example/firstmate.git
  out=$(hc "$w" pending --repo "$w/repo" --if-repo github.com/example/other "$(cat "$w/c2")")
  assert_equals "" "$out" "another repository's merge records nothing"
  [ ! -e "$w/versions" ] || fail "another repository's merge wrote a record"

  out=$(hc "$w" pending --repo "$w/repo" --if-repo github.com/Example/firstmate "$(cat "$w/c1")..$(cat "$w/c2")")
  assert_contains "$out" "helper-pending: bin/helper.sh version ${V2:0:12} recorded" "this repository's change is recorded"
  pass "pending honors its range and repository filters"
}

test_no_declarations_is_silent
test_malformed_declarations_hold_declared_helpers
test_check_advance_outcomes
test_pending_records_once_and_files_one_note
test_pending_range_and_repository_filters

echo "# all fm-helper-consumers tests passed"
