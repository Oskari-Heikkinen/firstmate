#!/usr/bin/env bash
# Component map: check validates the schema, the named skills, their
# frontmatter and required sections, the goal size limit, the two skill
# directories, non-provisional glob matches, root coverage and the claims limit;
# touched resolves multi-match, unmapped, outside, provisional and '**' paths
# and fails open without a map; review-pack carries each touched component's
# Review section across renames, deletions and spaces; drift reports a changed,
# a vanished and an unreadable pinned source for a repo map and a home map; one
# exit-code contract.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-component-map)

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
TOOL = str(root / "bin/fm-component-map.sh")
ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
           GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def run(*args, cwd=None):
    proc = subprocess.run([TOOL, *map(str, args)], capture_output=True, text=True, env=ENV, cwd=cwd)
    return proc.returncode, proc.stdout, proc.stderr


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=ENV)


def skill_text(name, goal="Keep the component flexible and fail closed.", refuse="- A second start path.",
               review="1. Does the change name a kind?", extra_fm="", sources=None, body_extra=""):
    fm = f"---\nname: {name}\ndescription: Load before changing {name}. One owner, fail closed.\n{extra_fm}"
    if sources:
        fm += "metadata:\n  sources:\n"
        for path, sha in sources:
            fm += f"    - path: {path}\n      sha256: {sha}\n"
    fm += "---\n\n"
    body = f"# {name}\n\n## Goal and operating principle\n{goal}\n\n## Refuse\n{refuse}\n\n## Review\n{review}\n{body_extra}"
    return fm + body


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def make_repo(name):
    repo = tmp / name
    if repo.exists():
        shutil.rmtree(repo)
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    write(repo / "README.md", "readme\n")
    write(repo / "src/alpha/a.py", "a = 1\n")
    write(repo / "src/beta/b.py", "b = 1\n")
    write(repo / "src/shared.py", "shared = 1\n")
    write(repo / "docs/alpha.md", "alpha contract v1\n")
    outside = tmp / f"{name}-plan.md"
    write(outside, "plan v1\n")
    write(repo / ".agents/skills/alpha/SKILL.md", skill_text(
        "alpha", review="1. Alpha check: is the contract unchanged?",
        sources=[("docs/alpha.md", sha(repo / "docs/alpha.md"))]))
    # beta uses a folded description and sources at the key's own indent.
    write(repo / ".agents/skills/beta/SKILL.md",
          "---\nname: beta\ndescription: >-\n  Load before changing beta.\n  One queue.\nmetadata:\n  sources:\n  - path: "
          + str(outside) + "\n    sha256: " + sha(outside) + "\n---\n\n## Goal and operating principle\nBeta goal.\n\n"
          "## How it works\nIt queues.\n\n## Long-term-correct patterns\n- Policy as data.\n\n"
          "## Refuse\n- Sleep loops.\n\n## Review\n```\n## not a heading\n```\n1. Beta check: one admission?\n\n## Notes\nextra\n")
    write(repo / ".claude/skills/gamma/SKILL.md", skill_text("gamma", review="1. Gamma check."))
    cmap = {"schema": "component-map/v1", "roots": ["src/**"], "components": [
        {"id": "alpha", "skill": "alpha", "paths": ["src/alpha/**", "src/shared.py", "docs/alpha.md"]},
        {"id": "beta", "skill": "beta", "paths": ["src/beta/*.py", "src/shared.py"], "provisional": False},
        {"id": "gamma", "skill": "gamma", "paths": ["tools/gamma/**"], "provisional": True}]}
    write(repo / "docs/component-map.json", json.dumps(cmap, indent=1))
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "init")
    return repo, cmap


def set_map(repo, cmap):
    write(repo / "docs/component-map.json", json.dumps(cmap, indent=1))


# --- help and usage ---
rc, out, err = run("--help")
expect(rc == 0 and "Exit codes" in out and "review-pack" in out, "--help prints the commands and the exit-code contract", out)
rc, out, err = run()
expect(rc == 2, "no subcommand exits 2", err)
rc, out, err = run("bogus", tmp)
expect(rc == 2, "an unknown subcommand exits 2", err)
rc, out, err = run("check")
expect(rc == 2, "check without a repo exits 2", err)

