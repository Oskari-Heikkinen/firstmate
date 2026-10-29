#!/usr/bin/env bash
# fm-ci-errors.sh - one error list for a finished GitHub Actions run: a row for
# every failed job and for every failing test in every shard, each with a cause
# class, its evidence and its job URL. It only reads the forge and writes the
# list; acting on the rows is the reader's job.
#
# Usage:
#   fm-ci-errors.sh [--repo OWNER/REPO] [--out DIR] [--flakes FILE] RUN-ID
#     --repo    the repository the run belongs to; default: the owner/repo of
#               this checkout's `origin` remote on github.com. Every gh call
#               names it.
#     --out     where the list goes; default: $FM_HOME/data/ci-errors/RUN-ID,
#               or data/ci-errors/RUN-ID in this checkout (gitignored) when
#               FM_HOME is unset.
#     --flakes  the known-flake list; default: tests/known-flakes.list.
#
# Reading (latest attempt only, as the jobs API serves it):
#   gh api repos/R/actions/runs/ID                  run status and URL
#   gh api --paginate repos/R/actions/runs/ID/jobs  every job and its steps
#   gh api repos/R/check-runs/JOB/annotations       per failed job
#   gh run view --job JOB --log -R R                per failed job not infra
# A job failed when its conclusion is anything but success, skipped or neutral.
#
# Cause classes, decided in this order for each failed job:
#   real     a job annotation says it exceeded its maximum execution time: the
#            job is read like any other, so a script it cut off gets a row;
#   infra    never got a runner (no runner name and no step started, or the
#            "not acquired by Runner" annotation), runner lost (an annotation
#            naming lost communication, a shutdown signal or a hosted runner
#            error), or cancelled before its first step (no step after
#            "Set up job" succeeded or failed); its log is not fetched;
#   unknown  the log could not be fetched, was empty, or shows neither a
#            failing test nor an ##[error] line, so the cause is not known;
#   flaky    a failing test listed in the known-flake list;
#   real     every other failing test, and a job that failed outside tests.
# Tests come from bin/fm-test-run.sh's markers: an FM_TEST_END with exit not 0
# is a failing test, an FM_TEST_BEGIN with no FM_TEST_END is a script the job
# cut off (class real), and an FM_TEST_END whose exit is not a number is class
# unknown. A job with test rows takes the worst of them (real, then unknown,
# then flaky). The list cannot tell a test defect from a real bug: that
# judgment stays with whoever reads a real row.
#
# Evidence: for a test, its first three failing-assertion lines (`not ok`, or
# unittest's `FAIL:`, `ERROR:`, `...Error:` and `...Exception:`), else the last
# three lines of its output (its output is the lines since the previous
# FM_TEST_ marker, which holds for serial and --jobs runs alike); for a job,
# its failure annotations, then the failing tests, or else the failing step's
# own output (its first four and last eight lines when longer) up to its first
# ##[error].
#
# Output in DIR, each file replaced whole:
#   errors.md    the list: run header, class counts, the next step, one table
#   errors.json  the same rows for tools, schema fm-ci-errors/v1:
#                {schema, run:{id,attempt,url,workflow,branch,head_sha,
#                conclusion,read_at,jobs,failed_jobs}, counts:{rows,real,flaky,
#                infra,unknown}, rows:[{kind:job|test, job_id, job, test,
#                class, reason, evidence:[...], url}]}; reason is one of
#                no-runner, runner-lost, cancelled-before-first-step,
#                step-failed, tests-failed, log-unreadable, log-empty,
#                failure-not-in-log, test-failed, test-cut-off, known-flake,
#                unparsable-marker
#   logs/JOB.log the raw log of each failed job that was fetched
#   fm-ci-errors.log  append-only, one UTC line per event
# Prints one line on success:
#   fm-ci-errors/v1 run=ID attempt=N rows=N real=N flaky=N infra=N unknown=N list=DIR/errors.md
#
# Exit codes:
#   0   the list was written, whatever its rows say;
#   1   refused, nothing replaced: the run or its jobs could not be read or
#       were incomplete, the flake list is unreadable or malformed, or a write
#       failed;
#   2   usage;
#   75  the run has not completed yet; rerun once it has.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-ci-errors: %s\n' "$1" >&2
  printf 'usage: fm-ci-errors.sh [--repo OWNER/REPO] [--out DIR] [--flakes FILE] RUN-ID\n' >&2
  exit 2
}

