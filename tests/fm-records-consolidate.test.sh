#!/usr/bin/env bash
# tests/fm-records-consolidate.test.sh - handled-record consolidation
# (bin/fm-records-consolidate.sh, log format owned by bin/fm-records-log-lib.sh)
# and every reader that must see a consolidated record as it saw the file.
#
# Fixtures only. Each case builds its own home under the suite's temp root and
# moves the tool's clock 8 days ahead through FM_RECORDS_CONSOLIDATE_NOW, so a
# record handled now counts as past the 7-day limit; a record meant to stay
# recent gets a modification time past that clock. Cases:
#   1. Procevent: old handled results move into the log, their zero-byte
#      markers stay, and `fm-procevent.sh handled` still answers
#      already-handled; `show` reads the logged bytes; nothing consolidated is
#      pending or re-announced by reconcile; a new capture never reuses a
#      consolidated sequence. Recent, unhandled and each source's newest
#      results stay files.
#   2. Task inbox: handled/ records move into the log, and the readers of
#      handled/ - the sequence allocator, the idempotent enqueue's dedup, the
#      milestone receipt and redelivery - see them exactly as before.
#      Unhandled and recent records stay files.
#   3. A crash after the log commit and before (or during) file removal leaves
#      every record readable; the rerun removes the files and an uncommitted
#      segment without storing anything twice, and a further rerun changes
#      nothing. An unreadable log fails closed.
#   4. --dry-run changes nothing and prints the files, bytes and MiB bound.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-records-consolidate)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
LATER=$(( $(date +%s) + 8 * 86400 ))

# The procevent runner resolves adapters under its root; this fixture adapter
# supports nothing, so reconcile announces every pending result as it is.
ADAPTER_ROOT="$TMP_ROOT/adapter-root"
mkdir -p "$ADAPTER_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 2\n' > "$ADAPTER_ROOT/bin/fm-procevent-plain.sh"
chmod +x "$ADAPTER_ROOT/bin/fm-procevent-plain.sh"

pe() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ADAPTER_ROOT" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Run one production library function in a fresh bash that sources the
# library, so the cases use the public functions and no format knowledge.
pe_lib() {  # <function> [args...]
  bash -c '
    . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
    fn=$2; shift 2; "$fn" "$@"' _ "$ROOT" "$@"
}
inbox_lib() {  # <function> [args...]
  bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT" "$@"
}

consolidate() { FM_RECORDS_CONSOLIDATE_NOW=$LATER bash "$ROOT/bin/fm-records-consolidate.sh" "$@"; }

make_recent() {  # <path>...
  perl -e 'my $t = shift; utime($t, $t, @ARGV) == @ARGV or exit 1' "$((LATER + 86400))" "$@" \
    || fail "cannot set a future modification time on $*"
}

new_home() {  # <home>
  (umask 077; mkdir -p "$1/state" "$1/data") || fail "cannot make home $1"
  fm_test_track_procevent_home "$1" "$FM_PROCEVENT_CLAIM_ROOT"
}

capture() {  # <home> <source-id> <text>
  printf '%s\n' "$3" > "$1/payload"
  pe_lib fm_procevent_capture "$1/state" "$2" plain "$1/payload" || fail "capture failed: $2 $3"
}

handled() {  # <home> <source-id> <sequence>
  pe "$1" handled "$2" "$3" >/dev/null || fail "handled failed: $2 $3"
}

# The tree's line from a run's output, by the tree's trailing path.
tree_line() {  # <output> <tree-suffix>
  printf '%s\n' "$1" | grep -F "$2 kind=" || fail "no line for $2 in:"$'\n'"$1"
}

wake_keys() { awk -F '\t' '{ print $4 }' "$1/state/.wake-queue" 2>/dev/null; }
count_exact() { printf '%s\n' "$1" | grep -cxF -- "$2" || true; }

# Two sources: src1 has results 1-4, of which 1-3 are handled and 3 is recent;
# src2 has results 1-2, both handled. Eligible: src1 1-2 and src2 1, because
# src2 2 is that source's newest result.
build_procevent() {  # <home>
  local home=$1 n
  for n in 1 2 3 4; do capture "$home" src1 "result src1 $n" >/dev/null; done
  for n in 1 2; do capture "$home" src2 "result src2 $n" >/dev/null; done
  for n in 1 2 3; do handled "$home" src1 "$n"; done
  for n in 1 2; do handled "$home" src2 "$n"; done
  make_recent "$home/state/procevent-inbox/src1.3.handled"
}