# --- a clean map passes check ---
repo, cmap = make_repo("clean")
rc, out, err = run("check", repo)
expect(rc == 0 and out.strip().startswith("ok: 3 components, 3 skills"), "a valid map and skills pass check", out + err)
expect("note:" not in out, "a provisional component whose globs match nothing gets no note", out)
noroots = dict(cmap)
del noroots["roots"]
set_map(repo, noroots)
rc, out, err = run("check", repo)
expect(rc == 0 and "note: the map has no roots, so coverage is not checked" in out and "ok:" in out,
       "a map without roots passes with a note that coverage is not checked", out + err)
set_map(repo, cmap)
rc, out, err = run("check", repo / "src")
expect(rc == 2 and "top level" in err, "check on a subdirectory exits 2", err)

# --- touched ---
rc, out, err = run("touched", repo, "src/shared.py")
lines = out.strip().split("\n")
expect(rc == 0 and len(lines) == 2 and lines[0].split("\t")[:3] == ["match", "src/shared.py", "alpha"]
       and lines[1].split("\t")[2] == "beta", "a path in two components matches both", out)
expect(lines[0].split("\t")[3] == str(repo / ".agents/skills/alpha/SKILL.md") and lines[0].split("\t")[4] == "0",
       "a match names the skill's absolute path and provisional 0", out)
rc, out, err = run("touched", repo, "README.md", str(tmp / "elsewhere.py"), "../clean/src/alpha/a.py")
expect(rc == 0 and out.strip().split("\n") == ["unmapped\tREADME.md", f"unmapped\t{tmp / 'elsewhere.py'}",
                                               "unmapped\t../clean/src/alpha/a.py"],
       "unmapped and outside paths print unmapped", out)
rc, out, err = run("touched", repo, str(repo / "src/alpha/new.py"), "tools/gamma/x/y.py", "src/beta/deep/c.py")
lines = out.strip().split("\n")
expect(rc == 0 and lines[0].split("\t")[2] == "alpha" and lines[1].split("\t")[2] == "gamma"
       and lines[1].split("\t")[3] == str(repo / ".claude/skills/gamma/SKILL.md") and lines[1].split("\t")[4] == "1"
       and lines[2] == "unmapped\tsrc/beta/deep/c.py",
       "an absolute path, a not-yet-existing provisional path and a '*' that stops at '/' resolve correctly", out)
repo, cmap = make_repo("globs")
set_map(repo, {"schema": "component-map/v1", "components": [
    {"id": "x", "skill": "alpha", "paths": ["lib/**/b"]}, {"id": "all", "skill": "alpha", "paths": ["**"]}]})
rc, out, err = run("touched", repo, "lib/b", "lib/x/y/b", "lib/bb")
expect(rc == 0 and [line.split("\t")[1:3] for line in out.strip().split("\n")]
       == [["lib/b", "x"], ["lib/b", "all"], ["lib/x/y/b", "x"], ["lib/x/y/b", "all"], ["lib/bb", "all"]],
       "a middle '**' matches zero or more segments and a bare '**' matches every path", out + err)
bare = tmp / "bare"
bare.mkdir()
rc, out, err = run("touched", bare, "x.py")
expect(rc == 0 and out == "" and err == "", "touched fails open without a map", out + err)
rc, out, err = run("check", bare)
expect(rc == 2, "check on a non-repository exits 2", err)

# --- schema errors ---
bad = dict(cmap, schema="component-map/v0", extra=1, components=cmap["components"] + [
    {"id": "alpha", "skill": "Alpha", "paths": ["/abs/**", "src/x**"], "provisional": "yes", "owner": "me"}])
set_map(repo, bad)
rc, out, err = run("check", repo)
for needle in ("schema must be", "unknown top-level key 'extra'", "duplicate id 'alpha'", "kebab-case skill name",
               "relative to the repository root", "whole path segment", "provisional must be", "unknown key 'owner'"):
    expect(rc == 3 and needle in err, f"check reports a schema error: {needle}", err)
expect(all(line.startswith(str(repo / "docs/component-map.json")) for line in err.strip().split("\n")),
       "every schema error line names the map", err)
