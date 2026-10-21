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
  fm_wake_signal_seen_path_to got "$state" "$f"
  [ "$got" = "$want" ] || printf 'seen path_to %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
want=$(cd "$FM_WAKE_LIB_DIR/.." && pwd)
[ "$FM_WAKE_DEFAULT_ROOT" = "$want" ] || printf 'default root: library %q, commands %q\n' "$FM_WAKE_DEFAULT_ROOT" "$want"
want=$(uname 2>/dev/null || echo unknown)
[ "$_FM_UNAME" = "$want" ] || printf 'kernel name: library %q, command %q\n' "$_FM_UNAME" "$want"
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
  fm_lock_abs_path_to got "$p" || printf 'lock path %q: the _to form failed\n' "$p"
  [ "$got" = "$want" ] || printf 'lock path %q: _to form %q, commands %q\n' "$p" "$got" "$want"
  fm_lock_owner_dir_to owner "$p" || printf 'owner dir %q: the _to form failed\n' "$p"
  case "$owner" in
    "$want".owner.??????)
      if [ -d "$owner" ]; then rmdir "$owner"; else printf 'owner dir %q: %q is no directory\n' "$p" "$owner"; fi
      ;;
    *) printf 'owner dir %q: %q is not %q.owner.XXXXXX\n' "$p" "$owner" "$want" ;;
  esac
done
for f in fm_lock_abs_path_to fm_lock_owner_dir_to; do
  got=stale
  ! "$f" got "$3/missing/x.lock" || printf '%s: a lock in a missing directory succeeded\n' "$f"
  [ -z "$got" ] || printf '%s: a lock in a missing directory left %q\n' "$f" "$got"
done
# The replaced reference: readlink and dirname in command substitutions.
reference_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}
# Each interpreter and locale reruns this script on the same directory.
rm -f "$3/abs.link" "$3/rel.link" "$3/newline.link" "$3/dangling.link"
ln -s "$3/sub" "$3/abs.link"
ln -s sub "$3/rel.link"
ln -s "sub/x.lock"$'\n' "$3/newline.link"
ln -s "$3/nowhere" "$3/dangling.link"
for l in "$3/abs.link" "$3/rel.link" rel.link ./rel.link "$3//rel.link" "$3/newline.link" \
  "$3/dangling.link" "$3/sub" "$3/missing.link"; do
  if want=$(reference_link_owner "$l"); then want="ok:$want"; else want=fail; fi
  got=stale
  if fm_lock_link_owner_to got "$l"; then got="ok:$got"; elif [ -z "$got" ]; then got=fail; fi
  [ "$got" = "$want" ] || printf 'link owner %q: _to form %q, reference %q\n' "$l" "$got" "$want"
  if got=$(fm_lock_link_owner "$l"); then got="ok:$got"; else got=fail; fi
  [ "$got" = "$want" ] || printf 'link owner %q: helper %q, reference %q\n' "$l" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths, lock paths and lock link owners are byte-identical to the command forms"
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

