#!/usr/bin/env bash
# Fixture front: a real direct child of the isolated watcher, never a live home.
set -u
SCRIPT_DIR=$1
watcher=$2
attempt=$3
mode=$4
STATE=$FM_HOME/state
root=$STATE/owner-notices
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
old_pid='' old_start='' old_identity=''
finish() {
  [ -z "$old_pid" ] || printf '%s\n' "$old_pid" > "$root/.runner.lock/pid"
  [ -z "$old_start" ] || printf '%s\n' "$old_start" > "$root/.runner.lock/pid-start"
  [ -z "$old_identity" ] || printf '%s\n' "$old_identity" > "$STATE/.watch.lock/pid-identity"
  fm_lock_release "$root/.foreign.lock"
  fm_lock_release "$root/.runner.lock"
}
trap finish EXIT
case "$mode" in
  install|foreign-lock|stale-lock|missing-lock-start|loop-foreign|loop-uninstalled|loop-identity)
    fm_lock_acquire_wait_max "$root/.runner.lock" 5 || exit 2
    IFS= read -r old_pid < "$root/.runner.lock/pid"
    IFS= read -r old_start < "$root/.runner.lock/pid-start"
    case "$mode" in
      foreign-lock) printf '999999999\n' > "$root/.runner.lock/pid" ;;
      stale-lock) printf 'proc-starttime=0\n' > "$root/.runner.lock/pid-start" ;;
      missing-lock-start) rm "$root/.runner.lock/pid-start" ;;
    esac ;;
  bad-watch)
    IFS= read -r old_identity < "$STATE/.watch.lock/pid-identity"
    printf 'proc-starttime=0\n' > "$STATE/.watch.lock/pid-identity" ;;
  token) attempt=00000000000000000000000000000000 ;;
esac
args=(start-run --home "$FM_HOME" --pid "$$" --watcher-pid "$watcher" --attempt "$attempt")
case "$mode" in install|lockless|foreign-lock|stale-lock|missing-lock-start) args+=(--install) ;; esac
code=0
if [ "$mode" = proof-bound ]; then export FM_TEST_AUTH_STALL=1; fi
if [ "$mode" = loop-foreign ] || [ "$mode" = loop-uninstalled ] || [ "$mode" = loop-identity ]; then
  python3 "$SCRIPT_DIR/fm_owner_notice_store.py" "${args[@]}" --install || exit 2
  lock=$root/.runner.lock
  if [ "$mode" = loop-foreign ]; then
    lock=$root/.foreign.lock
    fm_lock_acquire_wait_max "$lock" 5 || exit 2
  elif [ "$mode" = loop-uninstalled ]; then
    IFS= read -r installed < "$root/.runner"
    printf '%s\n' "${installed/pid=$$/pid=999999999}" > "$root/.runner"
  fi
  IFS= read -r identity < "$STATE/.watch.lock/pid-identity"
  if [ "$mode" = loop-identity ]; then fm_pid_identity_to identity "$$" || exit 2; fi
  args=(runner-loop --home "$FM_HOME" --lock "$lock" --watcher-pid "$watcher" --watcher-identity "$identity")
fi
if [ "$mode" = parent-change ] || [ "$mode" = parent-before ]; then
  # Fault only the post-proof snapshot; the native proof and actual process
  # remain valid. Removing that one recheck must permit the write.
  python3 -c 'import runpy,sys
sys.path.insert(0,sys.argv[1])
import fm_owner_notice_format as fmt
original=fmt.process_identity
calls=0
def changed(pid):
    global calls
    calls+=1
    start,parent=original(pid)
    return (start,0) if calls==target else (start,parent)
target=1 if sys.argv[2]=="parent-before" else 2
fmt.process_identity=changed
sys.argv=[sys.argv[1]+"/fm_owner_notice_store.py"]+sys.argv[3:]
runpy.run_path(sys.argv[0],run_name="__main__")' "$SCRIPT_DIR" "$mode" "${args[@]}" || code=$?
else
  python3 "$SCRIPT_DIR/fm_owner_notice_store.py" "${args[@]}" || code=$?
fi
# Prevent last-command exec optimization: the engine must keep this front as parent.
exit "$code"
