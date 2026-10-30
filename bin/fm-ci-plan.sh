#!/usr/bin/env bash
# fm-ci-plan.sh - the plan job of .github/workflows/ci.yml: which layout a
# trigger runs, and the tiers, shards, lint scopes and test selections that
# layout takes. docs/fm-test-portable-shards.md owns the layout table and its
# reasons; bin/fm-test-run.sh owns every test selection this script asks for.
#
# Usage:
#   fm-ci-plan.sh --event <name> --ref <ref> [--sha <sha>] [--repo <owner/name>]
#                 [--run-id <id>] [--base <ref>] [--output <file>]
#                 [--summary <file>] [--record <file>]
#
#   --event    the GitHub event name (push, schedule, workflow_dispatch, ...)
#   --ref      the pushed ref, e.g. refs/heads/ci/<task>
#   --sha      the pushed commit (default HEAD); a ci/try/** push reads its
#              trailers, and a main push looks for an earlier run of it
#   --repo, --run-id
#              this run's repository (owner/name) and numeric run id, for the
#              main push's lookup through gh (GH_TOKEN needs actions: read);
#              without them a main push runs its suites
#   --base     the ref changed files are diffed against (default origin/main)
#   --output   file the outputs are appended to as key=value lines (default
#              $GITHUB_OUTPUT, else stdout)
#   --summary  file every summary line is also appended to (default
#              $GITHUB_STEP_SUMMARY); summary lines always go to stdout
#   --record   file the plan record (below) is written to; needs --run-id and
#              a full --ref. The workflow uploads it as the fm-ci-plan artifact
#   -h, --help print this header
#
# Layouts:
#   skip    a main push whose exact commit already passed this workflow on
#           the full layout on a ci/** push (below); any doubt runs full
#   ci      other ci/** pushes: the gate shards plus the changed area; an
#           unmapped changed path, or more than 30 selected tier-2 tests,
#           escalates the push to full
#   full    main and ci/full/** pushes, and any other push event
#   weekly  schedule and workflow_dispatch
#   try     ci/try/** pushes: only the tests the head commit names (below),
#           never escalated, never green-pointer input
#
# Outputs: layout; tiers (the --tier list for the shards); shards (a JSON array
# of shard numbers, [] for none); lint (a JSON array of bin/fm-lint.sh scopes);
# changed (true when the ci layout's changed-area job has portable tests);
# herdr_paths (the real-Herdr selection, space-separated; --from-list entries
# on try); try_list (the try shards' --from-list entries, space-separated, and
# empty on every other layout).
#
# A ci/try/** selection comes from the head commit's trailers:
#   Fm-Try: <token>[,<token>...]
#     A token ending in .test.sh names a test in tests/tiers.list (the tests/
#     prefix may be left off). Any other token names a family listed by
#     bin/fm-test-run.sh --list-families and selects its members.
#   Fm-Try-Only: <script>:<case>
#     Runs only that case function of the script (FM_TEST_ONLY, which
#     tests/lib.sh owns; the runner fails a case that matches nothing).
# Both may repeat, and tokens may be separated by commas or spaces. A token
# that names nothing, an Fm-Try-Only without a case, a script named both whole
# and with a case, and an Fm-Try line outside the message's trailer block are
# refused with exit 1 and an ::error:: line naming the trailer. With no such
# trailer the selection is bin/fm-test-run.sh --changed --skip-unmapped --tier
# gate,full,weekly: the tier-2 and weekly tests mapped to the changed files,
# plus the gate members of the changed families. A changed path the map cannot
# place is listed in the summary and skipped, and no selection size widens the
# run. The portable entries run in up to three shards; the real-Herdr entries
# run in the Herdr job, which a try push otherwise skips.
#
# The plan record is one JSON object holding the layout this run chose:
#   {"schema":"fm-ci-plan/v1","layout":..,"sha":..,"ref":..,"event":..,
#    "run_id":..}
# A main push skips only when an earlier successful push run of this same
# workflow on the exact same commit, in this repository, on a ci/** branch
# other than ci/try/**, has an fm-ci-plan artifact whose record says layout
# full and names that run's own sha, run id, ref and push event. The reading
# fails closed: an API error, a missing, expired, malformed or mismatched
# record, or a run without one is no prior pass, and each candidate is judged
# on its own record, so one unreadable candidate never hides a valid one. Only
# the newest ten candidates are read, which bounds the plan job's API calls.
# Each rejected candidate and the verdict go to the summary.
#
# Exit status: 0 with every output written; 1 when a trailer is refused, a
# selection command fails or the plan record cannot be written; 2 on a usage
# error.
set -u
# Trailer values and test lists are split on whitespace; none is a glob.
set -f

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
RUNNER="$ROOT/bin/fm-test-run.sh"