test_window_and_meta_readers_match_the_meta_pipelines() {
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
  printf 'kind=ship\nwindow=sess:w10\nkind=secondmate\nharness=claude\nbackend=herdr\nbackend=\n' > "$state/iota.meta"
  printf 'backend=orca\nterminal=term-11\nwindow=sess:w11\n' > "$state/kappa.meta"
  printf 'backend=orca\nwindow=sess:w12\nterminal=\n' > "$state/lambda.meta"
  printf 'window=sess:w1\nkind=secondmate\n' > "$state/mu.meta"
  printf 'window=sess:w13\nkind=\nkind=\n\n' > "$state/nu.meta"
  printf 'window=sess:w14\nharness=a\nharness=\nkind=x=y' > "$state/xi.meta"
  cat > "$script" <<'SH'
# The watcher's source guard returns before its loop, leaving every reader below.
. "$1/bin/fm-watch.sh"
state=$2
STATE=$state
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
last_value() {  # <meta> <key>: the replaced grep | tail -1 | cut -d= -f2- read
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
all_values() {  # <meta> <key>: the replaced grep | cut -d= -f2- read of every value
  grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true
}
# What the watcher's window_kind, window_backend, window_harness and
# window_label readers printed before window_resolve replaced them, each
# matching through the window's meta: sets ref_task, ref_kind, ref_backend,
# ref_harness and ref_label.
reference_resolve() {  # <window>
  local w=$1 meta
  ref_task=$(reference "$w") ref_kind=unknown ref_backend=tmux ref_harness=''
  if [ -n "$w" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      [ "$(last_value "$meta" window)" = "$w" ] || [ "$(last_value "$meta" terminal)" = "$w" ] || continue
      ref_kind=$(all_values "$meta" kind); [ -n "$ref_kind" ] || ref_kind=ship
      ref_backend=$(all_values "$meta" backend); [ -n "$ref_backend" ] || ref_backend=tmux
      ref_harness=$(all_values "$meta" harness)
      break
    done
  fi
  ref_label=${ref_task:+fm-$ref_task}
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 \
  sess:w10 sess:w11 term-11 sess:w12 sess:w13 sess:w14 sess:fm-fallback-x unknown sess: sess:fm-; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
  reference_resolve "$w"
  window_resolve "$w"
  got=$(printf 'task=%s kind=%s backend=%s harness=%s label=%s' \
    "$WR_TASK" "$WR_KIND" "$WR_BACKEND" "$WR_HARNESS" "$WR_LABEL")
  want=$(printf 'task=%s kind=%s backend=%s harness=%s label=%s' \
    "$ref_task" "$ref_kind" "$ref_backend" "$ref_harness" "$ref_label")
  [ "$got" = "$want" ] || printf 'window_resolve %q: helper %q, pipelines %q\n' "$w" "$got" "$want"
  got=$(printf 'task=%s kind=%s backend=%s label=%s' "$(window_to_task "$w" "$state")" \
    "$(window_kind "$w")" "$(window_backend "$w")" "$(window_label "$w")")
  want=$(printf 'task=%s kind=%s backend=%s label=%s' "$ref_task" "$ref_kind" "$ref_backend" "$ref_label")
  [ "$got" = "$want" ] || printf 'window_* readers %q: helpers %q, pipelines %q\n' "$w" "$got" "$want"
done
for meta in "$state"/*.meta "$state/absent.meta"; do
  for key in window terminal backend; do
    got=unset
    fm_meta_get_to got "$meta" "$key"
    want=$(last_value "$meta" "$key")
    [ "$got" = "$want" ] || printf 'fm_meta_get_to %q %s: helper %q, pipeline %q\n' "${meta##*/}" "$key" "$got" "$want"
  done
  backend=$(last_value "$meta" backend)
  backend=${backend:-tmux}
  got=unset
  fm_backend_of_meta_to got "$meta"
  [ "$got" = "$backend" ] || printf 'fm_backend_of_meta_to %q: helper %q, pipeline %q\n' "${meta##*/}" "$got" "$backend"
  want=
  [ "$backend" != orca ] || want=$(last_value "$meta" terminal)
  [ -n "$want" ] || want=$(last_value "$meta" window)
  want_rc=1
  [ -z "$want" ] || want_rc=0
  got=unset rc=0
  fm_backend_target_of_meta_to got "$meta" || rc=$?
  [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ] \
    || printf 'fm_backend_target_of_meta_to %q: helper %q rc %s, pipeline %q rc %s\n' "${meta##*/}" "$got" "$rc" "$want" "$want_rc"
done
SH
  run_everywhere "window and meta readers" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task, window_resolve and the meta _to readers match the grep/tail/cut pipelines they replaced"
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

test_status_signature_reads_once_and_matches_the_forked_reader() {
  local script="$TMP_ROOT/status-sig.sh" quiet="$TMP_ROOT/status-sig-quiet.sh" cases="$TMP_ROOT/status-sig"
  local state="$TMP_ROOT/status-sig-state" shim="$TMP_ROOT/status-sig-shim" seams="$TMP_ROOT/status-sig-seams"
  local log="$TMP_ROOT/status-sig-spawned.log" long='' i tool interpreter out
  mkdir -p "$cases/dir.status" "$state" "$shim" "$seams"
  printf 'working: one\n' > "$cases/regular.status"
  : > "$cases/empty.status"
  ln -s regular.status "$cases/ascii-link.status"
  ln -s $'caf\303\251-\342\202\254-target' "$cases/utf8-link.status"
  # A filesystem that refuses a non-UTF-8 link target just leaves the case out.
  ln -s $'raw-\377\001-target' "$cases/raw-link.status" 2>/dev/null || true
  ln -s missing-target "$cases/dangling.status"
  i=1
  while [ "$i" -le 50 ]; do
    long="${long}segment-$i/"
    i=$((i + 1))
  done
  ln -s "$long" "$cases/long-link.status"
  printf 'secret\n' > "$cases/unreadable.status"
  chmod 000 "$cases/unreadable.status"
  mkfifo "$cases/fifo.status"
  printf 'turn\n' > "$state/crew.turn-ended"
  for tool in stat readlink od tr cat; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$log" "$(command -v "$tool")" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  cat > "$seams/ident-ok" <<'SH'
#!/bin/sh
printf 'seam:%s\n' "${1##*/}"
SH
  printf '#!/bin/sh\nexit 3\n' > "$seams/ident-fail"
  printf '#!/bin/sh\nprintf " 42 \\n"\n' > "$seams/size-ok"
  printf '#!/bin/sh\nexit 4\n' > "$seams/size-fail"
  chmod +x "$seams"/*
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
_fm_wake_require_classify || { printf 'the classify library did not load\n'; exit 0; }
cases=$2 state=$3 shim=$4 log=$5 seams=$6
# The forked readers these helpers replaced, kept as the reference.
reference_ident() {
  local f=$1 epoch birth ident
  if [ -n "${FM_STATUS_IDENTITY_READER:-}" ]; then
    "$FM_STATUS_IDENTITY_READER" "$f"
    return
  fi
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    ident=$(LC_ALL=C /usr/bin/stat -f '%d:%i' "$f" 2>/dev/null) || return 1
    epoch=$(LC_ALL=C /usr/bin/stat -f '%B' "$f" 2>/dev/null) || epoch=0
    if [ "$epoch" != 0 ]; then birth=$(LC_ALL=C /usr/bin/stat -f '%FB' "$f" 2>/dev/null) || birth=''; else birth=''; fi
  else
    ident=$(LC_ALL=C stat -c '%d:%i' "$f" 2>/dev/null) || return 1
    epoch=$(LC_ALL=C stat -c '%W' "$f" 2>/dev/null) || epoch=0
    if [ "$epoch" != 0 ]; then birth=$(LC_ALL=C stat -c '%w' "$f" 2>/dev/null) || birth=''; else birth=''; fi
  fi
  case "$ident$birth" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
  if [ -n "$birth" ]; then printf 'strong:%s:%s' "$ident" "$birth"; else printf 'weak:%s' "$ident"; fi
}
reference_signature() {  # <file> [size] [identity]
  local f=$1 size=${2-} ident=${3-} path_state link_target=- access kind encoded
  if [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
    path_state=$(LC_ALL=C /usr/bin/stat -f '%HT:%p' "$f" 2>/dev/null) || path_state=stat-error
  else
    path_state=$(LC_ALL=C stat -c '%F:%f' "$f" 2>/dev/null) || path_state=stat-error
  fi
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then
    kind=absent
  elif [ ! -f "$f" ]; then
    kind=nonregular
  elif [ -r "$f" ]; then
    kind=readable
  else
    kind=unreadable
  fi
  if [ -z "$size" ]; then
    if [ -n "${FM_STATUS_SIZE_READER:-}" ]; then
      size=$("$FM_STATUS_SIZE_READER" "$f") || size='size-error'
    elif [ "$_FM_CLASSIFY_UNAME_S" = Darwin ]; then
      size=$(LC_ALL=C /usr/bin/stat -f '%z' "$f" 2>/dev/null) || size='size-error'
    else
      size=$(LC_ALL=C stat -c '%s' "$f" 2>/dev/null) || size='size-error'
    fi
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  fi
  if [ -z "$ident" ]; then
    ident=$(reference_ident "$f") || ident=identity-error
    [ -n "$ident" ] || ident=identity-error
  fi
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  encoded=$(printf '%s\0%s\0%s\0%s\0%s\0%s' \
    "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  printf 'r1:%s' "$encoded"
}
counted_signature() {  # <file> [size] [identity]: status_observed_signature_to with every spawned command logged
  local PATH="$shim:$PATH"
  : > "$log"
  status_observed_signature_to got "$@"; grc=$?
}
# Only GNU stat reads every field at once, and the expected spawns assume the
# in-shell encoder; elsewhere the values must still match.
counts=0
[ "$_FM_CLASSIFY_UNAME_S" != Linux ] || [ "$_FM_CLASSIFY_HEX_BYTEWISE" != 1 ] || counts=1
check() {  # <spawned-commands|-> <file> [size] [identity]
  local spawns=$1 want wrc printed prc spawned
  shift
  want=$(reference_signature "$@" 2>/dev/null); wrc=$?
  counted_signature "$@"
  spawned=$(sort "$log" | tr '\n' ' ')
  printed=$(status_observed_signature "$@" 2>/dev/null); prc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'signature_to %s [%s]: helper %q (%s), reference %q (%s)\n' "${1##*/}" "${*:2}" "$got" "$grc" "$want" "$wrc"
  [ "$printed" = "$want" ] && [ "$prc" = "$wrc" ] \
    || printf 'signature %s [%s]: helper %q (%s), reference %q (%s)\n' "${1##*/}" "${*:2}" "$printed" "$prc" "$want" "$wrc"
  [ "$spawns" != - ] && [ "$counts" = 1 ] || return 0
  [ "$spawned" = "$spawns" ] || printf 'signature_to %s spawned [%s], not [%s]\n' "${1##*/}" "$spawned" "$spawns"
}
for f in "$cases"/*.status "$cases/absent.status"; do
  case "${f##*/}" in
    long-link.status) spawns='od readlink stat tr ' ;;
    *-link.status|dangling.status) spawns='readlink stat ' ;;
    absent.status) spawns=- ;;
    *) spawns='stat ' ;;
  esac
  check "$spawns" "$f"
  check - "$f" 17
  check - "$f" '' 'weak:1:2'
  check - "$f" 9 'strong:1:2:x'
  for reader in ident-ok ident-fail; do
    FM_STATUS_IDENTITY_READER=$seams/$reader check - "$f"
    want=$(FM_STATUS_IDENTITY_READER=$seams/$reader reference_ident "$f"); wrc=$?
    got=$(FM_STATUS_IDENTITY_READER=$seams/$reader _fm_open_decisions_file_ident "$f"); grc=$?
    [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
      || printf 'identity %s with %s: helper %q (%s), reference %q (%s)\n' "${f##*/}" "$reader" "$got" "$grc" "$want" "$wrc"
  done
  for reader in size-ok size-fail; do
    FM_STATUS_SIZE_READER=$seams/$reader check - "$f"
  done
  want=$(reference_ident "$f"); wrc=$?
  got=$(_fm_open_decisions_file_ident "$f"); grc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'identity %s: helper %q (%s), reference %q (%s)\n' "${f##*/}" "$got" "$grc" "$want" "$wrc"
  want=$(reference_signature "$f"); wrc=$?
  fm_wake_signal_sig_to got "$f"; grc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'signal sig_to %s: helper %q (%s), reference %q (%s)\n' "${f##*/}" "$got" "$grc" "$want" "$wrc"
done
for f in "$state/crew.turn-ended" "$state/absent.turn-ended"; do
  if [ "$_FM_UNAME" = Darwin ]; then
    want=$(/usr/bin/stat -f '%z:%Fm' "$f" 2>/dev/null); wrc=$?
  else
    want=$(stat -c '%s:%Y' "$f" 2>/dev/null); wrc=$?
  fi
  fm_wake_signal_sig_to got "$f"; grc=$?
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'signal sig_to %s: helper %q (%s), stat %q (%s)\n' "${f##*/}" "$got" "$grc" "$want" "$wrc"
done
# A passed signature stands in for reading the file again, so it decides the
# answer; an empty one never matches, and neither does a missing marker.
current() {  # <expected-rc> <label> <predicate> <state> <file> [signature]
  local want=$1 label=$2 rc
  shift 2
  "$@"; rc=$?
  [ "$rc" = "$want" ] || printf '%s %s: rc %s, not %s\n' "$label" "${3##*/}" "$rc" "$want"
}
cp "$cases/regular.status" "$state/crew.status"
for f in "$state/crew.status" "$state/crew.turn-ended"; do
  fm_wake_signal_seen_path_to marker "$state" "$f"
  rm -f "$marker"
  fm_wake_signal_sig_to sig "$f"
  for predicate in fm_wake_signal_reported_current fm_wake_signal_seen_current; do
    current 1 "unmarked" "$predicate" "$state" "$f"
    current 1 "unmarked with its signature" "$predicate" "$state" "$f" "$sig"
  done
  case "$f" in
    *.status) fm_wake_status_mark_current "$state" "$f" ;;
    *) printf '%s\n' "$sig" > "$marker" ;;
  esac
  for predicate in fm_wake_signal_reported_current fm_wake_signal_seen_current; do
    current 0 "marked" "$predicate" "$state" "$f"
    current 0 "marked with its signature" "$predicate" "$state" "$f" "$sig"
    current 1 "marked with another signature" "$predicate" "$state" "$f" "${sig}0"
    current 1 "marked with an empty signature" "$predicate" "$state" "$f" ''
  done
  : > "$log"
  (PATH="$shim:$PATH"; fm_wake_signal_reported_current "$state" "$f" "$sig") \
    || printf 'reported_current %s: the marked signature did not match\n' "${f##*/}"
  [ "$counts" = 1 ] && [ -s "$log" ] && printf 'reported_current %s with its signature spawned [%s]\n' "${f##*/}" "$(tr '\n' ' ' < "$log")"
  printf 'more\n' >> "$f"
  fm_wake_signal_sig_to newsig "$f"
  for predicate in fm_wake_signal_reported_current fm_wake_signal_seen_current; do
    current 1 "changed" "$predicate" "$state" "$f"
    current 1 "changed with its new signature" "$predicate" "$state" "$f" "$newsig"
    current 0 "changed with the marked signature" "$predicate" "$state" "$f" "$sig"
  done
