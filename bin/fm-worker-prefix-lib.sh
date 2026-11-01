#!/usr/bin/env bash
# fm-worker-prefix-lib.sh - the worker prompt-prefix cut, sourced by
# bin/fm-spawn.sh: the one parser of .agents/worker-skills.list and the
# builders of the Claude --settings members and Pi skill arguments it drives.
#
# docs/configuration.md "Worker prompt prefix" owns the operator contract and
# why each member is there; .agents/worker-skills.list's header owns which
# skill a worker keeps. Secondmate and primary launches never call this file.

# The Claude tools a worker never uses: the operator answers no worker
# question, nothing schedules a worker's next turn, review findings travel in
# the worker's report, and a worker messages no other session.
FM_WORKER_PREFIX_DENY_TOOLS='AskUserQuestion ScheduleWakeup ReportFindings ListAgents'

# fm_worker_skills_read <list-file>: print "<class> <name>" per entry. Non-zero
# with the reason on stderr when the file is unreadable or empty, or an entry
# has an unknown class, a malformed name, or repeats a name.
fm_worker_skills_read() {
  local file=$1 line class name rest seen=' ' out='' n=0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: the worker skill list $file must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    read -r class name rest <<<"$line"
    case "$class" in
    keep | name-only) ;;
    *)
      echo "error: $file line $n has class '$class'; expected keep or name-only" >&2
      return 1
      ;;
    esac
    if [ -z "$name" ] || [ -n "$rest" ] || [ -n "${name//[A-Za-z0-9._:-]/}" ]; then
      echo "error: $file line $n is malformed; expected '<keep|name-only> <skill-name>' with a name of letters, digits, _ . : and -" >&2
      return 1
    fi
    case "$seen" in
    *" $name "*)
      echo "error: $file line $n names $name a second time" >&2
      return 1
      ;;
    esac
    seen+="$name "
    out+="$class $name"$'\n'
  done <"$file" || {
    echo "error: cannot read the worker skill list $file" >&2
    return 1
  }
  if [ -z "$out" ]; then
    echo "error: the worker skill list $file lists no skill" >&2
    return 1
  fi
  printf '%s' "$out"
}

# fm_worker_skills_keep <entries>: the kept names from fm_worker_skills_read
# output, one per line.
fm_worker_skills_keep() {
  printf '%s' "$1" | awk '$1 == "keep" { print $2 }'
}

# _fm_worker_skill_dirs <root>...: the name of every skill directory (one
# holding SKILL.md) directly under each existing root, one per line.
_fm_worker_skill_dirs() {
  local root dir
  for root in "$@"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for dir in "$root"/*/; do
      [ -f "${dir}SKILL.md" ] || continue
      dir=${dir%/}
      dir=${dir##*/}
      # A name outside the list's alphabet cannot be written into the JSON
      # safely, so that skill keeps its full listing.
      [ -z "${dir//[A-Za-z0-9._:-]/}" ] || continue
      printf '%s\n' "$dir"
    done
  done
}

