#!/usr/bin/env bash
# Checked-spool consumers, including the independent R1 probes and siblings.
# SPOOL_TEST_BIN/SPOOL_ONLY_CASE are fixture-only seams for one-off guard
# counterfactuals; they never select a live home or run executable teardown.
# shellcheck disable=SC2030,SC2031 # Each subshell fixture assigns its own gate state.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SPOOL_TEST_BIN=${SPOOL_TEST_BIN:-$ROOT/bin}
# shellcheck source=bin/fm-task-evidence-lib.sh
. "$SPOOL_TEST_BIN/fm-task-evidence-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-spool)

# Extract function definitions only, as in the independent review probe.
# No source-byte assertions and no executable teardown/lifecycle entry point.
eval "$(python3 - "$SPOOL_TEST_BIN/fm-teardown.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for name in ('validate_worktree_teardown_safety', 'significant_worktree_changes',
             'report_worktree_dirt', 'unpushed_patches_are_in_pr_head',
             'commits_replayed_on_default', 'content_in_default', 'teardown_note_dirty_return',
             'work_is_landed', 'pr_is_merged'):
    print(re.search(r'^' + name + r'\(\) \{\n.*?^\}', text, re.M | re.S)[0])
PY
)"

fault() { # operation path; successful producers and otherwise-valid inputs
  [ "$1:${2##*/}" = "$fault_call" ] || return 0
  local count=0
  if [ -f "$lab/count" ]; then IFS= read -r count < "$lab/count" || return 2; fi
  count=$((count + 1)); printf '%s\n' "$count" > "$lab/count" || return 2
  [ "$count" = "$fault_n" ] || return 0
  : > "$lab/triggered"
  case "$fault_kind" in
    permission) chmod 000 "$2"; return 0 ;;
    prefix) printf 'D%s\0' "$fault_prefix" ;;
  esac
  echo "REFUSED: injected spool read error: $1 $2" >&2
  return 2
}
fm_spool() {
  fault "$1" "$2" || return 2
  python3 "$SPOOL_TEST_BIN/fm_spool.py" "$@"
}
fm_task_evidence_stream() {
  case "$1" in
    copies) fault copies "$6" || return 2 ;;
    verify) fault verify "$3" || return 2 ;;
  esac
  python3 "$SPOOL_TEST_BIN/fm-task-evidence-stream.py" "$@" || return
  if [ "$1" = copies ]; then fault producer "$5" || return 2; fi
}

run_evidence_case() (
  local name=$1 rc=0 fault_call='' fault_n=1 fault_kind=error fault_prefix='copy/bundle'
  local lab="$TMP_ROOT/$name" source data scan
  source="$lab/source"; data="$lab/data"; scan="$lab/scan"
  mkdir -p "$source/bundle" "$data/task" "$scan"
  printf 'old proof\n' > "$source/bundle/proof"
  ln -s proof "$source/bundle/link"
  printf 'bundle\n' > "$data/task/evidence.list"
  fm_task_evidence_preserve task "$data" "$source" 1 '' || fail "$name: seed prior evidence"
  printf 'new proof\n' > "$source/bundle/proof"
  case "$name" in
    rows) fault_call=read:rels.rows ;;
    rows-review-probe) fault_call=producer:rels.rows; fault_kind=permission ;;
    paths) fault_call=read:paths ;;
    source-links) fault_call=read:source-links ;;
    rels) fault_call=copies:rels; fault_kind=permission ;;
    declarations) fault_call=read:declarations ;;
    declared-overlap) fault_call=read:declared ;;
    declared-survival) fault_call=read:declared; fault_n=2; fault_kind=prefix ;;
    manifest-verify) fault_call=verify:MANIFEST.sha256; fault_kind=permission ;;
    links-verify) fault_call=read:MANIFEST.sha256.links ;;
    links-target) fault_call=read:MANIFEST.sha256.links; fault_n=2 ;;
    stage-messages) fault_call=cat:stage.err ;;
    manifest-empty) fault_call=inspect:MANIFEST.sha256 ;;
    matches) fault_call=read:matches ;;
    record-lines) fault_call=cat:record-lines ;;
    refs) fault_call=read:refs ;;
    prior-verify|prior-foreign) fault_call=verify:prior-regular; fault_kind=permission ;;
    prior-link-verify) fault_call=read:prior-links ;;
    prior-regular-append) fault_call=read:prior-regular ;;
    prior-link-append) fault_call=read:prior-links; fault_n=2 ;;
    healthy) ;;
    *) fail "unknown case $name" ;;
  esac
  case "$name" in
    matches|record-lines|refs) printf 'saved %s/bundle/proof\n' "$source" > "$data/task/report.md" ;;
  esac
  case "$name" in
    prior-foreign)
      fm_task_evidence_preserve task "$data" "$source" 0 '' > "$lab/out" 2> "$lab/err" || rc=$? ;;
    prior-*)
      FM_TE_WORK=$scan
      mkdir -p "$lab/staging"
      : > "$lab/staging/MANIFEST.sha256"; : > "$lab/staging/MANIFEST.sha256.links"
      fm_task_evidence_carry_prior "$data/task/evidence" copy/bundle "$lab/staging" "$lab/staging/MANIFEST.sha256" > "$lab/out" 2> "$lab/err" || rc=$?
      expect_code 2 "$rc" "$name: private spool failure is staging failure, not lost prior evidence"
      ;;
    *) fm_task_evidence_preserve task "$data" "$source" 1 '' > "$lab/out" 2> "$lab/err" || rc=$? ;;
  esac
  if [ "$name" = healthy ]; then
    expect_code 0 "$rc" 'healthy readable spools'
    assert_grep 'new proof' "$data/task/evidence/copy/bundle/proof" 'healthy preservation installs new proof'
  else
    case "$name" in prior-foreign) expect_code 1 "$rc" "$name: must refuse" ;; prior-*) ;; *) expect_code 1 "$rc" "$name: must refuse" ;; esac
    [ -f "$lab/triggered" ] || fail "$name: fault was not reached"
    assert_grep 'old proof' "$data/task/evidence/copy/bundle/proof" "$name: prior evidence retained"
    assert_grep 'REFUSED:' "$lab/err" "$name: named refusal"
  fi
  assert_grep 'new proof' "$source/bundle/proof" "$name: source retained unchanged"
  pass "evidence spool $name"
)

