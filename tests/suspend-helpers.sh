#!/usr/bin/env bash
# Saved-task fixtures shared by existing park/control/spawn/inbox subjects.
# No real backend, pool or home is touched; Git objects/branches are real.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shared assert_grep/assert_no_grep APIs are fixed-string checks. Saved
# custody tests need anchored whole-field and event-order regular expressions.
suspend_assert_matches() { grep -E -- "$1" "$2" >/dev/null || fail "$3"; }
suspend_assert_no_match() { ! grep -E -- "$1" "$2" >/dev/null || fail "$3"; }

suspend_case() { # <temp-root> <id>
  local root=$1 id=$2 wt project home dir
  dir="$root/$id"; home="$dir/home"; project="$dir/project"; wt="$dir/.treehouse/pool/1/project"
  mkdir -p "$home/state" "$home/config" "$home/data/$id" "$project" "$dir/fakebin"
  git init -q -b main "$project" || return 1
  printf 'base\n' > "$project/file"
  git -C "$project" add file && git -C "$project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm base || return 1
  git -C "$project" worktree add -q -b "fm/$id" "$wt" HEAD || return 1
  printf 'unlanded saved work\n' > "$wt/file"
  git -C "$wt" add file && git -C "$wt" -c user.name=Tests -c user.email=tests@example.invalid commit -qm saved || return 1
  fm_write_meta "$home/state/$id.meta" "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$project" \
    'harness=pi' 'kind=ship' 'mode=direct-push' 'yolo=off' "branch=fm/$id" 'model=default' 'effort=default' \
    'spawn_gen=g1' 'park_spawn_gen=g1' 'park_state=parked' "park_when=inbox:$id" "park_handoff=$home/data/$id/handoff.md" \
    'park_token=p1' 'park_exit_confirmed=p1' 'wait_started_at=1' 'park_relocation_safe=1' 'copy_state=retained'
  # shellcheck disable=SC2016 # Literal Markdown condition, not command substitution.
  printf '## Goal\ng\n## Done\nd\n## Waiting for\n`inbox:%s`\n## Next steps\nn\n' "$id" > "$home/data/$id/handoff.md"
  printf '# Task\n\n## Captain\x27s intent\nKeep the saved work.\n\n## Firstmate spec\nUse the recorded handoff.\n' > "$home/data/$id/brief.md"
  printf 'paused [at=1]: waiting for authorized pickup\n' > "$home/state/$id.status"
  # A fake pool starts leased to this task; production library reads actual state.
  local holder
  holder=$(FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_lease_holder "$2" "$3"' _ "$ROOT" "$home" "$id") || return 1
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s","lease_id":"old-lease"}]}\n' "$wt" "$holder" > "$dir/.treehouse/pool/treehouse-state.json"
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$dir/.treehouse/pool/1/.fm-slot-owner"
  printf 'treehouse_lease_holder=%s\ntreehouse_lease_id=old-lease\n' "$holder" >> "$home/state/$id.meta"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$SUSPEND_DIR/calls"
[ "${1-}" != --root ] || shift 2
case "$1" in
  get)
    [ ! -e "$SUSPEND_DIR/fail-get" ] || exit 1
    wt="$SUSPEND_DIR/.treehouse/pool/1/project"
    holder=$4
    if [ -e "$SUSPEND_DIR/different-slot" ]; then
      wt="$SUSPEND_DIR/.treehouse/pool/2/project"
      git -C "$SUSPEND_DIR/project" worktree add --detach -q "$wt" main || exit 1
      jq --arg w "$wt" '.worktrees += [{name:"2",path:$w,leased:false,lease_holder:"",lease_id:""}]' "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json" > "$SUSPEND_DIR/pool-new"
      mv "$SUSPEND_DIR/pool-new" "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json"
    fi
    git -C "$wt" checkout --detach -q main || exit 1
    jq --arg h "$holder" --arg w "$wt" '.worktrees |= map(if .path==$w then . + {leased:true,lease_holder:$h,lease_id:"new-lease"} else . end)' \
      "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json" > "$SUSPEND_DIR/pool-new"
    mv "$SUSPEND_DIR/pool-new" "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json"
    printf '%s\n' "$wt" ;;
  status)
    jq --slurpfile jobs "$SUSPEND_DIR/processes.json" '[.worktrees[] | {path,processes:$jobs[0]}]' "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json" ;;
  return)
    [ ! -e "$SUSPEND_DIR/fail-return" ] || exit 1
    holder=$3; lease=$5; wt=$6
    [ ! -e "${wt%/*}/.fm-slot-owner" ] || exit 8
    if git -C "$wt" symbolic-ref --quiet HEAD >/dev/null; then exit 8; fi
    jq -e --arg h "$holder" --arg l "$lease" --arg w "$wt" '.worktrees[0] | .leased and .lease_holder==$h and .lease_id==$l and .path==$w' "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json" >/dev/null || exit 1
    jq '.worktrees[0] += {leased:false,lease_holder:"",lease_id:""}' "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json" > "$SUSPEND_DIR/pool-new"
    mv "$SUSPEND_DIR/pool-new" "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json"
    if [ -e "$SUSPEND_DIR/reuse-after-return" ]; then
      # Same task slug, different home/acquisition: old-id-only cleanup would
      # erase this legitimate successor's claim after its native acquisition.
      printf 'task=%s\nhome=%s\n' "$(cat "$SUSPEND_DIR/id")" "$SUSPEND_DIR/foreign-home" > "${wt%/*}/.fm-slot-owner"
      printf 'foreign uncommitted work\n' > "$wt/file"
      jq '.worktrees[0] += {leased:true,lease_holder:"foreign-owner",lease_id:"successor-lease"}' "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json" > "$SUSPEND_DIR/pool-new"
      mv "$SUSPEND_DIR/pool-new" "$SUSPEND_DIR/.treehouse/pool/treehouse-state.json"
    fi ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$dir/fakebin/treehouse"
  printf '[]\n' > "$dir/processes.json"
  printf '%s\n' "$id" > "$dir/id"
  printf '%s\n' "$dir"
}