EVENT=
REF=
HEAD_SHA=HEAD
REPO=
RUN_ID=
BASE=origin/main
OUTPUT=${GITHUB_OUTPUT:-}
SUMMARY=${GITHUB_STEP_SUMMARY:-}
RECORD=
SCHEMA=fm-ci-plan/v1
ARTIFACT=fm-ci-plan
MAX_CANDIDATES=10

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die_usage() {
  printf 'fm-ci-plan: %s\n' "$*" >&2
  exit 2
}

# A refusal the push author must see: an annotation on the run and a summary line.
refuse() {
  printf '::error::%s\n' "$*"
  summary "Refused: $*"
  exit 1
}

out() {
  if [ -n "$OUTPUT" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$OUTPUT"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}

summary() {
  printf '%s\n' "$1"
  [ -z "$SUMMARY" ] || printf '%s\n' "$1" >>"$SUMMARY"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event|--ref|--sha|--repo|--run-id|--base|--output|--summary|--record)
      [ "$#" -gt 1 ] || die_usage "$1 requires a value"
      case "$1" in
        --event) EVENT=$2 ;;
        --ref) REF=$2 ;;
        --sha) HEAD_SHA=$2 ;;
        --repo) REPO=$2 ;;
        --run-id) RUN_ID=$2 ;;
        --base) BASE=$2 ;;
        --output) OUTPUT=$2 ;;
        --summary) SUMMARY=$2 ;;
        --record) RECORD=$2 ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1 (see --help)"
      ;;
  esac
