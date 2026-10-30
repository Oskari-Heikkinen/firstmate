#!/usr/bin/env bash
# Temporary mutant run for uh-j4-land-gate, pushed only to ci/try branches and
# never landed. Each line of tests/j4-mutants.tsv is
#   <tests, comma-separated> TAB <file> TAB <fm-mutate.sh list row>
# and every mutant must be killed (or time out) by one of its tests.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
total=0
survived=0
while IFS="$(printf '\t')" read -r tests file row <&3; do
  [ -n "$tests" ] || continue
  total=$((total + 1))
  # shellcheck disable=SC2046 # one test path per word
  out=$(bin/fm-mutate.sh run "$file" "$row" --stop-on-kill --timeout-secs 600 $(printf '%s' "$tests" | tr ',' ' ') </dev/null)
  printf '%s\n' "$out"
  if ! printf '%s\n' "$out" | awk -F '\t' '$3 == "killed" || $3 == "timeout" { k = 1 } END { exit !k }'; then
    survived=$((survived + 1))
    printf 'J4-SURVIVOR\t%s\n' "$(printf '%s' "$row" | cut -f1)"
  fi
  git diff --quiet -- "$file" || { echo "J4-ERROR: $file was not restored"; exit 1; }
done 3<tests/j4-mutants.tsv
printf 'J4-MUTANTS total=%s survived=%s\n' "$total" "$survived"
[ "$total" -gt 0 ] && [ "$survived" -eq 0 ]
