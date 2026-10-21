#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name once per process"
}

test_file_readers_match_cat_and_od() {
  local script="$TMP_ROOT/readers.sh" quiet="$TMP_ROOT/readers-quiet.sh" cases="$TMP_ROOT/reader-cases"
  local all='' oct i interpreter out
  mkdir -p "$cases/dir"
  : > "$cases/empty"
  printf '\n' > "$cases/newline"
  printf '\n\n\n' > "$cases/newlines"
  printf 'abc' > "$cases/bare"
  printf 'abc\n' > "$cases/line"
  printf 'abc\n\n\n' > "$cases/trailing-newlines"
  printf '\n\n  a b  \n\tc\t\n' > "$cases/inner-space"
  printf 'abc\r\n' > "$cases/crlf"
  printf 'abc\r' > "$cases/cr"
  printf 'a\\b\\n\\%s' '' > "$cases/backslashes"
  printf 'a\0b\0' > "$cases/nul-separated"
  printf '\0\0\0' > "$cases/only-nuls"
  printf '\0abc' > "$cases/leading-nul"
  printf 'abc\0\n' > "$cases/nul-newline"
  printf 'abc\n\0\n' > "$cases/newline-nul-newline"
  printf 'x\001\0\177y\001\177' > "$cases/escape-bytes"
  printf '\200\377\303\251\n' > "$cases/high-bytes"
  printf '\303\0\251' > "$cases/split-utf8"
  i=1
  while [ "$i" -le 255 ]; do
    printf -v oct '%03o' "$i"
    all="$all\\0$oct"
    i=$((i + 1))
  done
  printf '%b' "$all" > "$cases/every-byte"
  printf '%b%b%b' "$all" "$all" "$all" > "$cases/every-byte-thrice"
  printf '%511s\0' '' > "$cases/size-512"
  printf '%512s\0' '' > "$cases/size-513"
  printf '%300s\0\377\0%300s\n' '' '' > "$cases/long-mixed"
  printf 'secret\n' > "$cases/unreadable"
  chmod 000 "$cases/unreadable"
  ln -s line "$cases/symlink"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for f in "$2"/* "$2/missing"; do
  { want=$(cat "$f" 2>/dev/null); wrc=$?; } 2>/dev/null
  fm_file_text_to got "$f"; grc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'text %s: helper %q (%s), cat %q (%s)\n' "${f##*/}" "$got" "$grc" "$want" "$wrc"
  want=$(od -An -v -tx1 "$f" 2>/dev/null | tr -d '[:space:]')
  wrc=0
  [ -r "$f" ] && [ ! -d "$f" ] || wrc=1
  fm_file_hex_to got "$f"; grc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'hex %s: helper %q (%s), od %q (%s)\n' "${f##*/}" "$got" "$grc" "$want" "$wrc"
done
SH
  run_everywhere "file readers" "$script" "$cases"
  # The arm reads these every half second, so an ambient LC_ALL that names an
  # uninstalled locale must not make each read print a setlocale warning.
  # Bash itself warns once at startup, before the script takes stderr.
  cat > "$quiet" <<'SH'
