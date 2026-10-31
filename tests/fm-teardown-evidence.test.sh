#!/usr/bin/env bash
# tests/fm-teardown-evidence.test.sh - fm_task_evidence_verify_copies, the
# source-against-copy hash comparison that teardown's evidence preservation
# runs over every declared file. tests/fm-teardown.test.sh covers it through
# whole teardowns; these cases call the library directly, so they can compare
# its verdicts with batched and per-file hashing and time it on an evidence set
# far larger than a teardown fixture can build.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-teardown-evidence)
LIB="$ROOT/bin/fm-task-evidence-lib.sh"

# Run fm_task_evidence_verify_copies on <src-root>/<rel> against
# <copy-root>/<rel> for each <rel>, with <fakebin> first on PATH.
run_verify() {  # <fakebin> <manifest> <src-root> <copy-root> <rel>...
  local fakebin=$1
  shift
  # shellcheck disable=SC2016 # Positional parameters belong to the child bash.
  PATH="$fakebin:$PATH" bash -c '
    . "$1"; manifest=$2 src=$3 copy=$4; shift 4
    FM_TE_PATHS=() FM_TE_RELS=()
    for rel in "$@"; do FM_TE_PATHS+=("$src$rel"); FM_TE_RELS+=("$rel"); done
    for rel in "$@"; do FM_TE_PATHS+=("$copy$rel"); done
    fm_task_evidence_verify_copies "$manifest" key
  ' _ "$LIB" "$@"
}

# A shasum stand-in over the host's real hash tool. In per-file mode a run over
# more than one path fails, so the library falls back to hashing each path
# alone; the path named by <blank> hashes to an empty line in either mode.
make_hash_tool() {  # <fakebin> <batch|per-file> <blank-path or ''>
  local real tool
  mkdir -p "$1"
  if real=$(command -v shasum); then
    tool="\"$real\" -a 256"
  else
    real=$(command -v sha256sum) || fail 'shasum or sha256sum needed'
    tool="\"$real\""
  fi
  cat > "$1/shasum" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = '-a 256' ] && shift 2
[ "$2" = batch ] || [ "\$#" -le 1 ] || exit 1
for path in "\$@"; do
  if [ "\$path" = "$3" ]; then printf '\n'; continue; fi
  $tool "\$path" || exit
done
SH
  chmod +x "$1/shasum"
}

real_hash() {  # <path>
  { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | awk '{print $1}'
}

test_verdicts_match_in_batched_and_per_file_hashing() {
  local verdict mode dir rc
  for verdict in match mismatch missing-copy empty-hash; do
    for mode in batch per-file; do
      dir="$TMP_ROOT/verdict-$verdict-$mode"
      mkdir -p "$dir/src" "$dir/copy"
      printf 'first\n' > "$dir/src/a.txt"
      printf 'middle\n' > "$dir/src/m.txt"
      printf 'last\n' > "$dir/src/z.txt"
      cp -p "$dir/src/"*.txt "$dir/copy/"
      case "$verdict" in
        mismatch) printf 'changed\n' >> "$dir/copy/m.txt" ;;
        missing-copy) rm -- "$dir/copy/m.txt" ;;
      esac
      if [ "$verdict" = empty-hash ]; then
        make_hash_tool "$dir/fakebin" "$mode" "$dir/copy/m.txt"
      else
        make_hash_tool "$dir/fakebin" "$mode" ''
      fi
      : > "$dir/manifest"
      rc=0
      run_verify "$dir/fakebin" "$dir/manifest" "$dir/src" "$dir/copy" /a.txt /m.txt /z.txt \
        > "$dir/stdout" 2> "$dir/stderr" || rc=$?
      if [ "$verdict" = match ]; then
        expect_code 0 "$rc" "$verdict $mode: matching copies must verify: $(cat "$dir/stderr")"
        printf '%s  key/a.txt\n%s  key/m.txt\n%s  key/z.txt\n' \
          "$(real_hash "$dir/src/a.txt")" "$(real_hash "$dir/src/m.txt")" "$(real_hash "$dir/src/z.txt")" \
          > "$dir/want"
        cmp -s "$dir/want" "$dir/manifest" || fail "$verdict $mode: manifest differs: $(cat "$dir/manifest")"
        continue
      fi
      expect_code 1 "$rc" "$verdict $mode: the copy of m.txt must refuse"
      # The refusal stops at m.txt: a.txt is recorded, z.txt never is.
      printf '%s  key/a.txt\n' "$(real_hash "$dir/src/a.txt")" > "$dir/want"
      cmp -s "$dir/want" "$dir/manifest" || fail "$verdict $mode: refusal recorded the wrong lines: $(cat "$dir/manifest")"
      if [ "$verdict" = mismatch ]; then
        assert_grep "REFUSED: copied evidence $dir/copy/m.txt does not match its source" "$dir/stderr" \
          "$verdict $mode: the mismatch must name the copy: $(cat "$dir/stderr")"
        [ "$(grep -c 'does not match its source' "$dir/stderr")" = 1 ] \
          || fail "$verdict $mode: exactly one mismatch should be named: $(cat "$dir/stderr")"
      else
        assert_no_grep 'does not match its source' "$dir/stderr" \
          "$verdict $mode: an unreadable hash is not a content mismatch"
      fi
    done
  done
  pass 'match, mismatch, missing copy and empty hash give the same verdict, message and recorded lines batched and per file'
}

