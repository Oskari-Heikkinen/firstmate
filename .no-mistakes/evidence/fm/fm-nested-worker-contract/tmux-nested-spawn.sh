#!/usr/bin/env bash
# Live proof: the REAL bin/fm-spawn.sh spawns a REAL claude ship worker into a
# nested in-project Treehouse worktree (<home>/projects/proj/.treehouse/...) on a
# private, throwaway tmux server (tmux -L <socket>); the Herdr lab helper could
# not provision on this host because no default Herdr session is running. Claude's API is pointed at a local capture
# server (no tokens spent), so we read exactly what the worker sent.
# Usage: tmux-nested-spawn.sh <fm-root> <label> <out-dir> [harness]
set -u
FMROOT=$1 LABEL=$2 OUT=$3 HARNESS=${4:-claude}
mkdir -p "$OUT"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION CLAUDECODE CLAUDE_CODE_ENTRYPOINT
TMP=$(mktemp -d "$(cd /tmp && pwd -P)/fm-nested-lab.XXXXXX")
SOCK="fmnest-$LABEL-$$"
CAPPID=
cleanup() {
  [ -n "$CAPPID" ] && kill "$CAPPID" 2>/dev/null
  tmux -L "$SOCK" kill-server 2>/dev/null; echo "private tmux server $SOCK killed" >> "$OUT/transcript.txt"
  rm -rf "$TMP"
}
trap cleanup EXIT
echo "private tmux socket: $SOCK" | tee "$OUT/transcript.txt"

H="$TMP/home"; P="$H/projects/proj"; [ "${TH_ROOT:-}" = OUTSIDE ] && TH_ROOT="$TMP/outside-pool"
mkdir -p "$H/data" "$H/projects" "$H/state" "$H/config" "$P"
touch "$H/state/.last-watcher-beat"
echo "$HARNESS" > "$H/config/crew-harness"
printf '@AGENTS.md\n' > "$H/CLAUDE.md"
printf 'HOME_CONTRACT_MARKER firstmate supervisor contract\n' > "$H/AGENTS.md"
git -C "$P" init -q
printf 'PROJECT_MARKER project rules\n' > "$P/CLAUDE.md"; cp "$P/CLAUDE.md" "$P/AGENTS.md"
printf 'max_trees = 4\nroot = "%s"\n' "${TH_ROOT:-.}" > "$P/treehouse.toml"
printf '.treehouse/\n' > "$P/.gitignore"
git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t.invalid commit -qm init
git clone -q --bare "$P" "$P.origin.git" && git -C "$P" remote add origin "file://$P.origin.git"
mkdir -p "$H/data/nest1"
printf '# Task\n## Captain'"'"'s intent\nSay hi.\n\n## Firstmate spec\nReply with one word.\n' > "$H/data/nest1/brief.md"

# capture server
CAP="$TMP/cap"; mkdir -p "$CAP"
python3 - "$CAP" <<'PY' &
import http.server, itertools, json, os, sys
out=sys.argv[1]; seq=itertools.count()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b=self.rfile.read(int(self.headers.get("content-length") or 0))
        open(os.path.join(out,"%03d%s.json"%(next(seq),self.path.split("?")[0].replace("/","_"))),"wb").write(b)
        r=json.dumps({"type":"error","error":{"type":"invalid_request_error","message":"capture only"}}).encode()
        self.send_response(400); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(r))); self.end_headers(); self.wfile.write(r)
    def do_GET(self):
        self.send_response(404); self.send_header("content-length","0"); self.end_headers()
    def log_message(self,*a): pass
s=http.server.ThreadingHTTPServer(("127.0.0.1",0),H)
open(os.path.join(out,"port"),"w").write(str(s.server_address[1])); s.serve_forever()
PY
CAPPID=$!
for _ in $(seq 50); do [ -s "$CAP/port" ] && break; sleep 0.1; done
PORT=$(cat "$CAP/port")
KEY=sk-ant-capture-only-0123456789abcdefghij
CFG="$TMP/claude-config"; mkdir -p "$CFG"
jq -n --arg k "${KEY: -20}" '{hasCompletedOnboarding:true, theme:"dark", bypassPermissionsModeAccepted:true, customApiKeyResponses:{approved:[$k],rejected:[]}}' > "$CFG/.claude.json"
printf '{"skipDangerousModePermissionPrompt":true}\n' > "$CFG/settings.json"
PIDIR="$TMP/pi-agent"; mkdir -p "$PIDIR"
printf '{"providers":{"cap":{"baseUrl":"http://127.0.0.1:%s/v1","api":"openai-completions","apiKey":"capture-only","models":[{"id":"m"}]}}}\n' "$PORT" > "$PIDIR/models.json"
printf '{"defaultProvider":"cap","defaultModel":"m"}\n' > "$PIDIR/settings.json"

