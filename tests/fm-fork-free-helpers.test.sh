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

test_directory_helper_matches_cd_and_pwd() {
  local script="$TMP_ROOT/cd-pwd.sh"
  mkdir -p "$TMP_ROOT/cd-pwd"
  cat > "$script" <<'SH'
. "$1/bin/fm-dir-lib.sh"
t=$(mktemp -d "$2/run.XXXXXX") && t=$(cd -P "$t" && pwd) || exit 1
# Invalid UTF-8 names are refused on some file systems; those shapes then
# compare two failures.
mkdir -p "$t/d/sub/deep" "$t/real/x" "$t/sp ace/x" "$t/nl"$'\n' "$t/"$'caf\xc3\xa9/z' \
  "$t/"$'\xff\xfe/y' "$t/-dash/x" "$t/..." "$t/.hid/x" "$t/shut" 2>/dev/null
chmod 600 "$t/shut"
ln -s "$t/real" "$t/link"
ln -s ../../d "$t/real/x/rel"
ln -s "$t/missing" "$t/dangling"
: > "$t/file"
check() {  # <directory>: the helper either answers what cd and pwd print or assigns nothing
  local got=unset want rc=0
  want=$(cd "$1" 2>/dev/null && pwd) || rc=$?
  if fm_cd_pwd_to got "$1"; then
    [ "$rc" -eq 0 ] && [ "$got" = "$want" ] ||
      printf 'helper %q, cd and pwd %q (exit %s) for %q\n' "$got" "$want" "$rc" "$1"
  else
    [ "$got" = unset ] || printf 'refusing %q still assigned %q\n' "$1" "$got"
  fi
}
shapes() {
  local base suffix p
  for base in "$t/d" "$t/d/sub/deep" "$t/link" "$t/link/x" "$t/link/x/rel" "$t/sp ace/x" \
    "$t/nl"$'\n' "$t/"$'caf\xc3\xa9/z' "$t/"$'\xff\xfe' "$t/-dash/x" "$t/..." "$t/.hid/x" \
    "$t/shut" "$t/shut/inner" "$t/dangling" "$t/file" "$t/missing" / "$t"; do
    for suffix in '' / /. /./ /.. /../.. /../../.. /../../../../../../../../../../.. \
      /x/.. /sub/.. //.. /../ /.././..; do
      check "$base$suffix"
    done
  done
  for p in '' . .. ./d d "$t//d" "/$t/d" "$t/./d" "$t/d/../d" // /.. "$t/d//"; do
    check "$p"
  done
}
shapes
set -o posix
shapes
set +o posix
# The shapes a caller hands it resolve without a subshell, logical links kept.
for p in "$t/d" "$t/d/sub/deep/../.." "$t/link/x/rel" "$t/link/x/rel/.." "$t/sp ace/x/../../.." \
  "$t/"$'caf\xc3\xa9/z' "$t/-dash/x" "$t/..." "$t/.hid/x/.."; do
  fm_cd_pwd_to got "$p" || printf 'no subshell-free answer for %q\n' "$p"
done
# A relative directory is CDPATH's to resolve, so the helper leaves it to cd.
cd "$t" || exit 1
CDPATH=$t/d
for p in sub d d/sub "$t/d"; do check "$p"; done
CDPATH=
# Under set -P, pwd prints the physical path, which only cd can know.
set -P
for p in "$t/link" "$t/link/x/rel/.." "$t/d"; do
  got=unset
  fm_cd_pwd_to got "$p" && printf 'under set -P the helper answered %q for %q\n' "$got" "$p"
  check "$p"
done
set +P
log=$t/subshells
saved_path=$PATH
__level=$BASH_SUBSHELL
set -T
trap '[ "$BASH_SUBSHELL" -le "$__level" ] || printf "%s\n" "$BASH_COMMAND" >> "$log"' DEBUG
PATH=$t/missing
fm_cd_pwd_to got "$t/link/x/rel/.."
want_ok=$?
fm_cd_pwd_to got sub
PATH=$saved_path
trap - DEBUG
set +T
[ "$want_ok" -eq 0 ] && [ "$got" = "$t/link/x" ] || printf 'without PATH the helper answered %q (exit %s)\n' "$got" "$want_ok"
[ ! -s "$log" ] || printf 'the helper ran subshell commands: %s\n' "$(tr '\n' ' ' < "$log")"
chmod 700 "$t/shut"
SH
  run_everywhere "directory helper" "$script" "$TMP_ROOT/cd-pwd"
  pass "fm_cd_pwd_to answers what cd and pwd print, without a subshell or PATH, or assigns nothing"
}

