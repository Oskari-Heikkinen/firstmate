#!/usr/bin/env bash
# Component hook: a Read and an Edit under a mapped glob inject that
# component's goal and skill path once per session; a file in two components
# injects both; unmapped paths and repositories without a map are silent; an
# unusable map is reported once as context and never denies; the PostToolUse
# Bash sweep catches a file changed by a shell command; a compact SessionStart
# resets the record; a subagent gets its own record; the home map applies
# beside the repository map; output stays under 10,000 characters; and the
# Grok and --tool input shapes classify the same as Claude's.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
TMP_ROOT=$(fm_test_tmproot fm-component-check)

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
HOOK = str(root / "bin/fm-component-check.sh")
HOME = tmp / "home"
(HOME / "config").mkdir(parents=True)
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
           GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
           FM_HOME=str(HOME), FM_COMPONENT_STATE_DIR=str(tmp / "state"))
ENV.pop("GROK_AGENT", None)
ENV.pop("GROK_HOOK_EVENT", None)


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=ENV)


def hook(payload=None, args=(), claude=True):
    argv = [HOOK, *args] + (["--claude"] if claude else [])
    data = json.dumps(payload) if isinstance(payload, dict) else (payload or "")
    proc = subprocess.run(argv, input=data, capture_output=True, text=True, env=ENV)
    return proc.returncode, proc.stdout, proc.stderr


def context(out, event="PreToolUse"):
    """additionalContext of a --claude output, '' when silent."""
    if not out.strip():
        return ""
    obj = json.loads(out)
    spec = obj["hookSpecificOutput"]
    if spec["hookEventName"] != event:
        fail(f"hookEventName {spec['hookEventName']!r}, expected {event!r}")
    if "permissionDecision" in spec or "decision" in obj:
        fail("the hook must never decide: " + out)
    return spec["additionalContext"]


def pre(session, path, tool="Read", agent=None, cwd=None):
    key = "notebook_path" if tool == "NotebookEdit" else "file_path"
    payload = {"hook_event_name": "PreToolUse", "session_id": session, "tool_name": tool,
               "tool_input": {key: str(path)}, "cwd": str(cwd or tmp)}
    if agent:
        payload["agent_id"] = agent
    rc, out, err = hook(payload)
    if rc != 0:
        fail(f"the hook exited {rc}: {err}")
    return context(out)


def post_bash(session, cwd):
    rc, out, err = hook({"hook_event_name": "PostToolUse", "session_id": session, "tool_name": "Bash",
                         "tool_input": {"command": "sed -i ..."}, "cwd": str(cwd)})
    if rc != 0:
        fail(f"the hook exited {rc}: {err}")
    return context(out, "PostToolUse")


def skill(name, goal):
    return (f"---\nname: {name}\ndescription: Load before changing {name}. One owner.\n---\n\n# {name}\n\n"
            f"## Goal and operating principle\n{goal}\n\n## Refuse\n- A shortcut.\n\n## Review\n1. {name} check.\n")


def make_repo(name, extra=()):
    repo = tmp / name
    if repo.exists():
        shutil.rmtree(repo)
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    write(repo / "README.md", "readme\n")
    write(repo / "src/alpha/a.py", "a = 1\n")
    write(repo / "src/beta/b.py", "b = 1\n")
    write(repo / "src/shared.py", "shared = 1\n")
    write(repo / ".agents/skills/alpha/SKILL.md", skill("alpha", "ALPHA-GOAL: keep alpha flexible."))
    write(repo / ".agents/skills/beta/SKILL.md", skill("beta", "BETA-GOAL: one queue."))
    comps = [{"id": "alpha", "skill": "alpha", "paths": ["src/alpha/**", "src/shared.py"]},
             {"id": "beta", "skill": "beta", "paths": ["src/beta/**", "src/shared.py"]}, *extra]
    write(repo / "docs/component-map.json", json.dumps({"schema": "component-map/v1", "components": comps}))
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "init")
    return repo


repo = make_repo("repo")
alpha_skill = str(repo / ".agents/skills/alpha/SKILL.md")

# --- help ---
rc, out, err = hook(args=["--help"], claude=False)
expect(rc == 0 and "Output contract" in out, "--help prints the contract", out + err)

