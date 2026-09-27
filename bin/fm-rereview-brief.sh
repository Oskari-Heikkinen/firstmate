#!/usr/bin/env bash
# Scaffold and fill a short independent re-review scout brief after a builder
# fixed an earlier review's findings, so firstmate never hand-copies them.
#
# Usage: fm-rereview-brief.sh <task-id> <repo-name> --first <review-task-id|report.md>
#          --commit <rev> --file <path> [--file <path>...] [--repo-dir <dir>]
#          [--heavy-slot <path>] [--context <text>] [--spec <text>]
#   <task-id>        the new re-review scout's task id.
#   <repo-name>      the project the candidate lives in, passed to fm-brief.sh.
#   --first          the first review: a task id whose data/<id>/report.md exists
#                    under the active home, or a path to its report file.
#   --commit         the landed commit carrying the fixes; resolved to its full
#                    sha in --repo-dir without fetching.
#   --file           a candidate file path inside the repo; repeatable. Its
#                    sha256 is computed from the blob at that commit.
#   --repo-dir       the git clone holding the commit (default: the active
#                    home's projects/<repo-name>). It is only read, never fetched.
#   --heavy-slot     optional heavy-slot helper; heavy runs then go through
#                    `<path> --validate` (env FM_HEAVY_SLOT is the fallback).
#   --context        optional extra context appended to the Captain's intent,
#                    such as the live copy's path and digest.
#   --spec           optional extra build line appended to the Firstmate spec;
#                    repeatable.
#
# The first report must have exactly one `#`/`##` heading starting with
# "Verdict" and exactly one starting with "Findings", each with non-empty
# content up to the next heading of the same or higher level (fenced code is
# not scanned for headings). Both are copied verbatim as quoted blocks, never
# summarized or invented. When either section is missing, ambiguous, or empty,
# or the commit or any candidate file cannot be resolved, the script refuses
# and writes nothing.
#
# On success it runs `fm-brief.sh <task-id> <repo-name> --scout`, replaces the
# {TASK} and {FIRSTMATE_SPEC} placeholders atomically, and prints
# `filled: <brief path>`. The filled brief asks for a verdict (safe to cut over /
# safe with named fixes / not safe), each first-review finding closed or open
# with evidence, anything newly broken, and final cutover steps pinned to the
# computed digests with the live pre-check and a rollback copy. Dispatch stays
# with firstmate through the usual fm-spawn path.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
ID=$1
REPO=$2
shift 2
case "$ID" in ''|-*|*/*) die "invalid task id: $ID" ;; esac
case "$REPO" in ''|-*) die "invalid repo name: $REPO" ;; esac

FIRST=
COMMIT=
REPO_DIR=
HEAVY_SLOT=${FM_HEAVY_SLOT:-}
CONTEXT=
FILES=()
SPECS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --first|--commit|--file|--repo-dir|--heavy-slot|--context|--spec)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --first) FIRST=$2 ;;
        --commit) COMMIT=$2 ;;
        --file) FILES+=("$2") ;;
        --repo-dir) REPO_DIR=$2 ;;
        --heavy-slot) HEAVY_SLOT=$2 ;;
        --context) CONTEXT=$2 ;;
        --spec) SPECS+=("$2") ;;
      esac
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$FIRST" ] || die "--first <review-task-id|report.md> is required"
[ -n "$COMMIT" ] || die "--commit <rev> is required"
[ "${#FILES[@]}" -gt 0 ] || die "at least one --file <path> is required"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}

if [ -f "$FIRST" ]; then
  REPORT=$FIRST
elif [ -f "$DATA/$FIRST/report.md" ]; then
  REPORT=$DATA/$FIRST/report.md
else
  die "first review report not found: $FIRST (neither a file nor $DATA/$FIRST/report.md)"
fi
REPORT=$(cd "$(dirname "$REPORT")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$REPORT")")

[ -n "$REPO_DIR" ] || REPO_DIR=$FM_HOME/projects/$REPO
git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || die "repo dir is not a git clone: $REPO_DIR (pass --repo-dir)"
SHA=$(git -C "$REPO_DIR" rev-parse --verify --quiet "$COMMIT^{commit}") \
  || die "commit $COMMIT not found in $REPO_DIR; fetch it there first"

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

DIGESTS=
for f in "${FILES[@]}"; do
  [ "$(git -C "$REPO_DIR" cat-file -t "$SHA:$f" 2>/dev/null)" = blob ] \
    || die "candidate file $f is not a file at $SHA"
  d=$(git -C "$REPO_DIR" cat-file blob "$SHA:$f" | sha256_stdin)
  case "$d" in
    [0-9a-f]*) [ "${#d}" -eq 64 ] || die "could not hash $f at $SHA" ;;
    *) die "could not hash $f at $SHA" ;;
  esac
  DIGESTS="$DIGESTS- \`$f\` sha256 \`$d\`"$'\n'
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-rereview-brief.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$WORK"' EXIT

# Extract the Verdict and Findings sections as quoted blocks, or refuse.
python3 - "$REPORT" "$WORK" <<'PY' || exit 1
import re, sys
report, work = sys.argv[1], sys.argv[2]
lines = open(report, encoding="utf-8").read().splitlines()
heads = []  # (index, level, text)
fence = None
for i, line in enumerate(lines):
    m = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
    if m:
        mark = m.group(1)
        if fence is None:
            fence = mark[0] * len(mark)
        elif mark.startswith(fence):
            fence = None
        continue
    if fence is not None:
        continue
    h = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
    if h:
        heads.append((i, len(h.group(1)), h.group(2)))

def section(name):
    found = [h for h in heads if h[1] <= 2 and re.match(name + r"\b", h[2], re.I)]
    if len(found) != 1:
        what = "no" if not found else "more than one"
        sys.stderr.write(f"error: {what} '{name}' heading in {report}; refusing to guess\n")
        sys.exit(1)
    start, level, text = found[0]
    end = len(lines)
    for i, lvl, _ in heads:
        if i > start and lvl <= level:
            end = i
            break
    body = lines[start + 1:end]
    while body and not body[0].strip():
        body.pop(0)
    while body and not body[-1].strip():
        body.pop()
    rest = re.sub(r"^" + name + r"\b\s*[:\-]?\s*", "", text, flags=re.I)
    if rest:
        body = ["**" + rest + "**", ""] + body
    if not any(l.strip() for l in body):
        sys.stderr.write(f"error: the '{name}' section in {report} is empty; refusing to guess\n")
        sys.exit(1)
    return "\n".join(("> " + l) if l.strip() else ">" for l in body)

open(work + "/verdict", "w", encoding="utf-8").write(section("Verdict"))
open(work + "/findings", "w", encoding="utf-8").write(section("Findings"))
PY

HEAVY_LINE="Any test, preview, or other heavy local run: run it at nice 19 and ionice -c3"
if [ -n "$HEAVY_SLOT" ]; then
  HEAVY_LINE="$HEAVY_LINE through \`$HEAVY_SLOT --validate\`."
else
  HEAVY_LINE="$HEAVY_LINE."
fi

{
  printf '%s\n' "Short independent re-review of the fixes a builder landed after the first review of this $REPO candidate: are the first review's findings closed, is anything new broken, and is the candidate now safe to cut over?"
  if [ -n "$CONTEXT" ]; then printf '%s\n' "$CONTEXT"; fi
  printf '\n%s\n\n' "The first independent review (\`$REPORT\`) reached this verdict:"
  cat "$WORK/verdict"
  printf '\n\n%s\n\n' "Its findings:"
  cat "$WORK/findings"
  printf '\n\n%s\n' "The fixes landed on $REPO in \`$SHA\`, with these candidate digests at that commit:"
  printf '%s' "$DIGESTS"
} > "$WORK/task"

{
  printf '%s\n' "Read-only re-review of the fix diff, not a fresh full review. Do not fix code yourself, never push, and never modify any live copy, live queue or feed, running process, or any home's data/; exercise the candidate only in your scratch copy against temporary or copied inputs."
  printf '%s\n' "Fetch origin, inspect the candidate at \`$SHA\`, and verify each digest above yourself from that commit, for example \`git show $SHA:<path> | sha256sum\`."
  printf '%s\n' "Read the first report at \`$REPORT\` and check each of its findings item by item against the candidate, reproducing each original failure where the report shows how."
  printf '%s\n' "$HEAVY_LINE"
  for s in ${SPECS[@]+"${SPECS[@]}"}; do printf '%s\n' "$s"; done
  printf '%s\n' "Report: a clear verdict (safe to cut over / safe with named fixes / not safe); each first-review finding marked closed or still open with evidence (commands, output, file:line); anything new broken; and the final cutover steps pinned to the digests above, including the pre-check that the live copy is still the reviewed baseline and the rollback copy, carried forward from the first report where it gave them."
} > "$WORK/spec"

out=$("$SCRIPT_DIR/fm-brief.sh" "$ID" "$REPO" --scout) || exit 1
BRIEF=$(printf '%s\n' "$out" | sed -n 's/^scaffolded: \(.*\) (scout;.*$/\1/p' | head -n 1)
[ -n "$BRIEF" ] && [ -f "$BRIEF" ] || die "could not locate the scaffolded brief from: $out"

python3 - "$BRIEF" "$WORK/task" "$WORK/spec" <<'PY' || exit 1
import os, sys
brief, task, spec = sys.argv[1:4]
text = open(brief, encoding="utf-8").read()
for ph in ("{TASK}", "{FIRSTMATE_SPEC}"):
    if text.count(ph) != 1:
        sys.stderr.write(f"error: expected exactly one {ph} in {brief}\n")
        sys.exit(1)
# Splice both at their scaffold positions so report text that happens to
# contain a placeholder spelling is never itself substituted.
t = text.index("{TASK}")
s = text.index("{FIRSTMATE_SPEC}")
if t > s:
    sys.stderr.write(f"error: unexpected placeholder order in {brief}\n")
    sys.exit(1)
task_text = open(task, encoding="utf-8").read().rstrip("\n")
spec_text = open(spec, encoding="utf-8").read().rstrip("\n")
text = text[:t] + task_text + text[t + 6:s] + spec_text + text[s + 16:]
tmp = brief + ".tmp"
open(tmp, "w", encoding="utf-8").write(text)
os.replace(tmp, brief)
PY

echo "filled: $BRIEF"
