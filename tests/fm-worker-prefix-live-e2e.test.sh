#!/usr/bin/env bash
# Live guard: the worker prompt-prefix cut (docs/configuration.md "Worker
# prompt prefix") must actually shrink the installed harness's first model
# request for a ship worker of Firstmate's own repository.
#
# It spends no model tokens. Each harness is pointed at a local server that
# records the request body and answers with an error, so the assertions read
# exactly what the real binary would have sent. The launch material under test
# is what the real bin/fm-spawn.sh generates (Claude's --settings JSON and
# auto-memory switch, Pi's --no-skills and --skill arguments), produced through
# a fake tmux pane. Every cut is first shown present without that material, so
# a harness that stops sending a tool, a skill description or the memory index
# by itself cannot turn this into a vacuous pass.
# Claude runs in print mode, whose tool set can differ from an interactive
# worker's, so a cut tool absent from the baseline is reported rather than
# asserted, and at least one cut tool must be present there.
#
# Default-on because it submits no prompt to a provider; FM_WORKER_PREFIX_LIVE=1
# (or FM_LIVE=1) makes an absent harness a failure, =0 turns the guard off.
# FM_WORKER_PREFIX_TURN_LIVE=1 (or FM_LIVE=1) also submits one short prompt on
# the operator's own Claude login in the worker's worktree with its settings,
# so the hooks fm-spawn installed run the real bin/fm-worker-prefix-check.sh,
# and fails unless the check read a numeric first-turn size from the real
# transcript by the time Claude exits; it spends tokens, so it stays opt-in.
# docs/verification/runtime-backends.md "Worker prompt prefix" records the
# dated results.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_WORKER_PREFIX_LIVE python3 jq node git
fm_pi_live_model

TMP_ROOT=$(fm_test_tmproot fm-worker-prefix-live)
trap fm_test_cleanup EXIT

REQUESTED=0
case "${FM_WORKER_PREFIX_LIVE:-}${FM_LIVE:-}" in *1*) REQUESTED=1 ;; esac
TURN=0
case "${FM_WORKER_PREFIX_TURN_LIVE:-}" in
1) TURN=1 ;;
0) ;;
*) [ "${FM_LIVE:-}" != 1 ] || TURN=1 ;;
esac

if [ "$REQUESTED" -eq 0 ] && ! command -v claude >/dev/null 2>&1 && ! command -v pi >/dev/null 2>&1; then
  printf 'skip: live: neither claude nor pi is installed\n'
  exit 0
fi

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

# The longest run of five or more plain words in a skill's description: text
# that survives JSON encoding unchanged and names that one skill.
SNIPPET_PY="$TMP_ROOT/snippet.py"
cat > "$SNIPPET_PY" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read().split("\n---", 1)[0]
m = re.search(r"^description:[ \t]*(.*?)(?=^[A-Za-z_-]+:|\Z)", text, re.S | re.M)
desc = " ".join(m.group(1).replace(">-", " ").split()) if m else ""
runs = re.findall(r"[A-Za-z]+(?: [A-Za-z]+){4,}", desc)
print(max(runs, key=len) if runs else "")
PY

HOME_DIR="$TMP_ROOT/home"
fm_test_spawn_home "$HOME_DIR" claude
# A worktree of Firstmate's own repository: the fixture code root runs this
# checkout's bin/ and skills through symlinks, so fm-spawn sees the worktree as
# a checkout of its own repository and applies every cut, auto-memory included.
FM_CODE_ROOT="$TMP_ROOT/firstmate"
FM_WT="$TMP_ROOT/pool/2/firstmate"
fm_git_init_commit "$FM_CODE_ROOT"
ln -s "$ROOT/bin" "$FM_CODE_ROOT/bin"
mkdir -p "$FM_CODE_ROOT/.agents" "$FM_CODE_ROOT/.claude"
ln -s "$ROOT/.agents/skills" "$FM_CODE_ROOT/.agents/skills"
ln -s "$ROOT/.agents/worker-skills.list" "$FM_CODE_ROOT/.agents/worker-skills.list"
ln -s ../.agents/skills "$FM_CODE_ROOT/.claude/skills"
git -C "$FM_CODE_ROOT" add -A && git -C "$FM_CODE_ROOT" -c user.name=t -c user.email=t@t commit -qm firstmate
fm_git_add_origin "$FM_CODE_ROOT" "$FM_CODE_ROOT.origin.git"
mkdir -p "$(dirname "$FM_WT")"
git -C "$FM_CODE_ROOT" worktree add --quiet -b wt-firstmate "$FM_WT"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")

