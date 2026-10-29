#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, tier selection and shard packing, bounded concurrency, budgets,
# timing markers, JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

# The coverage guard's output is a pure function of the checkout, so the tests
# that read it share one invocation instead of repeating it.
COVERAGE_OUT=
COVERAGE_LOADED=0
load_coverage() {
  [ "$COVERAGE_LOADED" -eq 1 ] && return 0
  COVERAGE_OUT=$("$RUNNER" --check-coverage)
  COVERAGE_LOADED=1
}

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-dod-lib.test.sh \
    fm-documentation-audiences.test.sh \
    fm-test-isolation-proof.test.sh \
    fm-test-run.test.sh \
    fm-test-fixtures.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-harness-adapter-references.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-procevent-quota.test.sh \
    fm-quota-choose.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-pi-windows-shell-invocation.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-control-herdr-smoke.test.sh \
    fm-backend-herdr-presentation-e2e.test.sh \
    fm-backend-herdr-launcher-workspace-e2e.test.sh \
    fm-secondmate-harness.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-spawn.sh"
  : >"$repo/bin/fm-control-lib.sh"
  : >"$repo/bin/fm-timeout-lib.sh"
  : >"$repo/bin/fm-procevent-quota.sh"
  : >"$repo/bin/fm-quota-axi-lib.sh"
  : >"$repo/bin/fm-quota-choose.sh"
  : >"$repo/bin/unmapped-source.sh"
  # A shared top-level test fixture read by two suites in different families,
  # beside a tests/ file nothing reads at all.
  : >"$repo/tests/shared-probe-fixture.sh"
  : >"$repo/tests/unread-thing.sh"
  printf '# shared-probe-fixture.sh\n' >>"$repo/tests/fm-pr-merge.test.sh"
  printf '# shared-probe-fixture.sh\n' >>"$repo/tests/fm-secondmate-safety.test.sh"
  # A nested fixture whose consuming suite names only the fixture directory,
  # the shape the tests/fixtures/<dir>/ arm is keyed for.
  mkdir -p "$repo/tests/fixtures/demo"
  : >"$repo/tests/fixtures/demo/demo-fixture.sh"
  printf '# tests/fixtures/demo\n' >>"$repo/tests/fm-backend-orca.test.sh"
  # A shared helper with no curated family of its own, named by exactly ONE
  # script of the expensive real-Herdr family and consumed by one curated
  # watcher script. This is the shape that made a one-line helper change select
  # every real-Herdr E2E.
  : >"$repo/bin/shared-probe-lib.sh"
  printf '# shared-probe-lib.sh\n' >>"$repo/tests/fm-backend-herdr-smoke.test.sh"
  # shellcheck disable=SC2016  # literal fixture text: the reference must reach
  # the file verbatim so the changed-file scan can find it, not expand here.
  printf '. "$ROOT/bin/shared-probe-lib.sh"\n' >"$repo/bin/fm-watch-probe.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p \
    "$repo/.agents/skills/example" \
    "$repo/.agents/skills/harness-adapters/references/common" \
    "$repo/.claude" "$repo/.pi/extensions" "$repo/docs" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/SKILL.md"
  : >"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib"
  : >"$repo/.pi/extensions/lib/fm-operational-input.ts"
  : >"$repo/docs/fm-test-isolation-proof.md"
  : >"$repo/CONTRIBUTING.md"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

# Build a repository with a primary checkout and one linked worktree, each
# holding a runnable copy of the runner and a probe suite that records the fact
# that it ran. Untracked copies are enough: the runner resolves its root from
# its own path, and the probe is named explicitly.
init_primary_and_linked_worktree() {
  local repo=$1 linked=$2 tree
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b linked-probe "$linked"
  for tree in "$repo" "$linked"; do
    mkdir -p "$tree/bin" "$tree/tests"
    cp "$RUNNER" "$tree/bin/fm-test-run.sh"
    cp "$ROOT/tests/git-config-helpers.sh" "$tree/tests/"
    chmod +x "$tree/bin/fm-test-run.sh"
    cat >"$tree/tests/probe.test.sh" <<PROBE
#!/usr/bin/env bash
echo "ok - probe suite"
: >"$tree/ran"
PROBE
    chmod +x "$tree/tests/probe.test.sh"
  done
}

# A task worker's isolated placement is checked once, when the task starts.
# Nothing re-checks it, so a worker that later changes directory into the
# repository's primary checkout would run this branch-switching suite in the one
# checkout every linked worktree resolves against. The runner refuses that.
test_task_marker_refuses_the_primary_checkout() {
  local tmp repo linked out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-primary.XXXXXX")
  repo="$tmp/repo"
  linked="$tmp/linked"
  init_primary_and_linked_worktree "$repo" "$linked"

  # Marker set, primary checkout: refuse, name the primary, and run nothing.
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" tests/probe.test.sh 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "the runner must refuse the primary checkout under a task marker"; }
  assert_contains "$out" "primary checkout" "refusal did not name the primary checkout"
  assert_contains "$out" "FM_TASK_ID=probe-task" "refusal did not name the task marker"
  assert_contains "$out" "task worktree" "refusal did not point at the task worktree"
  assert_not_contains "$out" "FM_TEST_BEGIN" "the refusal must happen before any suite runs"
  assert_absent "$repo/ran" "the refused run still executed a suite"

  # Marker set, linked worktree: the assigned placement, so the suite runs.
  FM_TASK_ID=probe-task "$linked/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "the runner must still run in a linked task worktree"; }
  assert_present "$linked/ran" "the linked-worktree run did not execute its suite"

  # No marker: a person in their own checkout is unaffected.
  "$repo/bin/fm-test-run.sh" tests/probe.test.sh >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "an unmarked run in the primary checkout must be unchanged"; }
  assert_present "$repo/ran" "the unmarked run did not execute its suite"

  # Inspection executes nothing, so it stays available even in the primary.
  rm -f "$repo/ran"
  out=$(FM_TASK_ID=probe-task "$repo/bin/fm-test-run.sh" --list tests/probe.test.sh 2>&1) \
    || { rm -rf "$tmp"; fail "--list must remain available under a task marker"; }
  [ "$out" = "tests/probe.test.sh" ] \
    || { rm -rf "$tmp"; fail "--list under a task marker printed: $out"; }
  assert_absent "$repo/ran" "--list must not execute a suite"

  rm -rf "$tmp"
  pass "a task marker refuses execution in the primary checkout and leaves worktrees and inspection alone"
}

test_changed_runner_surfaces_select_their_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-owner-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  # A change to the runner selects the WHOLE pure-contract-unit family, not
  # just its own contract test. The runner executes every script in that
  # family, so its own test passing proves its logic is right, not that the
  # suite it drives still runs. Narrowing this to the contract owners would
  # also make any wall-clock claim about the changed suite trivially true by
  # not running the work.
  printf '\n' >>"$repo/bin/fm-test-run.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-test-run.test.sh*) ;;
    *) fail "runner change did not select its own contract test: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-dod-lib.test.sh*) ;;
    *) fail "runner change did not select its pure-contract-unit family: $listed" ;;
  esac
  # The suite that proves the runner's per-suite fixture Git isolation lives in
  # the standalone family, which pure-contract-unit never reaches.
  case "$listed" in
    *tests/fm-test-fixtures.test.sh*) ;;
    *) fail "runner change did not select its fixture-isolation regression: $listed" ;;
  esac
  git -C "$repo" add bin/fm-test-run.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm runner-change

  # The same holds for the surfaces that document that contract.
  printf '\n' >>"$repo/docs/fm-test-isolation-proof.md"
  printf '\n' >>"$repo/CONTRIBUTING.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD | LC_ALL=C sort)
  case "$listed" in
    *tests/fm-documentation-audiences.test.sh*) ;;
    *) fail "documentation surface change did not select audience coverage: $listed" ;;
  esac
  case "$listed" in
    *tests/fm-brief.test.sh*) ;;
    *) fail "documentation surface change did not select its curated family: $listed" ;;
  esac

  rm -rf "$tmp"
  pass "runner and its documentation surfaces select their curated family, not just their contract owners"
}

