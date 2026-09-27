#!/usr/bin/env bash
# Behavioral contracts for shared observations and precommissioned handoffs.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-observe-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/data"
fm_test_track_procevent_home "$H"
obs() { FM_HOME="$H" "$ROOT/bin/fm-procevent-observe.sh" "$@"; }
pe() { FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" "$@"; }
make_spec() {
  jq -n --arg key "$1" --arg kind "${2:-receipt}" --argjson deadline "$(( $(date +%s) + ${3:-120} ))" \
    '{schema:"fm-observe-v1", identity:{kind:$kind,request:$key},receipt:($key+".json"),deadline:$deadline,max_age:60,interval:1}' > "$TMP_ROOT/spec.json"
}
evidence() {
  jq -n --slurpfile s "$TMP_ROOT/spec.json" --arg status "$1" --arg rev "${2:-1}" --argjson now "$(date +%s)" \
    '{schema:"fm-evidence-v1",identity:$s[0].identity,status:$status,revision:$rev,observed_at:$now,verified:true,terminal:true}' > "$H/$(jq -r .receipt "$TMP_ROOT/spec.json")"
}
round() { pe start "$SID" >/dev/null; }
status() { obs snapshot "$SID" | jq -r .status; }
refuse() { if "$@" >"$TMP_ROOT/refuse.out" 2>&1; then fail "expected refusal: $*"; fi; }

make_spec shared
SID=$(obs arm "$TMP_ROOT/spec.json")
[ "$(obs arm "$TMP_ROOT/spec.json")" = "$SID" ] || fail 'identical dependency did not share source'
obs subscribe "$SID" alpha gen1
obs subscribe "$SID" beta gen2
round
[ "$(status)" = unavailable ] || fail 'missing receipt did not notify'
[ "$(obs pending "$SID" alpha gen1 | jq length)" = 1 ] || fail 'first subscriber lost event'
[ "$(obs pending "$SID" beta gen2 | jq length)" = 1 ] || fail 'second subscriber lost event'
obs ack "$SID" alpha gen1 1
[ "$(obs pending "$SID" alpha gen1 | jq length)" = 0 ] || fail 'ack did not advance cursor'
refuse obs pending "$SID" alpha other
refuse obs subscribe "$SID" alpha other
refuse obs ack "$SID" beta gen2 10
# A poll with unchanged unavailable evidence blocks, without another notification.
pe start "$SID" > "$TMP_ROOT/unchanged.out" & runner=$!
sleep 2
[ "$(obs snapshot "$SID" | jq '.events|length')" = 1 ] || fail 'unchanged poll emitted event'
evidence ready 2
wait "$runner"
[ "$(status)" = ready ] || fail 'recovered receipt not ready'
obs pending "$SID" beta gen2 | jq -e 'length==2 and .[1].recovery' >/dev/null || fail 'lost recovery fanout'
[ "$(obs pending "$SID" alpha gen1 | jq length)" = 1 ] || fail 'subscriber cursor affected another subscriber'
# Changed bytes at the same revision are contradictory, never a new green.
evidence red 2
round
[ "$(status)" = unavailable ] || fail 'revision mutation was trusted'
evidence red 3; round
[ "$(status)" = red ] || fail 'red outcome lost'
evidence ready 4
# Lose the first stdout before generic capture: journal must replay on restart.
obs run "$SID" > "$TMP_ROOT/lost-stdout"
round
jq -e '.status=="ready"' "$TMP_ROOT/lost-stdout" >/dev/null || fail 'crash fixture did not reach ready'
[ "$(obs snapshot "$SID" | jq '.events|length')" = 5 ] || fail 'restart duplicated or lost journal transition'
obs subscribe "$SID" late gen3
[ "$(obs pending "$SID" late gen3 | jq length)" = 5 ] || fail 'late subscriber lost retained history'
pe retire "$SID" >/dev/null
pass 'one dependency, durable fanout/cursors, unchanged suppression and recovery across lost capture'

# Required checks bind to the exact head and attempt; missing or unrelated green
# (including a previous revert) cannot prove ancestry/coverage of this head.
make_spec ci main-ci
jq '.identity += {repo:"owner/project",branch:"main",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",attempt:2,jobs:["test","lint"]}' "$TMP_ROOT/spec.json" > "$TMP_ROOT/ci-spec.json"
mv "$TMP_ROOT/ci-spec.json" "$TMP_ROOT/spec.json"
SID=$(obs arm "$TMP_ROOT/spec.json")
ci_evidence() {
  evidence ready "$1"
  jq --arg head "$2" --argjson attempt "$3" --argjson jobs "$4" '. + {head:$head,attempt:$attempt,jobs:$jobs}' "$H/ci.json" > "$TMP_ROOT/ci.json"
  mv "$TMP_ROOT/ci.json" "$H/ci.json"
}
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ci_evidence 1 "$HEAD_SHA" 2 '[{"name":"test","status":"success"}]'; round
[ "$(status)" = unavailable ] || fail 'missing required job became green'
ci_evidence 2 "$HEAD_SHA" 2 '[{"name":"test","status":"failure"},{"name":"lint","status":"success"}]'; round
[ "$(status)" = red ] || fail 'failed required check not red'
ci_evidence 3 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2 '[{"name":"test","status":"success"},{"name":"lint","status":"success"}]'; round
[ "$(status)" = unavailable ] || fail 'earlier revert/unrelated head became green without coverage proof'
ci_evidence 4 "$HEAD_SHA" 2 '[{"name":"test","status":"pending"},{"name":"lint","status":"success"}]'; round
[ "$(status)" = pending ] || fail 'pending check treated as green'
ci_evidence 5 "$HEAD_SHA" 1 '[{"name":"test","status":"success"},{"name":"lint","status":"success"}]'; round
[ "$(status)" = unavailable ] || fail 'old attempt became green'
ci_evidence 6 "$HEAD_SHA" 2 '[{"name":"test","status":"success"},{"name":"lint","status":"success"}]'; round
[ "$(status)" = ready ] || fail 'complete exact head did not become ready'
# Staleness/future time must override success.
jq '.observed_at=1 | .revision="7"' "$H/ci.json" > "$TMP_ROOT/ci.json"; mv "$TMP_ROOT/ci.json" "$H/ci.json"; round
[ "$(status)" = unavailable ] || fail 'stale success accepted'
pe retire "$SID" >/dev/null
pass 'required jobs, exact head, attempt and freshness prevent false green'

make_spec deadline receipt 5
SID=$(obs arm "$TMP_ROOT/spec.json")
evidence pending
round
[ "$(status)" = expired ] || fail 'unbounded pending observation'
[ ! -e "$H/state/procevent/$SID.source" ] || fail 'expired observation did not retire'
pass 'absolute deadline retires unresolved observations'

# Renewal is an explicit bounded re-arm of the same identity, keeping subscribers.
obs subscribe "$SID" waiter g1
jq '.receipt="elsewhere.json" | .deadline+=60' "$TMP_ROOT/spec.json" > "$TMP_ROOT/moved.json"
refuse obs arm "$TMP_ROOT/moved.json"
jq '.deadline=(now|floor)+60' "$TMP_ROOT/spec.json" > "$TMP_ROOT/renew.json"
[ "$(obs arm "$TMP_ROOT/renew.json")" = "$SID" ] || fail 're-arm changed the shared identity'
[ -e "$H/state/procevent/$SID.source" ] || fail 're-arm did not register a bounded source'
[ "$(status)" = pending ] || fail 're-armed observation not pending'
refuse obs arm "$TMP_ROOT/spec.json"
evidence ready 2; round
[ "$(status)" = ready ] || fail 're-armed observation did not observe readiness'
obs pending "$SID" waiter g1 | jq -e '.[-1].status=="ready"' >/dev/null || fail 're-arm lost the subscriber'
pe retire "$SID" >/dev/null
pass 'only an expired observation re-arms, with a new deadline and its subscribers intact'

# A relaunched consumer moves its subscription only from the exact generation.
obs ack "$SID" waiter g1 1
refuse obs resubscribe "$SID" waiter g0 g2
refuse obs resubscribe "$SID" nobody g1 g2
obs resubscribe "$SID" waiter g1 g2
refuse obs pending "$SID" waiter g1
obs pending "$SID" waiter g2 | jq -e 'length==1 and .[0].event==2' >/dev/null || fail 'resubscribe lost or replayed consumed events'
pass 'generation handoff keeps the cursor and retires the old generation'

# Exercise the real preauthorization/when/observer interfaces with only external
# lifecycle effects replaced: no runtime or worker is launched by this suite.
CODE="$TMP_ROOT/code"
mkdir -p "$CODE"
cp -R "$ROOT/bin" "$CODE/bin"
cat > "$CODE/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/spawns"
printf 'kind=scout\nspawn_gen=fixture-incarnation\n' > "$FM_HOME/state/$1.meta"
[ ! -e "$FM_HOME/fail-spawn" ]
SH
cat > "$CODE/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
[ "$FM_SEND_EXPECTED_SPAWN_GEN" = fixture-incarnation ] || exit 1
printf '%s\n' "$*" >> "$FM_HOME/sends"
SH
chmod +x "$CODE/bin/fm-spawn.sh" "$CODE/bin/fm-send.sh"
ready() { FM_HOME="$H" "$CODE/bin/fm-procevent-ready.sh" "$@"; }
# Real tasks-axi gives the authorizer the same typed row the lifecycle uses.
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
mkdir -p "$H/config" "$H/projects/demo"
task() { FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
prepare_ready() {
  local name=$1 existing=${2:-null} partial=${3:-false} capacity=${4:-10}
  make_spec "$name" analysis-ready
  SID=$(obs arm "$TMP_ROOT/spec.json")
  evidence ready; round
  mkdir -p "$H/data/$name"
  printf 'original question, pin, verified scope, domain skill version\n' > "$H/data/$name/handoff.md"
  printf 'Read data/%s/handoff.md and data/%s/readiness.json. Read-only analysis.\n' "$name" "$name" > "$H/data/$name/brief.md"
  task add "$name" "$name" --kind scout --repo demo >/dev/null
  if [ "$existing" != null ]; then
    task start "$name" >/dev/null
    printf 'kind=scout\nspawn_gen=fixture-incarnation\n' > "$H/state/$name.meta"
  fi
  jq -n --arg task "$name" --arg source "$SID" --argjson existing "$existing" --argjson partial "$partial" --argjson capacity "$capacity" --argjson deadline "$(( $(date +%s) + 120 ))" \
    '{schema:"fm-ready-v1",task:$task,generation:"v1",source:$source,handoff:("data/"+$task+"/handoff.md"),project:"projects/demo",profile:{harness:"pi",model:"test-model",effort:"high"},deadline:$deadline,capacity:$capacity,allow_partial:$partial,existing_generation:$existing}' > "$TMP_ROOT/ready.json"
  ready authorize "$TMP_ROOT/ready.json" --preauthorized >/dev/null
}
prepare_ready analyst
ready condition analyst v1 || fail 'preauthorized exact ready condition refused'
ready dispatch analyst v1 > "$TMP_ROOT/dispatched"
assert_grep 'confirmed: analyst fixture-incarnation' "$TMP_ROOT/dispatched" 'dispatch confirms actual incarnation'
assert_contains "$(< "$H/spawns")" '--scout' 'only read-only scout lifecycle chosen'
[ "$(obs pending "$SID" analyst v1 | jq length)" = 0 ] || fail 'confirmed consumption not acknowledged'
refuse ready dispatch analyst v1
[ "$(wc -l < "$H/spawns" | tr -d ' ')" = 1 ] || fail 'duplicate analyst created'
ready inspect analyst v1 > "$TMP_ROOT/inspect"
assert_grep 'fixture-incarnation' "$TMP_ROOT/inspect" 'reconciliation exposes known incarnation'
pass 'preauthorized handoff dispatches once through lifecycle and acks only confirmation'

prepare_ready changed
printf 'mutated\n' >> "$H/data/changed/handoff.md"
refuse ready dispatch changed v1
prepare_ready cancelled
ready cancel cancelled v1
refuse ready dispatch cancelled v1
prepare_ready held
task hold held --reason 'manual decision' >/dev/null
refuse ready dispatch held v1
prepare_ready stale
refuse ready dispatch stale v2
# Receipt revision changed after observation: condition must re-read evidence.
evidence ready 2
refuse ready condition stale v1
prepare_ready artifact
printf 'previous analysis\n' > "$H/data/artifact/report.md"
refuse ready dispatch artifact v1
[ "$(wc -l < "$H/spawns" | tr -d ' ')" = 1 ] || fail 'unsafe handoff launched'
pass 'mutated handoff, cancellation, hold, stale generation, changed receipt and existing artifact refuse launch'

prepare_ready capacity null false 1
refuse ready dispatch capacity v1
prepare_ready warm '"fixture-incarnation"'
ready dispatch warm v1 >/dev/null
[ "$(wc -l < "$H/spawns" | tr -d ' ')" = 1 ] || fail 'existing analyst was duplicated'
assert_grep 'warm' "$H/sends" 'receipt delivered to approved existing incarnation'
prepare_ready wrong-incarnation '"fixture-incarnation"'
printf 'kind=scout\nspawn_gen=replacement\n' > "$H/state/wrong-incarnation.meta"
refuse ready dispatch wrong-incarnation v1
prepare_ready partial null true
evidence partial 2; round
# Run the existing when action boundary, not only the dispatch helper directly.
FM_HOME="$H" "$CODE/bin/fm-procevent.sh" start when-ready-partial >/dev/null
jq -e '.status=="partial" and .evidence.status=="partial"' "$H/data/partial/readiness.json" >/dev/null || fail 'partial scope was lost'
prepare_ready partial-refused
evidence partial 2; round
refuse ready condition partial-refused v1
prepare_ready unverified
evidence ready 2
jq '.verified=false' "$H/unverified.json" > "$TMP_ROOT/unverified.json"; mv "$TMP_ROOT/unverified.json" "$H/unverified.json"
round
[ "$(status)" = unavailable ] || fail 'unverified receipt accepted'
refuse ready dispatch unverified v1
prepare_ready failed
: > "$H/fail-spawn"
refuse ready dispatch failed v1
refuse ready dispatch failed v1
ready inspect failed v1 > "$TMP_ROOT/failed-inspect"
assert_grep 'intent' "$TMP_ROOT/failed-inspect" 'unconfirmed spawn retains its intent'
assert_grep 'fixture-incarnation' "$TMP_ROOT/failed-inspect" 'unconfirmed spawn exposes known incarnation for reconciliation'
[ "$(wc -l < "$H/spawns" | tr -d ' ')" = 3 ] || fail 'failed dispatch retried or partial handoff did not launch'
pass 'capacity, existing generations, partial policy, verified evidence and ambiguous launch retain action boundaries'

printf 'all shared observation tests passed\n'