rc, out, err = run("touched", repo, "src/shared.py")
expect(rc == 3 and out == "" and "component-map.json" in err, "touched exits 3 on an unusable map", err)
write(repo / "docs/component-map.json", "{not json")
rc, out, err = run("check", repo)
expect(rc == 3 and "not valid JSON" in err, "invalid JSON exits 3", err)
os.remove(repo / "docs/component-map.json")
rc, out, err = run("check", repo)
expect(rc == 3 and "no component map" in err, "check exits 3 when the map is missing", err)

# --- coverage gaps, missing skills, unmatched globs ---
repo, cmap = make_repo("gaps")
write(repo / "src/orphan.py", "x\n")
git(repo, "add", "-A")
git(repo, "commit", "-qm", "orphan")
gap = json.loads(json.dumps(cmap))
gap["components"][1]["paths"].append("src/renamed/**")
gap["components"].append({"id": "delta", "skill": "delta", "paths": ["README.md"]})
gap["roots"].append("nothing/**")
set_map(repo, gap)
rc, out, err = run("check", repo)
expect(rc == 1 and "src/orphan.py: under a component root but in no component" in out,
       "a tracked file under a root in no component is a coverage gap", out)
expect("component beta: glob 'src/renamed/**' matches no tracked file" in out,
       "a non-provisional glob matching nothing is reported", out)
expect("component delta: skill 'delta' not found" in out, "a missing skill is reported", out)
expect("roots: glob 'nothing/**' matches no tracked file" in out, "a root matching nothing is reported", out)
expect("README.md:" not in out, "a file outside the roots may stay unmapped", out)

# --- claims limit ---
repo, cmap = make_repo("claims")
many = {"schema": "component-map/v1", "roots": ["src/**"],
        "components": [{"id": f"c{n}", "skill": "alpha", "paths": ["src/**"]} for n in range(7)]}
set_map(repo, many)
rc, out, err = run("check", repo)
expect(rc == 1 and "src/shared.py: claimed by 7 components; at most 6" in out,
       "a tracked file claimed by more than six components is reported", out + err)
many["components"].pop()
set_map(repo, many)
rc, out, err = run("check", repo)
expect(rc == 0 and out.startswith("ok: 6 components"), "six components on one path pass", out + err)

# --- provisional note ---
repo, cmap = make_repo("prov")
write(repo / "tools/gamma/run.py", "x\n")
git(repo, "add", "-A")
git(repo, "commit", "-qm", "gamma lands")
rc, out, err = run("check", repo)
expect(rc == 0 and "note: component gamma: every glob now matches a tracked file" in out,
       "a provisional component whose globs all match gets a note and still passes", out)

# --- bad frontmatter and skill shape ---
repo, cmap = make_repo("shape")
write(repo / ".agents/skills/alpha/SKILL.md", skill_text(
    "alfa", extra_fm="owner: me\n").replace("One owner, fail closed.", "One owner <fast>."))
write(repo / ".agents/skills/beta/SKILL.md", skill_text("beta", refuse="", review="1. ok") .replace("## Review", "## Reviews"))
write(repo / ".claude/skills/gamma/SKILL.md", "no frontmatter\n")
git(repo, "add", "-A")
git(repo, "commit", "-qm", "bad skills")
rc, out, err = run("check", repo)
for needle in (".agents/skills/alpha/SKILL.md: frontmatter: unknown key 'owner'",
               "name 'alfa' differs from the skill directory 'alpha'",
               "description must not contain angle brackets",
               ".agents/skills/beta/SKILL.md: section '## Refuse' is empty",
               ".agents/skills/beta/SKILL.md: missing required section '## Review'",
               ".claude/skills/gamma/SKILL.md: no frontmatter"):
    expect(rc == 1 and needle in out, f"check reports a skill problem: {needle}", out)
