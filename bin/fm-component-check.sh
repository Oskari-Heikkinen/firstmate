#!/usr/bin/env bash
# Component hook: tell an agent which component governs a file it reads or
# changes, with that component's goal, the first time it touches it.
#
# A component map (docs/component-map.md) names the skill that governs each
# path. Description-only skill triggering is model judgment, so a skill can go
# unloaded exactly when an agent starts a scrappy fix in its component. This
# hook makes the goal arrive deterministically: on the first touch of a mapped
# path in a session it returns that component's `## Goal and operating
# principle` section and the skill's path as context. It informs and never
# blocks. See docs/component-skills.md for the complete contract.
#
# It follows the bin/fm-subagent-pretool-check.sh pattern: this one script owns
# the hook behaviour, every harness feeds it, and it fails open. It resolves
# paths and reads goals only through bin/fm-component-map.sh (`touched` and
# `goal`); it never parses a map or a skill itself.
#
# Usage:
#   <hook JSON on stdin> | bin/fm-component-check.sh [--claude]
#   bin/fm-component-check.sh --tool <name> [--path <file>] [--cwd <dir>]
#                             [--session <id>] [--agent <id>] [--claude]
#
# Stdin mode reads Claude's hook input (hook_event_name, session_id, agent_id,
# cwd, tool_name, tool_input.file_path or tool_input.notebook_path, source) or
# Grok's (toolName, toolInput, sessionId). CLI mode is for adapters that already
# hold the fields. What it does depends on the input:
#   PATH   - the input names a file (file_path, notebook_path, path, or --path):
#            resolve it against the repository map of the file's git top level
#            and the home map $FM_HOME/config/component-map.json.
#   SWEEP  - a Bash tool with no file: run `git status --porcelain` in the
#            working directory's repository and resolve every changed path whose
#            status, size or modification time differs from this session's last
#            sweep (the first sweep counts every changed path).
#   RESET  - a SessionStart whose source is `compact`: forget which components
#            this session was told about, so their goals return after compaction.
# Every component is injected once per session; a subagent (agent_id) has its
# own context and so its own record.
#
# Output contract:
#   INJECT - exit 0; with --claude a hookSpecificOutput object carrying
#            additionalContext for the input's event, otherwise the plain text,
#            on stdout. The text stays under 10,000 characters.
#   SILENT - exit 0, no output: nothing mapped, already injected, a reset, or
#            no map anywhere.
#   UNUSABLE MAP - a map that fm-component-map.sh refuses is reported once per
#            session as context naming the map and its first problem.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin mode, or any
#            resolver failure: exit 0, never a deny.
#
# Environment: FM_HOME (default: this checkout) names the home whose map is
# read; FM_COMPONENT_STATE_DIR (default ${TMPDIR:-/tmp}/fm-component-check.<uid>)
# holds the per-session records.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
MAPTOOL=$SCRIPT_DIR/fm-component-map.sh
REPO_MAP=docs/component-map.json
# Claude Code caps additionalContext at 10,000 characters; keep a margin.
BUDGET=9500