test_a_single_file_declaration_records_its_key() {
  local mode dir rc
  for mode in batch per-file; do
    dir="$TMP_ROOT/single-$mode"
    mkdir -p "$dir"
    printf 'proof\n' > "$dir/src.txt"
    cp -p "$dir/src.txt" "$dir/copy.txt"
    make_hash_tool "$dir/fakebin" "$mode" ''
    : > "$dir/manifest"
    rc=0
    run_verify "$dir/fakebin" "$dir/manifest" "$dir/src.txt" "$dir/copy.txt" '' 2> "$dir/stderr" || rc=$?
    expect_code 0 "$rc" "single $mode: a matching file copy must verify: $(cat "$dir/stderr")"
    [ "$(cat "$dir/manifest")" = "$(real_hash "$dir/src.txt")  key" ] \
      || fail "single $mode: manifest should hold the bare key: $(cat "$dir/manifest")"
  done
  pass 'a single-file declaration records its key with no relative suffix, batched and per file'
}

# Reading the source and copy hashes at [i] and [n + i] in turn made the loop
# quadratic: 120,000 pairs took 103 seconds on a laptop, where reading
# each half in order took 9. The hash tool prints a fixed hash for every
# path, so no file is created and only the comparison loop is timed.
test_a_large_evidence_set_verifies_in_bounded_time() {
  local dir n=120000 rc
  dir="$TMP_ROOT/large"
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/shasum" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = '-a 256' ] && shift 2
for path in "$@"; do printf '%064d  %s\n' 0 "$path"; done
SH
  chmod +x "$dir/fakebin/shasum"
  : > "$dir/manifest"
  rc=0
  # shellcheck disable=SC2016 # Positional parameters belong to the child bash.
  PATH="$dir/fakebin:$PATH" fm_run_timed 60 bash -c '
    . "$1"; manifest=$2 n=$3
    FM_TE_PATHS=() FM_TE_RELS=()
    for ((i = 0; i < n; i++)); do FM_TE_RELS+=("/d$((i % 100))/f$i"); FM_TE_PATHS+=("/src/d$((i % 100))/f$i"); done
    for ((i = 0; i < n; i++)); do FM_TE_PATHS+=("/copy/d$((i % 100))/f$i"); done
    fm_task_evidence_verify_copies "$manifest" key
  ' _ "$LIB" "$dir/manifest" "$n" > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  ! fm_timed_out "$rc" || fail "verifying $n evidence copies did not finish within 60 seconds"
  expect_code 0 "$rc" "large: every copy should verify: $(head -5 "$dir/stderr")"
  [ "$(wc -l < "$dir/manifest" | tr -d ' ')" = "$n" ] || fail "large: manifest should list all $n copies"
  assert_grep "$(printf '%064d' 0)  key/d99/f119999" "$dir/manifest" 'large: the last copy was not recorded'
  pass "$n evidence copies verify within a 60-second bound"
}

test_verdicts_match_in_batched_and_per_file_hashing
test_a_single_file_declaration_records_its_key
test_a_large_evidence_set_verifies_in_bounded_time
