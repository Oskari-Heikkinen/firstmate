#!/usr/bin/env bash
# tests/fm-wake-file-ident-renumber.test.sh - behavior tests for the file identity
# every status cursor stores (bin/fm-classify-lib.sh, _fm_file_ident_compose_to).
# A device-number change under an unchanged file (a WSL restart renumbered a
# state disk) must keep every cursor kind - the OPEN DECISIONS fold cursor, the
# presentation manifest and its outcome backstop, the watcher's seen marker, the
# home-append ledger and the branch-outcome index - so no drain replays or
# refolds a whole log. A cursor stored in the older device-bearing form must
# still apply and be rewritten in the current form, a recreated file (new inode
# or new birth time) must still reset, and a reset must scan the log in one pass.
# Each case drives the real drain and the public library functions over crafted
# state, and asserts on printed output and cursor contents.
# shellcheck disable=SC2016 # the single-quoted scripts expand in the harness shell
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-file-ident-renumber-tests)

# The outcome backstop is presented only on a home that does not run the
# supervision host, so every drain here pins that posture (see
# tests/fm-wake-drain-open-decisions.test.sh).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# A stat stand-in that reports every %d as $FM_TEST_FAKE_DEV, so a test can
# renumber the device under an unchanged file. Only GNU stat is reached through
# PATH; Darwin reads /usr/bin/stat directly.
STUB_BIN="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/stat" <<SH
#!/usr/bin/env bash
args=() format=0
for arg in "\$@"; do
  if [ "\$format" = 1 ]; then arg=\${arg//%d/\${FM_TEST_FAKE_DEV:-1}}; format=0; fi
  [ "\$arg" = -c ] && format=1
  args+=("\$arg")
done
exec "$(command -v stat)" "\${args[@]}"
SH
chmod +x "$STUB_BIN/stat"

# An identity reader that prints the identity in the device-bearing form every
# cursor stored before the device was left out, with $FM_TEST_FAKE_DEV as the
# device and, when set, $FM_TEST_FAKE_BIRTH as the birth time.
OLD_READER="$TMP_ROOT/old-form-reader"
cat > "$OLD_READER" <<'SH'
#!/usr/bin/env bash
if [ "$(uname -s)" = Darwin ]; then
  ino=$(LC_ALL=C /usr/bin/stat -f '%i' "$1") || exit 1
  birth=$(LC_ALL=C /usr/bin/stat -f '%FB' "$1") || exit 1
else
  ino=$(LC_ALL=C stat -c '%i' "$1") || exit 1
  birth=$(LC_ALL=C stat -c '%w' "$1") || exit 1
fi
printf 'strong:%s:%s:%s' "${FM_TEST_FAKE_DEV:-2096}" "$ino" "${FM_TEST_FAKE_BIRTH:-$birth}"
SH
chmod +x "$OLD_READER"

lib() {  # <shell-text> [args...]: run text with the wake and classify libraries loaded
  local text=$1
  shift
  bash -c '. "$1/bin/fm-wake-lib.sh"; _fm_wake_require_classify || exit 97; shift; '"$text" _ "$ROOT" "$@"
}

current_ident() {  # <file>: the identity the library composes now
  lib '_fm_open_decisions_file_ident "$1"' "$1"
}

# A file system without birth times composes weak identities, which keep the
# device by design, so the device cases skip there.
strong_identities() {  # <file>
  case "$(current_ident "$1")" in strong:*) return 0 ;; *) return 1 ;; esac
}

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

# seed <state> <task>: a log with an open decision, an informational note, and a
# keyless captain event, last, for the outcome backstop.
seed() {
  printf 'needs-decision [key=target]: choose the release target\nnote: release context attached\ndone: delivered the build\n' \
    > "$1/$2.status"
  set_mtime $(( $(date +%s) - 20 )) "$1/$2.status"
}

