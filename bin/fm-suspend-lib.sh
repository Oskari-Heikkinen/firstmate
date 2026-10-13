#!/usr/bin/env bash
# fm-suspend-lib.sh - nonterminal copy custody for ordinary parked work.
# Called by park, control and spawn; never call terminal cleanup to suspend.
# config/park-release=on enables release in this home; absent/off retains copies.
# Only clean, exclusively leased Treehouse copies on verified tmux/Herdr
# endpoints with reproducible canonical launch adapters qualify. Unknown ignored
# files, submodules, local condition/receipt
# dependencies, queue sources, typed routes and active jobs retain their copies.
# The bounded first version accepts file:/pr-merged:/inbox: waits, not arbitrary
# cmd: dependencies. park owns immediate open-ended/inbox qualification and the
# 86400-second continuous-age policy. Timer expiry never authorizes pickup.
# A private data/<id>/suspension.json (fm-suspension.v1) binds the home, task,
# token, stopped generation, logical launch identity, branch, exact HEAD, common
# repository, bundle and its digest. old_record is historical evidence only.
# copy_state=release-prepared reserves the old acquisition pending exact return;
# released has no active endpoint/copy/lease fields; restore-prepared claims ONE
# fresh allocation attempt. Any interrupted preparation requires reconciliation,
# never blind replay, historical-path inspection, or a second allocation.
# Successful spawn republishes copy_state=retained with its fresh incarnation.
# A kept branch plus a self-contained verified bundle is the saved-work proof;
# no automatic commit, stash, publication, rebase, branch deletion or Done occurs.
# Lock order: supervision lease, control, metadata, shared project allocation.
# Release takes these locks only after the agent's verified exit. Spawn takes
# the same order, durably claims restore-prepared before native get, and records
# the exact new lease before restoring. Ordinary strict endpoint validation stays
# authoritative for retained tasks; this library validates only saved logical work.

FM_SUSPEND_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_suspend_field() { # <meta> <key>; reject duplicate or malformed fields
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  awk -v k="$2=" 'index($0,k)==1 {n++; v=substr($0,length(k)+1)}
    END {if(n>1 || v ~ /[\r\t]/) exit 1; print v}' "$1"
}

fm_suspend_manifest() { printf '%s/%s/suspension.json\n' "$2" "$1"; }

# Shared name binding for park registration and terminal source retirement.
fm_suspend_release_source_name() { # <home> <id> <park-token>
  local hash
  hash=$(printf '%s\t%s\t%s\n' "$1" "$2" "$3" | fm_pr_sha256 /dev/stdin) || return 1
  printf 'copy-release-%s\n' "${hash:0:40}"
}

fm_suspend_enabled() { # <config>
  [ -f "$1/park-release" ] && [ ! -L "$1/park-release" ] &&
    awk 'NR==1 {sub(/\r$/, ""); if($0!="on") exit 1; next}
      {exit 1} END {if(NR!=1) exit 1}' "$1/park-release"
}

fm_suspend_qualified() { # <meta> <now-epoch>; continuous age, not deadline
  local meta=$1 now=$2 started cond
  [ "$(fm_suspend_field "$meta" park_relocation_safe)" = 1 ] || return 1
  started=$(fm_suspend_field "$meta" wait_started_at) || return 1
  case "$started" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#started}" -le 10 ] && [ "$now" -ge "$started" ] || return 1
  cond=$(fm_suspend_field "$meta" park_when) || return 1
  case "$cond" in inbox:*) return 0 ;; esac
  [ "$(fm_suspend_field "$meta" park_open_ended)" = 1 ] || [ "$((now - started))" -ge 86400 ]
}

# Atomic field replacement under the caller's metadata lock, including empty
# values. Preserve the pr=/pr_head= tail and all unrelated obligations.
fm_suspend_record() { # <meta> <key=value>...
  local meta=$1 tmp kv keys=' ' line placed=0
  shift
  for kv in "$@"; do keys="$keys${kv%%=*} "; done
  tmp=$(mktemp "${meta%/*}/.suspend-meta.XXXXXX") || return 1
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$keys" in *" ${line%%=*} "*) continue ;; esac
      if [ "${line%%=*}" = pr ] && [ "$placed" = 0 ]; then
        printf '%s\n' "$@"; placed=1
      fi
      printf '%s\n' "$line"
    done < "$meta"
    [ "$placed" = 1 ] || printf '%s\n' "$@"
  } > "$tmp"
  if ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$meta"; then rm -f "$tmp"; return 1; fi
}