# spawn_firstmate <id> <harness> [<spawn-args>...] runs the real fm-spawn for
# the Firstmate-repo worktree through the fake pane and echoes the launch.
spawn_firstmate() {
  local id=$1 harness=$2 log="$TMP_ROOT/$1.launch" out
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" PATH="$FAKEBIN_DIR:$PATH" ROOT=$FM_CODE_ROOT fm_test_run_spawn "$HOME_DIR" "$FM_WT" "$FAKEBIN_DIR" \
    "$id" "$FM_CODE_ROOT" --harness "$harness" --mode direct-push --yolo off "${@:3}") \
    || fail "fm-spawn $harness Firstmate-repo launch failed: $out"
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
  body=$(grep -l '"messages"' "$out"/[0-9]*.json 2>/dev/null | head -n 1)
  [ -n "$body" ] || fail "$label: the harness sent no model request ($(tail -n 3 "$out/stderr" | tr '\n' ' '))"
  printf '%s\n' "$body"
}

harness_present() {
  command -v "$1" >/dev/null 2>&1 && return 0
  [ "$REQUESTED" -eq 1 ] && fail "$1 was requested but is not installed"
  printf 'skip: live: %s absent\n' "$1"
  return 1
}

# check_skills <label> <baseline-body> <cut-body>: every kept repository
# skill's description reaches the cut request, no name-only one does, and at
# least one name-only description was in the baseline.
check_skills() {
  local label=$1 base=$2 cut=$3 class name snip shown=0
  while read -r class name; do
    [ -f "$ROOT/.agents/skills/$name/SKILL.md" ] || continue
    snip=$(python3 -I "$SNIPPET_PY" "$ROOT/.agents/skills/$name/SKILL.md")
    [ -n "$snip" ] || continue
    if [ "$class" = keep ]; then
      grep -qF "$snip" "$cut" || fail "$label: the kept skill $name lost its description"
    else
      ! grep -qF "$snip" "$cut" || fail "$label: the name-only skill $name still sent its description"
      ! grep -qF "$snip" "$base" || shown=$((shown + 1))
    fi
  done < <(grep -E '^(keep|name-only) ' "$ROOT/.agents/worker-skills.list")
  [ "$shown" -gt 0 ] || fail "$label: no name-only skill description was in the baseline request, so the skill cut proved nothing"
}

CHECKED=0

run_claude() {
  local launch settings version base cut tool cfg slug dir in_base=0 absent=''
  harness_present claude || return 0
  version=$(claude --version 2>/dev/null | head -n 1)
  cfg="$TMP_ROOT/claude-config"
  mkdir -p "$cfg"
  jq -n --arg f "$(cd "$FM_WT" && pwd -P)" --arg r "$(cd "$FM_CODE_ROOT" && pwd -P)" '
    {hasTrustDialogAccepted: true} as $e | {projects: {($f): $e, ($r): $e}}' > "$cfg/.claude.json"
  # Auto-memory lives under the repository's project directory; seed both the
  # worktree's and the code root's so either naming carries the marker.
  for dir in "$FM_WT" "$FM_CODE_ROOT"; do
    slug=$(cd "$dir" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
    mkdir -p "$cfg/projects/$slug/memory"
    printf -- '- [Marker](marker.md) - MEMORY_INDEX_MARKER\n' > "$cfg/projects/$slug/memory/MEMORY.md"
  done
  launch=$(spawn_firstmate live-claude-prefix claude)
  settings=$(printf '%s\n' "$launch" | sed -n "s/.* --settings '\([^']*\)'.*/\1/p" | head -n 1)
  printf '%s' "$settings" | jq -e '.skillOverrides and .disableArtifact' >/dev/null \
    || fail "claude $version: fm-spawn produced no worker prompt-prefix settings: $settings"
  assert_contains "$launch" "CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 " "claude $version: a Firstmate-repo worker launch kept auto-memory on"
  claude_run() {
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR="$CLAUDE_CAPTURE_CONFIG_DIR" \
      ANTHROPIC_API_KEY=sk-capture-only ANTHROPIC_BASE_URL="http://127.0.0.1:$CAPTURE_PORT" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      claude -p hi --max-turns 1 --model claude-haiku-4-5 "$@"
  }
  export -f claude_run
  export CLAUDE_CAPTURE_CONFIG_DIR=$cfg
  base=$(capture claude-baseline "$FM_WT" bash -c 'claude_run "$@"' _)
  cut=$(capture claude-cut "$FM_WT" env CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 bash -c 'claude_run "$@"' _ --settings "$settings")
  for tool in AskUserQuestion ScheduleWakeup ReportFindings ListAgents Artifact Workflow; do
    jq -e --arg t "$tool" 'any(.tools[]?; .name == $t)' "$cut" >/dev/null \
      && fail "claude $version: the cut request still carries the $tool tool"
    if jq -e --arg t "$tool" 'any(.tools[]?; .name == $t)' "$base" >/dev/null; then
      in_base=$((in_base + 1))
    else
      absent+=" $tool"
    fi
  done
  [ "$in_base" -gt 0 ] || fail "claude $version: no cut tool was in the baseline request, so the tool cut proved nothing"
  [ -z "$absent" ] || printf 'note: claude %s print mode sent none of:%s, even without the cut\n' "$version" "$absent"
  check_skills "claude $version" "$base" "$cut"
  grep -qF MEMORY_INDEX_MARKER "$base" || fail "claude $version: the seeded memory index was not in the baseline request"
  ! grep -qF MEMORY_INDEX_MARKER "$cut" || fail "claude $version: the cut request still carries the memory index"
  [ "$(wc -c < "$cut")" -lt "$(wc -c < "$base")" ] || fail "claude $version: the cut request is not smaller than the baseline"
  pass "claude $version: a Firstmate-repo worker's first request drops the cut tools, the name-only skill descriptions and auto-memory"
  CHECKED=$((CHECKED + 1))
  [ "$TURN" -eq 1 ] || { printf 'skip: live: first-turn check is opt-in; set FM_WORKER_PREFIX_TURN_LIVE=1 to run\n'; return 0; }
  run_claude_turn "$version" "$settings"
}

# run_claude_turn <version> <settings>: one real prompt on the operator's own
# login in the worker's worktree with the worker's settings. The hooks fm-spawn
# wrote there run the real first-turn check, which must have read a numeric
# size from the transcript Claude wrote by the time Claude exits. The capture
# runs fired those hooks too, so their marker and log lines are cleared first.
run_claude_turn() {
  local version=$1 settings=$2 state line
  state=$(cd "$HOME_DIR/state" && pwd -P) || fail "claude $version: the worker's state directory is gone"
  rm -f "$state/live-claude-prefix.prefix-checked" "$state/worker-prefix/log"
  (cd "$FM_WT" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    timeout 300 claude -p 'Reply with exactly the word OK. Do not use any tools.' --max-turns 1 \
    --model claude-haiku-4-5 --settings "$settings" >"$TMP_ROOT/turn.out" 2>&1 </dev/null) \
    || fail "claude $version: the prompt failed: $(tail -n 3 "$TMP_ROOT/turn.out" | tr '\n' ' ')"
  [ -e "$state/live-claude-prefix.prefix-checked" ] || fail "claude $version: the worker's hooks reached no first-turn verdict by exit"
  line=$(tail -n 1 "$state/worker-prefix/log" 2>/dev/null)
  case "$line" in
  *" prefix="[0-9]*" verdict=within" | *" prefix="[0-9]*" verdict=over") ;;
  *) fail "claude $version: the first-turn check did not read a size from the real transcript: ${line:-no log line}" ;;
  esac
  printf 'note: claude %s first turn: %s\n' "$version" "$line"
  pass "claude $version: the worker's installed hooks check the first turn's usage from the real transcript"
}

