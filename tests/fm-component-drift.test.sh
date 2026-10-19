#!/usr/bin/env bash
# Component-skill drift run: a run where every pin holds files nothing; a
# changed pinned source files exactly one item, in the home metadata.owner
# names, and wakes that home, even with the repository checked out in two
# homes; a rerun of the unchanged drift, or a further edit of the same
# drifted source, files no second item while the first is open; a run
# stopped right after an add records it, so the next run files nothing more
# and delivers the wake; once that item is done the same drift files a new
# one; a further drift rewrites the open item in place and wakes its home
# again; an owner naming no local home and a home-map skill without an owner
# route to main and to the map's home; a map drift cannot read, and a run
# refused by the lock, fail and alarm main. Temp homes, real tasks-axi, a
# fake clock (--now).
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-component-drift)
export HOME="$TMP_ROOT/fakehome"
mkdir -p "$HOME"
unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_FILE

for h in main mate-a; do
  mkdir -p "$TMP_ROOT/$h/state" "$TMP_ROOT/$h/data" "$TMP_ROOT/$h/config" "$TMP_ROOT/$h/projects"
  fm_test_tasks_toml "$TMP_ROOT/$h/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$TMP_ROOT/$h/data/backlog.md"
done
printf 'mate-a\n' > "$TMP_ROOT/mate-a/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/main" \
  > "$TMP_ROOT/mate-a/.fm-secondmate-parent"
printf -- '- mate-a - Tooling (home: %s; scope: tooling; projects: proj; added 2026-09-01)\n' \
  "$TMP_ROOT/mate-a" > "$TMP_ROOT/main/data/secondmates.md"

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import hashlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
main, mate = tmp / "main", tmp / "mate-a"
TOOL = str(root / "bin/fm-component-drift.sh")
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
           GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
NOW = [1792400000]


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg, file=sys.stderr)
    sys.exit(1)


def check(cond, msg, detail=""):
    if not cond:
        fail("%s\n%s" % (msg, detail))
    ok(msg)


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=ENV)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def skill(name, owner, pins):
    fm = "---\nname: %s\ndescription: Load before changing %s. One owner, fail closed.\nmetadata:\n" % (name, name)
    if owner:
        fm += "  owner: %s\n" % owner
    fm += "  sources:\n"
    for path, digest in pins:
        fm += "    - path: %s\n      sha256: %s\n" % (path, digest)
    return fm + ("---\n\n# %s\n\n## Goal and operating principle\nStay flexible.\n\n## Refuse\n- A second path.\n\n"
                 "## Review\n1. Is there one path?\n" % name)


def run(*extra, rc=0):
    NOW[0] += 600
    p = subprocess.run([TOOL, "run", "--home", str(main), "--now", str(NOW[0]), *extra],
                       text=True, capture_output=True, env=ENV, timeout=300)
    if rc is not None and p.returncode != rc:
        fail("run exited %d, wanted %d:\n%s%s" % (p.returncode, rc, p.stdout, p.stderr))
    return p


def axi(home, *args):
    env = dict(os.environ, FM_HOME=str(home))
    return subprocess.run([str(root / "bin/fm-tasks-axi.sh"), *args], text=True, capture_output=True,
                          env=env, cwd=str(home), timeout=60)


def items(home):
    return sorted(set(re.findall(r"drift-[a-z0-9-]+-[0-9a-f]{6}-[0-9]{12}", (home / "data/backlog.md").read_text())))


def body(home, task):
    return axi(home, "show", task, "--full").stdout


def notes(home):
    d = home / "state/inbox"
    return sorted(p.read_text() for p in d.glob("*.note")) if d.is_dir() else []


def alarms():
    return [n for n in notes(main) if "component-skill drift run failed" in n]


# A repository whose skill pins one in-repo source and one plan in main's data/.
plan = main / "data/plan.md"
write(plan, "Plan v1\n")
repo = mate / "projects/proj"
write(repo / "docs/contract.md", "Contract v1\n")
write(repo / "lib/core.py", "x = 1\n")
write(repo / "docs/component-map.json", json.dumps({"schema": "component-map/v1", "components": [
    {"id": "core", "skill": "core-skill", "paths": ["lib/**", "docs/contract.md"]}]}))
write(repo / ".agents/skills/core-skill/SKILL.md",
      skill("core-skill", "mate-a", [("docs/contract.md", sha(repo / "docs/contract.md")), (str(plan), sha(plan))]))
git(repo, "init", "-q", "-b", "main")
git(repo, "remote", "add", "origin", "https://example.invalid/proj.git")
git(repo, "add", "-A")
ENV["GIT_COMMITTER_DATE"] = "2026-01-01T00:00:00Z"
git(repo, "commit", "-q", "-m", "init")
# The same repository checked out in main too, one commit older, so mate-a's checkout is the one checked.
older = main / "projects/proj"
subprocess.run(["git", "clone", "-q", str(repo), str(older)], check=True, capture_output=True, env=ENV)
git(older, "remote", "set-url", "origin", "https://example.invalid/proj")
ENV["GIT_COMMITTER_DATE"] = "2026-02-01T00:00:00Z"
git(repo, "commit", "-q", "--allow-empty", "-m", "newer")
del ENV["GIT_COMMITTER_DATE"]

p = run()
check(items(main) == [] and items(mate) == [] and notes(mate) == [] and alarms() == [],
      "an unchanged run files nothing and raises no alarm", p.stdout + p.stderr)