test_library_loads_match_the_subshells_they_replaced() {
  local script="$TMP_ROOT/library-loads.sh" dir="$TMP_ROOT/library-loads"
  mkdir -p "$dir/root" "$dir/noisy"
  ln -s "$ROOT" "$dir/link"
  ln -s "$ROOT/bin" "$dir/root/bin"
  printf '#!/bin/sh\necho "uname: unavailable" >&2\nexit 1\n' > "$dir/noisy/uname"
  chmod +x "$dir/noisy/uname"
  cat > "$script" <<'SH'
root=$1 dir=$2 log=$2/subshells.$$
cd "$dir" || exit 1
unset FM_ROOT FM_ROOT_OVERRIDE
expect() {  # <label> <want> <got>
  [ "$2" = "$3" ] || printf '%s: %q, not %q\n' "$1" "$3" "$2"
}
load_subshells() {  # <first-library-or-empty> <library>...: subshell commands loading each library runs
  (
    [ -z "$1" ] || . "$1"
    shift
    : > "$log"
    __level=$BASH_SUBSHELL
    set -T
    trap '[ "$BASH_SUBSHELL" -le "$__level" ] || printf "%s\n" "$BASH_COMMAND" >> "$log"' DEBUG
    for lib in "$@"; do . "$lib"; done
  ) > /dev/null 2>&1
  grep -c . "$log" || true
}
# A library under a linked, relative or dotted bin resolves what cd and pwd
# print there, whether or not the caller loaded fm-dir-lib.sh first.
for bin in "$root/bin" link/bin "$dir/link/bin" "$dir/root/bin" "$dir/link/bin/../bin"; do
  want=$(cd "$bin/.." && pwd)
  for first in '' "$root/bin/fm-dir-lib.sh"; do
    got=$([ -z "$first" ] || . "$first"; . "$bin/fm-backend.sh"; printf '%s' "$FM_ROOT")
    expect "fm-backend.sh root from $bin${first:+ after fm-dir-lib.sh}" "$want" "$got"
    got=$([ -z "$first" ] || . "$first"; . "$bin/fm-dod-lib.sh"; fm_worker_guide_ref x)
    expect "fm_worker_guide_ref from $bin${first:+ after fm-dir-lib.sh}" \
      "$want/.agents/skills/worker-guide/references/x.md" "$got"
  done
done
without=$(load_subshells '' "$root/bin/fm-backend.sh")
with=$(load_subshells "$root/bin/fm-dir-lib.sh" "$root/bin/fm-backend.sh")
[ "$with" -lt "$without" ] ||
  printf 'fm-backend.sh ran %s subshell commands after fm-dir-lib.sh, %s without it\n' "$with" "$without"
siblings=$(load_subshells '' "$root/bin/fm-pr-lib.sh" "$root/bin/fm-classify-lib.sh" \
  "$root/bin/fm-nm-run-lib.sh" "$root/bin/fm-brief-heading-lib.sh")
dod=$(load_subshells '' "$root/bin/fm-dod-lib.sh")
[ $((dod - siblings)) -le 4 ] ||
  printf 'fm-dod-lib.sh ran %s subshell commands of its own, more than one directory resolution\n' "$((dod - siblings))"
composer=$(load_subshells '' "$root/bin/fm-composer-lib.sh")
[ "$composer" -eq 0 ] || printf 'loading fm-composer-lib.sh ran %s subshell commands\n' "$composer"
# The prompt glyph sets hold exactly what their printf lists printed.
. "$root/bin/fm-composer-lib.sh"
while IFS= read -r glyph; do
  fm_composer_leading_agent_glyph_var got "  $glyph hello" || printf 'agent glyph %q unread\n' "$glyph"
  expect "agent glyph" "$glyph" "$got"
  fm_composer_leading_prompt_glyph_var got "$glyph"
  expect "prompt glyph" "$glyph" "$got"
  fm_composer_leading_shell_glyph_var got "$glyph" && printf 'agent glyph %q read as a shell glyph\n' "$glyph"
done <<EOF
$(printf '%s\n' '❯' '›' '⟩' '→' '❭')
EOF
while IFS= read -r glyph; do
  fm_composer_leading_shell_glyph_var got "$glyph ls" || printf 'shell glyph %q unread\n' "$glyph"
  expect "shell glyph" "$glyph" "$got"
  fm_composer_leading_prompt_glyph_var got " $glyph"
  expect "prompt glyph" "$glyph" "$got"
  fm_composer_leading_agent_glyph_var got "$glyph" && printf 'shell glyph %q read as an agent glyph\n' "$glyph"
done <<EOF
$(printf '%s\n' '>' '$' '%' '#')
EOF
for text in '' x '*' '-' "$(printf '\302\273')" "$(printf '\342\235')"; do
  fm_composer_leading_prompt_glyph_var got "$text" && printf '%q read as prompt glyph %q\n' "$text" "$got"
done
# A failing uname leaves the classify library's load silent.
out=$(PATH="$dir/noisy:$PATH"; unset _FM_UNAME; . "$root/bin/fm-classify-lib.sh" 2>&1)
expect "classify library load output with a failing uname" '' "$out"
rm -f "$log"
SH
  run_everywhere "library loads" "$script" "$dir"
  pass "fm-backend.sh, fm-dod-lib.sh, fm-composer-lib.sh and fm-classify-lib.sh load as before with fewer subshells"
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

test_engine_identity_matches_the_pipeline_it_replaced() {
  local script="$TMP_ROOT/engine-identity.sh" root="$TMP_ROOT/engine-proc" noproc="$TMP_ROOT/engine-noproc"
  local cases="$TMP_ROOT/engine-ps-cases" shim="$TMP_ROOT/engine-identity-shim" log="$TMP_ROOT/engine-identity-spawned.log"
  local tail tool pid
  tail='S 1 1 1 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 12345 1000 100 18446744073709551615'
  mkdir -p "$shim" "$noproc" "$cases"
  for tool in cat od tr sed; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$log" "$(command -v "$tool")" > "$shim/$tool"
    chmod +x "$shim/$tool"
  done
  # Where there is no /proc entry the identity is ps's line; this ps prints
  # the case file named by its -p argument and runs the real ps for any other.
  cat > "$shim/ps" <<SH
#!/bin/sh
printf 'ps\n' >> "$log"
pid= prev=
for arg in "\$@"; do
  [ "\$prev" = -p ] && pid=\$arg
  prev=\$arg
done
[ -f "$cases/\$pid" ] || exec "$(command -v ps)" "\$@"
exec "$(command -v cat)" "$cases/\$pid"
SH
  chmod +x "$shim/ps"
  for pid in 900000101 900000102 900000103; do
    mkdir -p "$root/$pid"
    printf '%s (fm-watch-arm.sh) %s\n' "$pid" "$tail" > "$root/$pid/stat"
  done
  printf 'bash\0/x/bin/fm-watch-arm.sh\0--take-over\0' > "$root/900000101/cmdline"
  printf 'a\tb\nc \0 \0' > "$root/900000102/cmdline"
  : > "$root/900000103/cmdline"
  printf '  Thu Oct 22 06:37:27 2026 /bin/bash /x/bin/fm-watch-arm.sh\n' > "$cases/800000001"
  printf 'Thu Oct 22 06:37:27 2026 bash\targ\twith tabs\n' > "$cases/800000002"
  printf 'Thu Oct 22 06:37:27 2026 ends in spaces   \n' > "$cases/800000003"
  printf 'Thu Oct 22 06:37:27 2026 ends in a tab\t\n' > "$cases/800000004"
  printf 'Thu Oct 22 06:37:27 2026 first line\n   second line \t \n' > "$cases/800000005"
  printf '   \n' > "$cases/800000006"
  printf 'Thu Oct 22 06:37:27 2026 caf\303\251 nbsp\302\240\n' > "$cases/800000007"
  printf 'Thu Oct 22 06:37:27 2026 cr\r\n' > "$cases/800000008"
  printf 'Thu Oct 22 06:37:27 2026 x \t \n \t\n\n' > "$cases/800000009"
  printf '\n\n' > "$cases/800000010"
  : > "$cases/800000011"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-supervision-engine-lib.sh"
root=$2 noproc=$3 shim=$4 log=$5
# The pipeline the printing _fm_engine_identity ran before
# _fm_engine_identity_to replaced it, kept as the reference.
reference_identity() {
  local identity
  identity=$(fm_pid_identity "$1" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" | tr '\t\n' '  ' | sed 's/ *$//'
}
modern=0
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  modern=1
fi
check() {  # <pid> [spawned-on-bash-4.2 spawned-before]: the spawned commands, space-separated
  local want wrc got grc spawned='' tool PATH="$shim:$PATH"
  want=$(reference_identity "$1"); wrc=$?
  : > "$log"
  _fm_engine_identity_to got "$1"; grc=$?
  while IFS= read -r tool; do spawned="$spawned$tool "; done < "$log"
  [ "$got" = "$want" ] && [ "$grc" = "$wrc" ] \
    || printf 'engine identity_to %q: helper %q (%s), reference %q (%s)\n' "$1" "$got" "$grc" "$want" "$wrc"
  [ "$#" -gt 1 ] || return 0
  if [ "$modern" = 1 ]; then
    [ "$spawned" = "$2" ] || printf 'engine identity_to %q spawned [%s], not [%s]\n' "$1" "$spawned" "$2"
  else
    [ "$spawned" = "$3" ] || printf 'engine identity_to %q spawned [%s], not [%s]\n' "$1" "$spawned" "$3"
  fi
}
FM_PROC_ROOT_OVERRIDE=$root
export FM_PROC_ROOT_OVERRIDE
check 900000101 '' 'cat od '
check 900000102 '' 'cat od '
check 900000103
check 900000104
FM_PROC_ROOT_OVERRIDE=$noproc
for pid in 800000001 800000002 800000003 800000004 800000005 800000007 800000008 800000009; do
  check "$pid" 'ps sed ' 'ps sed '
done
for pid in 800000006 800000010 800000011 800000012 '' abc; do
  check "$pid"
done
unset FM_PROC_ROOT_OVERRIDE
check "$$"
SH
  run_everywhere "engine identity" "$script" "$root" "$noproc" "$shim" "$log"
  pass "_fm_engine_identity_to matches the printf | tr | sed pipeline it replaced and spawns nothing on the /proc path on Bash 4.2+"
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
. "$1/bin/fm-wake-drain-lib.sh"
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
  if [ -n "$birth" ]; then printf 'strong:%s:%s' "${ident#*:}" "$birth"; else printf 'weak:%s' "$ident"; fi
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
# The optional annotation batch reuses exactly this signature policy, including
# empty files, under each interpreter/locale admitted by run_everywhere.
if [ "$_FM_CLASSIFY_UNAME_S" = Linux ] && [ "$_FM_CLASSIFY_HEX_BYTEWISE" = 1 ]; then
  want=$(reference_signature "$cases/regular.status"; printf '\n'; reference_signature "$cases/empty.status")
  : > "$log"
  got=$(PATH="$shim:$PATH" status_observed_signatures_batch "$cases/regular.status" "$cases/empty.status"); grc=$?
  [ "$grc" = 0 ] && [ "$got" = "$want" ] \
    || printf 'signature batch differs: helper %q (%s), reference %q\n' "$got" "$grc" "$want"
  spawned=$(sort "$log" | tr '\n' ' ')
  [ "$spawned" = 'stat ' ] || printf 'signature batch spawned [%s], not one stat\n' "$spawned"
  : > "$log"
  got=$(PATH="$shim:$PATH" status_observed_signatures_batch); grc=$?
  [ "$grc" = 0 ] && [ -z "$got" ] && [ ! -s "$log" ] || printf 'empty signature batch read a path\n'
else
  got=$(status_observed_signatures_batch "$cases/regular.status"); grc=$?
  [ "$grc" != 0 ] && [ -z "$got" ] || printf 'unsupported signature batch did not refuse\n'
fi
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
  # A marker written while the identity still carried the device number is
  # current for the same file under any device number, and not for another inode.
  case "$f" in
    *.status)
      ident=$(_fm_open_decisions_file_ident "$f")
      rest=${ident#strong:}
      if [ "$rest" != "$ident" ]; then
        status_observed_signature_to oldsig "$f" '' "strong:2096:$rest"
        status_presentation_marker_report "$marker" "$oldsig"
        current 0 "marked in the device-bearing form" fm_wake_signal_reported_current "$state" "$f"
        status_observed_signature_to oldsig "$f" '' "strong:2096:9$rest"
        status_presentation_marker_report "$marker" "$oldsig"
        current 1 "marked for another inode" fm_wake_signal_reported_current "$state" "$f"
        # The same inode under another birth time is a recreated file, in
        # either form.
        status_observed_signature_to oldsig "$f" '' "strong:2096:${rest%%:*}:2001-01-01 00:00:00.000000000 +0000"
        status_presentation_marker_report "$marker" "$oldsig"
        current 1 "marked in the device-bearing form for another birth time" fm_wake_signal_reported_current "$state" "$f"
        status_observed_signature_to oldsig "$f" '' "strong:${rest%%:*}:2001-01-01 00:00:00.000000000 +0000"
        status_presentation_marker_report "$marker" "$oldsig"
        current 1 "marked for another birth time" fm_wake_signal_reported_current "$state" "$f"
        fm_wake_status_mark_current "$state" "$f"
      fi
      ;;
  esac
  printf 'more\n' >> "$f"
  fm_wake_signal_sig_to newsig "$f"
  for predicate in fm_wake_signal_reported_current fm_wake_signal_seen_current; do
    current 1 "changed" "$predicate" "$state" "$f"
    current 1 "changed with its new signature" "$predicate" "$state" "$f" "$newsig"
    current 0 "changed with the marked signature" "$predicate" "$state" "$f" "$sig"
  done
done
# Late native acknowledgement freshness compares exactly the old text reader's
# normalized bytes, not file metadata, a status span or a reported-only policy.
fm_wake_signal_seen_path_to marker "$state" "$state/crew.status"
raw=$(cat "$marker")
hex=$(printf '%s' "$raw" | LC_ALL=C od -An -v -tx1 | tr -d ' \n')
evidence=$(printf 'crew\th:%s\n' "$hex")
if [ "$_FM_CLASSIFY_HEX_BYTEWISE" = 1 ]; then
  : > "$log"
  (PATH="$shim:$PATH"; fm_wake_classification_markers_current "$state" "$evidence") \
    || printf 'late classification evidence did not match the old marker reader\n'
  [ ! -s "$log" ] || printf 'late classification evidence spawned a per-row helper\n'
  printf '%s\n\n' "$raw" > "$marker"
  fm_wake_classification_markers_current "$state" "$evidence" \
    || printf 'late classification evidence changed on trailing newlines\n'
  printf 'malformed\n' > "$marker"
  fm_wake_classification_markers_current "$state" "$evidence" \
    && printf 'late malformed marker retained native acknowledgement\n'
  rm -f "$marker"
  fm_wake_classification_markers_current "$state" "$evidence" \
    && printf 'late deleted marker retained native acknowledgement\n'
  evidence=$(printf 'crew\t-\n')
  fm_wake_classification_markers_current "$state" "$evidence" \
    || printf 'stable missing marker refused native acknowledgement\n'
else
  fm_wake_classification_markers_current "$state" "$evidence" \
    && printf 'unsupported late classification evidence did not refuse\n'
fi
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

test_unread_line_scan_matches_the_loop_it_replaced() {
  local script="$TMP_ROOT/unread-scan.sh" cases="$TMP_ROOT/unread-scan-cases"
  mkdir -p "$cases"
  printf '%s\n' 'note: first' '' '   ' $'\t' $'\r' $'\v\f' 'working: progress' \
    '  note [corr=0123456789abcdef]: indented ack' $'\tnote: tabbed' 'notes: not a note' \
    'resolved [key=pending-reply-ab]: pending-reply-ab: closed' 'resolved [key=other]: closed' \
    'captain-held [key=pending-reply-cd]: pending-reply-cd: held' 'done: finished' \
    'blocked: stuck' $'note: caf\xc3\xa9' $'\xe3\x80\x80note: after an ideographic space' \
    $'note: \xff\xfe invalid bytes' > "$cases/mixed.status"
  printf 'note: no final newline' >> "$cases/mixed.status"
  printf 'note: before\n\034\nnote: after\n' > "$cases/separator-only.status"
  printf 'note: before\n\342\200\200 \nnote: after\n' > "$cases/multibyte-space-only.status"
  printf 'note: before\nno\000te: nul\nnote: after\n' > "$cases/nul.status"
  printf 'note: before\n\000\000\000\n\000\000note: after zeros\n \000\t\nnote: last\n\000\000\000\000' > "$cases/nul-tail.status"
  printf '\n\n  \n' > "$cases/blank.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
_fm_wake_require_classify || { printf 'the classify library did not load\n'; exit 0; }
out=$3
# The per-line loops the single pass replaced, kept as the reference.
reference_lines() {  # <status-file>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) printf '%s\n' "$line" ;; esac
  done < "$1"
}
surface() {  # <kind>: the unread-surface filter over standard input
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    status_line_is_unread_surface "$line" "$1" || continue
    printf '%s\n' "$line"
  done
}
for f in "$2"/*.status; do
  reference_lines "$f" > "$out/want" 2>/dev/null
  status_new_lines_since_cursor "$f" > "$out/got" 2>/dev/null \
    || printf 'lines %s: the scan failed\n' "${f##*/}"
  cmp -s "$out/want" "$out/got" || printf 'lines %s: the single pass differs from the loop\n' "${f##*/}"
  for kind in ship secondmate; do
    verbs='note resolved captain-held'
    [ "$kind" = ship ] || verbs="$verbs working"
    surface "$kind" < "$out/want" > "$out/want-surface"
    # shellcheck disable=SC2086 # One argument per verb.
    status_new_lines_since_cursor "$f" '' $verbs 2>/dev/null | surface "$kind" > "$out/got-surface"
    cmp -s "$out/want-surface" "$out/got-surface" \
      || printf 'surface %s (%s): the verb-filtered pass admits other lines\n' "${f##*/}" "$kind"
  done
done
exit 0
SH
  mkdir -p "$TMP_ROOT/unread-scan-out"
  run_everywhere "unread line scan" "$script" "$cases" "$TMP_ROOT/unread-scan-out"
  pass "status_new_lines_since_cursor prints, in one pass, exactly the lines the per-line loop printed"
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

test_watcher_poll_helpers_match_what_they_replaced() {
  local script="$TMP_ROOT/poll-helpers.sh" dir="$TMP_ROOT/poll-helpers" shim="$TMP_ROOT/poll-helpers-md5"
  local log="$TMP_ROOT/poll-helpers-md5.log" count_shim="$TMP_ROOT/poll-helpers-count"
  local count_log="$TMP_ROOT/poll-helpers-count.log" tool path
  mkdir -p "$dir/sub" "$dir/state" "$shim" "$count_shim"
  printf 'beat\n' > "$dir/fresh"
  touch -t 200001010000 "$dir/old"
  touch -t 209901010000 "$dir/future"
  ln -s missing-target "$dir/dangling"
  # What md5 -q prints, logged, so a host that ships only md5sum also runs the
  # md5 branch the watcher picks when it loads.
  cat > "$shim/md5" <<SH
#!/bin/sh
printf 'md5\n' >> "$log"
[ "\$1" = -q ] || exit 2
sum=\$(md5sum) || exit 1
printf '%s\n' "\${sum%% *}"
SH
  chmod +x "$shim/md5"
  for tool in rm stat date md5sum md5 cut cat; do
    path=$(command -v "$tool") || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$count_log" "$path" > "$count_shim/$tool"
    chmod +x "$count_shim/$tool"
  done
  cat > "$script" <<'SH'
md5_shim=$3 md5_log=$4 count_shim=$5 count_log=$6
[ -z "$md5_shim" ] || PATH="$md5_shim:$PATH"
# The watcher's source guard returns before its loop, leaving every helper below.
. "$1/bin/fm-watch.sh"
dir=$2
STATE=$dir/state
hash_pane() {  # the replaced hash reader
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}
reference_key() {  # the replaced window_key body
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}
long=''
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  long="$long  line $i of a pane, \$ % \\ ${i}0%"$'\n\n'
done
for t in '' a ' ' $'\n' $'line\n' $'two\nlines\n\n' -n '%s %d \' $'caf\xc3\xa9 \xff\xfe' "$long"; do
  want=$(printf '%s' "$t" | hash_pane)
  [ -z "$md5_log" ] || : > "$md5_log"
  got=unset
  hash_pane_to got "$t"
  [ "$got" = "$want" ] || printf 'hash %q: helper %q, pipeline %q\n' "$t" "$got" "$want"
  [ -z "$md5_shim" ] || [ -s "$md5_log" ] || printf 'hash %q: md5 on PATH at load, but the helper did not run it\n' "$t"
done
# The staleness pass's memory: a slot answers its own unchanged text with the
# pipeline's hash, and a changed text, down to one trailing newline, is hashed
# again.
slot=0
for t in '' a ' ' $'\n' $'line\n' $'two\nlines\n\n' -n '%s %d \' $'caf\xc3\xa9 \xff\xfe' "$long"; do
  slot=$((slot + 1))
  for u in "$t" "$t" "$t"$'\n' "$t"; do
    want=$(printf '%s' "$u" | hash_pane)
    got=unset
    hash_pane_memo_to got "$slot" "$u"
    [ "$got" = "$want" ] || printf 'memo hash %q in slot %s: helper %q, pipeline %q\n' "$u" "$slot" "$got" "$want"
  done
done
# A failed hash is passed on and never kept, so the slot is hashed again.
saved_path=$PATH
PATH=$dir/no-tools
got=unset
hash_pane_memo_to got 1 x 2>/dev/null
PATH=$saved_path
[ -z "$got" ] || printf 'memo hash with no md5 tool gave %q\n' "$got"
for u in '' x; do
  want=$(printf '%s' "$u" | hash_pane)
  got=unset
  hash_pane_memo_to got 1 "$u"
  [ "$got" = "$want" ] || printf 'memo hash %q after a failed hash: helper %q, pipeline %q\n' "$u" "$got" "$want"
done
for w in '' sess:w1 a/b.c:d ... ::: x:y/z.w fm-x sess:fm-a.b/c $'caf\xc3\xa9:\xff.x' '%s/%d'; do
  want=$(reference_key "$w")
  got=unset
  window_key_to got "$w"
  [ "$got" = "$want" ] || printf 'window_key_to %q: helper %q, reference %q\n' "$w" "$got" "$want"
  got=$(window_key "$w")
  [ "$got" = "$want" ] || printf 'window_key %q: printed %q, reference %q\n' "$w" "$got" "$want"
done
for f in "$dir/fresh" "$dir/old" "$dir/future" "$dir/sub" "$dir/dangling" "$dir/missing"; do
  m=$(stat_mtime "$f"); mrc=$?
  before=$(date +%s)
  got=unset
  age_of_to got "$f"; grc=$?
  printed=$(age_of "$f")
  after=$(date +%s)
  [ "$grc" = 0 ] || printf 'age_of_to %s returned %s\n' "${f##*/}" "$grc"
  for age in "$got" "$printed"; do
    if [ "$mrc" -ne 0 ] || [ "$m" -gt "$before" ]; then
      [ "$age" = 999999 ] || printf 'age %s: unreadable or future mtime gave %q, not 999999\n' "${f##*/}" "$age"
      continue
    fi
    case "$age" in
      ''|*[!0-9]*) printf 'age %s: not seconds: %q\n' "${f##*/}" "$age"; continue ;;
    esac
    [ "$age" -ge $((before - m)) ] && [ "$age" -le $((after - m)) ] \
      || printf 'age %s: %s outside [%s, %s]\n' "${f##*/}" "$age" "$((before - m))" "$((after - m))"
  done
done
r="$dir/rm-$$"
mkdir -p "$r/dir" "$r/dir2"
: > "$r/a"
ln -s missing "$r/link"
fm_rm_present "$r/a" "$r/none"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$r/a" ] || printf 'fm_rm_present kept a present file (status %s)\n' "$rc"
fm_rm_present "$r/none" "$r/link"; rc=$?
[ "$rc" = 0 ] && [ ! -L "$r/link" ] || printf 'fm_rm_present kept a dangling link (status %s)\n' "$rc"
fm_rm_present "$r/none" "$r/none2"; rc=$?
[ "$rc" = 0 ] || printf 'fm_rm_present of absent paths returned %s\n' "$rc"
# The loop's heartbeat streak and lock owner reads, each against the command
# substitution it replaced.
mkdir -p "$r/text/dir"
: > "$r/text/empty"
printf '3' > "$r/text/bare"
printf '3\n' > "$r/text/line"
printf '3\n\n' > "$r/text/lines"
printf 'a b\n' > "$r/text/spaced"
for f in "$r/text"/* "$r/text/missing"; do
  want=$(cat "$f" 2>/dev/null || echo 0)
  got=unset
  fm_file_text_to got "$f" || got=0
  [ "$got" = "$want" ] || printf 'streak read %s: helper %q, substitution %q\n' "${f##*/}" "$got" "$want"
  want=$(cat "$f" 2>/dev/null || true)
  got=unset
  fm_file_text_to got "$f" || true
  [ "$got" = "$want" ] || printf 'lock owner read %s: helper %q, substitution %q\n' "${f##*/}" "$got" "$want"
done
rm -f "$r/dir2" 2>/dev/null; want=$?
fm_rm_present "$r/dir" "$r/none" 2>/dev/null; rc=$?
[ "$rc" = "$want" ] || printf 'fm_rm_present of a directory returned %s, rm -f %s\n' "$rc" "$want"
: > "$STATE/.writing-since-k$$"
: > "$STATE/.writing-resurfaced-k$$"
clear_write_tracking "k$$"
[ ! -e "$STATE/.writing-since-k$$" ] && [ ! -e "$STATE/.writing-resurfaced-k$$" ] \
  || printf 'clear_write_tracking kept a marker\n'
# Run <command> with every tool it starts through PATH, and every command one
# of its subshells runs, logged: TOOLS lists the tools, SUBSHELLS counts the
# subshell commands.
counted() {  # <command> [args...]
  : > "$count_log"
  : > "$count_log.sub"
  (
    PATH="$count_shim:$PATH"
    __spawn_level=$BASH_SUBSHELL
    set -T
    trap '[ "$BASH_SUBSHELL" -le "$__spawn_level" ] || printf "%s\n" "$BASH_COMMAND" >> "$count_log.sub"' DEBUG
    "$@"
  ) > /dev/null 2>&1
  TOOLS=$(sort "$count_log" | tr '\n' ' ')
  SUBSHELLS=$(grep -c . "$count_log.sub" || true)
}
counted window_key_to got sess:w.1/x
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'window_key_to ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
counted fm_rm_present "$r/none" "$r/none2"
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'fm_rm_present of absent paths ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
counted clear_write_tracking absent-key
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'clear_write_tracking with no markers ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
# clear_pause_tracking's own stale and wedge markers, with clear_pause_state's
# separate clear set aside: no rm while they are absent, all of them gone when
# one is present.
pause_tracking_markers_only() {  # <window-key>
  clear_pause_state() { :; }
  clear_pause_tracking "$1"
}
counted pause_tracking_markers_only absent-key
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'clear_pause_tracking with no markers ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
: > "$STATE/.stale-p$$"
: > "$STATE/.waiting-resurfaced-p$$"
counted pause_tracking_markers_only "p$$"
[ "$TOOLS" = 'rm ' ] || printf 'clear_pause_tracking with markers ran [%s], not [rm ]\n' "$TOOLS"
[ ! -e "$STATE/.stale-p$$" ] && [ ! -e "$STATE/.waiting-resurfaced-p$$" ] \
  || printf 'clear_pause_tracking kept a marker\n'
# The pause and stale paths clear .stale-since-* only through fm_rm_present.
for fn in handle_paused_stale surface_nonterminal_stale clear_pause_tracking; do
  case "$(declare -f "$fn")" in
    *'rm -f "$STATE/.stale-since-'*) printf '%s clears .stale-since- with an unconditional rm -f\n' "$fn" ;;
  esac
done
: > "$r/b"
counted fm_rm_present "$r/none" "$r/b"
[ "$TOOLS" = 'rm ' ] || printf 'fm_rm_present of a present path ran [%s], not [rm ]\n' "$TOOLS"
# Bash before 4.2 reads a file with cat, so the read is counted only after it.
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  counted fm_file_text_to got "$r/text/line"
  [ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'fm_file_text_to ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
fi
# Only Linux resolves stat through PATH and only Bash 4.2+ reads the clock in
# the shell, so the age read is counted there; the md5sum branch is counted
# where it is the one the watcher picked.
if [ "$_FM_UNAME" = Linux ] && { [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; }; then
  counted age_of_to got "$dir/old"
  [ "$TOOLS" = 'stat ' ] || printf 'age_of_to ran [%s], not [stat ]\n' "$TOOLS"
fi
if [ -z "$md5_shim" ] && ! command -v md5 >/dev/null 2>&1; then
  counted hash_pane_to got "$long"
  [ "$TOOLS" = 'md5sum ' ] || printf 'hash_pane_to ran [%s], not [md5sum ]\n' "$TOOLS"
  counted hash_pane_memo_to got 1 "$long"
  [ "$TOOLS" = 'md5sum ' ] || printf 'hash_pane_memo_to of a changed text ran [%s], not [md5sum ]\n' "$TOOLS"
fi
hash_pane_memo_to got 1 "$long"
counted hash_pane_memo_to got 1 "$long"
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'hash_pane_memo_to of an unchanged text ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
rm -rf "$r"
SH
  run_everywhere "watcher poll helpers" "$script" "$dir" '' '' "$count_shim" "$count_log"
  if ! command -v md5 >/dev/null 2>&1 && command -v md5sum >/dev/null 2>&1; then
    run_everywhere "watcher poll helpers with md5" "$script" "$dir" "$shim" "$log" "$count_shim" "$count_log"
  fi
  pass "hash_pane_to and its per-window memory, window_key_to, age_of_to, fm_rm_present, the pause and stale marker clears and the loop's file reads match what they replaced and start no more processes"
}

test_inbox_due_action_matches_what_it_replaced() {
  local script="$TMP_ROOT/inbox-due.sh" dir="$TMP_ROOT/inbox-due" count_shim="$TMP_ROOT/inbox-due-count"
  local count_log="$TMP_ROOT/inbox-due-count.log" tool path
  mkdir -p "$dir" "$count_shim"
  for tool in rm stat date cat awk grep; do
    path=$(command -v "$tool") || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$count_log" "$path" > "$count_shim/$tool"
    chmod +x "$count_shim/$tool"
  done
  cat > "$script" <<'SH'
# The watcher's source guard returns before its loop, leaving every helper below.
. "$1/bin/fm-watch.sh"
dir=$2 count_shim=$3 count_log=$4
STATE=$dir/state
inbox=$STATE/t1.inbox
export FM_CONFIG_OVERRIDE=$dir/config FM_TASK_INBOX_GRACE_SECS=60
# The replaced fm_task_inbox_oldest_unhandled and fm_task_inbox_due_action.
reference_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}
reference_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(reference_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.busy-state" 2>/dev/null || true
    if [ -e "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/wait-no-turns" ]; then
      base=$(cat "$dir/.retry-ring" 2>/dev/null || true)
      if ! fm_task_inbox_seq_of "$base" >/dev/null || [ ! -f "$dir/$base" ]; then
        rm -f "$dir/.retry-ring" 2>/dev/null || true
      elif [ "$(fm_path_age "$dir/.retry-ring")" -ge "$(fm_task_inbox_grace_secs)" ]; then
        printf 'retry %s' "$dir/$base"
        return 0
      fi
    fi
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  if ! fm_task_inbox_generation_current "$1" "$2" "$oldest"; then
    printf 'stale-generation %s' "$oldest"
    return 0
  fi
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}
record() {  # <name> [header-line...]: a record written long ago
  local name=$1 line
  shift
  {
    printf 'schema=fm-task-inbox.v1\nat=2000-01-01T00:00:00Z\n'
    for line in "$@"; do printf '%s\n' "$line"; done
    printf -- '--\nbody of %s\n' "$name"
  } > "$inbox/$name"
  touch -t 200001010000 "$inbox/$name"
}
setup() {  # <case>
  rm -rf "$STATE" "$FM_CONFIG_OVERRIDE"
  mkdir -p "$inbox/handled" "$FM_CONFIG_OVERRIDE"
  case "$1" in
    wait-*) : > "$FM_CONFIG_OVERRIDE/wait-no-turns" ;;
  esac
  case "$1" in
    no-inbox) rm -rf "$inbox" ;;
    empty|wait-empty) ;;
    leftovers)
      printf '004.msg\t3\t0\n' > "$inbox/.ring-state"
      printf '004.msg\n' > "$inbox/.escalated"
      printf '004.msg\t1\n' > "$inbox/.busy-state"
      ;;
    ladder-dir) mkdir "$inbox/.ring-state" ;;
    leftover-link) ln -s missing "$inbox/.escalated" ;;
    fire-and-forget|wait-fire-and-forget) record 005.msg delivery=fire-and-forget ;;
    wait-mark-missing) printf '009.msg\n' > "$inbox/.retry-ring" ;;
    wait-mark-junk) printf 'not a record\n' > "$inbox/.retry-ring" ;;
    wait-mark-dir) mkdir "$inbox/.retry-ring" ;;
    wait-mark-fresh)
      record 005.msg delivery=fire-and-forget
      printf '005.msg\n' > "$inbox/.retry-ring"
      ;;
    wait-mark-due|wait-mark-newlines)
      record 005.msg delivery=fire-and-forget
      if [ "$1" = wait-mark-due ]; then printf '005.msg\n' > "$inbox/.retry-ring"; else printf '005.msg\n\n\n' > "$inbox/.retry-ring"; fi
      touch -t 200001010000 "$inbox/.retry-ring"
      ;;
    fresh) record 007.msg; touch "$inbox/007.msg" ;;
    due) record 007.msg ;;
    spaced) record 007.msg; printf '007.msg\t1\t%s\n' "$(date +%s)" > "$inbox/.ring-state" ;;
    spent) record 007.msg; printf '007.msg\t3\t0\n' > "$inbox/.ring-state" ;;
    other-ladder) record 007.msg; printf '006.msg\t5\t%s\n' "$(date +%s)" > "$inbox/.ring-state" ;;
    junk-ladder) record 007.msg; printf '007.msg\tx\ty\n' > "$inbox/.ring-state" ;;
    escalated) record 007.msg; printf '007.msg\t3\t0\n' > "$inbox/.ring-state"; printf '007.msg\n' > "$inbox/.escalated" ;;
    ordering)
      record 010.msg
      record 002.msg
      record 001.msg delivery=fire-and-forget
      record abc.msg
      record 1a.msg
      ;;
    stale-generation) record 007.msg task_generation=g2; printf 'spawn_gen=g1\n' > "$STATE/t1.meta" ;;
    current-generation) record 007.msg task_generation=g1; printf 'spawn_gen=g1\n' > "$STATE/t1.meta" ;;
  esac
}
left() {  # the names left in the inbox, dotfiles included
  local f out=''
  for f in "$inbox"/.[!.]* "$inbox"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    out="$out ${f##*/}"
  done
  printf '%s' "$out"
}
for c in no-inbox empty wait-empty leftovers ladder-dir leftover-link fire-and-forget wait-fire-and-forget \
  wait-mark-missing wait-mark-junk wait-mark-dir wait-mark-fresh wait-mark-due wait-mark-newlines fresh due \
  spaced spent other-ladder junk-ladder escalated ordering stale-generation current-generation; do
  setup "$c"
  want=$(reference_oldest_unhandled "$STATE" t1); want_rc=$?
  got=unset
  fm_task_inbox_oldest_unhandled_to got "$STATE" t1; got_rc=$?
  [ "$got/$got_rc" = "$want/$want_rc" ] || printf '%s: oldest_unhandled_to %q (status %s), replaced %q (status %s)\n' "$c" "$got" "$got_rc" "$want" "$want_rc"
  got=$(fm_task_inbox_oldest_unhandled "$STATE" t1); got_rc=$?
  [ "$got/$got_rc" = "$want/$want_rc" ] || printf '%s: oldest_unhandled printed %q (status %s), replaced %q (status %s)\n' "$c" "$got" "$got_rc" "$want" "$want_rc"
  want=$(reference_due_action "$STATE" t1); want_rc=$?
  want_left=$(left)
  setup "$c"
  got=unset
  fm_task_inbox_due_action_to got "$STATE" t1; got_rc=$?
  got_left=$(left)
  [ "$got/$got_rc" = "$want/$want_rc" ] || printf '%s: due_action_to %q (status %s), replaced %q (status %s)\n' "$c" "$got" "$got_rc" "$want" "$want_rc"
  [ "$got_left" = "$want_left" ] || printf '%s: due_action_to left [%s], replaced [%s]\n' "$c" "$got_left" "$want_left"
  setup "$c"
  got=$(fm_task_inbox_due_action "$STATE" t1); got_rc=$?
  got_left=$(left)
  [ "$got/$got_rc" = "$want/$want_rc" ] || printf '%s: due_action printed %q (status %s), replaced %q (status %s)\n' "$c" "$got" "$got_rc" "$want" "$want_rc"
  [ "$got_left" = "$want_left" ] || printf '%s: due_action left [%s], replaced [%s]\n' "$c" "$got_left" "$want_left"
