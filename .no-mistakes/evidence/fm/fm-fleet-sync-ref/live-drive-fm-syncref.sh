#!/usr/bin/env bash
# Live drive of bin/fm-fleet-sync.sh fm.syncRef behaviour against real git repos
# in an isolated throwaway FM_HOME (never the operator's real fleet).
# Usage: live-drive-fm-syncref.sh <firstmate-worktree>
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-syncref-live.XXXXXX)
export GIT_CONFIG_GLOBAL="$T/global.gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name live; git config --global user.email live@example.invalid
git config --global init.defaultBranch main; git config --global advice.detachedHead false
H="$T/home"; mkdir -p "$H/projects" "$H/remotes"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
sync() { echo "  \$ FM_HOME=\$H fm-fleet-sync.sh $*"; OUT=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null); echo "$OUT" | sed 's/^/    /'; }
short() { git -C "$1" rev-parse --short "$2"; }
commit() { printf '%s\n' "$2" > "$1/f.txt"; git -C "$1" add f.txt; git -C "$1" commit -qm "$2"; }
mk() { # mk name -> projects/name cloned from bare remote, work repo work-name
  local n=$1; git init -q "$T/work-$n"; commit "$T/work-$n" C0
  git clone -q --bare "$T/work-$n" "$H/remotes/$n.git"
  git -C "$T/work-$n" remote add origin "file://$H/remotes/$n.git"; git -C "$T/work-$n" push -q -u origin main
  git clone -q "file://$H/remotes/$n.git" "$H/projects/$n"; }
adv() { commit "$T/work-$1" "$2"; git -C "$T/work-$1" push -q origin main; }
approve() { git -C "$T/work-$1" push -q -f origin "$2:refs/heads/checks-approved"; }
state() { echo "    [$1] HEAD=$(short "$H/projects/$1" HEAD) branch=$(git -C "$H/projects/$1" symbolic-ref -q --short HEAD || echo DETACHED) origin/main=$(short "$H/projects/$1" origin/main) origin/checks-approved=$(short "$H/projects/$1" origin/checks-approved 2>/dev/null || echo none)"; }

echo "== S1: fm.syncRef unset -> clone fast-forwards to origin/main as before"
mk plain; adv plain C1; approve plain main~1; adv plain C2
sync plain; git -C "$H/projects/plain" fetch -q; state plain
check '[ "$(short $H/projects/plain HEAD)" = "$(short $H/projects/plain origin/main)" ] && [[ $OUT == *"plain: synced"* ]]' "unset clone synced to origin/main tip"

echo "== S2: clone-local fm.syncRef=checks-approved -> local main fast-forwards to origin/checks-approved, not main tip"
mk lattice; adv lattice C1; approve lattice main; adv lattice C2
git -C "$H/projects/lattice" config fm.syncRef checks-approved
echo "  \$ git -C projects/lattice config fm.syncRef checks-approved"
sync lattice; state lattice
check '[ "$(short $H/projects/lattice main)" = "$(short $H/projects/lattice origin/checks-approved)" ] && [ "$(short $H/projects/lattice main)" != "$(short $H/projects/lattice origin/main)" ] && [[ $OUT == *"lattice: synced"* ]]' "syncRef clone at approved commit, behind origin/main"
KEY=$(printf '%s' "$(cd "$H/projects/lattice" && pwd -P)" | sha256sum | cut -d' ' -f1)
R="$H/data/fleet-sync/$KEY.json"
echo "  receipt: $(python3 -c 'import json,sys;r=json.load(open(sys.argv[1]));print(json.dumps({k:r.get(k) for k in ("outcome","base","fetch_succeeded","after")}))' "$R")"
check 'python3 -c "import json,sys;r=json.load(open(sys.argv[1]));assert r[\"base\"]==\"origin/checks-approved\" and r[\"after\"][\"remote_tip\"]==r[\"after\"][\"source\"]" "$R"' "receipt base=origin/checks-approved, remote_tip == approved source"
APP=$("$ROOT/bin/fm-application-provenance.sh" "$R"); echo "  application readout: $(echo "$APP" | python3 -c 'import json,sys;d=json.load(sys.stdin);print({k:d.get(k) for k in ("source_current",)})')"
check '[ "$(echo "$APP" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"source_current\"])")" = True ]' "application provenance reads source_current=true"
sync lattice
check '[[ $OUT == *"lattice: already current"* ]]' "second run: already current despite origin/main ahead"

