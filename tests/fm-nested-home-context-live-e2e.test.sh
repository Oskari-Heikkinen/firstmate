#!/usr/bin/env bash
# Live guard: a ship or scout worktree nested inside a firstmate home must not
# carry that home's instruction files into the installed harness's first model
# request, while the project's own files and a home-cwd session's contract
# still load.
#
# It spends no model tokens. Each harness is pointed at a local server that
# records the request body and answers with an error, so the assertion reads
# exactly what the real binary would have sent. The launch material under test
# is what the real bin/fm-spawn.sh generates for a nested worktree (Claude's
# --settings JSON and Pi's per-task extension), produced through a fake tmux
# pane. Every harness first proves the leak exists without that material, so a
# harness that stops loading ancestors cannot turn this into a vacuous pass.
# Claude runs in an isolated config directory whose project entries carry the
# external-import consent the fleet's own entries carry, since without it
# Claude drops the home's @AGENTS.md import in print mode by itself.
#
# Default-on because it submits no prompt to a provider; FM_NESTED_HOME_CONTEXT_LIVE=1
# (or FM_LIVE=1) makes an absent harness a failure, =0 turns the guard off.
# docs/verification/runtime-backends.md records the dated results.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_NESTED_HOME_CONTEXT_LIVE python3 jq node git

TMP_ROOT=$(fm_test_tmproot fm-nested-home-context-live)
trap fm_test_cleanup EXIT

REQUESTED=0
case "${FM_NESTED_HOME_CONTEXT_LIVE:-}${FM_LIVE:-}" in *1*) REQUESTED=1 ;; esac