done
# Run <command> with every tool it starts through PATH, and every command one
# of its subshells runs, logged: TOOLS lists the tools, SUBSHELLS counts the
# subshell commands.
counted() {  # <command> [args...]
  : > "$count_log"
  : > "$count_log.sub"
  (
    PATH="$count_shim:$PATH"
    __spawn_level=$BASH_SUBSHELL
    set -T
    trap '[ "$BASH_SUBSHELL" -le "$__spawn_level" ] || printf "%s\n" "$BASH_COMMAND" >> "$count_log.sub"' DEBUG
    "$@"
  ) > /dev/null 2>&1
  TOOLS=$(sort "$count_log" | tr '\n' ' ')
  SUBSHELLS=$(grep -c . "$count_log.sub" || true)
}
# A quiet inbox is checked, and the watcher's per-window inbox check returns,
# without starting a process; leftover bookkeeping costs one rm. Bash before
# 4.2 reads the retry mark with cat.
cases='no-inbox empty'
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  cases="$cases wait-empty"
fi
for c in $cases; do
  setup "$c"
  counted fm_task_inbox_due_action_to got "$STATE" t1
  [ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf '%s: due_action_to ran [%s] and %s subshell commands\n' "$c" "$TOOLS" "$SUBSHELLS"
  counted inbox_steer_check sess:fm-t1 t1
  [ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf '%s: inbox_steer_check ran [%s] and %s subshell commands\n' "$c" "$TOOLS" "$SUBSHELLS"
done
setup leftovers
counted fm_task_inbox_due_action_to got "$STATE" t1
[ "$TOOLS" = 'rm ' ] && [ "$SUBSHELLS" -eq 0 ] || printf 'leftovers: due_action_to ran [%s] and %s subshell commands, not [rm ]\n' "$TOOLS" "$SUBSHELLS"
exit 0
SH
  run_everywhere "inbox due action" "$script" "$dir" "$count_shim" "$count_log"
  pass "fm_task_inbox_due_action_to and fm_task_inbox_oldest_unhandled_to match what they replaced and start no process on a quiet inbox"
}

test_watcher_capture_matches_what_it_replaced() {
  local script="$TMP_ROOT/capture.sh" dir="$TMP_ROOT/capture" count_shim="$TMP_ROOT/capture-count"
  local count_log="$TMP_ROOT/capture-count.log" tool path
  mkdir -p "$dir/state" "$count_shim"
  for tool in mktemp rm cat ps tr; do
    path=$(command -v "$tool") || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$count_log" "$path" > "$count_shim/$tool"
    chmod +x "$count_shim/$tool"
  done
  # A command whose name holds the stat line's delimiters, run as argv[0] sleep
  # so a multi-call sleep still knows what to run.
  ln -s "$(command -v sleep)" "$dir/a) (b c"
  cat > "$script" <<'SH'
# The watcher's source guard returns before its loop, leaving every helper below.
. "$1/bin/fm-watch.sh"
dir=$2 count_shim=$3 count_log=$4
STATE=$dir/state
# The replaced process-group read and watcher_capture.
reference_pgid() {  # <pid>
  ps -o pgid= -p "$1" 2>/dev/null | tr -d '[:space:]'
}
# Its own FM_CAPTURE_OUTPUT leaves the watcher's lifetime file alone.
reference_capture() {  # <backend> <target> <lines> [expected-label]
  local rc pgid FM_CAPTURE_OUTPUT=
  fm_capture_output_cleanup
  WATCHER_CAPTURE=
  FM_CAPTURE_OUTPUT=$(mktemp "$STATE/.fm-capture-output.XXXXXX") || return 1
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  { fm_backend_capture "$@" < /dev/null > "$FM_CAPTURE_OUTPUT" & } 2>/dev/null
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  watcher_stop_signals
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_capture_output_cleanup
    return 1
  fi
  wait "$FM_ACTIVE_CHECK_PID"
  rc=$?
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || { fm_capture_output_cleanup; return 1; }
  WATCHER_CAPTURE=$(cat "$FM_CAPTURE_OUTPUT" 2>/dev/null || true)
  fm_capture_output_cleanup
  return "$rc"
}
# The pane read each capture runs, chosen by CAPTURE_CASE.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local i=1
  case "$CAPTURE_CASE" in
    text) printf 'first line\n  indented line  \n\n\n' ;;
    empty) ;;
    failed) printf 'partial\n'; return 3 ;;
    silent) return 3 ;;
    prompt) printf 'prompt> ' ;;
    long)
      while [ "$i" -le 100 ]; do
        printf 'pane line %03d with $ %% \\ and a run of trailing spaces          \n' "$i"
        i=$((i + 1))
      done
      ;;
    bytes) printf 'caf\303\251 \377\376\001\n\n' ;;
    nul) printf 'before\000after\n' ;;
    vanished) rm -f "$FM_CAPTURE_OUTPUT"; printf 'gone\n' ;;
    args) printf '[%s]' "$@" ;;
    slow) sleep 0.3; printf 'late\n' ;;
  esac
}
captures_left() {  # the capture files left in the state directory
  local f out=''
  for f in "$STATE"/.fm-capture-output.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    out="$out ${f##*/}"
  done
  printf '%s' "$out"
}
# The replaced read printed bash's null-byte warning, the accepted difference,
# so only its value and status are compared. Short and empty reads follow long
# ones, so a byte kept from an earlier capture shows as a difference. The
# watcher keeps one capture file across captures and makes a new one only after
# a read removed it.
expected_path=
for CAPTURE_CASE in text empty failed prompt long empty long silent bytes long nul vanished args slow long prompt; do
  reference_capture herdr sess:fm-a 40 fm-a 2>/dev/null; want_rc=$?
  want=$WATCHER_CAPTURE
  WATCHER_CAPTURE=unset
  watcher_capture herdr sess:fm-a 40 fm-a; got_rc=$?
  [ "$WATCHER_CAPTURE/$got_rc" = "$want/$want_rc" ] || printf '%s: capture %q (status %s), replaced %q (status %s)\n' "$CAPTURE_CASE" "$WATCHER_CAPTURE" "$got_rc" "$want" "$want_rc"
  left=$(captures_left)
  want_left=" ${FM_CAPTURE_OUTPUT##*/}"
  [ "$CAPTURE_CASE" != vanished ] || want_left=
  [ -n "$FM_CAPTURE_OUTPUT" ] && [ "$left" = "$want_left" ] || printf '%s: capture left [%s] (%s)\n' "$CAPTURE_CASE" "$left" "$FM_CAPTURE_OUTPUT"
  [ -z "$expected_path" ] || [ "$FM_CAPTURE_OUTPUT" = "$expected_path" ] || printf '%s: capture file moved from %s to %s\n' "$CAPTURE_CASE" "$expected_path" "$FM_CAPTURE_OUTPUT"
  expected_path=$FM_CAPTURE_OUTPUT
  [ "$CAPTURE_CASE" != vanished ] || expected_path=
