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
#   - check-land refuses a head that lands helper bytes a consumer accepting
#     the current version has not accepted, passes it once the declaration
#     accepts or --allow-break names the consumer, never holds a head that
#     leaves helper bytes as they are, holds a head that changed a helper the
#     base also changed (diverged, which --allow-break does not release), maps
#     a hold to exit 1 under --condition, takes the origin default branch as
#     its base (origin/HEAD, else origin/main or origin/master), fetches a
#     missing head with --fetch, by id when no branch carries it, and is quiet
#     for another repository or a helper in another project. A declared helper
#     that cannot be located holds only a head that changes a file with its
#     basename, and is named as a stale declaration.
#   - Across the 10-30 sequence (one accept round, then a candidate) on
#     fixture bytes, check-land keeps every landed helper version accepted by
#     every consumer, and check-advance never answers hold.
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

# commit_on <w> <parent> <path> <content>: a commit on <parent> that sets
# <path> to <content>, leaving the checkout as it is. Echoes its sha.
commit_on() {
  local w=$1 blob tree
  blob=$(printf '%s' "$4" | git -C "$w/repo" hash-object -w --stdin)
  GIT_INDEX_FILE="$w/index.tmp" git -C "$w/repo" read-tree "$2"
  GIT_INDEX_FILE="$w/index.tmp" git -C "$w/repo" update-index --add --cacheinfo "100644,$blob,$3"
  tree=$(GIT_INDEX_FILE="$w/index.tmp" git -C "$w/repo" write-tree)
  rm -f "$w/index.tmp"
  git -C "$w/repo" commit-tree "$tree" -p "$2" -m "set $3"
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
  mkdir -p "$w/not-git"
  out=$(hc "$w" check-advance "$w/not-git" HEAD 2>&1) || rc=$?
  expect_code 0 "$rc" "check-advance with no declarations reads no checkout"
  assert_equals "" "$out" "check-advance with no declarations is silent on any checkout"
  out=$(hc "$w" check-land --repo "$w/not-git" HEAD 2>&1) || rc=$?
  expect_code 0 "$rc" "check-land with no declarations reads no checkout"
  assert_equals "" "$out" "check-land with no declarations is silent on any checkout"
  pass "no declarations: check-advance, check-land and pending are silent no-ops"
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

  declare_consumer "$w" holder "$w/gone/bin/helper.sh" "$V1"
  rc=0
  out=$(hc "$w" check-advance "$w/repo" "$(cat "$w/c2")" 2>&1) || rc=$?
  expect_code 0 "$rc" "a declared helper that cannot be located never holds an update"
  assert_equals "" "$out" "a helper that cannot be located is not reported by check-advance"

  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"
  rc=0
  hc "$w" check-advance --allow-break "" "$w/repo" "$(cat "$w/c2")" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "--allow-break with an empty consumer is a usage error"
  rc=0
  hc "$w" check-advance "$w/repo" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "check-advance without a target is a usage error"

  rc=0
  hc "$w" check-advance "$w/repo" no-such-rev >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown target revision is an error, which ff_target treats as a hold"
  pass "check-advance holds, advances, overrides, and reports exactly as declared"
}

