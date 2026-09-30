#!/usr/bin/env bash
# Live driver: real bin/fm-fleet-sync.sh + fm-application-provenance.sh against
# throwaway bare origins and clones in an isolated FM_HOME (never the real fleet).
set -u
ROOT=${ROOT:?}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: >"$GIT_CONFIG_GLOBAL"; git config --global init.defaultBranch main
H="$T/home"; mkdir -p "$H/projects" "$H/data"
say(){ printf '\n=== %s ===\n' "$*"; }
sync(){ echo "\$ FM_HOME=\$H bin/fm-fleet-sync.sh $1"; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$1" 2>&1 | grep -v '^fm-guard\|^guard'; }
prov(){ local c=$1 key; key=$(printf '%s' "$(cd "$c" && pwd -P)" | sha256sum | cut -d' ' -f1)
  echo "\$ bin/fm-application-provenance.sh <receipt> | selected fields"
  "$ROOT/bin/fm-application-provenance.sh" "$H/data/fleet-sync/$key.json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({k:d.get(k) for k in ("source_current","application_state")}))'
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("receipt:", json.dumps({"outcome":r["outcome"],"base":r.get("base"),"after.source":r["after"]["source"][:8] if r["after"]["source"] else None,"after.remote_tip":(r["after"]["remote_tip"] or "")[:8]}))' "$H/data/fleet-sync/$key.json"; }
mk(){ # mk name -> origin with main C0..C3, checks-approved at C1; clone at C0
  local n=$1; local w="$T/work-$n"
  git init -q --bare "$T/origin-$n.git"; git init -q "$w"
  for c in C0; do git -C "$w" commit -q --allow-empty -m $c; done
  git -C "$w" remote add origin "$T/origin-$n.git"; git -C "$w" push -q origin main
  git -C "$T/origin-$n.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$T/origin-$n.git" "$H/projects/$n"
  for c in C1 C2 C3; do git -C "$w" commit -q --allow-empty -m $c; done
  git -C "$w" push -q origin main; git -C "$w" push -q -f origin main~2:refs/heads/checks-approved; }
short(){ git -C "$1" rev-parse --short "$2"; }

say "S1 default: no fm.syncRef -> fast-forward to origin/main (unchanged behavior)"
mk plain; c="$H/projects/plain"
sync plain; echo "local main=$(short $c main) origin/main=$(short $c origin/main)"; prov "$c"

say "S2 fm.syncRef=checks-approved on the lattice-research clone -> ff to origin/checks-approved, not main tip"
mk lattice-research; c="$H/projects/lattice-research"
git -C "$c" config --local fm.syncRef checks-approved; echo "\$ git config --local fm.syncRef checks-approved"
sync lattice-research; echo "local main=$(short $c main) origin/checks-approved=$(short $c origin/checks-approved) origin/main=$(short $c origin/main)"; prov "$c"
say "S2b approved pointer advances (green CI) -> next sync follows it"
git -C "$T/work-lattice-research" push -q -f origin main~1:refs/heads/checks-approved
sync lattice-research; echo "local main=$(short $c main) origin/checks-approved=$(short $c origin/checks-approved)"; prov "$c"
say "S2c worker copy drawn from that clone starts at approved commit"
git clone -q "$c" "$T/worker"; echo "worker HEAD=$(short "$T/worker" HEAD) (approved=$(short $c origin/checks-approved))"

say "S3 whole-fleet run: other clone stays on its default branch while syncRef clone follows approved"
git -C "$T/work-plain" commit -q --allow-empty -m C4; git -C "$T/work-plain" push -q origin main
echo "\$ FM_HOME=\$H bin/fm-fleet-sync.sh   (whole fleet)"; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>&1 | grep -E 'plain|lattice'
echo "plain main=$(short $H/projects/plain main) origin/main=$(short $H/projects/plain origin/main); lattice main=$(short $c main) approved=$(short $c origin/checks-approved)"

say "S4 adversarial: fm.syncRef names a missing branch -> skipped, no fallback to origin/main"
mk missing; c="$H/projects/missing"; git -C "$c" config --local fm.syncRef no-such-branch
b=$(short $c main); sync missing; echo "local main before=$b after=$(short $c main) (origin/main=$(short $c origin/main))"

say "S5 adversarial: fm.syncRef only in GLOBAL config -> ignored, clone follows origin/main"
mk globalonly; c="$H/projects/globalonly"; git config --global fm.syncRef checks-approved
sync globalonly; echo "local main=$(short $c main) origin/main=$(short $c origin/main)"; git config --global --unset fm.syncRef

say "S6 enabling syncRef on a clone already at origin/main tip -> benign 'ahead', not STUCK, never moved back"
mk ahead; c="$H/projects/ahead"; sync ahead >/dev/null; git -C "$c" config --local fm.syncRef checks-approved
b=$(short $c main); sync ahead; echo "local main before=$b after=$(short $c main) approved=$(short $c origin/checks-approved)"; prov "$c"

say "S7 adversarial: syncRef clone = approved + unpushed local commit -> STUCK, untouched"
mk localwork; c="$H/projects/localwork"; git -C "$c" config --local fm.syncRef checks-approved; sync localwork >/dev/null
git -C "$c" commit -q --allow-empty -m local-only; b=$(short $c main); sync localwork; echo "local main before=$b after=$(short $c main)"

say "S8 adversarial: syncRef clone diverged from approved -> STUCK, untouched"
mk div; c="$H/projects/div"; git -C "$c" config --local fm.syncRef checks-approved
git -C "$c" commit -q --allow-empty -m diverge; b=$(short $c main); sync div; echo "local main before=$b after=$(short $c main)"