done
# A capture in a subshell leaves the main shell's file alone and removes its own.
lifetime_path=$FM_CAPTURE_OUTPUT
CAPTURE_CASE=text
sub=$(watcher_capture herdr sess:fm-a 40 fm-a; printf '%s|%s' "$WATCHER_CAPTURE" "$FM_CAPTURE_OUTPUT")
[ "$sub" = 'first line
  indented line  |' ] || printf 'subshell capture returned %q\n' "$sub"
left=$(captures_left)
[ "$FM_CAPTURE_OUTPUT" = "$lifetime_path" ] && [ "$left" = " ${lifetime_path##*/}" ] \
  || printf 'subshell capture left [%s] (%s)\n' "$left" "$FM_CAPTURE_OUTPUT"
# A replaced file is never written through: a link is dropped for a new file.
rm -f "$lifetime_path"
ln -s "$dir/elsewhere" "$lifetime_path"
watcher_capture herdr sess:fm-a 40 fm-a
[ "$FM_CAPTURE_OUTPUT" != "$lifetime_path" ] && [ ! -e "$dir/elsewhere" ] && [ ! -L "$lifetime_path" ] \
  || printf 'capture wrote through a replaced file (%s)\n' "$FM_CAPTURE_OUTPUT"
# The watcher's cleanup removes the lifetime file.
fm_capture_output_cleanup
left=$(captures_left)
[ -z "$FM_CAPTURE_OUTPUT" ] && [ -z "$left" ] || printf 'cleanup left [%s] (%s)\n' "$left" "$FM_CAPTURE_OUTPUT"
pgid_check() {  # <label> <pid>
  local want got
  want=$(reference_pgid "$2")
  got=unset
  fm_pid_pgid_to got "$2"
  [ "$got" = "$want" ] || printf 'pgid %s %q: helper %q, ps %q\n' "$1" "$2" "$got" "$want"
}
# The sleeps end on their own, and the braces hold bash 3.2's setpgid race
# message as watcher_capture does.
set -m
{ sleep 5 > /dev/null 2>&1 & } 2>/dev/null
own=$!
{ (exec -a sleep "$dir/a) (b c" 5) > /dev/null 2>&1 & } 2>/dev/null
odd=$!
set +m
sleep 5 > /dev/null 2>&1 &
shared=$!
sleep 0 > /dev/null 2>&1 &
gone=$!
wait "$gone"
pgid_check self "$$"
pgid_check own-group "$own"
pgid_check odd-name "$odd"
pgid_check shared-group "$shared"
pgid_check gone "$gone"
for p in '' abc 12a 0 0123 -1 '1 2'; do
  pgid_check invalid "$p"
done
# Run <command> with every tool it starts through PATH, and every command one
# of its subshells runs, logged: TOOLS lists the tools, SUBSHELLS counts the
# subshell commands.
counted() {  # <command> [args...]
  : > "$count_log"
  : > "$count_log.sub"
  (
    PATH="$count_shim:$PATH"
    __spawn_level=$BASH_SUBSHELL
    set -T
    trap '[ "$BASH_SUBSHELL" -le "$__spawn_level" ] || printf "%s\n" "$BASH_COMMAND" >> "$count_log.sub"' DEBUG
    "$@"
  ) > /dev/null 2>&1
  TOOLS=$(sort "$count_log" | tr '\n' ' ')
  SUBSHELLS=$(grep -c . "$count_log.sub" || true)
}
# On Linux with Bash 4.2 and later the group and the text are read in the
# shell, so a capture starts nothing besides its pane read, whose own commands
# run in the capture's subshell: the main shell's first capture starts mktemp,
# later ones nothing, and a subshell's capture mktemp and rm.
if [ "$_FM_UNAME" = Linux ] && { [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; }; then
  counted fm_pid_pgid_to got "$own"
  [ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'fm_pid_pgid_to ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
  CAPTURE_CASE=slow
  counted watcher_capture herdr sess:fm-a 40 fm-a
  [ "$TOOLS" = 'mktemp rm ' ] || printf 'watcher_capture in a subshell ran [%s], not [mktemp rm ]\n' "$TOOLS"
  for want in 'mktemp ' ''; do
    : > "$count_log"
    PATH="$count_shim:$PATH" watcher_capture herdr sess:fm-a 40 fm-a
    TOOLS=$(sort "$count_log" | tr '\n' ' ')
    [ "$TOOLS" = "$want" ] || printf 'watcher_capture in the main shell ran [%s], not [%s]\n' "$TOOLS" "$want"
  done
  fm_capture_output_cleanup
fi
exit 0
SH
  run_everywhere "watcher capture" "$script" "$dir" "$count_shim" "$count_log"
  pass "watcher_capture and fm_pid_pgid_to match what they replaced, a capture runs no ps, tr or cat, and the watcher keeps one capture file for its lifetime"
}

test_busy_classify_matches_what_it_replaced() {
  local script="$TMP_ROOT/busy-classify.sh" dir="$TMP_ROOT/busy-classify" count_shim="$TMP_ROOT/busy-classify-count"
  local count_log="$TMP_ROOT/busy-classify-count.log" tool path
  mkdir -p "$dir/state" "$dir/meta" "$count_shim"
  for tool in grep cat tail rm stat date tr cut awk sed head mktemp; do
    path=$(command -v "$tool") || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$tool" "$count_log" "$path" > "$count_shim/$tool"
    chmod +x "$count_shim/$tool"
  done
  cat > "$script" <<'SH'
# The watcher's source guard returns before its loop, leaving every helper below.
. "$1/bin/fm-watch.sh"
dir=$2 count_shim=$3 count_log=$4
STATE=$dir/state
# The replaced record readers, prompt checks, classifiers and window_is_busy.
reference_current_gen() {  # <state-dir> <id>
  local gen_file gen
  gen_file=$(fm_busy_gen_path "$1" "$2")
  [ -f "$gen_file" ] || return 1
  IFS= read -r gen < "$gen_file" 2>/dev/null || gen=
  fm_busy_token_valid "$gen" || return 1
  printf '%s' "$gen"
}
reference_sources_for_harness() {  # <harness>
  local adapter=
  case "${1:-}" in
    claude*) adapter=claude-hook ;;
    codex*)
      fm_busy_codex_semantic_source || { printf ''; return 0; }
      adapter='codex-hook codex-appserver'
      ;;
    opencode*) adapter=opencode-plugin ;;
    gemini*) adapter=gemini-hook ;;
    devin) adapter=devin-hook ;;
    pi|pi-signed) adapter=pi-ext ;;
    omp) adapter=omp-ext ;;
    kimi*)
      fm_busy_kimi_verified || { printf ''; return 0; }
      adapter='kimi-wire kimi-hook'
      ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s fm-spawn fm-interrupt fm-recovery' "$adapter"
}
reference_source_trusted() {  # <harness> <source>
  local trusted
  trusted=$(reference_sources_for_harness "$1")
  case " $trusted " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}