# mark_watcher_and_ledger <state> <task>: the watcher's seen marker at the
# current end, plus the note's bytes recorded in the home-append ledger, so the
# log's newest event stays the backstop's done line.
mark_watcher_and_ledger() {
  lib '
    f=$1/$2.status
    start=$(printf "needs-decision [key=target]: choose the release target\n" | LC_ALL=C wc -c)
    end=$(printf "note: release context attached\n" | LC_ALL=C wc -c)
    start=${start//[[:space:]]/}; end=$((start + ${end//[[:space:]]/}))
    status_home_appends_record "$f" "$start" "$end" || exit 1
    printf "%s\t%s\n" "$start" "$end" > "$1/.test-range"
    fm_wake_status_mark_current "$1" "$f"
  ' "$1" "$2"
}

# assert_cursors_held <label> <state> <task> <out> <probe>: the second drain
# replayed nothing and folded nothing, and the watcher, ledger and backstop
# cursors still apply.
assert_cursors_held() {
  local label=$1 state=$2 task=$3 out=$4 probe=$5 range
  if ! grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || ! grep -F "$task" "$out" | grep -F '[key=target]' | grep -F 'choose the release target' >/dev/null; then
    fail "$label: the open decision was lost: $(cat "$out")"
  fi
  if grep -F 'release context attached' "$out" >/dev/null; then
    fail "$label: the presented note was replayed: $(cat "$out")"
  fi
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null; then
    fail "$label: the outcome backstop re-presented a handled event: $(cat "$out")"
  fi
  if [ -s "$probe" ]; then
    fail "$label: the OPEN DECISIONS fold re-read the log: $(cat "$probe")"
  fi
  range=$(cat "$state/.test-range")
  lib '
    f=$1/$2.status
    fm_wake_signal_reported_current "$1" "$f" || { echo "reported marker no longer current"; exit 1; }
    fm_wake_signal_seen_current "$1" "$f" || { echo "seen marker no longer current"; exit 1; }
    seen=$(fm_wake_signal_seen_size "$1" "$f")
    [ "$seen" = "$(_fm_status_file_size "$f")" ] || { echo "seen offset reset to $seen"; exit 1; }
    status_home_appends_covers "$f" "${3%%	*}" "${3#*	}" || { echo "home-append ledger discarded"; exit 1; }
  ' "$state" "$task" "$range" >"$state/.test-lib.out" 2>&1 \
    || fail "$label: $(cat "$state/.test-lib.out")"
}

test_device_renumber_keeps_every_cursor() {
  local dir state out probe
  dir=$(make_case renumber); state="$dir/state"; out="$dir/drain.out"; probe="$dir/fold-probe"
  if [ "$(uname -s)" = Darwin ]; then
    pass "device renumber through a stat stand-in is covered on GNU stat only"
    return
  fi
  seed "$state" ren
  strong_identities "$state/ren.status" || { pass "device renumber needs birth times; this file system has none"; return; }
  PATH="$STUB_BIN:$PATH" FM_TEST_FAKE_DEV=2096 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first drain failed"
  grep -F 'ren note: release context attached' "$out" >/dev/null \
    || fail "the first drain did not present the note: $(cat "$out")"
  grep -F 'ren done: delivered the build' "$out" >/dev/null \
    || fail "the first drain did not backstop the keyless event: $(cat "$out")"
  PATH="$STUB_BIN:$PATH" FM_TEST_FAKE_DEV=2096 mark_watcher_and_ledger "$state" ren \
    || fail "could not mark the watcher and ledger cursors"
  PATH="$STUB_BIN:$PATH" FM_TEST_FAKE_DEV=2096 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "settling drain failed"

  PATH="$STUB_BIN:$PATH" FM_TEST_FAKE_DEV=2112 FM_OPEN_DECISIONS_READ_PROBE="$probe" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after the renumber failed"
  PATH="$STUB_BIN:$PATH" FM_TEST_FAKE_DEV=2112 \
    assert_cursors_held "device renumber" "$state" ren "$out" "$probe"
  pass "a device renumber under an unchanged file keeps every cursor and rescans nothing"
}

test_old_form_identity_is_accepted_and_migrated() {
  local dir state out probe ident manifest_ident
  dir=$(make_case old-form); state="$dir/state"; out="$dir/drain.out"; probe="$dir/fold-probe"
  seed "$state" old
  strong_identities "$state/old.status" || { pass "the device-bearing form exists only for strong identities"; return; }
  # The outcome comes first, so the backstop never presents the done line and
  # only the branch-outcome index keeps it from presenting later.
  FM_STATUS_IDENTITY_READER="$OLD_READER" FM_STATE_OVERRIDE="$state" "$OUTCOMES" append \
    --task old --verdict captain --summary 'build reached main' >/dev/null \
    || fail "could not record a branch outcome"
  grep -F 'strong:2096:' "$state/.old.branch-outcome-index" >/dev/null \
    || fail "the branch-outcome index did not store the device-bearing identity"
  FM_STATUS_IDENTITY_READER="$OLD_READER" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain under the device-bearing identity failed"
  grep -F 'old note: release context attached' "$out" >/dev/null \
    || fail "the first drain did not present the note: $(cat "$out")"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null; then
    fail "the backstop presented an event its branch outcome covers: $(cat "$out")"
  fi
  FM_STATUS_IDENTITY_READER="$OLD_READER" mark_watcher_and_ledger "$state" old \
    || fail "could not mark the watcher and ledger cursors"
  FM_STATUS_IDENTITY_READER="$OLD_READER" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "settling drain failed"

  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain under the current identity failed"
  assert_cursors_held "device-bearing cursors" "$state" old "$out" "$probe"

  ident=$(current_ident "$state/old.status")
  case "$ident" in strong:2096:*) fail "the composed identity still carries a device: $ident" ;; esac
  grep -Fx "ident=$ident" "$state/.old.open-decisions-cursor" >/dev/null \
    || fail "the OPEN DECISIONS cursor was not rewritten in the current form: $(cat "$state/.old.open-decisions-cursor")"
  manifest_ident=$(awk -F '\t' '$1 == "old" { print $2 }' "$state/.status-presentation-cursor")
  [ "$manifest_ident" = "$ident" ] \
    || fail "the presentation manifest kept '$manifest_ident', not the current '$ident'"
  pass "a cursor stored in the device-bearing form still applies and is rewritten in the current form"
}

