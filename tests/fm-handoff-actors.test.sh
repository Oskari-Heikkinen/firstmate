#!/usr/bin/env bash
# fm-handoff-actors: drill V-i and the install check. A custom check or timer
# with no fragment is refused at install and binds nothing; a bypassed install
# (a hand-written trust record, a unit started outside an installer) is listed
# as undeclared; a fragment stage, a no-handoff declaration, the first-run
# snapshot or the built-in list allows it; a custom check is covered only by a
# stage its own home owns; a service is covered by its same-name timer and by
# the timers in its TriggeredBy, never by a path unit; re-registering a
# grandfathered check still works; unreadable fragments, unit listings and
# TriggeredBy fail closed; an unlisted unit table still grandfathers checks;
# only the anchor home lists units; an unchanged pass reruns no unit query and
# rewrites no cache; a --home that is not a home is refused and nothing written.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-actors)

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
TOOL = str(root / "bin/fm-handoff-actors.py")
REGISTER = str(root / "bin/fm-check-register.sh")
FRAGMENT = root / "docs/handoff-coverage/examples/xp-chain.fragment.json"
CTL = tmp / "systemctl"
UNITS = tmp / "units.txt"
CALLS = tmp / "systemctl.calls"
TRIGGERS = tmp / "triggers.txt"
TRIGGERS.write_text("")

# Answers list-units and show from units.txt ("<unit> <fragment path>|transient")
# and TriggeredBy from triggers.txt ("<service> <triggering unit>..."); a
# units.txt.fail file fails every call, a triggers.txt.fail file only a
# TriggeredBy-only show.
CTL.write_text("""#!/bin/sh
printf '%s\\n' "$2" >> "$FAKE_CALLS"
[ -e "$FAKE_UNITS.fail" ] && { echo 'Failed to connect to bus' >&2; exit 1; }
case "$2" in
  list-units) while read -r unit _; do printf '%s loaded active waiting x\\n' "$unit"; done < "$FAKE_UNITS" ;;
  show)
    props=$3
    shift 4
    if [ "$props" = --property=TriggeredBy ] && [ -e "$FAKE_TRIGGERS.fail" ]; then
      echo 'Failed to get properties: Access denied' >&2; exit 1
    fi
    for unit in "$@"; do
      by=$(awk -v u="$unit" '$1 == u { $1 = ""; sub(/^ /, ""); print }' "$FAKE_TRIGGERS")
      if [ "$props" = --property=TriggeredBy ]; then printf 'TriggeredBy=%s\\n\\n' "$by"; continue; fi
      path=$(awk -v u="$unit" '$1 == u { print $2 }' "$FAKE_UNITS")
      if [ "$path" = transient ]; then printf 'Id=%s\\nFragmentPath=\\nTransient=yes\\nTriggeredBy=%s\\n\\n' "$unit" "$by"
      else printf 'Id=%s\\nFragmentPath=%s\\nTransient=no\\nTriggeredBy=%s\\n\\n' "$unit" "$path" "$by"; fi
    done ;;
esac
""")
CTL.chmod(0o755)
ENV = dict(os.environ, FM_HANDOFF_ACTORS_SYSTEMCTL=str(CTL), FAKE_UNITS=str(UNITS), FAKE_CALLS=str(CALLS),
           FAKE_TRIGGERS=str(TRIGGERS), HOME=str(tmp / "user"))
USER_UNIT = str(tmp / "user/.config/systemd/user")


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def units(*rows):
    UNITS.write_text("".join(f"{u} {p}\n" for u, p in rows))


def triggers(*rows):
    TRIGGERS.write_text("".join(" ".join(row) + "\n" for row in rows))


def tool(*args, env=None):
    proc = subprocess.run([sys.executable, "-I", TOOL, *map(str, args)], capture_output=True, text=True,
                          env=env or ENV)
    return proc.returncode, proc.stdout + proc.stderr


def register(home, cid, *extra):
    proc = subprocess.run([REGISTER, cid, *extra], capture_output=True, text=True,
                          env=dict(ENV, FM_HOME=str(home)))
    return proc.returncode, proc.stdout + proc.stderr


def make_home(path):
    state = path / "state"
    state.mkdir(parents=True)
    state.chmod(0o700)
    return path