# --- first touch injects, second is silent ---
ctx = pre("s1", repo / "src/alpha/a.py")
expect("ALPHA-GOAL: keep alpha flexible." in ctx and alpha_skill in ctx and "component alpha" in ctx
       and "src/alpha/a.py" in ctx and "BETA" not in ctx,
       "a Read under a mapped glob injects that component's goal and skill path", ctx)
expect(pre("s1", repo / "src/alpha/a.py") == "", "a second touch of the same file in the session is silent")
expect(pre("s1", repo / "src/alpha/new.py", tool="Write") == "",
       "a touch of another file of an injected component is silent")
ctx = pre("s2", repo / "src/beta/b.py", tool="Edit")
expect("BETA-GOAL: one queue." in ctx and "ALPHA" not in ctx, "an Edit under a mapped glob injects its goal", ctx)
ctx = pre("s2", "src/alpha/a.py", tool="NotebookEdit", cwd=repo)
expect("ALPHA-GOAL" in ctx, "a relative notebook_path resolves against cwd", ctx)

# --- multi-match, unmapped, no map ---
ctx = pre("s3", repo / "src/shared.py", tool="Write")
expect("ALPHA-GOAL" in ctx and "BETA-GOAL" in ctx, "a file in two components injects both", ctx)
expect(pre("s4", repo / "README.md") == "", "an unmapped path is silent")
bare = tmp / "bare"
bare.mkdir()
git(bare, "init", "-q")
write(bare / "x.py", "x\n")
expect(pre("s4", bare / "x.py") == "" and post_bash("s4", bare) == "", "a repository with no map is silent")
expect(pre("s4", tmp / "nowhere/x.py") == "", "a path in no repository is silent")
expect(pre("s4", repo / "src/alpha/later/x.py", tool="Write") != "",
       "a file created in a directory that does not exist yet still resolves")

# --- subagents have their own context ---
expect("ALPHA-GOAL" in pre("s1", repo / "src/alpha/a.py", agent="sub-1"),
       "a subagent gets its own injection for a component its parent was told about")
expect(pre("s1", repo / "src/alpha/a.py", agent="sub-1") == "", "a subagent's second touch is silent")

# --- compact resets the main context's record only ---
rc, out, err = hook({"hook_event_name": "SessionStart", "session_id": "s1", "source": "compact"})
expect(rc == 0 and out == "", "a compact SessionStart prints nothing", out + err)
expect("ALPHA-GOAL" in pre("s1", repo / "src/alpha/a.py"), "after compaction the goal is injected again")
expect(pre("s1", repo / "src/alpha/a.py", agent="sub-1") == "", "compaction of the main context keeps a subagent's record")
rc, out, err = hook({"hook_event_name": "SessionStart", "session_id": "s1", "source": "resume"})
expect(rc == 0 and out == "" and pre("s1", repo / "src/alpha/a.py") == "", "a non-compact SessionStart keeps the record")

# --- PostToolUse Bash sweep ---
repo = make_repo("sweep")
write(repo / "README.md", "dirty before\n")
expect(post_bash("w1", repo) == "", "a sweep that finds only unmapped changes is silent")
expect(post_bash("w1", repo) == "", "an unchanged sweep is silent")
write(repo / "src/beta/b.py", "b = 2\n")
ctx = post_bash("w1", repo)
expect("BETA-GOAL" in ctx and "src/beta/b.py" in ctx and "ALPHA" not in ctx,
       "a mapped file changed by a shell command is caught by the sweep", ctx)
expect(post_bash("w1", repo) == "", "the next sweep with no new change is silent")
write(repo / "src/alpha/new file.py", "n\n")
ctx = post_bash("w1", repo)
expect("ALPHA-GOAL" in ctx and "src/alpha/new file.py" in ctx, "a new untracked mapped file with a space is caught", ctx)
git(repo, "mv", "src/shared.py", "src/shared2.py")
expect(post_bash("w2", repo) != "", "a rename entry is parsed without error")

# --- unusable map ---
repo = make_repo("broken")
write(repo / "docs/component-map.json", "{not json")
ctx = pre("b1", repo / "src/alpha/a.py")
expect(str(repo / "docs/component-map.json") in ctx and "unusable" in ctx and ctx.count("\n") == 0,
       "an unusable map yields one context line naming the map", ctx)
expect(pre("b1", repo / "src/beta/b.py") == "", "an unusable map is reported once per session")
rc, out, err = hook({"hook_event_name": "PreToolUse", "session_id": "b2", "tool_name": "Read",
                     "tool_input": {"file_path": str(repo / "src/alpha/a.py")}}, claude=False)
