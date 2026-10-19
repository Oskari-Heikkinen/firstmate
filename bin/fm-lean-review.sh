#!/usr/bin/env bash
# fm-lean-review.sh - Firstmate's lean, blocking pre-push review of one
# risky-path commit, and the writer of its CI receipt.
#
# A commit that changes a script matched by tests/risky-areas.list must pass
# this review before it is pushed; bin/fm-safety-guard.sh's `receipts` rule
# fails a pushed range in CI when such a commit lacks the matching receipt, and
# that script's header owns the rule and what the receipt id covers. Commits
# that change no risky-area script need nothing, and this script says so.
#
# Usage (run inside the repository, normally on the commit just made):
#   fm-lean-review.sh [--commit <rev>] [--intent-file <path>] [--print-only]
#     --commit       the commit to review; default HEAD.
#     --intent-file  extra stated intent: the task's captain intent, and any
#                    firstmate answer to an earlier DECIDE finding. The commit
#                    message is always included.
#     --print-only   on a pass, print the trailer line instead of amending.
#
# One separate, read-only reviewer call reads the commit's diff and its stated
# intent and answers four questions (and Q5 below when a mapped path is
# touched): intent (no more, no less), weakened guards, real-runtime
# assumptions (naming the opt-in live lab test or saying one is missing), and
# untested risky-area behaviour. It is told not to judge test results, lint,
# style, or doc wording, and it never runs a command.
#
# A fifth question, Q5 architecture conformance, is asked only when the
# commit's first-parent diff touches a path the repository's component map
# (docs/component-map.md) claims. Its text is `bin/fm-component-map.sh
# review-pack` output for the commit: each touched component's skill path,
# changed paths, and `## Review` checklist, which the reviewer checks the
# change against. With no map, no touched component, or a root commit there
# is no Q5 and the prompt is the four-question one. A review-pack that fails
# (map unusable, git error) never blocks the review: a warning on stderr names
# the status, Q5 is not asked, and the review runs on Q1-Q4; repair the map
# with `bin/fm-component-map.sh check`. A pack in which a checklist could not
# be read is still asked, each such block saying why, with the same warning.
#
# The reviewer must answer in this strict form, and anything else is an error:
#   VERDICT: PASS
# or
#   VERDICT: FINDINGS
#   FINDING: <Q1|Q2|Q3|Q4> <FIX|DECIDE> <one-line finding>
#   (one FINDING line each, Q5 too when it was asked; no other text)
# FIX means the worker fixes it and reviews again; DECIDE means the finding is
# ambiguous or changes scope, so the worker reports it to firstmate as a
# needs-decision status line and re-runs with the answer in --intent-file.
#
# On a pass of HEAD the script amends HEAD's message only (never the staged
# index) to add the `Lean-Review: <receipt id>` trailer, replacing any older
# one, and verifies the tree is unchanged; for another commit, or with
# --print-only, it prints the trailer line to add. A commit already carrying
# its matching receipt is not reviewed again.
#
# Reviewer call: FM_LEAN_REVIEW_CMD, a bash command string that reads the
# prompt on stdin and prints the verdict on stdout, replaces the default, which
# is Claude Code's print mode under the calling worker's own Claude account
# (CLAUDE_CONFIG_DIR as its launch set it), in a fresh unsaved session with
# customizations and hooks off and only the Read, Grep, and Glob tools:
#   claude -p --safe-mode --restricted --strict-mcp-config
#     --no-session-persistence --tools Read,Grep,Glob
#     --allowedTools Read,Grep,Glob --permission-mode dontAsk
#     --output-format text --effort <FM_LEAN_REVIEW_EFFORT, default medium>
#     [--model <FM_LEAN_REVIEW_MODEL>]
# The call is bounded by FM_LEAN_REVIEW_TIMEOUT seconds (default 900).
#
# Exit status: 0 pass (receipt written or printed) or no review needed;
# 1 FIX findings only; 3 at least one DECIDE finding; 2 a usage, setup, or
# reviewer error, including a timeout or an answer not in the strict form.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$SELF_DIR/fm-safety-guard.sh"
RECEIPT_KEY=Lean-Review
# shellcheck source=bin/fm-timeout-lib.sh
. "$SELF_DIR/fm-timeout-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-lean-review: %s\n' "$*" >&2
  exit 2
}

commit=HEAD intent_file='' print_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) [ $# -ge 2 ] || die "--commit needs a revision"; commit=$2; shift 2 ;;
    --intent-file) [ $# -ge 2 ] || die "--intent-file needs a path"; intent_file=$2; shift 2 ;;
    --print-only) print_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[ -z "$intent_file" ] || [ -r "$intent_file" ] || die "intent file $intent_file is not readable"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run inside the repository whose commit you review"
sha=$(git rev-parse --verify --quiet "$commit^{commit}") || die "$commit is not a known commit"
short=$(git rev-parse --short "$sha")

