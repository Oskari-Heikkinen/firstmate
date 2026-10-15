#!/usr/bin/env bash
# fm-mutate.sh - a small, purpose-built mutation tester for Firstmate's bash
# scripts. It checks that the tests guarding a risky-area script fail when a
# guard in that script is broken: a mutant the tests still pass is a survivor.
# .github/workflows/mutation-audit.yml runs the sampled audit and the
# "Mutation check" job in .github/workflows/ci.yml runs the changed-lines check;
# docs/fm-test-portable-shards.md owns the rationale.
#
# Operators, each applied to the code part of one line (comments, heredoc
# bodies and blank lines are never mutated):
#   exit0   `exit N` / `return N` with N > 0 becomes 0
#   neg     `if !` / `elif !` / `while !` / `until !` loses its `!`
#   andor   ` && ` and ` || ` swap
#   cmp     a test comparison flips: -eq/-ne, -lt/-ge, -gt/-le, = or == / !=
#   zn      `-z` and `-n` swap
#   stmt    a complete guard statement (die, fail, refuse, exit, return,
#           flock, or a `[ ... ] && / ||` one-liner) becomes `:`
#
# A mutant is one TSV row: <id> <line> <op> <occurrence> <base64 original
# line>, with id `<file>:<line>:<op>:<occurrence>`. Carrying the original line
# lets a mutant sampled at one commit be applied at another: apply looks for
# that exact line nearest to <line>.
#
# Usage:
#   fm-mutate.sh list <file> [--max N] [--seed S] [--lines <a-b,c,...>]
#     Prints up to N (default 10) mutants, sampled deterministically by seed
#     and spread round-robin over the operators. Every printed mutant applies
#     and passes `bash -n`.
#   fm-mutate.sh apply <file> <mutant row>
#     Mutates <file> in place. Exit 3 when the original line is not in the
#     file, 4 when the mutant fails `bash -n` (the file is left unchanged).
#   fm-mutate.sh tests <script> [--tier <list> | --from-list <path>]
#     Prints the tests that guard <script>: tests in the pool (the gate and
#     full tiers, or the entries of <path>) that name the script and match
#     its risky area's test globs or the safety core; when none name it, the
#     pool's tests matching the area's test globs. Without --from-list, only
#     those in the given tiers (default gate,full) are kept, so a gate set is
#     always a subset of the gate-and-full set. Tests in the
#     real-herdr-gated family are left out.
#   fm-mutate.sh run <file> <mutant row> [--stop-on-kill]
#                    [--timeout-secs N] <test>...
#     Applies the mutant, runs the tests with bin/fm-test-run.sh, restores
#     the file, and prints one TSV row per test run:
#     <id> <test> killed|survived|timeout <duration_ms>. A timeout counts as a
#     kill. --stop-on-kill runs the tests one by one and stops at the first
#     kill; otherwise every test runs, in one invocation. Rows for a mutant
#     that cannot be applied say `absent` or `invalid` in the test column.
#     A row of `-` runs the tests on the unmutated file, as a sanity check;
#     its id is `<file>:unmutated`.
#   fm-mutate.sh report <dir>
#     Aggregates an audit's results into a Markdown kill matrix and parity
#     result. <dir> holds, per script, `*.current.tsv` (run rows at the
#     current commit, gate and full tests), `*.baseline.tsv` (run rows at the
#     pre-remake commit, old safety-core tests) and optional `*.rerun.tsv`
#     (both sides re-run for disputed mutants, ids suffixed `@current` or
#     `@baseline`). Tests failing their unmutated sanity row are not counted
#     as killers. Parity holds when every mutant the old core killed is
#     killed by a current gate-tier test.
#   fm-mutate.sh changed --base <ref> [--max N] [--budget-secs N]
#                        [--timeout-secs N] [--out <tsv>] [--scripts-only]
#     For each risky-area script changed since <ref>, samples mutants on its
#     added or changed lines (at most N, default 20, over all scripts) and
#     runs each against the script's gate-tier tests with --stop-on-kill,
#     until the budget (default 900 seconds) is spent. Prints a Markdown
#     report; survivors are listed but do not fail it. --scripts-only just
#     prints the changed risky-area scripts.
#
# It works in the checkout holding it, or in FM_MUTATE_ROOT when set (the audit
# points it at an older checkout); file and test paths are relative to that root. Exit status: 0 done, 1 a
# test run could not be judged, 2 a usage error; apply also uses 3 and 4.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${FM_MUTATE_ROOT:-$(cd "$SELF_DIR/.." && pwd)}
TEST_RUN="$ROOT/bin/fm-test-run.sh"
AREAS_LIST=tests/risky-areas.list
CORE_LIST=tests/safety-core.list
TIERS_LIST=tests/tiers.list

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