fm_suspend_launch_supported() { # <meta>; raw basenames cannot be reproduced
  local harness
  # shellcheck source=bin/fm-control-lib.sh
  . "$FM_SUSPEND_LIB_DIR/fm-control-lib.sh"
  harness=$(fm_suspend_field "$1" harness) || return 1
  [ "$(fm_control_harness_family "$harness")" = "$harness" ] &&
    fm_control_harness_supports_kind "$harness" "$(fm_suspend_field "$1" kind)"
}

# Validate a positive saved-task shape without ever reading old_record paths.
# Outputs FM_SUSPEND_HEAD/BRANCH/PROJECT/BUNDLE/TOKEN/BACKEND/SESSION.
# shellcheck disable=SC2034 # Outputs consumed by control/spawn/park.
fm_suspend_validate() { # <meta> <id> <home> <data>
  local meta=$1 id=$2 home=$3 data=$4 manifest key value common branch head digest state
  manifest=$(fm_suspend_manifest "$id" "$data")
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  state=$(fm_suspend_field "$meta" copy_state) || return 1
  case "$state" in released|release-prepared|restore-prepared) ;; *) return 1 ;; esac
  jq -e --arg id "$id" --arg home "$home" '
    .schema=="fm-suspension.v1" and .task==$id and .home==$home
    and (.token|type)=="string" and (.token|test("^[A-Za-z0-9._-]+$"))
    and (.head|test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
    and (.branch|type)=="string" and (.project|type)=="string"
    and (.bundle|type)=="string" and (.bundle_hash|test("^[0-9a-f]+$"))
    and (.identity|type)=="object" and (.old_record|type)=="object"
    and (.identity.kind=="ship" or .identity.kind=="scout")
    and (.identity.backend=="tmux" or .identity.backend=="herdr")
  ' "$manifest" >/dev/null || return 1
  FM_SUSPEND_TOKEN=$(jq -r .token "$manifest") || return 1
  [ "$(fm_suspend_field "$meta" suspend_token)" = "$FM_SUSPEND_TOKEN" ] || return 1
  for key in project kind mode yolo branch harness model effort account account_provider claude_config_dir backend spawn_gen base_branch; do
    value=$(fm_suspend_field "$meta" "$key") || return 1
    [ "$key" != backend ] || value=${value:-tmux}
    [ "$value" = "$(jq -r --arg k "$key" '.identity[$k] // ""' "$manifest")" ] || return 1
  done
  FM_SUSPEND_PROJECT=$(jq -r .project "$manifest") || return 1
  FM_SUSPEND_HEAD=$(jq -r .head "$manifest") || return 1
  FM_SUSPEND_BRANCH=$(jq -r .branch "$manifest") || return 1
  FM_SUSPEND_BUNDLE=$(jq -r .bundle "$manifest") || return 1
  FM_SUSPEND_BACKEND=$(jq -r .identity.backend "$manifest") || return 1
  fm_suspend_launch_supported "$meta" || return 1
  FM_SUSPEND_SESSION=$(jq -r '.old_record.herdr_session // ""' "$manifest") || return 1
  [ "$FM_SUSPEND_BUNDLE" = "$data/$id/suspension.bundle" ] || return 1
  [ -f "$FM_SUSPEND_BUNDLE" ] && [ ! -L "$FM_SUSPEND_BUNDLE" ] || return 1
  digest=$(git hash-object -- "$FM_SUSPEND_BUNDLE") || return 1
  [ "$digest" = "$(jq -r .bundle_hash "$manifest")" ] || return 1
  common=$(git -C "$FM_SUSPEND_PROJECT" rev-parse --path-format=absolute --git-common-dir) || return 1
  [ "$common" = "$(jq -r .common "$manifest")" ] || return 1
  git check-ref-format "refs/heads/$FM_SUSPEND_BRANCH" >/dev/null || return 1
  head=$(git -C "$FM_SUSPEND_PROJECT" rev-parse --verify "refs/heads/$FM_SUSPEND_BRANCH") || return 1
  [ "$head" = "$FM_SUSPEND_HEAD" ] || return 1
  branch=$(git -C "$FM_SUSPEND_PROJECT" bundle list-heads "$FM_SUSPEND_BUNDLE" "refs/heads/$FM_SUSPEND_BRANCH") || return 1
  [ "$branch" = "$FM_SUSPEND_HEAD refs/heads/$FM_SUSPEND_BRANCH" ] || return 1
  git -C "$FM_SUSPEND_PROJECT" bundle verify "$FM_SUSPEND_BUNDLE" >/dev/null 2>&1 || return 1
  if [ "$state" = released ]; then
    for key in window worktree treehouse_lease_holder treehouse_lease_id herdr_pane_id herdr_tab_id herdr_workspace_id; do
      [ -z "$(fm_suspend_field "$meta" "$key")" ] || return 1
    done
  fi
}

