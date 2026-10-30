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
#   - log appends one validated line per call, and holds reads every hold window
#     of the 2026-10 hold timeline back from the log, open holds included.
#   - alarm raises one level per version left unaccepted on the branch past the
#     limit, keeps it one level across passes, clears it on acceptance and on
#     supersession, routes it to main and to a reachable owner, raises a level
#     naming each unreadable record, declaration or limit file, and with no
#     declarations prints and writes nothing; --arm binds its check and runs a
#     first pass, and --disarm removes its stores and its check.
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
  env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE \
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

# --- hold log ------------------------------------------------------------------

iso_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
row() { local IFS=$'\t'; printf '%s' "$*"; }

# log_at <w> <iso time> <outcome> <helper> <sha> [<consumers>]
log_at() {
  FM_HELPER_CONSUMERS_NOW=$(iso_epoch "$2") hc "$1" log "$3" "$1/home" "$C_TARGET" "$4" "$5" "${6:-tetjet-filler,tetjet-services}" "fixture pass"
}

test_log_validates_and_appends_one_line() {
  local w out rc=0 home
  w=$(new_world holdlog)
  C_TARGET=$(cat "$w/c2")
  home=$(cd "$w/home" && pwd -P)
  log_at "$w" 2026-10-22T10:11:00Z held "$w/repo/bin/helper.sh" "$V2"
  log_at "$w" 2026-10-22T10:11:00Z held - - -
  assert_equals 2 "$(wc -l < "$w/versions/holds.log" | tr -d ' ')" "each call appends one line"
  assert_equals "$(row "2026-10-22T10:11:00Z" "held" "$home" "$C_TARGET" "$w/repo/bin/helper.sh" "$V2" "tetjet-filler,tetjet-services" "fixture pass")" \
    "$(head -n 1 "$w/versions/holds.log")" "the line carries every field in order"
  FM_HELPER_CONSUMERS_NOW=1 hc "$w" log break "$w/home" - - - - $'two\tfields\nand lines' >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a note with tabs and newlines is written"
  assert_equals "two fields and lines" "$(tail -n 1 "$w/versions/holds.log" | cut -f 8)" "tabs and newlines in the note become spaces"
  for bad in "unheld $w/home - - - -" "held relative - - - -" "held $w/home abc - - -" "held $w/home - x ABC -" "held $w/home - x - a;b"; do
    rc=0
    # shellcheck disable=SC2086 # Each case is a word list on purpose.
    hc "$w" log $bad >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "log refuses: $bad"
  done
  assert_equals 3 "$(wc -l < "$w/versions/holds.log" | tr -d ' ')" "a refused call writes nothing"
  pass "log validates its fields and appends exactly one line per call"
}