die() {
  printf 'fm-mutate: %s\n' "$*" >&2
  exit 2
}

# The mutation engine. MODE=list prints `<line>\t<op>\t<occ>\t<new line>` for
# every candidate; MODE=apply prints the file with mutant (LINE, OP, OCC)
# applied, or nothing when that mutant does not exist.
# shellcheck disable=SC2016 # an awk program, expanded by awk
MUTATOR_AWK='
function add(op, text) { occ[op]++; nop++; mo[nop] = op; mc[nop] = occ[op]; mt[nop] = text }
function swap(op, tok,    t) {
  if (op == "andor") return tok == " && " ? " || " : " && "
  if (op == "zn") { t = tok; if (t ~ /-z/) sub(/-z/, "-n", t); else sub(/-n/, "-z", t); return t }
  if (op == "exit0") { t = tok; sub(/[1-9][0-9]*$/, "0", t); return t }
  if (op == "neg") { t = tok; sub(/![ \t]+/, "", t); return t }
  if (op == "cmp") {
    t = tok
    if (t ~ /-eq/) sub(/-eq/, "-ne", t); else if (t ~ /-ne/) sub(/-ne/, "-eq", t)
    else if (t ~ /-lt/) sub(/-lt/, "-ge", t); else if (t ~ /-ge/) sub(/-ge/, "-lt", t)
    else if (t ~ /-gt/) sub(/-gt/, "-le", t); else if (t ~ /-le/) sub(/-le/, "-gt", t)
    else if (t ~ /!=/) sub(/!=/, "=", t); else if (t ~ /==/) sub(/==/, "!=", t)
    else sub(/=/, "!=", t)
    return t
  }
  return ""
}
function each(code, tail, re, op,    pre, rest, tok) {
  rest = code; pre = ""
  while (match(rest, re)) {
    tok = substr(rest, RSTART, RLENGTH)
    add(op, pre substr(rest, 1, RSTART - 1) swap(op, tok) substr(rest, RSTART + RLENGTH) tail)
    pre = pre substr(rest, 1, RSTART + RLENGTH - 1); rest = substr(rest, RSTART + RLENGTH)
  }
}
function candidates(line,    code, tail, p, ind, word) {
  nop = 0; split("", occ)
  if (line ~ /^[ \t]*(#|$)/) return
  code = line; tail = ""
  if (match(code, /[ \t]#/)) { tail = substr(code, RSTART); code = substr(code, 1, RSTART - 1) }
  each(code, tail, "(^|[ \t;&|({])(exit|return)[ \t]+[1-9][0-9]*", "exit0")
  each(code, tail, "(^|[ \t;])(if|elif|while|until)[ \t]+![ \t]+", "neg")
  each(code, tail, " (&&|\\|\\|) ", "andor")
  if (code ~ /\[/) {
    each(code, tail, "[ \t](-eq|-ne|-lt|-le|-gt|-ge|==|!=|=)[ \t]", "cmp")
    each(code, tail, "[ \t]-[zn][ \t]", "zn")
  }
  if (code !~ /(\\|\{|\(|\||&&|then|do|else|in)[ \t]*$/ && code !~ /^[ \t]*(\}|\)|;;|esac|fi|done)/) {
    word = code; sub(/^[ \t]*/, "", word)
    if (word ~ /^(die|fail|refuse|[a-z_]*_die|[a-z_]*_fail|[a-z_]*_refuse|exit|return|flock)([ \t]|$)/ ||
        word ~ /^\[\[? .* \]\]? *(&&|\|\|) /) {
      ind = code; sub(/[^ \t].*$/, "", ind)
      add("stmt", ind ":" tail)
    }
  }
}
{
  out = $0
  if (term != "") {
    t = $0; if (strip) sub(/^\t+/, "", t)
    if (t == term) term = ""
  } else {
    if (MODE == "list") {
      if (want_line(NR)) { candidates($0); for (i = 1; i <= nop; i++) printf "%d\t%s\t%d\t%s\n", NR, mo[i], mc[i], mt[i] }
    } else if (NR == LINE) {
      candidates($0)
      for (i = 1; i <= nop; i++) if (mo[i] == OP && mc[i] == OCC) { out = mt[i]; hit = 1 }
    }
    if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/) && substr($0, RSTART - 1, 1) != "<" && substr($0, RSTART + 2, 1) != "<") {
      t = substr($0, RSTART, RLENGTH); strip = (t ~ /^<<-/)
      sub(/^<<-?[ \t]*["\047]?/, "", t); sub(/["\047]$/, "", t); term = t
    }
  }
  if (MODE == "apply") lines[NR] = out
}
function want_line(n,    i, k, r) {
  if (LINES == "") return 1
  k = split(LINES, r, ",")
  for (i = 1; i <= k; i++) {
    if (r[i] ~ /-/) { split(r[i], ab, "-"); if (n >= ab[1] + 0 && n <= ab[2] + 0) return 1 }
    else if (n == r[i] + 0) return 1
  }
  return 0
}
END { if (MODE == "apply" && hit) for (i = 1; i <= NR; i++) print lines[i] }
'

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
unb64() { printf '%s' "$1" | base64 -d; }

# list_all <file> <lines>: every candidate as `<line>\t<op>\t<occ>`.
list_all() {
  awk -v MODE=list -v LINES="$2" "$MUTATOR_AWK" "$1" | cut -f1-3
}

# apply_to <file> <line> <op> <occ> <out>: writes the mutated file to <out>.
apply_to() {
  awk -v MODE=apply -v LINE="$2" -v OP="$3" -v OCC="$4" "$MUTATOR_AWK" "$1" >"$5" && [ -s "$5" ]
}

cmd_list() {
  local file='' max=10 seed=1 lines='' tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max) [ "$#" -gt 1 ] || die "--max needs a number"; max=$2; shift 2 ;;
      --seed) [ "$#" -gt 1 ] || die "--seed needs a value"; seed=$2; shift 2 ;;
      --lines) [ "$#" -gt 1 ] || die "--lines needs a range list"; lines=$2; shift 2 ;;
      -*) die "list: unknown option: $1" ;;
      *) [ -z "$file" ] || die "list: one file only"; file=$1; shift ;;
    esac
  done
  [ -n "$file" ] && [ -f "$file" ] || die "list: file not found: ${file:-<none>}"
  case "$max" in ''|*[!0-9]*) die "--max needs a whole number" ;; esac
  tmp=$(mktemp) || exit 1
  # Order: a seeded hash of each candidate, then round-robin over operators.
  list_all "$file" "$lines" | awk -F '\t' -v seed="$seed" -v f="$file" '
    function h(s,    i, x) { x = 0; for (i = 1; i <= length(s); i++) x = (x * 31 + index(CH, substr(s, i, 1)) + 7) % 2147483647; return x }
    BEGIN { CH = " !\"#$%&\047()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~" }
    { k = h(seed ":" f ":" $1 ":" $2 ":" $3); print k "\t" $0 }' |
    sort -t "$(printf '\t')" -k1,1n |
    awk -F '\t' '{ r = ++n[$3]; printf "%d\t%s\t%s\t%s\n", r, $2, $3, $4 }' |
    sort -t "$(printf '\t')" -s -k1,1n | cut -f2- >"$tmp"
  local count=0 line op occ orig work
  work=$(mktemp) || exit 1
  while IFS="$(printf '\t')" read -r line op occ; do
    [ "$count" -lt "$max" ] || break
    apply_to "$file" "$line" "$op" "$occ" "$work" || continue
    bash -n "$work" 2>/dev/null || continue
    orig=$(sed -n "${line}p" "$file")
    printf '%s:%s:%s:%s\t%s\t%s\t%s\t%s\n' "$file" "$line" "$op" "$occ" "$line" "$op" "$occ" "$(b64 "$orig")"
    count=$((count + 1))
  done <"$tmp"
  rm -f "$tmp" "$work"
}