id=$("$GUARD" receipt-id "$sha"); rc=$?
case "$rc" in
  0) ;;
  1) printf 'fm-lean-review: %s changes no risky-area script; no review needed\n' "$short"; exit 0 ;;
  *) die "could not compute the receipt id of $short" ;;
esac
trailer="$RECEIPT_KEY: $id"

if git log -1 --format="%(trailers:key=$RECEIPT_KEY,valueonly)" "$sha" | grep -Fxq -- "$id"; then
  printf 'fm-lean-review: %s already carries its matching receipt; no review needed\n' "$short"
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-lean-review.XXXXXX") || die "mktemp failed"
# shellcheck disable=SC2064 # expand tmp now
trap "rm -rf '$tmp'" EXIT

# Q5's review pack: empty when nothing mapped is touched, dropped with a
# warning when the resolver fails, so the Q1-Q4 review always runs.
pack=''
if parent=$(git rev-parse --verify --quiet "$sha^1"); then
  top=$(git rev-parse --show-toplevel) || die "could not find the repository top level"
  pack=$("$SELF_DIR/fm-component-map.sh" review-pack "$top" "$parent" "$sha" 2>"$tmp/pack.err"); rc=$?
  case "$rc" in
    0) ;;
    1) printf 'fm-lean-review: warning: a component review checklist could not be read; its Q5 block says why (see bin/fm-component-map.sh check)\n' >&2 ;;
    *)
      printf 'fm-lean-review: warning: bin/fm-component-map.sh review-pack failed with status %s, so Q5 (architecture conformance) is not asked; repair the map with bin/fm-component-map.sh check\n' "$rc" >&2
      sed 's/^/  | /' "$tmp/pack.err" >&2
      pack='' ;;
  esac
fi
qmax=4 count=four q5_scope='' q5_question='' q5_judge='' q5_read='' q5_fix='' q5_list='' q5_form=''
if [ -n "$pack" ]; then
  qmax=5 count=five
  q5_scope=$'\nIt also touches architecture components, each governed by a component skill whose review checklist is below.'
  q5_question=$'\nQ5 Architecture conformance: for each component whose checklist is below, does the change keep that component\'s goal and pass every check of its checklist, rather than adding a short-term fix its rules refuse? A check the change does not bear on passes, and a checklist that could not be read is not itself a finding.'
  q5_judge=', unless a Q5 checklist check asks about it'
  q5_read=', and the skill file each Q5 checklist names'
  q5_fix=' or a Q5 checklist'
  q5_list='|Q5'
  q5_form='; for Q5, also the component id and check number'
fi

{
  cat <<EOF
You are a lean pre-push reviewer for one commit to Firstmate, a supervisor for AI coding agents built mostly from bash scripts.
You did not write this change; judge it independently.
The commit touches Firstmate's risky areas: watcher and supervision, cleanup (teardown and park), steering and control, fleet sync and self-update, or the spawn and merge guards.$q5_scope

Answer only these $count questions:
Q1 Intent: does the change do what the stated intent asks, no more and no less (no scope creep, no missing piece)?
Q2 Weakened guards: did any refusal, check, lock, timeout, allow-list, or safety condition get weaker, removed, bypassable, or widened, even if every test still passes?
Q3 Runtime assumptions: does the change rely on how the real Claude or Codex terminal, WSL timing, or the live Herdr server behaves? If so, name the opt-in live lab test that should be run (tests in the live-harness-optin family of bin/fm-test-run.sh, or Herdr lab tests), or say that one is missing.
Q4 Untested behaviour: is there new behaviour in a risky area with no test that would fail if it broke?$q5_question

Do not judge, and do not report on: whether tests pass, lint or shellcheck, formatting or style, documentation wording, or anything CI already proves$q5_judge.
Do not run commands.
You may read the files this diff touches, and their tests$q5_read, with the Read, Grep, and Glob tools; the working tree may hold later commits than this one, so the diff below is authoritative.
Report only real problems you can point to in this diff; a concern without concrete evidence is not a finding.
Mark a finding FIX when the change should be corrected to match the stated intent$q5_fix, and DECIDE when it is ambiguous whether the behaviour is wanted or fixing it would change the task's scope.

Answer with exactly one of these two forms and no other text, no code fences, and no explanation outside the finding lines:

VERDICT: PASS

or

VERDICT: FINDINGS
FINDING: <Q1|Q2|Q3|Q4$q5_list> <FIX|DECIDE> <one-line finding naming the file and what is wrong$q5_form>

Use one FINDING line per finding.

## Stated intent: commit message
EOF
  git log -1 --format=%B "$sha" | grep -v -i "^$RECEIPT_KEY:"
  if [ -n "$intent_file" ]; then
    printf '\n## Stated intent: task intent and decisions\n'
    cat "$intent_file"
  fi
  if [ -n "$pack" ]; then
    printf '\n## Q5 component review checklists\n\n%s\n' "$pack"
  fi
  printf '\n## The commit diff\n'
  git show --first-parent --diff-merges=first-parent --no-color --no-ext-diff --no-renames --format='commit %H' --stat -p "$sha"
} >"$tmp/prompt" || die "could not build the review prompt"