reference_record_read() {  # <state-dir> <id>
  local state=$1 id=$2 rec gen line extra ver f
  local r_gen='' r_seq='' r_state='' r_source='' r_event='' r_ts=''
  rec=$(fm_busy_record_path "$state" "$id")
  if [ ! -f "$rec" ]; then
    printf 'missing'
    return 1
  fi
  if ! gen=$(reference_current_gen "$state" "$id"); then
    printf 'malformed'
    return 1
  fi
  { IFS= read -r line && ! IFS= read -r extra; } < "$rec" 2>/dev/null || {
    printf 'malformed'
    return 1
  }
  local -a fields
  IFS=' ' read -r -a fields <<< "$line"
  ver=${fields[0]:-}
  [ "$ver" = "$FM_BUSY_LIB_VERSION" ] || { printf 'malformed'; return 1; }
  for f in "${fields[@]:1}"; do
    case "$f" in
      gen=*) r_gen=${f#gen=} ;;
      seq=*) r_seq=${f#seq=} ;;
      state=*) r_state=${f#state=} ;;
      source=*) r_source=${f#source=} ;;
      event=*) r_event=${f#event=} ;;
      ts=*) r_ts=${f#ts=} ;;
      *) printf 'malformed'; return 1 ;;
    esac
  done
  fm_busy_token_valid "$r_gen" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_source" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_event" || { printf 'malformed'; return 1; }
  case "$r_seq" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_ts" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_state" in busy|idle|unknown) : ;; *) printf 'malformed'; return 1 ;; esac
  if [ "$r_gen" != "$gen" ]; then
    printf 'gen-mismatch'
    return 1
  fi
  printf '%s %s %s %s' "$r_state" "$r_source" "$r_event" "$r_seq"
}
reference_claude_launch_prompt_tail() {
  local buf
  buf=$(cat)
  if printf '%s' "$buf" | grep -qiE "${FM_BUSY_CLAUDE_TRUST_PROMPT_REGEX:-Quick safety check: Is this a project you created or one you trust\\?}" \
    && printf '%s' "$buf" | grep -qiE 'No, exit|Enter to confirm'; then
    return 0
  fi
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_CLAUDE_IMPORTS_PROMPT_REGEX:-Allow external CLAUDE\\.md file imports\\?}" \
    && printf '%s' "$buf" | grep -qiE 'No, disable external imports|Yes, allow external imports'
}
reference_pi_launch_prompt_tail() {
  local buf
  buf=$(cat)
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_PI_LAUNCH_PROMPT_REGEX:-Trust project folder\\?}" \
    && printf '%s' "$buf" | grep -qiE 'Do not trust'
}
reference_gemini_launch_prompt_tail() {
  local buf
  buf=$(cat)
  if printf '%s' "$buf" | grep -qiE "${FM_BUSY_GEMINI_TRUST_PROMPT_REGEX:-Do you trust the files in this folder\\?}" \
    && printf '%s' "$buf" | grep -qiE "Trust folder|Don't trust"; then
    return 0
  fi
  if printf '%s' "$buf" | grep -qiE "${FM_BUSY_GEMINI_AUTH_PROMPT_REGEX:-How would you like to authenticate for this project\\?}" \
    && printf '%s' "$buf" | grep -qiE 'Use Gemini API Key|No authentication method selected'; then
    return 0
  fi
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_GEMINI_APIKEY_PROMPT_REGEX:-Enter Gemini API Key}"
}
reference_launch_prompt_parked() {  # <harness>
  case "${1:-}" in
    claude*) reference_claude_launch_prompt_tail ;;
    pi | pi-signed | omp) reference_pi_launch_prompt_tail ;;
    gemini) reference_gemini_launch_prompt_tail ;;
    *) return 1 ;;
  esac
}
reference_classify() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 tail40=${6-}
  local out rc r_state r_source native log
  case "$harness" in
    kimi*)
      if ! fm_busy_kimi_verified; then
        printf 'unknown kimi-unverified'
        return 0
      fi
      ;;
    codex*)
      if ! fm_busy_codex_semantic_source; then
        printf 'unknown codex-unverified'
        return 0
      fi
      ;;
    cursor*)
      if ! log=$(fm_busy_cursor_transcript "$state" "$id"); then
        printf 'unknown cursor-transcript'
        return 0
      fi
      case "$(fm_busy_cursor_turn_state "$log" 2>/dev/null)" in
        busy) printf 'busy cursor-transcript' ;;
        settled) printf 'idle cursor-transcript' ;;
        *) printf 'unknown cursor-transcript' ;;
      esac
      return 0
      ;;
  esac
  out=$(reference_record_read "$state" "$id") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    r_state=${out%% *}
    out=${out#* }
    r_source=${out%% *}
    if reference_source_trusted "$harness" "$r_source"; then
      if [ "$r_state" = busy ] && [ "$r_source" = fm-spawn ] && [ -n "$tail40" ] \
        && printf '%s' "$tail40" | reference_launch_prompt_parked "$harness"; then
        printf 'unknown launch-prompt'
      else
        printf '%s %s' "$r_state" "$r_source"
      fi
    else
      printf 'unknown source-mismatch'
    fi
    return 0
  fi
  case "$out" in
    malformed|gen-mismatch)
      printf 'unknown %s' "$out"
      return 0
      ;;
  esac
  if [ "$backend" = herdr ] && command -v fm_backend_busy_state >/dev/null 2>&1; then
    native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
    if [ "$native" = busy ]; then
      printf 'busy herdr-native'
      return 0
    fi
  fi
  case "$harness" in
    muse*)
      if ! log=$(fm_busy_muse_session_log "$state" "$id"); then
        printf 'unknown muse-session-log'
        return 0
      fi
      case "$(fm_busy_muse_run_state "$log" 2>/dev/null)" in
        busy) printf 'busy muse-session-log' ;;
        settled) printf 'idle muse-session-log' ;;
        *) printf 'unknown muse-session-log' ;;
      esac
      return 0
      ;;
    grok*)
      if [ -z "$tail40" ]; then
        if command -v fm_backend_capture >/dev/null 2>&1; then
          tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || {
            printf 'unknown capture-failed'
            return 0
          }
        else
          printf 'unknown capture-failed'
          return 0
        fi
      fi
      if printf '%s' "$tail40" | fm_busy_grok_tail_busy; then
        printf 'busy grok-regex'
      else
        printf 'idle grok-regex'
      fi
      return 0
      ;;
    rovo*)
      if [ -z "$tail40" ]; then
        if command -v fm_backend_capture >/dev/null 2>&1; then
          tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || {
            printf 'unknown capture-failed'
            return 0
          }
        else
          printf 'unknown capture-failed'
          return 0
        fi
      fi
      if printf '%s' "$tail40" | fm_busy_rovo_tail_busy; then
        printf 'busy rovo-regex'
      else
        printf 'unknown rovo-regex'
      fi
      return 0
      ;;
    agy)
      if [ -z "$tail40" ]; then
        if command -v fm_backend_capture >/dev/null 2>&1; then
          tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || {
            printf 'unknown capture-failed'
            return 0
          }
        else
          printf 'unknown capture-failed'
          return 0
        fi
      fi
      if printf '%s' "$tail40" | fm_busy_agy_tail_busy; then
        printf 'busy agy-regex'
      else
        printf 'unknown agy-regex'
      fi
      return 0
      ;;
  esac
  printf 'unknown missing'
}
reference_classify_meta() {  # <meta-file> <id> <state-dir> [tail40]
  local meta=$1 id=$2 state=$3 tail40=${4-} backend target harness
  [ -f "$meta" ] || { printf 'unknown missing'; return 0; }
  fm_backend_of_meta_to backend "$meta"
  fm_backend_target_of_meta_to target "$meta"
  fm_meta_get_to harness "$meta" harness
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  reference_classify "$backend" "$target" "$harness" "$id" "$state" "$tail40"
}
reference_window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 meta verdict
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL
  window_resolve "$w"
  meta="$STATE/$WR_TASK.meta"
  if [ -n "$WR_TASK" ] && [ -f "$meta" ]; then
    verdict=$(reference_classify_meta "$meta" "$WR_TASK" "$STATE" "$tail40")
  else
    verdict=$(reference_classify "$WR_BACKEND" "$w" "$WR_HARNESS" \
      "${WR_TASK:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}
# Stand-ins for the gates, the Cursor and Muse readers and the backend, which
# both sides call; each answers only the arguments the task's own call passes.
STUB=settled TARGET=sess:w BACKEND=tmux MARK=none VERIFIED=0
fm_busy_codex_hooks_verified() { [ "$VERIFIED" = 1 ]; }
fm_busy_kimi_verified() { [ "$VERIFIED" = 1 ]; }
fm_busy_cursor_transcript() {  # <state-dir> <id>
  [ "$1/$2" = "$STATE/t" ] && [ "$STUB" != fail ] || return 1
  printf '%s' "$STATE/t.cursor"
}
fm_busy_cursor_turn_state() {  # <transcript>
  [ "$1" = "$STATE/t.cursor" ] && printf '%s' "$STUB"
}
fm_busy_muse_session_log() {  # <state-dir> <id>
  [ "$1/$2" = "$STATE/t" ] && [ "$STUB" != fail ] || return 1
  printf '%s' "$STATE/t.muse"
}
fm_busy_muse_run_state() {  # <session-log>
  [ "$1" = "$STATE/t.muse" ] && printf '%s' "$STUB"
}
fm_backend_busy_state() {  # <backend> <target>
  [ "$1 $2" = "herdr $TARGET" ] || return 1
  case "$STUB" in
    busy) printf busy ;;
    settled) printf idle ;;
    fail) return 1 ;;
    *) printf '%s' "$STUB" ;;
  esac
}
fm_backend_capture() {  # <backend> <target> <lines>
  [ "$1 $2 $3" = "$BACKEND $TARGET 40" ] || return 1
  case "$STUB" in
    busy) printf 'working\n%s\n\n' "$MARK" ;;
    fail) return 1 ;;
    *) printf 'plain pane text\n' ;;
  esac
}
claude_trust='Accessing workspace: /tmp/wt-a
Quick safety check: Is this a project you created or one you trust?
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel'
claude_imports='Allow external CLAUDE.md file imports?
> No, disable external imports
  Yes, allow external imports'
pi_trust=' Trust project folder?
 /tmp/wt-a
 > Trust
   Do not trust
 up/down navigate  enter select'
gemini_trust="Do you trust the files in this folder?
> 1. Trust folder (worktree)
  3. Don't trust"