usage() { sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

TOOL="" FILE="" CWD="" SESSION="" AGENT="" EVENT="" SOURCE=""
CLI=0 CLAUDE_MODE=0
need() { [ "$2" -gt 1 ] || { echo "error: $1 requires a value" >&2; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool) need "$1" "$#"; TOOL=$2; CLI=1; shift 2 ;;
    --path) need "$1" "$#"; FILE=$2; shift 2 ;;
    --cwd) need "$1" "$#"; CWD=$2; shift 2 ;;
    --session) need "$1" "$#"; SESSION=$2; shift 2 ;;
    --agent) need "$1" "$#"; AGENT=$2; shift 2 ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$CLI" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # One jq call, one base64 line per field, so a newline inside a value
  # cannot shift the fields after it.
  FIELDS=$(printf '%s' "$PAYLOAD" | jq -r '
    (.tool_input // .toolInput // {}) as $in
    | [ (.hook_event_name // .hookEventName // ""),
        (.tool_name // .toolName // ""),
        (if ($in|type) == "object" then ($in.file_path // $in.notebook_path // $in.filePath // $in.path // "") else "" end),
        (.cwd // ""),
        (.session_id // .sessionId // ""),
        (.agent_id // .agentId // ""),
        (.source // "") ]
    | map(tostring | @base64) | .[]' 2>/dev/null) || exit 0
  dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }
  i=0
  while IFS= read -r field; do
    value=$(dec "$field")
    case $i in
      0) EVENT=$value ;; 1) TOOL=$value ;; 2) FILE=$value ;; 3) CWD=$value ;;
      4) SESSION=$value ;; 5) AGENT=$value ;; 6) SOURCE=$value ;;
    esac
    i=$((i + 1))
  done <<EOF
$FIELDS
EOF
fi

# --claude output is built with jq; without it nothing could be delivered, so
# record nothing either.
[ "$CLAUDE_MODE" -eq 0 ] || command -v jq >/dev/null 2>&1 || exit 0

FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
FM_HOME=${FM_HOME:-$FM_ROOT}
HOME_MAP=$FM_HOME/config/component-map.json
[ -n "$CWD" ] || CWD=$PWD

# --- per-session records ------------------------------------------------------
# A session id is the harness's; without one, the harness process (the hook's
# parent) stands in, so dedup still holds for that process's lifetime.
safe() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-120; }
[ -n "$SESSION" ] || SESSION="ppid-$PPID"
STATE_ROOT=${FM_COMPONENT_STATE_DIR:-${TMPDIR:-/tmp}/fm-component-check.$(id -u)}
SESSION_DIR=$STATE_ROOT/$(safe "$SESSION")
if [ -n "$AGENT" ]; then
  REC_DIR=$SESSION_DIR/agent-$(safe "$AGENT")
else
  REC_DIR=$SESSION_DIR/main
fi
INJECTED=$REC_DIR/injected
REPORTED=$REC_DIR/reported
SWEPT=$REC_DIR/swept

if [ "$EVENT" = SessionStart ]; then
  # Compaction drops the injected goals from the context, so they must come
  # back on the next touch; any other start keeps the record it has.
  [ "$SOURCE" = compact ] && rm -rf -- "$SESSION_DIR/main" 2>/dev/null
  exit 0
fi

(umask 077 && mkdir -p -- "$REC_DIR") 2>/dev/null || true
# Serialise against parallel tool calls in the same context, so two hooks do
# not both inject one component. Without flock the worst case is a duplicate.
if command -v flock >/dev/null 2>&1 && exec 9>>"$REC_DIR/lock" 2>/dev/null; then
  flock -w 5 9 2>/dev/null || true
fi

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "${CWD%/}" "$1" ;;
  esac
}

# Git top level of a path that may not exist yet (a Write creates it).
toplevel_of() {
  local dir=$1
  while [ ! -d "$dir" ]; do
    [ "$dir" != / ] && [ -n "$dir" ] || return 1
    dir=$(dirname -- "$dir")
  done
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

# --- collect touched paths ----------------------------------------------------
TOP=""
PATHS=()
if [ -n "$FILE" ]; then
  FILE=$(abs_path "$FILE")
  PATHS=("$FILE")
  TOP=$(toplevel_of "$(dirname -- "$FILE")") || TOP=""
else
  lc_tool=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
  [ "$lc_tool" = bash ] || exit 0
  TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
  [ -f "$TOP/$REPO_MAP" ] || [ -f "$HOME_MAP" ] || exit 0
  # stat flavour: GNU first, BSD second.
  if stat -c '%Y %s' -- "$TOP" >/dev/null 2>&1; then
    fingerprint() { stat -c '%Y %s' -- "$1" 2>/dev/null || printf 'gone'; }
  else
    fingerprint() { stat -f '%m %z' -- "$1" 2>/dev/null || printf 'gone'; }
  fi
  NEW_SWEPT=""
  skip_next=0
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    xy=${entry:0:2}
    rel=${entry:3}
    # A rename or copy entry is followed by its source path.
    case "$xy" in R*|C*) skip_next=1 ;; esac
    line="$rel	$xy $(fingerprint "$TOP/$rel")"
    NEW_SWEPT+="$line"$'\n'
    if ! grep -qxF -- "$line" "$SWEPT" 2>/dev/null; then
      PATHS+=("$TOP/$rel")
    fi
  done < <(git -C "$TOP" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
  printf '%s' "$NEW_SWEPT" > "$SWEPT.tmp" 2>/dev/null && mv -f -- "$SWEPT.tmp" "$SWEPT" 2>/dev/null
  [ "${#PATHS[@]}" -gt 0 ] || exit 0
fi

# --- resolve through the map tool ---------------------------------------------
# Each source is a repository top level or the home map; touched prints
# "match<TAB>path<TAB>id<TAB>skill<TAB>provisional" lines.
SOURCES=()
[ -n "$TOP" ] && [ -f "$TOP/$REPO_MAP" ] && SOURCES+=("$TOP")
[ -f "$HOME_MAP" ] && SOURCES+=("$HOME_MAP")
[ "${#SOURCES[@]}" -gt 0 ] || exit 0

TEXT=""
add_text() {
  local next=$1
  [ -z "$TEXT" ] || next=$'\n\n'"$next"
  [ $((${#TEXT} + ${#next})) -le "$BUDGET" ] || return 1
  TEXT+=$next
}
map_file_of() { if [ -d "$1" ]; then printf '%s/%s' "$1" "$REPO_MAP"; else printf '%s' "$1"; fi; }
shown_path() {
  if [ -n "$TOP" ] && [ "${1#"$TOP"/}" != "$1" ]; then
    printf '%s' "${1#"$TOP"/}"
  else
    printf '%s' "$1"
  fi
}

PENDING_IDS=()
PENDING_KEYS=()
PENDING_SKILLS=()
PENDING_PROV=()
PENDING_FILES=()
PENDING_SOURCES=()
for src in "${SOURCES[@]}"; do
  map_file=$(map_file_of "$src")
  out="" err="" rc=0
  # Batches keep a large sweep inside the argument limit.
  for ((start = 0; start < ${#PATHS[@]}; start += 200)); do
    errfile=$(mktemp 2>/dev/null) || exit 0
    chunk=$("$MAPTOOL" touched "$src" "${PATHS[@]:start:200}" 2>"$errfile") || rc=$?
    err=$(head -n 1 "$errfile" 2>/dev/null)
    rm -f -- "$errfile"
    [ "$rc" -eq 0 ] || break
    out+="$chunk"$'\n'
  done
  if [ "$rc" -eq 3 ]; then
    key=$map_file
    if ! grep -qxF -- "$key" "$REPORTED" 2>/dev/null; then
      problem=${err#"$map_file": }
      add_text "The component map $map_file is unusable, so no component goal from it is available here (first problem: ${problem:-unknown}); \`bin/fm-component-map.sh check\` lists every problem." \
        && printf '%s\n' "$key" >> "$REPORTED"
    fi
    continue
  fi
  [ "$rc" -eq 0 ] || continue
  while IFS=$'\t' read -r kind path id skill prov; do
    [ "$kind" = match ] || continue
    key="$map_file	$id"
    grep -qxF -- "$key" "$INJECTED" 2>/dev/null && continue
    dup=0
    for ((n = 0; n < ${#PENDING_KEYS[@]}; n++)); do
      if [ "${PENDING_KEYS[n]}" = "$key" ]; then
        PENDING_FILES[n]+=", $(shown_path "$path")"
        dup=1
      fi
    done
    [ "$dup" -eq 0 ] || continue
    PENDING_KEYS+=("$key")
    PENDING_IDS+=("$id")
    PENDING_SKILLS+=("$skill")
    PENDING_PROV+=("$prov")
    PENDING_FILES+=("$(shown_path "$path")")
    PENDING_SOURCES+=("$src")
  done <<EOF
$out
EOF
done

for ((n = 0; n < ${#PENDING_KEYS[@]}; n++)); do
  id=${PENDING_IDS[$n]}
  skill=${PENDING_SKILLS[$n]}
  files=${PENDING_FILES[$n]}
  note=""
  [ "${PENDING_PROV[$n]}" != 1 ] || note=" (provisional: its code has not fully landed)"
  head="$files belongs to component $id$note; its full rules, refuse list and review checklist are in $skill."
  if goal=$("$MAPTOOL" goal "${PENDING_SOURCES[$n]}" "$id" 2>/dev/null) && [ -n "$goal" ]; then
    block="$head"$'\n'"Goal and operating principle of $id:"$'\n'"$goal"
  else
    block="$head Its goal section could not be read; \`bin/fm-component-map.sh check\` says why."
  fi
  # A goal that does not fit under the cap leaves only its pointer line, and
  # the component stays unrecorded so its goal arrives on its next touch.
  if add_text "$block"; then
    printf '%s\n' "${PENDING_KEYS[$n]}" >> "$INJECTED"
  else
    add_text "$head Its goal did not fit in this message and comes with the next touch of its files." || break
  fi
done

[ -n "$TEXT" ] || exit 0
if [ "$CLAUDE_MODE" -eq 1 ]; then
  if [ -z "$EVENT" ]; then
    if [ -n "$FILE" ]; then EVENT=PreToolUse; else EVENT=PostToolUse; fi
  fi
  jq -cn --arg ev "$EVENT" --arg ctx "$TEXT" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
else
  printf '%s\n' "$TEXT"
fi
exit 0