# Any generation-bound route touching this task retains its copy. Routes live
# in registered local homes; failed inventory/parse is uncertainty, not absence.
fm_suspend_routes_clear() { # <state> <meta> <id> <home>
  local state=$1 meta=$2 id=$3 home=$4 dir route
  fm_treehouse_collect_states "$state" || return 1
  for dir in "${TREEHOUSE_OWNER_STATES[@]}"; do
    for route in "$dir/task-inbox-routes/"*.json; do
      [ -e "$route" ] || [ -L "$route" ] || continue
      [ -f "$route" ] && [ ! -L "$route" ] || return 1
      jq -e --arg id "$id" --arg gen "$(fm_suspend_field "$meta" spawn_gen)" '
        .schema=="fm-task-milestone-route.v1" and
        ([.producer,.consumer] | all(.task!=$id or .generation!=$gen))
      ' "$route" >/dev/null || return 1
    done
  done
  [ -n "$home" ]
}

# Relocation qualification is deliberately conservative: arbitrary cmd bodies
# cannot be proven independent. Handoff/condition paths into copy/temp refuse,
# including clean tracked scripts (recoverable evidence is not a runnable wait).
fm_suspend_dependencies_clear() { # <meta> <handoff> <copy> <tmp>
  local meta=$1 handoff=$2 wt=$3 tmp=$4 cond path
  cond=$(fm_suspend_field "$meta" park_when) || return 1
  case "$cond" in file:/*|pr-merged:*|inbox:*) ;; *) return 1 ;; esac
  [ -f "$handoff" ] && [ ! -L "$handoff" ] || return 1
  path=$handoff
  case "$cond" in file:*) path="${cond#file:}" ;; esac
  # A missing result can have an existing parent symlink into this copy/temp.
  # Canonicalize even nonexistent suffixes; string attestation is not a bypass.
  python3 - "$path" "$handoff" "$wt" "$tmp" <<'PY' || return 1
import os, sys
paths = [os.path.realpath(p) for p in sys.argv[1:3]]
roots = [os.path.realpath(p) for p in sys.argv[3:] if p]
if any(os.path.commonpath([p, r]) == r for p in paths for r in roots):
    raise SystemExit(1)
PY
  case "$cond" in *"$wt"*) return 1 ;; esac
  ! grep -F -- "$wt" "$handoff" >/dev/null || return 1
  if [ -n "$tmp" ]; then
    case "$cond" in *"$tmp"*) return 1 ;; esac
    ! grep -F -- "$tmp" "$handoff" >/dev/null || return 1
  fi
  [ -z "$(fm_suspend_field "$meta" park_source)" ] || return 1
  if [ -n "$tmp" ] && [ -e "$tmp" ]; then
    [ -d "$tmp" ] && [ ! -L "$tmp" ] || return 1
    # No temporary inputs are silently classified as caches. Empty directories
    # (including the spawn-created gotmp/) are harmless; anything else retains.
    [ -z "$(find "$tmp" -xdev ! -type d -print)" ] || return 1
  fi
}

# Never kill jobs to qualify. Before endpoint close, native process inventory
# must consist solely of the proven idle pane shell/plain-get chain. After
# close, the same inventory must be empty. Unknown platform evidence refuses.
fm_suspend_quiet_copy() { # <project> <copy> <meta> <allow-idle 0|1>
  local project=$1 wt=$2 meta=$3 allow=$4 root status pids pid table
  root=$(fm_treehouse_native_root "$wt") || return 1
  status=$(cd "$project" && treehouse --root "$root" status --json) || return 1
  pids=$(printf '%s\n' "$status" | jq -er --arg wt "$wt" '
    [.[] | select(.path==$wt)] | select(length==1) | .[0].processes |
    select(type=="array") | if all(.[]; (.pid|type)=="number" and .pid>0)
    then map(.pid|tostring)|join("\n") else error("unknown processes") end') || return 1
  [ -n "$pids" ] || return 0
  [ "$allow" = 1 ] || return 1
  table=$(ps -e -o pid= -o ppid=) || return 1
  while IFS= read -r pid; do
    # Unlike adoption, active task-owned children are NOT release-safe.
    fm_treehouse_idle_shell "$pid" "$(fm_suspend_field "$meta" herdr_pane_id)" "$table" || return 1
  done <<< "$pids"
}

fm_suspend_clean_copy() { # <copy>; reject hidden index changes as well
  local wt=$1 status flags
  status=$(git -C "$wt" status --porcelain --untracked-files=all --ignored) || return 1
  [ -z "$status" ] || return 1
  flags=$(git -C "$wt" ls-files -v) || return 1
  ! printf '%s\n' "$flags" | grep -E '^[a-zS] ' >/dev/null || return 1
  [ ! -f "$wt/.gitmodules" ] || return 1
  git -C "$wt" diff --quiet && git -C "$wt" diff --cached --quiet
}

# Save only after verified stop, under custody locks. The bundle contains all
# objects (no prerequisites), and a private temporary bare repo proves import.
fm_suspend_save() { # <meta> <id> <home> <data> <copy>
  local meta=$1 id=$2 home=$3 data=$4 wt=$5 dir head branch common token tmp identity old digest key value
  fm_suspend_launch_supported "$meta" && fm_suspend_clean_copy "$wt" || return 1
  dir="$data/$id"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  head=$(git -C "$wt" rev-parse --verify HEAD) || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || return 1
  [ "$(git -C "$wt" rev-parse "refs/heads/$branch")" = "$head" ] || return 1
  case "$(fm_suspend_field "$meta" kind)" in
    ship) [ "$branch" = "$(fm_suspend_field "$meta" branch)" ] || return 1 ;;
    scout) ;;
    *) return 1 ;;
  esac
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir) || return 1
  [ "$common" = "$(git -C "$(fm_suspend_field "$meta" project)" rev-parse --path-format=absolute --git-common-dir)" ] || return 1
  token="suspend.$(date +%s).${BASHPID:-$$}.$RANDOM"
  tmp=$(mktemp -d "$dir/.suspend-save.XXXXXX") || return 1
  chmod 0700 "$tmp" || return 1
  if ! git -C "$wt" bundle create "$tmp/suspension.bundle" "refs/heads/$branch" ||
     ! git init --bare -q "$tmp/proof.git" ||
     ! git -C "$tmp/proof.git" bundle verify "$tmp/suspension.bundle" >/dev/null 2>&1 ||
     ! git -C "$tmp/proof.git" fetch -q "$tmp/suspension.bundle" "refs/heads/$branch:refs/heads/proof" ||
     [ "$(git -C "$tmp/proof.git" rev-parse refs/heads/proof)" != "$head" ]; then
    rm -rf -- "$tmp"; return 1
  fi
  identity='{}'; old='{}'
  for key in project kind mode yolo branch harness model effort account account_provider claude_config_dir backend spawn_gen base_branch; do
    value=$(fm_suspend_field "$meta" "$key") || { rm -rf -- "$tmp"; return 1; }
    [ "$key" != backend ] || value=${value:-tmux}
    identity=$(printf '%s' "$identity" | jq --arg k "$key" --arg v "$value" '. + {($k):$v}') || return 1
  done
  for key in worktree window treehouse_lease_holder treehouse_lease_id herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id; do
    value=$(fm_suspend_field "$meta" "$key") || return 1
    old=$(printf '%s' "$old" | jq --arg k "$key" --arg v "$value" '. + {($k):$v}') || return 1
  done
  digest=$(git hash-object "$tmp/suspension.bundle") || return 1
  jq -n --arg id "$id" --arg home "$home" --arg token "$token" --arg head "$head" --arg branch "$branch" \
    --arg project "$(fm_suspend_field "$meta" project)" --arg common "$common" \
    --arg bundle "$dir/suspension.bundle" --arg digest "$digest" --argjson identity "$identity" --argjson old "$old" \
    '{schema:"fm-suspension.v1",task:$id,home:$home,token:$token,head:$head,branch:$branch,project:$project,
      common:$common,bundle:$bundle,bundle_hash:$digest,identity:$identity,old_record:$old}' > "$tmp/suspension.json" || return 1
  chmod 0600 "$tmp/suspension.bundle" "$tmp/suspension.json" || return 1
  mv "$tmp/suspension.bundle" "$dir/suspension.bundle" && mv "$tmp/suspension.json" "$dir/suspension.json" || return 1
  rm -rf -- "$tmp"
  fm_suspend_record "$meta" "copy_state=release-prepared" "suspend_token=$token"
}

# Called ONLY by spawn while metadata/project/control locks are held. Claim
# before get so a crash cannot license another acquire; native holder identity
# remains available even in the acquisition->publication interruption window.
fm_suspend_allocate() { # <meta> <id> <home> <data> <state>
  local meta=$1 id=$2 home=$3 data=$4 state=$5 wt holder lease
  [ "$(fm_suspend_field "$meta" copy_state)" = released ] &&
    fm_suspend_validate "$meta" "$id" "$home" "$data" || return 1
  fm_treehouse_intake_preflight "$FM_SUSPEND_PROJECT" "$state" || return 1
  holder=$(fm_treehouse_lease_holder "$home" "$id") || return 1
  fm_suspend_record "$meta" 'copy_state=restore-prepared' || return 1
  wt=$(cd "$FM_SUSPEND_PROJECT" && treehouse get --lease --lease-holder "$holder") || return 1
  fm_treehouse_pool_slot "$FM_SUSPEND_PROJECT" "$wt" &&
    fm_treehouse_slot_lease_read "$wt" && [ "$FM_TREEHOUSE_LEASED" = 1 ] &&
    [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$holder" ] || return 1
  lease=$FM_TREEHOUSE_LEASE_ID
  # Immediately record custody even if a later isolation/claim/restore refuses.
  fm_suspend_record "$meta" "worktree=$wt" "treehouse_lease_holder=$holder" "treehouse_lease_id=$lease" || return 1
  fm_treehouse_slot_records_exclusive "$wt" "$meta" &&
    fm_treehouse_slot_owner_claim "$wt" "$id" "$home" || return 1
  [ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" = "$(git -C "$FM_SUSPEND_PROJECT" rev-parse --path-format=absolute --git-common-dir)" ] || return 1
  [ "$(git -C "$wt" rev-parse --show-toplevel)" != "$(git -C "$FM_SUSPEND_PROJECT" rev-parse --show-toplevel)" ] || return 1
  fm_suspend_clean_copy "$wt" || return 1
  # Never rebase or reset the saved branch. Occupancy is enforced by git itself.
  git -C "$wt" checkout --no-overwrite-ignore "$FM_SUSPEND_BRANCH" &&
    [ "$(git -C "$wt" rev-parse HEAD)" = "$FM_SUSPEND_HEAD" ] || return 1
  # shellcheck disable=SC2034 # Fresh identities consumed by spawn.
  FM_SUSPEND_NEW_WT=$wt FM_SUSPEND_NEW_HOLDER=$holder FM_SUSPEND_NEW_LEASE=$lease
}
