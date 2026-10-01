#!/usr/bin/env bash
# Live lab drive of bin/fm-teardown.sh against merge-train / rebase landings.
# Usage: live-train-teardown.sh <worktree-root> <transcript-file>
# Real git, real local bare origin, real treehouse pool (rooted inside the lab),
# real tmux endpoint on a private fm-lab socket, disposable marked lab FM_HOME.
set -u
SRC=$1
OUT=$2
BASE_COMMIT=9d2d88a8daa279efb88953ac8608b50aa1d5a10b
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/remotes" "$LAB/base-src"
git -C "$SRC" archive "$BASE_COMMIT" | tar -x -C "$LAB/base-src"
touch "$LAB/state/.last-watcher-beat"
SOCK=fm-lab
labtmux() { TMUX_TMPDIR="$LAB/tmux" tmux -L "$SOCK" "$@"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L "$SOCK" new-session -d -s firstmate -n ops -x 200 -y 50 bash --norc
cleanup() { labtmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
g() { git -c user.email=t@t -c user.name=t "$@"; }

# setup <id>: origin + project clone + real treehouse-leased worktree on fm/<id>
setup() {
  local id=$1 o p wt
  o="$LAB/remotes/$id.git"; p="$LAB/projects/$id"
  git init -q --bare "$o"; git -C "$o" symbolic-ref HEAD refs/heads/main
  git clone -q "$o" "$LAB/_seed" 2>/dev/null
  printf 'readme\n' > "$LAB/_seed/README"; g -C "$LAB/_seed" add README
  g -C "$LAB/_seed" commit -q -m "origin baseline"; g -C "$LAB/_seed" push -q origin HEAD:main
  rm -rf "$LAB/_seed"
  git clone -q "$o" "$p"; git -C "$p" remote set-head origin main >/dev/null 2>&1
  wt=$(cd "$p" && TREEHOUSE_ROOT="$LAB/pool" treehouse get --lease --lease-holder "$id" 2>/dev/null)
  git -C "$wt" checkout -q -b "fm/$id" origin/main
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$p" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=live-$id" > "$LAB/state/$id.meta"
  labtmux new-window -d -t firstmate -n "fm-$id" -c "$wt" "sleep 3600"
  printf '%s' "$wt"
}
commit_file() { printf '%s\n' "$3" > "$1/$2"; g -C "$1" add -- "$2"; g -C "$1" commit -q -m "${4:-add $2}"; }
# train <id> <how-many-commits-to-replay|all>: push branch, land on main with new
# SHAs (unrelated main commit first), later conflicting main edit, delete branch.
train() {
  local id=$1 n=$2 wt=$3 tmp base range
  tmp="$LAB/_train"
  git -C "$wt" push -q origin "fm/$id"
  git clone -q "$LAB/remotes/$id.git" "$tmp"
  commit_file "$tmp" unrelated.txt unrelated "unrelated main work"
  base=$(git -C "$tmp" merge-base HEAD "origin/fm/$id")
  if [ "$n" = all ]; then range="$base..origin/fm/$id"
  else range="$base..$(git -C "$tmp" rev-list --reverse "$base..origin/fm/$id" | sed -n "${n}p")"; fi
  g -C "$tmp" cherry-pick "$range" >/dev/null
  commit_file "$tmp" feature.txt "later main edit" "later main edit"
  git -C "$tmp" push -q origin HEAD:main
  git -C "$tmp" push -q origin --delete "fm/$id"
  rm -rf "$tmp"
  git -C "$LAB/projects/$id" fetch -q --prune origin
}
# teardown <id> <src-root> : run the real CLI from a lab tmux pane (inherits the
# lab $TMUX), as an operator would.
teardown() {
  local id=$1 root=$2 rcf; rcf="$LAB/$id.rc"
  rm -f "$rcf"
  labtmux send-keys -t firstmate:ops \
    "cd '$LAB/projects/$id' && FM_HOME='$LAB' TREEHOUSE_ROOT='$LAB/pool' '$root/bin/fm-teardown.sh' $id > '$LAB/$id.out' 2> '$LAB/$id.err'; echo \$? > '$rcf'" Enter
  for _ in $(seq 1 120); do [ -s "$rcf" ] && break; sleep 0.5; done
  say "\$ fm-teardown.sh $id   (cli: $root)"
  sed 's/^/  stdout| /' "$LAB/$id.out" | tee -a "$OUT"
  grep -v 'new version of treehouse\|treehouse update' "$LAB/$id.err" | sed 's/^/  stderr| /' | tee -a "$OUT"
  say "  exit=$(cat "$rcf" 2>/dev/null || echo timeout)"
}
state() {
  local id=$1 wt=$2
  say "  after: meta=$([ -e "$LAB/state/$id.meta" ] && echo present || echo removed)" \
      " worker_window=$(labtmux list-windows -t firstmate -F '#W' | grep -qx "fm-$id" && echo alive || echo killed)" \
      " wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
      " wt_head=$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)"
}
cherry() { say "  git cherry origin/main HEAD (in worker copy):"; git -C "$1" cherry origin/main HEAD | sed 's/^/    /' | tee -a "$OUT"; }

: > "$OUT"
say "lab home: $LAB (marked: $([ -f "$LAB/.fm-lab-home" ] && echo yes))"; say ""

say "=== S0 baseline: base $BASE_COMMIT refuses a train-landed branch (reported symptom) ==="
wt=$(setup s0); commit_file "$wt" feature.txt hello "add feature"; commit_file "$wt" second.txt two "add second"
train s0 all "$wt"; cherry "$wt"; teardown s0 "$LAB/base-src"; state s0 "$wt"; say ""

say "=== S1 fix: every commit replayed by train, branch deleted -> teardown succeeds ==="
wt=$(setup s1); commit_file "$wt" feature.txt hello "add feature"; commit_file "$wt" second.txt two "add second"
train s1 all "$wt"; cherry "$wt"; teardown s1 "$SRC"; state s1 "$wt"; say ""

say "=== S2 guard: replayed branch plus one extra unlanded local commit -> refuse ==="
wt=$(setup s2); commit_file "$wt" feature.txt hello "add feature"
train s2 all "$wt"; commit_file "$wt" extra.txt extra "unlanded follow-up"; cherry "$wt"; teardown s2 "$SRC"; state s2 "$wt"; say ""

say "=== S3 guard: train replayed only the first of two commits -> refuse ==="
wt=$(setup s3); commit_file "$wt" feature.txt hello "add feature"; commit_file "$wt" second.txt two "add second"
train s3 1 "$wt"; cherry "$wt"; teardown s3 "$SRC"; state s3 "$wt"; say ""

say "=== S4 guard: main has same-message commit on same file with a different patch -> refuse ==="
wt=$(setup s4); commit_file "$wt" feature.txt local-version "add feature"
git -C "$wt" push -q origin fm/s4
git clone -q "$LAB/remotes/s4.git" "$LAB/_d"; commit_file "$LAB/_d" feature.txt main-version "add feature"
git -C "$LAB/_d" push -q origin HEAD:main; git -C "$LAB/_d" push -q origin --delete fm/s4; rm -rf "$LAB/_d"
git -C "$LAB/projects/s4" fetch -q --prune origin
cherry "$wt"; teardown s4 "$SRC"; state s4 "$wt"; say ""

say "=== S5 guard: every commit replayed but tracked file has uncommitted edit -> refuse ==="
wt=$(setup s5); commit_file "$wt" feature.txt hello "add feature"
train s5 all "$wt"; printf 'uncommitted\n' > "$wt/feature.txt"; cherry "$wt"; teardown s5 "$SRC"; state s5 "$wt"; say ""

say "=== S6 every commit replayed, only untracked .claude/ scratch present -> teardown succeeds ==="
wt=$(setup s6); commit_file "$wt" feature.txt hello "add feature"
train s6 all "$wt"; mkdir -p "$wt/.claude"; printf '{}\n' > "$wt/.claude/notes.json"
say "  git status --porcelain: $(git -C "$wt" status --porcelain | tr '\n' ' ')"
cherry "$wt"; teardown s6 "$SRC"; state s6 "$wt"; say ""

say "=== S7 stale local origin/main: train landed after the project's last fetch -> teardown fetches and succeeds ==="
wt=$(setup s7); commit_file "$wt" feature.txt hello "add feature"
train s7 all "$wt"
# Rewind the project's view of origin/main to before the landing (branch ref already pruned).
git -C "$LAB/projects/s7" update-ref refs/remotes/origin/main "$(git -C "$LAB/projects/s7" rev-list --max-parents=0 origin/main)"
say "  local origin/main before teardown: $(git -C "$wt" log --oneline -1 origin/main)"
teardown s7 "$SRC"; state s7 "$wt"; say ""