echo "== S3: checks-approved advances after green CI -> next sync follows it"
approve lattice main; adv lattice C3
sync lattice; state lattice
check '[ "$(short $H/projects/lattice main)" = "$(short $H/projects/lattice origin/checks-approved)" ] && [[ $OUT == *"lattice: synced"* ]]' "followed checks-approved forward, still behind main tip"

echo "== S4 (adversarial): fm.syncRef names missing origin ref -> skipped, NO fallback to origin/main"
mk missing; git -C "$H/projects/missing" config fm.syncRef checks-approved; B=$(short "$H/projects/missing" HEAD); adv missing C1
sync missing; state missing
check '[[ $OUT == *"skipped: origin/checks-approved does not exist"* ]] && [ "$(short $H/projects/missing HEAD)" = "$B" ]' "skipped by name, clone not moved"

echo "== S5 (adversarial): global fm.syncRef is ignored (clone-local only)"
mk globalc; adv globalc C1; approve globalc main~1; adv globalc C2
git config --global fm.syncRef checks-approved; echo "  \$ git config --global fm.syncRef checks-approved"
sync globalc; git config --global --unset fm.syncRef; state globalc
check '[ "$(short $H/projects/globalc HEAD)" = "$(short $H/projects/globalc origin/main)" ]' "global setting did not change sync base"

echo "== S6: enabling fm.syncRef on a clone already at origin/main tip -> benign 'ahead', never STUCK, never moved back"
mk ahead; adv ahead C1; approve ahead main; adv ahead C2; sync ahead >/dev/null
B=$(short "$H/projects/ahead" HEAD); git -C "$H/projects/ahead" config fm.syncRef checks-approved; echo "  \$ git config fm.syncRef checks-approved (main at $B)"
sync ahead; state ahead
check '[[ $OUT == *"ahead of sync base origin/checks-approved"* ]] && [[ $OUT != *STUCK* ]] && [ "$(short $H/projects/ahead HEAD)" = "$B" ]' "reported ahead/waiting, main untouched"

echo "== S7 (adversarial): local unpushed commit on main atop checks-approved -> STUCK, untouched"
mk work; adv work C1; approve work main; adv work C2
git -C "$H/projects/work" config fm.syncRef checks-approved; git -C "$H/projects/work" fetch -q
git -C "$H/projects/work" reset -q --hard origin/checks-approved; commit "$H/projects/work" LOCAL; B=$(short "$H/projects/work" HEAD)
sync work; state work
check '[[ $OUT == *"STUCK:"*"diverged main"* ]] && [[ $OUT != *"ahead of sync base"* ]] && [ "$(short $H/projects/work HEAD)" = "$B" ]' "STUCK diverged main, local work untouched"

echo "== S8: detached HEAD at origin/main tip past checks-approved -> benign wait; with local main work -> STUCK"
mk det; adv det C1; approve det main; adv det C2; git -C "$H/projects/det" config fm.syncRef checks-approved
git -C "$H/projects/det" fetch -q; git -C "$H/projects/det" checkout -q --detach origin/main; B=$(short "$H/projects/det" HEAD)
sync det; state det
check '[[ $OUT == *"detached HEAD ahead of sync base"* ]] && [[ $OUT != *STUCK* ]] && [ "$(short $H/projects/det HEAD)" = "$B" ]' "detached ahead waits, untouched"
git -C "$H/projects/det" branch -f main origin/checks-approved; git -C "$H/projects/det" checkout -q main; commit "$H/projects/det" LOCAL; L=$(short "$H/projects/det" main); git -C "$H/projects/det" checkout -q --detach origin/main
sync det; state det
check '[[ $OUT == *"STUCK:"* ]] && [[ $OUT != *"ahead of sync base"* ]] && [ "$(short $H/projects/det main)" = "$L" ]' "detached + local main work is STUCK, local main untouched"
git -C "$H/projects/det" checkout -q main; git -C "$H/projects/det" reset -q --hard origin/checks-approved  # tidy for fleet run

echo "== S9: whole-fleet run through bootstrap: STUCK relayed as FLEET_SYNC, benign ahead not relayed"
BOUT=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep FLEET_SYNC)
echo "$BOUT" | sed 's/^/    /'
check '[[ $BOUT == *"FLEET_SYNC: work: STUCK:"* ]] && [[ $BOUT != *"ahead: "* ]] && [[ $BOUT != *"lattice"* ]]' "bootstrap relays STUCK for work, stays quiet for ahead/lattice"

echo "== RESULT: $PASS passed, $FAIL failed"
rm -rf "$T"
[ "$FAIL" -eq 0 ]
