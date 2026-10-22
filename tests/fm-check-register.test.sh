#!/usr/bin/env bash
# Behavior tests for fm-check-register.sh --from: a staged check is bound
# before it becomes state/<id>.check.sh, an unsafe staged file is refused
# without touching the check or its binding, and a failed final rename puts
# the prior binding back.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-register)
REAL_MV=$(command -v mv)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_check() {  # <path> <word>: a private check that prints <word>
  printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$2" > "$1"
  chmod 0700 "$1"
}

register_in_place() {  # <home> <id> <word>
  write_check "$1/state/$2.check.sh" "$3"
  FM_HOME="$1" "$REGISTER" "$2" --no-handoff test-fixture >/dev/null \
    || fail "could not register the in-place fixture check $2"
}

stage_check() {  # <home> <word> -> a staged check in the home's state directory
  local staged
  staged=$(mktemp "$1/state/.staged-check.XXXXXX") || fail "could not stage a check"
  write_check "$staged" "$2"
  printf '%s\n' "$staged"
}

# The fake mv refuses to rename anything onto FM_TEST_CHECK and passes every
# other rename through.
install_failing_check_rename() {  # <home>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
args=("$@")
[ "${args[$# - 1]}" != "$FM_TEST_CHECK" ] || exit 1
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
}

register_with_fake_mv() {  # <home> <id> <args...>: run the register with the home's fake mv
  local home=$1 id=$2
  shift 2
  PATH="$home/fakebin:$PATH" FM_TEST_REAL_MV="$REAL_MV" FM_TEST_MV_LOG="$home/mv.log" \
    FM_TEST_CHECK="$home/state/$id.check.sh" FM_HOME="$home" "$REGISTER" "$id" "$@"
}

test_from_binds_the_check_before_it_appears() {
  local home state staged out status
  home=$(make_home observed)
  state="$home/state"
  fm_check_rename_observer "$home" >/dev/null

  staged=$(stage_check "$home" first)
  : > "$home/mv.log"
  status=0
  out=$(register_with_fake_mv "$home" custom --from "$staged" --no-handoff test-fixture 2>&1) || status=$?
  expect_code 0 "$status" "a fresh install from a staged check"
  assert_contains "$out" "registered: state/custom.check.sh" "the fresh install did not report its registration"
  assert_absent "$staged" "the fresh install left the staged check behind"
  assert_contains "$(cat "$state/custom.check.sh")" 'printf "first\n"' "the fresh install did not install the staged bytes"
  fm_custom_check_registered "$state" custom || fail "the freshly installed check is not bound to its bytes"
  assert_equals "trust absent|check bound" "$(paste -sd'|' "$home/mv.log")" \
    "a fresh install must publish the binding before the check appears"

  staged=$(stage_check "$home" first)
  : > "$home/mv.log"
  status=0
  out=$(register_with_fake_mv "$home" custom --from "$staged" --no-handoff test-fixture 2>&1) || status=$?
  expect_code 0 "$status" "a reinstall of the same bytes"
  assert_absent "$staged" "the same-bytes reinstall left the staged check behind"
  fm_custom_check_registered "$state" custom || fail "the same-bytes reinstall left the check unbound"
  assert_equals "trust bound|check bound" "$(paste -sd'|' "$home/mv.log")" \
    "a reinstall of the same bytes must keep the visible check bound throughout"

  staged=$(stage_check "$home" second)
  : > "$home/mv.log"
  status=0
  out=$(register_with_fake_mv "$home" custom --from "$staged" --no-handoff test-fixture 2>&1) || status=$?
  expect_code 0 "$status" "a replacement with other bytes"
  assert_absent "$staged" "the replacement left the staged check behind"
  assert_contains "$(cat "$state/custom.check.sh")" 'printf "second\n"' "the replacement did not install the staged bytes"
  fm_custom_check_registered "$state" custom || fail "the replacement left the check unbound"
  assert_equals "trust unbound|check bound" "$(paste -sd'|' "$home/mv.log")" \
    "a replacement may pair the old bytes with the new binding only between its two renames"

  pass "--from binds a staged check before it becomes the watcher's check"
}

test_from_accepts_a_relative_staged_name_in_either_option_order() {
  local home state staged status
  home=$(make_home relative)
  state="$home/state"
  staged=$(stage_check "$home" relative)
  status=0
  (cd "$state" && FM_HOME="$home" "$REGISTER" custom --no-handoff test-fixture --from "${staged##*/}" >/dev/null) \
    || status=$?
  expect_code 0 "$status" "an install from a staged name relative to the state directory"
  assert_absent "$staged" "the relative install left the staged check behind"
  fm_custom_check_registered "$state" custom || fail "the relative install left the check unbound"
  assert_contains "$(cat "$state/custom.check.sh")" 'printf "relative\n"' "the relative install did not install the staged bytes"
  pass "--from takes a staged name relative to the state directory, before or after --no-handoff"
}

# expect_refusal <home> <code> <stderr needle> <label> <args...>: the register
# refuses with <code>, and the registered check "custom" keeps its bytes and
# its binding.
expect_refusal() {
  local home=$1 code=$2 needle=$3 label=$4 status check_before trust_before
  shift 4
  check_before=$(cat "$home/state/custom.check.sh")
  trust_before=$(cat "$home/state/custom.check-trust")
  status=0
  FM_HOME="$home" "$REGISTER" custom "$@" >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code "$code" "$status" "$label"
  assert_contains "$(cat "$home/err.txt")" "$needle" "$label used the wrong stderr"
  assert_equals "$check_before" "$(cat "$home/state/custom.check.sh")" "$label changed the registered check"
  assert_equals "$trust_before" "$(cat "$home/state/custom.check-trust")" "$label changed the check's binding"
  fm_custom_check_registered "$home/state" custom || fail "$label left the registered check unbound"
}