# The 2026-10 hold timeline (UTC): W1 10-22 10:11-19:56, W2 10-25 09:55 to
# 10-29 19:14 with two versions joining, a 3.7 h gap, then W3 from 10-29 22:58,
# still open at 10-30 09:04 with a second version joined and one break record.
test_holds_reads_back_every_window() {
  local w out err rc=0 home d1 d2 d3 s1 d4 d5 disk store
  w=$(new_world windows)
  C_TARGET=$(cat "$w/c2")
  home=$(cd "$w/home" && pwd -P)
  disk="$w/repo/bin/fm-disk-room.sh" store="$w/repo/bin/fm-storage.sh"
  d1=$(sha_of d1) d2=$(sha_of d2) d3=$(sha_of d3) s1=$(sha_of s1) d4=$(sha_of d4) d5=$(sha_of d5)
  log_at "$w" 2026-10-22T10:11:00Z held "$disk" "$d1"
  log_at "$w" 2026-10-22T14:00:00Z held "$disk" "$d1"
  log_at "$w" 2026-10-22T19:56:00Z cleared "$disk" "$d1"
  log_at "$w" 2026-10-25T09:55:00Z held "$disk" "$d2"
  log_at "$w" 2026-10-26T08:00:00Z held "$disk" "$d2"
  log_at "$w" 2026-10-26T08:00:00Z held "$disk" "$d3"
  log_at "$w" 2026-10-27T08:00:00Z held "$disk" "$d3"
  log_at "$w" 2026-10-27T08:00:00Z held "$store" "$s1"
  log_at "$w" 2026-10-29T19:14:00Z cleared "$disk" "$d2"
  log_at "$w" 2026-10-29T19:14:00Z cleared "$disk" "$d3"
  log_at "$w" 2026-10-29T19:14:00Z cleared "$store" "$s1"
  log_at "$w" 2026-10-29T22:58:00Z held "$disk" "$d4"
  log_at "$w" 2026-10-30T03:38:00Z held "$disk" "$d4"
  log_at "$w" 2026-10-30T03:38:00Z held "$disk" "$d5"
  log_at "$w" 2026-10-30T04:00:00Z break "$disk" "$d5" tetjet-filler
  FM_HELPER_CONSUMERS_NOW=1 hc "$w" log held "$TMP_ROOT/other-home" - - - - other
  printf 'not a hold record\n' >> "$w/versions/holds.log"

  out=$(FM_HELPER_CONSUMERS_NOW=$(iso_epoch 2026-10-30T09:04:00Z) hc "$w" holds --home "$w/home" --windows 2>"$w/err") || rc=$?
  err=$(cat "$w/err")
  expect_code 0 "$rc" "holds --windows"
  assert_equals 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line per window of this home"
  assert_equals "$(row "$home" "2026-10-22T10:11:00Z" "2026-10-22T19:56:00Z" "9.8" "2" "fm-disk-room.sh@${d1:0:12}" "0" "fixture pass")" \
    "$(printf '%s\n' "$out" | sed -n 1p)" "W1 reads back"
  assert_equals "$(row "$home" "2026-10-25T09:55:00Z" "2026-10-29T19:14:00Z" "105.3" "3" "fm-disk-room.sh@${d2:0:12},fm-disk-room.sh@${d3:0:12},fm-storage.sh@${s1:0:12}" "0" "fixture pass")" \
    "$(printf '%s\n' "$out" | sed -n 2p)" "W2 reads back with the versions that joined it"
  assert_equals "$(row "$home" "2026-10-29T22:58:00Z" "open" "10.1" "2" "fm-disk-room.sh@${d4:0:12},fm-disk-room.sh@${d5:0:12}" "1" "-")" \
    "$(printf '%s\n' "$out" | sed -n 3p)" "W3 reads back as open, with its break record"
  assert_equals 13440 "$(( $(iso_epoch 2026-10-29T22:58:00Z) - $(iso_epoch "$(printf '%s\n' "$out" | sed -n 2p | cut -f 3)") ))" \
    "the 3.7 h gap between W2 and W3 reads back"
  assert_contains "$err" "$w/versions/holds.log line 17 is not a hold record; skipped" "an unknown line is named"

  out=$(hc "$w" holds --home "$w/home" --open 2>/dev/null)
  assert_equals "$(row "$home" "$disk" "$d4" tetjet-filler,tetjet-services 2026-10-29T22:58:00Z)
$(row "$home" "$disk" "$d5" tetjet-filler,tetjet-services 2026-10-30T03:38:00Z)" "$out" "--open lists the holds not yet cleared"
  out=$(hc "$w" holds --home "$TMP_ROOT/other-home" --windows 2>/dev/null)
  assert_contains "$out" "$(row "$TMP_ROOT/other-home" 1970-01-01T00:00:01Z open "")" "another home's hold is its own window"
  rm -f "$w/versions/holds.log"
  out=$(hc "$w" holds --windows 2>&1)
  assert_equals "" "$out" "a missing log reads as no holds"
  pass "holds reads every hold window, gap and open hold back from the log"
}

# --- unaccepted-version alarm -------------------------------------------------

