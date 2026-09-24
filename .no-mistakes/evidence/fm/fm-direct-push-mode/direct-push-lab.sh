#!/usr/bin/env bash
# Live direct-push validation on an isolated private-socket tmux server (the
# Herdr lab helper refuses on this host because its default Herdr session is
# not running, and the live sessions must not be touched).
# Drives the real bin/fm-brief.sh, bin/fm-spawn.sh (tmux backend),
# bin/fm-crew-state.sh, bin/fm-pr-check.sh and bin/fm-teardown.sh against a
# scratch project whose origin is a local bare repo. The worker side of the
# landing loop is executed by hand, step by step as the rendered launch brief
# says, including a real lost push race.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
T=$(mktemp -d /tmp/fm-dp-lab.XXXXXX)
export TREEHOUSE_ROOT="$T/treehouse"
SOCK="fm-dp-lab-$$"
REAL_TMUX=$(command -v tmux)
mkdir -p "$T/shim"
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$T/shim/tmux"
chmod +x "$T/shim/tmux"
# A stub `claude` stands in for the Claude harness so the busy-state contract
# (Claude Stop hook -> idle) applies, without launching a real model; its trust
# store is a sandbox CLAUDE_CONFIG_DIR, never the user's ~/.claude.json.
printf '#!/bin/sh\necho "stub claude worker (args: $#)"; exec sleep 1800\n' > "$T/shim/claude"
chmod +x "$T/shim/claude"
export CLAUDE_CONFIG_DIR="$T/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR"; printf '{}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
export PATH="$T/shim:$PATH"
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX TMUX_PANE
export FM_BACKEND=tmux
# Temp-sandbox fleet: the documented test-harness escape hatch for the gate guard.
export FM_GATE_REFUSE_BYPASS=1
cd "$T" || exit 1
# Every worker step must address a worktree inside this sandbox; abort otherwise.
need_wt() { case "$1" in "$TREEHOUSE_ROOT"/?*) [ -d "$1" ] || { echo "ABORT: missing worktree $1"; exit 1; } ;; *) echo "ABORT: worktree '$1' is outside the sandbox"; exit 1 ;; esac; }
say() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return $rc; }
WTS=()
cleanup() {
  say "cleanup"
  for wt in ${WTS[@]+"${WTS[@]}"}; do [ -d "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1; done
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; echo "private tmux server $SOCK killed"
  rm -rf "$T"
}
trap cleanup EXIT
say "private tmux server $SOCK"
tmux new-session -d -s firstmate || exit 1

gitc() { git -c user.name='Lab Worker' -c user.email='lab@example.invalid' "$@"; }

# --- scratch project with a bare origin and a local "full suite" ---------------
P="$T/projects/proj"
mkdir -p "$P"
git -C "$P" init -q -b main
cat > "$P/run-suite.sh" <<'EOF'
#!/bin/sh
# The project's full suite. The first run simulates another worker landing on
# origin/main while this suite runs, so the worker's next push loses the race.
set -e
test -f VERSION
if [ -n "${RACE_FLAG:-}" ] && [ ! -e "$RACE_FLAG" ]; then
  : > "$RACE_FLAG"
  other=$(mktemp -d)
  git clone -q "$RACE_ORIGIN" "$other/c"
  printf 'landed by another worker\n' > "$other/c/OTHER.md"
  git -C "$other/c" add OTHER.md
  git -C "$other/c" -c user.name=Other -c user.email=o@example.invalid commit -qm 'other worker lands first'
  git -C "$other/c" push -q origin HEAD:main
  rm -rf "$other"
  echo "suite: (meanwhile another worker landed on origin/main)"
fi
echo "suite: all checks passed"
EOF
chmod +x "$P/run-suite.sh"
printf '1\n' > "$P/VERSION"
printf '# proj\nFull suite: ./run-suite.sh (there is no CI workflow).\n' > "$P/AGENTS.md"
gitc -C "$P" add -A && gitc -C "$P" commit -qm initial
git clone -q --bare "$P" "$T/proj.origin.git"
git -C "$P" remote add origin "file://$T/proj.origin.git"
git -C "$P" fetch -q origin && git -C "$P" remote set-head origin --auto >/dev/null
ORIGIN="$T/proj.origin.git"

H="$T/home"
mkdir -p "$H/data" "$H/state" "$H/config"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
printf '%s\n' '- proj [direct-push +yolo] - lab fixture (added 2026-09-24)' > "$H/data/projects.md"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$H/data/backlog.md"
ENVH=(env FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1)

fill() { # <brief> <intent> <spec>
  local c; c=$(cat "$1"); c=${c//'{TASK}'/$2}; c=${c//'{FIRSTMATE_SPEC}'/$3}; printf '%s\n' "$c" > "$1"
}

for y in on off; do
  id=dpush-$y
  say "fm-brief.sh $id proj --mode direct-push"
  run "${ENVH[@]}" "$ROOT/bin/fm-brief.sh" "$id" proj --mode direct-push
  fill "$H/data/$id/brief.md" "Bump VERSION for the lab." "Change VERSION and land it by direct push."
  tasks-axi add "$id" "lab direct-push yolo $y" --kind ship --file "$H/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$H/data/backlog.md" >/dev/null
  say "fm-spawn.sh $id --mode direct-push --yolo $y --backend tmux (private socket)"
  run "${ENVH[@]}" "$ROOT/bin/fm-spawn.sh" "$id" "$P" --harness claude \
    --backend tmux --mode direct-push --yolo "$y"
  cp "$H/data/$id/launch-brief.md" "$EV/launch-brief-yolo-$y.md"
  echo "meta:"; cat "$H/state/$id.meta" | grep -E '^(kind|mode|yolo|worktree|backend)='
  WTS+=("$(grep '^worktree=' "$H/state/$id.meta" | cut -d= -f2-)")
  echo "landing authority section in launch brief:"
  awk '/^# Current landing authority$/{p=1} p' "$H/data/$id/launch-brief.md"
done

# The worker's turn ends (what a Claude Stop hook reports through the busy-event
# contract), then firstmate reads its current state.
crew() {
  # The spawn armed the claude busy record; report the idle turn end against it.
  "$ROOT/bin/fm-busy-event.sh" apply "$H/state" "$1" idle --current-gen --source claude-hook --event stop >/dev/null
  run "${ENVH[@]}" "$ROOT/bin/fm-crew-state.sh" "$1"
}

# --- yolo on: land through the loop, losing one push race ----------------------
id=dpush-on; W=${WTS[0]:-}; need_wt "$W"
say "[$id] worker: implement and commit on fm/$id"
printf '2\n' > "$W/VERSION"; gitc -C "$W" commit -qam 'bump VERSION to 2'
gitc -C "$W" rev-parse --abbrev-ref HEAD
DB=$(git -C "$W" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##'); echo "default branch: $DB"

say "[$id] adversarial: a done: whose head is not on origin must not read done"
printf 'done [at=%s]: landed %s on main\n' "$(date +%s)" "$(git -C "$W" rev-parse HEAD)" >> "$H/state/$id.status"
crew "$id"

say "[$id] landing loop step 1-2: fetch, rebase, full suite (another worker lands meanwhile)"
gitc -C "$W" fetch -q origin; gitc -C "$W" rebase -q "origin/$DB"
(cd "$W" && RACE_FLAG="$T/race-fired" RACE_ORIGIN="$ORIGIN" ./run-suite.sh)
say "[$id] step 3: plain push to the default branch - expected to be refused (lost race)"
(cd "$W" && run git push origin "HEAD:$DB"); first_push=$?
[ "$first_push" -ne 0 ] && echo "RESULT: first push refused as non-fast-forward (race lost, nothing overwritten)"
echo "origin/main tip after refused push: $(git --git-dir="$ORIGIN" log --oneline -1 main)"
say "[$id] step 4 -> 1-2 again: re-fetch, rebase, re-run the full suite"
gitc -C "$W" fetch -q origin; gitc -C "$W" rebase -q "origin/$DB"
(cd "$W" && RACE_FLAG="$T/race-fired" RACE_ORIGIN="$ORIGIN" ./run-suite.sh)
say "[$id] step 3 again: plain push"
(cd "$W" && run git push origin "HEAD:$DB")
SHA=$(git -C "$W" rev-parse HEAD)
echo "origin main history:"; git --git-dir="$ORIGIN" log --oneline main
git -C "$W" fetch -q origin
printf 'done [at=%s]: landed %s on %s\n' "$(date +%s)" "$SHA" "$DB" >> "$H/state/$id.status"
say "[$id] firstmate reads crew state after landing"
crew "$id"
say "[$id] firstmate tries to arm a PR merge poll for a direct-push task"
run "${ENVH[@]}" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-pr-check.sh" "$id" https://github.com/o/r/pull/1
grep -c '^pr=' "$H/state/$id.meta" | sed 's/^/pr= lines recorded in meta: /'

# --- yolo off: stop at ready on fm/<id>, never touch main ------------------------
id=dpush-off; W=${WTS[1]:-}; need_wt "$W"
say "[$id] worker: implement and commit"
printf 'lab note\n' > "$W/NOTE.md"; gitc -C "$W" add NOTE.md; gitc -C "$W" commit -qm 'add NOTE'
say "[$id] adversarial: teardown before anything is pushed must refuse"
run "${ENVH[@]}" "$ROOT/bin/fm-teardown.sh" "$id"
MAIN_BEFORE=$(git --git-dir="$ORIGIN" rev-parse main)
say "[$id] stop at ready: steps 1-2, then push to fm/$id only"
gitc -C "$W" fetch -q origin; gitc -C "$W" rebase -q "origin/$DB"
(cd "$W" && ./run-suite.sh)
(cd "$W" && run git push origin "HEAD:refs/heads/fm/$id")
SHA=$(git -C "$W" rev-parse HEAD); git -C "$W" fetch -q origin
printf 'done [at=%s]: ready in branch fm/%s tested on %s at %s\n' "$(date +%s)" "$id" "$DB" "$SHA" >> "$H/state/$id.status"
[ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$MAIN_BEFORE" ] && echo "RESULT: origin/main unchanged by the yolo-off worker"
say "[$id] firstmate reads crew state at ready"
crew "$id"

# --- teardown of the landed task ---------------------------------------------
say "[dpush-on] teardown after landing (no PR recorded)"
run "${ENVH[@]}" "$ROOT/bin/fm-teardown.sh" dpush-on
echo "backlog row:"; tasks-axi show dpush-on --file "$H/data/backlog.md" | grep -E 'state|id'
