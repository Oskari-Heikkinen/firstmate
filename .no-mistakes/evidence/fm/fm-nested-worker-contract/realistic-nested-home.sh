#!/usr/bin/env bash
# Realistic nested-home measurement: a throwaway copy of this firstmate repo at
# the change head acts as the home (real AGENTS.md, CLAUDE.md, .claude/skills),
# its own bin/fm-spawn.sh generates the launch for a worker nested at
# <home>/projects/proj/.treehouse/pool/1/proj, and the installed claude and pi
# send their first request to a local capture server (no provider tokens).
set -u
WT=${1:?worktree}
T=$(mktemp -d /tmp/fm-nested-real.XXXXXX); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
HOME_DIR="$T/home"; mkdir -p "$HOME_DIR"
git -C "$WT" archive HEAD | tar -x -C "$HOME_DIR"
ROOT=$HOME_DIR
. "$WT/tests/fixtures.sh"
fm_test_spawn_home "$HOME_DIR" claude
PROJ="$HOME_DIR/projects/proj"; NESTED="$PROJ/.treehouse/pool/1/proj"
fm_git_init_commit "$PROJ"
printf 'PROJECT_MARKER project rules\n' > "$PROJ/AGENTS.md"; printf '@AGENTS.md\n' > "$PROJ/CLAUDE.md"
printf '.treehouse/\n' > "$PROJ/.gitignore"
git -C "$PROJ" add -A && git -C "$PROJ" -c user.name=t -c user.email=t@t commit -qm p
fm_git_add_origin "$PROJ" "$PROJ.origin.git"
mkdir -p "$(dirname "$NESTED")"; git -C "$PROJ" worktree add -q -b wt "$NESTED"
FAKE=$(fm_test_make_spawn_fakebin "$T/fake")
cat > "$FAKE/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --help ] && printf '%s\n' 'Pi 0.85.1' 'Options: --help --tui-mode <mode>'
exit 0
SH
chmod +x "$FAKE/pi"
spawn() { fm_test_spawn_brief "$HOME_DIR" "$1"; printf '%s\n' "$2" > "$HOME_DIR/config/crew-harness"; : > "$T/$1.log"
  FM_FAKE_LAUNCH_LOG="$T/$1.log" fm_test_run_spawn "$HOME_DIR" "$NESTED" "$FAKE" "$1" "$PROJ" --harness "$2" --mode no-mistakes --yolo off >/dev/null || { echo "spawn $2 failed"; exit 1; }; }
spawn real-claude claude
spawn real-pi pi
SETTINGS=$(sed -n "s/.* --settings '\([^']*\)'.*/\1/p" "$T/real-claude.log" | head -n1)
echo "== fm-spawn claude --settings for nested worker (home=$HOME_DIR):"; printf '%s' "$SETTINGS" | jq .
PY="$T/cap.py"; cat > "$PY" <<'PY'
import http.server, itertools, json, os, sys
out=sys.argv[1]; seq=itertools.count()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b=self.rfile.read(int(self.headers.get("content-length") or 0))
        open(os.path.join(out,"%03d.json"%next(seq)),"wb").write(b)
        r=json.dumps({"type":"error","error":{"type":"invalid_request_error","message":"capture"}}).encode()
        self.send_response(400); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(r))); self.end_headers(); self.wfile.write(r)
    def do_GET(self): self.send_response(404); self.send_header("content-length","0"); self.end_headers()
    def log_message(self,*a): pass
s=http.server.ThreadingHTTPServer(("127.0.0.1",0),H); open(os.path.join(out,"port"),"w").write(str(s.server_address[1])); s.serve_forever()
PY
CFG="$T/claude-config"; mkdir -p "$CFG"
jq -n --arg p "$PROJ" --arg n "$NESTED" --arg h "$HOME_DIR" '{hasTrustDialogAccepted:true,hasClaudeMdExternalIncludesApproved:true,hasClaudeMdExternalIncludesWarningShown:true} as $e | {projects:{($p):$e,($n):$e,($h):$e}}' > "$CFG/.claude.json"
PIDIR="$T/pi-agent"; mkdir -p "$PIDIR"
cap() { local label=$1 out="$T/cap/$1" pid port i=0; shift; mkdir -p "$out"; python3 "$PY" "$out" & pid=$!
  while [ ! -s "$out/port" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; port=$(cat "$out/port")
  (cd "$NESTED" && PORT=$port timeout 90 "$@" >/dev/null 2>"$out/err" </dev/null) || true; kill $pid; wait $pid 2>/dev/null
  f=$(grep -l '"messages"' "$out"/[0-9]*.json | head -n1); [ -n "$f" ] || { echo "$label: no request"; return; }
  python3 - "$f" "$label" <<'PY'
import json,sys
b=json.load(open(sys.argv[1])); s=json.dumps(b)
contract=s.count("This is the supervisor contract for primary firstmates")
skills=sum(1 for k in ("bootstrap-diagnostics","captain-hold-lifecycle","stuck-crewmate-recovery") if k in s)
print(f"{sys.argv[2]:<34} request_bytes={len(s.encode()):>7}  home_contract_hits={contract}  project_rules_hits={s.count('PROJECT_MARKER')}  firstmate_skill_names_found={skills}/3")
PY
}
crun() { env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CONFIG_DIR="$CFG" ANTHROPIC_API_KEY=sk-capture ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude -p hi --max-turns 1 --model claude-haiku-4-5 "$@"; }
prun() { printf '{"providers":{"cap":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"x","models":[{"id":"m"}]}}}\n' "$PORT" > "$PIDIR/models.json"; PI_CODING_AGENT_DIR="$PIDIR" PI_OFFLINE=1 pi -p --no-session --provider cap --model m "$@" hi; }
export -f crun prun; export CFG PIDIR
echo "== first model request from a worker nested in the home ($(claude --version | head -n1); pi $(pi --version))"
cap "claude nested, pre-change launch" bash -c 'crun'
cap "claude nested, fm-spawn launch" bash -c 'crun --settings "$1"' _ "$SETTINGS"
cap "pi nested, no filter" bash -c 'prun'
cap "pi nested, fm-spawn extension" bash -c 'prun -e "$1"' _ "$HOME_DIR/state/real-pi.pi-ext.ts"