test_shell_line_ending_policy_selects_runner_contract() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-attributes.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '*.sh text eol=lf\n' >"$repo/.gitattributes"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-test-run.test.sh" \
    "shell line-ending policy selects the runner contract"
  rm -rf "$tmp"
  pass "shell line-ending policy selects runner coverage"
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/git-config-helpers.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "git-config helper selects lib.sh dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "git-config helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "git-config helper selects snapshot dependents"
  git -C "$repo" add tests/git-config-helpers.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm git-config-helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/bin/fm-spawn.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-presentation-e2e.test.sh" "spawn selects the real-Herdr presentation e2e"
  assert_contains "$listed" "tests/fm-backend-herdr-launcher-workspace-e2e.test.sh" "spawn selects the real-Herdr launcher e2e"
  assert_contains "$listed" "tests/fm-secondmate-harness.test.sh" "spawn selects the secondmate harness"
  git -C "$repo" add bin/fm-spawn.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm spawn-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-session-start.test.sh" "Claude settings and turn-end guard select session coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "turn-end extension selects native-Windows shell coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/.pi/extensions/lib/fm-operational-input.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pi-windows-shell-invocation.test.sh" \
    "operational-input extension selects native-Windows shell coverage"
  git -C "$repo" add .pi/extensions/lib/fm-operational-input.ts
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm operational-input-source-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/references/common/dispatch.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter reference selects portable structural coverage"
  assert_contains "$listed" "tests/fm-afk-pi-herdr-return-e2e.test.sh" "harness adapter reference selects the opt-in live guards"
  git -C "$repo" add .agents/skills/harness-adapters
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-reference-change

  printf '\n' >>"$repo/.agents/skills/harness-adapters/SKILL.md"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-harness-adapter-references.test.sh" "harness adapter router selects portable structural coverage"
  assert_contains "$listed" "tests/fm-afk-pi-herdr-return-e2e.test.sh" "harness adapter router selects the opt-in live guards"
  git -C "$repo" add .agents/skills/harness-adapters/SKILL.md
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm harness-adapter-router-change

  printf '\n' >>"$repo/bin/fm-procevent-quota.sh"
  printf '\n' >>"$repo/bin/fm-quota-choose.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "quota process-event source selects its focused test"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "quota chooser source selects its focused test"
  git -C "$repo" add bin/fm-procevent-quota.sh bin/fm-quota-choose.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-source-change

  printf '\n' >>"$repo/bin/fm-quota-axi-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "shared quota validator selects process-event coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "shared quota validator selects chooser coverage"
  git -C "$repo" add bin/fm-quota-axi-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm quota-validator-change

  printf '\n' >>"$repo/bin/fm-control-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" \
    "control library keeps backend coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "control library keeps session coverage"
  assert_contains "$listed" "tests/fm-quota-choose.test.sh" \
    "control library selects chooser coverage"
  git -C "$repo" add bin/fm-control-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm control-lib-change

  printf '\n' >>"$repo/bin/fm-timeout-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent-quota.test.sh" \
    "timeout library selects quota polling coverage"
  git -C "$repo" add bin/fm-timeout-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm timeout-lib-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"

  rm -f "$repo/src/unmapped.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  [ -z "$listed" ] || fail "a retired unmapped source without consumers selected tests: $listed"
  rm -rf "$tmp"
  pass "changed selection covers dependents, fails closed for live unmapped source, and accepts retired unconsumed source"
}

# A direct test reference is per-script evidence. Widening it to the referencing
# test's whole family is what turned a one-line change to a shared helper into
# every real-Herdr E2E, including scripts with no dependency on it at all.
# Consumer bin/ scripts must still resolve through the curated map, so recorded
# family-level coupling is not lost along the way.
test_changed_bin_reference_selects_per_script_not_per_family() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-scope.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/bin/shared-probe-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)

  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" \
    "the one gated script that names the helper must still be selected"
  case "$listed" in
    *tests/fm-control-herdr-smoke.test.sh*)
      fail "a single gated script's reference dragged in its whole family: $listed"
      ;;
  esac
  # The curated consumer keeps its family-level coupling.
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a curated consumer of the helper must still select its whole family"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" \
    "a curated consumer of the helper must still select its whole family"

  rm -rf "$tmp"
  pass "a bin reference selects the referencing scripts, and consumers still select their curated families"
}

# Commit everything in <repo> so the next change is the only changed path.
commit_fixture_setup() {
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qm "$2"
}

# Sets LISTED to the changed-path listing of <repo>, failing the case unless
# the runner exits 0, since any exit 2 would escalate a CI push to the full
# layout.
LISTED=
changed_listing() {  # <repo> <label>
  local rc
  set +e
  LISTED=$(cd "$1" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$1.err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$2 must not escalate, got exit $rc: $(cat "$1.err")"
}

# The safety guard's risky-area list and skill prose used to fall through to
# the unmapped refusal. The list selects the two suites that read it; a skill
# file selects only a suite naming that exact file, and otherwise nothing,
# as docs/ does.
test_changed_risky_list_and_skill_prose_map_without_escalating() {
  local tmp repo listed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-lists.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'bin/fm-spawn.sh\n' >"$repo/tests/risky-areas.list"
  printf '#!/usr/bin/env bash\n' >"$repo/tests/fm-safety-guard.test.sh"
  printf '#!/usr/bin/env bash\n' >"$repo/tests/fm-lean-review.test.sh"
  mkdir -p "$repo/.agents/skills/example/references"
  : >"$repo/.agents/skills/example/references/notes.md"
  : >"$repo/.agents/skills/example/references/read-by-a-suite.md"
  printf '# .agents/skills/example/references/read-by-a-suite.md\n' \
    >>"$repo/tests/fm-brief.test.sh"
  commit_fixture_setup "$repo" list-and-skill-setup

  printf 'bin/fm-control-lib.sh\n' >>"$repo/tests/risky-areas.list"
  changed_listing "$repo" "a risky-area list change"
  listed=$LISTED
  [ "$listed" = "tests/fm-safety-guard.test.sh"$'\n'"tests/fm-lean-review.test.sh" ] \
    || fail "the risky-area list must select exactly its two reader suites, got: $listed"
  commit_fixture_setup "$repo" risky-list-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.agents/skills/example/references/notes.md"
  changed_listing "$repo" "skill prose no suite reads"
  listed=$LISTED
  [ -z "$listed" ] || fail "skill prose no suite reads selected tests: $listed"
  commit_fixture_setup "$repo" skill-prose-change

  printf '\n' >>"$repo/.agents/skills/example/references/read-by-a-suite.md"
  changed_listing "$repo" "a skill reference a suite reads"
  listed=$LISTED
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "a skill reference must select exactly the suite naming it, got: $listed"

  rm -rf "$tmp"
  pass "the risky-area list selects its readers and skill prose selects only a suite naming it"
}

# Plugin suites name a plugin by basename, and plugins share lib/ modules, so
# any plugin file selects every suite naming a plugin file or the plugin
# directory. With no such suite left, a live plugin still refuses.
test_changed_opencode_plugin_selects_plugin_suites() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-plugin.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  mkdir -p "$repo/.opencode/plugins/lib"
  : >"$repo/.opencode/plugins/fm-primary-demo-check.js"
  : >"$repo/.opencode/plugins/lib/fm-demo-shared.js"
  printf 'for plugin in fm-primary-demo-check.js; do :; done\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .opencode/plugins\n' >>"$repo/tests/fm-daemon.test.sh"
  commit_fixture_setup "$repo" plugin-setup

  printf '\n' >>"$repo/.opencode/plugins/fm-primary-demo-check.js"
  changed_listing "$repo" "a plugin change"
  listed=$LISTED
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "a plugin selects the suite naming it"
  assert_contains "$listed" "tests/fm-daemon.test.sh" "a plugin selects a suite naming the plugin directory"
  assert_not_contains "$listed" "tests/fm-pi-watch-extension.test.sh" \
    "a plugin selected a family-mate of a plugin suite"
  commit_fixture_setup "$repo" plugin-change

  printf '\n' >>"$repo/.opencode/plugins/lib/fm-demo-shared.js"
  changed_listing "$repo" "a plugin lib change"
  listed=$LISTED
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "a plugin lib selects the plugin suites"
  commit_fixture_setup "$repo" plugin-lib-change

  printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/fm-daemon.test.sh"
  commit_fixture_setup "$repo" plugin-suites-gone
  printf '\n' >>"$repo/.opencode/plugins/fm-primary-demo-check.js"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a plugin no suite names must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: .opencode/plugins/fm-primary-demo-check.js' "$tmp/err" \
    || fail "the plugin refusal did not name the plugin: $(cat "$tmp/err")"

  rm -rf "$tmp"
  pass "a plugin or plugin lib selects the plugin suites, and an unread plugin refuses"
}

