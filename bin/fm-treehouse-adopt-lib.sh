#!/usr/bin/env bash
# fm-treehouse-adopt-lib.sh - in-place reservation repair shared by owner adoption
# and relaunch. Call fm_treehouse_adopt_locked only with this task's metadata
# lock and the shared project allocation lock held. It publishes only its own
# record, never releases a slot, and never changes repository contents.
# Live task workers/jobs require the exported FM_TASK_ID plus their recorded
# pane identity. Idle Herdr login shells (or plain get/idle-shell chains) need
# exact pane environment and ancestry, with no unrelated children.
# Unknown processes/platform evidence refuse adoption.
# Native Treehouse lease is state-only, including while plain get is alive;
# protect first, before lifecycle control can exit that interactive holder.

fm_treehouse_process_command() { # <pid>
  ps -ww -p "$1" -o args= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

fm_treehouse_process_env() { # <pid>
  if [ -r "/proc/$1/environ" ]; then
    tr '\0' '\n' < "/proc/$1/environ"
  else
    ps -Eww -p "$1" -o command= 2>/dev/null | tr ' ' '\n'
  fi
}

fm_treehouse_process_pane() { # <pid> <pane>
  local env
  env=$(fm_treehouse_process_env "$1") || return 1
  [ "$(printf '%s\n' "$env" | grep '^HERDR_PANE_ID=')" = "HERDR_PANE_ID=$2" ]
}

fm_treehouse_owned_process() { # <pid> <meta>
  local env id backend pane key panes endpoint
  env=$(fm_treehouse_process_env "$1") || return 1
  id=${2##*/}; id=${id%.meta}
  [ "$(printf '%s\n' "$env" | grep '^FM_TASK_ID=')" = "FM_TASK_ID=$id" ] || return 1
  backend=$(fm_treehouse_record_field "$2" backend) || return 1
  case "$backend" in
    herdr) key=HERDR_PANE_ID; pane=$(fm_treehouse_record_field "$2" herdr_pane_id) ;;
    zellij) key=ZELLIJ_PANE_ID; pane=$(fm_treehouse_record_field "$2" zellij_pane_id) ;;
    cmux) key=CMUX_SURFACE_ID; pane=$(fm_treehouse_record_field "$2" cmux_surface_id) ;;
    tmux|'')
      key=TMUX_PANE; endpoint=$(fm_treehouse_record_field "$2" window) || return 1
      [ -n "$endpoint" ] || return 1
      panes=$(tmux list-panes -t "$endpoint" -F '#{pane_id}' 2>/dev/null) || return 1
      pane=$(printf '%s\n' "$env" | sed -n 's/^TMUX_PANE=//p')
      [ -n "$pane" ] && printf '%s\n' "$panes" | grep -Fxq -- "$pane" || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$pane" ] && [ "$(printf '%s\n' "$env" | grep "^$key=")" = "$key=$pane" ]
}

fm_treehouse_idle_shell() { # <pid> <pane> <process-table>
  local cmd tty
  [ "$(ps -p "$1" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//; s#.*/##')" = bash ] || return 1
  fm_treehouse_process_pane "$1" "$2" || return 1
  cmd=$(fm_treehouse_process_command "$1") || return 1
  case "$cmd" in
    -bash|bash\ -i\ -l|/bin/bash\ -i\ -l|bash\ -l\ -i|/bin/bash\ -l\ -i|bash\ -il|/bin/bash\ -il) ;;
    *) return 1 ;;
  esac
  tty=$(ps -p "$1" -o tty= 2>/dev/null | tr -d '[:space:]') || return 1
  case "$tty" in ''|'?'|'??'|'-') return 1 ;; esac
  ! printf '%s\n' "$3" | awk -v p="$1" '$2==p {found=1} END {exit !found}'
}

