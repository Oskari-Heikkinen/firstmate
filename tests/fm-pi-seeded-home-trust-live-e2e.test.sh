#!/usr/bin/env bash
# Live guard for fm-spawn's Pi project-trust preflight (seeded homes + workers).
#
# Real Pi, disposable HOME / PI_CODING_AGENT_DIR and a private tmux server only.
# Worker copies are standalone fixture clones, never the shared worktree pool.
# Like a scout/ship launch, Pi starts in its copy with --approve and an explicit
# -e outside the copy. No initial brief is submitted (this guard is token-free);
# fm-spawn-dispatch-profile.test.sh separately pins production command assembly.
# A project extension proves which cwd actually loaded trusted resources.
# The real viewport feeds the existing composer adapter and sourced watcher
# dialog owner, without starting a watcher or any fleet supervision.
# Never answers a trust dialog or touches ~/.pi. No Herdr server is used.
# Policy: default-on wherever pi and tmux are installed (fm_live_gate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
LAB_HOME=
LAB_TMUX_DIR=
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
CHECKED=0

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - pi %s: %s\n' "${VERSION_OUT:-unknown}" "$1" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [ -n "${LAB_TMUX_DIR:-}" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
    "$LAB_HOME_HELPER" teardown "$LAB_HOME" || rc=1
  fi
  [ -z "${LAB:-}" ] || rm -rf -- "$LAB"
  exit "$rc"
}
trap cleanup EXIT

fm_live_gate default-on FM_PI_SEEDED_HOME_TRUST_LIVE pi tmux

PI_BIN=$(command -v pi) || fail "pi missing after live gate"
VERSION_OUT=$("$PI_BIN" --version 2>&1) || fail "pi --version failed: $VERSION_OUT"
note "live pi version: $VERSION_OUT"
HELP=$("$PI_BIN" --help 2>&1) || fail "pi --help failed"
if ! printf '%s\n' "$HELP" | grep -Eq -- '(^|[[:space:]])--approve([^[:alnum:]_-]|$)'; then
  note "installed pi does not advertise --approve; spawn omits the flag and this guard has nothing to prove"
  echo "# fm-pi-seeded-home-trust-live-e2e: skipped (no --approve on installed pi)"
  exit 0
fi
TUI_ARGS=()
if printf '%s\n' "$HELP" | grep -q -- '--tui-mode'; then
  TUI_ARGS=(--tui-mode regular)
fi

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-seeded-trust.XXXXXX") || fail "could not create disposable lab"
fm_pi_faux_model "$LAB"
LAB_HOME=$("$LAB_HOME_HELPER" create "$LAB/supervisor") || fail "could not create lab home"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$LAB_HOME") || fail "could not isolate tmux"
export TMUX_TMPDIR="$LAB_TMUX_DIR"
unset TMUX TMUX_PANE
PI_DIR="$LAB/pi-agent"
mkdir -p "$PI_DIR"
printf '{}\n' > "$PI_DIR/trust.json"
cp "$PI_DIR/trust.json" "$LAB/trust.before"

assert_trust_unchanged() {
  cmp -s "$LAB/trust.before" "$PI_DIR/trust.json" || fail "trust.json changed ($1)"
}

seed_home() {  # <dir> <id>
  local dir=$1 id=$2
  mkdir -p "$dir/.pi/extensions" "$dir/data" "$dir/state" "$dir/config"
  printf '%s\n' "$id" > "$dir/.fm-secondmate-home"
  printf 'export default function () {}\n' > "$dir/.pi/extensions/fm-primary-turnend-guard.ts"
  printf 'export default function () {}\n' > "$dir/.pi/extensions/fm-primary-pi-watch.ts"
  printf '# test charter\n' > "$dir/data/charter.md"
}

launch() {  # <session> <cwd> [Pi flags...]
  local session=$1 cwd=$2
  shift 2
  # env -i prevents inherited credentials, extensions and fleet/task pins from
  # affecting Pi. All paths and every writable resource belong to this lab.
  "$REAL_TMUX" new-session -d -s "$session" -n w -x 120 -y 40 -c "$cwd" -- \
    env -i PATH="$PATH" TERM=xterm-256color LANG=C.UTF-8 \
    HOME="$LAB/home" PI_CODING_AGENT_DIR="$PI_DIR" PI_OFFLINE=1 \
    FM_PI_HARNESS=pi FM_TRUST_PROOF="$LAB/$session.loaded" \
    "$PI_BIN" "${TUI_ARGS[@]}" --model "$PI_FAUX_MODEL" -e "$PI_FAUX_EXT" --no-session --no-skills --no-prompt-templates "$@" \
    || fail "could not launch $session in $cwd"
}