# mutant_fields <row>: sets M_ID M_LINE M_OP M_OCC M_ORIG.
mutant_fields() {
  IFS="$(printf '\t')" read -r M_ID M_LINE M_OP M_OCC M_ORIG <<EOF_ROW
$1
EOF_ROW
  [ -n "${M_ORIG:-}" ] || die "malformed mutant row: $1"
  case "$M_LINE$M_OCC" in ''|*[!0-9]*) die "malformed mutant row: $1" ;; esac
}

# apply_mutant <file> <row>: mutates in place; exit 3 absent, 4 invalid.
apply_mutant() {
  local file=$1 orig at work
  mutant_fields "$2"
  orig=$(unb64 "$M_ORIG")
  # The nearest line equal to the original, preferring the recorded number.
  # The line goes through the environment: awk -v would expand backslashes.
  at=$(FM_MUTATE_WANT=$orig awk -v near="$M_LINE" '
    $0 == ENVIRON["FM_MUTATE_WANT"] { d = NR - near; if (d < 0) d = -d; if (best == "" || d < far) { best = NR; far = d } }
    END { print best }' "$file")
  [ -n "$at" ] || return 3
  work=$(mktemp) || exit 1
  if ! apply_to "$file" "$at" "$M_OP" "$M_OCC" "$work" || ! bash -n "$work" 2>/dev/null; then
    rm -f "$work"
    return 4
  fi
  cat "$work" >"$file"
  rm -f "$work"
}

cmd_apply() {
  [ "$#" -eq 2 ] || die "apply needs <file> <mutant row>"
  [ -f "$1" ] || die "apply: file not found: $1"
  apply_mutant "$1" "$2"
}

# area_globs <script> <kind>: the risky-area globs of <kind> for <script>'s areas.
area_globs() {
  local script=$1 kind=$2 areas area k glob
  [ -f "$AREAS_LIST" ] || return 0
  areas=$(sed 's/#.*//' "$AREAS_LIST" | while read -r area k glob; do
    [ "$k" = script ] || continue
    # shellcheck disable=SC2053 # the glob is the pattern
    [[ $script == $glob ]] && printf '%s\n' "$area"
  done | sort -u)
  [ -n "$areas" ] || return 0
  sed 's/#.*//' "$AREAS_LIST" | while read -r area k glob; do
    [ "$k" = "$kind" ] || continue
    printf '%s\n' "$areas" | grep -qxF "$area" && printf '%s\n' "$glob"
  done
}

matches_any() { # <path> <globs>
  local glob
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    # shellcheck disable=SC2053 # the glob is the pattern
    [[ $1 == $glob ]] && return 0
  done <<EOF_GLOBS
$2
EOF_GLOBS
  return 1
}

tier_tests() { # <comma-separated tiers>
  sed 's/#.*//' "$TIERS_LIST" | awk -v want=",$1," 'NF == 2 && index(want, "," $1 ",") { print $2 }'
}

cmd_tests() {
  local script='' tier=gate,full from='' pool globs core gated t name rel=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tier) [ "$#" -gt 1 ] || die "--tier needs a list"; tier=$2; from=''; shift 2 ;;
      --from-list) [ "$#" -gt 1 ] || die "--from-list needs a path"; from=$2; shift 2 ;;
      -*) die "tests: unknown option: $1" ;;
      *) [ -z "$script" ] || die "tests: one script only"; script=$1; shift ;;
    esac
  done
  [ -n "$script" ] || die "tests needs <script>"
  if [ -n "$from" ]; then
    [ -f "$from" ] || die "tests: list not found: $from"
    pool=$(sed 's/#.*//; s/[[:space:]]*$//' "$from" | grep -v '^$')
  else
    pool=$(tier_tests gate,full)
  fi
  globs=$(area_globs "$script" test)
  core=$(sed 's/#.*//; s/[[:space:]]*$//' "$CORE_LIST" 2>/dev/null | grep -v '^$')
  gated=$("$TEST_RUN" --list --family real-herdr-gated 2>/dev/null)
  name=$(basename "$script")
  pool=$(printf '%s\n' "$pool" | while IFS= read -r t; do
    [ -n "$t" ] && [ -f "$t" ] || continue
    printf '%s\n' "$gated" | grep -qxF "$t" && continue
    printf '%s\n' "$t"
  done)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    grep -qF "$name" "$t" || continue
    if matches_any "$t" "$globs" || printf '%s\n' "$core" | grep -qxF "$t"; then
      rel="$rel$t"$'\n'
    fi
  done <<EOF_POOL