test_procevent_consolidation() {
  local home="$TMP_ROOT/procevent" inbox out line f n pending keys path
  new_home "$home"
  build_procevent "$home"
  inbox="$home/state/procevent-inbox"
  out=$(consolidate --state "$home/state") || fail "consolidation failed: $out"
  line=$(tree_line "$out" procevent-inbox)
  assert_contains "$line" 'files=6 bytes=60 ' 'procevent run did not take exactly the eligible files'
  assert_contains "$line" 'moved=3 skipped=0' 'procevent run did not move the three eligible records'
  for f in src1.1 src1.2 src2.1; do
    assert_absent "$inbox/$f.result" "$f.result is still a file"
    assert_absent "$inbox/$f.adapter" "$f.adapter is still a file"
    [ -f "$inbox/$f.handled" ] && [ ! -s "$inbox/$f.handled" ] || fail "$f lost its zero-byte handled marker"
  done
  for f in src1.3 src1.4 src2.2; do
    assert_present "$inbox/$f.result" "$f.result (recent, unhandled or newest) was moved"
    assert_present "$inbox/$f.adapter" "$f.adapter (recent, unhandled or newest) was moved"
  done
  assert_absent "$inbox/src1.4.handled" 'consolidation marked an unhandled result'
  pass 'procevent: old handled results move into the log; recent, unhandled and newest results stay files'

  for f in 'src1 1' 'src1 2' 'src2 1'; do
    # shellcheck disable=SC2086 # f is a source id and sequence pair.
    out=$(pe "$home" handled $f) || fail "handled refused a consolidated result: $f"
    assert_equals "already-handled: $f" "$out" "a consolidated result did not answer already-handled"
  done
  if pe "$home" handled src1 99 >/dev/null 2>&1; then
    fail 'a sequence with no result and no logged copy was answered as handled'
  fi
  assert_absent "$inbox/src1.99.handled" 'a refused handled call wrote a marker'
  pass 'procevent: handled answers already-handled for a consolidated sequence, and still refuses an unknown one'

  for f in 'src1 1' 'src2 1'; do
    # shellcheck disable=SC2086 # f is a source id and sequence pair.
    pe "$home" show $f > "$home/shown" || fail "show could not read a consolidated result: $f"
    printf 'result %s\n' "$f" | cmp -s - "$home/shown" || fail "show did not return the exact bytes of $f"
  done
  pe "$home" show src1 3 > "$home/shown" || fail 'show could not read a result file'
  printf 'result src1 3\n' | cmp -s - "$home/shown" || fail 'show changed a result file'
  if pe "$home" show src1 99 >/dev/null 2>&1; then fail 'show printed a result that never existed'; fi
  pass 'procevent: show returns a consolidated result byte for byte'

  pending=$(pe_lib fm_procevent_pending "$home/state") || fail 'pending failed after consolidation'
  assert_equals "$inbox/src1.4.result" "$pending" 'pending lists a consolidated or handled result'
  out=$(pe "$home" reconcile 2>&1) || fail "reconcile failed after consolidation: $out"
  assert_contains "$out" 'published=1 ' 'reconcile did not publish exactly the one unhandled result'
  keys=$(wake_keys "$home")
  assert_equals 1 "$(count_exact "$keys" 'procevent:src1:4')" 'reconcile did not announce the unhandled result'
  for f in src1:1 src1:2 src1:3 src2:1 src2:2; do
    assert_equals 0 "$(count_exact "$keys" "procevent:$f")" "reconcile re-announced handled result $f"
  done
  pass 'procevent: a consolidated result is never pending and never re-announced'

  path=$(capture "$home" src1 'result src1 5')
  assert_equals "$inbox/src1.5.result" "$path" 'a capture reused or skipped a sequence'
  path=$(capture "$home" src2 'result src2 3')
  assert_equals "$inbox/src2.3.result" "$path" 'a capture reused a consolidated sequence'
  for n in 1 2; do
    pe "$home" show src1 "$n" > "$home/shown" || fail "consolidated src1 $n became unreadable"
    printf 'result src1 %s\n' "$n" | cmp -s - "$home/shown" || fail "a capture replaced consolidated src1 $n"
  done
  pass 'procevent: a new capture never reuses a consolidated sequence'
}

write_handled() {  # <state> <task> <text>
  local rec
  rec=$(inbox_lib fm_task_inbox_write "$1" "$2" "$3") || fail "inbox write failed: $2"
  mv "$rec" "${rec%/*}/handled/" || fail "cannot acknowledge $rec"
  printf '%s\n' "${rec%/*}/handled/${rec##*/}"
}