env CLAUDE_CONFIG_DIR="$CFG" ANTHROPIC_API_KEY="$KEY" ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 PI_CODING_AGENT_DIR="$PIDIR" PI_OFFLINE=1 \
  tmux -L "$SOCK" -f /dev/null new-session -d -s fmlab -c "$TMP" -x 200 -y 50
SOCKPATH=$(tmux -L "$SOCK" display -p '#{socket_path}'); SPID=$(tmux -L "$SOCK" display -p '#{pid}')
LAUNCHER_PANE=$(tmux -L "$SOCK" display -p -t fmlab '#{pane_id}')
echo "fm-root: $FMROOT ($(git -C "$FMROOT" rev-parse --short HEAD 2>/dev/null || cat "$FMROOT/.rev" 2>/dev/null))" | tee -a "$OUT/transcript.txt"
echo "home: $H  harness: $HARNESS" | tee -a "$OUT/transcript.txt"
env CLAUDE_CONFIG_DIR="$CFG" ANTHROPIC_API_KEY="$KEY" ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 PI_CODING_AGENT_DIR="$PIDIR" PI_OFFLINE=1 \
  TMUX="$SOCKPATH,$SPID,0" TMUX_PANE="$LAUNCHER_PANE" \
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$FMROOT" \
  "$FMROOT/bin/fm-spawn.sh" nest1 "$P" --harness "$HARNESS" --mode no-mistakes --yolo off --backend tmux \
  >"$OUT/spawn.out" 2>"$OUT/spawn.err"
echo "fm-spawn rc=$?" | tee -a "$OUT/transcript.txt"
cat "$H/state/nest1.meta" 2>/dev/null | tee "$OUT/meta.txt" | tee -a "$OUT/transcript.txt"
for _ in $(seq 30); do ls /tmp/fm-nest1+*/launch*.sh >/dev/null 2>&1 && break; sleep 1; done; cp /tmp/fm-nest1+*/launch*.sh "$OUT/launch.sh" 2>/dev/null
PANE=$(sed -n 's/^window=//p' "$H/state/nest1.meta" | head -1)
WT=$(sed -n 's/^worktree=//p' "$H/state/nest1.meta" | head -1)
echo "worktree: $WT" | tee -a "$OUT/transcript.txt"
# APPROVE_EXTERNAL=1: answer Claude's external-import consent prompt with
# "Yes", the state the fleet's own claude config carries after first approval.
if [ "${APPROVE_EXTERNAL:-0}" = 1 ]; then
  for _ in $(seq 60); do
    tmux -L "$SOCK" capture-pane -p -t "$PANE" | grep -q "Allow external CLAUDE.md" && {
      tmux -L "$SOCK" capture-pane -p -t "$PANE" > "$OUT/pane-consent-prompt.txt"
      tmux -L "$SOCK" send-keys -t "$PANE" Down; sleep 0.5; tmux -L "$SOCK" send-keys -t "$PANE" Enter
      echo "answered external-import prompt: Yes" | tee -a "$OUT/transcript.txt"; break; }
    sleep 1
  done
fi
# wait for a model request
for _ in $(seq 60); do ls "$CAP"/0*.json >/dev/null 2>&1 && sleep 3 && break; sleep 1; done
sleep 3
tmux -L "$SOCK" capture-pane -p -t "$PANE" -S -80 > "$OUT/pane.txt" 2>&1 || true
cp "$CAP"/0*.json "$OUT/" 2>/dev/null
cp "$H/state/nest1.pi-ext.ts" "$OUT/" 2>/dev/null
grep -o "\-\-settings '[^']*'" "$OUT/spawn.out" "$OUT/spawn.err" "$H/state/nest1.launch" 2>/dev/null | head -2 >> "$OUT/transcript.txt"
{
  echo "--- captured requests ---"
  for f in "$CAP"/0*.json; do [ -f "$f" ] || continue
    echo "$(basename "$f"): HOME_CONTRACT_MARKER=$(grep -o HOME_CONTRACT_MARKER "$f" | wc -l) PROJECT_MARKER=$(grep -o PROJECT_MARKER "$f" | wc -l) bytes=$(wc -c <"$f")"
  done
  echo "--- pane shows external-include consent prompt? ---"
  grep -iE "external|import" "$OUT/pane.txt" | head -5 || true
  echo "(end)"
} | tee -a "$OUT/transcript.txt"