done
exit 0
SH
  run_everywhere "status signature" "$script" "$cases" "$state" "$shim" "$log" "$seams"
  # The watcher signs every status file each poll, so an ambient LC_ALL that
  # names an uninstalled locale must not make a signature print a setlocale
  # warning. Bash itself warns once at startup, before the script takes stderr.
  # Darwin keeps the separate per-field reads, which this does not cover.
  cat > "$quiet" <<'SH'
exec 2>"$3"
. "$1/bin/fm-wake-lib.sh"
if [ "$_FM_UNAME" = Linux ]; then
  for f in "$2"/*.status; do
    fm_wake_signal_sig_to got "$f"
  done
fi
exec 2>&-
while IFS= read -r line; do printf 'stderr: %s\n' "$line"; done < "$3"
SH
  while IFS= read -r interpreter; do
    out=$(LC_ALL=xx_XX.UTF-8 FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$quiet" "$ROOT" "$cases" "$TMP_ROOT/status-sig-quiet.err" 2>/dev/null) \
      || fail "status signatures failed under $interpreter with an uninstalled LC_ALL: $out"
    [ -z "$out" ] || fail "status signatures wrote to stderr under $interpreter with an uninstalled LC_ALL:"$'\n'"$out"
  done < <(test_interpreters)
  chmod 600 "$cases/unreadable.status"
  pass "status_observed_signature_to reads each status file once and signs it exactly as the forked readers did"
}

test_status_event_reads_match_the_tail_pipeline() {
  local script="$TMP_ROOT/status-events.sh" cases="$TMP_ROOT/status-events" i
  mkdir -p "$cases/dir.status"
  : > "$cases/empty.status"
  printf '\n  \n\t\n' > "$cases/blank.status"
  printf 'some prose\nmore prose\n' > "$cases/prose.status"
  printf 'paused: awaiting release\nPR ready https://example.com/pull/1\nMore detail: cleanup complete.\n\n' > "$cases/legacy.status"
  printf 'working: a\nneeds-decision [key=k]: b\ncontinuation\nresolved [key=k]: c\npaused: d\nmore\n' > "$cases/events.status"
  printf 'working: x\ncaptain-held [key=h]: held\nprose\n' > "$cases/captain-held.status"
  printf 'working [at=1792600000]: a\npaused [at=17:00]: b\n' > "$cases/stamped.status"
  printf 'paused: x\nparked: y\nprose\n' > "$cases/unrecognized.status"
  printf 'needs-decision corr=0123456789abcdef [key=k]: x\nresolved corr=0123456789abcdef [key=k]: y\n' > "$cases/corr.status"
  printf 'working: a\ncustom-event: ready\nprose\n' > "$cases/custom.status"
  printf 'paused [key=p]: waiting\nresolved [key=q]: other\nresolved: default\n' > "$cases/resolved-other.status"
  printf 'paused [key=p]: waiting\nresolved [key=p]: done\n' > "$cases/resolved-same.status"
  printf 'paused: waiting\nresolved: answered\n' > "$cases/resolved-keyless.status"
  printf 'paused: x\nworking: y\nresolved [key=z]: a\n' > "$cases/resolved-working.status"
  printf 'resolved: a\nresolved [key=b]: c\n' > "$cases/resolved-only.status"
  # Under a two-line window these widen past resolved lines to the whole file.
  printf 'paused: waiting\nresolved [key=a]: x\nresolved [key=b]: y\n' > "$cases/resolved-widen.status"
  printf 'paused [key=b]: waiting\nresolved [key=a]: x\nresolved [key=b]: y\n' > "$cases/resolved-widen-same.status"
  printf 'working: a\r\npaused: b\r\n\r\n' > "$cases/crlf.status"
  printf 'working: a\npau\0sed: b\n\0\n' > "$cases/nul.status"
  printf 'working: a\npaused: b' > "$cases/unterminated.status"
  printf 'working: \377\376\npaused: \303\251t\303\251\n' > "$cases/high-bytes.status"
  # Stray lead bytes: under a UTF-8 locale read takes the newline after each
  # into the character, joining lines.
  printf 'paused: x\342\nworking: y\n' > "$cases/join.status"
  printf 'working: a\npaused: x\342\n\n' > "$cases/join-trailing.status"
  printf 'working: a\360\237\npaused: b\n' > "$cases/join-four.status"
  printf 'paused: x\342\n\nresolved [key=q]: other\n' > "$cases/join-resolved.status"
  printf 'working: a\npaused: c\342' > "$cases/lead-at-end.status"
  {
    for ((i = 1; i <= 300; i++)); do printf 'prose %s\n' "$i"; done
    printf 'working: recent\n'
  } > "$cases/long-recent.status"
  {
    printf 'done: shipped\n'
    for ((i = 1; i <= 300; i++)); do printf '\n'; done
  } > "$cases/long-blank.status"
  {
    printf 'paused: at the window edge\n'
    for ((i = 1; i < 200; i++)); do printf 'prose %s\n' "$i"; done
  } > "$cases/window.status"
  {
    printf 'paused: past the window edge\n'
    for ((i = 1; i <= 200; i++)); do printf 'prose %s\n' "$i"; done
  } > "$cases/window-plus-one.status"
  ln -s legacy.status "$cases/link.status"
  ln -s missing-target "$cases/dangling.status"
  printf 'paused: secret\n' > "$cases/unreadable.status"
  chmod 000 "$cases/unreadable.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
set -u
cases=$2 out=$3
# The readers the in-shell reads replaced, kept as the reference: the tail
# pipeline into the forward event scan, the stdin walk behind
# status_declared_wait_line, and the command-substitution verb read.
reference_last() {  # <status-file> [<previous-event-var>]
  local f=$1 scan=''
  [ -f "$f" ] && [ -r "$f" ] || return 0
  if [ "$#" -gt 1 ]; then
    scan=$(_fm_status_event_scan < "$f") || :
  elif ! scan=$(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$f" 2>/dev/null | _fm_status_event_scan); then
    scan=$(_fm_status_event_scan < "$f") || :
  fi
  [ "$#" -lt 2 ] || printf -v "$2" '%s' "${scan%%$'\n'*}"
  printf '%s\n' "${scan##*$'\n'}"
}
reference_wait_scan() {  # <resolve-verb> <legacy-captain-re>
  local resolve=$1 legacy_re=$2 line verb key keys=$'\n' i=0
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    lines[i]=$line
    i=$((i + 1))
  done
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    line=${lines[i]}
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" || continue
    status_line_verb "$line" verb
    case "$verb" in
      "$resolve") ;;
      "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
      *) return 0 ;;
    esac
    key=$(_fm_decision_key "$line" "$_FM_CLASSIFY_KEYLESS_PHASE") || key=
    if [ "$verb" = "$resolve" ]; then
      keys="$keys$key"$'\n'
      continue
    fi
    case "$keys" in *$'\n'"$key"$'\n'*) return 0 ;; esac
    printf '%s\n' "$line"
    return 0
  done
  return 1
}
reference_wait() {  # <status-file>
  local f=$1 last verb resolve legacy_re
  last=$(reference_last "$f")
  if reference_verb_is "$last" "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" \
    || reference_verb_is "$last" "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}"; then
    printf '%s\n' "$last"
    return 0
  fi
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  status_line_verb "$last" verb
  [ "$verb" = "$resolve" ] || return 0
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$f" 2>/dev/null \
    | reference_wait_scan "$resolve" "$legacy_re" \
    || reference_wait_scan "$resolve" "$legacy_re" < "$f" || :
}
reference_verb_is() {  # <status-line> <verb>
  local verb
  [ -n "$1" ] || return 1
  verb=$(status_line_verb "$1")
  [ "$verb" = "$2" ]
}
reference_terminal() {  # <status-line>
  local verb
  [ -n "$1" ] || return 1
  verb=$(status_line_verb "$1")
  case "$verb" in done|needs-decision|blocked|failed) return 0 ;; esac
  return 1
}
compare() {  # <status-file>
  local f=$1 name="${1##*/} (window $FM_CLASSIFY_EVENT_WINDOW_LINES, captain re ${FM_CAPTAIN_RE-unset})"
  local want got want_prev got_prev wrc grc
  want=$(reference_last "$f"; printf '.%s' "$?")
  got=$(last_status_line "$f"; printf '.%s' "$?")
  [ "$got" = "$want" ] || printf 'last_status_line %s: %q, reference %q\n' "$name" "$got" "$want"
  want_prev=untouched got_prev=untouched
  reference_last "$f" want_prev > "$out.want"
  last_status_line "$f" got_prev > "$out.got"
  [ "$got_prev" = "$want_prev" ] && cmp -s "$out.want" "$out.got" \
    || printf 'last_status_line %s with the previous event: %q, reference %q\n' "$name" "$got_prev" "$want_prev"
  want=$(reference_last "$f")
  got=unset
  last_status_line_to got "$f" || printf 'last_status_line_to %s failed\n' "$name"
  [ "$got" = "$want" ] || printf 'last_status_line_to %s: %q, reference %q\n' "$name" "$got" "$want"
  got=unset got_prev=untouched
  last_status_line_to got "$f" got_prev
  want=$(reference_last "$f" ignored)
  [ "$got" = "$want" ] && [ "$got_prev" = "$want_prev" ] \
    || printf 'last_status_line_to %s with the previous event: %q %q, reference %q %q\n' "$name" "$got" "$got_prev" "$want" "$want_prev"
  # Every caller captures the declared wait with a command substitution, which
  # also drops the second newline the scan printed after a joined line that
  # ended in one.
  want=$(reference_wait "$f"); wrc=$?
  got=$(status_declared_wait_line "$f"); grc=$?
  [ "$got.$grc" = "$want.$wrc" ] || printf 'status_declared_wait_line %s: %q (%s), reference %q (%s)\n' "$name" "$got" "$grc" "$want" "$wrc"
  got=unset
  status_declared_wait_line_to got "$f" || printf 'status_declared_wait_line_to %s failed\n' "$name"
  [ "$got" = "$want" ] || printf 'status_declared_wait_line_to %s: %q, reference %q\n' "$name" "$got" "$want"
}
for window in 200 2; do
  FM_CLASSIFY_EVENT_WINDOW_LINES=$window
  for f in "$cases"/*.status "$cases/missing.status"; do
    compare "$f"
    FM_CAPTAIN_RE='custom-event:' compare "$f"
  done
done
FM_CLASSIFY_EVENT_WINDOW_LINES=200
# The verb predicates now assign the verb instead of capturing it.
for line in '' ' ' 'paused: x' ' paused : x' 'paused [key=a]: x' 'paused corr=0123456789abcdef [key=a]: x' \
  'corr=0123456789abcdef paused: x' 'paused corr=deadbeef: x' 'paused [at=17:00]: x' 'paused' 'Paused: x' \
  $'paused\t: x' $'paused\n: x' $'paused\r: x' 'captain-held [key=h]: x' 'done: y' 'done corr=0123456789abcdef: y' \
  'needs-decision: z' 'blocked: q' 'failed: f' 'working: w' 'awaiting: x' $'pa\303\251used: x' $'\377: x'; do
  for paused_verb in '' awaiting; do
    FM_CLASSIFY_PAUSED_VERB=$paused_verb
    status_is_paused "$line"; got=$?
    reference_verb_is "$line" "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}"; want=$?
    [ "$got" = "$want" ] || printf 'status_is_paused %q (paused verb %q): %s, reference %s\n' "$line" "$paused_verb" "$got" "$want"
  done
  FM_CLASSIFY_PAUSED_VERB=
  status_is_captain_held "$line"; got=$?
  reference_verb_is "$line" "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}"; want=$?
  [ "$got" = "$want" ] || printf 'status_is_captain_held %q: %s, reference %s\n' "$line" "$got" "$want"
  status_is_terminal_verb "$line"; got=$?
  reference_terminal "$line"; want=$?
  [ "$got" = "$want" ] || printf 'status_is_terminal_verb %q: %s, reference %s\n' "$line" "$got" "$want"
done
# A status file the event window holds is read without starting a process
# unless its lines read back joined or, for the declared wait, its latest event
# is a resolved line, whose walk still reads each key with a command
# substitution. Every command a subshell runs is logged.
spawned() {  # <command> [args...]
  : > "$out.spawned"
  (
    __spawn_level=$BASH_SUBSHELL
    set -T
    trap '[ "$BASH_SUBSHELL" -le "$__spawn_level" ] || printf "%s\n" "$BASH_COMMAND" >> "$out.spawned"' DEBUG
    "$@"
  ) > /dev/null
  [ ! -s "$out.spawned" ] || printf '%s spawned: %s\n' "$*" "$(tr '\n' ' ' < "$out.spawned")"
}
for f in empty blank prose legacy events captain-held stamped unrecognized crlf nul unterminated high-bytes window missing; do
  f="$cases/$f.status"
  spawned last_status_line "$f"
  spawned last_status_line_to got "$f"
  spawned last_status_line_to got "$f" got_prev
  spawned status_declared_wait_line "$f"
  spawned status_declared_wait_line_to got "$f"
done
exit 0
SH
  run_everywhere "status event reads" "$script" "$cases" "$TMP_ROOT/status-events-out"
  chmod 600 "$cases/unreadable.status"
  pass "status event reads match the tail pipeline they replaced and start no process for a file the window holds"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_and_meta_readers_match_the_meta_pipelines
  test_classify_stat_helpers_read_the_kernel_name_once
  test_file_readers_match_cat_and_od
  test_proc_identity_matches_the_forked_reader
  test_path_age_helpers_match_stat_and_the_clock
  test_status_signature_reads_once_and_matches_the_forked_reader
  test_status_event_reads_match_the_tail_pipeline
fi