capture_until() {  # <session> <regex> <seconds> <out-file>
  local session=$1 expect=$2 seconds=$3 out=$4
  local target="$session:w" tail='' i limit
  limit=$((seconds * 5))
  for ((i = 0; i < limit; i++)); do
    tail=$("$REAL_TMUX" capture-pane -p -t "$target" -S -80 2>/dev/null) || true
    if printf '%s' "$tail" | grep -qiE "$expect"; then
      printf '%s' "$tail" > "$out"
      return 0
    fi
    sleep 0.2
  done
  printf '%s' "$tail" > "$out"
  return 1
}

expect_dialog() {  # <session> <cwd>
  local session=$1 cwd=$2
  capture_until "$session" 'escape/ctrl\+c cancel' 15 "$LAB/$session.pane" \
    || fail "$session did not render a trust dialog: $(cat "$LAB/$session.pane")"
  grep -F 'Trust project folder?' "$LAB/$session.pane" >/dev/null \
    || fail "$session has no trust heading"
  grep -F "$cwd" "$LAB/$session.pane" >/dev/null \
    || fail "$session dialog did not name its own cwd: $(cat "$LAB/$session.pane")"
  [ ! -e "$LAB/$session.loaded" ] || fail "$session loaded project resources before trust"
  assert_trust_unchanged "$session dialog"
}

stop_pi() {
  "$REAL_TMUX" kill-session -t "$1" || fail "could not stop lab session $1"
  assert_trust_unchanged "$1 stopped"
}

# Existing seeded-home coverage remains in this guard.
SEED="$LAB/seeded-stall"
seed_home "$SEED" lab-sm-stall
launch stall "$SEED"
expect_dialog stall "$SEED"
stop_pi stall
CHECKED=$((CHECKED + 1))
pass "fresh seeded Pi secondmate-shaped home stalls on Trust project folder? without --approve"

SEED2="$LAB/seeded-approve"
seed_home "$SEED2" lab-sm-approve
launch approve "$SEED2" --approve
capture_until approve 'fm-primary-turnend-guard|fm-primary-pi-watch|No models available|escape interrupt' 15 \
  "$LAB/approve.pane" || fail "approved seeded home never reached post-trust TUI: $(cat "$LAB/approve.pane")"
if grep -qi 'Trust project folder' "$LAB/approve.pane"; then
  fail "approved seeded home still shows trust dialog"
fi
stop_pi approve
CHECKED=$((CHECKED + 1))
pass "seeded home with --approve starts past the trust dialog without rewriting trust.json"

UNSEEDED="$LAB/unseeded"
mkdir -p "$UNSEEDED/.pi/extensions"
printf 'export default function () {}\n' > "$UNSEEDED/.pi/extensions/dummy.ts"
launch unseeded "$UNSEEDED"
expect_dialog unseeded "$UNSEEDED"
stop_pi unseeded
CHECKED=$((CHECKED + 1))
pass "unseeded path without --approve still prompts on Trust project folder?"

# A fresh Git copy with committed trust-requiring resources. No pool allocation
# or git-worktree operation is needed to exercise the worker's launch boundary.
PROJECT="$LAB/project"
mkdir -p "$PROJECT/.pi/extensions"
cat > "$PROJECT/.pi/extensions/trust-proof.ts" <<'TS'
import { writeFileSync } from "node:fs";
export default function () {
  writeFileSync(process.env.FM_TRUST_PROOF!, process.cwd());
}
TS
git -C "$PROJECT" init -q || fail "fixture git init failed"
git -C "$PROJECT" add . || fail "fixture git add failed"
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.invalid commit -qm 'Seed trust resource' \
  || fail "fixture git commit failed"
mkdir -p "$LAB/copies"
WORKER="$LAB/copies/worker"
git clone -q "$PROJECT" "$WORKER" || fail "fixture clone failed"
# CLI -e is outside the copy, as the production worker busy extension is.
printf 'export default function () {}\n' > "$LAB_HOME/state/worker.pi-ext.ts"