run_gate_case() (
  local name=$1 rc=0 fault_call='' fault_n=1 fault_kind=error fault_prefix=abc
  local lab="$TMP_ROOT/$name"
  mkdir -p "$lab/spool" "$lab/wt"
  export WT="$lab/wt" TEARDOWN_WORK_SCAN="$lab/spool" FORCE='' KIND=ship MODE=no-mistakes
  export TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=topic LANDED_HEAD=HEAD PROJ=fixture TEARDOWN_POOL_SLOT_LOST=0
  # Invoked by the sourced landed-work functions through the fake tool surface.
  # shellcheck disable=SC2329
  git() {
    case "${3:-}" in
      status) return 0 ;;
      log)
        case "$*" in
          *--oneline*) case "$name" in gate-unpushed*|gate-unmerged*|gate-unlanded) printf 'abc private commit\n' ;; esac ;;
          *) printf 'abc\n' ;;
        esac ;;
      rev-parse|merge-base) printf 'abc\n' ;;
      rev-list) case "$*" in *--merges*) ;; *) printf 'abc\n' ;; esac ;;
      merge-tree) printf 'abc\n' ;;
      *) if [ "$1" = patch-id ]; then while IFS= read -r _; do :; done; printf 'patch abc\n'; else return 1; fi ;;
    esac
  }
  # shellcheck disable=SC2329 # Invoked by the sourced landed-work predicate.
  default_branch() { printf 'main\n'; }
  work_is_landed() { : > "$lab/landed-called"; return 1; }
  patch_id_for_commit() { printf 'patch\n'; }
  canonical_existing_dir() { printf '%s\n' "$1"; }
  case "$name" in
    gate-status) fault_call=cat:status ;;
    gate-dirty) fault_call=inspect:dirty ;;
    gate-unpushed) fault_call=summary:unpushed ;;
    gate-unpushed-review-probe) fault_call=seal:unpushed; fault_kind=permission ;;
    gate-unmerged) MODE=local-only; fault_call=summary:unmerged ;;
    gate-unmerged-review-probe) MODE=local-only; fault_call=seal:unmerged; fault_kind=permission ;;
    pr-commits) fault_call=read:pr-commits; fault_kind=prefix ;;
    pr-unpushed) fault_call=read:pr-unpushed ;;
    pr-patches) fault_call=contains:pr-patches ;;
    replay-status) fault_call=cat:replay-status ;;
    replay-dirty) fault_call=inspect:replay-dirty ;;
    replay-merges) fault_call=inspect:replay-merges ;;
    replay-commits) fault_call=read:replay-commits ;;
    replay-patches) fault_call=contains:replay-patches ;;
    merge-tree) fault_call=summary:merge-tree ;;
    residue) fault_call=inspect:residue ;;
    gate-empty|gate-unlanded) ;;
    *) fail "unknown case $name" ;;
  esac
  case "$name" in
    pr-*) unpushed_patches_are_in_pr_head abc > "$lab/out" 2> "$lab/err" || rc=$? ;;
    replay-*) commits_replayed_on_default main > "$lab/out" 2> "$lab/err" || rc=$? ;;
    merge-tree) content_in_default main > "$lab/out" 2> "$lab/err" || rc=$? ;;
    residue) teardown_note_dirty_return "$WT" > "$lab/out" 2> "$lab/err" || rc=$? ;;
    *) validate_worktree_teardown_safety > "$lab/out" 2> "$lab/err" || rc=$? ;;
  esac
  case "$name" in
    gate-empty) expect_code 0 "$rc" 'healthy empty status and commit spools' ;;
    residue) [ "$TEARDOWN_POOL_SLOT_LOST" = 1 ] || fail 'unknown residue is not a healthy clean return' ;;
    pr-*|replay-*|merge-tree) expect_code 2 "$rc" "$name: failed spool is not an inconclusive proof" ;;
    *) expect_code 1 "$rc" "$name: must refuse" ;;
  esac
  if [ "$name" = gate-unlanded ]; then
    [ -f "$lab/landed-called" ] || fail 'readable unlanded control must invoke landed predicate'
  elif [ "$name" != gate-empty ]; then
    [ -f "$lab/triggered" ] || fail "$name: fault was not reached"
    assert_grep 'REFUSED:' "$lab/err" "$name: named refusal"
  fi
  [ -d "$WT" ] || fail "$name: worktree retained"
  pass "landed-work spool $name"
)