test_check_land_gates_helper_changes() {
  local w out err rc c1 c2 c3
  w=$(new_world land)
  c1=$(cat "$w/c1") c2=$(cat "$w/c2")
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"
  declare_consumer "$w" waiter "$w/repo/bin/helper.sh" "$(sha_of 'older')"

  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c2" 2>"$w/err") || rc=$?
  err=$(cat "$w/err")
  expect_code 3 "$rc" "a head landing unaccepted helper bytes holds"
  assert_contains "$out" "hold"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"holder" "the hold names the helper, version and consumer"
  assert_contains "$out" "waiting"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"waiter" "a consumer that already waits is reported"
  assert_contains "$err" "$c2 may not land on $c1 yet" "the refusal names the head and base"

  rc=0
  hc "$w" check-land --repo "$w/repo" --condition "$c1" "$c2" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "--condition maps a hold to not yet"

  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" --allow-break holder "$c1" "$c2" 2>&1) || rc=$?
  expect_code 0 "$rc" "--allow-break releases the hold"
  assert_contains "$out" "break"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"holder" "the break is recorded"

  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1" "$V2"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" --condition "$c1" "$c2" 2>&1) || rc=$?
  expect_code 0 "$rc" "a head whose helper bytes every holding consumer accepts lands"
  assert_not_contains "$out" "holder" "an accepting consumer is not reported"

  # A head that leaves every declared helper's bytes alone is never held, even
  # beside a malformed declaration and a consumer that accepts nothing.
  declare_consumer "$w" holder "$w/repo/bin/helper.sh"
  printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=typo' 'owner=x' "helper=$w/repo/bin/helper.sh" 'acept=abc' > "$w/decl/typo.conf"
  c3=$(commit_on "$w" "$c1" bin/other.sh $'echo changed\n')
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c3" 2>&1) || rc=$?
  expect_code 0 "$rc" "a head that does not change helper bytes lands"
  assert_not_contains "$out" "unproven" "an untouched helper is not held by a malformed declaration"
  assert_not_contains "$out" "hold"$'\t' "an untouched helper is not held"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c2" 2>&1) || rc=$?
  expect_code 3 "$rc" "a malformed declaration holds a head that changes its helper"
  assert_contains "$out" "unproven"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"typo" "the unproven hold names the declaration"
  rm -f "$w/decl/typo.conf"

  # A helper at the same path in another project is not this project's helper.
  rm -f "$w/decl/waiter.conf"
  fm_git_init_commit "$w/other-project"
  mkdir -p "$w/other-project/bin"
  printf 'echo v1\n' > "$w/other-project/bin/helper.sh"
  git -C "$w/other-project" add -A
  git -C "$w/other-project" commit -qm helper
  declare_consumer "$w" holder "$w/other-project/bin/helper.sh" "$V1"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c2" 2>&1) || rc=$?
  expect_code 0 "$rc" "a helper in another project never holds this project's landing"
  assert_equals "" "$out" "another project's helper is not reported"
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"

  rc=0
  hc "$w" check-land --repo "$w/repo" --allow-break "" "$c1" "$c2" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "check-land --allow-break with an empty consumer is a usage error"
  rc=0
  hc "$w" check-land --repo "$w/repo" "$c1" no-such-rev >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown head is an error, which every landing path refuses"

  # A stale declaration whose helper cannot be located holds a head that
  # changes any file with the helper's basename, wherever it now lives, and
  # no other head.
  declare_consumer "$w" holder "$w/old/place/helper.sh" "$V1"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c2" 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "a head changing a file named like an unlocatable helper holds"
  assert_contains "$out" "malformed"$'\t'"$w/decl/holder.conf"$'\t'"declared helper $w/old/place/helper.sh cannot be located" \
    "the stale declaration is named"
  assert_contains "$out" "unproven"$'\t'"$w/old/place/helper.sh"$'\t'"$V2"$'\t'"holder" \
    "the hold names the head's bytes of the same-named file and the consumer"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" --allow-break holder "$c1" "$c2" 2>&1) || rc=$?
  expect_code 0 "$rc" "--allow-break releases a stale declaration's hold"
  assert_contains "$out" "break"$'\t'"$w/old/place/helper.sh"$'\t'"$V2"$'\t'"holder" "the break on a stale declaration is recorded"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c3" 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale declaration never holds a head that changes no file of its helper's name"
  assert_contains "$out" "malformed"$'\t'"$w/decl/holder.conf" "the stale declaration is still named on a passing head"
  assert_not_contains "$out" "unproven" "a head changing no same-named file is not held"
  mkdir -p "$w/plain"
  printf 'echo v1\n' > "$w/plain/helper.sh"
  declare_consumer "$w" holder "$w/plain/helper.sh" "$V1"
  rc=0
  GIT_CEILING_DIRECTORIES="$w" hc "$w" check-land --repo "$w/repo" "$c1" "$c2" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "a declared helper outside any git checkout is stale too"
  rm -f "$w/decl/holder.conf"
  printf '%s\n' 'schema=fm-helper-consumer/v1' 'consumer=typo' 'owner=x' "helper=$w/old/place/helper.sh" 'acept=abc' > "$w/decl/typo.conf"
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c1" "$c2" 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "a malformed declaration's unlocatable helper holds a same-named change"
  assert_contains "$out" "unproven"$'\t'"$w/old/place/helper.sh"$'\t'"$V2"$'\t'"typo" "the hold names the malformed declaration"
  rc=0
  hc "$w" check-land --repo "$w/repo" "$c1" "$c3" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a malformed declaration's unlocatable helper holds no other head"
  pass "check-land holds unaccepted helper bytes, passes accepted or broken ones, and never holds an untouched helper"
}