exec 2>"$3"
. "$1/bin/fm-wake-lib.sh"
for f in "$2"/*; do
  fm_file_text_to got "$f"
  fm_file_hex_to got "$f"
done
fm_pid_identity_to got "$$"
exec 2>&-
while IFS= read -r line; do printf 'stderr: %s\n' "$line"; done < "$3"
SH
  while IFS= read -r interpreter; do
    out=$(LC_ALL=xx_XX.UTF-8 FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$quiet" "$ROOT" "$cases" "$TMP_ROOT/quiet.err" 2>/dev/null) \
      || fail "file readers failed under $interpreter with an uninstalled LC_ALL: $out"
    [ -z "$out" ] || fail "file readers wrote to stderr under $interpreter with an uninstalled LC_ALL:"$'\n'"$out"
  done < <(test_interpreters)
  chmod 600 "$cases/unreadable"
  pass "fm_file_text_to and fm_file_hex_to read every file exactly as cat and od did, quietly in any locale"
}

test_proc_identity_matches_the_forked_reader() {
  local script="$TMP_ROOT/identity.sh" root="$TMP_ROOT/fake-proc" shim="$TMP_ROOT/identity-shim"
  local log="$TMP_ROOT/identity-spawned.log" tail tool pid
  tail='S 1 1 1 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 12345 1000 100 18446744073709551615'
  mkdir -p "$shim"
  for tool in cat od tr sed ps; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$log" "$(command -v "$tool")" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  for pid in 900000001 900000002 900000003 900000004 900000005 900000006 900000007 900000008 \
    900000009 900000011 900000012 900000013 900000014 900000015 900000016 900000017; do
    mkdir -p "$root/$pid"
    printf '%s (fm-watch.sh) %s\n' "$pid" "$tail" > "$root/$pid/stat"
    printf 'bash\0/x/bin/fm-watch.sh\0' > "$root/$pid/cmdline"
  done
  printf '900000002 (a) b) c) %s\n' "$tail" > "$root/900000002/stat"
  printf '900000003 (a\nb) %s\n' "$tail" > "$root/900000003/stat"
  printf '\303\251\377\200\001\177\0x y\0\t\n\0' > "$root/900000004/cmdline"
  : > "$root/900000005/cmdline"
  printf '900000006 (short) S 1 2 3\n' > "$root/900000006/stat"
  printf '900000007 (alpha) S 1 1 1 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 12x45 1000\n' > "$root/900000007/stat"
  printf '%511s\0' '' > "$root/900000008/cmdline"
  rm -f "$root/900000009/cmdline"
  printf '%s (bare) %s' 900000011 "$tail" > "$root/900000011/stat"
  rm -f "$root/900000012/stat"
  mkdir -p "$root/900000012/stat"
  rm -f "$root/900000013/cmdline"
  mkdir -p "$root/900000013/cmdline"
  printf '900000014 (a\0b) %s\0\n' "$tail" > "$root/900000014/stat"
  printf '900000015 (crlf) %s\r\n' "$tail" > "$root/900000015/stat"
  printf '%512s\0' '' > "$root/900000016/cmdline"
  printf 'argument-%03d\0' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 \
    26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 > "$root/900000017/cmdline"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
root=$2 shim=$3 log=$4
# The forked reader these helpers replaced, kept as the reference.
reference_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  out=$(COLUMNS=10000 LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}
counted_identity() {  # <pid>: fm_pid_identity_to with every spawned command logged
  local PATH="$shim:$PATH"
  : > "$log"
  fm_pid_identity_to got "$1"; grc=$?
}
modern=0
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  modern=1
fi
check() {  # <pid> [spawns-on-bash-4.2 spawns-before]
  local want wrc printed prc spawned
  want=$(reference_identity "$1" 2>/dev/null); wrc=$?
  counted_identity "$1"
  spawned=$(grep -c . "$log")
  printed=$(fm_pid_identity "$1" 2>/dev/null); prc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'identity_to %q: helper %q (%s), reference %q (%s)\n' "$1" "$got" "$grc" "$want" "$wrc"
  [ "$printed" = "$want" ] && [ "$prc" = "$wrc" ] \
    || printf 'identity %q: helper %q (%s), reference %q (%s)\n' "$1" "$printed" "$prc" "$want" "$wrc"
  [ "$#" -gt 1 ] || return 0
  if [ "$modern" = 1 ]; then
    [ "$spawned" -eq "$2" ] || printf 'identity_to %q spawned %s commands, not %s: %s\n' "$1" "$spawned" "$2" "$(tr '\n' ' ' < "$log")"
  else
    [ "$spawned" -eq "$3" ] || printf 'identity_to %q spawned %s commands, not %s: %s\n' "$1" "$spawned" "$3" "$(tr '\n' ' ' < "$log")"
  fi
}
FM_PROC_ROOT_OVERRIDE=$root
export FM_PROC_ROOT_OVERRIDE
for pid in 900000001 900000002 900000003 900000004 900000008 900000011 900000014 900000015; do
  check "$pid" 0 2
done
check 900000016 1 2
check 900000017 1 2
for pid in 900000005 900000006 900000007 900000009 900000010 900000012 900000013 '' abc 12a; do
  check "$pid"
done
unset FM_PROC_ROOT_OVERRIDE
check "$$"
SH
  run_everywhere "/proc identity" "$script" "$root" "$shim" "$log"
  pass "fm_pid_identity_to and fm_pid_identity match the forked reader and spawn nothing on Bash 4.2+"
}

test_path_age_helpers_match_stat_and_the_clock() {
  local script="$TMP_ROOT/path-age.sh" dir="$TMP_ROOT/path-age"
  mkdir -p "$dir/sub"
  printf 'beat\n' > "$dir/fresh"
  touch -t 200001010000 "$dir/old"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
reference_mtime() {
  if [ "$_FM_UNAME" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}
for f in "$2/fresh" "$2/old" "$2/sub" "$2/missing"; do
  want=$(reference_mtime "$f"); wrc=$?
  fm_path_mtime_to got "$f"; grc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'mtime %s: helper %q (%s), stat %q (%s)\n' "${f##*/}" "$got" "$grc" "$want" "$wrc"
  before=$(date +%s)
  fm_path_age_to age "$f"
  printed=$(fm_path_age "$f")
  after=$(date +%s)
  for got in "$age" "$printed"; do
    if [ "$wrc" -ne 0 ]; then
      [ "$got" = 999999 ] || printf 'age %s: unreadable path gave %q, not 999999\n' "${f##*/}" "$got"
      continue
    fi
    case "$got" in
      ''|*[!0-9]*) printf 'age %s: not seconds: %q\n' "${f##*/}" "$got"; continue ;;
    esac
    [ "$got" -ge $((before - want)) ] && [ "$got" -le $((after - want)) ] \
      || printf 'age %s: %s outside [%s, %s]\n' "${f##*/}" "$got" "$((before - want))" "$((after - want))"
  done
done
SH
  run_everywhere "path age helpers" "$script" "$dir"
  pass "fm_path_mtime_to, fm_path_age_to and fm_path_age agree with stat and the clock"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_file_readers_match_cat_and_od
  test_proc_identity_matches_the_forked_reader
  test_path_age_helpers_match_stat_and_the_clock
fi