run_fallback_case() (
  local name=$1 rc=0 lab="$TMP_ROOT/$1"
  mkdir -p "$lab/wt"
  export WT="$lab/wt" LANDED_HEAD=HEAD PR_URL=https://example.invalid/pull/1
  fresh_default_ref() { printf 'main\n'; }
  content_in_default() { : > "$lab/accepted"; return 0; }
  commits_replayed_on_default() { [ "$name" != fallback-replay ] || return 2; return 1; }
  if [ "$name" != fallback-pr-inner ]; then
    pr_is_merged() { [ "$name" != fallback-pr ] || return 2; return 1; }
  fi
  fm_pr_url_parse() { return 1; }
  teardown_remote() { printf 'MERGED\tabc\thttps://example.invalid/pull/1\n'; }
  ensure_commit_object() { return 0; }
  # shellcheck disable=SC2329 # Invoked by the sourced PR predicate.
  unpushed_patches_are_in_pr_head() { return 2; }
  # Invoked by the sourced PR predicate.
  # shellcheck disable=SC2329
  git() { [ "${3:-}" != rev-parse ] || { printf 'abc\n'; return 0; }; return 1; }
  work_is_landed topic || rc=$?
  if [ "$name" = fallback-valid ]; then
    expect_code 0 "$rc" 'ordinary not-proven predicates retain content fallback'
    [ -f "$lab/accepted" ] || fail 'healthy fallback not invoked'
  else
    expect_code 2 "$rc" "$name: private spool errors must not fall back to success"
    [ ! -e "$lab/accepted" ] || fail "$name: failed proof reached accepting fallback"
  fi
  pass "$name"
)

failed=0
for case_name in healthy rows rows-review-probe paths source-links rels declarations declared-overlap declared-survival manifest-verify links-verify links-target stage-messages manifest-empty matches record-lines refs prior-verify prior-foreign prior-link-verify prior-regular-append prior-link-append gate-empty gate-unlanded gate-status gate-dirty gate-unpushed gate-unpushed-review-probe gate-unmerged gate-unmerged-review-probe pr-commits pr-unpushed pr-patches replay-status replay-dirty replay-merges replay-commits replay-patches merge-tree residue fallback-pr fallback-pr-inner fallback-replay fallback-valid; do
  [ -z "${SPOOL_ONLY_CASE:-}" ] || [ "$SPOOL_ONLY_CASE" = "$case_name" ] || continue
  case "$case_name" in
    gate-*|pr-*|replay-*|merge-tree|residue) run_gate_case "$case_name" || failed=1 ;;
    fallback-*) run_fallback_case "$case_name" || failed=1 ;;
    *) run_evidence_case "$case_name" || failed=1 ;;
  esac
done
if [ -z "${SPOOL_ONLY_CASE:-}" ] || [ "$SPOOL_ONLY_CASE" = protocol ]; then
  python3 "$ROOT/tests/spool-probes.py" "$SPOOL_TEST_BIN" "$TMP_ROOT/protocol" || failed=1
fi
exit "$failed"