# An unmapped bin/ file reaches tests through consumers of any language and any
# depth: a shell helper named by a Python module, imported by another module,
# imported by a client script that a curated watcher runs. Python modules count
# as named by their import, and a fixture or Python test helper importing a
# module selects the suites that read it. A file nothing reaches still refuses,
# an import cycle with no reader ends in that refusal, and so does a scan that
# cannot read a file.
test_changed_bin_walk_follows_python_imports_to_any_depth() {
  local tmp repo listed rc path
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-walk.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  : >"$repo/bin/fm-zview-adapter.sh"
  printf 'ADAPTER = HERE / "fm-zview-adapter.sh"\n' >"$repo/bin/fm_zview_crew.py"
  printf 'import fm_zview_crew\n' >"$repo/bin/fm_zview_engine.py"
  printf 'from fm_zview_engine import run\n' >"$repo/bin/fm-zview-client.py"
  # shellcheck disable=SC2016  # literal fixture text the scan must find verbatim
  printf 'python3 "$ROOT/bin/fm-zview-client.py"\n' >>"$repo/bin/fm-watch-probe.sh"
  : >"$repo/bin/fm_zfixture_only.py"
  mkdir -p "$repo/tests/fixtures/zviews"
  printf 'import fm_zfixture_only\n' >"$repo/tests/fixtures/zviews/check.py"
  printf '# tests/fixtures/zviews\n' >>"$repo/tests/fm-session-start.test.sh"
  : >"$repo/bin/fm_zhelper_only.py"
  printf 'from fm_zhelper_only import cases\n' >"$repo/tests/zcases.py"
  printf '# zcases.py\n' >>"$repo/tests/fm-pr-merge.test.sh"
  : >"$repo/bin/fm_zorphan.py"
  printf 'import fm_zloop_b\n' >"$repo/bin/fm_zloop_a.py"
  printf 'import fm_zloop_a\n' >"$repo/bin/fm_zloop_b.py"
  commit_fixture_setup "$repo" walk-setup

  printf '\n' >>"$repo/bin/fm-zview-adapter.sh"
  changed_listing "$repo" "a helper four consumers from a curated script"
  listed=$LISTED
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "the walk must reach the curated watcher four consumers away"
  commit_fixture_setup "$repo" adapter-change

  printf '\n' >>"$repo/bin/fm_zview_crew.py"
  changed_listing "$repo" "an imported Python module"
  listed=$LISTED
  assert_contains "$listed" "tests/fm-daemon.test.sh" \
    "a module must reach the curated watcher through its importers"
  commit_fixture_setup "$repo" module-change

  printf '\n' >>"$repo/bin/fm_zfixture_only.py"
  changed_listing "$repo" "a module a fixture imports"
  listed=$LISTED
  [ "$listed" = "tests/fm-session-start.test.sh" ] \
    || fail "a module a fixture imports must select exactly the fixture's reader, got: $listed"
  commit_fixture_setup "$repo" fixture-module-change

  printf '\n' >>"$repo/bin/fm_zhelper_only.py"
  changed_listing "$repo" "a module a Python test helper imports"
  listed=$LISTED
  [ "$listed" = "tests/fm-pr-merge.test.sh" ] \
    || fail "a module a Python test helper imports must select exactly the helper's reader, got: $listed"
  commit_fixture_setup "$repo" helper-module-change

  for path in bin/fm_zorphan.py bin/fm_zloop_a.py; do
    printf '\n' >>"$repo/$path"
    set +e
    (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "$path reaches no test and must fail with exit 2, got $rc"
    grep -Fq "no changed-test mapping for source path: $path" "$tmp/err" \
      || fail "the refusal did not name $path: $(cat "$tmp/err")"
    git -C "$repo" checkout -q -- "$path"
  done

  # A bin file the scan cannot read is a failed reading, never "nothing names
  # it". The file is git-ignored so only the scan meets it, not the diff.
  printf 'bin/fm-zunreadable.sh\n' >"$repo/.gitignore"
  commit_fixture_setup "$repo" ignore-unreadable
  : >"$repo/bin/fm-zunreadable.sh"
  chmod 000 "$repo/bin/fm-zunreadable.sh"
  if [ -r "$repo/bin/fm-zunreadable.sh" ]; then
    echo "# skip: mode 000 stays readable for this user, so the unreadable-scan case cannot run"
  else
    printf '\n' >>"$repo/bin/fm_zview_crew.py"
    set +e
    (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "a bin file the scan cannot read must fail with exit 2, got $rc: $(cat "$tmp/out")"
    grep -Fq 'reference scan failed' "$tmp/err" \
      || fail "the failed scan was not reported: $(cat "$tmp/err")"
    grep -Fq 'no changed-test mapping for source path: bin/fm_zview_crew.py' "$tmp/err" \
      || fail "the failed scan did not refuse the changed path: $(cat "$tmp/err")"
  fi
  chmod 600 "$repo/bin/fm-zunreadable.sh"

  rm -rf "$tmp"
  pass "the bin walk follows Python imports, fixtures and helpers to any depth, and an unreached or unreadable file refuses"
}

# Exercise begin/end markers from real fixture processes to prove the automatic
# changed-suite default and its explicit serial override.
test_changed_uses_bounded_automatic_concurrency() {
  local tmp repo script serial_shape parallel_shape timeout_repo timeout_script expected_jobs rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed-consent.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  for script in fm-backend-herdr-smoke.test.sh fm-daemon.test.sh fm-pi-watch-extension.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
echo "ok - concurrency consent fixture"
SH
    chmod +x "$repo/tests/$script"
  done
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures
  printf '\n' >>"$repo/bin/shared-probe-lib.sh"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/parallel.json") \
    >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default changed fixture run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "plain --changed did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --jobs 1 --json "$tmp/serial.json") \
    >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial changed fixture run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force serial execution: $serial_shape"
  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PY' \
    || fail "changed timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PY

  timeout_repo="$tmp/timeout-repo"
  timeout_script=tests/fm-calm-pi-extension.test.sh
  mkdir -p "$timeout_repo/bin" "$timeout_repo/tests"
  cp "$RUNNER" "$timeout_repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$timeout_repo/tests/"
  cat >"$timeout_repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  [ "$1" -eq 1500 ] || return 99
  return 124
}
SH
  cat >"$timeout_repo/$timeout_script" <<'SH'
#!/usr/bin/env bash
touch should-not-run
echo "not ok - automatic timeout helper was bypassed"
SH
  chmod +x "$timeout_repo/bin/fm-test-run.sh" "$timeout_repo/$timeout_script"
  git -C "$timeout_repo" init -q
  git -C "$timeout_repo" add .
  git -C "$timeout_repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$timeout_repo/$timeout_script"
  set +e
  (cd "$timeout_repo" && bin/fm-test-run.sh --changed --base HEAD) \
    >"$tmp/timeout.out" 2>"$tmp/timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "single-script automatic timeout must fail the run, got $rc"
  grep -Eq '^FM_TEST_END .+ tests/fm-calm-pi-extension\.test\.sh exit=124 ' "$tmp/timeout.out" \
    || fail "single unproven changed script did not receive the automatic timeout: $(cat "$tmp/timeout.out")"
  [ ! -e "$timeout_repo/should-not-run" ] || fail "automatic timeout helper did not own the single changed script"

  rm -rf "$tmp"
  pass "changed defaults to bounded automatic scheduling with serial override"
}

test_windows_posix_mode_emulation_does_not_fail_parallel_runs() {
  local tmp repo fakebin real_stat out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-windows-modes.XXXXXX")
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  real_stat=$(command -v stat)
  init_changed_fixture_repo "$repo"
  mkdir -p "$fakebin"
  cat >"$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME:-MINGW64_NT-10.0}"
SH
  cat >"$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %a ]; then
  printf '%s\n' 755
  exit 0
fi
exec "$REAL_STAT" "$@"
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-dod-lib.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "native-Windows POSIX-mode emulation"
  assert_contains "$out" "FM_TEST_SUMMARY total=2 failed=0" \
    "Windows mode emulation did not complete both parallel scripts"

  set +e
  out=$(cd "$repo" && PATH="$fakebin:$PATH" REAL_STAT="$real_stat" FAKE_UNAME=CYGWIN_NT-10.0 \
    bin/fm-test-run.sh --jobs 2 \
      tests/fm-cd-pretool-check.test.sh tests/fm-dod-lib.test.sh 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "Cygwin POSIX-mode enforcement"
  assert_contains "$out" "isolation failure: worker root mode is 755, expected 0700" \
    "Cygwin mode enforcement did not reject a non-0700 worker root"
  rm -rf "$tmp"
  pass "Windows emulation exempts only synthetic POSIX modes"
}

# A local verification round names the subjects it cares about. Exercise begin/end
# markers from real fixture processes to prove that a plain list of script paths
# gets bounded automatic scheduling without changing its per-script timeout
# contract, so verifying several subjects is one bounded concurrent run rather
# than a serial chain of separate `bash tests/X.test.sh` invocations.
test_script_list_uses_bounded_automatic_concurrency() {
  local tmp repo script parallel_shape serial_shape mixed_shape expected_jobs
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-script-list.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  rm -f "$repo/bin/fm-timeout-lib.sh"
  # fm-cd-pretool-check and fm-pr-merge are individually proven isolated;
  # fm-backend-orca is not, so it must still land in the serial tail.
  for script in fm-cd-pretool-check.test.sh fm-pr-merge.test.sh fm-backend-orca.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
echo "ok - script-list concurrency fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --json "$tmp/parallel.json") >"$tmp/parallel.out" 2>"$tmp/parallel.err" \
    || fail "default script-list run failed: $(cat "$tmp/parallel.err")"
  parallel_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/parallel.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$parallel_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN ] \
    || fail "a plain script list did not use bounded concurrent scheduling: $parallel_shape"

  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      --jobs 1 --json "$tmp/serial.json") >"$tmp/serial.out" 2>"$tmp/serial.err" \
    || fail "explicit serial script-list run failed: $(cat "$tmp/serial.err")"
  serial_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/serial.out" | head -n 2 | awk '{print $1}' | paste -sd, -)
  [ "$serial_shape" = FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "explicit --jobs 1 did not force a serial script list: $serial_shape"

  # An unproven script in the list is scheduled around, never refused and never
  # run beside another script.
  (cd "$repo" && bin/fm-test-run.sh tests/fm-cd-pretool-check.test.sh tests/fm-pr-merge.test.sh \
      tests/fm-backend-orca.test.sh) >"$tmp/mixed.out" 2>"$tmp/mixed.err" \
    || fail "mixed proven/unproven script list failed: $(cat "$tmp/mixed.err")"
  mixed_shape=$(grep -E '^FM_TEST_(BEGIN|END)' "$tmp/mixed.out" | awk '{print $1}' | paste -sd, -)
  [ "$mixed_shape" = FM_TEST_BEGIN,FM_TEST_BEGIN,FM_TEST_END,FM_TEST_END,FM_TEST_BEGIN,FM_TEST_END ] \
    || fail "an unproven script was not kept in the serial tail: $mixed_shape"

  expected_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$expected_jobs" in
    ''|*[!0-9]*) expected_jobs=1 ;;
  esac
  [ "$expected_jobs" -le 4 ] || expected_jobs=4
  [ "$expected_jobs" -ge 1 ] || expected_jobs=1
  python3 - "$tmp/parallel.json" "$tmp/serial.json" "$expected_jobs" <<'PYJSON' \
    || fail "script-list timing artifacts did not record their resolved worker counts"