test_from_refuses_a_staged_file_it_cannot_install_safely() {
  local home state staged alias
  home=$(make_home refusals)
  state="$home/state"
  register_in_place "$home" custom old
  register_in_place "$home" other other

  expect_refusal "$home" 2 "invalid custom check registration" "--from without a value" \
    --no-handoff test-fixture --from
  expect_refusal "$home" 2 "invalid custom check registration" "--from with an empty value" \
    --from '' --no-handoff test-fixture
  staged=$(stage_check "$home" new)
  expect_refusal "$home" 2 "invalid custom check registration" "a repeated --from" \
    --from "$staged" --from "$staged" --no-handoff test-fixture
  assert_present "$staged" "a refused option list removed the staged check"

  write_check "$state/custom.staged" new
  expect_refusal "$home" 1 "must be a hidden file in the state directory" "a staged check that is not hidden" \
    --from "$state/custom.staged" --no-handoff test-fixture
  assert_present "$state/custom.staged" "the not-hidden refusal removed the staged check"

  write_check "$home/data/.custom.staged" new
  expect_refusal "$home" 1 "must be a hidden file in the state directory" "a staged check outside the state directory" \
    --from "$home/data/.custom.staged" --no-handoff test-fixture
  assert_present "$home/data/.custom.staged" "the outside-state refusal removed the staged check"

  expect_refusal "$home" 1 "must be a hidden file in the state directory" "another check as the staged file" \
    --from "$state/other.check.sh" --no-handoff test-fixture
  fm_custom_check_registered "$state" other || fail "naming another check as the staged file unbound it"

  chmod 0755 "$staged"
  expect_refusal "$home" 1 "custom check is unavailable" "a staged check that is not private" \
    --from "$staged" --no-handoff test-fixture
  assert_present "$staged" "the non-private refusal removed the staged check"
  chmod 0700 "$staged"

  alias="$home/data/staged.alias"
  ln "$staged" "$alias"
  expect_refusal "$home" 1 "custom check is unavailable" "a hard-linked staged check" \
    --from "$staged" --no-handoff test-fixture
  assert_present "$staged" "the hard-link refusal removed the staged check"
  assert_present "$alias" "the hard-link refusal removed the external alias"
  rm -f "$alias"

  ln -s "$staged" "$state/.staged-link"
  expect_refusal "$home" 1 "custom check is unavailable" "a symlinked staged check" \
    --from "$state/.staged-link" --no-handoff test-fixture
  assert_present "$staged" "the symlink refusal removed the staged check's target"

  pass "--from refuses a staged file it cannot install safely and leaves the check and its binding alone"
}

test_from_refuses_a_destination_that_is_not_a_plain_file() {
  local home state staged status
  home=$(make_home destination)
  state="$home/state"
  mkdir "$state/dir.check.sh"
  staged=$(stage_check "$home" new)
  status=0
  FM_HOME="$home" "$REGISTER" dir --from "$staged" --no-handoff test-fixture \
    >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "an install onto a directory"
  assert_contains "$(cat "$home/err.txt")" "custom check path is unavailable" "the directory refusal used the wrong stderr"
  assert_present "$staged" "the directory refusal removed the staged check"
  assert_absent "$state/dir.check-trust" "the directory refusal published a binding"
  [ -z "$(ls -A "$state/dir.check.sh")" ] || fail "the directory refusal moved the staged check into the directory"
  pass "--from refuses to install onto a destination that is not a plain file"
}

test_from_restores_the_prior_binding_when_the_check_rename_fails() {
  local home state staged status
  home=$(make_home failed-rename)
  state="$home/state"
  install_failing_check_rename "$home"

  register_in_place "$home" custom old
  staged=$(stage_check "$home" new)
  status=0
  register_with_fake_mv "$home" custom --from "$staged" --no-handoff test-fixture \
    >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "an install whose check rename fails"
  assert_contains "$(cat "$home/err.txt")" "could not install the staged custom check" \
    "the failed rename used the wrong stderr"
  assert_present "$staged" "the failed rename removed the staged check"
  assert_contains "$(cat "$state/custom.check.sh")" 'printf "old\n"' "the failed rename changed the installed check"
  fm_custom_check_registered "$state" custom || fail "the failed rename did not restore the prior binding"

  staged=$(stage_check "$home" fresh)
  status=0
  register_with_fake_mv "$home" fresh --from "$staged" --no-handoff test-fixture \
    >"$home/out.txt" 2>"$home/err.txt" || status=$?
  expect_code 1 "$status" "a fresh install whose check rename fails"
  assert_present "$staged" "the failed fresh install removed the staged check"
  assert_absent "$state/fresh.check.sh" "the failed fresh install left a check"
  assert_absent "$state/fresh.check-trust" "the failed fresh install left a binding to a check that never appeared"

  pass "a failed check rename leaves the staged file and puts the prior binding back"
}

test_from_binds_the_check_before_it_appears
test_from_accepts_a_relative_staged_name_in_either_option_order
test_from_refuses_a_staged_file_it_cannot_install_safely
test_from_refuses_a_destination_that_is_not_a_plain_file
test_from_restores_the_prior_binding_when_the_check_rename_fails