log = (main / "state/component-drift/log").read_text()
check("run ended: 1 map(s) checked, 0 drifted" in log, "the log records the run's summary", log[-400:])

write(plan, "Plan v2\n")
p = run()
check(items(mate) != [] and len(items(mate)) == 1 and items(main) == [],
      "a changed pinned source files exactly one item, in the owner home, across two checkouts",
      "%s %s\n%s" % (items(mate), items(main), p.stdout))
first = items(mate)[0]
b = body(mate, first)
check(str(plan) in b and "metadata.owner names mate-a" in b and "pin the new sha256" in b,
      "the item names the drifted source, the owner rule and the update path", b)
check(any(first in n for n in notes(mate)), "the owner home is woken with the task id", str(notes(mate)))

run()
check(items(mate) == [first], "a rerun of the unchanged drift files no second item while the first is open",
      str(items(mate)))
run()
check(items(mate) == [first], "a third run files nothing either", str(items(mate)))
write(plan, "Plan v3\n")
run()
check(items(mate) == [first], "editing an already-drifted source again files nothing", str(items(mate)))

# A run stopped right after its add (the owner home's tasks-axi kills it) records the item it filed.
p = axi(mate, "done", first)
check(p.returncode == 0, "the first item closes", p.stdout + p.stderr)
stopper = mate / "bin/fm-tasks-axi.sh"
write(stopper, '#!/usr/bin/env bash\n"%s" "$@"; rc=$?\n[ "$1" = add ] && kill -TERM "$PPID"\nexit $rc\n'
      % (root / "bin/fm-tasks-axi.sh"))
stopper.chmod(0o755)
p = run(rc=2)
stopper.unlink()
again = [t for t in items(mate) if t != first]
check(len(again) == 1 and len(alarms()) == 1 and "stopped" in alarms()[0],
      "a stopped run has filed one new item for the done one's unchanged drift and alarms main",
      "%s %s\n%s" % (items(mate), alarms(), p.stdout + p.stderr))
woken = len(notes(mate))
run()
check(sorted(items(mate)) == sorted([first, again[0]]),
      "the run after a stopped one files no second item", str(items(mate)))
check(len(notes(mate)) == woken + 1 and any(again[0] in n for n in notes(mate)),
      "the run after a stopped one delivers the wake it missed", str(notes(mate)))

write(repo / "docs/contract.md", "Contract v2\n")
woken = len(notes(mate))
run()
b = body(mate, again[0])
check(sorted(items(mate)) == sorted([first, again[0]]) and "docs/contract.md" in b and "Rewritten by the drift run" in b,
      "a further drift rewrites the open item in place and files no new one", "%s\n%s" % (items(mate), b))
check(len(notes(mate)) == woken + 1 and any("rewrote backlog task %s" % again[0] in n for n in notes(mate)),
      "the rewrite wakes the owner home again", str(notes(mate)))

# Re-pin everything: the run files nothing and forgets the skill.
write(repo / ".agents/skills/core-skill/SKILL.md",
      skill("core-skill", "mate-a", [("docs/contract.md", sha(repo / "docs/contract.md")), (str(plan), sha(plan))]))
before = items(mate)
run()
ledger = json.loads((main / "state/component-drift/ledger.json").read_text())
check(items(mate) == before and ledger["skills"] == {}, "a re-pinned skill files nothing and is forgotten",
      json.dumps(ledger))

# An owner naming no local home goes to main; a home-map skill without an owner goes to the map's home.
write(repo / ".agents/skills/core-skill/SKILL.md",
      skill("core-skill", "nobody", [("docs/contract.md", "0" * 64)]))
kit = mate / "data/kit/run.sh"
write(kit, "echo v1\n")
hskill = tmp / "skills/kit-skill/SKILL.md"
write(hskill, skill("kit-skill", None, [(str(kit), "1" * 64)]))
write(mate / "config/component-map.json", json.dumps({"schema": "component-map/v1", "components": [
    {"id": "kit", "skill": str(hskill), "paths": [str(mate / "data/kit/**")]}]}))
before = items(mate)
run()
check(len(items(main)) == 1 and "which is no local home" in body(main, items(main)[0]),
      "an owner naming no local home routes the item to main", str(items(main)))
new = [t for t in items(mate) if t not in before]
check(len(new) == 1 and new[0].startswith("drift-kit-skill-") and "home map in mate-a" in body(mate, new[0]),
      "a home-map skill without an owner is filed in the map's home", str(new))

# A map drift cannot read fails the run and says so in the summary.
write(mate / "config/component-map.json", "{not json")
before = len(alarms())
p = run(rc=1)
check(len(alarms()) == before + 1 and any("component-map.json" in a for a in alarms()),
      "an unreadable map fails the run and its alarm to main names the map", str(alarms()))
log = (main / "state/component-drift/log").read_text()
check("FAILED: drift could not check home-map" in log, "the log records the failure", log[-400:])

# A run refused by the lock alarms main, naming the lock, and does nothing else.
before, filed = len(alarms()), (items(main), items(mate))
with open(main / "state/component-drift/.lock", "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    p = run(rc=2)
check(len(alarms()) == before + 1 and any("holds the lock" in a and ".lock" in a for a in alarms())
      and (items(main), items(mate)) == filed,
      "a run refused by the lock alarms main naming the lock and files nothing", str(alarms()) + p.stderr)
PY