$pool
EOF_POOL
  if [ -z "$rel" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] && matches_any "$t" "$globs" && rel="$rel$t"$'\n'
    done <<EOF_POOL
$pool
EOF_POOL
  fi
  if [ -z "$from" ]; then
    rel=$(printf '%s' "$rel" | grep -xF -f <(tier_tests "$tier") || true)
    [ -z "$rel" ] || rel="$rel"$'\n'
  fi
  printf '%s' "$rel" | sort -u
}

# run_tests <timeout> <test>...: prints `<test>\t<exit>\t<ms>` per test.
# FM_MUTATE_LOG names a file that keeps the runner's whole output, so a test
# failing its unmutated sanity run can be diagnosed.
run_tests() {
  local timeout=$1
  shift
  "$TEST_RUN" --per-script-timeout-secs "$timeout" "$@" 2>&1 | tee -a "${FM_MUTATE_LOG:-/dev/null}" |
    awk '$1 == "FM_TEST_END" {
      e = ""; d = ""
      for (i = 4; i <= NF; i++) { if ($i ~ /^exit=/) e = substr($i, 6); if ($i ~ /^duration_ms=/) d = substr($i, 13) }
      printf "%s\t%s\t%s\n", $3, e, d }'
}

verdict() { # <exit>
  case "$1" in
    0) printf survived ;;
    124) printf timeout ;;
    '') printf error ;;
    *) printf killed ;;
  esac
}