test_task_inbox_readers() {
  local home="$TMP_ROOT/task-inbox" state cli reg event key out line rec base n
  new_home "$home"
  state="$home/state"; cli="$ROOT/bin/fm-task-inbox.sh"
  # t1: 001 and 002 handled and old, 003 unhandled, 004 handled but recent.
  write_handled "$state" t1 'steer one' >/dev/null
  write_handled "$state" t1 'steer two' >/dev/null
  inbox_lib fm_task_inbox_write "$state" t1 'steer three' >/dev/null || fail 'inbox write failed'
  rec=$(write_handled "$state" t1 'steer four') || fail 'cannot acknowledge 004'
  make_recent "$rec"
  cp "$state/t1.inbox/handled/001.msg" "$home/before-001"
  # t2: every record handled and old, so only the log remembers its sequences.
  write_handled "$state" t2 'first' >/dev/null
  write_handled "$state" t2 'second' >/dev/null
  # A milestone delivery the reviewer acknowledged.
  printf 'spawn_gen=author-v1\n' > "$state/author.meta"
  printf 'spawn_gen=review-v1\n' > "$state/reviewer.meta"
  reg="$home/route.json"; event="$home/event.json"
  jq -n '{schema:"fm-task-milestone-route.v1",kind:"result-receipt",request:"request-1",batch:"batch-1",
    producer:{home:"main",task:"author",generation:"author-v1"},
    consumer:{home:"main",task:"reviewer",generation:"review-v1"},
    independent:true,exclusions:[]}' > "$reg"
  key=$(printf 'PASS with limitation\n' | shasum -a 256 | awk '{print $1}')
  jq -n --arg key "$key" '{schema:"fm-task-milestone.v1",kind:"result-receipt",request:"request-1",batch:"batch-1",
    producer:{home:"main",task:"author",generation:"author-v1"}, evidence_sha256:$key,
    payload:"PASS with limitation\n"}' > "$event"
  FM_HOME="$home" "$cli" register v1 "$reg" >/dev/null || fail 'route registration failed'
  out=$(FM_HOME="$home" "$cli" deliver v1 "$event") || fail 'milestone delivery failed'
  base=$(printf '%s' "$out" | jq -r .record)
  mv "$state/reviewer.inbox/$base" "$state/reviewer.inbox/handled/" || fail 'cannot acknowledge the milestone'

  out=$(consolidate --state "$state") || fail "consolidation failed: $out"
  line=$(tree_line "$out" t1.inbox/handled)
  assert_contains "$line" 'files=2 ' 't1 run did not take exactly the two old handled records'
  assert_contains "$line" 'moved=2 skipped=0' 't1 run did not move the two old handled records'
  assert_contains "$(tree_line "$out" t2.inbox/handled)" 'moved=2 skipped=0' 't2 run did not move its records'
  assert_contains "$(tree_line "$out" reviewer.inbox/handled)" 'moved=1 skipped=0' 'the milestone was not moved'
  assert_absent "$state/t1.inbox/handled/001.msg" '001 is still a file'
  assert_absent "$state/t1.inbox/handled/002.msg" '002 is still a file'
  assert_present "$state/t1.inbox/handled/004.msg" 'a recent handled record was moved'
  assert_present "$state/t1.inbox/003.msg" 'an unhandled record was moved'
  assert_absent "$state/reviewer.inbox/handled/$base" 'the milestone record is still a file'
  pass 'task inbox: old handled records move into the log; unhandled and recent records stay files'

  inbox_lib fm_records_log_cat "$state/t1.inbox/handled" 001.msg > "$home/logged-001" \
    || fail 'the log cannot return 001'
  cmp -s "$home/before-001" "$home/logged-001" || fail 'the logged 001 differs from the handled file'
  out=$(inbox_lib fm_task_inbox_handled_body "$state/t1.inbox" 002.msg) || fail 'handled body of 002 failed'
  assert_equals 'steer two' "$out" 'the handled body of a logged record changed'
  inbox_lib fm_task_inbox_handled_has "$state/t1.inbox" 001.msg || fail 'a logged record reads as unacknowledged'
  n=0; inbox_lib fm_task_inbox_handled_has "$state/t1.inbox" 003.msg || n=$?
  assert_equals 1 "$n" 'an unhandled record reads as acknowledged'
  pass 'task inbox: a logged record reads back byte for byte and as acknowledged'

  rec=$(inbox_lib fm_task_inbox_write_idempotent "$state" t1 'steer one') || fail 'idempotent enqueue failed'
  assert_equals "$state/t1.inbox/handled/001.msg" "$rec" 'the idempotent enqueue did not find the logged record'
  assert_absent "$state/t1.inbox/005.msg" 'the idempotent enqueue wrote a duplicate of a logged record'
  rec=$(inbox_lib fm_task_inbox_write_idempotent "$state" t1 'steer five') || fail 'idempotent enqueue failed'
  assert_equals "$state/t1.inbox/005.msg" "$rec" 'a new body did not get the next sequence'
  rec=$(inbox_lib fm_task_inbox_write "$state" t2 'third') || fail 'inbox write failed'
  assert_equals "$state/t2.inbox/003.msg" "$rec" 'a logged sequence was reissued'
  pass 'task inbox: the idempotent enqueue and the sequence allocator read the log'

  out=$(FM_HOME="$home" "$cli" receipt v1 "$key") || fail "receipt failed after consolidation: $out"
  assert_equals consumed "$(printf '%s' "$out" | jq -r .outcome)" 'a consolidated milestone did not read as consumed'
  out=$(FM_HOME="$home" "$cli" deliver v1 "$event") || fail "redelivery failed after consolidation: $out"
  assert_equals consumed "$(printf '%s' "$out" | jq -r .outcome)" 'redelivery did not see the consumed milestone'
  for rec in "$state/reviewer.inbox"/*.msg; do
    [ ! -e "$rec" ] || fail "redelivery enqueued the milestone again: $rec"
  done
  pass 'task inbox: the milestone receipt and redelivery read a consolidated record as consumed'
}

# Store <names> in <tree>'s log by the production append protocol and leave
# every file in place: the state a run leaves when it stops after its commit.
commit_only() {  # <tree> <name>...
  local tree=$1
  shift
  printf '%s\n' "$@" > "$TMP_ROOT/commit-list"
  bash -c '
    . "$1/bin/fm-records-log-lib.sh"
    [ -d "$2/.records-log" ] || (umask 077; mkdir "$2/.records-log") || exit 1
    fm_records_log_run_dir_to run "$2" && fm_records_log_commit "$2" "$3" "$run" && rm -rf "$run"
  ' _ "$ROOT" "$tree" "$TMP_ROOT/commit-list" || fail "the test commit into $tree failed"
}

test_crash_and_rerun() {
  local home="$TMP_ROOT/crash" state inbox log out line n rec seg
  new_home "$home"
  state="$home/state"; inbox="$state/procevent-inbox"; log="$inbox/.records-log"
  for n in 1 2 3; do capture "$home" srcA "result srcA $n" >/dev/null; handled "$home" srcA "$n"; done
  write_handled "$state" t1 'steer one' >/dev/null
  commit_only "$inbox" srcA.1.result srcA.1.adapter srcA.2.result srcA.2.adapter
  commit_only "$state/t1.inbox/handled" 001.msg
  # The removal stopped after its first file, and an earlier run stopped
  # before its commit, leaving a segment the index does not name and scratch.
  rm "$inbox/srcA.1.result"
  for seg in "$log"/*.tgz; do cp "$seg" "$log/20000101T000000Z-1-1.tgz"; done
  [ -f "$log/20000101T000000Z-1-1.tgz" ] || fail 'the test commit wrote no segment'
  mkdir "$log/.run.crashed" && : > "$log/.run.crashed/segment"

  for n in 1 2; do
    assert_equals "already-handled: srcA $n" "$(pe "$home" handled srcA "$n")" \
      "srcA $n did not answer already-handled between commit and removal"
    pe "$home" show srcA "$n" > "$home/shown" || fail "srcA $n is unreadable between commit and removal"
    printf 'result srcA %s\n' "$n" | cmp -s - "$home/shown" || fail "srcA $n changed between commit and removal"
  done
  assert_equals '' "$(pe_lib fm_procevent_pending "$home/state")" 'a handled result became pending after a crash'
  assert_equals 'steer one' "$(inbox_lib fm_task_inbox_handled_body "$state/t1.inbox" 001.msg)" \
    'a task record is unreadable between commit and removal'
  rec=$(inbox_lib fm_task_inbox_write_idempotent "$state" t1 'steer one') || fail 'idempotent enqueue failed'
  assert_equals "$state/t1.inbox/handled/001.msg" "$rec" 'a crash left a record the idempotent enqueue duplicates'
  pass 'crash: between the log commit and file removal every record stays readable from the files, the log or both'

  out=$(consolidate --state "$state") || fail "the rerun after a crash failed: $out"
  line=$(tree_line "$out" procevent-inbox)
  assert_contains "$line" 'files=3 ' 'the rerun did not take the files the crash left'
  assert_contains "$line" 'moved=2 skipped=0' 'the rerun did not finish the interrupted records'
  assert_contains "$(tree_line "$out" t1.inbox/handled)" 'moved=1 skipped=0' 'the rerun did not finish the task record'
  for n in 1 2; do
    assert_absent "$inbox/srcA.$n.result" "srcA.$n.result is still a file"
    assert_absent "$inbox/srcA.$n.adapter" "srcA.$n.adapter is still a file"
    assert_present "$inbox/srcA.$n.handled" "srcA.$n lost its marker"
  done
  assert_present "$inbox/srcA.3.result" 'the newest result was moved'
  assert_absent "$state/t1.inbox/handled/001.msg" 'the task record is still a file'
  assert_absent "$log/20000101T000000Z-1-1.tgz" 'the uncommitted segment survived the rerun'
  assert_absent "$log/.run.crashed" 'the interrupted run scratch survived the rerun'
  assert_grep 'removed uncommitted segment(s)' "$state/records-consolidate.log" 'the recovery was not logged'
  assert_equals 1 "$(find "$log" -name '*.tgz' | wc -l | tr -d ' ')" 'the rerun stored the records a second time'
  assert_equals 5 "$(wc -l < "$log/index" | tr -d ' ')" 'the index names a record twice'
  assert_equals '' "$(awk -F '\t' 'NR > 1 { print $1 }' "$log/index" | sort | uniq -d)" 'the index names a record twice'
  pass 'crash: the rerun finishes the removal and clears the uncommitted segment without duplicates'

  cp "$log/index" "$home/index-before"
  out=$(consolidate --state "$state") || fail "the second rerun failed: $out"
  assert_contains "$(tree_line "$out" procevent-inbox)" 'files=0 ' 'a second rerun found work'
  cmp -s "$home/index-before" "$log/index" || fail 'a second rerun changed the index'
  assert_equals 1 "$(find "$log" -name '*.tgz' | wc -l | tr -d ' ')" 'a second rerun wrote a segment'
  assert_equals 'already-handled: srcA 1' "$(pe "$home" handled srcA 1)" 'a rerun lost a consolidated result'
  pass 'rerun: a further run changes nothing'

  printf 'not an index\n' > "$log/index"
  if pe "$home" show srcA 1 >/dev/null 2>&1; then fail 'show read a record from an unreadable log'; fi
  if pe "$home" handled srcA 1 >/dev/null 2>&1; then fail 'handled answered from an unreadable log'; fi
  printf 'not an index\n' > "$state/t1.inbox/handled/.records-log/index"
  n=0; inbox_lib fm_task_inbox_handled_has "$state/t1.inbox" 001.msg || n=$?
  assert_equals 2 "$n" 'an unreadable task log read as absent or present'
  if inbox_lib fm_task_inbox_write "$state" t1 'after' >/dev/null 2>&1; then
    fail 'the sequence allocator issued a sequence past an unreadable log'
  fi
  n=0; out=$(consolidate --state "$state" 2>&1) || n=$?
  assert_equals 1 "$n" 'consolidation over an unreadable log did not fail'
  assert_contains "$out" 'inspect .records-log' 'the failure does not say what to inspect'
  pass 'an unreadable log fails closed for every reader and for the tool'
}

test_dry_run() {
  local home="$TMP_ROOT/dry-run" state out
  new_home "$home"
  state="$home/state"
  build_procevent "$home"
  write_handled "$state" t1 'steer one' >/dev/null
  write_handled "$state" t1 'steer two' >/dev/null
  find "$state" -exec ls -ld {} + | sort > "$home/before"
  out=$(consolidate --dry-run --state "$state") || fail "dry run failed: $out"
  find "$state" -exec ls -ld {} + | sort > "$home/after"
  cmp -s "$home/before" "$home/after" || fail "the dry run changed the state:"$'\n'"$(diff "$home/before" "$home/after")"
  assert_contains "$(tree_line "$out" procevent-inbox)" 'files=6 bytes=60 mib<=' 'the dry run misreported the procevent tree'
  assert_contains "$(tree_line "$out" t1.inbox/handled)" 'files=2 ' 'the dry run misreported the task tree'
  assert_not_contains "$out" 'moved=' 'the dry run reported moving records'
  assert_absent "$state/procevent-inbox/.records-log" 'the dry run made a log'
  assert_absent "$state/records-consolidate.log" 'the dry run wrote the run log'
  pass 'dry run: prints files, bytes and the MiB bound per tree and changes nothing'
}

test_procevent_consolidation
test_task_inbox_readers
test_crash_and_rerun
test_dry_run

printf '\nall records-consolidate tests passed\n'