test_recreated_file_still_resets() {
  local dir state out probe
  dir=$(make_case recreated); state="$dir/state"; out="$dir/drain.out"; probe="$dir/fold-probe"
  seed "$state" new
  strong_identities "$state/new.status" || { pass "the device-bearing form exists only for strong identities"; return; }
  FM_STATUS_IDENTITY_READER="$OLD_READER" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first drain failed"
  grep -F 'new note: release context attached' "$out" >/dev/null \
    || fail "the first drain did not present the note: $(cat "$out")"

  # The same inode under another birth time is another file.
  FM_STATUS_IDENTITY_READER="$OLD_READER" FM_TEST_FAKE_BIRTH='2001-01-01 00:00:00.000000000 +0000' \
    FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain under a new birth time failed"
  grep -F 'new note: release context attached' "$out" >/dev/null \
    || fail "a new birth time kept the old presentation cursor: $(cat "$out")"
  [ -s "$probe" ] || fail "a new birth time kept the old OPEN DECISIONS cursor"

  # A replacement file (a new inode) after cursors stored in the device-bearing form.
  FM_STATUS_IDENTITY_READER="$OLD_READER" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "settling drain failed"
  seed "$state" new.next
  mv -f "$state/new.next.status" "$state/new.status"
  : > "$probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain after the replacement failed"
  grep -F 'new note: release context attached' "$out" >/dev/null \
    || fail "a replaced file kept the old presentation cursor: $(cat "$out")"
  [ -s "$probe" ] || fail "a replaced file kept the old OPEN DECISIONS cursor"
  pass "a new inode or a new birth time still resets every cursor"
}

test_reset_rescan_is_one_pass() {
  local dir state counts lines=20000 i
  dir=$(make_case big-log); state="$dir/state"; counts="$dir/surface-calls"
  {
    i=0
    while [ "$i" -lt "$lines" ]; do
      printf 'working: step %s of a long build\n' "$i"
      case "$i" in 5000|10000|15000) printf 'note: checkpoint %s reached\n' "$i" ;; esac
      i=$((i + 1))
    done
  } > "$state/big.status"
  : > "$counts"
  # No manifest row: the reset reads the whole log. Count how often the
  # per-line surface test runs; a per-line pass over the log would run it for
  # every one of its lines.
  FM_TEST_SURFACE_CALLS="$counts" lib '
    eval "_counted_$(declare -f status_line_is_unread_surface)"
    status_line_is_unread_surface() { printf x >> "$FM_TEST_SURFACE_CALLS"; _counted_status_line_is_unread_surface "$@"; }
    scan_unread_surface_lines "$1"
  ' "$state" > "$dir/unread.out" || fail "the unread scan failed on a large log"
  printf 'big\tnote: checkpoint %s reached\n' 5000 10000 15000 > "$dir/unread.want"
  cmp -s "$dir/unread.want" "$dir/unread.out" \
    || fail "the unread scan printed other lines than the three notes: $(cat "$dir/unread.out")"
  [ "$(wc -c < "$counts")" -le 3 ] \
    || fail "the per-line surface test ran $(wc -c < "$counts") times for 3 candidate lines"
  pass "a reset rescan of a large log filters it in one pass and tests only its candidate lines"
}

test_device_renumber_keeps_every_cursor
test_old_form_identity_is_accepted_and_migrated
test_recreated_file_still_resets
test_reset_rescan_is_one_pass