import json, sys
automatic = json.load(open(sys.argv[1], encoding="utf-8"))
serial = json.load(open(sys.argv[2], encoding="utf-8"))
expected = int(sys.argv[3])
assert automatic["selection"].split(";")[-1] == f"jobs={expected}"
assert serial["selection"].split(";")[-1] == "jobs=1"
PYJSON

  (cd "$repo" && bin/fm-test-run.sh tests/fm-backend-orca.test.sh) \
    >"$tmp/named.out" 2>"$tmp/named.err" \
    || fail "a named script unexpectedly required a timeout helper: $(cat "$tmp/named.err")"
  grep -Eq '^FM_TEST_END .+ tests/fm-backend-orca\.test\.sh exit=0 ' "$tmp/named.out" \
    || fail "a named script did not run without an automatic bound: $(cat "$tmp/named.out")"

  rm -rf "$tmp"
  pass "a plain script list defaults to bounded automatic concurrency without an automatic timeout"
}

test_family_proofs_run_in_separate_concurrent_phases() {
  local tmp repo script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-family-phases.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-calm-pi-extension.test.sh fm-vendor-auth-probe.test.sh \
    fm-pr-check-security.test.sh fm-teardown.test.sh; do
    cat >"$repo/tests/$script" <<'SH'
#!/usr/bin/env bash
echo "ok - family phase fixture"
SH
    chmod +x "$repo/tests/$script"
  done

  (cd "$repo" && bin/fm-test-run.sh \
      tests/fm-pr-check-security.test.sh tests/fm-calm-pi-extension.test.sh \
      tests/fm-teardown.test.sh tests/fm-vendor-auth-probe.test.sh --jobs 4) \
    >"$tmp/out" 2>"$tmp/err" \
    || fail "cross-family phase fixture failed: $(cat "$tmp/err")"

  python3 - "$tmp/out" <<'PY' \
    || fail "family-proof scripts from different families overlapped: $(cat "$tmp/out")"
import re, sys
active = {}
overlap = {"pure-contract-unit": False, "pr-forge": False}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("FM_TEST_BEGIN "):
        match = re.search(r" (tests/\S+) family=(\S+) ", line)
        assert match, line
        path, family = match.groups()
        assert not active or set(active.values()) == {family}, (active, line)
        active[path] = family
        if sum(value == family for value in active.values()) > 1:
            overlap[family] = True
    elif line.startswith("FM_TEST_END "):
        match = re.search(r" (tests/\S+) exit=", line)
        assert match and match.group(1) in active, (active, line)
        del active[match.group(1)]
assert not active, active
assert all(overlap.values()), overlap
PY

  rm -rf "$tmp"
  pass "family proofs run concurrently only within separate family phases"
}

test_empty_selection_emits_summary() {
  local tmp repo out json rc fake_bin real_git
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  printf '%s\n' "$out" | grep -Eq \
    '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' \
    || fail "empty selection summary is missing or malformed: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"]["total"] == 0
assert doc["summary"]["failed"] == 0
assert doc["summary"]["skipped_gate"] == 0
assert doc["summary"]["duration_ms"] >= 0
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  fake_bin="$tmp/fake-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
if [ ! -e "$SLOW_GIT_MARKER" ]; then
  : >"$SLOW_GIT_MARKER"
  sleep 0.3
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$fake_bin/git"
  set +e
  (cd "$repo" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" SLOW_GIT_MARKER="$tmp/slow-git" \
    bin/fm-test-run.sh --changed --base HEAD --max-wall-ms 100) \
    >"$tmp/slow-selection.out" 2>"$tmp/slow-selection.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an empty run past its budget must fail normally, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its summary"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=100 duration_ms=[0-9]+$' "$tmp/slow-selection.out" \
    || fail "over-budget empty selection omitted its budget result"
  [ -e "$tmp/slow-git" ] || fail "the slow selection fixture did not run"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --max-wall-ms nope) \
    >"$tmp/bad-budget.out" 2>"$tmp/bad-budget.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed budget on an empty selection must be refused, got $rc"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --per-script-timeout-secs nope) \
    >"$tmp/bad-timeout.out" 2>"$tmp/bad-timeout.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed timeout on an empty selection must be refused, got $rc"
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_gate_skip_reason_is_recorded() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skipreason.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: live: fmnosuchharness absent"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "a capability skip must still exit 0 from the runner"
  grep -q 'live: fmnosuchharness absent' "$tmp/err.txt" \
    || fail "the runner log must name what this host could not exercise: $(cat "$tmp/err.txt")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"] == "live: fmnosuchharness absent", record
' "$json" || { rm -rf "$tmp"; fail "the timing artifact must carry the skip reason"; }
  rm -rf "$tmp"
  pass "a gate skip records why it skipped"
}

test_a_run_that_ran_records_no_skip_reason() {
  local tmp ran_f json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-ranreason.XXXXXX")
  ran_f="$tmp/ran.test.sh"
  json="$tmp/timing.json"
  cat >"$ran_f" <<'SH'
#!/usr/bin/env bash
echo "ok - ran"
exit 0
SH
  chmod +x "$ran_f"
  "$RUNNER" --json "$json" "$ran_f" >"$tmp/out.txt" 2>&1 \
    || fail "a passing fixture must exit 0 from the runner"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["gate_skip"] is False, record
assert record["gate_skip_reason"] == "", record
' "$json" || { rm -rf "$tmp"; fail "a script that ran must carry an empty skip reason"; }
  rm -rf "$tmp"
  pass "a script that actually ran records no skip reason"
}

test_live_guards_expect_a_capability_skip_class() {
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-liveclass.XXXXXX")
  out="$tmp/out.txt"
  # FM_LIVE=0 makes every live guard refuse without touching a harness, so this
  # exercises the real family through the real runner in bounded time.
  FM_LIVE=0 "$RUNNER" --json "$tmp/timing.json" \
    tests/fm-composer-matrix-live-e2e.test.sh >"$out" 2>"$tmp/err.txt" \
    || fail "a disabled live guard must not fail the runner: $(cat "$tmp/err.txt")"
  grep -q 'expected_gate_skip=live-capability' "$out" \
    || fail "the live-harness family must expect a capability skip: $(grep FM_TEST_BEGIN "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
record = doc["scripts"][0]
assert record["expected_gate_skip"] == "live-capability", record
assert record["gate_skip"] is True, record
assert record["gate_skip_reason"].startswith("live: "), record
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "the live guard record is wrong"; }
  rm -rf "$tmp"
  pass "live guards are recorded as a capability class, not a bare env opt-in"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_list_scheduled_proven_isolated_uses_path_order_without_timing() {
  local tmp
  tmp=$(fm_test_tmproot fm-test-run-proven-schedule)
  "$RUNNER" --list --proven-isolated | LC_ALL=C sort >"$tmp/expected"
  "$RUNNER" --list-scheduled --proven-isolated >"$tmp/actual" \
    || fail "--list-scheduled --proven-isolated failed"
  cmp -s "$tmp/expected" "$tmp/actual" \
    || fail "with no --timing every script weighs 0, so ties must break by path"
  pass "scheduling without --timing is path order"
}

# write_timing <file> <path>=<ms>...: a minimal timing JSON as --json writes it.
write_timing() {
  local out=$1
  shift
  python3 - "$out" "$@" <<'PY'
import json, sys
rows = []
for arg in sys.argv[2:]:
    path, _, ms = arg.partition("=")
    rows.append({"path": path, "duration_ms": int(ms)})
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"scripts": rows}, fh)
PY
}

test_list_scheduled_orders_by_timing() {
  local tmp repo selection
  tmp=$(fm_test_tmproot fm-test-run-timing-schedule)
  repo="$tmp/repo"
  init_stub_suite_repo "$repo" fm-a.test.sh fm-b.test.sh fm-c.test.sh fm-d.test.sh
  # Two records for one path keep the larger, as an aggregate of shards would.
  write_timing "$tmp/timing.json" tests/fm-b.test.sh=500 tests/fm-a.test.sh=100 \
    tests/fm-a.test.sh=900 tests/fm-d.test.sh=300
  printf '%s\n' tests/fm-a.test.sh tests/fm-b.test.sh tests/fm-d.test.sh \
    tests/fm-c.test.sh >"$tmp/expected"
  for selection in all scripts; do
    case "$selection" in
      all) set -- --all ;;
      scripts) set -- tests/fm-c.test.sh tests/fm-d.test.sh tests/fm-a.test.sh tests/fm-b.test.sh ;;
    esac
    (cd "$repo" && bin/fm-test-run.sh --list-scheduled --timing "$tmp/timing.json" "$@") >"$tmp/actual" \
      || fail "--list-scheduled $selection failed"
    cmp -s "$tmp/expected" "$tmp/actual" \
      || fail "$selection scheduling must run longest measured first and unmeasured last: $(cat "$tmp/actual")"
  done
  pass "--list-scheduled orders by the --timing durations"
}