expect(rc == 0 and "deny" not in out + err, "an unusable map never denies", out + err)

# --- fail open ---
for payload in ("", "not json", "[]", '{"tool_input": 5}'):
    rc, out, err = hook(payload)
    expect(rc == 0 and out == "", f"malformed stdin {payload!r} fails open silently", out + err)

# --- home map ---
kit_skill = tmp / "skills/kit/SKILL.md"
write(kit_skill, skill("kit", "KIT-GOAL: frozen behind adapters."))
write(HOME / "config/component-map.json", json.dumps({"schema": "component-map/v1", "components": [
    {"id": "kit", "skill": str(kit_skill), "paths": [str(HOME / "data/kit/**")]}]}))
write(HOME / "data/kit/run.sh", "run\n")
ctx = pre("h1", HOME / "data/kit/run.sh", tool="Edit")
expect("KIT-GOAL" in ctx and str(kit_skill) in ctx, "a path the home map claims injects the home component", ctx)
repo = make_repo("homerepo", extra=[{"id": "gamma", "skill": "alpha", "paths": ["lib/**"]}])
write(HOME / "config/component-map.json", json.dumps({"schema": "component-map/v1", "components": [
    {"id": "kit", "skill": str(kit_skill), "paths": [str(repo / "src/alpha/**")]}]}))
ctx = pre("h2", repo / "src/alpha/a.py")
expect("KIT-GOAL" in ctx and "ALPHA-GOAL" in ctx, "the home map applies beside the repository map", ctx)
os.remove(HOME / "config/component-map.json")

# --- output cap ---
big = [{"id": f"c{n}", "skill": f"c{n}", "paths": ["src/many/**"]} for n in range(10)]
repo = make_repo("cap", extra=big)
for n in range(10):
    write(repo / f".agents/skills/c{n}/SKILL.md", skill(f"c{n}", f"C{n}-GOAL " + "g" * 1292))
for n in range(10):
    write(repo / f"src/many/f{n}.py", "x\n")
ctx = post_bash("c1", repo)
expect(0 < len(ctx) < 10000, f"a sweep touching ten large goals stays under 10,000 characters ({len(ctx)})")
told = [n for n in range(10) if f"C{n}-GOAL" in ctx]
expect(0 < len(told) < 10, f"the cap carries some goals and holds the rest back ({told})", ctx[:300])
expect(any(f"component c{n}" in ctx and "comes with the next touch" in ctx for n in range(10) if n not in told),
       "a goal held back by the cap leaves its pointer line", ctx[-600:])
rest = pre("c1", repo / "src/many/f0.py")
expect(all(f"C{n}-GOAL" in rest for n in range(10) if n not in told) and all(f"C{n}-GOAL" not in rest for n in told),
       "goals held back by the cap arrive on the next touch, and only those", rest[:400])

# --- Grok and --tool shapes classify the same ---
repo = make_repo("shapes")
rc, out, err = hook({"toolName": "Edit", "toolInput": {"file_path": str(repo / "src/alpha/a.py")},
                     "sessionId": "g1"}, claude=False)
expect(rc == 0 and "ALPHA-GOAL" in out and "BETA" not in out and not out.lstrip().startswith("{"),
       "Grok's input shape classifies like Claude's, with plain-text output", out + err)
rc, out, err = hook(args=["--tool", "Edit", "--path", str(repo / "src/shared.py"), "--session", "t1"], claude=False)
expect(rc == 0 and "ALPHA-GOAL" in out and "BETA-GOAL" in out, "the --tool form classifies like Claude's", out + err)
rc, out, err = hook(args=["--tool", "Edit", "--path", str(repo / "src/shared.py"), "--session", "t1"], claude=False)
expect(rc == 0 and out == "", "the --tool form dedups by --session", out + err)
write(repo / "src/beta/b.py", "b = 3\n")
rc, out, err = hook(args=["--tool", "bash", "--cwd", str(repo), "--session", "t2"], claude=False)
expect(rc == 0 and "BETA-GOAL" in out, "the --tool form sweeps for a bash tool", out + err)
rc, out, err = hook(args=["--tool", "Grep", "--cwd", str(repo), "--session", "t3"], claude=False)
expect(rc == 0 and out == "", "a tool with no path that is not bash is silent", out + err)
PY
