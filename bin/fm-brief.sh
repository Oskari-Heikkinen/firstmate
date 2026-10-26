#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Its Rules always state the only criteria for judging options
# (for planners, evaluators and reviewers alike) and point any tool work at the
# tool-design skill by absolute path. Ship and scout `# Task` sections have
# two subsections Firstmate fills before dispatch: `{TASK}` under
# `## Captain's intent` (the captain's own ask plus the context needed to read it, including the substance of any
# report, decision, or PR the ask refers to, without added speaker labels or
# direct address) and `{FIRSTMATE_SPEC}`
# under `## Firstmate spec` (build instructions, which are never the captain's
# intent). bin/fm-dod-lib.sh owns the no-mistakes `--intent` contract those
# subsections feed; bin/fm-spawn.sh refuses leftover placeholders and a
# `## Captain's intent` line opening with a Captain label or address. Secondmate
# charters still use a single `{TASK}` charter fill. Firstmate may adjust other
# sections when the task genuinely deviates (e.g. working an existing external
# PR instead of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|direct-push|local-only> [--branch-prefix <prefix>] [--base-branch <branch>] [--forge <none|gerrit|forgejo> [--shape squash]] [--review-range <base>...<head>] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--base-branch <branch>] [--review-range <base>...<head>] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#        fm-brief.sh <task-id> --secondmate --render-charter <stored-charter> [--dropped-lines]
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --render-charter prints the current charter template to stdout around the
#   stored charter's Charter, Routing scope, and Project clones sections and any
#   section the template does not own, writing nothing. With --dropped-lines it
#   prints instead each nonblank line of the stored copy's template-owned text
#   that the render would not carry. bin/fm-home-seed.sh --refresh-charter owns
#   applying a render to a seeded home.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} and {FIRSTMATE_SPEC} are filled
#   after scaffolding and the caller-supplied repo string cannot reliably
#   identify this repo. Briefs made without it carry a loud declaration so an
#   omitted contract cannot be silent.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   direct-push  implement -> rebase + full local suite -> fast-forward push to the
#                default branch, no PR; the launch brief's landing authority (from
#                the spawn's yolo) says whether to land at once or stop at ready
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the concrete modes at intake before calling this script.
# --branch-prefix <prefix> optionally overrides the ship branch's "fm/" prefix, so
# the resolved branch is "<prefix><task-id>" instead of the default "fm/<task-id>".
# Pass an empty prefix ("--branch-prefix ''") for a bare "<task-id>" branch, or a
# conventional prefix such as "fix/" - useful for a third-party project that does
# not use this tooling and should not see an "fm/"-branded branch or PR. Defaults
# to "fm/" when omitted, so every existing installation's branch names are
# unchanged. Like --mode, this script never reads data/projects.md for it: the
# registry's optional "branch=<prefix>" annotation (bin/fm-project-mode.sh's
# header owns that format and its --branch-prefix query) is the captain's
# standing per-project preference, and firstmate resolves it per task at intake
# and passes the explicit flag. Refused on --scout and --secondmate: a scout
# makes no branch and a charter is not a delivery contract.
# --base-branch <branch> starts the task from origin's <branch> instead of the
# repository default, for work that belongs on a named integration, feature, or
# release branch. It writes a "Base branch: <branch>" line under `# Setup`, which
# bin/fm-spawn.sh requires to agree with the same --base-branch it is passed to
# choose the copy's starting point, and a ship's
# Definition of done then targets that branch with its pull request.
# bin/fm-dod-lib.sh's fm_base_branch_valid owns which deliveries accept one.
# Refused on --secondmate.
# --review-range <base>...<head> marks the task as a review of that range and
# writes a "Review range: <base>...<head>" line under `# Setup`.
# bin/fm-spawn.sh reads it and appends the review checklists of the components
# the range touches, from the repository's component map
# (docs/component-map.md), to the launch brief; bin/fm-dod-lib.sh's
# fm_review_range_valid owns the line's form. Refused on --secondmate.
# --forge names the project's forge, defaults to none, and is orthogonal to --mode
# exactly as the registry's `forge=` token is. It is the captain's confirmed
# registry binding, read from data/projects.md at intake and passed here; this
# script never infers a forge and never looks the binding up, and bin/fm-spawn.sh
# refuses a brief whose forge disagrees with the registry. bin/fm-project-mode.sh's
# header owns what the binding means, and bin/fm-dod-lib.sh owns what `gerrit`
# and `forgejo` change in the Definition of done. A forge on --mode local-only
# is refused, because that mode publishes nothing.
# --shape names how a forge=gerrit task is published, and only `squash` - one
# change - is accepted: `stack` is refused until a stack can be watched by its
# membership pinned when its watch is armed, because the merge watch follows one
# change.
# It defaults to squash on gerrit and is refused without it.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line, followed by " forge=gerrit shape=squash"
# on Gerrit or " forge=forgejo" on Forgejo. bin/fm-spawn.sh reads that line and
# refuses to launch a ship task whose explicit --mode or registered forge
# disagrees, so an adjusted brief and the recorded task metadata cannot drift
# apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Both crewmate scaffolds carry one shared rule against administering the
# infrastructure every lane shares - the no-mistakes daemon and the worktree pool
# their own slot came from - so ship and scout cannot drift apart. The check for
# when a pipeline block is real belongs to no-mistakes ships only, in the
# worker-guide no-mistakes-drive reference their Definition of done names. A secondmate
# charter omits it: that home allocates and returns slots for its own crewmates.
# --mode, --forge, and --shape are refused on scout and secondmate scaffolds: a
# scout's deliverable is a report rather than a merge, and a charter is not a
# delivery contract.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known wait expected to clear on its own, including
# the worker's own background work, pipeline or long command; blocked when
# firstmate must act. The wait tags, first-sight alert cadence, and parking live
# in the worker-guide waits-and-parking reference the scaffold names by path.
# Emission-time syntax and legacy unknown-time handling are owned by
# bin/fm-classify-lib.sh; each scaffold renders the stamp as a literal <epoch>
# placeholder that bin/fm-worker-status.sh, the ship and scout status command,
# fills in (a hand append replaces it with a numeric Unix time), so a scaffold
# never emits a substitution a file-write tool would copy through.
# Every scaffold also carries the steering-inbox receive-and-ack section:
# process state/<id>.inbox/*.msg in order and acknowledge each by moving it to
# handled/ (record, doorbell, and ladder owned by bin/fm-task-inbox-lib.sh).
# Ship tasks include a project-memory section bounding crewmate edits to a
# project's AGENTS.md/CLAUDE.md: only corrections of factually wrong
# information, including wrong information the task itself introduced - never
# additions of missing knowledge. A correction edits only the wrong text and
# never runs fm-ensure-agents-md.sh, whose inserted sections and created
# pointer file are themselves additions.
# Scaffolds carry no role scope, not even the crewmate identity line:
# fm-spawn.sh supplies fm_brief_worker_role from
# fm-dod-lib.sh to every ship/scout launch brief, so this file never becomes a
# second owner of a contract that must stay current across relaunches.
# A home may carry standing worker instructions without editing this tracked
# script: when config/brief-include.md exists under the active home, ship and
# scout scaffolds append its text verbatim as their last section, "# Home brief
# additions", which defers to every other section of the brief. It goes last
# because the machine-read `# Task` heading resolves to its first match, so
# appended text can never shadow it; a later scout promotion appends its ship
# contract below it, which that position-free deference already covers. An
# absent or blank file changes nothing; a present path that is not a readable
# regular file, or text carrying its own "Delivery contract: mode=" line (which
# would outrank the brief's own contract, since bin/fm-spawn.sh reads the last
# one), stops the scaffold before
# anything is written. Secondmate charters never take it.
# It validates before writing and never rewrites intent or instruction precedence.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
IFS= read -r -d '' CREWMATE_PAUSE_INSTRUCTIONS <<EOF || true
4. Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - for a wait expected to clear on its own, including your own validation round.
   Before ending your turn with your own background shell or monitor still running, or before waiting on your own pipeline run or a long foreground command, append \`$PAUSED_VERB [at=<epoch>]: {what you wait for and what resumes you}\` once, not on every poll.
   Do not declare active implementation or reasoning as a wait.
EOF

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
MODE=
MODE_SET=0
BRANCH_PREFIX=fm/
BRANCH_PREFIX_SET=0
BASE_BRANCH=
BASE_BRANCH_SET=0
REVIEW_RANGE=
REVIEW_RANGE_SET=0
FORGE=none
FORGE_SET=0
SHAPE=
SHAPE_SET=0
RENDER_CHARTER=
DROPPED_LINES=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      branch-prefix) BRANCH_PREFIX=$a; BRANCH_PREFIX_SET=1 ;;
      base-branch) BASE_BRANCH=$a; BASE_BRANCH_SET=1 ;;
      review-range) REVIEW_RANGE=$a; REVIEW_RANGE_SET=1 ;;
      forge) FORGE=$a; FORGE_SET=1 ;;
      shape) SHAPE=$a; SHAPE_SET=1 ;;
      render-charter) RENDER_CHARTER=$a ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --branch-prefix) want_value="branch-prefix" ;;
    --branch-prefix=*) BRANCH_PREFIX=${a#--branch-prefix=}; BRANCH_PREFIX_SET=1 ;;
    --base-branch) want_value="base-branch" ;;
    --base-branch=*) BASE_BRANCH=${a#--base-branch=}; BASE_BRANCH_SET=1 ;;
    --review-range) want_value="review-range" ;;
    --review-range=*) REVIEW_RANGE=${a#--review-range=}; REVIEW_RANGE_SET=1 ;;
    --forge) want_value=forge ;;
    --forge=*) FORGE=${a#--forge=}; FORGE_SET=1 ;;
    --shape) want_value=shape ;;
    --shape=*) SHAPE=${a#--shape=}; SHAPE_SET=1 ;;
    --render-charter) want_value=render-charter ;;
    --dropped-lines) DROPPED_LINES=1 ;;
    # yolo never reaches the worker: it is firstmate's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|direct-push|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|direct-push|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, direct-push, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi

# A ship branch's prefix is optional per-project cosmetics, not a delivery
# decision, but it still only makes sense where a branch is actually created.
if [ "$KIND" != ship ] && [ "$BRANCH_PREFIX_SET" -eq 1 ]; then
  echo "error: --branch-prefix applies only to ship briefs; a scout makes no branch and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
case "$BRANCH_PREFIX" in
  *' '*) echo "error: --branch-prefix must not contain a space (got '$BRANCH_PREFIX')" >&2; exit 1 ;;
  -*) echo "error: --branch-prefix must not start with '-' (got '$BRANCH_PREFIX')" >&2; exit 1 ;;
esac
# The forge is validated against the same closed set the renderers enforce, so a
# typo or an impossible mode/forge pair stops here rather than reaching a worker.
if [ "$KIND" = ship ]; then
  fm_forge_valid_for_mode "$FORGE" "$MODE" "fm-brief.sh --forge" || exit 1
  if [ "$FORGE" = gerrit ]; then
    [ "$SHAPE_SET" -eq 1 ] || SHAPE=squash
    case "$SHAPE" in
      squash) ;;
      stack)
        echo "error: --shape stack is refused: a stack is several changes, and it must be watched by its membership pinned when its watch is armed, which this fleet does not yet do - the merge watch follows exactly one change, so a stack's wake could report one change as the whole stack; publish --shape squash" >&2
        exit 1 ;;
      *) echo "error: --shape must be squash (got '$SHAPE')" >&2; exit 1 ;;
    esac
  elif [ "$SHAPE_SET" -eq 1 ]; then
    echo "error: --shape applies only with --forge gerrit, where the worker publishes the change itself" >&2
    exit 1
  fi
elif [ "$FORGE_SET" -eq 1 ] || [ "$SHAPE_SET" -eq 1 ]; then
  echo "error: --forge and --shape apply only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
if [ "$BASE_BRANCH_SET" -eq 1 ]; then
  if [ "$KIND" = secondmate ] || [ -z "$BASE_BRANCH" ]; then
    echo "error: --base-branch takes a branch name and applies only to ship and scout briefs" >&2
    exit 1
  fi
  fm_base_branch_valid "$BASE_BRANCH" "$MODE" "$FORGE" "fm-brief.sh --base-branch" || exit 1
fi
if [ "$REVIEW_RANGE_SET" -eq 1 ]; then
  if [ "$KIND" = secondmate ]; then
    echo "error: --review-range applies only to ship and scout briefs" >&2
    exit 1
  fi
  fm_review_range_valid "$REVIEW_RANGE" "fm-brief.sh --review-range" || exit 1
fi
ID=${POS[0]}
BRANCH="$BRANCH_PREFIX$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: --branch-prefix and task id must form a valid git branch (got '$BRANCH')" >&2
  exit 1
fi
printf -v BRANCH_Q '%q' "$BRANCH"

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$DROPPED_LINES" -eq 1 ] && [ -z "$RENDER_CHARTER" ]; then
  echo "error: --dropped-lines applies only with --render-charter" >&2
  exit 1
fi
if [ -n "$RENDER_CHARTER" ]; then
  [ "$KIND" = secondmate ] && [ "$NO_PROJECTS" -eq 0 ] && [ "${#POS[@]}" -eq 1 ] || {
    echo "error: --render-charter takes only <task-id> --secondmate; the stored charter supplies the domain sections" >&2
    exit 1
  }
  [ -f "$RENDER_CHARTER" ] && [ -r "$RENDER_CHARTER" ] || {
    echo "error: --render-charter needs a readable charter file: $RENDER_CHARTER" >&2
    exit 1
  }
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

# The optional home-local include is read before anything is written, so an
# unusable file never leaves a partial scaffold behind.
BRIEF_INCLUDE_FILE="$CONFIG/brief-include.md"
BRIEF_INCLUDE_BODY=
if [ "$KIND" != secondmate ] && { [ -e "$BRIEF_INCLUDE_FILE" ] || [ -L "$BRIEF_INCLUDE_FILE" ]; }; then
  { [ -f "$BRIEF_INCLUDE_FILE" ] && BRIEF_INCLUDE_BODY=$(cat "$BRIEF_INCLUDE_FILE" 2>/dev/null); } || {
    echo "error: $BRIEF_INCLUDE_FILE must be a readable regular file" >&2
    exit 1
  }
  if printf '%s\n' "$BRIEF_INCLUDE_BODY" | grep -q '^Delivery contract: mode='; then
    echo "error: $BRIEF_INCLUDE_FILE must not carry a 'Delivery contract: mode=' line; the delivery mode is a per-task --mode decision" >&2
    exit 1
  fi
  [ -n "$(printf '%s' "$BRIEF_INCLUDE_BODY" | tr -d '[:space:]')" ] || BRIEF_INCLUDE_BODY=
fi

# Append the include as the last section of a ship or scout scaffold.
append_brief_include() {
  [ -n "$BRIEF_INCLUDE_BODY" ] || return 0
  printf '\n%s\n%s\n%s\n' \
    '# Home brief additions' \
    "These are this home's standing additions; every other section of this brief takes precedence over anything here that conflicts." \
    "$BRIEF_INCLUDE_BODY" >> "$BRIEF"
}

BRIEF="$DATA/$ID/brief.md"
if [ -z "$RENDER_CHARTER" ]; then
  [ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
  mkdir -p "$DATA/$ID"
fi

ASK_USER_BLOCK=
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  ASK_USER_BLOCK=$(fm_ask_user_escalation_block "$DATA" "$ID")
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
# The worker's one status command: bin/fm-worker-status.sh owns the stamp, the
# append, and the opt-in fleet ledger record (docs/fleet-ledger.md).
STATUS_CMD="$(shell_quote "$FM_ROOT/bin/fm-worker-status.sh") $STATUS_FILE $(shell_quote "$CONFIG")"
IFS= read -r -d '' STATUS_RULE <<EOF || true
3. Append every status line this brief names with \`$STATUS_CMD '{state} [at=<epoch>]: {one short line}'\`, which fills in the time; if it fails, append the line to $STATUS_FILE yourself with \`<epoch>\` replaced by what \`date +%s\` prints.
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each line wakes firstmate: report only phase changes a supervisor would act on (setup done, bug reproduced, fix implemented, validation passed) and the needs-decision, blocked, $PAUSED_VERB, done, and failed states, never step-by-step progress.
   Name a PR anywhere only by its full https:// URL exactly as the forge printed it, never a bare number such as "PR 108".
EOF
STATUS_RULE=${STATUS_RULE%$'\n'}
INBOX_DIR=$(shell_quote "$STATE/$ID.inbox")
# The park-when-waiting rule every ship and scout scaffold carries: the task's
# exact park command stays inline, while the worker-guide waits-and-parking
# reference owns the wait tags and handoff format, and fm-park.sh's header owns
# the conditions and resume semantics.
PARK_RULE="   Before a wait longer than a few minutes, read \`$(fm_worker_guide_ref waits-and-parking)\` for the tags that keep monitoring quiet while a declared wait holds, and for parking:
   when the wait is on an external result that will take a while, park instead of idling with \`FM_HOME=$(shell_quote "$FM_HOME") $(shell_quote "$FM_ROOT/bin/fm-park.sh") $ID --handoff <file>\`."

# The receive-and-ack half of the steering-inbox contract, included in every
# scaffold kind. The record format, doorbell line, and re-ring ladder are
# owned by bin/fm-task-inbox-lib.sh. The doorbell carries the absolute inbox
# path and does not depend on a worker's tool shell inheriting FM_TASK_INBOX.
# The doorbell itself is self-describing, so this section is reinforcement
# for the natural-checkpoint habit, not the only carrier of the instruction.
# config/wait-no-turns (docs/configuration.md) adds the line that a waiting
# worker does not poll the inbox: checkpoint checks happen during active work,
# so waiting still spends no turns.
# A ship or scout launch states the inbox path once, in its worker role
# contract (fm_brief_worker_role); a charter has no role contract, so it names it.
if [ "$KIND" = secondmate ]; then
  INBOX_WHERE="in $INBOX_DIR"
else
  INBOX_WHERE="in your steering inbox, which your worker role contract names"
fi
IFS= read -r -d '' INBOX_SECTION <<EOF || true
# Firstmate instruction inbox
Firstmate steers you through message files $INBOX_WHERE.
When a terminal message says one is waiting, and at any natural checkpoint when you are unsure, act on each \`*.msg\` there in numeric order, then acknowledge it by moving it into that inbox's \`handled/\`; without the move firstmate rings again and eventually treats you as stuck.
EOF
if [ -e "$CONFIG/wait-no-turns" ]; then
  INBOX_SECTION+="Do not poll or list the inbox while waiting; a waiting instruction rings."$'\n'
fi
INBOX_SECTION=${INBOX_SECTION%$'\n'}

# One pointer, shared by the ship and scout scaffolds, to the owner of how a
# worker keeps evidence that lives in its disposable copy or temp folder.
EVIDENCE_LINE="If a report, note, or other record you leave under \`$DATA/$ID/\` cites a file inside your copy or your task temp folder, follow \`$FM_ROOT/.agents/skills/task-evidence/SKILL.md\` so cleanup preserves it instead of refusing."

# How a crewmate or scout waits. Every model turn resends the whole context, so
# a wait must cost no turns: a decision wait ends the turn, and an external
# wait sleeps in one bounded blocking shell command sized to the harness.
# Emitted only when config/wait-no-turns is present.
IFS= read -r -d '' WAIT_SECTION <<'EOF' || true
# Waiting
Every turn you take resends your whole context, so a wait must cost no turns.
After you append `needs-decision:` or `blocked:`, end your turn at once: do not check the inbox, the status file, or anything else, because the answer arrives as a terminal message that starts your next turn.
Wait on anything external - a pipeline gate, PR checks, a heavy-test slot - with ONE blocking shell command that returns when the state changes: `no-mistakes axi run` or `respond` with `--wait`, `gh pr checks <pr> --watch`, or `until <condition>; do sleep 30; done` for anything else.
Never spend turns on `sleep` followed by a status check, and never background a command in order to poll it.
In Claude Code that `until` loop in a single Bash call is the sanctioned foreground wait: when the harness refuses a sleep-then-check command and points you at backgrounding instead, reissue the wait as the loop rather than accepting the background.
Bound that command by what your harness lets one command run: in Pi pass the bash tool a `timeout` of at most 2700 seconds, because Pi sets none by default; in Claude Code pass the Bash tool its maximum `timeout` of 600000 ms, because its default is 2 minutes; in Codex keep waiting on a still-running command with empty `write_stdin` polls of up to 300000 ms; elsewhere pass your shell tool its largest timeout and assume at most 10 minutes.
Give any `--wait` a duration a little under that bound.
When the bound passes with nothing changed, run the same blocking command again, with no status check in between.
The one exception is `respond`: it sent its answer before it began waiting, so reattach with `no-mistakes axi run --wait` instead, and never send the same `respond` again, because it would answer whichever gate parks next without you reading it.
A wait your shell can watch this way needs no `paused:` line, except your own pipeline run, a long foreground command, or your own validation round, which you declare once just before its blocking hold: append `paused:` once just before its first blocking command, then stay in the command, and never append it again as you reissue that command.
EOF
WAIT_SECTION=${WAIT_SECTION%$'\n'}
WAIT_BLOCK=
if [ -e "$CONFIG/wait-no-turns" ]; then
  WAIT_BLOCK="$WAIT_SECTION"$'\n\n'
fi

if [ "$KIND" = secondmate ]; then
# A charter is the current template around three domain sections: Charter,
# Routing scope, and Project clones. --render-charter <stored> re-renders that
# template to stdout around the stored copy's domain sections, plus any section
# the template does not own, so a seeded copy can be refreshed to the current
# contract; everything else in the stored copy is template-owned text.
CHARTER_DOMAIN_HEADINGS='|Charter|Routing scope|Project clones|'
CHARTER_TEMPLATE_HEADINGS="${CHARTER_DOMAIN_HEADINGS}Operating model|The captain and the parent channel|Requests from the main firstmate|Firstmate instruction inbox|Escalation to main firstmate|Definition of done|"
stored_section() {  # <heading>: the section body, trailing blank lines trimmed
  awk -v heading="# $1" '
    $0 == heading { on=1; next }
    on && /^# / { exit }
    on { buf = buf $0 "\n"; if ($0 != "") { printf "%s", buf; buf = "" } }
  ' "$RENDER_CHARTER"
}
SECONDMATE_EXTRA=
if [ -n "$RENDER_CHARTER" ]; then
  SECONDMATE_CHARTER=$(stored_section Charter)
  SECONDMATE_SCOPE=$(stored_section "Routing scope")
  PROJECT_CLONES_BODY=$(stored_section "Project clones")
  [ -n "$(printf '%s' "$SECONDMATE_CHARTER" | tr -d '[:space:]')" ] && [ -n "$PROJECT_CLONES_BODY" ] || {
    echo "error: $RENDER_CHARTER has no filled Charter or Project clones section to render" >&2
    exit 1
  }
  case "$SECONDMATE_CHARTER" in *'{TASK}'*) echo "error: $RENDER_CHARTER still contains {TASK}" >&2; exit 1 ;; esac
  [ -n "$SECONDMATE_SCOPE" ] || SECONDMATE_SCOPE=$SECONDMATE_CHARTER
  case "$PROJECT_CLONES_BODY" in None.*) NO_PROJECTS=1 ;; esac
  SECONDMATE_EXTRA=$(awk -v known="$CHARTER_TEMPLATE_HEADINGS" '
    /^# / { keep = index(known, "|" substr($0, 3) "|") == 0 }
    keep { print }
  ' "$RENDER_CHARTER")
else
  SECONDMATE_PROJECTS=""
  idx=1
  while [ "$idx" -lt "${#POS[@]}" ]; do
    SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
    idx=$((idx + 1))
  done
  if [ "$NO_PROJECTS" -eq 1 ]; then
    [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
    PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that repo."
  else
    [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
    PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  fi
  SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
  SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
fi
if [ "$NO_PROJECTS" -eq 0 ]; then
  PROJECT_CLONES_NOTE="These are local clones for work you supervise, not an exclusive ownership claim."
  case "$PROJECT_CLONES_BODY" in *"$PROJECT_CLONES_NOTE"*) ;; *) PROJECT_CLONES_BODY+=$'\n'"$PROJECT_CLONES_NOTE" ;; esac
fi
[ -z "$SECONDMATE_EXTRA" ] || SECONDMATE_EXTRA=$'\n'"$SECONDMATE_EXTRA"$'\n'
SECONDMATE_STATUS_FILE=$(shell_quote "$STATE/$ID.status")
emit_charter() {
cat <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY
$SECONDMATE_EXTRA
# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and this home's \`data/\`, \`state/\`, \`config/\`, and \`projects/\` are yours to operate.
Act only on tasks the main firstmate routes to you.

# The captain and the parent channel
Nobody reads this chat: the captain and the main firstmate see only what is appended to $SECONDMATE_STATUS_FILE; in this home it IS the captain, and a sentence not appended there has not been sent.
Scripts publish your crew's routine outcomes there (\`docs/secondmate-parent-channel.md\`); you append only judgement: a marked-request answer, a recommendation or caveat on a delivered outcome, a blocker or failure of your own, and anything else you would say to the captain.

# Requests from the main firstmate
A request from the main firstmate carries a leading \`$FM_FROMFIRST_LABEL\` marker that a human cannot type, then a \`corr=<id>\` token: do the work, answer on the parent channel, never only in this chat, and include that exact token in your parent status reply (or in the status pointer to a detailed doc).
\`bin/fm-secondmate-report.sh <verb> <corr_id> <note>\` appends that correlated line for you - do not pass a status path; a plain \`echo\` with the same \`corr=<id>\` is equally valid.
When the marker carries \`expect=ack\`, reply with \`bin/fm-secondmate-report.sh --receipt <corr_id>\`; substantive replies and failures still use their ordinary report, never a receipt.
For a terse result, a status line is the whole answer.
For a detailed one, write a doc under this home's \`data/\` and append a status line that points to that doc.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Every marked request gets that line, including one that asks for a reply only if affected: answer it with \`note\` and \`not affected: {why}\` or \`noted\`.
If the answer is not ready when the turn that took the request up ends - you dispatched a worker, armed a watch, or wait on an approval - append one correlated \`working:\` line naming what you wait on, because the parent asks for a repost once a request turn ends with no correlated line; a dispatch or an armed watch is not an answer.
That correlated \`working:\` line settles the parent's guard, so nothing reminds you of the answer still owed: post it with the same \`corr=<id>\` when the wait ends.
Apart from that one turn-end line, never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
Before treating an investigation or visual review as complete, load \`captain-hold-lifecycle\` and pass its completion gate.
A message with NO marker is the captain typing directly into your pane: authoritative, answered conversationally, not on the status path. An inbox request follows the same marker rules.

$INBOX_SECTION

# Escalation to main firstmate
Report only true captain-relevant outcomes or a declared external wait, with \`bin/fm-secondmate-report.sh --state <state> [--key <slug>] [--wait <kind>:<arg>] <note>\`, which stamps and records it, or by hand, replacing \`<epoch>\` with what \`date +%s\` prints:
   \`echo "{state} [at=<epoch>]: {one short line}" >> $SECONDMATE_STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` only while your domain idles on a known external wait, naming when it clears with \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) or one \`[wait=<kind>:<arg>]\` tag; use \`blocked:\` when you need firstmate to act.
Report only material phase changes, a captain decision, a real blocker, a failure, work ready for review, or work you landed.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event, and when it ends without another reportable state, append \`resolved [key=<work-slug>] [at=<epoch>]: {why it is no longer active}\`.
Only a \`resolved\` line carrying an escalated decision's or blocker's exact key closes it, never a later \`done\` or \`working\`, even when the answer is what started that work; the main firstmate's answer normally writes it, and when a blocker or wait clears without one, append \`resolved [at=<epoch>]: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one).

# Definition of done
You are persistent: an empty queue is a healthy resting state, never a reason to exit.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
Then, with nothing assigned, go idle and wait silently for the main firstmate to route you a task; never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
A scheduled run that \`bin/fm-schedule.sh\` files in this home's backlog from an approved \`config/schedules.d\` file counts as captain-routed work, not self-started work.
If this charter cannot be carried out, append \`blocked [at=<epoch>]: {why}\` or \`failed [at=<epoch>]: {why}\` to the parent channel and stop.
EOF
}
if [ -n "$RENDER_CHARTER" ]; then
  if [ "$DROPPED_LINES" -eq 1 ]; then
    # Template-owned text is the preamble before the first heading plus every
    # template section other than the domain ones.
    emit_charter | awk -v domain="$CHARTER_DOMAIN_HEADINGS" -v known="$CHARTER_TEMPLATE_HEADINGS" '
      NR == FNR { have[$0] = 1; next }
      /^# / { name = "|" substr($0, 3) "|"; owned = index(known, name) > 0 && index(domain, name) == 0; started = 1; next }
      (owned || !started) && $0 !~ /^[[:space:]]*$/ && !($0 in have) { print }
    ' - "$RENDER_CHARTER"
  else
    emit_charter
  fi
  exit 0
fi
emit_charter > "$BRIEF"
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus an explicit `--session <name>` Herdr option on every call is the only viable local isolation.' \
'' \
'For tmux-based lab primaries, `bin/fm-lab-home.sh` owns the short private socket directory; do not place `TMUX_TMPDIR` under the lab home or worktree.' \
'Use `LAB_HOME_HELPER='"$(shell_quote "$FM_ROOT/bin/fm-lab-home.sh")"'`, then `LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")` and launch tmux with `TMUX_TMPDIR="$LAB_TMUX_DIR"`.' \
'Your single EXIT cleanup trap must kill only the server addressed through that `TMUX_TMPDIR`, call `"$LAB_HOME_HELPER" teardown "$FM_HOME"`, and call the Herdr teardown below; do not install a second trap that replaces either cleanup.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install the combined EXIT cleanup before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper supplies the required `--session "$HERDR_LAB_SESSION"` as a Herdr option, before any `--` delimiter; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