# init_tier_repo <repo> <tier>=<basename>...: a stub suite plus its tier map.
init_tier_repo() {
  local repo=$1 arg
  shift
  local -a names=()
  for arg in "$@"; do names+=("${arg#*=}"); done
  init_stub_suite_repo "$repo" "${names[@]}"
  printf '# fixture tier map\n' >"$repo/tests/tiers.list"
  for arg in "$@"; do
    printf '%s tests/%s\n' "${arg%%=*}" "${arg#*=}" >>"$repo/tests/tiers.list"
  done
}

test_tier_selection_and_filter() {
  local tmp repo out rc
  tmp=$(fm_test_tmproot fm-test-run-tiers)
  repo="$tmp/repo"
  init_tier_repo "$repo" gate=fm-a.test.sh full=fm-b.test.sh weekly=fm-c.test.sh live=fm-d.test.sh
  out=$(cd "$repo" && bin/fm-test-run.sh --list --tier gate) || fail "--tier gate failed"
  [ "$out" = tests/fm-a.test.sh ] || fail "--tier gate must select only the gate entry: $out"
  out=$(cd "$repo" && bin/fm-test-run.sh --list --tier full,gate) || fail "--tier full,gate failed"
  [ "$out" = "$(printf '%s\n' tests/fm-a.test.sh tests/fm-b.test.sh)" ] \
    || fail "a tier list must select the union of its tiers: $out"
  out=$(cd "$repo" && bin/fm-test-run.sh --list-tiers) || fail "--list-tiers failed"
  assert_contains "$out" "weekly tests/fm-c.test.sh" "--list-tiers prints the map"
  assert_not_contains "$out" "#" "--list-tiers drops comments"

  out=$(cd "$repo" && bin/fm-test-run.sh --list --tier full tests/fm-a.test.sh tests/fm-b.test.sh 2>"$tmp/err") \
    || fail "--tier as a filter failed"
  [ "$out" = tests/fm-b.test.sh ] || fail "--tier with script paths must keep only that tier: $out"
  grep -Fq 'tier filter: dropping tests/fm-a.test.sh' "$tmp/err" \
    || fail "the tier filter must log what it drops: $(cat "$tmp/err")"

  out=$(cd "$repo" && bin/fm-test-run.sh --list --tier nightly 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown tier must refuse"
  assert_contains "$out" "unknown tier: nightly" "the refusal names the tier"
  pass "--tier selects by tier, filters other selections, and refuses unknown tiers"
}

# Every tier the CI workflow runs is a real slice of the checkout: the tiers
# are disjoint, together they are the whole suite, and the gate every push runs
# carries every safety-core test.
test_tiers_partition_the_suite_and_gate_holds_the_core() {
  local all union gate t listed dups core missing
  all=$("$RUNNER" --list --all | LC_ALL=C sort)
  union=""
  for t in static gate full weekly live; do
    listed=$("$RUNNER" --list --tier "$t") || fail "--list --tier $t failed"
    [ -n "$listed" ] || fail "tier $t selected nothing"
    union=$(printf '%s\n%s' "$union" "$listed")
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' | LC_ALL=C sort)
  dups=$(printf '%s\n' "$union" | uniq -d)
  [ -z "$dups" ] || fail "scripts in more than one tier: $dups"
  [ "$union" = "$all" ] || fail "the tiers together must equal --all"
  gate=$("$RUNNER" --list --tier gate)
  core=$(sed 's/#.*//' "$ROOT/tests/safety-core.list" | awk 'NF { print $1 }' | LC_ALL=C sort -u)
  missing=$(comm -23 <(printf '%s\n' "$core") <(printf '%s\n' "$gate" | LC_ALL=C sort -u) || true)
  [ -z "$missing" ] || fail "safety-core tests outside the gate tier: $missing"
  pass "the tiers partition the suite and the gate selects all $(printf '%s\n' "$core" | wc -l | tr -d ' ') core tests"
}

test_shards_partition_a_tier() {
  local n=3 k listed union gate dups again
  gate=$("$RUNNER" --list --tier gate | LC_ALL=C sort)
  union=""
  for k in 1 2 3; do
    listed=$("$RUNNER" --list --tier gate --shard "$k/$n" 2>/dev/null) || fail "--shard $k/$n failed"
    [ -n "$listed" ] || fail "gate shard $k/$n selected nothing"
    union=$(printf '%s\n%s' "$union" "$listed")
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' | LC_ALL=C sort)
  dups=$(printf '%s\n' "$union" | uniq -d)
  [ -z "$dups" ] || fail "gate shards run the same script twice: $dups"
  [ "$union" = "$gate" ] || fail "gate shards must together equal the gate tier"
  again=$("$RUNNER" --list --tier gate --shard 1/3 2>/dev/null)
  [ "$again" = "$("$RUNNER" --list --tier gate --shard 1/3 2>/dev/null)" ] \
    || fail "shard membership must be deterministic"
  pass "--shard k/n is a deterministic disjoint cover of its selection"
}

test_shard_packs_by_timing() {
  local tmp repo out err rc bad
  tmp=$(fm_test_tmproot fm-test-run-shard-pack)
  repo="$tmp/repo"
  init_tier_repo "$repo" gate=fm-a.test.sh gate=fm-b.test.sh gate=fm-c.test.sh gate=fm-d.test.sh
  # fm-d is unmeasured and weighs the median of 900, 500 and 400. Longest
  # first: a(900)->1, b(500)->2, d(500)->2, c(400)->1.
  write_timing "$tmp/timing.json" tests/fm-a.test.sh=900 tests/fm-b.test.sh=500 tests/fm-c.test.sh=400
  out=$(cd "$repo" && bin/fm-test-run.sh --list --tier gate --shard 1/2 --timing "$tmp/timing.json" 2>"$tmp/err1") \
    || fail "shard 1/2 failed: $(cat "$tmp/err1")"
  [ "$out" = "$(printf '%s\n' tests/fm-a.test.sh tests/fm-c.test.sh)" ] || fail "shard 1/2 packed wrong: $out"
  grep -Fxq 'FM_TEST_SHARD shard=1/2 scripts=2 modeled_ms=1300 max_modeled_ms=1300 unmeasured=0' "$tmp/err1" \
    || fail "shard 1/2 marker wrong: $(cat "$tmp/err1")"
  out=$(cd "$repo" && bin/fm-test-run.sh --list --tier gate --shard 2/2 --timing "$tmp/timing.json" 2>"$tmp/err2") \
    || fail "shard 2/2 failed: $(cat "$tmp/err2")"
  [ "$out" = "$(printf '%s\n' tests/fm-b.test.sh tests/fm-d.test.sh)" ] || fail "shard 2/2 packed wrong: $out"
  grep -Fxq 'FM_TEST_SHARD shard=2/2 scripts=2 modeled_ms=1000 max_modeled_ms=1300 unmeasured=1' "$tmp/err2" \
    || fail "shard 2/2 marker wrong: $(cat "$tmp/err2")"

  # A proven-isolated script shares a concurrent phase, so it weighs its
  # duration divided by --jobs: alone on shard 1 when serial, a light extra
  # beside fm-b at four workers.
  init_tier_repo "$tmp/proven" gate=fm-brief.test.sh gate=fm-a.test.sh gate=fm-b.test.sh
  write_timing "$tmp/proven.json" tests/fm-brief.test.sh=1000 tests/fm-a.test.sh=600 tests/fm-b.test.sh=500
  out=$(cd "$tmp/proven" && bin/fm-test-run.sh --list --tier gate --shard 1/2 --timing "$tmp/proven.json" 2>/dev/null)
  [ "$out" = tests/fm-brief.test.sh ] || fail "a serial run must weigh the proven script in full: $out"
  out=$(cd "$tmp/proven" && bin/fm-test-run.sh --list --tier gate --jobs 4 --shard 2/2 --timing "$tmp/proven.json" 2>/dev/null)
  [ "$out" = "$(printf '%s\n' tests/fm-b.test.sh tests/fm-brief.test.sh)" ] \
    || fail "--jobs 4 must divide the proven script's weight: $out"

  for bad in 0/2 3/2 2 a/2 1/0; do
    err=$(cd "$repo" && bin/fm-test-run.sh --list --tier gate --shard "$bad" 2>&1 >/dev/null) && rc=0 || rc=$?
    expect_code 2 "$rc" "--shard $bad must refuse"
    assert_contains "$err" "--shard requires" "--shard $bad refusal explains the form"
  done
  pass "--shard packs longest measured first, weighs the unmeasured at the median, and refuses bad forms"
}

test_coverage_guard_reports_and_refuses() {
  local tmp repo out rc total sum t n
  load_coverage
  assert_contains "$COVERAGE_OUT" "FM_TEST_COVERAGE ok total=" "coverage guard success marker"
  total=$(printf '%s\n' "$COVERAGE_OUT" | sed -n 's/.* total=\([0-9][0-9]*\).*/\1/p')
  sum=0
  for t in static gate full weekly live; do
    n=$(printf '%s\n' "$COVERAGE_OUT" | sed -n "s/.* $t=\\([0-9][0-9]*\\).*/\\1/p")
    [ -n "$n" ] || fail "coverage guard must report a $t count: $COVERAGE_OUT"
    sum=$((sum + n))
  done
  [ "$sum" = "$total" ] || fail "tier counts ($sum) must add up to the total ($total)"

  tmp=$(fm_test_tmproot fm-test-run-coverage)
  repo="$tmp/repo"
  init_tier_repo "$repo" gate=fm-a.test.sh full=fm-b.test.sh
  out=$(cd "$repo" && bin/fm-test-run.sh --check-coverage 2>&1) || fail "a complete fixture map must pass: $out"
  assert_contains "$out" "FM_TEST_COVERAGE ok total=2 static=0 gate=1 full=1 weekly=0 live=0" \
    "fixture coverage counts"

  printf 'weekly tests/fm-a.test.sh\n' >>"$repo/tests/tiers.list"
  out=$(cd "$repo" && bin/fm-test-run.sh --check-coverage 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a test in two tiers must fail coverage"
  assert_contains "$out" "listed more than once:" "duplicate is reported"

  printf 'gate tests/fm-a.test.sh\n' >"$repo/tests/tiers.list"
  out=$(cd "$repo" && bin/fm-test-run.sh --check-coverage 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a test with no tier must fail coverage"
  assert_contains "$out" "tests/fm-b.test.sh" "the untiered test is named"

  printf 'gate tests/fm-a.test.sh\nfull tests/fm-b.test.sh\nfull tests/fm-gone.test.sh\n' >"$repo/tests/tiers.list"
  out=$(cd "$repo" && bin/fm-test-run.sh --check-coverage 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a map entry with no test file must fail coverage"
  assert_contains "$out" "tests/fm-gone.test.sh" "the stale entry is named"

  printf 'gate tests/fm-a.test.sh\nnightly tests/fm-b.test.sh\n' >"$repo/tests/tiers.list"
  out=$(cd "$repo" && bin/fm-test-run.sh --check-coverage 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "an unknown tier must fail coverage"
  assert_contains "$out" "nightly tests/fm-b.test.sh" "the bad line is shown"
  pass "coverage guard counts every tier and refuses duplicate, missing, stale, and unknown entries"
}

test_jobs_requires_proven_isolated() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 tests/fm-board.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on a family with no recorded proof must refuse, got $rc"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

# Under --tier, --jobs overlaps only the proven-isolated set and still runs
# every other script alone after that phase, family proofs included.
test_tier_jobs_overlap_only_proven_scripts() {
  local tmp repo rc out first_tail last_proven s b e other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-tier-jobs.XXXXXX")
  repo="$tmp/repo"
  # Two proven-isolated stand-ins, one pure-contract-unit member (a family
  # proof that a --tier run does not use), and one script with no proof.
  init_tier_repo "$repo" gate=fm-brief.test.sh gate=fm-lint.test.sh \
    gate=fm-documentation-audiences.test.sh gate=fm-board.test.sh
  # Leave an owner-read-only directory in the worker TMPDIR, as a secondmate's
  # locked git-hooks do; removing the run's scratch must not fail a green run.
  # shellcheck disable=SC2016 # expanded by the stand-in, not here
  printf '%s\n' 'mkdir -p "${TMPDIR:?}/locked-hooks" && : >"$TMPDIR/locked-hooks/pre-push" && chmod a-w "$TMPDIR/locked-hooks"' \
    >>"$repo/tests/fm-brief.test.sh"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 --tier gate) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  out=$(cat "$tmp/out")
  [ "$rc" -eq 0 ] || fail "--jobs on a tier must be admitted, got $rc: $(cat "$tmp/err") $out"
  grep -Fq 'FM_TEST_SUMMARY total=4 failed=0' "$tmp/out" \
    || fail "the tier did not run all four scripts green: $out"
  last_proven=$(grep -nE '^FM_TEST_END .*(fm-brief|fm-lint)\.test' "$tmp/out" | tail -1 | cut -d: -f1)
  first_tail=$(grep -nE '^FM_TEST_BEGIN .*(fm-documentation-audiences|fm-board)' "$tmp/out" | head -1 | cut -d: -f1)
  [ -n "$first_tail" ] && [ -n "$last_proven" ] && [ "$first_tail" -gt "$last_proven" ] \
    || fail "an unproven script did not wait for the proven phase: $out"
  for s in fm-documentation-audiences fm-board; do
    b=$(grep -n "^FM_TEST_BEGIN .*$s" "$tmp/out" | cut -d: -f1)
    e=$(grep -n "^FM_TEST_END .*$s" "$tmp/out" | cut -d: -f1)
    other=$(sed -n "$((b + 1)),$((e - 1))p" "$tmp/out" | grep -c '^FM_TEST_BEGIN' || true)
    [ "$other" -eq 0 ] || fail "$s overlapped another script under --tier: $out"
  done
  rm -rf "$tmp"
  pass "--jobs under --tier overlaps only proven-isolated scripts and keeps the rest serial"
}

# The complement of the refusal above: a family carrying a recorded concurrent
# proof is admitted and actually scheduled, so the admission rule is two-sided
# rather than a blanket refusal that happens to pass its negative cases.
# init_stub_suite_repo <repo> <script-basename>...: a private copy of the runner
# beside instant stand-ins named like real suites. Family membership, proofs,
# and the proven-isolated set are keyed by path, so the copy schedules the stand-ins
# exactly as it would the real suites without paying for their bodies.
init_stub_suite_repo() {
  local repo=$1 script
  shift
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in "$@"; do
    printf '#!/usr/bin/env bash\necho "ok - %s stand-in"\n' "$script" >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
}

test_jobs_admits_a_concurrent_safe_family() {
  local tmp repo rc external
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-admit.XXXXXX")
  repo="$tmp/repo"
  init_stub_suite_repo "$repo" fm-supervision-events.test.sh fm-session-lock-ancestry.test.sh
  # --list exits before the admission guard, so this has to be a real run for
  # the assertion to mean anything. Two watcher-wake-lock stand-ins exercise
  # admission and the concurrent scheduler for real.
  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-supervision-events.test.sh tests/fm-session-lock-ancestry.test.sh) \
    >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--jobs on a proven family must be admitted, got $rc: $(cat "$tmp/err") $(cat "$tmp/out")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/out" \
    || fail "the admitted concurrent run did not report both scripts green: $(cat "$tmp/out")"

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 5 tests/fm-session-lock-ancestry.test.sh) \
    >"$tmp/over-cap.out" 2>"$tmp/over-cap.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a family run above its proven four-worker cap must be refused, got $rc"

  external="$tmp/fm-session-lock-ancestry.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - colliding external fixture"\n' >"$external"
  chmod +x "$external"
  set +e
  "$repo/bin/fm-test-run.sh" --jobs 2 "$external" >"$tmp/external.out" 2>"$tmp/external.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an external script colliding with a proven family member must be refused, got $rc"
  rm -rf "$tmp"
  pass "--jobs admits and schedules a family with a recorded concurrent proof"
}

# The residual `standalone` family carries a concurrent proof, but the `*)`
# catch-all it was split out of must not: a test nobody has classified yet is
# exactly the one with no proof, so it has to stay serial rather than inherit
# concurrency from the family map's default arm.
test_unmapped_new_test_never_inherits_family_concurrency() {
  local tmp repo rc script
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-unmapped.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh"
  # Two members of the proven residual family, plus a test basename the family
  # map has never seen - the shape of any test added tomorrow.
  for script in fm-procevent.test.sh fm-quota-choose.test.sh fm-zz-unmapped-fixture.test.sh; do
    printf '#!/usr/bin/env bash\necho "ok - %s fixture"\n' "$script" >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-quota-choose.test.sh) \
    >"$tmp/family.out" 2>"$tmp/family.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "two members of the proven residual family must be admitted, got $rc: $(cat "$tmp/family.err")"
  grep -Fq 'FM_TEST_SUMMARY total=2 failed=0' "$tmp/family.out" \
    || fail "the admitted residual-family run did not report both scripts green: $(cat "$tmp/family.out")"

  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 \
    tests/fm-procevent.test.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/unmapped.out" 2>"$tmp/unmapped.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] \
    || fail "an unclassified new test must not be admitted under --jobs, got $rc: $(cat "$tmp/unmapped.out")"
  grep -Fq 'fm-zz-unmapped-fixture.test.sh' "$tmp/unmapped.err" \
    || fail "the refusal did not name the unclassified script: $(cat "$tmp/unmapped.err")"

  # It is only concurrency that is refused: the same script still runs serially.
  set +e
  (cd "$repo" && bin/fm-test-run.sh tests/fm-zz-unmapped-fixture.test.sh) \
    >"$tmp/serial.out" 2>"$tmp/serial.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "an unclassified test must still run serially, got $rc: $(cat "$tmp/serial.err")"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$tmp/serial.out" \
    || fail "the unmapped fixture did not land in the catch-all family: $(cat "$tmp/serial.out")"
  rm -rf "$tmp"
  pass "an unclassified new test stays serial while the proven residual family runs concurrently"
}