CAPTURE_PY="$TMP_ROOT/capture.py"
cat > "$CAPTURE_PY" <<'PY'
import http.server, itertools, json, os, sys
out = sys.argv[1]
seq = itertools.count()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        name = "%03d%s.json" % (next(seq), self.path.split("?")[0].replace("/", "_"))
        with open(os.path.join(out, name), "wb") as f:
            f.write(body)
        reply = json.dumps({"type": "error", "error": {"type": "invalid_request_error", "message": "capture only"}}).encode()
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    def do_GET(self):
        self.send_response(404)
        self.send_header("content-length", "0")
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(out, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$HOME_DIR/projects/proj"
NESTED_WT="$PROJ_DIR/.treehouse/pool/1/proj"
OUTSIDE_WT="$TMP_ROOT/pool/1/proj"
fm_test_spawn_home "$HOME_DIR" claude
printf '@AGENTS.md\n' > "$HOME_DIR/CLAUDE.md"
printf 'HOME_CONTRACT_MARKER firstmate supervisor contract\n' > "$HOME_DIR/AGENTS.md"
fm_git_init_commit "$PROJ_DIR"
printf 'PROJECT_MARKER project rules\n' > "$PROJ_DIR/CLAUDE.md"
printf 'PROJECT_MARKER project rules\n' > "$PROJ_DIR/AGENTS.md"
printf '.treehouse/\n' > "$PROJ_DIR/.gitignore"
git -C "$PROJ_DIR" add -A && git -C "$PROJ_DIR" -c user.name=t -c user.email=t@t commit -qm project
fm_git_add_origin "$PROJ_DIR" "$PROJ_DIR.origin.git"
mkdir -p "$(dirname "$NESTED_WT")" "$(dirname "$OUTSIDE_WT")"
git -C "$PROJ_DIR" worktree add --quiet -b wt-nested "$NESTED_WT"
git -C "$PROJ_DIR" worktree add --quiet -b wt-outside "$OUTSIDE_WT"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")

# spawn_nested <id> <harness> writes the brief, runs the real fm-spawn against
# the nested worktree through the fake pane, and echoes the captured launch.
spawn_nested() {
  local id=$1 harness=$2 log="$TMP_ROOT/$1.launch" out
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" PATH="$FAKEBIN_DIR:$PATH" fm_test_run_spawn "$HOME_DIR" "$NESTED_WT" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness "$harness" --mode no-mistakes --yolo off) \
    || fail "fm-spawn $harness nested launch failed: $out"
  cat "$log"
}

# capture <label> <cwd> <command...> runs the harness against a fresh capture
# server and prints the path of the first recorded model request body.
capture() {
  local label=$1 cwd=$2 out="$TMP_ROOT/capture/$1" pid port i=0 body
  shift 2
  mkdir -p "$out"
  python3 "$CAPTURE_PY" "$out" & pid=$!
  while [ ! -s "$out/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  port=$(cat "$out/port" 2>/dev/null) || { kill "$pid"; fail "$label: capture server did not start"; }
  (cd "$cwd" && CAPTURE_PORT=$port timeout 90 "$@" >"$out/stdout" 2>"$out/stderr" </dev/null) || true
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  body=$(grep -l 'PROJECT_MARKER\|HOME_CONTRACT_MARKER\|"messages"' "$out"/[0-9]*.json 2>/dev/null | head -n 1)
  [ -n "$body" ] || fail "$label: the harness sent no model request ($(tail -n 3 "$out/stderr" | tr '\n' ' '))"
  printf '%s\n' "$body"
}

expect_markers() {
  local label=$1 body=$2 home=$3 project=$4 got
  [ -f "$body" ] || fail "$label: no model request was captured"
  got=$(grep -c HOME_CONTRACT_MARKER "$body")
  { [ "$home" = yes ] && [ "$got" -gt 0 ]; } || { [ "$home" = no ] && [ "$got" -eq 0 ]; } \
    || fail "$label: home contract expected=$home but the first request carried it $got time(s)"
  got=$(grep -c PROJECT_MARKER "$body")
  { [ "$project" = yes ] && [ "$got" -gt 0 ]; } || { [ "$project" = no ] && [ "$got" -eq 0 ]; } \
    || fail "$label: project rules expected=$project but the first request carried them $got time(s)"
}

harness_present() {
  command -v "$1" >/dev/null 2>&1 && return 0
  [ "$REQUESTED" -eq 1 ] && fail "$1 was requested but is not installed"
  printf 'skip: live: %s absent\n' "$1"
  return 1
}

CHECKED=0

run_claude() {
  local launch settings version body
  harness_present claude || return 0
  version=$(claude --version 2>/dev/null | head -n 1)
  CLAUDE_CAPTURE_CONFIG_DIR="$TMP_ROOT/claude-config"
  mkdir -p "$CLAUDE_CAPTURE_CONFIG_DIR"
  jq -n --arg p "$(cd "$PROJ_DIR" && pwd -P)" --arg n "$(cd "$NESTED_WT" && pwd -P)" --arg h "$(cd "$HOME_DIR" && pwd -P)" '
    {hasTrustDialogAccepted: true, hasClaudeMdExternalIncludesApproved: true, hasClaudeMdExternalIncludesWarningShown: true} as $e
    | {projects: {($p): $e, ($n): $e, ($h): $e}}' > "$CLAUDE_CAPTURE_CONFIG_DIR/.claude.json"
  launch=$(spawn_nested live-claude-nested claude)
  settings=$(printf '%s\n' "$launch" | sed -n "s/.* --settings '\([^']*\)'.*/\1/p" | head -n 1)
  printf '%s' "$settings" | jq -e '.claudeMdExcludes | length > 0' >/dev/null \
    || fail "claude $version: fm-spawn produced no claudeMdExcludes for a nested worktree: $settings"
  claude_run() {
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR="$CLAUDE_CAPTURE_CONFIG_DIR" \
      ANTHROPIC_API_KEY=sk-capture-only ANTHROPIC_BASE_URL="http://127.0.0.1:$CAPTURE_PORT" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p hi --max-turns 1 --model claude-haiku-4-5 "$@"
  }
  export -f claude_run
  export CLAUDE_CAPTURE_CONFIG_DIR
  body=$(capture claude-nested-baseline "$NESTED_WT" bash -c 'claude_run "$@"' _)
  expect_markers "claude $version nested worktree without the spawn settings" "$body" yes yes
  body=$(capture claude-nested-spawn "$NESTED_WT" bash -c 'claude_run "$@"' _ --settings "$settings")
  expect_markers "claude $version nested worktree with the spawn settings" "$body" no yes
  body=$(capture claude-outside "$OUTSIDE_WT" bash -c 'claude_run "$@"' _)
  expect_markers "claude $version worktree outside the home" "$body" no yes
  body=$(capture claude-home "$HOME_DIR" bash -c 'claude_run "$@"' _)
  expect_markers "claude $version session whose cwd is the home" "$body" yes no
  pass "claude $version: a nested worker's first request drops the home contract, keeps the project's, and a home session keeps its own"
  CHECKED=$((CHECKED + 1))
}

run_pi() {
  local launch ext version body agent_dir
  harness_present pi || return 0
  version=$(pi --version 2>/dev/null | head -n 1)
  launch=$(spawn_nested live-pi-nested pi)
  ext="$HOME_DIR/state/live-pi-nested.pi-ext.ts"
  [ -f "$ext" ] || fail "pi $version: fm-spawn wrote no per-task extension: $launch"
  agent_dir="$TMP_ROOT/pi-agent"
  mkdir -p "$agent_dir"
  pi_run() {
    printf '{"providers":{"cap":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"capture-only","models":[{"id":"m"}]}}}\n' \
      "$CAPTURE_PORT" > "$PI_CAPTURE_AGENT_DIR/models.json"
    PI_CODING_AGENT_DIR="$PI_CAPTURE_AGENT_DIR" PI_OFFLINE=1 pi -p --no-session --provider cap --model m "$@" hi
  }
  export -f pi_run
  export PI_CAPTURE_AGENT_DIR=$agent_dir
  body=$(capture pi-nested-baseline "$NESTED_WT" bash -c 'pi_run "$@"' _)
  expect_markers "pi $version nested worktree without the spawn extension" "$body" yes yes
  body=$(capture pi-nested-spawn "$NESTED_WT" bash -c 'pi_run "$@"' _ -e "$ext")
  expect_markers "pi $version nested worktree with the spawn extension" "$body" no yes
  body=$(capture pi-outside "$OUTSIDE_WT" bash -c 'pi_run "$@"' _)
  expect_markers "pi $version worktree outside the home" "$body" no yes
  body=$(capture pi-home "$HOME_DIR" bash -c 'pi_run "$@"' _)
  expect_markers "pi $version session whose cwd is the home" "$body" yes no
  pass "pi $version: a nested worker's first request drops the home contract, keeps the project's, and a home session keeps its own"
  CHECKED=$((CHECKED + 1))
}

run_claude
run_pi
[ "$CHECKED" -gt 0 ] || { printf 'skip: live: neither claude nor pi is installed\n'; exit 0; }
printf '# fm-nested-home-context live guard checked %s harness(es)\n' "$CHECKED"