cmd=${FM_LEAN_REVIEW_CMD:-}
if [ -z "$cmd" ]; then
  cmd="claude -p --safe-mode --restricted --strict-mcp-config --no-session-persistence"
  cmd="$cmd --tools Read,Grep,Glob --allowedTools Read,Grep,Glob --permission-mode dontAsk"
  cmd="$cmd --output-format text --effort $(printf '%q' "${FM_LEAN_REVIEW_EFFORT:-medium}")"
  [ -z "${FM_LEAN_REVIEW_MODEL:-}" ] || cmd="$cmd --model $(printf '%q' "$FM_LEAN_REVIEW_MODEL")"
fi
timeout=${FM_LEAN_REVIEW_TIMEOUT:-900}
case "$timeout" in ''|*[!0-9]*) die "FM_LEAN_REVIEW_TIMEOUT must be whole seconds" ;; esac

printf 'fm-lean-review: reviewing %s (one reviewer call, up to %ss)\n' "$short" "$timeout"
export FM_LEAN_REVIEW_PROMPT="$tmp/prompt" FM_LEAN_REVIEW_OUT="$tmp/out"
fm_run_timed "$timeout" bash -c "{ $cmd
} <\"\$FM_LEAN_REVIEW_PROMPT\" >\"\$FM_LEAN_REVIEW_OUT\""
rc=$?
if fm_timed_out "$rc"; then
  die "the reviewer call hit its ${timeout}s bound; nothing was recorded"
fi
[ "$rc" -eq 0 ] || die "the reviewer call failed with status $rc; nothing was recorded"

# Parse the strict verdict: blank lines are ignored, the first line must be the
# verdict, PASS takes no other line, and FINDINGS takes only FINDING lines.
verdict='' findings=0 decide=0 bad=''
finding_re="^FINDING: Q[1-$qmax] (FIX|DECIDE) [^[:space:]]"
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in *[![:space:]]*) ;; *) continue ;; esac
  if [ -z "$verdict" ]; then
    case "$line" in
      'VERDICT: PASS') verdict=pass ;;
      'VERDICT: FINDINGS') verdict=findings ;;
      *) bad=$line; break ;;
    esac
    continue
  fi
  if [ "$verdict" = findings ] && [[ $line =~ $finding_re ]]; then
    findings=$((findings + 1))
    [ "${BASH_REMATCH[1]}" = FIX ] || decide=1
    continue
  fi
  bad=$line
  break
done <"$tmp/out"
if [ -n "$bad" ] || [ -z "$verdict" ] || { [ "$verdict" = findings ] && [ "$findings" -eq 0 ]; }; then
  printf 'fm-lean-review: the reviewer did not answer in the strict verdict form; nothing was recorded\n' >&2
  [ -z "$bad" ] || printf '  unexpected line: %s\n' "$bad" >&2
  printf '  reviewer output:\n' >&2
  sed 's/^/  | /' "$tmp/out" >&2
  exit 2
fi

if [ "$verdict" = findings ]; then
  printf 'fm-lean-review: %s has %s finding(s); nothing was recorded\n' "$short" "$findings"
  grep '^FINDING: ' "$tmp/out" | tr -d '\r' | sed 's/^/  /'
  if [ "$decide" -eq 1 ]; then
    printf 'Report the DECIDE finding(s) to firstmate as a needs-decision status line, then re-run with the answer in --intent-file; amend a fix for any FIX finding into this commit first.\n'
    exit 3
  fi
  printf 'Amend the fix into this commit and review again.\n'
  exit 1
fi

if [ "$print_only" -eq 1 ] || [ "$sha" != "$(git rev-parse HEAD)" ]; then
  printf 'fm-lean-review: %s passed; add this trailer to its commit message:\n%s\n' "$short" "$trailer"
  exit 0
fi
tree=$(git rev-parse "HEAD^{tree}")
git -c trailer.ifexists=replace commit --quiet --amend --only --no-edit --trailer "$trailer" \
  || die "the review passed, but amending HEAD with the receipt failed; add this trailer yourself: $trailer"
[ "$(git rev-parse "HEAD^{tree}")" = "$tree" ] \
  || die "amending HEAD changed its tree; inspect HEAD before pushing"
git log -1 --format="%(trailers:key=$RECEIPT_KEY,valueonly)" HEAD | grep -Fxq -- "$id" \
  || die "the amended HEAD does not carry the receipt; add this trailer yourself: $trailer"
printf 'fm-lean-review: %s passed; HEAD is now %s with %s\n' "$short" "$(git rev-parse --short HEAD)" "$trailer"