# Use the watcher's supported source-only boundary, never its runtime loop.
# Its composer read still uses the real backend and live tmux viewport.
check_worker_dialog() (  # <session> <kind> <dialog|idle>
  export FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$ROOT"
  export FM_STATE_OVERRIDE="$LAB_HOME/state" FM_CONFIG_OVERRIDE="$LAB_HOME/config"
  local target="$1:w" kind=$2 expected=$3 verdict reason
  printf 'window=%s\nkind=%s\nharness=pi\nbackend=tmux\n' "$target" "$kind" \
    > "$LAB_HOME/state/worker.meta"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  fm_composer_dialog_sink_prepare || fail "could not prepare composer sink"
  verdict=$(fm_backend_composer_state tmux "$target" fm-worker)
  if [ "$expected" = dialog ]; then
    [ "$verdict" = unknown ] || fail "trust dialog classified $verdict, not unknown"
    [ "$(fm_composer_blocking_dialog_noted)" = 'Pi project-trust dialog' ] \
      || fail "composer did not name the real trust viewport (target=$target, cursor=$(fm_tmux_composer_cursor_row "$target")):
$(fm_tmux_composer_capture "$target")"
    stale_worker_dialog "$target" || fail "watcher did not recognize $kind trust viewport"
    reason=$IDLE_PARK_REASON
    [ "$reason" = 'blocked on a prompt: Pi project-trust dialog; inspect the worker' ] \
      || fail "watcher returned wrong reason: $reason"
    note "$kind stale reason: $reason"
  else
    [ "$verdict" = empty ] || fail "idle Pi composer classified $verdict, not empty"
    if fm_composer_blocking_dialog_noted >/dev/null || stale_worker_dialog "$target"; then
      fail "ordinary idle $kind composer misnamed as a dialog"
    fi
  fi
  fm_composer_dialog_sink_release
)

launch worker-stall "$WORKER" -e "$LAB_HOME/state/worker.pi-ext.ts"
expect_dialog worker-stall "$WORKER"
for kind in scout ship; do
  check_worker_dialog worker-stall "$kind" dialog || fail "$kind live dialog check failed"
done
stop_pi worker-stall
CHECKED=$((CHECKED + 1))
pass "real worker trust viewport is unknown and named by composer and watcher for scout and ship"

launch worker-approve "$WORKER" --approve -e "$LAB_HOME/state/worker.pi-ext.ts"
capture_until worker-approve 'trust-proof|No models available|escape interrupt' 15 \
  "$LAB/worker-approve.pane" || fail "approved worker never reached TUI: $(cat "$LAB/worker-approve.pane")"
[ -f "$LAB/worker-approve.loaded" ] || fail "approved worker did not execute its project extension"
[ "$(cat "$LAB/worker-approve.loaded")" = "$WORKER" ] || fail "approval loaded resources in another cwd"
if grep -qi 'Trust project folder' "$LAB/worker-approve.pane"; then
  fail "approved worker still shows trust dialog"
fi
for kind in scout ship; do
  check_worker_dialog worker-approve "$kind" idle || fail "$kind live idle negative control failed"
done
stop_pi worker-approve
CHECKED=$((CHECKED + 1))
pass "worker --approve loads only its launch cwd; ordinary idle composer is not a trust dialog"

# Keep the SAME store: no reset that could hide persistent or parent approval.
# Reopening even the approved copy must ask again; its sibling and parent must
# also ask. All three contain project resources, so these are nonvacuous probes.
mkdir -p "$LAB/copies/.pi/extensions"
printf 'export default function () {}\n' > "$LAB/copies/.pi/extensions/parent.ts"
git clone -q "$PROJECT" "$LAB/copies/sibling" || fail "sibling clone failed"
for probe in worker sibling parent; do
  case "$probe" in
    worker) cwd=$WORKER ;;
    sibling) cwd="$LAB/copies/sibling" ;;
    parent) cwd="$LAB/copies" ;;
  esac
  launch "scope-$probe" "$cwd" -e "$LAB_HOME/state/worker.pi-ext.ts"
  expect_dialog "scope-$probe" "$cwd"
  stop_pi "scope-$probe"
done
CHECKED=$((CHECKED + 1))
pass "approval is session-only: same copy, sibling and parent still prompt; trust.json is byte-identical"

[ "$CHECKED" -eq 6 ] || fail "guard did not complete every case (checked=$CHECKED)"
echo "# all fm-pi-seeded-home-trust-live-e2e checks passed ($CHECKED)"