def write_check(home, cid):
    check = home / "state" / f"{cid}.check.sh"
    check.write_text("#!/usr/bin/env bash\nexit 0\n")
    check.chmod(0o700)


def bypass(home, cid):
    """A check bound by hand, as an installer that skipped the check would leave it."""
    write_check(home, cid)
    (home / "state" / f"{cid}.check-trust").write_text("fm-custom-check-v1\n0\n")


def fragment(home, owner, actors):
    doc = json.loads(FRAGMENT.read_text())
    doc.pop("example", None)
    doc["home"] = home.name
    doc["protocols"][0]["owner"] = home.name
    doc["protocols"][0]["stages"][0]["owner"] = owner
    doc["protocols"][0]["stages"][0]["actors"] = actors
    folder = home / "state" / "handoff-registry"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "xp.json").write_text(json.dumps(doc))
    return folder / "xp.json"


def inventory(home, *extra):
    rc, out = tool("list", "--home", home, *extra)
    try:
        return rc, json.loads(out), out
    except ValueError:
        fail(f"list printed no inventory\n{out}")


def states(doc):
    return {row["actor"]: row["state"] for row in doc["actors"]}


# ---------- custom checks through bin/fm-check-register.sh ----------

units()
home = make_home(tmp / "plain")
bypass(home, "armed-before")
rc, out = register(home, "armed-before")
expect(rc == 0, "a check armed before the install check re-registers on update (first-run snapshot)", out)
snap = json.loads((home / "state/handoff-actors/grandfathered.json").read_text())
expect([e["actor"] for e in snap["actors"]] == ["fm-check:armed-before"]
       and snap["actors"][0]["handoff"] == "grandfathered", "the snapshot lists exactly the checks bound before", snap)

write_check(home, "new-tool")
rc, out = register(home, "new-tool")
expect(rc == 1 and "not registered" in out and "--no-handoff" in out,
       "drill V-i: a new check with no fragment is refused at install", out)
expect(not (home / "state/new-tool.check-trust").exists(), "a refused check gets no trust record")
log = (home / "state/handoff-actors/log").read_text()
expect("check fm-check:new-tool: refused" in log, "the refusal is logged", log)

rc, out = register(home, "new-tool", "--no-handoff", "pings a health URL only")
expect(rc == 0 and (home / "state/new-tool.check-trust").exists(), "--no-handoff declares and registers", out)
declared = json.loads((home / "state/handoff-actors/declared.json").read_text())
expect(declared["revision"] == 1 and declared["actors"][0]["handoff"] == "none"
       and declared["actors"][0]["reason"] == "pings a health URL only", "the declaration is recorded", declared)
rc, out = register(home, "new-tool", "--no-handoff", "pings a health URL only")
declared = json.loads((home / "state/handoff-actors/declared.json").read_text())
expect(rc == 0 and declared["revision"] == 1, "an identical declaration does not bump the revision", out)
rc, out = register(home, "new-tool", "--no-handoff")
expect(rc == 2, "--no-handoff needs a reason", out)

write_check(home, "disk-room")
rc, out = register(home, "disk-room")
expect(rc == 0, "a Firstmate built-in check is allowed by the built-in list", out)

write_check(home, "chain-stage")
fragment(home, "main", ["fm-check:chain-stage"])
rc, out = register(home, "chain-stage")
expect(rc == 0, "a check its own home's fragment stage lists is allowed", out)

bypass(home, "sneaked-in")
rc, doc, out = inventory(home)
got = states(doc)
expect(rc == 1 and got.get("fm-check:sneaked-in") == "undeclared",
       "drill V-i: a check bound around the installer is listed as undeclared", out)
expect(got.get("fm-check:armed-before") == "grandfathered" and got.get("fm-check:new-tool") == "none"
       and got.get("fm-check:chain-stage") == "declared", "covered checks list their verdicts", out)
rc, out = tool("undeclare", "--home", home, "fm-check:new-tool")
rc2, out2 = tool("check", "--home", home, "fm-check:new-tool")
expect(rc == 0 and rc2 == 1, "undeclare removes the declaration", out + out2)

# ---------- scope: per-home checks, machine-wide units ----------