test_check_land_judges_the_bytes_a_landing_yields() {
  local w out rc c1 c2 base_only both same
  w=$(new_world land-merge)
  c1=$(cat "$w/c1") c2=$(cat "$w/c2")
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V2"

  # The base moved the helper to v2, the only version the consumer accepts; a
  # head from before that which changes only other.sh leaves the base's bytes,
  # so it lands, though its own tree still carries v1.
  base_only=$(commit_on "$w" "$c1" bin/other.sh $'echo changed\n')
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" "$c2" "$base_only" 2>&1) || rc=$?
  expect_code 0 "$rc" "a head behind a base that alone changed the helper lands"
  assert_equals "" "$out" "a base-only change is not reported"

  same=$(commit_on "$w" "$c1" bin/helper.sh $'echo v2\n')
  rc=0
  hc "$w" check-land --repo "$w/repo" "$c2" "$same" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a head that makes the base's own helper change lands"

  both=$(commit_on "$w" "$c1" bin/helper.sh $'echo v3\n')
  rc=0
  out=$(hc "$w" check-land --repo "$w/repo" --allow-break holder "$c2" "$both" 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "a head and base that both changed the helper hold, whatever is broken"
  assert_contains "$out" "diverged"$'\t'"$w/repo/bin/helper.sh"$'\t'"$(sha_of $'echo v3\n')"$'\t'"holder" \
    "the diverged hold names the head's bytes and the consumer"
  pass "check-land judges the bytes a landing yields, and holds a head whose landed bytes are unknown"
}

test_check_land_default_base_fetch_and_repository_filter() {
  local w out rc c1 c2 pr
  w=$(new_world land-remote)
  c1=$(cat "$w/c1") c2=$(cat "$w/c2")
  git init -q --bare "$w/origin.git"
  git -C "$w/repo" push -q "$w/origin.git" "$c1:refs/heads/main" "$c2:refs/heads/candidate"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/repo" remote add origin "$w/origin.git"
  git -C "$w/repo" fetch -q origin
  git init -q "$w/clone"
  git -C "$w/clone" remote add origin "$w/origin.git"
  git -C "$w/clone" fetch -q origin main
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"

  rc=0
  hc "$w" check-land --repo "$w/clone" "$c2" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a head the checkout does not have is an error without --fetch"
  rc=0
  out=$(hc "$w" check-land --repo "$w/clone" --fetch "$c2" 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "--fetch reads the head and judges it against origin's default branch"
  assert_contains "$out" "hold"$'\t'"$w/repo/bin/helper.sh"$'\t'"$V2"$'\t'"holder" \
    "a helper in another checkout of the same project is judged"

  rc=0
  hc "$w" check-land --repo "$w/clone" --if-repo "$w/origin.git" "$c2" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "this repository's landing is gated under --if-repo"

  # A head on no branch, as a pull request's is, is fetched by its id.
  pr=$(commit_on "$w" "$c1" bin/helper.sh $'echo pr\n')
  git -C "$w/repo" push -q "$w/origin.git" "$pr:refs/pull/9/head"
  git -C "$w/origin.git" config uploadpack.allowAnySHA1InWant true
  rc=0
  out=$(hc "$w" check-land --repo "$w/clone" --fetch "$pr" 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "--fetch fetches a head no branch carries by its id"
  assert_contains "$out" "hold"$'\t'"$w/repo/bin/helper.sh"$'\t'"$(sha_of $'echo pr\n')"$'\t'"holder" \
    "a head fetched by id is judged"

  rc=0
  out=$(hc "$w" check-land --repo "$w/clone" --if-repo github.com/example/other "$c2" 2>&1) || rc=$?
  expect_code 0 "$rc" "another repository's landing is not gated"
  assert_equals "" "$out" "another repository's landing prints nothing"

  rc=0
  out=$(FM_HELPER_CONSUMERS="$w/none" FM_HELPER_VERSIONS="$w/versions" "$HC" check-land --repo "$w/clone" "$c2" 2>&1) || rc=$?
  expect_code 0 "$rc" "no declarations: nothing is gated"
  assert_equals "" "$out" "no declarations: check-land prints nothing"
  pass "check-land takes origin's default branch, fetches a missing head, and skips other repositories"
}

test_origin_default_branch() {
  local w err rc c1 c2 out c
  w=$(new_world origin-default)
  c1=$(cat "$w/c1") c2=$(cat "$w/c2")
  git init -q --bare "$w/origin.git"
  git -C "$w/repo" push -q "$w/origin.git" "$c1:refs/heads/main" "$c1:refs/heads/trunk" "$c1:refs/heads/master"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/repo" remote add origin "$w/origin.git"
  declare_consumer "$w" holder "$w/repo/bin/helper.sh" "$V1"
  for c in trunk master none; do
    git init -q "$w/$c"
    git -C "$w/$c" remote add origin "$w/origin.git"
  done
  git -C "$w/trunk" fetch -q origin main trunk
  git -C "$w/trunk" remote set-head origin trunk
  git -C "$w/master" fetch -q origin master
  git -C "$w/master" remote set-head origin -d >/dev/null 2>&1 || true
  for c in trunk master; do git -C "$w/repo" push -q "$w/$c" "$c2:refs/heads/candidate"; done

  rc=0
  hc "$w" check-land --repo "$w/trunk" "$c2" >/dev/null 2>"$w/err" || rc=$?
  err=$(cat "$w/err")
  expect_code 3 "$rc" "origin/HEAD names the base"
  assert_contains "$err" "may not land on origin/trunk yet" "origin/HEAD's target wins over origin/main"
  rc=0
  hc "$w" check-land --repo "$w/master" "$c2" >/dev/null 2>"$w/err" || rc=$?
  err=$(cat "$w/err")
  expect_code 3 "$rc" "origin/master is the base without origin/HEAD or origin/main"
  assert_contains "$err" "may not land on origin/master yet" "the base is origin/master"
  rc=0
  hc "$w" check-land --repo "$w/none" "$c1" >/dev/null 2>"$w/err" || rc=$?
  err=$(cat "$w/err")
  expect_code 2 "$rc" "no origin default branch is an error"
  assert_contains "$err" "no origin default branch in" "the error names the missing default branch"

  out=$(hc "$w" pending --repo "$w/none")
  assert_contains "$out" "helper-pending: skipped: no origin default branch in $w/none" "pending without a default branch skips"
  git -C "$w/repo" push -q "$w/origin.git" "$c2:refs/heads/main"
  git -C "$w/repo" fetch -q origin
  out=$(hc "$w" pending --repo "$w/repo")
  assert_contains "$out" "helper-pending: bin/helper.sh version ${V2:0:12} recorded" "pending without a revision reads origin's default branch"
  pass "check-land and pending take origin/HEAD, else origin/main or origin/master, and refuse without one"
}

# The 10-30 sequence on fixture bytes: version B lands through an accept round
# (one consumer at a time), then candidate C arrives. With the landing gate,
# main and green carry only versions every consumer accepts, so the update
# gate's check-advance never answers hold.
test_check_land_keeps_the_10_30_sequence_accepted() {
  local w main cand rc out c b5 c2c
  w=$(new_world ten-thirty)
  main=$(cat "$w/c1")
  git -C "$w/repo" update-ref refs/heads/green "$main"
  for c in tetjet-filler tetjet-services tetjet-test-lane; do
    declare_consumer "$w" "$c" "$w/repo/bin/helper.sh" "$V1"
  done
  b5=$(sha_of $'echo b536047d\n')
  c2c=$(sha_of $'echo 2c69d78f\n')

  green_accepted() {  # every consumer accepts the helper bytes main and green carry
    local ref sha f
    for ref in "$main" green; do
      sha=$(git -C "$w/repo" cat-file blob "$ref:bin/helper.sh" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
      for f in "$w"/decl/*.conf; do
        grep -qx "accept=$sha" "$f" || fail "10-30: $(basename "$f") does not accept ${sha:0:12} on $ref ($1)"
      done
    done
  }
  update_never_holds() {  # the home's update gate on green
    local rc=0 out
    out=$(hc "$w" check-advance "$w/repo" green 2>&1) || rc=$?
    expect_code 0 "$rc" "10-30: check-advance on green ($1)"
    assert_not_contains "$out" "hold"$'\t' "10-30: check-advance answered hold ($1)"
    git -C "$w/repo" reset -q --hard green
  }
  land() {  # <head>: lands it on main and green only when check-land passes
    local rc=0
    hc "$w" check-land --repo "$w/repo" "$main" "$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) main=$1; git -C "$w/repo" update-ref refs/heads/green "$main"; return 0 ;;
      3) return 3 ;;
      *) fail "10-30: check-land failed with exit $rc" ;;
    esac
  }

  cand=$(commit_on "$w" "$main" bin/helper.sh $'echo b536047d\n')
  for c in tetjet-filler tetjet-services; do
    rc=0; land "$cand" || rc=$?
    expect_code 3 "$rc" "10-30: b536047d lands before $c accepts"
    green_accepted "b536047d accept round"; update_never_holds "b536047d accept round"
    declare_consumer "$w" "$c" "$w/repo/bin/helper.sh" "$V1" "$b5"
  done
  rc=0; land "$cand" || rc=$?
  expect_code 3 "$rc" "10-30: b536047d lands before tetjet-test-lane accepts"
  declare_consumer "$w" tetjet-test-lane "$w/repo/bin/helper.sh" "$V1" "$b5"
  land "$cand" || fail "10-30: b536047d does not land once every consumer accepts"
  green_accepted "b536047d landed"; update_never_holds "b536047d landed"

  # An unrelated ship lands meanwhile, then the 2c69d78f candidate arrives.
  land "$(commit_on "$w" "$main" bin/other.sh $'echo unrelated\n')" \
    || fail "10-30: an unrelated head was held"
  cand=$(commit_on "$w" "$main" bin/helper.sh $'echo 2c69d78f\n')
  rc=0; land "$cand" || rc=$?
  expect_code 3 "$rc" "10-30: the 2c69d78f candidate lands unaccepted"
  green_accepted "2c69d78f candidate"; update_never_holds "2c69d78f candidate"
  for c in tetjet-filler tetjet-services tetjet-test-lane; do
    declare_consumer "$w" "$c" "$w/repo/bin/helper.sh" "$b5" "$c2c"
  done
  land "$cand" || fail "10-30: 2c69d78f does not land once accepted"
  green_accepted "2c69d78f landed"; update_never_holds "2c69d78f landed"
  out=$(git -C "$w/repo" cat-file blob green:bin/helper.sh)
  assert_equals "echo 2c69d78f" "$out" "10-30: green ends on the accepted candidate"
  pass "the 10-30 sequence keeps main and green fully accepted, and check-advance never holds"
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
test_check_land_gates_helper_changes
test_check_land_judges_the_bytes_a_landing_yields
test_check_land_default_base_fetch_and_repository_filter
test_origin_default_branch
test_check_land_keeps_the_10_30_sequence_accepted
test_pending_records_once_and_files_one_note
test_pending_range_and_repository_filters

echo "# all fm-helper-consumers tests passed"