REPO='' OUT='' FLAKES=$ROOT/tests/known-flakes.list RUN=''
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --repo|-R) [ $# -ge 2 ] || die_usage "$1 needs a value"; REPO=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die_usage "$1 needs a value"; OUT=$2; shift 2 ;;
    --flakes) [ $# -ge 2 ] || die_usage "$1 needs a value"; FLAKES=$2; shift 2 ;;
    -*) die_usage "unknown option $1" ;;
    *) [ -z "$RUN" ] || die_usage "one run id only"; RUN=$1; shift ;;
  esac
done
case $RUN in ''|*[!0-9]*) die_usage "RUN-ID must be a number" ;; esac

LOG=''
log() {  # <what happened, why, what next>
  [ -n "$LOG" ] || return 0
  printf '%s run=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN" "$1" >>"$LOG"
}

refuse() {  # <code> <reason>
  printf 'fm-ci-errors: run %s: %s\n' "$RUN" "$2" >&2
  log "refused: $2; nothing replaced"
  exit "$1"
}

if [ -z "$REPO" ]; then
  url=$(git -C "$ROOT" remote get-url origin 2>/dev/null) || url=
  case $url in
    *github.com[:/]*) REPO=${url#*github.com[:/]}; REPO=${REPO%.git}; REPO=${REPO%/} ;;
  esac
  [ -n "$REPO" ] || die_usage "no github.com origin remote in $ROOT; name the repository with --repo"
fi
case $REPO in */*/*|/*|*/|*[!A-Za-z0-9._/-]*) die_usage "--repo must be OWNER/REPO, got '$REPO'" ;; */*) ;; *) die_usage "--repo must be OWNER/REPO, got '$REPO'" ;; esac

[ -n "$OUT" ] || OUT=${FM_HOME:-$ROOT}/data/ci-errors/$RUN
mkdir -p "$OUT/logs" || refuse 1 "cannot create $OUT"
LOG=$OUT/fm-ci-errors.log
WORK=$(mktemp -d "$OUT/.work.XXXXXX") || refuse 1 "cannot create a work directory in $OUT"
trap 'rm -rf "$WORK"' EXIT
log "start: reading run in $REPO into $OUT"

# The known-flake list: `<tests/...test.sh> <reason>` per line, `#` comments.
[ -f "$FLAKES" ] && [ -r "$FLAKES" ] || refuse 1 "flake list $FLAKES is missing or unreadable"
FLAKE_NAMES=$'\n'
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line=${line%%#*}
  case $line in *[![:space:]]*) ;; *) continue ;; esac
  read -r name reason <<<"$line"
  case $name in
    tests/*.test.sh) [ -n "${reason:-}" ] || refuse 1 "flake list $FLAKES line $n names no reason" ;;
    *) refuse 1 "flake list $FLAKES line $n is not '<tests/...test.sh> <reason>'" ;;
  esac
  FLAKE_NAMES=$FLAKE_NAMES$name$'\n'
done <"$FLAKES"

is_flake() { case $FLAKE_NAMES in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

# --- the run and its jobs ---------------------------------------------------

gh api "repos/$REPO/actions/runs/$RUN" >"$WORK/run.json" 2>"$WORK/err" \
  || refuse 1 "cannot read the run from $REPO: $(head -n 1 "$WORK/err")"
jq -e 'type == "object" and (.id | type) == "number" and (.status | type) == "string"' \
  "$WORK/run.json" >/dev/null 2>&1 || refuse 1 "the run reply from $REPO is not a run object"
status=$(jq -r .status "$WORK/run.json")
[ "$status" = completed ] || {
  printf 'fm-ci-errors: run %s is %s; rerun once it has completed\n' "$RUN" "$status" >&2
  log "wait: run is $status, so its failures are not final; rerun once it completes"
  exit 75
}

gh api --paginate "repos/$REPO/actions/runs/$RUN/jobs?per_page=100" >"$WORK/pages.json" 2>"$WORK/err" \
  || refuse 1 "cannot read the run's jobs from $REPO: $(head -n 1 "$WORK/err")"
jq -s -e '
  if length > 0 and all(.[]; type == "object" and (.jobs | type) == "array"
      and (.total_count | type) == "number")
  then {total: .[0].total_count, jobs: [.[].jobs[]]}
       | if (.jobs | length) == .total then .jobs else error("partial") end
  else error("shape") end' "$WORK/pages.json" >"$WORK/jobs.json" 2>/dev/null \
  || refuse 1 "the jobs reply from $REPO is malformed or holds fewer jobs than its total_count"

jq -r '.[] | select((.conclusion // "") as $c | ["success", "skipped", "neutral"] | index($c) | not)
  | .id' "$WORK/jobs.json" >"$WORK/failed"
total_jobs=$(jq length "$WORK/jobs.json")
failed_jobs=$(wc -l <"$WORK/failed" | tr -d ' ')
log "read: $total_jobs jobs, $failed_jobs failed; classifying each failed job"

# --- per failed job ---------------------------------------------------------

: >"$WORK/rows.ndjson"
ROW_OUT=$WORK/rows.ndjson
row() {  # <kind> <job-id> <job> <test> <class> <reason> <url> <evidence-file>
  jq -nc --arg kind "$1" --argjson job_id "$2" --arg job "$3" --arg test "$4" \
    --arg class "$5" --arg reason "$6" --arg url "$7" --rawfile ev "$8" \
    '{kind: $kind, job_id: $job_id, job: $job, test: $test, class: $class,
      reason: $reason, evidence: ($ev | split("\n") | map(select(length > 0))), url: $url}' \
    >>"$ROW_OUT"
}

# The log reader: strips the `<job>\t<step>\t` prefix, a BOM, the timestamp,
# colour codes and CRs, then prints tab-separated records, evidence lines
# joined by \037:
#   T <script> <test-failed|test-cut-off|unparsable-marker> <evidence>
#   E <the failing step's output (its first four and last eight lines when
#     it has more than twelve) and the first ##[error] line>
#   N <the log's last five non-empty lines>  (only when no E record)
read_log() {  # <log-file>
  LC_ALL=C sed -e $'s/\xef\xbb\xbf//' -e $'s/\r$//' -e $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$1" \
  | LC_ALL=C awk '
    function clip(s) { gsub(/\t/, " ", s); return length(s) > 240 ? substr(s, 1, 237) "..." : s }
    function evidence(   i, out, k) {
      out = ""; k = 0
      for (i = 1; i <= seglen && k < 3; i++)
        if (seg[i] ~ /^ *(not ok|FAIL:|ERROR:|[A-Z][A-Za-z]*(Error|Exception):)/) out = out (k++ ? "\037" : "") seg[i]
      if (k) return out
      for (i = seglen; i >= 1 && k < 3; i--) if (seg[i] ~ /[^ ]/) { out = seg[i] (k++ ? "\037" out : "") }
      return k ? out : "(the script printed nothing)"
    }
    {
      line = $0
      if (match(line, /^[^\t]*\t[^\t]*\t/)) {
        rest = substr(line, RLENGTH + 1)
        if (rest ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) line = rest
      }
      sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]*Z ?/, "", line)
      line = clip(line)
      if (line ~ /^FM_TEST_BEGIN /) {
        split(line, f, " ")
        if (!(f[3] in begun)) order[++nscripts] = f[3]
        begun[f[3]]++; seglen = 0; next
      }
      if (line ~ /^FM_TEST_END /) {
        split(line, f, " ")
        ended[f[3]]++
        if (f[4] !~ /^exit=[0-9]+$/) printf "T\t%s\tunparsable-marker\t%s\n", f[3], line
        else if (f[4] != "exit=0") printf "T\t%s\ttest-failed\t%s\037%s\n", f[3], f[4], evidence()
        seglen = 0; next
      }
      if (line ~ /^FM_TEST_[A-Z_]+ /) { seglen = 0; next }
      seg[++seglen] = line
      # A step starts at its "##[group]Run" header, whose script and env
      # block end at the next ##[endgroup]; what follows is its own output.
      if (line ~ /^##\[group\]Run /) { nstep = 0; ntail = 0; in_header = 1; next }
      if (in_header && line ~ /^##\[endgroup\]/) { in_header = 0; next }
      if (line ~ /^##\[error\]/) {
        if (!have_error) {
          have_error = 1; out = ""
          if (nstep <= 12) { for (i = 1; i <= nstep; i++) out = out head[i] "\037" }
          else {
            for (i = 1; i <= 4; i++) out = out head[i] "\037"
            out = out "..." "\037"
            for (i = 0; i < 8; i++) out = out tail[(ntail + i) % 8] "\037"
          }
          printf "E\t%s%s\n", out, line
        }
      } else if (!in_header && line ~ /[^ ]/ && line !~ /^##\[(end)?group\]/) {
        if (++nstep <= 12) head[nstep] = line
        tail[ntail++ % 8] = line
        if (nlast == 5) { for (i = 1; i < 5; i++) last[i] = last[i + 1] } else nlast++
        last[nlast] = line
      }
    }
    END {
      for (i = 1; i <= nscripts; i++) {
        s = order[i]
        if (begun[s] > ended[s] + 0)
          printf "T\t%s\ttest-cut-off\tno FM_TEST_END: the job ended while this script ran\n", s
      }
      if (!have_error) {
        out = ""
        for (i = 1; i <= nlast; i++) out = out (i > 1 ? "\037" : "") last[i]
        printf "N\t%s\n", out
      }
    }'
}

rank() { case $1 in real) echo 3 ;; unknown) echo 2 ;; flaky) echo 1 ;; *) echo 0 ;; esac; }

while IFS= read -r job_id; do
  jq --argjson id "$job_id" '.[] | select(.id == $id)' "$WORK/jobs.json" >"$WORK/job.json"
  name=$(jq -r .name "$WORK/job.json")
  url=$(jq -r '.html_url // ""' "$WORK/job.json")
  if gh api "repos/$REPO/check-runs/$job_id/annotations" >"$WORK/ann.json" 2>"$WORK/err" \
    && jq -e 'type == "array"' "$WORK/ann.json" >/dev/null 2>&1; then
    jq -r '.[] | select(.annotation_level == "failure") | .message // empty
      | select(test("^Process completed with exit code") | not) | gsub("[\r\n]+"; " ")' \
      "$WORK/ann.json" >"$WORK/ann.txt"
  else
    printf '(annotations unreadable: %s)\n' "$(head -n 1 "$WORK/err")" >"$WORK/ann.txt"
  fi
  cp "$WORK/ann.txt" "$WORK/ev"

  # Infra is decided from the job record and its annotations alone.
  reason=$(jq -r --rawfile ann "$WORK/ann.txt" '
    def started: [.steps[]? | select(.number > 1
      and ((.conclusion == "success" or .conclusion == "failure") or .status == "in_progress"))] | length > 0;
    def any_step: [.steps[]? | select(.started_at != null or .conclusion == "success"
      or .conclusion == "failure" or .status == "in_progress")] | length > 0;
    if ($ann | test("exceeded the maximum execution time")) then "read-log"
    elif ($ann | test("not acquired by Runner")) or (((.runner_name // "") == "") and (any_step | not)) then "no-runner"
    elif ($ann | test("lost communication with the server|received a shutdown signal|hosted runner encountered an error")) then "runner-lost"
    elif .conclusion == "cancelled" and (started | not) then "cancelled-before-first-step"
    else "read-log" end' "$WORK/job.json")
  if [ "$reason" != read-log ]; then
    [ -s "$WORK/ev" ] || printf 'conclusion %s, runner "%s", no step started\n' \
      "$(jq -r '.conclusion // "none"' "$WORK/job.json")" "$(jq -r '.runner_name // ""' "$WORK/job.json")" >"$WORK/ev"
    row job "$job_id" "$name" "" infra "$reason" "$url" "$WORK/ev"
    log "job $job_id ($name): infra, $reason; log not fetched"
    continue
  fi

  joblog=$OUT/logs/$job_id.log
  if ! gh run view --job "$job_id" --log -R "$REPO" >"$WORK/log" 2>"$WORK/err"; then
    printf 'log unreadable: %s\n' "$(head -n 1 "$WORK/err")" >>"$WORK/ev"
    row job "$job_id" "$name" "" unknown log-unreadable "$url" "$WORK/ev"
    log "job $job_id ($name): unknown, its log could not be fetched; read it by hand at $url"
    continue
  fi
  mv "$WORK/log" "$joblog"
  if [ ! -s "$joblog" ]; then
    printf 'log empty\n' >>"$WORK/ev"
    row job "$job_id" "$name" "" unknown log-empty "$url" "$WORK/ev"
    log "job $job_id ($name): unknown, its log is empty; read it by hand at $url"
    continue
  fi

  # Test rows follow their job's row, so they are held until it is written.
  read_log "$joblog" >"$WORK/records"
  worst=0 tests=''
  : >"$WORK/testrows"
  ROW_OUT=$WORK/testrows
  while IFS=$'\t' read -r kind script treason ev; do
    [ "$kind" = T ] || continue
    class=real
    case $treason in
      unparsable-marker) class=unknown ;;
      test-failed) if is_flake "$script"; then class=flaky treason=known-flake; fi ;;
    esac
    printf '%s\n' "$ev" | tr '\037' '\n' >"$WORK/tev"
    row test "$job_id" "$name" "$script" "$class" "$treason" "$url" "$WORK/tev"
    [ "$(rank "$class")" -le "$worst" ] || worst=$(rank "$class")
    tests="$tests $script"
  done <"$WORK/records"
  ROW_OUT=$WORK/rows.ndjson

  if [ -n "$tests" ]; then
    case $worst in 3) class=real ;; 2) class=unknown ;; *) class=flaky ;; esac
    printf 'failing tests:%s\n' "$tests" >>"$WORK/ev"
    row job "$job_id" "$name" "" "$class" tests-failed "$url" "$WORK/ev"
    cat "$WORK/testrows" >>"$ROW_OUT"
    log "job $job_id ($name): $class, failing tests:$tests"
  elif grep -q $'^E\t' "$WORK/records"; then
    grep $'^E\t' "$WORK/records" | cut -f2- | tr '\037' '\n' >>"$WORK/ev"
    row job "$job_id" "$name" "" real step-failed "$url" "$WORK/ev"
    log "job $job_id ($name): real, a step failed outside tests"
  else
    { printf 'no failing test and no ##[error] line; last lines:\n'
      grep $'^N\t' "$WORK/records" | cut -f2- | tr '\037' '\n'; } >>"$WORK/ev"
    row job "$job_id" "$name" "" unknown failure-not-in-log "$url" "$WORK/ev"
    log "job $job_id ($name): unknown, the log shows no failure; read it by hand at $url"
  fi
done <"$WORK/failed"

# --- the list ---------------------------------------------------------------

jq -s --slurpfile run "$WORK/run.json" --arg read_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson jobs "$total_jobs" --argjson failed "$failed_jobs" '
  . as $rows | $run[0] as $r
  | {schema: "fm-ci-errors/v1",
     run: {id: $r.id, attempt: ($r.run_attempt // 1), url: ($r.html_url // ""),
           workflow: ($r.name // ""), branch: ($r.head_branch // ""), head_sha: ($r.head_sha // ""),
           conclusion: ($r.conclusion // ""), read_at: $read_at, jobs: $jobs, failed_jobs: $failed},
     counts: ({rows: ($rows | length)} + (["real", "flaky", "infra", "unknown"]
       | map({key: ., value: (. as $c | $rows | map(select(.class == $c)) | length)}) | from_entries)),
     rows: $rows}' "$WORK/rows.ndjson" >"$WORK/errors.json" || refuse 1 "cannot assemble errors.json"

jq -r --arg repo "$REPO" '
  def cell: tostring | gsub("\\|"; "\\|");
  .run as $r | .counts as $c
  | "# CI errors: run \($r.id), attempt \($r.attempt)", "",
    "- Run: \($r.url)",
    "- Workflow: \($r.workflow), branch `\($r.branch)`, head `\($r.head_sha)`, conclusion \($r.conclusion)",
    "- Read: \($r.read_at), \($r.jobs) jobs, \($r.failed_jobs) failed",
    "- Rows: \($c.rows) (real \($c.real), flaky \($c.flaky), infra \($c.infra), unknown \($c.unknown))",
    "- Next: " + (
      if $c.rows == 0 then "nothing failed."
      elif $c.real + $c.unknown > 0 then "read every real and unknown row; fix every real and test-defect cause in one commit."
      elif $c.flaky > 0 then "only known flakes and infra failed; a flake counts as infra only when the change does not touch what it tests."
      else "infra only: `gh run rerun \($r.id) --failed -R \($repo)` once, with no new push." end),
    "",
    (if $c.rows > 0 then
      "| Kind | Job | Test | Class | Reason | Evidence | URL |",
      "|---|---|---|---|---|---|---|",
      (.rows[] | "| \(.kind) | \(.job | cell) | \(.test | cell) | \(.class) | \(.reason) | \(.evidence | map(cell) | join("<br>")) | \(.url) |")
    else empty end)' "$WORK/errors.json" >"$WORK/errors.md" || refuse 1 "cannot render errors.md"

mv -f "$WORK/errors.json" "$OUT/errors.json" || refuse 1 "cannot write errors.json into $OUT"
mv -f "$WORK/errors.md" "$OUT/errors.md" || refuse 1 "cannot write errors.md into $OUT"
summary=$(jq -r '"rows=\(.counts.rows) real=\(.counts.real) flaky=\(.counts.flaky) infra=\(.counts.infra) unknown=\(.counts.unknown)"' "$OUT/errors.json")
attempt=$(jq -r .run.attempt "$OUT/errors.json")
log "written: $summary in $OUT/errors.md; next: act on its rows"
printf 'fm-ci-errors/v1 run=%s attempt=%s %s list=%s/errors.md\n' "$RUN" "$attempt" "$summary" "$OUT"