done
[ -n "$EVENT" ] || die_usage "--event is required"
[ -n "$REF" ] || [ "$EVENT" != push ] || die_usage "--ref is required for a push"
# Both go into API paths, and the run id into the plan record.
case "$REPO" in
  '') ;;
  */*/*|/*|*/|*[!A-Za-z0-9._/-]*) die_usage "--repo '$REPO' is not an owner/name" ;;
  */*) ;;
  *) die_usage "--repo '$REPO' is not an owner/name" ;;
esac
case "$RUN_ID" in
  *[!0-9]*) die_usage "--run-id '$RUN_ID' is not a run id" ;;
esac
if [ -n "$RECORD" ]; then
  [ -n "$RUN_ID" ] || die_usage "--record needs --run-id"
  case "$REF" in
    refs/*) ;;
    *) die_usage "--record needs a full --ref, not '$REF'" ;;
  esac
fi

HEAD_SHA=$(git rev-parse --verify --quiet "$HEAD_SHA^{commit}") || {
  printf 'fm-ci-plan: --sha names no commit in this checkout\n' >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-plan.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# The first line of a captured stderr file, or a placeholder.
first_line() {
  local line=
  { IFS= read -r line <"$1"; } 2>/dev/null
  printf '%s' "${line:-no error text}"
}

# Print "<verdict> <detail>" for one candidate's downloaded record: "full" when
# it proves a full-layout run of HEAD_SHA by run <id> on <branch>, otherwise
# why not.
judge_record() {
  local file=$1 id=$2 branch=$3
  if [ ! -f "$file" ]; then
    printf 'unreadable the artifact holds no plan.json\n'
    return
  fi
  jq -rs --arg schema "$SCHEMA" --arg sha "$HEAD_SHA" --argjson id "$id" \
    --arg ref "refs/heads/$branch" '
    if length != 1 or (.[0] | type) != "object" then "unreadable the record is not one JSON object"
    else .[0]
    | if .schema != $schema then "unreadable the record schema is \(.schema | tojson), not \($schema)"
      elif .sha != $sha then "mismatch the record names commit \(.sha | tojson)"
      elif .run_id != $id then "mismatch the record names run \(.run_id | tojson)"
      elif .ref != $ref or .event != "push" then "mismatch the record names \(.event | tojson) on \(.ref | tojson)"
      elif .layout != "full" then "layout it used the \(.layout | tojson) layout"
      else "full ok" end
    end' "$file" 2>/dev/null || printf 'unreadable the record is not valid JSON\n'
}

# A main push may skip when an earlier run proved this commit on the full
# layout (the header owns the rule). Returns 0 for a proven pass, 1 otherwise,
# with the reason in the summary.
prior_full_pass() {
  local run workflow_id runs candidates id url branch verdict detail count=0
  local shown="\`$HEAD_SHA\`" scratch=$WORK/prior
  if [ -z "$REPO" ] || [ -z "$RUN_ID" ]; then
    summary "Suites run: no --repo and --run-id to look up an earlier run of $shown."
    return 1
  fi
  if ! mkdir -p "$scratch"; then
    summary "Suites run: could not make a scratch directory for the API answers."
    return 1
  fi
  if ! run=$(gh api "repos/$REPO/actions/runs/$RUN_ID" 2>"$scratch/err"); then
    summary "Suites run: could not read this run's workflow ($(first_line "$scratch/err"))."
    return 1
  fi
  if ! workflow_id=$(printf '%s' "$run" | jq -er '.workflow_id | numbers' 2>/dev/null); then
    summary "Suites run: this run's API answer names no workflow id."
    return 1
  fi
  if ! runs=$(gh api "repos/$REPO/actions/workflows/$workflow_id/runs?head_sha=$HEAD_SHA&event=push&status=success&per_page=100" 2>"$scratch/err"); then
    summary "Suites run: could not list earlier successful runs of $shown ($(first_line "$scratch/err"))."
    return 1
  fi
  # Newest first. head_branch is the pushed branch without refs/heads/.
  if ! candidates=$(printf '%s' "$runs" | jq -r --arg sha "$HEAD_SHA" --arg repo "$REPO" \
    --argjson wid "$workflow_id" --argjson self "$RUN_ID" '
    if (.workflow_runs | type) != "array" then error("no workflow_runs list") else . end
    | [.workflow_runs[]
      | select(.head_sha == $sha and .event == "push" and .conclusion == "success"
        and .workflow_id == $wid and .id != $self
        and .head_repository.full_name == $repo
        and (.head_branch // "" | startswith("ci/"))
        and (.head_branch // "" | startswith("ci/try/") | not))]
    | sort_by(.run_started_at) | reverse | .[]
    | "\(.id) \(.html_url) \(.head_branch)"' 2>/dev/null); then
    summary "Suites run: the list of earlier successful runs of $shown was unreadable."
    return 1
  fi
  if [ -z "$candidates" ]; then
    summary "Suites run: no earlier successful ci/** run of $shown (ci/try/** never counts)."
    return 1
  fi

  while IFS=' ' read -r id url branch; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$MAX_CANDIDATES" ]; then
      summary "Not read: candidates past the newest $MAX_CANDIDATES."
      break
    fi
    case "$id" in
      *[!0-9]*) summary "Not counted: a candidate with run id $id."; continue ;;
    esac
    if ! gh run download "$id" -R "$REPO" -n "$ARTIFACT" -D "$scratch/$id" </dev/null >/dev/null 2>"$scratch/err"; then
      summary "Not counted: $url ($branch) has no readable $ARTIFACT artifact ($(first_line "$scratch/err"))."
      continue
    fi
    read -r verdict detail <<<"$(judge_record "$scratch/$id/plan.json" "$id" "$branch")"
    if [ "$verdict" = full ]; then
      summary "Suites skipped: $url ($branch) already passed this workflow on the full layout at $shown."
      return 0
    fi
    summary "Not counted: $url ($branch): $detail."
  done <<<"$candidates"
  summary "Suites run: no earlier successful full-layout ci/** run of $shown."
  return 1
}

# Write the plan record of the chosen layout to RECORD.
write_record() {
  local tmp=$RECORD.tmp.$$
  if ! jq -n --arg schema "$SCHEMA" --arg layout "$layout" --arg sha "$HEAD_SHA" \
    --arg ref "$REF" --arg event "$EVENT" --argjson run_id "$RUN_ID" \
    '{schema: $schema, layout: $layout, sha: $sha, ref: $ref, event: $event, run_id: $run_id}' \
    >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$RECORD" 2>/dev/null; then
    rm -f "$tmp"
    printf '::error::fm-ci-plan: could not write the plan record %s\n' "$RECORD"
    exit 1
  fi
  summary "Plan record: layout $layout at $RECORD"
}

# Count the non-empty lines of $1.
count_lines() {
  printf '%s\n' "$1" | grep -c . || true
}

# Write the try selection to $WORK/try.list, one --from-list entry per line,
# from the head commit's trailers or, without any, from the changed files.
try_select() {
  local msg written parsed tiers families token script case_name members line
  local list=$WORK/try.list err=$WORK/try.err
  : >"$list"
  msg=$(git log -1 --format=%B "$HEAD_SHA") || refuse "could not read the commit message of $HEAD_SHA"
  # Every line that looks like one of these trailers must be one, so a typo or
  # a trailer outside the last paragraph is refused instead of silently
  # turning into the changed-file selection.
  written=$(printf '%s\n' "$msg" | grep -i '^fm-try' || true)
  parsed=$(git log -1 --format='%(trailers:key=Fm-Try,key=Fm-Try-Only)' "$HEAD_SHA") \
    || refuse "could not read the trailers of $HEAD_SHA"
  if [ "$(count_lines "$written")" != "$(count_lines "$parsed")" ]; then
    refuse "an Fm-Try line in $HEAD_SHA is misspelled or outside the message's final trailer block: $(printf '%s' "$written" | tr '\n' ';')"
  fi
  if [ -z "$parsed" ]; then
    "$RUNNER" --list --changed --skip-unmapped --base "$BASE" --tier gate,full,weekly \
      >"$list" 2>"$err" || {
      cat "$err" >&2
      refuse "bin/fm-test-run.sh --changed could not select the changed area against $BASE"
    }
    TRY_SOURCE="changed files against $BASE"
    TRY_UNMAPPED=$(sed -n 's/^FM_TEST_UNMAPPED path=//p' "$err")
    return 0
  fi

  TRY_SOURCE="Fm-Try trailers"
  tiers=$("$RUNNER" --list-tiers) || refuse "could not read tests/tiers.list"
  families=$("$RUNNER" --list-families) || refuse "could not list the test families"
  while IFS= read -r line; do
    for token in $(printf '%s\n' "$line" | tr ',' ' '); do
      case "$token" in
        *.test.sh)
          script=tests/${token#tests/}
          printf '%s\n' "$tiers" | awk -v p="$script" '$2 == p { found = 1 } END { exit !found }' \
            || refuse "Fm-Try: $token names no test in tests/tiers.list"
          printf '%s\n' "$script" >>"$list"
          ;;
        *)
          grep -qxF -e "$token" <<<"$families" \
            || refuse "Fm-Try: $token is neither a tests/*.test.sh file nor a family from bin/fm-test-run.sh --list-families"
          members=$("$RUNNER" --list --family "$token" 2>"$err") || {
            cat "$err" >&2
            refuse "Fm-Try: family $token has no tests"
          }
          printf '%s\n' "$members" >>"$list"
          ;;
      esac
    done
  done < <(git log -1 --format='%(trailers:key=Fm-Try,valueonly)' "$HEAD_SHA")
  while IFS= read -r line; do
    for token in $(printf '%s\n' "$line" | tr ',' ' '); do
      script=${token%%:*}
      case_name=${token#*:}
      case "$token" in
        *.test.sh:?*) ;;
        *) refuse "Fm-Try-Only: $token is not <script>.test.sh:<case>" ;;
      esac
      script=tests/${script#tests/}
      printf '%s\n' "$tiers" | awk -v p="$script" '$2 == p { found = 1 } END { exit !found }' \
        || refuse "Fm-Try-Only: $token names no test in tests/tiers.list"
      printf '%s:%s\n' "$script" "$case_name" >>"$list"
    done
  done < <(git log -1 --format='%(trailers:key=Fm-Try-Only,valueonly)' "$HEAD_SHA")
  [ -s "$list" ] || refuse "the Fm-Try trailers of $HEAD_SHA have no value"
  # The runner owns the entry rules (duplicates, conflicting cases, case
  # names); its --list prints the entries back in canonical form.
  if ! "$RUNNER" --list --from-list "$list" >"$list.checked" 2>"$err"; then
    refuse "the Fm-Try trailers of $HEAD_SHA do not form a test list: $(sed -n 's/^fm-test-run: //p' "$err" | head -n 1)"
  fi
  mv "$list.checked" "$list"
}

layout=full
case "$EVENT" in
  schedule|workflow_dispatch) layout=weekly ;;
  push)
    case "$REF" in
      refs/heads/main) prior_full_pass && layout=skip ;;
      refs/heads/ci/full/*) layout=full ;;
      refs/heads/ci/try/*) layout=try ;;
      refs/heads/ci/*) layout=ci ;;
    esac
    ;;
esac

changed=false
herdr_paths=
try_list=
try_shards=0
if [ "$layout" = ci ]; then
  # Tier-2 and weekly tests mapped to the changed files. An unmapped path, or
  # a widely sourced change selecting more than 30 tests, escalates the push
  # to the main layout.
  herdr_family=$("$RUNNER" --list --family real-herdr-gated) || exit 1
  if ! selected=$("$RUNNER" --list --changed --base "$BASE" --tier full,weekly); then
    summary "Changed files include a path the test map cannot place: running the main layout."
    layout=full
  elif [ "$(printf '%s\n' "$selected" | grep -c .)" -gt 30 ]; then
    summary "Changed files select more than 30 tier-2 tests: running the main layout."
    layout=full
  else
    portable=$(printf '%s\n' "$selected" | grep -vxF -e "$herdr_family" | grep . || true)
    [ -z "$portable" ] || changed=true
    herdr_gate=$("$RUNNER" --list --family real-herdr-gated --tier gate) || exit 1
    herdr_paths=$( { printf '%s\n' "$herdr_gate"; printf '%s\n' "$selected" | grep -xF -e "$herdr_family" || true; } \
      | grep . | LC_ALL=C sort -u | tr '\n' ' ')
    summary "Changed-area tier-2 tests: $(printf '%s\n' "$selected" | grep -c .)"
  fi
elif [ "$layout" = try ]; then
  TRY_SOURCE=
  TRY_UNMAPPED=
  try_select
  herdr_family=$("$RUNNER" --list --family real-herdr-gated) || exit 1
  try_portable=
  try_herdr=
  n_portable=0
  n_herdr=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if grep -qxF -e "${entry%%:*}" <<<"$herdr_family"; then
      try_herdr="$try_herdr $entry"
      n_herdr=$((n_herdr + 1))
    else
      try_portable="$try_portable $entry"
      n_portable=$((n_portable + 1))
    fi
  done <"$WORK/try.list"
  try_list=${try_portable# }
  herdr_paths=${try_herdr# }
  try_shards=$n_portable
  [ "$try_shards" -le 3 ] || try_shards=3
  summary "Try selection from $TRY_SOURCE: $n_portable tests in $try_shards shards, $n_herdr in the Herdr job."
  while IFS= read -r entry; do
    [ -z "$entry" ] || summary "- \`$entry\`"
  done <"$WORK/try.list"
  [ -s "$WORK/try.list" ] || summary "No tests selected: only the static checks and changed-file lint run."
  while IFS= read -r path; do
    [ -z "$path" ] || summary "Unmapped changed path, skipped (a try run never widens): \`$path\`"
  done <<<"$TRY_UNMAPPED"
fi

case "$layout" in
  skip) tiers=; shards='[]' ;;
  ci) tiers=gate; shards='[1,2,3]' ;;
  full) tiers=gate,full; shards='[1,2,3,4,5,6,7]' ;;
  weekly) tiers=weekly,live; shards='[1,2,3,4,5]' ;;
  try)
    tiers=
    shards='[]'
    case "$try_shards" in
      1) shards='[1]' ;;
      2) shards='[1,2]' ;;
      3) shards='[1,2,3]' ;;
    esac
    ;;
esac
# Lint scopes: the changed files on every ci/** push, all of bin/ in three
# partitions on the main layout; the weekly test-lint job covers every test
# file.
lint='[]'
case "$layout:$REF" in
  ci:*|try:*) lint='["changed"]' ;;
  full:refs/heads/main) lint='["1of3","2of3","3of3"]' ;;
  full:*) lint='["changed","1of3","2of3","3of3"]' ;;
esac
summary "Layout: $layout (event $EVENT, ref $REF)"
out layout "$layout"
out tiers "$tiers"
out shards "$shards"
out lint "$lint"
out changed "$changed"
out herdr_paths "$herdr_paths"
out try_list "$try_list"
[ -z "$RECORD" ] || write_record
