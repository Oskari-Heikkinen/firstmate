#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-resolve.sh from the CLI in an isolated FM_HOME.
L=/tmp/fm-dr-live.WTGh; W=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M39F2FRP14YDWXMJBZ4M8YNX
export FM_HOME=$L/home CAP=$L/cap PATH=$L/bin:$PATH
step() { echo; echo "=================== $1"; }
show() { echo "$ $*"; "$@"; echo "[exit $?]"; }
last_req() { ls -t $CAP/* 2>/dev/null | head -1; }
reqcount() { ls $CAP | wc -l; }
T=$W/bin/fm-dispatch-resolve.sh
echo "--- brief (private content):"; cat $L/brief.md
step "S1 off: no TYPESAFE_API_KEY"
before=$(reqcount); show $T $L/brief.md --summary "A simple bug fix with a stated root cause"; echo "requests sent: $(($(reqcount)-before))"
step "S2 clear path: private brief + generic summary (canned Jev answer, real quota-axi)"
before=$(reqcount); TYPESAFE_API_KEY=fm-lab-invalid-key LIVE_CANNED=$L/canned-clear.json show $T $L/brief.md --summary "A simple bug fix with a stated root cause in an exporter"
echo "requests sent: $(($(reqcount)-before))"; echo "--- exact request body:"; jq . $(last_req)
echo "--- private brief strings found in request body:"; for s in PRIVATE-CAD-SPEC Lattice AcmeCustomer captain lattice_bracket acme.invalid PN-4471 ghp_ eng@ PRIVATE-BRIEF-LINE-SUMMARY fillets; do grep -q -- "$s" $(last_req) && echo "LEAK: $s"; done; echo "(none above = no leak)"
step "S3 adversarial summary: identifiers, URL, path, email, secrets, long ids"
TYPESAFE_API_KEY=fm-lab-invalid-key LIVE_CANNED=$L/canned-clear.json show $T $L/brief.md --summary 'Fix `export_fillets()` in export_step_file per https://cad.acme.invalid/p and ~/cad/lattice.step, mail eng@acme.invalid, TOKEN=abc ghp_PRIVATETOKEN0123 sk-live-9 AKIAXYZ id 0123456789abcdef bug fix'
echo "--- state sent:"; jq -c .state $(last_req)
step "S4a no --summary: escalate, no request"
before=$(reqcount); TYPESAFE_API_KEY=fm-lab-invalid-key show $T $L/brief.md; echo "requests sent: $(($(reqcount)-before))"
step "S4b summary that is only private tokens: escalate, no request"
before=$(reqcount); TYPESAFE_API_KEY=fm-lab-invalid-key show $T $L/brief.md --summary 'https://cad.acme.invalid/x /home/captain/a.step eng@acme.invalid'; echo "requests sent: $(($(reqcount)-before))"
step "S5 removed --project flag is rejected"
before=$(reqcount); TYPESAFE_API_KEY=fm-lab-invalid-key show $T $L/brief.md --project AcmeLattice --summary "bug fix"; echo "requests sent: $(($(reqcount)-before))"
step "S6a error after send (canned HTTP 500) prints sent: line"
TYPESAFE_API_KEY=fm-lab-invalid-key LIVE_CANNED=$L/canned-500.json LIVE_HTTP=500 show $T $L/brief.md --summary "A simple bug fix with a stated root cause"
step "S6b error after send against the REAL api.typesafe.ai with an invalid key"
TYPESAFE_API_KEY=fm-lab-invalid-key show $T $L/brief.md --summary "A simple bug fix with a stated root cause"
echo "--- exact request body sent to api.typesafe.ai:"; jq -c . $(last_req)
step "S7 direct-push brief sends mode=direct-push"
printf '%s\n' '# Task' 'Private PRIVATE-DP-DETAIL here.' 'Delivery contract: mode=direct-push' > $L/dp.md
TYPESAFE_API_KEY=fm-lab-invalid-key LIVE_CANNED=$L/canned-clear.json show $T $L/dp.md --summary "A small bug fix"
echo "--- state sent:"; jq -c .state $(last_req)
step "S8 --help documents --summary"
show $T --help | sed -n 1,12p