# alarm_world <name>: a repo whose origin main carries bin/helper.sh v1, committed
# at T0, with a home that has state/ and config/; the declaration accepts v1.
T0=$(iso_epoch 2026-10-25T00:00:00Z)
alarm_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data" "$w/decl"
  fm_git_init_commit "$w/repo"
  mkdir -p "$w/repo/bin"
  printf 'echo v1\n' > "$w/repo/bin/helper.sh"
  git -C "$w/repo" add -A
  GIT_COMMITTER_DATE="@$T0 +0000" GIT_AUTHOR_DATE="@$T0 +0000" git -C "$w/repo" commit -qm v1
  fm_git_add_origin "$w/repo" "$w/origin.git"
  git -C "$w/repo" fetch -q origin
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"
  printf '%s\n' "$w"
}

# land <w> <text> <epoch>: land bin/helper.sh as <text> on origin main at <epoch>
# and record the pending version, as a landing does.
land() {
  printf '%s\n' "$2" > "$1/repo/bin/helper.sh"
  GIT_COMMITTER_DATE="@$3 +0000" GIT_AUTHOR_DATE="@$3 +0000" git -C "$1/repo" commit -qam "land $2"
  git -C "$1/repo" push -q origin HEAD:main
  git -C "$1/repo" fetch -q origin
  hc "$1" pending --repo "$1/repo" origin/main >/dev/null
}

alarm_at() {  # <w> <epoch>
  FM_HELPER_CONSUMERS_NOW=$2 hc "$1" alarm --repo "$1/repo"
}

# store_query <w> <target> <jq filter>
store_query() {
  jq -r "$3" "$1/home/state/helper-unaccepted/stores/$2.json" 2>/dev/null
}

test_alarm_w2_raises_once_and_clears_on_acceptance() {
  local w out t land_at end_at key reg home
  w=$(alarm_world alarm-w2)
  home=$(cd "$w/home" && pwd -P)
  land_at=$(iso_epoch 2026-10-25T09:55:00Z) end_at=$(iso_epoch 2026-10-29T19:14:00Z)
  land "$w" 'echo v2' "$land_at"
  key="helper-unaccepted-helper.sh-${V2:0:12}"

  out=$(alarm_at "$w" $((land_at + 3600)))
  assert_equals "" "$out" "a pass within the limit prints nothing"
  assert_equals "" "$(store_query "$w" main '.active | keys[]')" "no level within the limit"

  out=$(alarm_at "$w" $((land_at + 7200)))
  assert_equals "" "$out" "a delivered level prints nothing"
  assert_equals "$key" "$(store_query "$w" main '.active | keys[]')" "the level is raised once the limit has passed"
  assert_contains "$(store_query "$w" main ".active[\"$key\"].reason")" \
    "bin/helper.sh version ${V2:0:12} on origin/main since 2026-10-25T09:55:00Z is not accepted by holder (owner other-mate)" \
    "the level names the version, the branch, its start and the consumer"
  assert_contains "$(store_query "$w" main ".active[\"$key\"].reason")" "for other-mate, whose home this machine does not see" \
    "an owner this machine cannot reach is named in main's level"
  reg="$w/home/state/alert-stores/helper-unaccepted.main.reg"
  assert_grep "path=$home/state/helper-unaccepted/stores/main.json" "$reg" "the store is registered in the root home"
  assert_grep "status=helper-unaccepted.status" "$reg" "the store is bound to its status file"
  [ -f "$w/home/state/helper-unaccepted.status" ] || fail "the bound status file is missing"

  t=$((land_at + 6 * 3600))
  while [ "$t" -lt "$end_at" ]; do
    out=$(alarm_at "$w" "$t")
    assert_equals "" "$out" "a pass at $t prints nothing"
    t=$((t + 6 * 3600))
  done
  assert_equals "$key" "$(store_query "$w" main '.active | keys[]')" "the level stays one level across passes"
  assert_equals 1 "$(store_query "$w" main '[.events[] | select(.action == "raised")] | length')" "the level was raised exactly once"

  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1" "$V2"
  out=$(alarm_at "$w" "$end_at")
  assert_equals "" "$out" "the clearing pass prints nothing"
  assert_equals "" "$(store_query "$w" main '.active | keys[]')" "acceptance clears the level"
  assert_equals 1 "$(store_query "$w" main '[.events[] | select(.action == "cleared")] | length')" "the level was cleared exactly once"
  assert_equals 1 "$(store_query "$w" main '[.events[] | select(.action == "raised")] | length')" "no second raise"
  pass "a W2-shaped 105 h wait raises one level once and clears it once on acceptance"
}

