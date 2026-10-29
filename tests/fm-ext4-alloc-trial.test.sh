#!/usr/bin/env bash
# Behavior tests for bin/fm-ext4-alloc-trial.sh (docs/disk-room.md
# "Allocator settings").
#
# The hermetic cases run as any user: argument checks, every refusal (which
# all happen before the root check), the shared mb_groups parser on a fixture
# in the kernel's own layout, and the table and answer line on fixture result
# files. The root end-to-end case runs the real trial on loop images in a
# fixture directory through passwordless `sudo -n`; it runs only on GitHub
# Actions or with FM_EXT4_TRIAL_E2E=1, so a cached sudo on a workstation never
# mounts anything, and says why when it skips.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_EXT4_TRIAL_DISK_ROOM
TRIAL="$ROOT/bin/fm-ext4-alloc-trial.sh"
DISK_ROOM="$ROOT/bin/fm-disk-room.sh"
T=$(fm_test_tmproot fm-ext4-alloc-trial) || fail "cannot create the fixture root"
GIB=1073741824
HEADER='# fm-ext4-alloc-trial-results/v1 size=8589934592 rounds=2 volume=134217728 churn=15 jobs=4 seed=1'

# run_trial ARGS...: sets OUT (stdout and stderr) and RC.
run_trial() {
  OUT=$("$TRIAL" "$@" 2>&1)
  RC=$?
}

test_arguments() {
  run_trial
  expect_code 2 "$RC" "no command"
  assert_contains "$OUT" "fm-ext4-alloc-trial.sh run --dir DIR" "usage names run"
  run_trial --help
  expect_code 0 "$RC" "--help"
  assert_contains "$OUT" "fm-ext4-alloc-trial.sh table [FILE|-]" "help names table"
  run_trial run
  expect_code 2 "$RC" "run without --dir"
  assert_contains "$OUT" "run needs --dir DIR" "run without --dir names it"
  run_trial run --dir
  expect_code 2 "$RC" "--dir without a value"
  run_trial run --dir "$T" --bogus 1
  expect_code 2 "$RC" "unknown run argument"
  assert_contains "$OUT" "unknown run argument: --bogus" "unknown argument named"
  pass "run arguments"
}

test_option_values() {
  local d=$T/opts
  mkdir -p "$d"
  run_trial run --dir "$d" --size 512M
  expect_code 2 "$RC" "image under 1G"
  run_trial run --dir "$d" --size 8X
  expect_code 2 "$RC" "bad size unit"
  run_trial run --dir "$d" --rounds 0
  expect_code 2 "$RC" "zero rounds"
  run_trial run --dir "$d" --volume 100K
  expect_code 2 "$RC" "volume under 1M"
  run_trial run --dir "$d" --jobs 65
  expect_code 2 "$RC" "too many writers"
  run_trial run --dir "$d" --churn x
  expect_code 2 "$RC" "bad churn"
  run_trial run --dir "$d" --size 4G --rounds 20 --volume 128M
  expect_code 2 "$RC" "workload larger than half the image"
  assert_contains "$OUT" "raise --size" "an oversized workload asks for a larger image"
  run_trial run --dir "$d" --settings ' '
  expect_code 2 "$RC" "empty settings"
  run_trial run --dir "$d" --settings 'default stream=1'
  expect_code 2 "$RC" "a key outside mb_*"
  assert_contains "$OUT" "bad setting stream=1" "the bad setting is named"
  run_trial run --dir "$d" --settings 'mb_group_prealloc=-1'
  expect_code 2 "$RC" "a negative value"
  run_trial run --dir "$d" --settings 'mb_Group=1'
  expect_code 2 "$RC" "a key with capitals"
  run_trial run --dir "$d" --settings 'mb_../x=1'
  expect_code 2 "$RC" "a key that walks out of sysfs"
  run_trial run --dir "$d" --results rel.tsv
  expect_code 2 "$RC" "relative results path"
  : >"$T/exists.tsv"
  run_trial run --dir "$d" --results "$T/exists.tsv"
  expect_code 2 "$RC" "existing results file"
  assert_contains "$OUT" "it exists" "an existing results file is refused"
  run_trial run --dir "$d" --results "$d/r.tsv"
  expect_code 2 "$RC" "results inside the scratch directory"
  assert_absent "$d/r.tsv" "a refused run writes no results file"
  pass "option values"
}