IFS= read -r -d '' TASK_SECTION <<'EOF' || true
# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}
EOF
TASK_SECTION=${TASK_SECTION%$'\n'}

# One shared string keeps the ship and scout infrastructure rule identical.
# Rule 2 governs file edits, so it does not prohibit pool administration.
# The secondmate charter deliberately omits this rule because a secondmate
# legitimately allocates and returns slots for crewmates in its own home.
IFS= read -r -d '' SHARED_INFRA_RULE <<'EOF' || true
7. Never administer infrastructure every lane shares, because running lanes depend on it:
   - the `no-mistakes` daemon: never stop, restart, or update it; only firstmate manages it.
   - the worktree pool and its repository: never create, remove, return, prune, move, or reassign any worktree or pool slot - not even your own or one that looks unused - whether by `treehouse`, `git worktree add|remove|move|prune`, or any other worktree provider, and never write into a sibling slot.
   If you need a second checkout, another slot, or the daemon touched, append `blocked [at=<epoch>]: {what you need}` and stop.
EOF
SHARED_INFRA_RULE=${SHARED_INFRA_RULE%$'\n'}
# Every ship and scout carries both rules unconditionally: a brief has no
# planner, evaluator, reviewer or tool-work kind, so a rule gated on one would
# depend on the dispatcher remembering to mark it, and the workers that need
# these rules never load the home's preferences or the skill index.
JUDGING_RULE="8. When you compare, rank, or recommend options - in a plan, an evaluation, a review verdict, or a decision request - judge them only on how well they work (safety included), future-proofing, and maintainability; development time, effort, size, or rollout cost is never a reason, a tie-breaker, or a factor you report."
TOOL_DESIGN_RULE="9. If this task builds or changes a tool, script, service, watcher, or automation, in this repo or any other, read \`$FM_ROOT/.agents/skills/tool-design/SKILL.md\` before designing it."
OBSTACLE_RULE="5. If you are stuck and need help, or hit the same obstacle twice, append \`blocked [at=<epoch>]: {why}\` and stop."
RESOLVE_RULE="   Only a \`resolved\` line with an opened decision's or blocker's exact key closes it, never a later \`done:\` or \`working:\`, even when the answer is what started that work; firstmate's reply normally writes it, and when a blocker or wait clears without one, append \`resolved [at=<epoch>]: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one)."