# _fm_worker_synced_skills <claude-config-dir>: every synced skill's listed
# name, anthropic-skills:<name>. An unreadable manifest is reported on stderr
# and skipped, so its skills keep their full listing rather than refusing the
# launch.
_fm_worker_synced_skills() {
  local manifest names
  for manifest in "$1"/skills/synced/*/manifest.json; do
    [ -f "$manifest" ] || continue
    if ! names=$(jq -r '.skills[]?.name | strings' "$manifest" 2>/dev/null); then
      echo "warning: cannot read the synced skill manifest $manifest, so this worker still lists its skills in full" >&2
      continue
    fi
    printf '%s\n' "$names" | awk '/^[A-Za-z0-9._:-]+$/ { print "anthropic-skills:" $0 }'
  done
}

# fm_worker_prefix_claude_setting <entries> <claude-config-dir> <skill-root>...:
# print the members a Claude worker's inline --settings object gains, each with
# a leading comma. skillOverrides names every skill the list marks name-only
# plus every skill found under the roots, the Claude config's skills/ and its
# synced manifests that the list does not keep.
fm_worker_prefix_claude_setting() {
  local entries=$1 cfg=$2 keep names deny='' tool overrides
  shift 2
  keep=$(fm_worker_skills_keep "$entries")
  names=$({
    printf '%s' "$entries" | awk '$1 == "name-only" { print $2 }'
    _fm_worker_skill_dirs "$@" "$cfg/skills"
    _fm_worker_synced_skills "$cfg"
  } | LC_ALL=C sort -u)
  for tool in $FM_WORKER_PREFIX_DENY_TOOLS; do
    deny+="${deny:+,}\"$tool\""
  done
  overrides=$(printf '%s\n' "$names" | FM_KEEP=$keep awk '
    BEGIN { n = split(ENVIRON["FM_KEEP"], k, "\n"); for (i = 1; i <= n; i++) kept[k[i]] = 1 }
    NF && !($0 in kept) { printf "%s\"%s\":\"name-only\"", sep, $0; sep = "," }')
  printf ',"disableArtifact":true,"disableClaudeAiConnectors":true,"disableWorkflows":true,"permissions":{"deny":[%s]},"skillOverrides":{%s}' "$deny" "$overrides"
}

# fm_worker_prefix_pi_skill_dirs <entries> <keep-root>... -- <whole-root>...:
# print the directories a Pi worker launched with --no-skills loads through
# --skill, one per line: each kept skill from the first keep-root holding it,
# then every whole-root that exists (a project's own skill directories, which
# the list does not classify).
fm_worker_prefix_pi_skill_dirs() {
  local entries=$1 keep name root
  local -a keep_roots=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    keep_roots+=("$1")
    shift
  done
  [ "$#" -eq 0 ] || shift
  keep=$(fm_worker_skills_keep "$entries")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    for root in ${keep_roots[@]+"${keep_roots[@]}"}; do
      [ -n "$root" ] && [ -f "$root/$name/SKILL.md" ] || continue
      printf '%s\n' "$root/$name"
      break
    done
  done <<<"$keep"
  for root in "$@"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    printf '%s\n' "$root"
  done
}

_fm_worker_prefix_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# fm_worker_prefix_pi_supports_skill_flags <pi-executable>: zero when its
# --help advertises both --no-skills and --skill, the flags the Pi cut needs.
fm_worker_prefix_pi_supports_skill_flags() {
  local help
  help=$("$1" --help 2>&1) || return 1
  printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--no-skills([^[:alnum:]_-]|$)' &&
    printf '%s\n' "$help" | grep -Eq -- '(^|[[:space:]])--skill([[:space:]=]|$)'
}

# fm_worker_prefix_pi_skill_args <entries> <keep-root>... -- <whole-root>...:
# print ` --no-skills` and a quoted ` --skill '<dir>'` for each directory
# fm_worker_prefix_pi_skill_dirs names, ready to substitute into a launch.
fm_worker_prefix_pi_skill_args() {
  local dirs dir out=' --no-skills'
  dirs=$(fm_worker_prefix_pi_skill_dirs "$@")
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    out+=" --skill $(_fm_worker_prefix_quote "$dir")"
  done <<<"$dirs"
  printf '%s' "$out"
}

# fm_worker_prefix_stop_command <fm-root> <fm-home> <state> <config> <task-id> <project>:
# print the Stop hook shell command that runs bin/fm-worker-prefix-check.sh
# until it writes <state>/<task-id>.prefix-checked; after that a turn costs
# one file test.
fm_worker_prefix_stop_command() {
  printf '[ -e %s ] || %s %s %s %s %s %s >/dev/null 2>&1 || true' \
    "$(_fm_worker_prefix_quote "$3/$5.prefix-checked")" "$(_fm_worker_prefix_quote "$1/bin/fm-worker-prefix-check.sh")" \
    "$(_fm_worker_prefix_quote "$2")" "$(_fm_worker_prefix_quote "$3")" "$(_fm_worker_prefix_quote "$4")" \
    "$(_fm_worker_prefix_quote "$5")" "$(_fm_worker_prefix_quote "$6")"
}