cmd_run() {
  local file='' row='' stop=0 timeout=600 tests=() backup t e ms rc status=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stop-on-kill) stop=1; shift ;;
      --timeout-secs) [ "$#" -gt 1 ] || die "--timeout-secs needs a number"; timeout=$2; shift 2 ;;
      -?*) die "run: unknown option: $1" ;;
      *)
        if [ -z "$file" ]; then file=$1
        elif [ -z "$row" ]; then row=$1
        else tests+=("$1")
        fi
        shift ;;
    esac
  done
  [ -f "$file" ] && [ -n "$row" ] && [ "${#tests[@]}" -gt 0 ] || die "run needs <file> <mutant row> <test>..."
  backup=$(mktemp) || exit 1
  cp -p "$file" "$backup"
  # shellcheck disable=SC2064 # restore this file whatever happens
  trap "cat '$backup' >'$file'; rm -f '$backup'" EXIT INT TERM
  if [ "$row" = - ]; then
    M_ID="$file:unmutated"
    rc=0
  else
    mutant_fields "$row"
    apply_mutant "$file" "$row"
    rc=$?
  fi
  case "$rc" in
    0) ;;
    3) printf '%s\tabsent\t-\t0\n' "$M_ID"; return 0 ;;
    *) printf '%s\tinvalid\t-\t0\n' "$M_ID"; return 0 ;;
  esac
  if [ "$stop" -eq 1 ]; then
    for t in "${tests[@]}"; do
      IFS="$(printf '\t')" read -r _ e ms <<EOF_RES