drill = tmp / "drill"
main = make_home(drill / "main")
other = make_home(drill / "tetjet-mate")
fragment(other, "tetjet-mate", ["fm-check:tj-watch", "systemd-timer:tj-new.timer"])
units(("stray-old.timer", USER_UNIT + "/stray-old.timer"))
rc, out = tool("check", "--home", main, "--root", drill, "fm-check:tj-watch")
expect(rc == 1, "another home's stage does not cover this home's custom check", out)
rc, out = tool("check", "--home", other, "--root", drill, "fm-check:tj-watch")
expect(rc == 0 and out.startswith("declared\t"), "the owning home's stage covers its custom check", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tj-new.service")
expect(rc == 0, "a service is covered by its timer listed in any local home's fragment", out)

rc, doc, out = inventory(main, "--root", drill)
expect(states(doc) == {"systemd-timer:stray-old.timer": "grandfathered"} and rc == 0,
       "units running at first run are grandfathered", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-timer:lattice-new.timer")
expect(rc == 1 and out.startswith("refused\t"), "drill V-i: a timer with no fragment is refused at install", out)

units(("stray-old.timer", USER_UNIT + "/stray-old.timer"), ("lattice-new.timer", USER_UNIT + "/lattice-new.timer"),
      ("run-u1.service", "transient"), ("dbus.service", "/usr/lib/systemd/user/dbus.service"),
      ("tj-new.timer", USER_UNIT + "/tj-new.timer"))
rc, doc, out = inventory(main, "--root", drill)
got = states(doc)
expect(rc == 1 and got.get("systemd-timer:lattice-new.timer") == "undeclared"
       and got.get("systemd-service:run-u1.service") == "undeclared",
       "drill V-i: units started around the installer are listed as undeclared", out)
expect("systemd-service:dbus.service" not in got and got.get("systemd-timer:tj-new.timer") == "declared",
       "distribution units are not inventoried and fragment-listed units are declared", out)
rc, doc, out = inventory(other, "--root", drill)
expect(not [r for r in doc["actors"] if r["scope"] == "machine"] and doc["anchor"] is False,
       "only the anchor home lists units", out)

CALLS.write_text("")
cache = main / "state/handoff-actors/.cache.json"
before = cache.stat().st_mtime_ns
inventory(main, "--root", drill)
expect(CALLS.read_text().split() == ["list-units"] and cache.stat().st_mtime_ns == before,
       "an unchanged pass reruns no unit query and rewrites no cache")

# ---------- a service started by a differently named timer ----------

triggers(("tjsvc@pc-archive.service", "tj-new.timer"), ("tjcap@capacity-fill.service", "stray-old.timer"),
         ("tjsvc@watch.service", "tj-new.path"))
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tjsvc@pc-archive.service")
expect(rc == 0 and out.startswith("declared\t") and "systemd-timer:tj-new.timer" in out,
       "a service is covered by the declared timer systemd names in its TriggeredBy", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tjcap@capacity-fill.service")
expect(rc == 0 and out.startswith("grandfathered\t"),
       "a service is covered by the grandfathered timer systemd names in its TriggeredBy", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tjsvc@watch.service")
expect(rc == 1 and out.startswith("refused\t"), "a path unit in TriggeredBy covers nothing", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tjsvc@fetch.service")
expect(rc == 1 and out.startswith("refused\t"),
       "counterfactual: the same service with no triggering timer is refused", out)

units(("stray-old.timer", USER_UNIT + "/stray-old.timer"), ("tj-new.timer", USER_UNIT + "/tj-new.timer"),
      ("tjsvc@pc-archive.service", USER_UNIT + "/tjsvc@.service"),
      ("tjsvc@keeper.service", USER_UNIT + "/tjsvc@.service"))
CALLS.write_text("")
rc, doc, out = inventory(main, "--root", drill)
got = states(doc)
expect(got.get("systemd-service:tjsvc@pc-archive.service") == "declared"
       and got.get("systemd-service:tjsvc@keeper.service") == "undeclared",
       "the inventory credits a running service to the timer in its TriggeredBy", out)
expect(CALLS.read_text().split() == ["list-units", "show"],
       "the inventory reads TriggeredBy in its one unit show, with no call per service", CALLS.read_text())
CALLS.write_text("")
inventory(main, "--root", drill)
expect(CALLS.read_text().split() == ["list-units"], "an unchanged pass reruns no TriggeredBy query",
       CALLS.read_text())

Path(str(TRIGGERS) + ".fail").write_text("")
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tjsvc@pc-archive.service")
expect(rc == 3 and out.startswith("unknown\t") and "TriggeredBy" in out,
       "an unreadable TriggeredBy refuses an otherwise uncovered service with exit 3", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-service:tj-new.service")
expect(rc == 0 and out.startswith("declared\t"),
       "counterfactual: a service its same-name timer covers stays allowed while TriggeredBy is unreadable", out)
os.unlink(str(TRIGGERS) + ".fail")

# ---------- a --home that is not a home ----------

units(("stray-old.timer", USER_UNIT + "/stray-old.timer"))
missing, empty, bare = tmp / "typo-home", tmp / "empty-home", tmp / "bare-home"
empty.mkdir()
bare.mkdir()
(bare / "notes.txt").write_text("not a home\n")
for path, what in ((missing, "a missing folder"), (empty, "an empty folder"), (bare, "a folder with no state/")):
    for args in (("check", "--home", path, "systemd-timer:stray-old.timer"),
                 ("declare", "--home", path, "--none", "--reason", "x", "fm-check:a"),
                 ("undeclare", "--home", path, "fm-check:a"), ("list", "--home", path)):
        rc, out = tool(*args)
        expect(rc == 2 and str(path) in out and "not a firstmate home" in out,
               f"{args[0]} refuses {what} as --home with exit 2", out)
expect(not missing.exists() and not any(empty.iterdir()) and sorted(p.name for p in bare.iterdir()) == ["notes.txt"],
       "a refused --home gets no state, snapshot or log")
rc, out = tool("check", "--home", make_home(tmp / "real-home"), "systemd-timer:stray-old.timer")
expect(rc == 0 and out.startswith("grandfathered\t"),
       "counterfactual: the same check in a real home grandfathers the running unit", out)

# ---------- failing closed ----------

Path(str(UNITS) + ".fail").write_text("")
rc, doc, out = inventory(main, "--root", drill)
expect(rc == 3 and any(p["subject"] == "systemctl --user" for p in doc["problems"]),
       "a failing unit listing is a problem, not an empty machine", out)
fresh = make_home(tmp / "no-bus")
bypass(fresh, "armed-before")
rc, out = register(fresh, "armed-before")
expect(rc == 0 and (fresh / "state/handoff-actors/grandfathered.json").exists(),
       "with no unit listing, checks are still grandfathered", out)
rc, out = tool("check", "--home", fresh, "systemd-timer:unknown.timer")
expect(rc == 3 and out.startswith("unknown\t")
       and not (fresh / "state/handoff-actors/grandfathered-units.json").exists(),
       "a timer cannot be allowed before units are listed, and the unit snapshot waits", out)
os.unlink(str(UNITS) + ".fail")
rc, out = tool("check", "--home", fresh, "systemd-timer:unknown.timer")
expect(rc == 1 and (fresh / "state/handoff-actors/grandfathered-units.json").exists(),
       "the unit snapshot is taken once units can be listed", out)

rc, out = tool("check", "--home", make_home(tmp / "no-systemd"), "systemd-timer:none.timer",
               env=dict(ENV, FM_HANDOFF_ACTORS_SYSTEMCTL=str(tmp / "missing-systemctl")))
expect(rc == 1 and out.startswith("refused\t"), "a machine with no systemctl has no units, not a problem", out)

(other / "state/handoff-registry/xp.json").write_text("{not json")
rc, out = tool("check", "--home", main, "--root", drill, "systemd-timer:lattice-new2.timer")
expect(rc == 3 and out.startswith("unknown\t"), "an unreadable fragment refuses an uncovered install with exit 3", out)
rc, out = tool("check", "--home", main, "--root", drill, "systemd-timer:stray-old.timer")
expect(rc == 0, "a grandfathered unit stays allowed while a fragment is unreadable", out)

rc, out = tool("check", "--home", main, "nokind")
expect(rc == 2, "an actor without a kind is a usage error", out)
rc, out = tool("declare", "--home", main, "--reason", "x", "fm-check:a")
expect(rc == 2, "declare needs --none", out)
PY
pass "handoff install check and undeclared-actor inventory"