# refused_for REASON DIR...: each --dir is refused for REASON before the root check.
refused_for() {
  local why=$1 d
  shift
  for d in "$@"; do
    run_trial run --dir "$d"
    expect_code 2 "$RC" "--dir $d"
    assert_contains "$OUT" "refusing --dir $d:" "--dir $d is refused by name"
    assert_contains "$OUT" "$why" "--dir $d is refused for its own reason"
    assert_not_contains "$OUT" "needs root" "--dir $d is refused before the root check"
  done
}

test_refusals() {
  local out
  mkdir -p "$T/real" "$T/full" "$T/emptyok"
  : >"$T/full/x"
  : >"$T/afile"
  ln -s "$T/real" "$T/link"
  ln -s / "$T/rootlink"
  refused_for "it is /" /
  refused_for "it is on /mnt" /mnt /mnt/ /mnt/c /mnt/c/scratch /mnt/wsl/x
  refused_for "is a system directory" /proc /sys/fs /dev/shm /run/user /etc /usr/local \
    /boot /bin /sbin /lib /lib64 /root /home /home/
  refused_for "not a plain path" // /tmp/../mnt/c "$T/./real" "$T/../x" "$T/real/.."
  # Places reached only through a symbolic link are refused once resolved.
  if [ -d /sys/fs ]; then refused_for "/sys/fs is a system directory" "$T/rootlink/sys/fs"; fi
  if [ -d /mnt ]; then refused_for "it is on /mnt (/mnt)" "$T/rootlink/mnt"; fi
  refused_for "it is a symbolic link" "$T/link/"
  run_trial run --dir relative/dir
  expect_code 2 "$RC" "relative --dir"
  assert_contains "$OUT" "not an absolute path" "relative --dir names the reason"
  run_trial run --dir "$T/link"
  expect_code 2 "$RC" "symlinked --dir"
  assert_contains "$OUT" "symbolic link" "a symlinked --dir names the reason"
  run_trial run --dir "$T/full"
  expect_code 2 "$RC" "non-empty --dir"
  assert_contains "$OUT" "not empty" "a non-empty --dir names the reason"
  assert_present "$T/full/x" "a refused run leaves the directory's file alone"
  run_trial run --dir "$T/afile"
  expect_code 2 "$RC" "--dir that is a file"
  run_trial run --dir "$T/missing"
  expect_code 2 "$RC" "missing --dir"
  assert_absent "$T/missing" "a refused run creates no directory"
  if [ "$(id -u)" != 0 ]; then
    run_trial run --dir "$T/emptyok"
    expect_code 2 "$RC" "a safe --dir as a normal user"
    assert_contains "$OUT" "run needs root" "a safe --dir reaches the root check"
    out=$(ls -A "$T/emptyok")
    assert_equals "" "$out" "a run that stops at the root check creates nothing"
  fi
  pass "refusals"
}

# The kernel's own layout: a header, then groups whose number and colon are
# padded, and fourteen buddy counts in brackets.
test_shared_parser() {
  local f=$T/mb_groups out
  {
    printf '#group: free  frags first [ 2^0   2^1   2^2   2^3   2^4   2^5   2^6   2^7   2^8   2^9   2^10  2^11  2^12  2^13  ]\n'
    printf '#0    : 1000  12    7     [ 4     2     1     3     0     1     2     0     1     0     0     0     0     0     ]\n'
    printf '#1    : 32768 1     0     [ 0     0     0     0     0     0     0     0     0     0     0     0     0     4     ]\n'
    printf '#2    : 0     0     32768 [ 0     0     0     0     0     0     0     0     0     0     0     0     0     0     ]\n'
  } >"$f"
  # Fragmented: orders 0-7 of 4 KiB blocks (under 1 MiB): 4+4+4+24+32+128 = 196 blocks.
  out=$("$DISK_ROOM" mb-groups "$f" 4096)
  assert_equals "fragmented=$((196 * 4096)) free=$(((1000 + 32768) * 4096)) largest=$((8192 * 4096))" "$out" \
    "the shared parser reads the kernel layout"
  run_trial table "$f"
  expect_code 2 "$RC" "an mb_groups file is not a results file"
  pass "shared mb_groups parser"
}