run_pi() {
  local launch version base cut agent_dir dir
  local -a skill_args=()
  harness_present pi || return 0
  version=$(pi --version 2>/dev/null | head -n 1)
  pi --help 2>&1 | grep -Eq -- '(^|[[:space:]])--no-skills([^[:alnum:]_-]|$)' \
    || fail "pi $version: --help no longer lists --no-skills"
  pi --help 2>&1 | grep -Eq -- '(^|[[:space:]])--skill([[:space:]=]|$)' \
    || fail "pi $version: --help no longer lists --skill"
  # The real Pi help is the probe fm-spawn runs, so the fake pane needs the
  # real executable; only tmux is faked.
  launch=$(spawn_firstmate live-pi-prefix pi --model "$PI_LIVE_MODEL")
  assert_contains "$launch" " --no-skills" "pi $version: fm-spawn produced no --no-skills for a worker"
  while IFS= read -r dir; do
    skill_args+=(--skill "$dir")
  done < <(printf '%s\n' "$launch" | grep -oE -- "--skill '[^']*'" | sed "s/^--skill '//; s/'\$//")
  [ "${#skill_args[@]}" -gt 0 ] || fail "pi $version: fm-spawn loaded no kept skill: $launch"
  agent_dir="$TMP_ROOT/pi-agent"
  mkdir -p "$agent_dir"
  pi_run() {
    printf '{"providers":{"cap":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"capture-only","models":[{"id":"m"}]}}}\n' \
      "$CAPTURE_PORT" > "$PI_CAPTURE_AGENT_DIR/models.json"
    PI_CODING_AGENT_DIR="$PI_CAPTURE_AGENT_DIR" PI_OFFLINE=1 pi -p --no-session --provider cap --model m "$@" hi
  }
  export -f pi_run
  export PI_CAPTURE_AGENT_DIR=$agent_dir
  base=$(capture pi-baseline "$FM_WT" bash -c 'pi_run "$@"' _)
  cut=$(capture pi-cut "$FM_WT" bash -c 'pi_run "$@"' _ --no-skills "${skill_args[@]}")
  check_skills "pi $version" "$base" "$cut"
  [ "$(wc -c < "$cut")" -lt "$(wc -c < "$base")" ] || fail "pi $version: the cut request is not smaller than the baseline"
  pass "pi $version: a worker's first request keeps only the kept skills"
  CHECKED=$((CHECKED + 1))
}

run_claude
run_pi
[ "$CHECKED" -gt 0 ] || { printf 'skip: live: neither claude nor pi is installed\n'; exit 0; }
printf '# fm-worker-prefix live guard checked %s harness(es)\n' "$CHECKED"