suspend_lib() { # <case-dir> <function> [args...]
  local dir=$1; shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-suspend-lib.sh"
      shift
      "$@"
    ' _ "$ROOT" "$@"
}

suspend_saved() { # <case-dir> <id>; simulate verified return, never real return
  local dir=$1 id=$2 home="$1/home" wt="$1/.treehouse/pool/1/project"
  suspend_lib "$dir" fm_suspend_save "$home/state/$id.meta" "$id" "$home" "$home/data" "$wt" || return 1
  git -C "$wt" checkout --detach -q HEAD || return 1
  rm "$dir/.treehouse/pool/1/.fm-slot-owner"
  jq '.worktrees[0] += {leased:false,lease_holder:"",lease_id:""}' "$dir/.treehouse/pool/treehouse-state.json" > "$dir/pool-new"
  mv "$dir/pool-new" "$dir/.treehouse/pool/treehouse-state.json"
  suspend_lib "$dir" fm_suspend_record "$home/state/$id.meta" 'copy_state=released' 'worktree=' 'window=' \
    'treehouse_lease_holder=' 'treehouse_lease_id='
}

# Agent-free tmux model for the portable release subject (not an allocation
# model). The control relaunch subject owns its more detailed launch model.
suspend_idle_terminal() { # <case-dir> <id>
  local dir=$1 id=$2
  printf 'fm-%s\n' "$id" > "$dir/windows"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$1" in
  list-windows) cat "$SUSPEND_DIR/windows" ;;
  display-message)
    case "${*: -1}" in
      *pane_current_command*) [ ! -e "$SUSPEND_DIR/live-agent" ] && echo bash || echo pi ;;
      *) echo '%1' ;;
    esac ;;
  capture-pane) printf 'idle shell\n' ;;
  kill-window)
    printf '%s\n' "$*" >> "$SUSPEND_DIR/terminal-calls"
    [ ! -e "$SUSPEND_DIR/slow-kill" ] || /bin/sleep 5
    [ ! -e "$SUSPEND_DIR/fail-kill" ] || exit 1
    : > "$SUSPEND_DIR/windows" ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
}

# Register and execute a real bounded release action in the fixture's private
# home, so portable policy cases use the same entrypoint as live acceptance.
suspend_register_release() { # <case-dir> <id>
  local dir=$1 id=$2 token name meta
  meta="$dir/home/state/$id.meta"
  token=$(sed -n 's/^park_token=//p' "$meta")
  name=$(bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-suspend-lib.sh"; fm_suspend_release_source_name "$2" "$3" "$4"' _ "$ROOT" "$dir/home" "$id" "$token") || return 1
  suspend_lib "$dir" fm_suspend_record "$meta" "park_release_source=when-$name" || return 1
  SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-procevent-when.sh" arm "$name" --stable 1 --interval 1 --deadline 30 --action-timeout 20 \
    --condition "$ROOT/bin/fm-park.sh" release-ready "$id" "$token" \
    --action "$ROOT/bin/fm-park.sh" release "$id" "$token" >/dev/null || return 1
  fm_test_track_procevent_home "$dir/home"
}

suspend_run_release() { # <case-dir> <id>; captures through the generic runner
  local dir=$1 id=$2 source
  source=$(sed -n 's/^park_release_source=//p' "$dir/home/state/$id.meta")
  [ -n "$source" ] || return 1
  SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    "$ROOT/bin/fm-procevent.sh" start "$source" > "$dir/runner.out" 2>&1 || return 1
  cp "$dir/home/state/procevent-inbox/$source".*.result "$dir/action-result" || return 1
  [ -n "$id" ]
}

suspend_park() { # <case-dir> <park arguments...>
  local dir=$1; shift
  (cd "$dir/home" && SUSPEND_DIR="$dir" PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$ROOT/bin/fm-park.sh" "$@")
}