write(repo / ".agents/skills/alpha/SKILL.md", "---\nname: alpha\ndescription: [a, b]\n---\n")
write(repo / ".agents/skills/beta/SKILL.md", skill_text("beta", sources=[("docs/alpha.md", "ABC")]))
rc, out, err = run("check", repo)
expect(rc == 1 and "outside the supported YAML subset" in out, "a flow collection in frontmatter is refused", out)
expect("metadata.sources[0] must have exactly a path and a lowercase 64-hex sha256" in out, "a malformed pin is refused", out)
write(repo / ".agents/skills/alpha/SKILL.md", skill_text(
    "alpha", extra_fm="user-invocable: false\nwhen_to_use: Before edits.\nargument-hint: <file>\nmodel: opus\npaths:\n  - src/**\n"))
write(repo / ".agents/skills/beta/SKILL.md", skill_text("beta", extra_fm="disable-model-invocation: maybe\n"))
rc, out, err = run("check", repo)
expect(rc == 1 and ".agents/skills/alpha/SKILL.md" not in out,
       "Claude Code's documented skill keys are allowed", out)
expect(".agents/skills/beta/SKILL.md: frontmatter: disable-model-invocation must be true or false" in out,
       "a Claude Code skill key of the wrong type is refused", out)

# --- the two skill directories ---
repo, cmap = make_repo("links")
shutil.move(str(repo / ".claude/skills/gamma"), str(repo / ".agents/skills/gamma"))
os.rmdir(repo / ".claude/skills")
os.symlink("../.agents/skills", repo / ".claude/skills")
git(repo, "add", "-A")
git(repo, "commit", "-qm", "link skills")
rc, out, err = run("check", repo)
expect(rc == 0 and out.startswith("ok: 3 components"), "a .claude/skills symlink to .agents/skills is one copy of each skill", out + err)
repo, cmap = make_repo("copies")
write(repo / ".claude/skills/alpha/SKILL.md", (repo / ".agents/skills/alpha/SKILL.md").read_text())
rc, out, err = run("check", repo)
expect(rc == 1 and "component alpha: skill 'alpha' exists in both .agents/skills and .claude/skills" in out,
       "a skill present as two different files is reported", out + err)

# --- oversize goal ---
repo, cmap = make_repo("goal")
write(repo / ".agents/skills/alpha/SKILL.md", skill_text("alpha", goal="x" * 1501))
write(repo / ".agents/skills/beta/SKILL.md", skill_text("beta", goal="y" * 1500))
rc, out, err = run("check", repo)
expect(rc == 1 and ".agents/skills/alpha/SKILL.md: section '## Goal and operating principle' is 1501 characters; the injection limit is 1500" in out,
       "a goal section over the injection limit is reported", out)
expect("beta" not in out, "a goal section exactly at the limit passes", out)

# --- review pack ---
repo, cmap = make_repo("review")
base = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
write(repo / "src/alpha/a.py", "a = 2\n")
write(repo / "src/beta/b.py", "b = 2\n")
write(repo / "README.md", "readme 2\n")
git(repo, "add", "-A")
git(repo, "commit", "-qm", "touch two")
rc, out, err = run("review-pack", repo, base, "HEAD")
expect(rc == 0 and "## Component alpha" in out and "## Component beta" in out and "gamma" not in out,
       "a diff touching two components carries both and only those", out + err)
expect("1. Alpha check: is the contract unchanged?" in out and "1. Beta check: one admission?" in out
       and "## not a heading" in out and "extra" not in out and "It queues." not in out,
       "each block carries exactly its skill's Review section", out)
expect(f"Skill: {repo / '.agents/skills/alpha/SKILL.md'}" in out and "Changed paths: src/alpha/a.py" in out,
       "each block names its skill path and changed paths", out)
git(repo, "checkout", "-qb", "side", base)
write(repo / "README.md", "side readme\n")
git(repo, "commit", "-qam", "unmapped only")
rc, out, err = run("review-pack", repo, "main", "HEAD")
expect(rc == 0 and out == "", "a branch touching no component gets an empty pack (three-dot diff)", out + err)
rc, out, err = run("review-pack", repo, "main", "no-such-rev")
expect(rc == 2 and "git diff" in err, "a bad revision exits 2", err)
git(repo, "checkout", "-q", "main")
write(repo / ".agents/skills/beta/SKILL.md", skill_text("beta").replace("## Review", "## Later"))
rc, out, err = run("review-pack", repo, base, "HEAD")
expect(rc == 1 and "Review checklist unavailable: no '## Review' section." in out and "Alpha check" in out,
       "a component whose checklist cannot be read exits 1 and says why in its block", out)