if [ -n "$BASE_BRANCH" ]; then
  SETUP_BASE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean copy of its base branch.
Base branch: $BASE_BRANCH"
else
  SETUP_BASE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch."
fi
if [ -n "$REVIEW_RANGE" ]; then
  SETUP_BASE="$SETUP_BASE
Review range: $REVIEW_RANGE"
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
$TASK_SECTION

$HERDR_SECTION

# Setup
$SETUP_BASE
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
   Search only inside this worktree: never grep or find over a firstmate home's \`data/\` or \`state/\`, \`/\`, or \`/mnt/c\`, and bound any wider search with \`-xdev\` and \`--exclude-dir\`.
$STATUS_RULE
$CREWMATE_PAUSE_INSTRUCTIONS$PARK_RULE
$OBSTACLE_RULE
6. If a decision belongs to a human (product choices, destructive actions), append \`needs-decision [at=<epoch>]: {options}\` and stop; firstmate replies with the decision.
$RESOLVE_RULE
$SHARED_INFRA_RULE
$JUDGING_RULE
$TOOL_DESIGN_RULE

$WAIT_BLOCK$INBOX_SECTION

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
$EVIDENCE_LINE
A visual deliverable is a static HTML file beside the report, named by path in it.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report.
When the report is complete, append \`done [at=<epoch>]: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report.
EOF
append_brief_include
echo "scaffolded: $BRIEF (scout; replace {TASK} and {FIRSTMATE_SPEC})"
exit 0
fi

# Ship task: shape Setup / Rule 1 by this task's explicit delivery mode, validated
# above, and render the Definition of done from its single owner, bin/fm-dod-lib.sh,
# which bin/fm-promote.sh renders too so a promoted scout receives the same contract.
# The block opens with the fixed "Delivery contract: mode=<mode>" line that
# bin/fm-spawn.sh checks against its own explicit --mode and the project's
# registered forge before launching.
# Only direct-push adds a setup step; the no-mistakes drive reference owns the
# pipeline's doctor/init step.
SETUP2=""
if [ "$MODE" = direct-push ]; then
  SETUP2="
2. Start from the latest origin default branch: run \`git fetch origin\`, then \`git rebase origin/<default-branch>\` (the Definition of done says how to name it)."
fi
RULE1=$(fm_ship_rule_one "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH") || exit 1
DOD=$(fm_dod_block "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH") || exit 1

cat > "$BRIEF" <<EOF
$TASK_SECTION

$HERDR_SECTION

# Setup
$SETUP_BASE

**Verify isolation before anything else.** \`pwd -P\` and \`git rev-parse --show-toplevel\` must both resolve to the disposable worktree you were launched in, not firstmate's primary checkout.
The path check is authoritative; git-dir checks do not prove it.
If either fails, do not branch or commit here: append \`blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree\` and stop.

1. First action: create your branch: \`git checkout -b $BRANCH_Q --\`$SETUP2

# Rules
$RULE1
2. Keep project edits inside this worktree; keep proof and scratch output outside it, under \`$DATA/$ID/\` or a temporary directory.
   Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
   Leave the worktree clean before reporting done.
   Search only inside this worktree: never grep or find over a firstmate home's \`data/\` or \`state/\`, \`/\`, or \`/mnt/c\`, and bound any wider search with \`-xdev\` and \`--exclude-dir\`.
$STATUS_RULE
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the turn after it; continue until a \`done:\` gate under Definition of done.
$CREWMATE_PAUSE_INSTRUCTIONS$PARK_RULE
$OBSTACLE_RULE
6. If a decision belongs above you (product choices, destructive actions), append \`needs-decision [at=<epoch>]: {options}\` and stop; firstmate replies with the decision.
$ASK_USER_BLOCK
$RESOLVE_RULE
$SHARED_INFRA_RULE
$JUDGING_RULE
$TOOL_DESIGN_RULE

$WAIT_BLOCK$INBOX_SECTION

# Project memory
A project's \`AGENTS.md\` or \`CLAUDE.md\` is loaded into every agent session in that project, so edit it only to correct information that is factually wrong - including information your own change made wrong - and never to add knowledge because it is missing.
A correction edits only the wrong text: do not run \`$FM_ROOT/bin/fm-ensure-agents-md.sh\`, create either file, or add sections, headings, or pointers alongside it.
$EVIDENCE_LINE

$DOD
EOF
append_brief_include
if [ "$FORGE" = none ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK} and {FIRSTMATE_SPEC})"
elif [ "$FORGE" = gerrit ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE forge=$FORGE shape=$SHAPE; replace {TASK} and {FIRSTMATE_SPEC})"
else
  echo "scaffolded: $BRIEF (ship, mode=$MODE forge=$FORGE; replace {TASK} and {FIRSTMATE_SPEC})"
fi