# A process must be the idle leaf, or the plain get directly parenting it.
# Every ancestor in the exception carries the same recorded pane identity.
fm_treehouse_idle_holder() { # <pid> <meta> <process-table>
  local pid=$1 meta=$2 table=$3 pane cmd child parent children
  fm_treehouse_owned_process "$pid" "$meta" && return 0
  [ "$(fm_treehouse_record_field "$meta" backend)" = herdr ] || return 1
  pane=$(fm_treehouse_record_field "$meta" herdr_pane_id) || return 1
  [ -n "$pane" ] || return 1
  fm_treehouse_process_pane "$pid" "$pane" || return 1
  if fm_treehouse_idle_shell "$pid" "$pane" "$table"; then return 0; fi
  cmd=$(fm_treehouse_process_command "$pid") || return 1
  case "$cmd" in
    -bash|bash\ -i\ -l|/bin/bash\ -i\ -l|bash\ -l\ -i|/bin/bash\ -l\ -i|bash\ -il|/bin/bash\ -il)
      children=$(printf '%s\n' "$table" | awk -v p="$pid" '$2==p {print $1}')
      [ -n "$children" ] || return 1
      if [[ "$children" =~ ^[0-9]+$ ]]; then
        cmd=$(fm_treehouse_process_command "$children") || return 1
        case "$cmd" in treehouse\ get|*/treehouse\ get)
          fm_treehouse_idle_holder "$children" "$meta" "$table"; return $? ;;
        esac
      fi
      # The pane's original shell may not have the subsequently exported task
      # marker in /proc/environ, but its actual worker/job children must have it.
      while IFS= read -r child; do
        fm_treehouse_owned_process "$child" "$meta" || return 1
      done <<< "$children"
      return 0 ;;
    treehouse\ get|*/treehouse\ get) ;;
    *) return 1 ;;
  esac
  [ "$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//; s#.*/##')" = treehouse ] || return 1
  children=$(printf '%s\n' "$table" | awk -v p="$pid" '$2==p {print $1}')
  case "$children" in ''|*[!0-9]*) return 1 ;; esac
  child=$children
  fm_treehouse_idle_shell "$child" "$pane" "$table" || return 1
  parent=$(printf '%s\n' "$table" | awk -v p="$pid" '$1==p {print $2}')
  case "$parent" in ''|*[!0-9]*) return 1 ;; esac
  fm_treehouse_process_pane "$parent" "$pane" || return 1
  [ "$(ps -p "$parent" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//; s#.*/##')" = bash ] || return 1
  cmd=$(fm_treehouse_process_command "$parent") || return 1
  case "$cmd" in -bash|bash\ -i\ -l|/bin/bash\ -i\ -l|bash\ -l\ -i|/bin/bash\ -l\ -i|bash\ -il|/bin/bash\ -il) ;; *) return 1 ;; esac
  [ "$(printf '%s\n' "$table" | awk -v p="$parent" '$2==p {print $1}')" = "$pid" ]
}