# write_results FILE ROWS...: a results file with HEADER and tab-separated rows
# given with | between fields.
write_results() {
  local f=$1 row
  shift
  {
    printf '%s\n' "$HEADER"
    for row in "$@"; do printf '%s\n' "$row" | tr '|' '\t'; done
  } >"$f"
}

test_table() {
  local f=$T/results.tsv out
  write_results "$f" \
    "default|0|0|$((7 * GIB))|$((128 << 20))|$((200 << 20))|0" \
    "default|1|$((GIB / 2))|$((6 * GIB))|$((64 << 20))|$GIB|10.5" \
    "default|2|$GIB|$((5 * GIB))|$((32 << 20))|$((2 * GIB))|11.5" \
    "mb_group_prealloc=0|0|0|$((7 * GIB))|$((128 << 20))|$((200 << 20))|0" \
    "mb_group_prealloc=0|1|$((GIB / 40))|$((6 * GIB))|$((64 << 20))|$GIB|12" \
    "mb_group_prealloc=0|2|$((GIB / 20))|$((5 * GIB))|$((64 << 20))|$((2 * GIB))|13" \
    "mb_group_prealloc=16|0|0|$((7 * GIB))|$((128 << 20))|$((200 << 20))|0" \
    "mb_group_prealloc=16|1|$((GIB / 10))|$((6 * GIB))|$((64 << 20))|$GIB|30" \
    "mb_group_prealloc=16|2|$((GIB / 20))|$((5 * GIB))|$((64 << 20))|$((2 * GIB))|20" \
    "mb_group_prealloc=64|0|0|$((7 * GIB))|$((128 << 20))|$((200 << 20))|0" \
    "mb_group_prealloc=64|1|$((GIB / 4))|$((6 * GIB))|$((64 << 20))|$GIB|11" \
    "mb_stream_req=64|failed|the kernel refused mb_stream_req=64"
  run_trial table "$f"
  expect_code 0 "$RC" "table"
  assert_contains "$OUT" "fresh 8.0 GiB image per setting, 2 rounds of 128 MiB long-lived files with 15x short-lived churn, 4 writers, seed 1" \
    "the table states the workload"
  assert_contains "$OUT" "| setting | fragmented GiB after round 0..2 | growth GiB | growth vs default | used GiB | alloc s | alloc vs default | largest free MiB |" \
    "the table has its columns"
  assert_contains "$OUT" "| default | 0.000 0.500 1.000 | 1.000 | 1.00 | 2.000 | 22.0 | 1.00 | 32 |" "the default row"
  assert_contains "$OUT" "| mb_group_prealloc=0 | 0.000 0.025 0.050 | 0.050 | 0.05 | 2.000 | 25.0 | 1.14 | 64 |" \
    "a row with its ratios to the default"
  assert_contains "$OUT" "| mb_group_prealloc=16 | 0.000 0.100 0.050 | 0.050 | 0.05 | 2.000 | 50.0 | 2.27 | 64 |" \
    "growth is last round minus round 0, time is the rounds' sum"
  assert_contains "$OUT" "| mb_group_prealloc=64 | failed: incomplete |" "a setting short of its rounds is incomplete"
  assert_contains "$OUT" "| mb_stream_req=64 | failed: the kernel refused mb_stream_req=64 |" "a failed setting keeps its reason"
  assert_contains "$OUT" "answer: mb_group_prealloc=0 (fragmented growth under 10% of the default's, within twice its allocation time)" \
    "the answer names only the setting inside both limits"
  out=$("$TRIAL" table - <"$f")
  assert_equals "$OUT" "$out" "table reads stdin"

  write_results "$f" \
    "default|0|0|1|1|1|0" "default|1|100|1|1|1|1" "default|2|200|1|1|1|1" \
    "mb_group_prealloc=0|0|0|1|1|1|0" "mb_group_prealloc=0|1|10|1|1|1|1" "mb_group_prealloc=0|2|20|1|1|1|1"
  run_trial table "$f"
  assert_contains "$OUT" "answer: none:" "exactly 10% of the default's growth is not under it"

  write_results "$f" \
    "default|0|0|1|1|1|0" "default|1|100|1|1|1|1" "default|2|200|1|1|1|1" \
    "mb_group_prealloc=0|0|0|1|1|1|0" "mb_group_prealloc=0|1|0|1|1|1|2" "mb_group_prealloc=0|2|0|1|1|1|2"
  run_trial table "$f"
  assert_contains "$OUT" "answer: mb_group_prealloc=0 " "exactly twice the allocation time is within the limit"

  write_results "$f" \
    "default|0|0|1|1|1|0" "default|1|0|1|1|1|1" "default|2|0|1|1|1|1" \
    "mb_group_prealloc=0|0|0|1|1|1|0" "mb_group_prealloc=0|1|0|1|1|1|1" "mb_group_prealloc=0|2|0|1|1|1|1"
  run_trial table "$f"
  assert_contains "$OUT" "answer: unknown (the default setting shows no fragmented growth in this workload)" \
    "no default growth gives no answer"

  write_results "$f" "default|failed|mkfs.ext4 failed" \
    "mb_group_prealloc=0|0|0|1|1|1|0" "mb_group_prealloc=0|1|0|1|1|1|1" "mb_group_prealloc=0|2|0|1|1|1|1"
  run_trial table "$f"
  expect_code 0 "$RC" "table with a failed default"
  assert_contains "$OUT" "| mb_group_prealloc=0 | 0.000 0.000 0.000 | 0.000 | - | " "no ratio without a default"
  assert_contains "$OUT" "answer: unknown (the default setting did not complete)" "a failed default gives no answer"

  run_trial table "$T/no-such.tsv"
  expect_code 2 "$RC" "missing results file"
  printf 'setting\tround\n' >"$f"
  run_trial table "$f"
  expect_code 2 "$RC" "a file without the format line"
  assert_contains "$OUT" "not a fm-ext4-alloc-trial-results/v1 file" "the format is named"
  run_trial table "$f" "$f"
  expect_code 2 "$RC" "two files"
  pass "table and answer line"
}