$(run_tests "$timeout" "$t")
EOF_RES
      [ -n "${e:-}" ] || status=1
      printf '%s\t%s\t%s\t%s\n' "$M_ID" "$t" "$(verdict "${e:-}")" "${ms:-0}"
      [ "${e:-0}" = 0 ] || break
    done
  else
    local got
    got=$(run_tests "$timeout" "${tests[@]}")
    for t in "${tests[@]}"; do
      e=$(printf '%s\n' "$got" | awk -F '\t' -v t="$t" '$1 == t { print $2 }' | tail -n 1)
      ms=$(printf '%s\n' "$got" | awk -F '\t' -v t="$t" '$1 == t { print $3 }' | tail -n 1)
      [ -n "$e" ] || status=1
      printf '%s\t%s\t%s\t%s\n' "$M_ID" "$t" "$(verdict "$e")" "${ms:-0}"
    done
  fi
  return "$status"
}

# changed_lines <base> <file>: the new-side line numbers the diff adds.
changed_lines() {
  git diff -U0 "$1" -- "$2" | awk '
    /^@@/ { split($3, a, ","); s = substr(a[1], 2) + 0; n = (a[2] == "" ? 1 : a[2] + 0)
            if (n > 0) printf "%s%d-%d", (c++ ? "," : ""), s, s + n - 1 }'
}

