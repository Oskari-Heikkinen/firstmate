#!/usr/bin/env bash
# fm-lint-workflows.sh - owner of firstmate's GitHub workflow lint.
#
# Runs pinned actionlint on every .github/workflows/*.{yml,yaml} so a malformed
# workflow, including a self-broken ci.yml, fails in the local and no-mistakes
# lint lane before merge. A broken ci.yml cannot report its own breakage, so
# this check must not live only as a step inside that workflow. bin/fm-lint.sh
# invokes this owner on its default (no explicit-path) path, which CI and
# commands.lint both use.
#
# After actionlint passes, a policy check holds every workflow that runs on
# push (python3 with PyYAML parses it; either missing fails closed):
#   - every job sets timeout-minutes to a positive integer, so a hung job
#     cannot hold a runner for GitHub's six-hour default;
#   - a push run is never cancelled or replaced: every concurrency block leaves
#     cancel-in-progress absent or literally false, and its group names
#     github.run_id, because a group also drops older pending runs.
#
# Usage:
#   fm-lint-workflows.sh                 lint workflows under this repo
#   fm-lint-workflows.sh --root <dir>    lint workflows under <dir>
#   fm-lint-workflows.sh <path>...       lint explicit workflow files
#   fm-lint-workflows.sh --required-version
#   fm-lint-workflows.sh --help
set -eu

REQUIRED_ACTIONLINT=1.7.12
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-workflows.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_ACTIONLINT"
  exit 0
fi

fm_lint_workflows_usage() {
  sed -n '2,24{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-workflows.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_lint_workflows_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-workflows.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-workflows.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

FILES=()
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'fm-lint-workflows.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'fm-lint-workflows.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    FILES+=("$path")
  done
else
  workflow_dir="$ROOT/.github/workflows"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$workflow_dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'fm-lint-workflows.sh: no GitHub workflow files found under %s\n' \
      "$workflow_dir" >&2
    exit 1
  fi
fi

if ! command -v actionlint >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: actionlint not found; install actionlint %s with bin/fm-install-actionlint.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi
ACTIONLINT_BIN=$(command -v actionlint)
resolved=$("$ACTIONLINT_BIN" -version | awk 'NR==1 {print; exit}')
printf 'fm-lint-workflows.sh: actionlint %s (pinned %s)\n' "$resolved" "$REQUIRED_ACTIONLINT" >&2
if [ "$resolved" != "$REQUIRED_ACTIONLINT" ]; then
  printf 'fm-lint-workflows.sh: actionlint %s required for CI parity, found %s. Install %s with bin/fm-install-actionlint.sh <destination-directory>.\n' \
    "$REQUIRED_ACTIONLINT" "$resolved" "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi

# fm-lint.sh owns ShellCheck of the canonical shell set. Disable actionlint's
# extra shell and Python subprocess linters so this gate is the named workflow
# linter, not a second shell lint of `run:` blocks.
set +e
"$ACTIONLINT_BIN" -no-color -shellcheck= -pyflakes= -- "${FILES[@]}"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

if ! command -v python3 >/dev/null 2>&1 \
  || ! python3 -I -c 'import yaml' >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: python3 with PyYAML is required for the workflow policy check.\n' >&2
  exit 1
fi
python3 -I - "${FILES[@]}" <<'PY'
import sys
import yaml

problems = []


def triggers(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return set(on)
    return set()


def check_concurrency(path, where, conc):
    if conc is None:
        return
    if not isinstance(conc, dict):
        problems.append(f"{path}: {where} concurrency must be a mapping naming github.run_id in its group")
        return
    cancel = conc.get("cancel-in-progress", False)
    if cancel is not False:
        problems.append(f"{path}: {where} concurrency cancel-in-progress must be absent or false in a push workflow (got {cancel!r})")
    if "github.run_id" not in str(conc.get("group", "")):
        problems.append(f"{path}: {where} concurrency group must name github.run_id so no push run is replaced")


for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    if not isinstance(doc, dict) or "push" not in triggers(doc):
        continue
    check_concurrency(path, "workflow", doc.get("concurrency"))
    for name, job in (doc.get("jobs") or {}).items():
        job = job or {}
        limit = job.get("timeout-minutes")
        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            problems.append(f"{path}: job {name} needs timeout-minutes as a positive integer (got {limit!r})")
        check_concurrency(path, f"job {name}", job.get("concurrency"))

for problem in problems:
    print(f"fm-lint-workflows.sh: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

printf 'fm-lint-workflows.sh: %s workflow files valid\n' "${#FILES[@]}"
exit 0