# e2e_gate: prints why the root end-to-end case cannot run here, or nothing.
e2e_gate() {
  local tool
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${FM_EXT4_TRIAL_E2E:-}" != 1 ]; then
    echo "not on GitHub Actions and FM_EXT4_TRIAL_E2E is not 1"; return
  fi
  [ "$(uname -s)" = Linux ] || { echo "not Linux"; return; }
  sudo -n true 2>/dev/null || { echo "no passwordless sudo -n"; return; }
  for tool in mkfs.ext4 losetup mount umount mountpoint truncate python3 ionice; do
    sudo -n sh -c "command -v $tool" >/dev/null 2>&1 || { echo "root has no $tool"; return; }
  done
}

# assert_clean DIR LABEL: the trial left no image, mount or loop device.
assert_clean() {
  local left mounted loops
  left=$(sudo -n ls -A -- "$1")
  assert_equals "" "$left" "$2: the scratch directory is empty again"
  mounted=$(awk -v m="$1/mnt" '$5 == m' /proc/self/mountinfo)
  assert_equals "" "$mounted" "$2: nothing is mounted at the mount point"
  loops=$(sudo -n losetup -l -n -O NAME,BACK-FILE 2>/dev/null | awk -v img="$1/trial.img" 'index($0, img)')
  assert_equals "" "$loops" "$2: no loop device backs the image"
}