cmd_changed() {
  local base='' max=20 budget=900 timeout=600 out='' scripts s lines rows row tests
  local start now t verdicts survivors=0 killed=0 skipped=0 total=0 report only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) [ "$#" -gt 1 ] || die "--base needs a ref"; base=$2; shift 2 ;;
      --max) [ "$#" -gt 1 ] || die "--max needs a number"; max=$2; shift 2 ;;
      --budget-secs) [ "$#" -gt 1 ] || die "--budget-secs needs a number"; budget=$2; shift 2 ;;
      --timeout-secs) [ "$#" -gt 1 ] || die "--timeout-secs needs a number"; timeout=$2; shift 2 ;;
      --out) [ "$#" -gt 1 ] || die "--out needs a path"; out=$2; shift 2 ;;
      --scripts-only) only=1; shift ;;
      *) die "changed: unknown argument: $1" ;;
    esac
  done
  [ -n "$base" ] || die "changed needs --base <ref>"
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "changed: unknown base: $base"
  scripts=$(git diff --name-only --diff-filter=AM "$base" -- 'bin/*.sh' | sort -u |
    while IFS= read -r s; do [ -n "$(area_globs "$s" script)" ] && printf '%s\n' "$s"; done)
  if [ "$only" -eq 1 ]; then
    [ -z "$scripts" ] || printf '%s\n' "$scripts"
    return 0
  fi
  report=$(mktemp) || exit 1
  rows=$(mktemp) || exit 1
  for s in $scripts; do
    lines=$(changed_lines "$base" "$s")
    [ -n "$lines" ] && cmd_list "$s" --max "$max" --lines "$lines" --seed changed
  done | head -n "$max" >"$rows"
  start=$(date +%s)
  {
    printf '## Mutation check on changed risky lines\n\n'
    printf 'Non-blocking: a survivor is a changed guard no gate-tier test noticed breaking.\n\n'
    if [ ! -s "$rows" ]; then
      printf 'No mutable changed lines in risky-area scripts since %s.\n' "$base"
    else
      printf '| Mutant | Original line | Result | Killed by |\n|---|---|---|---|\n'
    fi
  } >"$report"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mutant_fields "$row"
    total=$((total + 1))
    s=${M_ID%%:*}
    t=$(unb64 "$M_ORIG" | sed 's/^[[:space:]]*//; s/|/\\|/g' | cut -c1-80)
    now=$(date +%s)
    if [ $((now - start)) -ge "$budget" ]; then
      skipped=$((skipped + 1))
      # shellcheck disable=SC2016 # Markdown code spans
      printf '| `%s` | `%s` | not run (budget) | |\n' "$M_ID" "$t" >>"$report"
      continue
    fi
    tests=$(cmd_tests "$s" --tier gate)
    if [ -z "$tests" ]; then
      survivors=$((survivors + 1))
      # shellcheck disable=SC2016 # Markdown code spans
      printf '| `%s` | `%s` | survived (no gate test) | |\n' "$M_ID" "$t" >>"$report"
      continue
    fi
    # shellcheck disable=SC2086 # one test path per word
    verdicts=$(cmd_run "$s" "$row" --stop-on-kill --timeout-secs "$timeout" $tests)
    [ -z "$out" ] || printf '%s\n' "$verdicts" >>"$out"
    if printf '%s\n' "$verdicts" | awk -F '\t' '$3 == "killed" || $3 == "timeout" { k = 1 } END { exit !k }'; then
      killed=$((killed + 1))
      # shellcheck disable=SC2016 # Markdown code spans
      printf '| `%s` | `%s` | killed | %s |\n' "$M_ID" "$t" \
        "$(printf '%s\n' "$verdicts" | awk -F '\t' '$3 == "killed" || $3 == "timeout" { print $2; exit }')" >>"$report"
    else
      survivors=$((survivors + 1))
      # shellcheck disable=SC2016 # Markdown code spans
      printf '| `%s` | `%s` | **survived** | |\n' "$M_ID" "$t" >>"$report"
    fi
  done <"$rows"
  printf '\nMutants: %d, killed: %d, survived: %d, not run: %d.\n' "$total" "$killed" "$survivors" "$skipped" >>"$report"
  cat "$report"
  rm -f "$report" "$rows"
}