fm_treehouse_adopt_locked() { # <meta> <id> <project> <home>
  local meta=$1 id=$2 project=$3 home=$4 wt holder old_holder old_lease lease marker pool root row name pid status pids table result tmp
  [ "$meta" = "$STATE/$id.meta" ] && [ "$home" = "$FM_HOME" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  awk '/^(project|worktree|kind|backend|herdr_pane_id|treehouse_lease_holder|treehouse_lease_id)=/ {
    split($0,a,"="); if (++n[a[1]]>1) bad=1
  } END {exit bad}' "$meta" || return 1
  wt=$(fm_treehouse_record_field "$meta" worktree) || return 1
  fm_treehouse_pool_slot "$project" "$wt" || return 1
  wt=$(CDPATH='' cd -- "$wt" && pwd -P) || return 1
  fm_treehouse_collect_states "$STATE" && fm_treehouse_slot_records_exclusive "$wt" "$meta" || return 1
  marker=$(fm_treehouse_slot_owner_marker "$wt") || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_treehouse_slot_claim_matches "$wt" "$id" "$home" || return 1
  fi
  holder=$(fm_treehouse_lease_holder "$home" "$id") || return 1
  old_holder=$(fm_treehouse_record_field "$meta" treehouse_lease_holder) || return 1
  old_lease=$(fm_treehouse_record_field "$meta" treehouse_lease_id) || return 1
  fm_treehouse_slot_lease_read "$wt" || return 1
  if [ "$FM_TREEHOUSE_LEASED" = 1 ]; then
    [ "$FM_TREEHOUSE_LEASE_HOLDER" = "$holder" ] &&
      { [ -z "$old_holder$old_lease" ] || { [ "$old_holder" = "$holder" ] && [ "$old_lease" = "$FM_TREEHOUSE_LEASE_ID" ]; }; } || return 1
    lease=$FM_TREEHOUSE_LEASE_ID
    if [ "$old_holder" = "$holder" ] && [ "$old_lease" = "$lease" ] && fm_treehouse_slot_claim_matches "$wt" "$id" "$home"; then
      printf 'already protected: %s %s\n' "$id" "$wt"; return 0
    fi
  else
    [ -z "$old_holder$old_lease" ] || return 1
    lease=''
  fi
  # Also inspect holders of an intake-protected or partially published lease:
  # exclusion from allocation is not proof that an unrelated process is ours.
    pool=$(dirname "$(dirname "$wt")")
    root=$(fm_treehouse_native_root "$wt") || return 1
    row=$(jq -cer --arg wt "$wt" '[.worktrees[] | select(.path==$wt)] | if length==1 then .[0] else error("ambiguous row") end' "$pool/treehouse-state.json") || return 1
    pid=$(printf '%s\n' "$row" | jq -er '(.owner_pid // 0) | select(type=="number" and .>=0 and floor==.)') || return 1
    name=$(printf '%s\n' "$row" | jq -er '.name | select(type=="string" and test("^[A-Za-z0-9._-]+$") and .!="." and .!="..")') || return 1
    status=$(cd "$project" && treehouse --root "$root" status --json) || return 1
    pids=$(printf '%s\n' "$status" | jq -er --arg wt "$wt" --arg name "$name" --arg lease "$lease" '
      [.[] | select(.path==$wt and .name==$name)] | select(length==1) | .[0] |
      select(.status=="available" or .status=="dirty" or (.status=="leased" and $lease!="") or (.status=="in-use" and (.processes|length)>0)) |
      .processes | select(type=="array") |
      if all(.[]; (.pid|type)=="number" and .pid>0 and (.pid|floor)==.pid)
      then map(.pid|tostring)|join("\n") else error("unsafe processes") end') || return 1
    table=$(ps -e -o pid= -o ppid=) || return 1
    if [ "$pid" != 0 ] && { fm_pid_alive "$pid" || ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'; }; then
      fm_treehouse_idle_holder "$pid" "$meta" "$table" || { echo "conflict: live holder pid=$pid at $wt ($id)" >&2; return 1; }
    fi
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      fm_treehouse_idle_holder "$pid" "$meta" "$table" || { echo "conflict: live/unverified holder pid=$pid at $wt ($id)" >&2; return 1; }
    done <<< "$pids"
  if [ -z "$lease" ]; then
    result=$(cd "$project" && treehouse --root "$root" lease "$name" --lease-holder "$holder" --json) || return 1
    lease=$(printf '%s\n' "$result" | jq -er --arg wt "$wt" --arg h "$holder" 'select(.path==$wt and .lease_holder==$h) | .lease_id | select(type=="string" and length>0 and (test("[\\r\\n\\t]")|not))') || return 1
  fi
  printf 'protected acquisition: %s %s holder=%s lease_id=%s\n' "$id" "$wt" "$holder" "$lease"
  fm_treehouse_slot_lease_matches "$wt" "$holder" "$lease" && fm_treehouse_slot_records_exclusive "$wt" "$meta" && fm_treehouse_slot_owner_claim "$wt" "$id" "$home" || return 1
  tmp=$(mktemp "$STATE/.adopt-$id.XXXXXX") || return 1
  if ! { cp -p "$meta" "$tmp" && awk '!/^treehouse_lease_holder=/ && !/^treehouse_lease_id=/' "$meta" > "$tmp" && printf 'treehouse_lease_holder=%s\ntreehouse_lease_id=%s\n' "$holder" "$lease" >> "$tmp" && mv "$tmp" "$meta"; }; then
    rm -f "$tmp"; return 1
  fi
  printf 'adopted: %s %s\n' "$id" "$wt"
}

# Control calls before exiting any holder. Its outer supervision/lifecycle
# guard remains held; this subshell takes the same metadata/project lock order
# as spawn/adoption and releases only the locks it acquired.
fm_treehouse_adopt_for_relaunch() ( # <meta> <id> <project> <home>
  local meta=$1 id=$2 project=$3 home=$4 wt lock meta_lock='' project_lock=''
  wt=$(fm_treehouse_record_field "$meta" worktree) || return 1
  fm_treehouse_pool_slot "$project" "$wt" || return 0
  [ -z "$(fm_treehouse_record_field "$meta" treehouse_lease_holder)$(fm_treehouse_record_field "$meta" treehouse_lease_id)" ] || return 0
  trap '[ -z "$project_lock" ] || fm_lock_release "$project_lock"; [ -z "$meta_lock" ] || fm_lock_release "$meta_lock"' EXIT
  trap 'exit 1' HUP INT TERM
  lock=$(fm_meta_lock_path "$meta") && fm_lock_try_acquire "$lock" || return 1
  meta_lock=$lock
  lock=$(fm_treehouse_project_lock_path "$project") && fm_lock_try_acquire "$lock" || return 1
  project_lock=$lock
  fm_treehouse_adopt_locked "$meta" "$id" "$project" "$home"
)