test_changed_shared_fixture_selects_its_readers() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fixture.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/shared-probe-fixture.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" \
    "shared test fixture selects its pr-forge reader"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" \
    "shared test fixture selects its secondmate reader"
  case "$listed" in
    *fm-backend-orca.test.sh*)
      fail "shared test fixture selection widened past its readers: $listed" ;;
  esac
  git -C "$repo" add tests/shared-probe-fixture.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture-change

  printf '\n' >>"$repo/tests/unread-thing.sh"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "an unread tests/ path must still fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: tests/unread-thing.sh' "$tmp/err" \
    || fail "the refusal did not name the unread tests/ path: $(cat "$tmp/err")"
  git -C "$repo" checkout -q -- tests/unread-thing.sh

  # A nested tests/fixtures/<dir>/<name>-fixture.sh still reaches the
  # directory-scan arm rather than the top-level fixture arm's basename scan.
  printf '\n' >>"$repo/tests/fixtures/demo/demo-fixture.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-orca.test.sh" \
    "a nested fixture selects the suite that reads its directory"

  rm -rf "$tmp"
  pass "a changed shared test fixture selects its readers while an unread tests/ path still refuses"
}

# Workers are handed scripts in order, so the slowest script must start first or
# it runs alone at the tail and throws away most of the concurrency.
test_concurrent_runs_are_ordered_longest_first() {
  local tmp repo first
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-order.XXXXXX")
  repo="$tmp/repo"
  init_stub_suite_repo "$repo" fm-session-lock-ancestry.test.sh fm-task-inbox.test.sh
  write_timing "$tmp/timing.json" tests/fm-session-lock-ancestry.test.sh=1000 tests/fm-task-inbox.test.sh=90000
  # The scheduler reorders the real run, so assert on the begin-marker order of
  # a real concurrent run over scripts whose measured times differ widely.
  set +e
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 --timing "$tmp/timing.json" \
    tests/fm-session-lock-ancestry.test.sh tests/fm-task-inbox.test.sh) \
    >"$tmp/out" 2>"$tmp/err"
  set -e
  first=$(grep -m1 '^FM_TEST_BEGIN' "$tmp/out" | awk '{print $3}')
  [ "$first" = tests/fm-task-inbox.test.sh ] \
    || fail "concurrent run did not start the longest script first, started: $first"
  rm -rf "$tmp"
  pass "a concurrent run starts the longest measured script first"
}

