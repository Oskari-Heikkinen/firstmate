#!/usr/bin/env bash
# Behavior tests for bin/fm-landed-sync.sh, the post-landing refresh of the main
# home's clone through the guarded fleet-sync path.
#
# Pins that a behind clone fast-forwards with no report; that a dirty or
# diverged clone is left untouched and reported to the main home's wake queue
# exactly once per episode, the report re-arming after a good refresh; that a
# provably stale index.lock is reported once and never removed, while a young
# one is left to its owner and never called stale; that a secondmate home
# refreshes its own clone and the main home's clone, reporting into the main
# home only; and that a recorded merge launches the refresh without waiting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-landed-sync-tests)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/lsof"
export PATH="$FAKEBIN:$PATH"

new_home() {
  local h
  h=$(mktemp -d "$TMP_ROOT/home-XXXXXX")
  mkdir -p "$h/projects" "$h/state"
  printf '%s\n' "$h"
}

commit_file() {
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}

# build_origin <name>: a bare origin with one commit on main and a work repo
# wired to it; echoes the origin URL.
build_origin() {
  local name=$1 work="$TMP_ROOT/work-$1" remote="$TMP_ROOT/remotes/$1.git"
  mkdir -p "$TMP_ROOT/remotes"
  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  git -C "$work" remote add origin "file://$(cd "$remote" && pwd)"
  git -C "$work" push -q -u origin main
  printf 'file://%s\n' "$(cd "$remote" && pwd)"
}

advance_origin() {
  commit_file "$TMP_ROOT/work-$1" file.txt "$2" "$2"
  git -C "$TMP_ROOT/work-$1" push -q origin main
}

run_landed() {  # <home> <arg>
  FM_HOME="$1" "$ROOT/bin/fm-landed-sync.sh" "$2" 2>/dev/null
}

wake_rows() {  # <home> <name>
  { cat "$1/state/.wake-queue" 2>/dev/null || true; } | grep -c "	landed-sync-$2	"
}

test_behind_clone_fast_forwards_silently() {
  local h url out
  h=$(new_home)
  url=$(build_origin p1)
  git clone -q "$url" "$h/projects/p1"
  advance_origin p1 v1
  out=$(run_landed "$h" p1); expect_code 0 $? "${FUNCNAME[0]}:$LINENO"
  assert_contains "$out" "main clone current" "${FUNCNAME[0]}:$LINENO"
  assert_equals "$(git -C "$TMP_ROOT/work-p1" rev-parse HEAD)" "$(git -C "$h/projects/p1" rev-parse HEAD)" "${FUNCNAME[0]}:$LINENO"
  assert_equals 0 "$(wake_rows "$h" p1)" "${FUNCNAME[0]}:$LINENO"
  pass "a behind main clone fast-forwards with no report"
}

test_dirty_clone_reported_once_per_episode() {
  local h url out
  h=$(new_home)
  url=$(build_origin p2)
  git clone -q "$url" "$h/projects/p2"
  advance_origin p2 v1
  printf 'local edit\n' > "$h/projects/p2/file.txt"
  out=$(run_landed "$h" p2); expect_code 0 $? "${FUNCNAME[0]}:$LINENO"
  assert_contains "$out" "reported stuck" "${FUNCNAME[0]}:$LINENO"
  assert_equals 1 "$(wake_rows "$h" p2)" "${FUNCNAME[0]}:$LINENO"
  assert_grep "check: landed-sync p2: the main clone was not refreshed: on branch main with uncommitted changes" "$h/state/.wake-queue" "${FUNCNAME[0]}:$LINENO"
  assert_equals "local edit" "$(cat "$h/projects/p2/file.txt")" "${FUNCNAME[0]}:$LINENO"
  out=$(run_landed "$h" p2)
  assert_contains "$out" "stuck already reported" "${FUNCNAME[0]}:$LINENO"
  assert_equals 1 "$(wake_rows "$h" p2)" "${FUNCNAME[0]}:$LINENO"
  git -C "$h/projects/p2" checkout -q -- file.txt
  out=$(run_landed "$h" p2)
  assert_contains "$out" "main clone current" "${FUNCNAME[0]}:$LINENO"
  assert_absent "$h/state/landed-sync/p2.reported" "${FUNCNAME[0]}:$LINENO"
  printf 'again\n' > "$h/projects/p2/file.txt"
  advance_origin p2 v2
  run_landed "$h" p2 >/dev/null
  assert_equals 2 "$(wake_rows "$h" p2)" "${FUNCNAME[0]}:$LINENO"
  pass "a dirty main clone is untouched and reported once per episode"
}

test_diverged_clone_reported() {
  local h url
  h=$(new_home)
  url=$(build_origin p3)
  git clone -q "$url" "$h/projects/p3"
  commit_file "$h/projects/p3" local.txt x local
  advance_origin p3 v1
  run_landed "$h" p3 >/dev/null
  assert_grep "landed-sync p3: the main clone was not refreshed: on diverged main" "$h/state/.wake-queue" "${FUNCNAME[0]}:$LINENO"
  pass "a diverged main clone is reported, never forced"
}