gemini_auth='How would you like to authenticate for this project?
> 2. Use Gemini API Key'
gemini_apikey='Enter Gemini API Key'
# Compare <name>_to, then <name> in a command substitution, with <reference>:
# value and status. The replaced side's stderr is dropped: its pipe into a
# prompt check that returns without reading can report a broken pipe where
# SIGPIPE is ignored.
compare() {  # <label> <reference> <name> [args...]
  local label=$1 ref=$2 name=$3 want want_rc got got_rc
  shift 3
  want=$("$ref" "$@" 2>/dev/null) && want_rc=0 || want_rc=$?
  got=unset
  "${name}_to" got "$@" && got_rc=0 || got_rc=$?
  [ "$got/$got_rc" = "$want/$want_rc" ] || printf '%s: %s_to %q (status %s), replaced %q (status %s)\n' "$label" "$name" "$got" "$got_rc" "$want" "$want_rc"
  got=$("$name" "$@") && got_rc=0 || got_rc=$?
  [ "$got/$got_rc" = "$want/$want_rc" ] || printf '%s: %s %q (status %s), replaced %q (status %s)\n' "$label" "$name" "$got" "$got_rc" "$want" "$want_rc"
}
# Write <id>'s gen and record files from printf %b text, leaving either out
# given -.
put() {  # <id> <gen|-> <record|->
  rm -f "$STATE/$1.busy-gen" "$STATE/$1.busy-state"
  [ "$2" = - ] || printf '%b' "$2" > "$STATE/$1.busy-gen"
  [ "$3" = - ] || printf '%b' "$3" > "$STATE/$1.busy-state"
}
compare_record() {  # <label>
  compare "$1: gen" reference_current_gen fm_busy_current_gen "$STATE" t
  compare "$1: record" reference_record_read fm_busy_record_read "$STATE" t
  compare "$1: classify" reference_classify fm_busy_classify tmux sess:w claude t "$STATE" "$claude_trust"
}
# Each record case is <label>|<gen file>|<record file>.
records() {
  local entry label gen record id
  for entry in 'none|-|-' 'gen only|g1\n|-' \
    'record only|-|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'gen with a space|g 1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'empty gen|\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'unterminated gen|g1|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'gen with a CR|g1\r\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'two gens|g1\ng2\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'glob gen|*\n|v1 gen=* seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'empty record|g1\n|' 'blank record|g1\n|\n' \
    'two records|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\nv1 gen=g1 seq=2 state=idle source=claude-hook event=e ts=2\n' \
    'unterminated record|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1' \
    'v2|g1\n|v2 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'no version|g1\n|gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'unknown key|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1 x=1\n' \
    'bare glob|g1\n|v1 * gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'bad source|g1\n|v1 gen=g1 seq=1 state=busy source=a/b event=e ts=1\n' \
    'empty event|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event= ts=1\n' \
    'glob event|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=* ts=1\n' \
    'bad seq|g1\n|v1 gen=g1 seq=1a state=busy source=claude-hook event=e ts=1\n' \
    'no seq|g1\n|v1 gen=g1 state=busy source=claude-hook event=e ts=1\n' \
    'negative ts|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=-1\n' \
    'CRLF|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\r\n' \
    'bad state|g1\n|v1 gen=g1 seq=1 state=working source=claude-hook event=e ts=1\n' \
    'tabs|g1\n|v1\tgen=g1\tseq=1\tstate=busy\tsource=claude-hook\tevent=e\tts=1\n' \
    'extra spaces|g1\n|v1  gen=g1   seq=1 state=busy source=claude-hook event=e ts=1  \n' \
    'leading space|g1\n| v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'repeated key|g1\n|v1 gen=g1 seq=1 state=idle source=claude-hook event=e ts=1 state=busy\n' \
    'gen mismatch|g1\n|v1 gen=g2 seq=1 state=busy source=claude-hook event=e ts=1\n' \
    'backslash|g1\n|v1 gen=g1 seq=1 state=busy source=claude-hook event=e\\q ts=1\n'; do
    IFS='|' read -r label gen record <<< "$entry"
    put t "$gen" "$record"
    compare_record "$label"
  done
  for record in 'busy claude-hook' 'busy fm-spawn' 'busy fm-interrupt' 'busy fm-recovery' 'busy codex-hook' \
    'busy pi-ext' 'busy gemini-hook' 'busy kimi-wire' 'busy opencode-plugin' 'idle claude-hook' 'idle fm-spawn' \
    'unknown claude-hook' 'unknown fm-recovery'; do
    put t 'g1\n' "v1 gen=g1 seq=7 state=${record% *} source=${record#* } event=stop ts=1792000000\n"
    compare_record "$record"
  done
  for id in t '%s' 'a b' $'x\n' ''; do
    compare "record path $id" fm_busy_record_path fm_busy_record_path "$STATE" "$id"
    compare "gen path $id" fm_busy_gen_path fm_busy_gen_path "$STATE/%d" "$id"
  done
}
harnesses() {
  local h VERIFIED src want_rc got_rc record
  for h in claude claude-x codex codex-x kimi kimi-cli cursor opencode opencode-x gemini gemini-x \
    devin devin-x pi pi-signed pi-x omp muse grok rovo agy agy-x other ''; do
    for VERIFIED in 0 1; do
      case "$VERIFIED/$h" in 0/* | 1/codex* | 1/kimi*) ;; *) continue ;; esac
      compare "sources $h, verified $VERIFIED" reference_sources_for_harness fm_busy_sources_for_harness "$h"
      for src in claude-hook codex-hook codex-appserver opencode-plugin gemini-hook devin-hook pi-ext omp-ext \
        kimi-wire kimi-hook fm-spawn fm-interrupt fm-recovery '' 'pi-ext fm-spawn'; do
        reference_source_trusted "$h" "$src" && want_rc=0 || want_rc=$?
        fm_busy_source_trusted "$h" "$src" && got_rc=0 || got_rc=$?
        [ "$got_rc" = "$want_rc" ] || printf 'trusted %q %q, verified %s: status %s, replaced %s\n' "$h" "$src" "$VERIFIED" "$got_rc" "$want_rc"
      done
      for record in 'busy claude-hook' 'busy fm-spawn' 'idle pi-ext'; do
        put t 'g1\n' "v1 gen=g1 seq=1 state=${record% *} source=${record#* } event=e ts=1\n"
        compare "classify $h $record, verified $VERIFIED" reference_classify fm_busy_classify tmux sess:w "$h" t "$STATE" "$claude_trust"
      done
    done
  done
}
no_record() {
  local h BACKEND STUB MARK
  put t - -
  for h in cursor muse grok rovo agy agy-x claude; do
    case "$h" in
      grok) MARK='Ctrl+c:cancel' ;;
      rovo) MARK='Rovo is thinking...' ;;
      agy*) MARK='esc to cancel' ;;
      *) MARK=none ;;
    esac
    for BACKEND in tmux herdr; do
      for STUB in busy settled fail junk; do
        compare "no record $h $BACKEND $STUB" reference_classify fm_busy_classify "$BACKEND" sess:w "$h" t "$STATE" ''
      done
    done
    BACKEND=tmux STUB=settled
    compare "no record $h, marked tail" reference_classify fm_busy_classify tmux sess:w "$h" t "$STATE" "working"$'\n'"$MARK"$'\n'
    compare "no record $h, plain tail" reference_classify fm_busy_classify tmux sess:w "$h" t "$STATE" 'plain pane text'
  done
}
prompts() {
  local h text want_rc got_rc i
  for h in claude claude-x pi pi-signed omp gemini gemini-x opencode codex ''; do
    i=0
    for text in "$claude_trust" "$claude_imports" "$pi_trust" "$gemini_trust" "$gemini_auth" "$gemini_apikey" \
      'Trust project folder?' 'TRUST PROJECT FOLDER? DO NOT TRUST' "$claude_trust"$'\n\n\n' $'\n\n' \
      'I trust this approach and will proceed.' '' $'\xff Trust project folder?\n Do not trust \xc3\n\n'; do
      i=$((i + 1))
      reference_launch_prompt_parked "$h" <<< "$text" && want_rc=0 || want_rc=$?
      fm_busy_launch_prompt_parked "$h" "$text" && got_rc=0 || got_rc=$?
      [ "$got_rc" = "$want_rc" ] || printf 'prompt %q, tail %s: status %s, replaced %s\n' "$h" "$i" "$got_rc" "$want_rc"
    done
  done
  put t 'g1\n' 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=launch ts=1\n'
  for h in claude pi gemini opencode; do
    i=0
    for text in "$claude_trust" "$pi_trust" "$gemini_auth" 'plain pane text' $'\n\n'; do
      i=$((i + 1))
      compare "seed $h, tail $i" reference_classify fm_busy_classify tmux sess:w "$h" t "$STATE" "$text"
    done
    compare "seed $h, no tail" reference_classify fm_busy_classify tmux sess:w "$h" t "$STATE"
  done
}
# Each meta case is <label>|<the backend it names>|<meta file>.
metas() {
  local entry label BACKEND text record STUB=settled TARGET=sess:w
  local tail="$claude_trust"$'\n'"$pi_trust"$'\n'"$gemini_trust"
  for entry in 'none|tmux|-' 'no window|tmux|harness=claude\n' 'window|tmux|window=sess:w\nharness=claude\n' \
    'orca terminal|orca|backend=orca\nwindow=sess:o\nterminal=sess:w\nharness=grok\n' \
    'orca without a terminal|orca|backend=orca\nwindow=sess:w\nharness=pi\n' \
    'herdr|herdr|backend=herdr\nwindow=sess:w\nharness=grok\n' \
    'two windows|tmux|window=sess:x\nwindow=sess:w\nharness=pi\n' \
    'unterminated|tmux|window=sess:w\nharness=gemini'; do
    IFS='|' read -r label BACKEND text <<< "$entry"
    rm -f "$dir/meta/t.meta"
    [ "$text" = - ] || printf '%b' "$text" > "$dir/meta/t.meta"
    for record in seed none; do
      if [ "$record" = seed ]; then
        put t 'g1\n' 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=launch ts=1\n'
      else
        put t - -
      fi
      compare "meta $label, $record" reference_classify_meta fm_busy_classify_meta "$dir/meta/t.meta" t "$STATE" "$tail"
      compare "meta $label, $record, no tail" reference_classify_meta fm_busy_classify_meta "$dir/meta/t.meta" t "$STATE"
    done
  done
}
# window_is_busy's status, and that it prints nothing.
check_window() {  # <label> <window> <tail>
  local want_rc got_rc
  reference_window_is_busy "$2" "$3" 2>/dev/null && want_rc=0 || want_rc=$?
  window_is_busy "$2" "$3" > "$dir/stdout" && got_rc=0 || got_rc=$?
  [ "$got_rc" = "$want_rc" ] || printf 'window %s: status %s, replaced %s\n' "$1" "$got_rc" "$want_rc"
  [ ! -s "$dir/stdout" ] || printf 'window %s printed %q\n' "$1" "$(cat "$dir/stdout")"
}
windows() {
  local STUB=settled TARGET=sess:w BACKEND=tmux
  printf 'window=sess:w\nharness=claude\n' > "$STATE/t.meta"
  printf 'backend=herdr\nwindow=sess:h\nharness=grok\n' > "$STATE/h.meta"
  printf 'backend=orca\nwindow=sess:o\nterminal=term-9\nharness=pi\n' > "$STATE/o.meta"
  put o 'g1\n' 'v1 gen=g1 seq=1 state=busy source=pi-ext event=e ts=1\n'
  put t 'g1\n' 'v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n'
  check_window 'hook busy' sess:w 'plain pane text'
  put t 'g1\n' 'v1 gen=g1 seq=1 state=idle source=claude-hook event=e ts=1\n'
  check_window 'hook idle' sess:w 'plain pane text'
  put t 'g1\n' 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=launch ts=1\n'
  check_window 'seed on the trust dialog' sess:w "$claude_trust"
  check_window 'seed' sess:w 'plain pane text'
  TARGET=sess:h BACKEND=herdr
  for STUB in busy settled; do
    check_window "herdr $STUB" sess:h 'plain pane text'
  done
  check_window 'herdr capture' sess:h ''
  check_window 'herdr footer' sess:h $'working\nCtrl+c:cancel'
  check_window 'orca terminal' term-9 'plain pane text'
  check_window 'no meta' sess:fm-z 'plain pane text'
  check_window 'empty window' '' 'plain pane text'
}
# Every variable's name and value, so one the comparisons set shows.
variables() {
  local vars_name
  for vars_name in $(compgen -v); do
    case "$vars_name" in
      _ | vars_* | BASH* | FUNCNAME | LINENO | RANDOM | SRANDOM | SECONDS | EPOCH* | PIPESTATUS | HISTCMD | COLUMNS | LINES) continue ;;
    esac
    printf '%s=%q\n' "$vars_name" "${!vars_name-}"
  done
}
vars_before=$(variables)
records
harnesses
no_record
prompts
metas
windows
vars_after=$(variables)
if [ "$vars_after" != "$vars_before" ]; then
  printf '%s\n' "$vars_before" > "$dir/vars-before"
  printf '%s\n' "$vars_after" > "$dir/vars-after"
  printf 'the comparisons changed these variables:\n'
  diff "$dir/vars-before" "$dir/vars-after"
fi
# Run <command> with every tool it starts through PATH, and every command one
# of its subshells runs, logged: TOOLS lists the tools, SUBSHELLS counts the
# subshell commands.
counted() {  # <command> [args...]
  : > "$count_log"
  : > "$count_log.sub"
  (
    PATH="$count_shim:$PATH"
    __spawn_level=$BASH_SUBSHELL
    set -T
    trap '[ "$BASH_SUBSHELL" -le "$__spawn_level" ] || printf "%s\n" "$BASH_COMMAND" >> "$count_log.sub"' DEBUG
    "$@"
  ) > /dev/null 2>&1
  TOOLS=$(sort "$count_log" | tr '\n' ' ')
  SUBSHELLS=$(grep -c . "$count_log.sub" || true)
}
# A window whose record a hook wrote, or that no task owns, is classified
# without starting a process; one still at its fm-spawn seed starts only the
# prompt check's two greps.
put t 'g1\n' 'v1 gen=g1 seq=1 state=busy source=claude-hook event=e ts=1\n'
counted window_is_busy sess:w 'plain pane text'
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'window_is_busy on a hook record ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
counted window_is_busy sess:fm-z 'plain pane text'
[ -z "$TOOLS" ] && [ "$SUBSHELLS" -eq 0 ] || printf 'window_is_busy on an unowned window ran [%s] and %s subshell commands\n' "$TOOLS" "$SUBSHELLS"
put t 'g1\n' 'v1 gen=g1 seq=1 state=busy source=fm-spawn event=launch ts=1\n'
counted window_is_busy sess:w 'plain pane text'
[ "$TOOLS" = 'grep grep ' ] || printf 'window_is_busy on a launch seed ran [%s], not [grep grep ]\n' "$TOOLS"
exit 0
SH
  run_everywhere "busy classify" "$script" "$dir" "$count_shim" "$count_log"
  pass "fm_busy_classify, its record readers and window_is_busy match what they replaced, and a polled window's verdict starts no subshell"
}

test_pending_reply_correlation_matches_forked_token() {
  local script="$TMP_ROOT/correlation.sh"
  cat > "$script" <<'SH'
. "$1/bin/fm-pending-reply-lib.sh"
old_match() {
  local re
  re="(^|[^[:alnum:]_])$(fm_pending_reply_corr_token "$2")([^[:alnum:]_]|\$)"
  [[ $1 =~ $re ]]
}
corr=abcdef0123456789
for text in '' "corr=$corr" "[corr=$corr]" "note corr=$corr: answer" \
  "xcorr=$corr" "_corr=$corr" "corr=${corr}ff" "corr=${corr}_" \
  "corr=${corr}-suffix" "corr=ABCDEF0123456789" $'\303\251'"corr=$corr" \
  $'\377'"corr=$corr" $'note\t'"corr=$corr"; do
  want=1 got=1
  old_match "$text" "$corr" && want=0
  fm_pending_reply_text_has_corr "$text" "$corr" && got=0
  [ "$want" = "$got" ] || printf 'correlation %q: old=%s new=%s\n' "$text" "$want" "$got"
done
# A runtime tripwire: the new predicate must not ask the token helper to
# execute in a command substitution for even one unrelated or matching line.
fm_pending_reply_corr_token() { printf 'unexpected token subprocess\n' >&2; return 1; }
fm_pending_reply_text_has_corr "note: corr=$corr" "$corr" || exit 1
if fm_pending_reply_text_has_corr 'working: unrelated' "$corr"; then exit 1; fi
exit 0
SH
  run_everywhere 'pending reply correlation' "$script"
  pass 'pending-reply whole-token matching equals the old substitution without invoking its helper'
}

test_pending_reply_escalation_line_matches_the_per_line_scan() {
  local script="$TMP_ROOT/escalation-line.sh" cases="$TMP_ROOT/escalation-line" corr=0123456789abcdef i token
  local key="pending-reply-0123456789abcdef" ids="task=hibit pending-reply-id=0123456789abcdef"
  mkdir -p "$cases/records" "$cases/dir.status"
  esc_record() {  # <name> <record-lines>...
    local name=$1
    shift
    printf '%s\n' "$@" > "$cases/records/$name"
  }
  esc_record failed "corr_id=$corr" task_id=hibit 'request_summary=S' recovery_delivery_outcome=failed
  esc_record unknown "corr_id=$corr" task_id=hibit 'request_summary=S' recovery_delivery_outcome=unknown
  esc_record confirmed "corr_id=$corr" task_id=hibit 'request_summary=S' recovery_delivery_outcome=confirmed
  esc_record no-outcome "corr_id=$corr" task_id=hibit 'request_summary=S'
  esc_record glob "corr_id=$corr" task_id=hibit 'request_summary=S*[a]?' recovery_delivery_outcome=failed
  esc_record empty-summary "corr_id=$corr" task_id=hibit 'request_summary=' recovery_delivery_outcome=unknown
  esc_record accents "corr_id=$corr" task_id=hibit $'request_summary=caf\303\251 S' recovery_delivery_outcome=failed
  esc_record rewritten "corr_id=$corr" task_id=old 'request_summary=old' task_id=hibit 'request_summary=S'
  esc_record no-task "corr_id=$corr" 'request_summary=S' recovery_delivery_outcome=failed
  esc_record other-corr corr_id=fedcba9876543210 task_id=hibit 'request_summary=S'
  esc_record no-corr task_id=hibit 'request_summary=S'
  : > "$cases/records/empty"
  esc_status() {  # <name> <line>...: a status file of exactly these lines
    local name=$1
    shift
    printf '%s\n' "$@" > "$cases/$name.status"
  }
  for token in missed delivery-unknown recovery-delivery-failed recovery-delivery-unknown; do
    esc_status "keyed-$token" "blocked [key=$key]: pending-reply-$token: $ids request=S"
    esc_status "suffix-$token" "blocked [key=$key]: pending-reply-$token: $ids request=S more words"
    esc_status "legacy-$token" "blocked: pending-reply-$token: $ids request=S"
    esc_status "legacy-suffix-$token" "blocked: pending-reply-$token: $ids request=S tail"
  done
  esc_status timed "working: a" "blocked [key=$key] [at=1792600000]: pending-reply-missed: $ids request=S"
  esc_status timed-legacy "blocked [at=1792600000]: pending-reply-recovery-delivery-failed: $ids request=S"
  esc_status bad-time "blocked [key=$key] [at=17:00]: pending-reply-missed: $ids request=S"
  esc_status corr-verb "blocked corr=$corr [key=$key]: pending-reply-missed: $ids request=S"
  esc_status foreign-key "blocked [key=release]: pending-reply-missed: $ids request=S"
  esc_status glued "blocked [key=$key]: pending-reply-missed: $ids request=Sx"
  esc_status glob-literal "blocked [key=$key]: pending-reply-missed: $ids request=S*[a]?"
  esc_status glob-wild "blocked [key=$key]: pending-reply-missed: $ids request=Sxxa!"
  esc_status accents "blocked: pending-reply-missed: $ids request="$'caf\303\251 S'
  esc_status empty-summary "blocked [key=$key]: pending-reply-delivery-unknown: $ids request="
  esc_status not-blocked "needs-decision [key=$key]: pending-reply-missed: $ids request=S" \
    "resolved [key=$key]: pending-reply-missed: $ids request=S"
  esc_status verbs "Blocked: pending-reply-missed: $ids request=S" \
    "  blocked: pending-reply-missed: $ids request=S" "blockedx: pending-reply-missed: $ids request=S"
  esc_status last-wins "blocked: pending-reply-missed: $ids request=S first" "working: between" \
    "blocked [key=$key]: pending-reply-delivery-unknown: $ids request=S second" "blocked: unrelated"
  esc_status prose "working: a" "plain prose" ""
  : > "$cases/empty.status"
  printf 'blocked [key=%s]: pending-reply-missed: %s request=S\r\n' "$key" "$ids" > "$cases/crlf.status"
  printf 'working: a\nblocked [key=%s]: pending-reply-missed: %s request=S' "$key" "$ids" > "$cases/unterminated.status"
  printf 'blo\0cked [key=%s]: pending-reply-missed: %s request=S\n' "$key" "$ids" > "$cases/nul.status"
  printf 'blocked: \377\376\nblocked [key=%s]: pending-reply-missed: %s request=S \342\n' "$key" "$ids" > "$cases/high-bytes.status"
  esc_status short "blocked [key=$key]: pending-reply-missed: $ids request=S"
  {
    for ((i = 1; i <= 300; i++)); do
      printf 'working [at=%s]: step %s\n' "$((1792000000 + i))" "$i"
      printf 'blocked [key=b%s]: unrelated blocker %s\n' "$((i % 7))" "$i"
    done
    printf 'blocked [key=%s]: pending-reply-missed: %s request=S\n' "$key" "$ids"
  } > "$cases/long.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-pending-reply-lib.sh"
set -u
cases=$2 corr=0123456789abcdef
# The per-line scan the fork-free one replaced, kept as the reference.
ref_escalation_line() {  # <status-file> <record-path> <corr_id>
  local status_file=$1 rec=$2 corr=$3 line found='' kind payload own_key untimed
  [ -f "$status_file" ] || return 0
  [ "$(fm_pending_reply_get "$rec" corr_id)" = "$corr" ] || return 0
  own_key=$(fm_pending_reply_escalation_key "$corr")
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = blocked ] || continue
    _fm_status_untimed "$line" untimed
    for kind in missed delivery-unknown recovery-delivery; do
      payload=$(fm_pending_reply_escalation_payload "$rec" "$kind") || continue
      case "$untimed" in
        "blocked [key=$own_key]: $payload"|"blocked: $payload") found=$line; break ;;
        "blocked [key=$own_key]: $payload "*|"blocked: $payload "*) found=$line; break ;;
      esac
    done
  done < "$status_file"
  printf '%s' "$found"
}
matched=0
compare() {  # <status-file> <record-name> [corr]
  local want got
  want=$(ref_escalation_line "$1" "$cases/records/$2" "${3:-$corr}" 2>&1; printf 'rc=%s' "$?")
  got=$(fm_pending_reply_escalation_line "$1" "$cases/records/$2" "${3:-$corr}" 2>&1; printf 'rc=%s' "$?")
  [ "$got" = "$want" ] || printf 'escalation line %s %s %s: new %q, old %q\n' "${1##*/}" "$2" "${3:-$corr}" "$got" "$want"
  [ "$want" = rc=0 ] || matched=$((matched + 1))
}
# Every line shape against the records that build each payload kind, and every
# record shape against the line shapes its payload decides.
for f in "$cases"/*.status "$cases/missing.status"; do
  [ "${f##*/}" != long.status ] || continue
  for r in failed unknown no-outcome; do compare "$f" "$r"; done