# --max-wall-ms is checked after the run, so it cannot end a run that never
# finishes. A hung script has to become a bounded failure, because an unbounded
# suite is exactly what silently outruns its caller's invocation budget.
test_per_script_timeout_bounds_a_hang() {
  local tmp repo runner hang rc began ended grandchild_pid grandchild waited
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-hang.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  hang=tests/fm-hang-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/fm-timeout-lib.sh"
  grandchild_pid="$tmp/grandchild.pid"
  cat >"$repo/$hang" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture is about to hang"
sh -c 'trap "" TERM; echo $$ >"$1"; sleep 600' _ "$GRANDCHILD_PID" &
sleep 600
SH
  chmod +x "$runner" "$repo/$hang"

  began=$(date +%s)
  set +e
  GRANDCHILD_PID="$grandchild_pid" \
    "$runner" --per-script-timeout-secs 3 "$hang" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  ended=$(date +%s)

  [ "$rc" -ne 0 ] || fail "a terminated script must fail the run: $(cat "$tmp/out")"
  [ "$((ended - began))" -lt 120 ] \
    || fail "the per-script bound did not stop a 600s hang (took $((ended - began))s)"
  grep -Fq 'exceeded the per-script bound' "$tmp/out" \
    || fail "the terminated script was not named: $(cat "$tmp/out")"
  grep -Eq 'FM_TEST_END .* exit=124 ' "$tmp/out" \
    || fail "a terminated script must be recorded as exit 124: $(cat "$tmp/out")"
  # The run still completes and accounts for the script, rather than dying.
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out" \
    || fail "the bounded run did not report a complete summary: $(cat "$tmp/out")"
  [ -s "$grandchild_pid" ] || fail "the hanging fixture did not record its grandchild"
  grandchild=$(cat "$grandchild_pid")
  waited=0
  while kill -0 "$grandchild" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$grandchild" 2>/dev/null; then
    kill -KILL "$grandchild" 2>/dev/null || true
    fail "the timed-out script left grandchild $grandchild running"
  fi

  # 0 keeps the historical unbounded behavior, so no existing caller changes.
  set +e
  "$runner" --per-script-timeout-secs nope "$hang" >"$tmp/o2" 2>"$tmp/e2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--per-script-timeout-secs with a non-number must be refused, got $rc"

  rm -rf "$tmp"
  pass "--per-script-timeout-secs turns a hung script into a bounded failure"
}

# The duration regression this guard exists for: a suite whose scripts are all
# green but whose wall clock outgrew its caller's invocation budget. The caller
# gets killed mid-run and retries invisibly, so an over-budget run has to be a
# failure, not a note in the log.
# tests/fm-watch-triage.test.sh finishes in about 434s alone and about 698s
# under CI load, so the automatic --changed bound must leave a slow but healthy
# watcher-wake-lock script room while still bounding a genuinely hung one
# (upstream issue #3869). The stub records the bound the runner hands it.
test_changed_bound_gives_slow_watcher_suites_headroom() {
  local tmp repo script bound rc
  tmp=$(mktemp -d)
  repo="$tmp/repo"
  script=tests/fm-watch-triage.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/bin/fm-timeout-lib.sh" <<'SH'
fm_run_timed() {
  printf '%s\n' "$1" >bound-secs
  shift
  "$@"
}
SH
  cat >"$repo/$script" <<'SH'
#!/usr/bin/env bash
echo "ok - healthy but slow watcher suite"
SH
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/$script"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
  printf '\n' >>"$repo/$script"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "healthy changed watcher script must pass, got $rc: $(cat "$tmp/out" "$tmp/err")"
  [ -s "$repo/bound-secs" ] || fail "changed watcher script did not run under the automatic bound: $(cat "$tmp/out")"
  bound=$(cat "$repo/bound-secs")
  [ "$bound" -ge 1500 ] \
    || fail "automatic --changed bound for $script must be at least 1500s, got ${bound}s"
  rm -rf "$tmp"
  pass "the automatic --changed bound gives the slow watcher suite at least 1500s"
}

