#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-resolve.sh (real jq, real curl, real quota-axi)
# against a local capture server standing in for api.typesafe.ai.
set -u
WT=${WT:?}; EV=${EV:?}
TOOL="$WT/bin/fm-dispatch-resolve.sh"
T=$(mktemp -d /tmp/fm-dr-live.XXXXXX)
mkdir -p "$T/home/config" "$T/bin"
ln -s "$EV/curl-redirect.sh" "$T/bin/curl"
export CAPTURE_LOG="$T/wire.jsonl" CAPTURE_MODE="$T/mode" CURL_ARGV_LOG="$T/curl-argv" CAPTURE_PORT=$(( 20000 + RANDOM % 20000 ))
: > "$CAPTURE_LOG"; echo ok > "$CAPTURE_MODE"
python3 "$EV/capture_server.py" "$CAPTURE_PORT" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.5
cat > "$T/home/config/crew-dispatch.json" <<'JSON'
{ "rules": [
  { "when": "New feature work on the app.", "use": { "harness": "claude", "model": "opus", "effort": "high" } },
  { "when": "Bounded UI polish in an existing panel.", "use": [ { "harness": "claude", "model": "sonnet", "effort": "high" }, { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" } ] },
  { "when": "Genuinely very difficult design or planning work.", "approval": "captain", "use": { "harness": "claude", "model": "opus", "effort": "xhigh" } }
] }
JSON
BRIEF="$T/brief.md"
cat > "$BRIEF" <<'MD'
# Task
## Captain's intent
Polish the export panel in LatticeCAD for customer AcmeAerospace: the PRIVATE-CAD-PART-7731 bracket preview clips.
Specs at https://cad.acme.invalid/parts/7731 and /home/captain/cad/secret-bracket.step, owner jane.doe@acme.invalid.
Token ghp_LIVEPRIVATETOKEN0123456789abcdefXYZ.

Dispatch summary: PRIVATE-BRIEF-LINE-SUMMARY for LatticeCAD bracket.

# Definition of done
Delivery contract: mode=no-mistakes
MD
SENTINELS='LatticeCAD AcmeAerospace PRIVATE-CAD-PART-7731 cad.acme.invalid secret-bracket.step jane.doe ghp_LIVEPRIVATETOKEN PRIVATE-BRIEF-LINE-SUMMARY Captain Polish export'
KEY='live-key-5e1b-never-on-argv-or-body'
n=0
run() {  # <title> <mode> <args...>
  local title=$1 mode=$2; shift 2
  n=$((n+1)); echo "$mode" > "$CAPTURE_MODE"
  local before; before=$(wc -l < "$CAPTURE_LOG")
  echo "================================================================"
  echo "## [$n] $title"
  printf '$ fm-dispatch-resolve.sh'; printf ' %q' "$@"; echo
  PATH="$T/bin:$PATH" FM_HOME="$T/home" "$TOOL" "$@" > "$T/out" 2> "$T/err"; local code=$?
  echo "exit=$code"; echo "--- stdout"; cat "$T/out"; echo "--- stderr"; cat "$T/err"
  local after; after=$(wc -l < "$CAPTURE_LOG")
  echo "--- requests received by the local api.typesafe.ai stand-in: $((after-before))"
  if [ "$after" -gt "$before" ]; then
    local rec; rec=$(tail -n1 "$CAPTURE_LOG")
    echo "--- wire state (exact .state of the POST body):"; jq -r '.body | fromjson | .state' <<<"$rec"
    echo "--- wire top-level keys: $(jq -c '.body | fromjson | keys' <<<"$rec")   task keys: $(jq -c '.body | fromjson | .state.task | keys' <<<"$rec")"
    echo "--- Authorization header on the wire matches key: $(jq -r --arg k "$KEY" '.headers.Authorization == ("Bearer " + $k)' <<<"$rec")"
    local leaked=''
    for s in $SENTINELS; do jq -r .body <<<"$rec" | grep -qF -- "$s" && leaked="$leaked $s"; done
    echo "--- private brief sentinels found in wire body: ${leaked:-none}"
    grep -qF -- "$KEY" "$CURL_ARGV_LOG" && echo "--- KEY ON CURL ARGV: yes" || echo "--- key on curl argv: no"
    jq -r .body <<<"$rec" | grep -qF -- "$KEY" && echo "--- KEY IN BODY: yes" || echo "--- key in body: no"
  fi
}
export TYPESAFE_API_KEY=$KEY
run "Private brief + generic summary: only allow-listed state leaves" ok "$BRIEF" --summary "Bounded UI polish in an existing panel"
run "Adversarial summary: URL, path, email, token, code span, dotted file, snake_case" ok "$BRIEF" --summary 'Bounded UI polish at https://cad.acme.invalid/x in /home/captain/cad for jane.doe@acme.invalid using ghp_LIVEPRIVATETOKEN0123456789abcdefXYZ fix `renderPreview()` in panel.tsx'
run "Reviewer example: snake_case identifier redacted" ok "$BRIEF" --summary 'Refactor export_step_file in LatticeBracket for AcmeCorp'
run "No --summary (brief still has a Dispatch summary: line): escalate, no request" ok "$BRIEF"
run "Summary that is entirely private tokens: escalate, no request" ok "$BRIEF" --summary 'https://cad.acme.invalid/x /home/captain/secret.step `code`'
run "Removed --project flag is rejected" ok "$BRIEF" --project LatticeCAD --summary "Bounded UI polish in an existing panel"
run "Error after send (HTTP 500): sent line still shown" 500 "$BRIEF" --summary "Difficult diagnosis across components"
run "Error after send (HTTP 429): sent line still shown" 429 "$BRIEF" --summary "Difficult diagnosis across components"
echo stop > "$CAPTURE_MODE"; kill $SRV; wait $SRV 2>/dev/null
run "Transport failure after send (endpoint down): sent line still shown" ok "$BRIEF" --summary "Difficult diagnosis across components"
unset TYPESAFE_API_KEY
python3 "$EV/capture_server.py" "$CAPTURE_PORT" & SRV=$!; sleep 0.5
run "No key: tool is off, no request" ok "$BRIEF" --summary "Bounded UI polish in an existing panel"