# stop_trial SIGNAL CODE BASE SCRATCH: a SIGNAL in the middle of a round
# stops the trial with CODE and still unmounts, detaches and deletes.
stop_trial() {
  local results=$3/e2e-$1.tsv pid i rc
  # shellcheck disable=SC2024 # the test user owns its own output files
  sudo -n "$TRIAL" run --dir "$4" --size 2G --rounds 3 --volume 256M --settings default \
    --results "$results" >/dev/null 2>"$T/e2e-$1.err" &
  pid=$!
  for ((i = 0; i < 1200; i++)); do
    [ "$(awk -F '\t' '$2 == "0"' "$results" 2>/dev/null | wc -l)" -ge 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  sudo -n kill "-$1" "$pid"
  wait "$pid"
  rc=$?
  if [ "$rc" -ne "$2" ]; then
    cat "$T/e2e-$1.err"
    fail "a trial stopped by $1 exited $rc, not $2"
  fi
  assert_clean "$4" "a trial stopped by $1"
}

test_root_trial() {
  local why base scratch results tablef=$T/e2e-table.txt rc s n
  why=$(e2e_gate)
  if [ -n "$why" ]; then
    echo "note: skipped the root end-to-end trial: $why"
    return 0
  fi
  # The trial refuses directories another user could swap, so root makes them.
  mkdir -p "$T/userdir"
  # shellcheck disable=SC2024 # the test user owns its own output files
  sudo -n "$TRIAL" run --dir "$T/userdir" --size 2G >"$T/e2e-owner.out" 2>&1
  rc=$?
  expect_code 2 "$rc" "a scratch directory owned by the test user"
  assert_grep "does not belong to root" "$T/e2e-owner.out" "a user-owned scratch directory is refused as root"
  base=$(sudo -n mktemp -d /var/tmp/fm-ext4-trial-test.XXXXXX) || fail "cannot make a root scratch base"
  { sudo -n chmod 755 "$base" && sudo -n mkdir "$base/scratch"; } || fail "cannot make the root scratch directory"
  scratch=$base/scratch results=$base/e2e.tsv
  # Every default setting, at a scale that fits the CI per-script timeout.
  # shellcheck disable=SC2024 # the test user owns its own output files
  sudo -n "$TRIAL" run --dir "$scratch" --size 2G --rounds 3 --volume 64M --results "$results" >"$tablef" 2>"$T/e2e.err"
  rc=$?
  echo "--- root end-to-end trial (exit $rc) ---"
  cat "$tablef"
  if [ "$rc" -ne 0 ]; then
    cat "$T/e2e.err"
    fail "the root trial exited $rc"
  fi
  for s in default mb_group_prealloc=64 mb_group_prealloc=16 mb_group_prealloc=0 mb_stream_req=64; do
    n=$(awk -F '\t' -v s="$s" '$1 == s && $2 ~ /^[0-9]+$/' "$results" | wc -l | tr -d ' ')
    assert_equals 4 "$n" "$s has round 0 and three rounds of readings"
    assert_contains "$(cat "$tablef")" "| $s | " "$s has a table row"
  done
  assert_grep "answer: " "$tablef" "the table ends with the answer line"
  assert_clean "$scratch" "a finished trial"

  # A setting the kernel does not have fails that setting after setup, and
  # the teardown still removes everything.
  # shellcheck disable=SC2024 # the test user owns its own output files
  sudo -n "$TRIAL" run --dir "$scratch" --size 1G --rounds 1 --volume 16M --settings mb_nosuchkey=1 \
    >"$T/e2e-bad.out" 2>&1
  rc=$?
  expect_code 1 "$rc" "a setting the kernel does not have"
  assert_grep "no mb_nosuchkey in /sys/fs/ext4/loop" "$T/e2e-bad.out" "the failed setting is named"
  assert_clean "$scratch" "a trial whose setting failed"

  stop_trial TERM 143 "$base" "$scratch"
  stop_trial HUP 129 "$base" "$scratch"
  sudo -n rm -f -- "$base/e2e.tsv" "$base/e2e-TERM.tsv" "$base/e2e-HUP.tsv"
  sudo -n rmdir -- "$scratch" "$base"
  pass "root end-to-end trial on loop images"
}

test_arguments
test_option_values
test_refusals
test_shared_parser
test_table
test_root_trial