test_alarm_supersession_owner_route_and_limit_file() {
  local w out at key2 key3 owner
  w=$(alarm_world alarm-super)
  owner="$w/owner"
  mkdir -p "$owner/state"
  printf -- '- other-mate - helper owner (home: %s; scope: helpers; projects: none; added 2026-10-01)\n' "$owner" > "$w/home/data/secondmates.md"
  at=$(iso_epoch 2026-10-29T22:58:00Z)
  land "$w" 'echo v2' "$at"
  key2="helper-unaccepted-helper.sh-${V2:0:12}"
  alarm_at "$w" $((at + 7200)) >/dev/null
  assert_equals "$key2" "$(store_query "$w" main '.active | keys[]')" "main holds the level"
  assert_equals "$key2" "$(store_query "$w" other-mate '.active | keys[]')" "the reachable owner holds the level too"
  assert_not_contains "$(store_query "$w" main ".active[\"$key2\"].reason")" "whose home this machine does not see" \
    "a reachable owner is not named as unreached"
  assert_grep "status=helper-unaccepted.status" "$owner/state/alert-stores/helper-unaccepted.main.reg" "the owner's home binds the store"

  land "$w" 'echo v3' $((at + 4 * 3600))
  key3="helper-unaccepted-helper.sh-$(sha_of $'echo v3\n' | cut -c1-12)"
  alarm_at "$w" $((at + 4 * 3600 + 60)) >/dev/null
  assert_equals "" "$(store_query "$w" main '.active | keys[]')" "a superseded version's level clears"
  assert_equals "" "$(store_query "$w" other-mate '.active | keys[]')" "the owner's level clears with it"

  printf '30m\n' > "$w/home/config/helper-unaccepted-max"
  alarm_at "$w" $((at + 4 * 3600 + 1860)) >/dev/null
  assert_equals "$key3" "$(store_query "$w" main '.active | keys[]')" "the limit file is read on the next pass"
  pass "supersession clears a level, a reachable owner gets its own store, and the limit file is read every pass"
}

test_alarm_failed_readings_raise_naming_the_file() {
  local w out keys bad_record home
  w=$(alarm_world alarm-failed)
  home=$(cd "$w/home" && pwd -P)
  land "$w" 'echo v2' "$T0"
  printf 'soon\n' > "$w/home/config/helper-unaccepted-max"
  printf 'consumer=broken\n' > "$w/decl/broken.conf"
  bad_record="$w/versions/helper.sh/$(sha_of nothing)"
  mkdir -p "$bad_record"
  printf 'not json\n' > "$bad_record/pending.json"

  out=$(alarm_at "$w" $((T0 + 60)))
  assert_equals "" "$out" "delivered failure levels print nothing"
  keys=$(store_query "$w" main '.active | keys[]')
  assert_contains "$keys" "helper-unaccepted-max-unreadable" "an unparsable limit file raises"
  assert_contains "$(store_query "$w" main '.active["helper-unaccepted-max-unreadable"].reason')" "$home/config/helper-unaccepted-max" \
    "the limit level names the file"
  assert_contains "$keys" "helper-unaccepted-decl-broken" "a malformed declaration raises"
  assert_contains "$(store_query "$w" main '.active["helper-unaccepted-decl-broken"].reason')" "$w/decl/broken.conf" \
    "the declaration level names the file"
  assert_contains "$keys" "helper-unaccepted-record-helper.sh-$(sha_of nothing | cut -c1-12)" "an unreadable record raises"
  assert_contains "$(store_query "$w" main ".active[\"helper-unaccepted-record-helper.sh-$(sha_of nothing | cut -c1-12)\"].reason")" \
    "$bad_record/pending.json" "the record level names the file"
  assert_not_contains "$keys" "helper-unaccepted-helper.sh-" "a version still within the 2h fallback limit raises nothing"

  rm -f "$w/home/config/helper-unaccepted-max" "$w/decl/broken.conf"
  rm -rf "$bad_record"
  out=$(alarm_at "$w" $((T0 + 120)))
  assert_equals "" "$(store_query "$w" main '.active | keys[]')" "fixing each file clears its level"
  pass "an unreadable record, declaration or limit file raises a level naming it"
}