done
for r in "$cases"/records/* "$cases/records/missing"; do
  for f in keyed-missed legacy-recovery-delivery-failed suffix-recovery-delivery-unknown \
    glob-literal glob-wild accents empty-summary last-wins; do
    compare "$cases/$f.status" "${r##*/}"
  done
done
for f in keyed-missed legacy-delivery-unknown long; do compare "$cases/$f.status" failed fedcba9876543210; done
# Non-vacuity: the shapes above must select an escalation in many cases.
[ "$matched" -ge 40 ] || printf 'only %s cases selected an escalation\n' "$matched"
subshells() {  # <function> <status-file>: subshell commands one scan runs
  local log=$cases/subshells.$$ __level
  : > "$log"
  __level=$BASH_SUBSHELL
  set -T
  trap '[ "$BASH_SUBSHELL" -le "$__level" ] || printf "%s\n" "$BASH_COMMAND" >> "$log"' DEBUG
  "$1" "$2" "$cases/records/failed" "$corr" > /dev/null
  trap - DEBUG
  set +T
  grep -c . "$log" || true
  rm -f "$log"
}
short=$(subshells fm_pending_reply_escalation_line "$cases/short.status")
long=$(subshells fm_pending_reply_escalation_line "$cases/long.status")
[ "$short" -gt 0 ] && [ "$long" = "$short" ] \
  || printf 'a 601-line scan ran %s subshell commands, a 1-line scan %s\n' "$long" "$short"
none=$(subshells fm_pending_reply_escalation_line "$cases/prose.status")
[ "$none" -lt "$short" ] || printf 'a scan with no blocked line ran %s subshell commands, not fewer than %s\n' "$none" "$short"
# The counter sees the per-line subshells of the scan it replaced.
ref_short=$(subshells ref_escalation_line "$cases/short.status")
ref_long=$(subshells ref_escalation_line "$cases/long.status")
[ "$ref_long" -gt $((ref_short * 10)) ] || printf 'the reference scan ran %s and %s subshell commands\n' "$ref_long" "$ref_short"
exit 0
SH
  run_everywhere "pending-reply escalation line" "$script" "$cases"
  pass "the escalation-line scan selects what the per-line scan did, and its subshells do not grow with the log"
}

test_open_decisions_fold_matches_the_text_fold() {
  local script="$TMP_ROOT/open-decisions.sh" cases="$TMP_ROOT/open-decisions" i
  mkdir -p "$cases"
  printf 'working: a\nneeds-decision [key=k1]: first\nblocked [key=b1]: stuck\nresolved [key=k1]: yes\nneeds-decision [key=k2]: second\nneeds-decision [key=k2]: second again\n' > "$cases/basic.status"
  printf 'blocked [key=b1]: one\nblocked [key=held-b2]: alert store\nneeds-decision [key=d1]: keep\nblocked [key=pending-reply-x]: pending-reply-x: reserved\nnote [supersedes=relaunch]: relaunched\nblocked [key=b3]: after\nnote [supersedes=bogus]: kept\nnote: plain note\n' > "$cases/supersede.status"
  printf 'needs-decision [key=pending-reply-a]: no prefix in note\nneeds-decision [key=pending-reply-b]: pending-reply-b: proper\nresolved [key=pending-reply-b]: wrong closer\nresolved [key=handoff-tj-c]: handoff-tj-c: nothing open\nblocked [key=handoff-pickup-d]: handoff-pickup-d: open\n' > "$cases/reserved.status"
  printf 'needs-decision [key=a]: x\ndone: shipped\nneeds-decision [key=b]: y\nfailed: gone\nblocked [key=c]: z\ndone without colon\n' > "$cases/done.status"
  printf 'needs-decision: keyless\nblocked: keyless blocker\ncaptain-held [key=default]: held\nneeds-decision [key=Bad Slug]: refused\nneeds-decision corr=0123456789abcdef [key=c1]: corr\nresolved corr=0123456789abcdef [key=c1]: closed\nneeds-decision [at=1792600000] [key=t1]: stamped\nneeds-decision [key=h1]\nprose with [key=p1] inside\nneeds-decision [at=17:00]: time tag\n' > "$cases/shapes.status"
  printf 'needs-decision [key=a]: x\r\nblocked [key=b]: \377\376\nneeds-decision [key=c]: caf\303\251\nblocked [key=d]: tab\there\n\n\n  \nneeds-decision [key=e]: unterminated' > "$cases/bytes.status"
  # A NUL run inside a line, which read drops: the mid-line capture ends just
  # after it, and a 16-byte step crosses it.
  printf 'working: s\nn\000\000eeds-decision [key=q]: x\nworking: z\n' > "$cases/nul.status"
  {
    for ((i = 1; i <= 120; i++)); do
      printf 'needs-decision [key=k%s]: open %s\n' "$((i % 17))" "$i"
      printf 'blocked [key=b%s]: block %s\n' "$((i % 5))" "$i"
      [ $((i % 7)) -eq 0 ] && printf 'resolved [key=k%s]: closed\n' "$((i % 17))"
      [ $((i % 11)) -eq 0 ] && printf 'note [supersedes=resume]: resumed\n'
      [ $((i % 13)) -eq 0 ] && printf 'blocked [key=held-%s]: held\n' "$i"
      [ $((i % 19)) -eq 0 ] && printf 'blocked [key=n%s]: nul\000\000\000\000\000\000\000\000 run %s\n' "$i" "$i"
      printf 'working: step %s\n' "$i"
    done
  } > "$cases/long.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
set -u
cases=$2
# A registered alert store holds every held-* key. The stub also sets a
# registration global, which the fold must not leak into its caller.
fm_alert_store_holds() {
  FM_ALERT_REG_LEAK=1
  case "$2" in held-*) return 0 ;; esac
  return 1
}
# The text fold the in-shell fold replaced, kept as the reference.
ref_drop_blocked() {  # <open-set>
  local line out='' rest
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rest=${line#*$'\t'}
    case "$rest" in
      blocked$'\t'*) _fm_decision_key_protected "${line%%$'\t'*}" || continue ;;
    esac
    out="${out}${line}"$'\n'
  done <<EOF
$1
EOF
  printf '%s' "$out"
}
ref_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb> <kind>
  local open=$1 line=$2 resolve=$3 held=$4 kind=$5 verb key note unstamped
  _fm_status_unstamped "$line" unstamped
  case "$unstamped" in
    *:*|*\[key=*\]*) ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  status_line_verb "$line" verb
  case "$unstamped" in
    *:*) case "$verb:$kind" in done:ship|done:scout|failed:ship|failed:scout) return 0 ;; esac ;;
  esac
  if [ "$verb" = note ]; then
    case "$unstamped" in
      *:*) status_supersedes_kind "$line" >/dev/null && open=$(ref_drop_blocked "$open") ;;
    esac
    [ -n "$open" ] && open="${open}"$'\n'
    printf '%s' "$open"
    return 0
  fi
  case "$verb" in
    needs-decision|blocked|"$resolve"|"$held") ;;
    *) printf '%s' "$open"; return 0 ;;
  esac
  key=$(_fm_decision_key "$line") || { printf '%s' "$open"; return 0; }
  _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")" \
    || { printf '%s' "$open"; return 0; }
  case "$verb" in
    needs-decision|blocked)
      note=$(status_line_note "$line")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
      ;;
    "$resolve"|"$held")
      open=$(_fm_decision_drop "$open" "$key")
      [ -n "$open" ] && open="${open}"$'\n'
      ;;
  esac
  printf '%s' "$open"
}
ref_open_decisions() {  # <status-file> <kind>
  local f=$1 kind=$2 line resolve held open='' verb
  local _fm_fold_status_file=$1
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb
    case "$verb" in
      needs-decision|blocked|done|failed|note|"$resolve"|"$held")
        open=$(ref_fold_line "$open" "$line" "$resolve" "$held" "$kind")
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}
for f in "$cases"/*.status; do
  for kind in ship scout secondmate; do
    want=$(ref_open_decisions "$f" "$kind"; printf x)
    got=$(status_open_decisions "$f" "$kind"; printf x)
    [ "$got" = "$want" ] || printf 'whole fold %s (%s): new %q, old %q\n' "${f##*/}" "$kind" "$got" "$want"
    unset FM_ALERT_REG_LEAK
    status_open_decisions "$f" "$kind" > /dev/null
    [ -z "${FM_ALERT_REG_LEAK+x}" ] || printf 'whole fold %s (%s) leaked alert-store globals\n' "${f##*/}" "$kind"
  done
done
# The text-form wrapper on sets carrying blank lines and a trailing newline,
# which a persisted cursor set may hold, read as every caller reads it: through
# a command substitution, which drops the trailing newlines the old fold left.
_fm_fold_status_file=$cases/supersede.status
for set in '' $'a\tblocked\tx' $'\na\tblocked\tx' $'a\tblocked\tx\n\nb\tneeds-decision\ty' \
  $'a\tblocked\tx\n' $'a\tblocked\tx\n\n' $'\n' $'held-z\tblocked\th\n\nq\tblocked\tr'; do
  for line in 'working: x' 'note: plain' 'note [supersedes=relaunch]: r' 'needs-decision [key=a]: n' \
    'resolved [key=a]: r' 'blocked [key=c]: c' 'done: d' 'resolved [key=zz]: none' 'prose' ''; do
    want=$(ref_fold_line "$set" "$line" resolved captain-held ship)
    got=$(_fm_decision_fold_line "$set" "$line" resolved captain-held ship)
    [ "$got" = "$want" ] || printf 'fold line %q on %q: new %q, old %q\n' "$line" "$set" "$got" "$want"
  done
done
# The cursor-backed fold: a reset (no cursor) folds the whole log from byte 0,
# and a fold split at a line boundary carries its set through the cursor. Both
# must equal the old text fold of every line, which is what the old incremental
# loop ran.
prefixes=$cases.prefixes
mkdir -p "$prefixes"
ref_incremental() {  # <status-file>
  local f=$1 line open='' kind
  local _fm_fold_status_file=$1
  kind=$(_fm_status_kind "$f")
  while IFS= read -r line || [ -n "$line" ]; do
    open=$(ref_fold_line "$open" "$line" resolved captain-held "$kind")
  done < "$f"
  printf '%s' "$open"
}
for f in "$cases"/*.status; do
  name=${f##*/}
  want=$(ref_incremental "$f"; printf x)
  rm -f "$cases/.${name%.status}.open-decisions-cursor"
  got=$(status_open_decisions_incremental "$f"; printf x)
  [ "$got" = "$want" ] || printf 'incremental reset %s: new %q, old %q\n' "$name" "$got" "$want"
  rm -f "$cases/.${name%.status}.open-decisions-cursor" "$cases/.${name%.status}.snapshot-open-decisions-cursor"
  size=$(wc -c < "$f" | tr -d ' ')
  half=$(head -c $((size / 2)) "$f" | wc -l | tr -d ' ')
  half=$(head -n "$half" "$f" | wc -c | tr -d ' ')
  status_open_decisions_incremental "$f" "$half" exact > /dev/null
  got=$(status_open_decisions_incremental "$f" "$size" exact; printf x)
  [ "$got" = "$want" ] || printf 'incremental split %s at %s: new %q, old %q\n' "$name" "$half" "$got" "$want"
  [ ! -e "$cases/.${name%.status}.open-decisions-cursor" ] \
    || printf 'exact fold of %s wrote the drain cursor\n' "$name"
  # A capture that ends inside a line answers with the whole fold of exactly
  # those bytes, but the cursor stops at the last newline and holds only the
  # fold of complete lines, so the next fold reads that line whole.
  rm -f "$cases/.${name%.status}.snapshot-open-decisions-cursor"
  mid=$((half + 3))
  [ "$mid" -lt "$size" ] || continue
  head -c "$mid" "$f" > "$prefixes/$name"
  want_mid=$(ref_incremental "$prefixes/$name"; printf x)
  got=$(status_open_decisions_incremental "$f" "$mid" exact; printf x)
  [ "$got" = "$want_mid" ] || printf 'incremental mid-line capture %s at %s: new %q, old %q\n' "$name" "$mid" "$got" "$want_mid"
  cursor_offset=$(sed -n 's/^offset=//p' "$cases/.${name%.status}.snapshot-open-decisions-cursor")
  [ "$cursor_offset" -le "$mid" ] && { [ "$cursor_offset" = 0 ] \
    || [ "$(head -c "$cursor_offset" "$f" | tail -c 1 | od -An -tx1 | tr -d ' ')" = 0a ]; } \
    || printf 'mid-line capture %s at %s left the cursor off a line boundary at %s\n' "$name" "$mid" "$cursor_offset"
  got=$(status_open_decisions_incremental "$f" "$size" exact; printf x)
  [ "$got" = "$want" ] || printf 'incremental after mid-line capture %s at %s: new %q, old %q\n' "$name" "$mid" "$got" "$want"
  # A checkpoint step shorter than some lines reads them again, wider, and
  # ends at the same answer and cursor as one read.
  whole_cursor=$(cat "$cases/.${name%.status}.snapshot-open-decisions-cursor")
  rm -f "$cases/.${name%.status}.snapshot-open-decisions-cursor"
  got=$(FM_OPEN_DECISIONS_CHECKPOINT_BYTES=16 status_open_decisions_incremental "$f" "$size" exact; printf x)
  [ "$got" = "$want" ] || printf 'incremental in 16-byte steps %s: new %q, old %q\n' "$name" "$got" "$want"
  [ "$(cat "$cases/.${name%.status}.snapshot-open-decisions-cursor")" = "$whole_cursor" ] \
    || printf 'incremental in 16-byte steps %s left a different cursor\n' "$name"