# --- review pack across a rename, a deletion and a path with spaces ---
repo, cmap = make_repo("moves")
base = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
(repo / "lib").mkdir()
git(repo, "mv", "src/beta/b.py", "lib/new name.py")
git(repo, "rm", "-q", "src/alpha/a.py")
write(repo / "src/alpha/f 1.py", "f = 1\n")
git(repo, "add", "-A")
git(repo, "commit", "-qm", "move, delete, space")
rc, out, err = run("review-pack", repo, base, "HEAD")
expect(rc == 0 and "Changed paths: src/alpha/a.py, src/alpha/f 1.py\n" in out,
       "a deletion and a path with spaces are carried", out + err)
expect("## Component beta" in out and "Changed paths: src/beta/b.py\n" in out,
       "a rename out of a component still carries the component it left", out + err)

# --- drift ---
repo, cmap = make_repo("drift")
rc, out, err = run("drift", repo)
expect(rc == 0 and out == "", "drift is silent when every pin holds", out + err)
write(repo / "docs/alpha.md", "alpha contract v2\n")
os.remove(tmp / "drift-plan.md")
rc, out, err = run("drift", repo)
lines = sorted(out.strip().split("\n"))
expect(rc == 1 and len(lines) == 2, "drift reports exactly the changed and the vanished pin", out)
changed = lines[0].split("\t")
expect(changed[:4] == ["changed", "alpha", str(repo / ".agents/skills/alpha/SKILL.md"), str(repo / "docs/alpha.md")]
       and changed[5] == sha(repo / "docs/alpha.md"), "a changed repo-relative source is reported with both hashes", out)
expect(lines[1] == f"vanished\tbeta\t{repo / '.agents/skills/beta/SKILL.md'}\t{tmp / 'drift-plan.md'}",
       "a vanished absolute source is reported", out)
rc, out, err = run("drift", repo / "docs/component-map.json")
expect(rc == 1 and len(out.strip().split("\n")) == 2, "drift accepts a repo map file", out + err)
home_map = tmp / "home/config/component-map.json"
write(home_map, json.dumps({"schema": "component-map/v1", "components": [
    {"id": "kit", "skill": str(repo / ".agents/skills/alpha/SKILL.md"), "paths": [str(tmp / "home/data/kit/**")]}]}))
rc, out, err = run("drift", home_map)
expect(rc == 1 and out.startswith("changed\tkit\t"), "drift reads a home map with absolute skill paths", out + err)
write(home_map, json.dumps({"schema": "component-map/v1", "roots": ["/x/**"], "components": [
    {"id": "kit", "skill": "alpha", "paths": ["data/**"]}]}))
rc, out, err = run("drift", home_map)
expect(rc == 3 and "unknown top-level key 'roots'" in err and "absolute path to a SKILL.md" in err
       and "absolute path glob" in err, "a home map refuses roots, skill names and relative globs", err)
nomap = tmp / "nomap"
nomap.mkdir()
git(nomap, "init", "-q")
rc, out, err = run("drift", nomap)
expect(rc == 0 and out == "", "drift on a repository top level without a map is silent", out + err)
rc, out, err = run("drift", bare)
expect(rc == 2 and "not a git repository" in err, "drift on a directory outside any repository exits 2", err)
rc, out, err = run("drift", repo / "src")
expect(rc == 2 and "top level" in err, "drift on a repository subdirectory exits 2", err)
repo, cmap = make_repo("pindir")
write(repo / ".claude/skills/gamma/SKILL.md", skill_text("gamma", sources=[("src", "a" * 64)]))
rc, out, err = run("drift", repo)
expect(rc == 1 and out.startswith(f"unreadable\tgamma\t{repo / '.claude/skills/gamma/SKILL.md'}\t{repo / 'src'}: ")
       and "vanished" not in out, "a pin naming a directory is unreadable, not vanished", out + err)
rc, out, err = run("drift", tmp / "missing.json")
expect(rc == 2, "drift on a missing path exits 2", err)
PY