cmd_report() {
  local dir=${1:-}
  [ -n "$dir" ] && [ -d "$dir" ] || die "report needs <dir>"
  shopt -s nullglob
  local cur=("$dir"/*.current.tsv) base=("$dir"/*.baseline.tsv) rerun=("$dir"/*.rerun.tsv)
  [ "${#cur[@]}" -gt 0 ] || die "report: no *.current.tsv in $dir"
  # Each input row is tagged with its side: C current, B baseline, R rerun.
  { awk -F '\t' '{ print "C\t" $0 }' "${cur[@]}"
    [ "${#base[@]}" -eq 0 ] || awk -F '\t' '{ print "B\t" $0 }' "${base[@]}"
    [ "${#rerun[@]}" -eq 0 ] || awk -F '\t' '{ print "R\t" $0 }' "${rerun[@]}"
  } | awk -F '\t' -v gates="$(tier_tests gate | tr '\n' ' ')" '
    function short(t) { sub(/^tests\//, "", t); sub(/\.test\.sh$/, "", t); return t }
    function scr(id) { sub(/:.*/, "", id); return id }
    function kill(v) { return v == "killed" || v == "timeout" }
    BEGIN { n = split(gates, g, " "); for (i = 1; i <= n; i++) gate[g[i]] = 1 }
    {
      side = $1; id = $2; t = $3; v = $4
      if (id ~ /:unmutated$/) { if (v != "survived") broken[side, scr(id), t] = 1; next }
      if (side == "R") {
        k = id; s2 = (k ~ /@baseline$/) ? "B" : "C"; sub(/@(current|baseline)$/, "", k)
        rr[s2, k] = 1; if (kill(v) && !broken[s2, scr(k), t] && (s2 == "B" || gate[t])) rk[s2, k] = 1
        next
      }
      if (side == "C" && !(id in seen)) { seen[id] = 1; order[++m] = id; sc = scr(id); if (!(sc in nm)) sorder[++ns] = sc; nm[sc]++ }
      if (t == "absent" || t == "invalid") { state[side, id] = t; next }
      ran[side, id] = 1
      if (side == "C") { tested[scr(id), t] = 1; if (!(scr(id) SUBSEP t in tseen)) { tseen[scr(id), t] = 1; tl[scr(id)] = tl[scr(id)] " " t } }
      if (kill(v) && !broken[side, scr(id), t]) {
        if (side == "C") { kc[id] = kc[id] (kc[id] == "" ? "" : ", ") short(t) (gate[t] ? "*" : ""); ck[id] = 1; if (gate[t]) gk[id] = 1; tk[scr(id), t]++ }
        else bk[id] = 1
      }
    }
    END {
      print "## Kill matrix\n"
      print "One row per mutant; `*` marks a gate-tier killer. Baseline: the old safety core at the pre-remake commit.\n"
      print "| Mutant | Killed by (current gate and full) | Gate | Old core | Parity |"
      print "|---|---|---|---|---|"
      for (i = 1; i <= m; i++) {
        id = order[i]; sc = scr(id)
        cs = state["C", id] != "" ? state["C", id] : (ck[id] ? "killed" : "survived")
        b = state["B", id] != "" ? "not comparable (" state["B", id] ")" : (!ran["B", id] ? "not run" : (bk[id] ? "killed" : "survived"))
        p = "-"
        if (bk[id] && ran["B", id]) {
          if (gk[id]) p = "kept"
          else if (rr["C", id] && rk["C", id]) { p = "kept (rerun)"; gk[id] = 1 }
          else if (rr["B", id] && !rk["B", id]) p = "baseline flake"
          else { p = "**LOST**"; lost++ }
          bkills++
        } else if (state["B", id] != "") nc++
        tot++; if (ck[id]) cks++; if (gk[id]) gks++
        if (cs == "survived") surv[sc] = surv[sc] " `" id "`"
        printf "| `%s` | %s | %s | %s | %s |\n", id, (kc[id] == "" ? cs : kc[id]), (gk[id] ? "killed" : cs == "killed" ? "survived" : cs), b, p
        sk[sc] += ck[id]; sg[sc] += gk[id]; sb[sc] += bk[id]
      }
      print "\n## Per script\n"
      print "| Script | Mutants | Killed (gate+full) | Killed (gate) | Killed (old core) | Tests that never killed |"
      print "|---|---|---|---|---|---|"
      for (i = 1; i <= ns; i++) {
        sc = sorder[i]; idle = ""
        k = split(tl[sc], arr, " ")
        for (j = 1; j <= k; j++) if (!tk[sc, arr[j]]) idle = idle (idle == "" ? "" : ", ") short(arr[j])
        printf "| `%s` | %d | %d | %d | %d | %s |\n", sc, nm[sc], sk[sc], sg[sc], sb[sc], idle
      }
      printf "\n## Totals\n\nMutants: %d. Killed by gate and full: %d. Killed by gate: %d. Killed by the old core: %d. Not comparable at baseline: %d.\n", tot, cks, gks, bkills, nc
      printf "\nParity: %s (%d of %d old-core kills lost by the current gate).\n", (lost ? "FAILED" : "held"), lost, bkills
    }'
}

cd "$ROOT" || die "cannot enter $ROOT"
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
sub=$1
shift
case "$sub" in
  -h|--help|help) usage ;;
  list) cmd_list "$@" ;;
  apply) cmd_apply "$@" ;;
  tests) cmd_tests "$@" ;;
  run) cmd_run "$@" ;;
  changed) cmd_changed "$@" ;;
  report) cmd_report "$@" ;;
  *) die "unknown command: $sub" ;;
esac