test_max_wall_ms_is_a_result_not_advice() {
  local tmp repo runner fast rc summary_duration budget_duration
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fast=tests/fm-budget-fixture.test.sh
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$repo/$fast" <<'SH'
#!/usr/bin/env bash
echo "ok - budget fixture"
SH
  chmod +x "$runner" "$repo/$fast"

  # Comfortably inside budget: the run passes and states the budget it met.
  set +e
  "$runner" --max-wall-ms 60000 "$fast" >"$tmp/under" 2>"$tmp/under.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a run inside its budget must pass, got $rc: $(cat "$tmp/under.err")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=60000 duration_ms=[0-9]+$' "$tmp/under" \
    || fail "an inside-budget run did not report the budget: $(cat "$tmp/under")"

  # Same green script, budget it cannot meet: no runner invocation finishes
  # within a millisecond, so the run must FAIL.
  set +e
  "$runner" --max-wall-ms 1 "$fast" >"$tmp/over" 2>"$tmp/over.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an over-budget run must fail through the result path, got $rc"
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SUMMARY_FAMILY .+$' "$tmp/over" \
    || fail "an over-budget run omitted its family summary: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_SLOWEST rank=1 .+$' "$tmp/over" \
    || fail "an over-budget run omitted its slowest result: $(cat "$tmp/over")"
  grep -Eq '^FM_TEST_BUDGET max_wall_ms=1 duration_ms=[0-9]+$' "$tmp/over" \
    || fail "an over-budget run omitted its budget result: $(cat "$tmp/over")"
  summary_duration=$(awk '/^FM_TEST_SUMMARY / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  budget_duration=$(awk '/^FM_TEST_BUDGET / { for (i=1;i<=NF;i++) if ($i ~ /^duration_ms=/) { sub(/^duration_ms=/, "", $i); print $i } }' "$tmp/over")
  [ "$budget_duration" = "$summary_duration" ] \
    || fail "budget verdict used a different duration than the summary: $(cat "$tmp/over")"

  # A malformed budget is refused rather than silently ignored.
  set +e
  "$runner" --max-wall-ms 0 "$fast" >"$tmp/bad" 2>"$tmp/bad.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms 0 must be refused (exit 2), got $rc"
  set +e
  "$runner" --max-wall-ms nope "$fast" >"$tmp/bad2" 2>"$tmp/bad2.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--max-wall-ms with a non-number must be refused (exit 2), got $rc"

  rm -rf "$tmp"
  pass "--max-wall-ms fails an over-budget run and refuses a malformed budget"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_from_list_selects_entries_and_refuses_bad_ones() {
  local tmp repo out rc
  tmp=$(fm_test_tmproot fm-test-run-from-list)
  repo="$tmp/repo"
  init_stub_suite_repo "$repo" fm-a.test.sh fm-b.test.sh
  printf '# try list\n\ntests/fm-a.test.sh\r\nfm-b.test.sh:test_x\ntests/fm-a.test.sh\n' >"$tmp/ok.list"
  out=$(cd "$repo" && bin/fm-test-run.sh --list --from-list "$tmp/ok.list") \
    || fail "--from-list with a comment, a blank, CRLF and a duplicate must list"
  [ "$out" = "tests/fm-a.test.sh
tests/fm-b.test.sh:test_x" ] || fail "--from-list must print each entry once in canonical form: $out"

  for bad in 'tests/fm-a.test.sh
tests/fm-a.test.sh:test_y' 'tests/fm-a.test.sh:bad-name' 'tests/fm-a.test.sh:' \
    'tests/fm-missing.test.sh' '# only a comment'; do
    printf '%s\n' "$bad" >"$tmp/bad.list"
    rc=0
    (cd "$repo" && bin/fm-test-run.sh --list --from-list "$tmp/bad.list") >/dev/null 2>"$tmp/bad.err" || rc=$?
    [ "$rc" -eq 2 ] || fail "--from-list must refuse with exit 2 (got $rc) for: $bad"
  done
  printf 'tests/fm-a.test.sh\ntests/fm-a.test.sh:test_y\n' >"$tmp/bad.list"
  (cd "$repo" && bin/fm-test-run.sh --list --from-list "$tmp/bad.list") >/dev/null 2>"$tmp/bad.err" || true
  assert_grep "twice with different cases" "$tmp/bad.err" "a whole and a case entry for one script must name the conflict"
  rc=0
  (cd "$repo" && bin/fm-test-run.sh --list --from-list "$tmp/nowhere.list") >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "--from-list must refuse an unreadable list file (got $rc)"
  pass "--from-list lists entries once and refuses conflicts, malformed cases, missing scripts and empty lists"
}

# A case suite sourcing a real copy of tests/lib.sh, so the FM_TEST_ONLY filter
# and the runner's no-match verdict meet as they do in CI.
init_case_suite_repo() {
  local repo=$1
  init_stub_suite_repo "$repo"
  cp "$ROOT/tests/lib.sh" "$repo/tests/lib.sh"
  cat >"$repo/tests/fm-cases.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
case_helper() { printf 'helper ran\n'; }
test_one() { pass "one"; }
test_two() { case_helper; test_three_helper_case; pass "two"; }
test_three_helper_case() { pass "three"; }
test_one
test_two
test_three_helper_case
SH
  cat >"$repo/tests/fm-gated.test.sh" <<'SH'
#!/usr/bin/env bash
echo "skip: fixture tool not found"
SH
}

test_from_list_case_entry_runs_one_case() {
  local tmp repo rc
  tmp=$(fm_test_tmproot fm-test-run-from-list-case)
  repo="$tmp/repo"
  init_case_suite_repo "$repo"

  printf 'tests/fm-cases.test.sh:test_two\n' >"$tmp/two.list"
  (cd "$repo" && bin/fm-test-run.sh --from-list "$tmp/two.list") >"$tmp/two.out" 2>&1 \
    || fail "a case entry naming a case must pass: $(cat "$tmp/two.out")"
  assert_grep "ok - two" "$tmp/two.out" "the named case must run"
  assert_grep "helper ran" "$tmp/two.out" "the named case's helpers must run"
  assert_grep "ok - three" "$tmp/two.out" "a sibling case the named case calls must run"
  assert_no_grep "ok - one" "$tmp/two.out" "a sibling case at top level must not run"
  assert_grep "# FM_TEST_ONLY: skipped test_one" "$tmp/two.out" "a skipped sibling must say so"

  printf 'tests/fm-cases.test.sh:test_four\n' >"$tmp/four.list"
  rc=0
  (cd "$repo" && bin/fm-test-run.sh --from-list "$tmp/four.list") >"$tmp/four.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a case entry matching no case must fail: $(cat "$tmp/four.out")"
  assert_grep "not ok - FM_TEST_ONLY=test_four matched no case in tests/fm-cases.test.sh" "$tmp/four.out" \
    "a case entry matching no case must say which"

  printf 'tests/fm-gated.test.sh:test_any\n' >"$tmp/gated.list"
  (cd "$repo" && bin/fm-test-run.sh --from-list "$tmp/gated.list") >"$tmp/gated.out" 2>&1 \
    || fail "a gate-skipped script must not fail its case entry: $(cat "$tmp/gated.out")"
  assert_no_grep "matched no case" "$tmp/gated.out" "a gate skip is not a missed case"

  printf 'tests/fm-cases.test.sh\n' >"$tmp/whole.list"
  (cd "$repo" && FM_TEST_ONLY=test_one bin/fm-test-run.sh --from-list "$tmp/whole.list") >"$tmp/whole.out" 2>&1 \
    || fail "a whole-script entry must pass: $(cat "$tmp/whole.out")"
  assert_grep "ok - two" "$tmp/whole.out" "an inherited FM_TEST_ONLY must not filter a whole-script entry"

  rc=0
  (cd "$repo" && FM_TEST_ONLY=bad-name bash tests/fm-cases.test.sh) >"$tmp/bad.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "tests/lib.sh must refuse a malformed FM_TEST_ONLY"
  assert_grep "FM_TEST_ONLY=bad-name is not a case function name" "$tmp/bad.out" "the refusal must name the value"
  pass "a case entry runs only its case, fails a miss, and leaves whole entries and gate skips alone"
}

test_changed_skip_unmapped_reports_and_carries_on() {
  local tmp repo listed rc
  tmp=$(fm_test_tmproot fm-test-run-skip-unmapped)
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf '\n' >>"$repo/src/unmapped.ts"
  printf '\n' >>"$repo/tests/fm-backend.test.sh"
  rc=0
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unmapped changed path must still refuse plain --changed (got $rc)"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --skip-unmapped --base HEAD 2>"$tmp/err") \
    || fail "--skip-unmapped must carry on past an unmapped path: $(cat "$tmp/err")"
  assert_contains "$listed" "tests/fm-backend.test.sh" "--skip-unmapped must keep the mapped selection"
  assert_grep "FM_TEST_UNMAPPED path=src/unmapped.ts" "$tmp/err" "--skip-unmapped must report the unmapped path"
  rc=0
  (cd "$repo" && bin/fm-test-run.sh --list --skip-unmapped tests/fm-backend.test.sh) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "--skip-unmapped without --changed must be a usage error (got $rc)"
  pass "--skip-unmapped reports an unmapped changed path and keeps the rest"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr job's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/ci.yml as YAML"
  local json job_timeout step_timeout
  json=$(ruby -ryaml -rjson -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("tests-herdr")
step = job.fetch("steps").find { |s|
  s.is_a?(Hash) && s["name"] == "Run real-Herdr family (serial, required)"
}
raise "missing family-run step" if step.nil?
raise "family-run step has no timeout-minutes" unless step.key?("timeout-minutes")
puts JSON.generate(
  "job_timeout" => job.fetch("timeout-minutes"),
  "step_timeout" => step.fetch("timeout-minutes")
)
' "$ROOT/.github/workflows/ci.yml") \
    || fail "could not parse tests-herdr timeouts from ci.yml"
  job_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_task_marker_refuses_the_primary_checkout
test_changed_runner_surfaces_select_their_family
test_shell_line_ending_policy_selects_runner_contract
test_changed_dependency_selection_and_unmapped_failure
test_changed_bin_reference_selects_per_script_not_per_family
test_changed_risky_list_and_skill_prose_map_without_escalating
test_changed_opencode_plugin_selects_plugin_suites
test_changed_bin_walk_follows_python_imports_to_any_depth
test_changed_uses_bounded_automatic_concurrency
test_windows_posix_mode_emulation_does_not_fail_parallel_runs
test_script_list_uses_bounded_automatic_concurrency
test_family_proofs_run_in_separate_concurrent_phases
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_gate_skip_reason_is_recorded
test_a_run_that_ran_records_no_skip_reason
test_live_guards_expect_a_capability_skip_class
test_fail_on_gate_skip_token
test_exclude_family
test_list_scheduled_proven_isolated_uses_path_order_without_timing
test_list_scheduled_orders_by_timing
test_tier_selection_and_filter
test_tiers_partition_the_suite_and_gate_holds_the_core
test_shards_partition_a_tier
test_shard_packs_by_timing
test_coverage_guard_reports_and_refuses
test_jobs_requires_proven_isolated
test_tier_jobs_overlap_only_proven_scripts
test_jobs_admits_a_concurrent_safe_family
test_unmapped_new_test_never_inherits_family_concurrency
test_changed_shared_fixture_selects_its_readers
test_concurrent_runs_are_ordered_longest_first
test_per_script_timeout_bounds_a_hang
test_changed_bound_gives_slow_watcher_suites_headroom
test_max_wall_ms_is_a_result_not_advice
test_jobs_parallel_scheduler_and_failure_propagation
test_from_list_selects_entries_and_refuses_bad_ones
test_from_list_case_entry_runs_one_case
test_changed_skip_unmapped_reports_and_carries_on
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