test_alarm_without_declarations_is_silent() {
  local w out
  w=$(alarm_world alarm-none)
  rm -f "$w/decl/holder.conf"
  out=$(alarm_at "$w" "$T0" 2>&1)
  assert_equals "" "$out" "no declarations: the alarm prints nothing"
  [ ! -e "$w/home/state/helper-unaccepted" ] || fail "the alarm wrote state with no declarations"
  [ ! -e "$w/home/state/alert-stores" ] || fail "the alarm registered a store with no declarations"
  pass "with no declarations the alarm prints and writes nothing"
}

# --arm binds the check through fm-check-register.sh and runs a first pass;
# the bound check runs the same pass; --disarm removes the stores and the check.
test_alarm_arm_and_disarm() {
  local w out at key
  w=$(alarm_world alarm-arm)
  at=$((T0 + 3600))
  land "$w" 'echo v2' "$at"
  key="helper-unaccepted-helper.sh-${V2:0:12}"

  out=$(FM_HELPER_CONSUMERS_NOW=$((at + 3 * 3600)) hc "$w" alarm --repo "$w/repo" --arm 2>&1) || fail "arming failed: $out"
  assert_contains "$out" "helper-unaccepted: armed in " "arming reports the arm"
  [ -x "$w/home/state/helper-unaccepted.check.sh" ] || fail "arming installed no check"
  [ -f "$w/home/state/helper-unaccepted.check-trust" ] || fail "the check is not bound"
  assert_equals "$key" "$(store_query "$w" main '.active | keys[]')" "arming runs a first pass"

  out=$(env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE FM_HELPER_CONSUMERS_NOW=$((at + 4 * 3600)) \
    "$w/home/state/helper-unaccepted.check.sh" 2>&1) || fail "the bound check failed: $out"
  assert_equals "" "$out" "the bound check prints nothing while its level is delivered"
  assert_equals "$key" "$(store_query "$w" main '.active | keys[]')" "the bound check keeps the one level"
  assert_equals 1 "$(store_query "$w" main '[.events[] | select(.action == "raised")] | length')" "the bound check raises nothing new"

  out=$(hc "$w" alarm --repo "$w/repo" --disarm 2>&1) || fail "disarming failed: $out"
  [ ! -e "$w/home/state/helper-unaccepted.check.sh" ] || fail "disarming left the check"
  [ ! -e "$w/home/state/helper-unaccepted.check-trust" ] || fail "disarming left the check's binding"
  [ ! -e "$w/home/state/alert-stores/helper-unaccepted.main.reg" ] || fail "disarming left the store registered"
  pass "arming binds the check and runs a pass, and disarming removes the stores and the check"
}

test_no_declarations_is_silent
test_malformed_declarations_hold_declared_helpers
test_check_advance_outcomes
test_pending_records_once_and_files_one_note
test_pending_range_and_repository_filters
test_log_validates_and_appends_one_line
test_holds_reads_back_every_window
test_alarm_w2_raises_once_and_clears_on_acceptance
test_alarm_supersession_owner_route_and_limit_file
test_alarm_failed_readings_raise_naming_the_file
test_alarm_without_declarations_is_silent
test_alarm_arm_and_disarm

echo "# all fm-helper-consumers tests passed"