done
# The reviewer's case: a capture ending inside a closer must not leave the
# decision open once the closer is whole.
rm -f "$prefixes/.split.snapshot-open-decisions-cursor"
printf 'needs-decision [key=k1]: a\nresolved [key=k1]: done\nneeds-decision [key=k2]: b\n' > "$prefixes/split.status"
mid=$(printf 'needs-decision [key=k1]: a\nresolved [key=k' | wc -c | tr -d ' ')
status_open_decisions_incremental "$prefixes/split.status" "$mid" exact > /dev/null
got=$(status_open_decisions_incremental "$prefixes/split.status" "$(wc -c < "$prefixes/split.status" | tr -d ' ')" exact)
[ "$got" = $'k2\tneeds-decision\tb' ] || printf 'a closer split by the capture left %q open\n' "$got"
# A capture ending in a NUL run that read drops still leaves the cursor on the
# line's first byte: neither the decision whose closer follows the NULs nor a
# line that only becomes a decision after them may change the answer.
for nul_case in 'working: s\nneeds-decision [key=q]: pi|resolved [key=q]: ok\n' \
  'working: sta|needs-decision [key=q]: x\n'; do
  rm -f "$prefixes/.nul.snapshot-open-decisions-cursor"
  { printf "${nul_case%%|*}"; head -c 30 /dev/zero; } > "$prefixes/nul.status"
  size=$(wc -c < "$prefixes/nul.status" | tr -d ' ')
  status_open_decisions_incremental "$prefixes/nul.status" "$size" exact > /dev/null
  cursor_offset=$(sed -n 's/^offset=//p' "$prefixes/.nul.snapshot-open-decisions-cursor")
  [ "$cursor_offset" = "$(printf "${nul_case%%|*}" | sed '$d' | wc -c | tr -d ' ')" ] \
    || printf 'a NUL tail %q left the cursor at %s\n' "${nul_case%%|*}" "$cursor_offset"
  printf "${nul_case#*|}" >> "$prefixes/nul.status"
  want=$(ref_incremental "$prefixes/nul.status"; printf x)
  got=$(status_open_decisions_incremental "$prefixes/nul.status" "$(wc -c < "$prefixes/nul.status" | tr -d ' ')" exact; printf x)
  [ "$got" = "$want" ] || printf 'the fold after a NUL tail %q: new %q, old %q\n' "${nul_case%%|*}" "$got" "$want"
done
# Exact mode keeps its read chunk under TMPDIR: a fold killed mid-read leaves
# nothing beside the status log for a refresh's sweep to miss. Each killed
# child runs in a subshell with stderr closed, and exits after it rather than
# being exec'd as the subshell's last command, so the shell's own "Killed"
# notice lands on that closed stderr and stays out of the case output.
rm -rf "$prefixes/killed" "$prefixes/killed-tmp"
mkdir -p "$prefixes/killed" "$prefixes/killed-tmp"
cp "$cases/long.status" "$prefixes/killed/t.status"
( TMPDIR="$prefixes/killed-tmp" "$BASH" -c '. "$1/bin/fm-classify-lib.sh"; eval "$3"; _fm_od_fold_line() { kill -9 $$; }
  status_open_decisions_incremental "$2" "$(wc -c < "$2" | tr -d " ")" exact' _ "$1" "$prefixes/killed/t.status" \
  "$(declare -f fm_alert_store_holds)" > /dev/null 2>&1; exit $? ) 2>/dev/null && printf 'the killed exact fold was not killed\n'
left=$(cd "$prefixes/killed" && ls -A | grep -vx 't.status')
[ -z "$left" ] || printf 'a killed exact fold left %s beside the status log\n' "$left"
case "$(cd "$prefixes/killed-tmp" && ls -A)" in
  fm-open-decisions-read.??????) ;;
  *) printf 'a killed exact fold did not keep its chunk under TMPDIR: %s\n' "$(ls -A "$prefixes/killed-tmp")" ;;
esac
# A cold fold killed partway still leaves a checkpoint at a line boundary, so
# the next fold reads only the rest and answers as a whole fold does. The child
# carries the same alert-store stub, or its checkpoint drops held keys the
# reference keeps.
rm -rf "$prefixes/killed-tmp"
mkdir -p "$prefixes/killed-tmp"
size=$(wc -c < "$prefixes/killed/t.status" | tr -d ' ')
( TMPDIR="$prefixes/killed-tmp" FM_OPEN_DECISIONS_CHECKPOINT_BYTES=512 "$BASH" -c '. "$1/bin/fm-classify-lib.sh"
  eval "$4"
  eval "_fm_real_fold() $(declare -f _fm_od_fold_line | sed 1d)"
  n=0
  _fm_od_fold_line() { n=$((n + 1)); [ "$n" -lt 100 ] || kill -9 $$; _fm_real_fold "$@"; }
  status_open_decisions_incremental "$2" "$3" exact' _ "$1" "$prefixes/killed/t.status" "$size" \
  "$(declare -f fm_alert_store_holds)" > /dev/null 2>&1; exit $? ) 2>/dev/null && printf 'the checkpointed exact fold was not killed\n'
cursor="$prefixes/killed/.t.snapshot-open-decisions-cursor"
cursor_offset=$(sed -n 's/^offset=//p' "$cursor" 2>/dev/null)
case "$cursor_offset" in
  ''|0|*[!0-9]*) printf 'a killed cold fold left no checkpoint: %q\n' "$cursor_offset" ;;
  *)
    [ "$(head -c "$cursor_offset" "$prefixes/killed/t.status" | tail -c 1 | od -An -tx1 | tr -d ' ')" = 0a ] \
      || printf 'a killed cold fold checkpointed off a line boundary at %s\n' "$cursor_offset"
    rm -f "$prefixes/probe"
    want=$(ref_incremental "$prefixes/killed/t.status"; printf x)
    got=$(FM_OPEN_DECISIONS_READ_PROBE="$prefixes/probe" status_open_decisions_incremental \
      "$prefixes/killed/t.status" "$size" exact; printf x)
    [ "$got" = "$want" ] || printf 'the fold after a killed cold fold: new %q, old %q\n' "$got" "$want"
    [ "$(cut -f2 "$prefixes/probe")" = "$((size - cursor_offset))" ] \
      || printf 'the fold after a killed cold fold read %s bytes, not the %s after its checkpoint\n' \
        "$(cut -f2 "$prefixes/probe")" "$((size - cursor_offset))"
    ;;
esac
# A cursor already past the capture answers for the capture without a fold
# when the lines between cannot move the set, and folds the capture from byte 0
# when they can; the newer cursor stays either way.
printf 'working: one\nworking: two\nworking: three\nneeds-decision [key=a]: x\nblocked [key=b]: y\nresolved [key=a]: z\n' > "$prefixes/ahead.status"
rm -f "$prefixes/.ahead.snapshot-open-decisions-cursor" "$prefixes/probe"
size=$(wc -c < "$prefixes/ahead.status" | tr -d ' ')
want=$(ref_incremental "$prefixes/ahead.status"; printf x)
printf 'working: later\nprose: [key=a] in passing\n' >> "$prefixes/ahead.status"
status_open_decisions_incremental "$prefixes/ahead.status" "$(wc -c < "$prefixes/ahead.status" | tr -d ' ')" exact > /dev/null
ahead_cursor=$(cat "$prefixes/.ahead.snapshot-open-decisions-cursor")
got=$(FM_OPEN_DECISIONS_READ_PROBE="$prefixes/probe" status_open_decisions_incremental "$prefixes/ahead.status" "$size" exact; printf x)
[ "$got" = "$want" ] || printf 'a cursor ahead over inert lines: new %q, whole fold %q\n' "$got" "$want"
[ ! -s "$prefixes/probe" ] || printf 'a cursor ahead over inert lines still folded %s\n' "$(cat "$prefixes/probe")"
printf 'needs-decision [key=c]: later\n' >> "$prefixes/ahead.status"
status_open_decisions_incremental "$prefixes/ahead.status" "$(wc -c < "$prefixes/ahead.status" | tr -d ' ')" exact > /dev/null
ahead_cursor=$(cat "$prefixes/.ahead.snapshot-open-decisions-cursor")
got=$(FM_OPEN_DECISIONS_READ_PROBE="$prefixes/probe" status_open_decisions_incremental "$prefixes/ahead.status" "$size" exact; printf x)
[ "$got" = "$want" ] || printf 'a cursor ahead over a transition: new %q, whole fold %q\n' "$got" "$want"
[ "$(cut -f2 "$prefixes/probe")" = "$size" ] || printf 'a cursor ahead over a transition did not fold the capture whole: %s\n' "$(cat "$prefixes/probe")"
[ "$(cat "$prefixes/.ahead.snapshot-open-decisions-cursor")" = "$ahead_cursor" ] \
  || printf 'a cursor ahead of the capture was moved\n'
# A cursor that cannot be written costs only the saved reading: the call still
# answers, and the old cursor stays.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$prefixes/ro"
  printf 'needs-decision [key=a]: x\n' > "$prefixes/ro/r.status"
  status_open_decisions_incremental "$prefixes/ro/r.status" 26 exact > /dev/null
  ro_cursor=$(cat "$prefixes/ro/.r.snapshot-open-decisions-cursor")
  printf 'blocked [key=b]: y\n' >> "$prefixes/ro/r.status"
  chmod 555 "$prefixes/ro"
  got=$(status_open_decisions_incremental "$prefixes/ro/r.status" 45 exact; printf x)
  chmod 755 "$prefixes/ro"
  [ "$got" = $'a\tneeds-decision\tx\nb\tblocked\tyx' ] || printf 'an unwritable cursor lost the answer: %q\n' "$got"
  [ "$(cat "$prefixes/ro/.r.snapshot-open-decisions-cursor")" = "$ro_cursor" ] \
    || printf 'an unwritable cursor directory still changed the cursor\n'
  [ "$(cd "$prefixes/ro" && ls -A | tr '\n' ' ')" = '.r.snapshot-open-decisions-cursor r.status ' ] \
    || printf 'an unwritable cursor directory gained %s\n' "$(ls -A "$prefixes/ro")"
  rm -rf "$prefixes/ro"
fi
# status_key_closing_verb folds its candidates in the current shell too. Its
# candidate grep warns on the binary bytes case in both versions.
ref_key_closing_verb() {  # <status-file> <key>
  local f=$1 want=$2 line resolve held open='' was verb='' kind event candidates
  local _fm_fold_status_file=$1
  kind=$(_fm_status_kind "$f")
  resolve=resolved held=captain-held
  candidates=$(grep -E \
    "^[[:space:]]*(needs-decision|blocked|done|failed|note|$resolve|$held)[[:space:]:[]" \
    "$f") || [ "$?" -eq 1 ] || candidates=$(cat "$f")
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" event
    case "$event:$kind" in
      done:ship|done:scout|failed:ship|failed:scout) ;;
      note:*) status_supersedes_kind "$line" >/dev/null || continue ;;
      *)
        case "$event" in
          needs-decision|blocked|"$resolve"|"$held") ;;
          *) continue ;;
        esac
        if [ "$want" != default ]; then
          case "$line" in *"[key=$want]"*) ;; *) continue ;; esac
        fi
        ;;
    esac
    was=0
    _fm_open_set_has "$open" "$want" && was=1
    open=$(ref_fold_line "$open" "$line" "$resolve" "$held" "$kind")
    if [ "$was" = 1 ] && ! _fm_open_set_has "$open" "$want"; then
      verb=$event
    fi
  done <<EOF
$candidates
EOF
  if _fm_open_set_has "$open" "$want"; then
    _fm_open_set_verb "$open" "$want"
    return 0
  fi
  printf '%s' "$verb"
}
for f in "$cases"/*.status; do
  for key in default k1 k2 b1 b3 held-b2 c1 pending-reply-b handoff-pickup-d k5 b2 absent; do
    want=$(ref_key_closing_verb "$f" "$key" 2>/dev/null; printf x)
    got=$(status_key_closing_verb "$f" "$key" 2>/dev/null; printf x)
    [ "$got" = "$want" ] || printf 'closing verb %s %s: new %q, old %q\n' "${f##*/}" "$key" "$got" "$want"
  done
done
exit 0
SH
  run_everywhere "open-decisions fold" "$script" "$cases"
  pass "the whole, incremental and closing-verb folds match the text fold they replaced on every log and set shape"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_directory_helper_matches_cd_and_pwd
  test_library_loads_match_the_subshells_they_replaced
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_and_meta_readers_match_the_meta_pipelines
  test_classify_stat_helpers_read_the_kernel_name_once
  test_file_readers_match_cat_and_od
  test_proc_identity_matches_the_forked_reader
  test_engine_identity_matches_the_pipeline_it_replaced
  test_path_age_helpers_match_stat_and_the_clock
  test_status_signature_reads_once_and_matches_the_forked_reader
  test_unread_line_scan_matches_the_loop_it_replaced
  test_status_event_reads_match_the_tail_pipeline
  test_watcher_poll_helpers_match_what_they_replaced
  test_inbox_due_action_matches_what_it_replaced
  test_watcher_capture_matches_what_it_replaced
  test_busy_classify_matches_what_it_replaced
  test_pending_reply_correlation_matches_forked_token
  test_pending_reply_escalation_line_matches_the_per_line_scan
  test_open_decisions_fold_matches_the_text_fold
fi