test_stale_index_lock_reported_never_removed() {
  local h url before out
  h=$(new_home)
  url=$(build_origin p4)
  git clone -q "$url" "$h/projects/p4"
  advance_origin p4 v1
  : > "$h/projects/p4/.git/index.lock"
  fm_touch_epoch $(( $(date +%s) - 1200 )) "$h/projects/p4/.git/index.lock"
  before=$(git -C "$h/projects/p4" rev-parse HEAD)
  out=$(run_landed "$h" p4); expect_code 0 $? "${FUNCNAME[0]}:$LINENO"
  assert_contains "$out" "reported stale-lock" "${FUNCNAME[0]}:$LINENO"
  assert_present "$h/projects/p4/.git/index.lock" "${FUNCNAME[0]}:$LINENO"
  assert_equals "$before" "$(git -C "$h/projects/p4" rev-parse HEAD)" "${FUNCNAME[0]}:$LINENO"
  assert_grep "stale git lock $h/projects/p4/.git/index.lock (20 minutes old, no process holds it) left in place" "$h/state/.wake-queue" "${FUNCNAME[0]}:$LINENO"
  run_landed "$h" p4 >/dev/null
  assert_equals 1 "$(wake_rows "$h" p4)" "${FUNCNAME[0]}:$LINENO"
  pass "a stale index lock is reported once and left in place"
}

test_young_index_lock_is_not_called_stale() {
  local h url
  h=$(new_home)
  url=$(build_origin p5)
  git clone -q "$url" "$h/projects/p5"
  advance_origin p5 v1
  : > "$h/projects/p5/.git/index.lock"
  run_landed "$h" p5 >/dev/null
  assert_present "$h/projects/p5/.git/index.lock" "${FUNCNAME[0]}:$LINENO"
  assert_no_grep "stale git lock" "$h/state/.wake-queue" "${FUNCNAME[0]}:$LINENO"
  assert_grep "landed-sync p5: the main clone was not refreshed: fast-forward failed" "$h/state/.wake-queue" "${FUNCNAME[0]}:$LINENO"
  pass "a young index lock is left to its owner and not called stale"
}

test_secondmate_refreshes_both_and_reports_to_main() {
  local main sm url
  main=$(new_home)
  sm=$(new_home)
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$main" > "$sm/.fm-secondmate-parent"
  url=$(build_origin p6)
  git clone -q "$url" "$main/projects/p6"
  git clone -q "$url" "$sm/projects/p6"
  advance_origin p6 v1
  run_landed "$sm" "$sm/projects/p6" >/dev/null; expect_code 0 $? "${FUNCNAME[0]}:$LINENO"
  assert_equals "$(git -C "$TMP_ROOT/work-p6" rev-parse HEAD)" "$(git -C "$main/projects/p6" rev-parse HEAD)" "${FUNCNAME[0]}:$LINENO"
  assert_equals "$(git -C "$TMP_ROOT/work-p6" rev-parse HEAD)" "$(git -C "$sm/projects/p6" rev-parse HEAD)" "${FUNCNAME[0]}:$LINENO"
  printf 'dirty\n' > "$main/projects/p6/file.txt"
  advance_origin p6 v2
  run_landed "$sm" "$sm/projects/p6" >/dev/null
  assert_equals 1 "$(wake_rows "$main" p6)" "${FUNCNAME[0]}:$LINENO"
  assert_equals 0 "$(wake_rows "$sm" p6)" "${FUNCNAME[0]}:$LINENO"
  pass "a secondmate landing refreshes both clones and reports to the main home"
}

test_unknown_project_and_bad_name() {
  local h out
  h=$(new_home)
  out=$(run_landed "$h" nothere); expect_code 0 $? "${FUNCNAME[0]}:$LINENO"
  assert_contains "$out" "holds no clone" "${FUNCNAME[0]}:$LINENO"
  FM_HOME="$h" "$ROOT/bin/fm-landed-sync.sh" 'a b' >/dev/null 2>&1
  expect_code 2 $? "${FUNCNAME[0]}:$LINENO"
  pass "an absent project is skipped and a bad name refused"
}

test_recorded_merge_launches_refresh() {
  local h url i
  h=$(new_home)
  url=$(build_origin p7)
  # An explicitly registered clone outside projects/ must still be refreshed.
  git clone -q "$url" "$h/p7"
  advance_origin p7 v1
  printf 'project=%s\n' "$h/p7" > "$h/state/t7.meta"
  (
    STATE="$h/state"
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_merge_outcome_refresh_main_clone "$h" "$h/state" t7
  )
  for i in $(seq 1 100); do
    [ "$(git -C "$h/p7" rev-parse HEAD)" = "$(git -C "$TMP_ROOT/work-p7" rev-parse HEAD)" ] && break
    sleep 0.1
  done
  assert_equals "$(git -C "$TMP_ROOT/work-p7" rev-parse HEAD)" "$(git -C "$h/p7" rev-parse HEAD)" "${FUNCNAME[0]}:$LINENO"
  pass "a recorded merge refreshes an explicit clone outside projects/ in the background"
}

test_behind_clone_fast_forwards_silently
test_dirty_clone_reported_once_per_episode
test_diverged_clone_reported
test_stale_index_lock_reported_never_removed
test_young_index_lock_is_not_called_stale
test_secondmate_refreshes_both_and_reports_to_main
test_unknown_project_and_bad_name
test_recorded_merge_launches_refresh
