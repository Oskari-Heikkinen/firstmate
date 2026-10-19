#!/usr/bin/env python3
"""Component map logic behind bin/fm-component-map.sh.

That script's header owns the usage and the exit-code contract, and
docs/component-map.md owns the map schema, the glob syntax and the skill shape.
This file only implements them; it reads maps, skills and pinned sources and
writes nothing.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

SCHEMA = "component-map/v1"
REPO_MAP = os.path.join("docs", "component-map.json")
SKILL_DIRS = (os.path.join(".agents", "skills"), os.path.join(".claude", "skills"))
GOAL = "Goal and operating principle"
REFUSE = "Refuse"
REVIEW = "Review"
REQUIRED_SECTIONS = (GOAL, REFUSE, REVIEW)
# The goal section is the text sized for injection, under the 10,000-character
# cap on a hook's output. Six components of 1,500 characters claiming one path
# leave room for their path lines, so check refuses a seventh.
GOAL_LIMIT = 1500
MAX_CLAIMS = 6
# skill-creator's validator keys plus Claude Code's documented skill keys: check
# validates what the harness accepts, not one authoring style.
FRONTMATTER_KEYS = {"name", "description", "license", "allowed-tools", "metadata", "compatibility",
                    "user-invocable", "disable-model-invocation", "when_to_use", "argument-hint", "model", "paths"}
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")

OK, FINDINGS, USAGE, MAP_UNUSABLE = 0, 1, 2, 3


class UsageError(Exception):
    pass


class MapError(Exception):
    def __init__(self, path, problems):
        super().__init__(problems[0])
        self.path = path
        self.problems = problems


# ---------- globs ----------

def glob_problem(glob, absolute):
    if not isinstance(glob, str) or not glob:
        return "a glob must be a non-empty string"
    if absolute and not glob.startswith("/"):
        return f"{glob!r} must be an absolute path glob in a home map"
    if not absolute and glob.startswith("/"):
        return f"{glob!r} must be relative to the repository root"
    for seg in (glob[1:] if absolute else glob).split("/"):
        if seg in ("", ".", ".."):
            return f"{glob!r} has an empty, '.' or '..' segment"
        if "**" in seg and seg != "**":
            return f"{glob!r}: '**' must be a whole path segment"
    try:
        glob_regex(glob)
    except re.error as exc:
        return f"{glob!r} is not a valid glob ({exc})"
    return None


def glob_regex(glob):
    out = []
    segments = glob.split("/")
    last = len(segments) - 1
    for i, seg in enumerate(segments):
        if seg == "**":
            # a/**/b matches a/b too; a trailing ** matches everything below.
            out.append(".*" if i == last else "(?:[^/]+/)*")
            continue
        j = 0
        while j < len(seg):
            ch = seg[j]
            if ch == "*":
                out.append("[^/]*")
            elif ch == "?":
                out.append("[^/]")
            elif ch == "[":
                end = seg.find("]", j + 2 if seg[j + 1:j + 2] in ("!", "^") else j + 1)
                if end < 0:
                    out.append(re.escape(ch))
                else:
                    body = seg[j + 1:end]
                    if body[:1] in ("!", "^"):
                        body = "^" + body[1:]
                    out.append("[" + body.replace("\\", "\\\\") + "]")
                    j = end
            else:
                out.append(re.escape(ch))
            j += 1
        if i != last:
            out.append("/")
    return re.compile("".join(out))


# ---------- maps ----------

class Component:
    def __init__(self, cid, skill, globs, provisional):
        self.id = cid
        self.skill = skill
        self.globs = globs
        self.provisional = provisional
        self.regexes = [glob_regex(g) for g in globs]

    def matches(self, path):
        return any(r.fullmatch(path) for r in self.regexes)


class Map:
    def __init__(self, path, home, root, components, roots):
        self.path = path
        self.home = home
        self.root = root
        self.components = components
        self.roots = roots
        self.root_regexes = [glob_regex(g) for g in roots]

    def skill_path(self, comp):
        """Absolute SKILL.md path for a component, or None when no file exists."""
        if self.home:
            return comp.skill if os.path.isfile(comp.skill) else None
        for sub in SKILL_DIRS:
            cand = os.path.join(self.root, sub, comp.skill, "SKILL.md")
            if os.path.isfile(cand):
                return cand
        return None

    def skill_label(self, comp):
        found = self.skill_path(comp)
        if found:
            return found
        if self.home:
            return comp.skill
        return os.path.join(self.root, SKILL_DIRS[0], comp.skill, "SKILL.md")


def load_map(path, home, root):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as exc:
        raise MapError(path, [f"cannot read the map ({exc.strerror})"])
    except (ValueError, UnicodeDecodeError) as exc:
        raise MapError(path, [f"the map is not valid JSON ({exc})"])
    problems = []
    if not isinstance(data, dict):
        raise MapError(path, ["the map must be a JSON object"])
    allowed = {"schema", "components"} if home else {"schema", "components", "roots"}
    for key in sorted(set(data) - allowed):
        problems.append(f"unknown top-level key {key!r}")
    if data.get("schema") != SCHEMA:
        problems.append(f"schema must be {SCHEMA!r}")
    roots = data.get("roots", [])
    if not isinstance(roots, list):
        problems.append("roots must be a list of globs")
        roots = []
    for glob in roots:
        problem = glob_problem(glob, home)
        if problem:
            problems.append(f"roots: {problem}")
    comps = data.get("components")
    out = []
    if not isinstance(comps, list) or not comps:
        problems.append("components must be a non-empty list")
        comps = []
    seen = set()
    for idx, comp in enumerate(comps):
        where = f"components[{idx}]"
        if not isinstance(comp, dict):
            problems.append(f"{where} must be an object")
            continue
        for key in sorted(set(comp) - {"id", "skill", "paths", "provisional"}):
            problems.append(f"{where}: unknown key {key!r}")
        cid = comp.get("id")
        if not isinstance(cid, str) or not ID_RE.match(cid):
            problems.append(f"{where}: id must match {ID_RE.pattern}")
        elif cid in seen:
            problems.append(f"{where}: duplicate id {cid!r}")
        else:
            seen.add(cid)
            where = f"component {cid}"
        skill = comp.get("skill")
        if home:
            if not isinstance(skill, str) or not os.path.isabs(skill) or os.path.basename(skill) != "SKILL.md":
                problems.append(f"{where}: skill must be an absolute path to a SKILL.md in a home map")
        elif not isinstance(skill, str) or not NAME_RE.match(skill):
            problems.append(f"{where}: skill must be a kebab-case skill name")
        globs = comp.get("paths")
        if not isinstance(globs, list) or not globs:
            problems.append(f"{where}: paths must be a non-empty list of globs")
            globs = []
        for glob in globs:
            problem = glob_problem(glob, home)
            if problem:
                problems.append(f"{where}: {problem}")
        provisional = comp.get("provisional", False)
        if not isinstance(provisional, bool):
            problems.append(f"{where}: provisional must be true or false")
        if not problems:
            out.append(Component(cid, skill, globs, provisional))
    if problems:
        raise MapError(path, problems)
    return Map(path, home, root, out, roots)


def repo_map(repo):
    return load_map(os.path.join(repo, REPO_MAP), False, repo)


def is_repo_map(path):
    top = git_toplevel(os.path.dirname(os.path.abspath(path)))
    return bool(top) and os.path.realpath(path) == os.path.realpath(os.path.join(top, REPO_MAP))


# ---------- skills ----------

def parse_scalar(raw, lineno):
    text = raw.strip()
    if not text:
        return None
    if text[0] == '"':
        try:
            value, end = json.JSONDecoder().raw_decode(text)
        except ValueError:
            raise ValueError(f"line {lineno}: unterminated or invalid double-quoted value")
        rest = text[end:].strip()
        if rest and not rest.startswith("#"):
            raise ValueError(f"line {lineno}: text after a quoted value")
        return value
    if text[0] == "'":
        m = re.match(r"'((?:[^']|'')*)'\s*(#.*)?$", text)
        if not m:
            raise ValueError(f"line {lineno}: unterminated single-quoted value")
        return m.group(1).replace("''", "'")
    if text in ("[]", "{}"):
        return [] if text == "[]" else {}
    if text[0] in "[{&*!%@`":
        raise ValueError(f"line {lineno}: flow collections, anchors and tags are outside the supported YAML subset")
    text = re.sub(r"\s+#.*$", "", text)
    if text in ("true", "True", "false", "False"):
        return text.lower() == "true"
    if text in ("null", "~"):
        return None
    if re.fullmatch(r"-?[0-9]+", text):
        return int(text)
    return text


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def parse_yaml(lines):
    """Parse the YAML subset skills use: block mappings, block sequences,
    plain and quoted scalars, and | or > block scalars."""
    rows = []
    for n, line in enumerate(lines, 1):
        if "\t" in line[:indent_of(line) + 1] and line.strip():
            raise ValueError(f"line {n}: tab indentation")
        rows.append((n, line))

    def skip(i):
        while i < len(rows) and (not rows[i][1].strip() or rows[i][1].lstrip().startswith("#")):
            i += 1
        return i

    def block_scalar(i, parent_indent, style, lineno):
        body = []
        while i < len(rows) and (not rows[i][1].strip() or indent_of(rows[i][1]) > parent_indent):
            body.append(rows[i][1])
            i += 1
        while body and not body[-1].strip():
            body.pop()
        if not body:
            return "", i
        cut = min(indent_of(b) for b in body if b.strip())
        body = [b[cut:] for b in body]
        if style[0] == "|":
            text = "\n".join(body)
        else:
            paras, cur = [], []
            for b in body:
                if b.strip():
                    cur.append(b.strip())
                else:
                    paras.append(" ".join(cur))
                    cur = []
            paras.append(" ".join(cur))
            text = "\n".join(paras)
        if not style.endswith("-"):
            text += "\n"
        return text, i

    def value_after(i, rest, indent, lineno, seq_ok):
        """Value of a key whose inline text is rest, at the key's indent."""
        rest = rest.strip()
        if rest in ("|", "|-", ">", ">-"):
            return block_scalar(i, indent, rest, lineno)
        if rest and not rest.startswith("#"):
            value = parse_scalar(rest, lineno)
            # A plain scalar may continue on more-indented lines.
            j = skip(i)
            if isinstance(value, str) and rest[0] not in "\"'":
                while j < len(rows) and indent_of(rows[j][1]) > indent:
                    value += " " + rows[j][1].strip()
                    i = j + 1
                    j = skip(i)
            return value, i
        j = skip(i)
        if j < len(rows):
            ind = indent_of(rows[j][1])
            starts_seq = rows[j][1].lstrip().startswith("- ") or rows[j][1].strip() == "-"
            if ind > indent or (seq_ok and ind == indent and starts_seq):
                return node(j, ind)
        return None, i

    def node(i, indent):
        i = skip(i)
        line = rows[i][1]
        if line.lstrip().startswith("- ") or line.strip() == "-":
            return sequence(i, indent)
        return mapping(i, indent)

    def sequence(i, indent):
        items = []
        while True:
            i = skip(i)
            if i >= len(rows) or indent_of(rows[i][1]) != indent:
                break
            n, line = rows[i][0], rows[i][1].rstrip()
            stripped = line.strip()
            if not (stripped.startswith("- ") or stripped == "-"):
                break
            content = stripped[1:].lstrip()
            inner = indent + (len(line) - indent - len(content)) if content else indent + 2
            if re.match(r"[A-Za-z0-9_.-]+\s*:(\s|$)", content):
                rows[i] = (n, " " * inner + content)
                value, i = mapping(i, inner)
            elif content:
                value, i = parse_scalar(content, n), i + 1
            else:
                value, i = value_after(i + 1, "", indent, n, False)
            items.append(value)
        return items, i

    def mapping(i, indent):
        out = {}
        while True:
            i = skip(i)
            if i >= len(rows):
                break
            n, line = rows[i]
            ind = indent_of(line)
            if ind < indent:
                break
            if ind > indent:
                raise ValueError(f"line {n}: unexpected indentation")
            m = re.match(r"([A-Za-z0-9_.-]+)\s*:(\s(.*)|$)", line.strip())
            if not m:
                if line.strip().startswith("- "):
                    break
                raise ValueError(f"line {n}: expected 'key: value'")
            key = m.group(1)
            if key in out:
                raise ValueError(f"line {n}: duplicate key {key!r}")
            out[key], i = value_after(i + 1, m.group(3) or "", indent, n, True)
        return out, i

    start = skip(0)
    if start >= len(rows):
        return {}
    value, end = node(start, indent_of(rows[start][1]))
    end = skip(end)
    if end < len(rows):
        raise ValueError(f"line {rows[end][0]}: unexpected text")
    return value


def split_frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0].rstrip() != "---":
        raise ValueError("no frontmatter: the file must start with a '---' line")
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            return lines[1:i], "\n".join(lines[i + 1:])
    raise ValueError("frontmatter has no closing '---' line")


def read_skill(path):
    """(frontmatter dict, body) for a SKILL.md; raises ValueError on a bad file."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise ValueError(f"cannot read ({exc.strerror})")
    except UnicodeDecodeError:
        raise ValueError("not UTF-8 text")
    fm_lines, body = split_frontmatter(text.replace("\r\n", "\n"))
    try:
        fm = parse_yaml(fm_lines)
    except ValueError as exc:
        raise ValueError(f"frontmatter: {exc}")
    if not isinstance(fm, dict):
        raise ValueError("frontmatter must be a mapping")
    return fm, body


def sections(body):
    """Level-2 sections of a Markdown body: {title: [text, ...]}; fenced code is opaque."""
    out = {}
    title, buf, fence = None, [], None
    for line in body.split("\n"):
        m = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                fence = None
        elif m:
            fence = m.group(1)
        else:
            h = re.match(r"(#{1,2})\s+(.*?)\s*$", line)
            if h:
                if title is not None:
                    out.setdefault(title, []).append("\n".join(buf).strip("\n"))
                title, buf = (h.group(2) if len(h.group(1)) == 2 else None), []
                continue
        if title is not None:
            buf.append(line)
    if title is not None:
        out.setdefault(title, []).append("\n".join(buf).strip("\n"))
    return out


def pins(fm):
    meta = fm.get("metadata")
    if not isinstance(meta, dict):
        return []
    srcs = meta.get("sources")
    return srcs if isinstance(srcs, list) else []


def skill_problems(path, expected_name):
    try:
        fm, body = read_skill(path)
    except ValueError as exc:
        return [str(exc)]
    problems = []
    for key in sorted(set(fm) - FRONTMATTER_KEYS):
        problems.append(f"frontmatter: unknown key {key!r} (allowed: {', '.join(sorted(FRONTMATTER_KEYS))})")
    name = fm.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name.strip()) or len(name.strip()) > 64:
        problems.append("frontmatter: name must be a kebab-case string of at most 64 characters")
    elif name.strip() != expected_name:
        problems.append(f"frontmatter: name {name.strip()!r} differs from the skill directory {expected_name!r}")
    desc = fm.get("description")
    if not isinstance(desc, str) or not desc.strip():
        problems.append("frontmatter: description must be a non-empty string")
    else:
        if "<" in desc or ">" in desc:
            problems.append("frontmatter: description must not contain angle brackets")
        if len(desc.strip()) > 1024:
            problems.append(f"frontmatter: description is {len(desc.strip())} characters; the limit is 1024")
    compat = fm.get("compatibility")
    if compat is not None and (not isinstance(compat, str) or len(compat) > 500):
        problems.append("frontmatter: compatibility must be a string of at most 500 characters")
    for key in ("user-invocable", "disable-model-invocation"):
        if key in fm and not isinstance(fm[key], bool):
            problems.append(f"frontmatter: {key} must be true or false")
    for key in ("when_to_use", "argument-hint", "model"):
        if key in fm and not isinstance(fm[key], str):
            problems.append(f"frontmatter: {key} must be a string")
    if "paths" in fm and not (isinstance(fm["paths"], str)
                              or isinstance(fm["paths"], list) and all(isinstance(p, str) for p in fm["paths"])):
        problems.append("frontmatter: paths must be a string or a list of strings")
    meta = fm.get("metadata")
    if meta is not None and not isinstance(meta, dict):
        problems.append("frontmatter: metadata must be a mapping")
    elif isinstance(meta, dict) and "sources" in meta:
        srcs = meta["sources"]
        if not isinstance(srcs, list):
            problems.append("frontmatter: metadata.sources must be a list of {path, sha256}")
        else:
            for idx, pin in enumerate(srcs):
                if (not isinstance(pin, dict) or set(pin) != {"path", "sha256"}
                        or not isinstance(pin["path"], str) or not pin["path"].strip()
                        or not isinstance(pin["sha256"], str) or not SHA_RE.match(pin["sha256"])):
                    problems.append(f"frontmatter: metadata.sources[{idx}] must have exactly a path and a lowercase 64-hex sha256")
    secs = sections(body)
    for title in REQUIRED_SECTIONS:
        found = secs.get(title, [])
        if not found:
            problems.append(f"missing required section '## {title}'")
        elif len(found) > 1:
            problems.append(f"section '## {title}' appears {len(found)} times")
        elif not found[0].strip():
            problems.append(f"section '## {title}' is empty")
    goal = secs.get(GOAL, [""])[0].strip()
    if len(goal) > GOAL_LIMIT:
        problems.append(f"section '## {GOAL}' is {len(goal)} characters; the injection limit is {GOAL_LIMIT}")
    return problems


# ---------- git and paths ----------

def git(root, *args):
    proc = subprocess.run(["git", "-C", root, *args], capture_output=True)
    if proc.returncode != 0:
        msg = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise UsageError(f"git {' '.join(args[:2])} failed in {root}: {msg[-1] if msg else 'exit ' + str(proc.returncode)}")
    return proc.stdout


def git_toplevel(path):
    proc = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True)
    return proc.stdout.decode().strip() if proc.returncode == 0 else ""


def repo_root(arg):
    if not os.path.isdir(arg):
        raise UsageError(f"not a directory: {arg}")
    top = git_toplevel(arg)
    if not top:
        raise UsageError(f"not a git repository: {arg}")
    if os.path.realpath(top) != os.path.realpath(arg):
        raise UsageError(f"not the repository top level: {arg} (top level is {top})")
    return os.path.abspath(arg)


def nul_list(raw):
    return [p for p in raw.decode("utf-8", "surrogateescape").split("\0") if p]


def repo_relative(repo, path):
    """Repo-relative form of an input path, or None when it is outside the repo."""
    if not os.path.isabs(path):
        rel = os.path.normpath(path)
        return None if rel == ".." or rel.startswith("../") or rel == "." else rel
    roots = {os.path.abspath(repo), os.path.realpath(repo)}
    for cand in {os.path.normpath(path), os.path.realpath(path)}:
        for root in roots:
            if cand.startswith(root.rstrip("/") + "/"):
                return cand[len(root.rstrip("/")) + 1:]
    return None


def source_path(skill, raw):
    path = os.path.expanduser(raw)
    if os.path.isabs(path):
        return path
    base = os.path.dirname(os.path.abspath(skill))
    probe = base
    while True:
        if os.path.exists(os.path.join(probe, ".git")):
            return os.path.join(probe, path)
        parent = os.path.dirname(probe)
        if parent == probe:
            return os.path.join(base, path)
        probe = parent


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------- subcommands ----------

def home_skill_problems(cmap):
    """check for a home map: every skill exists and has a valid shape; its globs
    name home data outside any repository, so no tracked-file check applies."""
    problems, checked = [], set()
    for comp in cmap.components:
        skill = cmap.skill_path(comp)
        if skill is None:
            problems.append(f"component {comp.id}: skill {comp.skill} not found")
            continue
        if skill in checked:
            continue
        checked.add(skill)
        for problem in skill_problems(skill, os.path.basename(os.path.dirname(skill))):
            problems.append(f"{skill}: {problem}")
    if problems:
        for line in problems:
            print(line)
        return FINDINGS
    print(f"ok: {len(cmap.components)} components, {len(checked)} skills (home map: globs not checked)")
    return OK


def cmd_check(args):
    if len(args) != 1:
        raise UsageError("check needs exactly <repo|map>")
    cmap = map_arg(args[0], "check")
    if cmap is None:
        print(f"{REPO_MAP}: no component map", file=sys.stderr)
        return MAP_UNUSABLE
    if cmap.home:
        return home_skill_problems(cmap)
    repo = cmap.root
    tracked = nul_list(git(repo, "ls-files", "-z", "--full-name"))
    problems, notes = [], []
    checked = set()
    for comp in cmap.components:
        skill = cmap.skill_path(comp)
        if skill is None:
            problems.append(f"component {comp.id}: skill {comp.skill!r} not found in {' or '.join(SKILL_DIRS)}")
            continue
        if skill in checked:
            continue
        checked.add(skill)
        if not cmap.home:
            others = [os.path.join(repo, d, comp.skill, "SKILL.md") for d in SKILL_DIRS]
            found = {os.path.realpath(o) for o in others if os.path.isfile(o)}
            if len(found) > 1:
                problems.append(f"component {comp.id}: skill {comp.skill!r} exists in both {SKILL_DIRS[0]} and {SKILL_DIRS[1]}")
        rel = os.path.relpath(skill, repo)
        for problem in skill_problems(skill, os.path.basename(os.path.dirname(skill))):
            problems.append(f"{rel}: {problem}")
    for comp in cmap.components:
        unmatched = [g for g, r in zip(comp.globs, comp.regexes) if not any(r.fullmatch(p) for p in tracked)]
        if comp.provisional:
            if not unmatched:
                notes.append(f"note: component {comp.id}: every glob now matches a tracked file; it may drop provisional")
            continue
        for glob in unmatched:
            problems.append(f"component {comp.id}: glob {glob!r} matches no tracked file")
    for glob, regex in zip(cmap.roots, cmap.root_regexes):
        if not any(regex.fullmatch(p) for p in tracked):
            problems.append(f"roots: glob {glob!r} matches no tracked file")
    if not cmap.roots:
        notes.append("note: the map has no roots, so coverage is not checked")
    for path in tracked:
        claims = sum(1 for c in cmap.components if c.matches(path))
        if claims > MAX_CLAIMS:
            problems.append(f"{path}: claimed by {claims} components; at most {MAX_CLAIMS} fit the hook output cap")
        if not claims and any(r.fullmatch(path) for r in cmap.root_regexes):
            problems.append(f"{path}: under a component root but in no component")
    for line in notes:
        print(line)
    if problems:
        for line in problems:
            print(line)
        return FINDINGS
    print(f"ok: {len(cmap.components)} components, {len(checked)} skills, {len(tracked)} tracked files")
    return OK


def home_forms(path):
    """The absolute forms of an input path that a home map's globs may name."""
    path = os.path.abspath(path)
    return {path, os.path.realpath(path)}


def cmd_touched(args):
    if len(args) < 2:
        raise UsageError("touched needs <repo|map> and at least one <path>")
    target, paths = args[0], args[1:]
    if os.path.isfile(target) and not is_repo_map(target):
        cmap = load_map(target, True, None)
    else:
        repo = git_toplevel(os.path.dirname(os.path.abspath(target))) if os.path.isfile(target) else target
        if not os.path.isdir(repo):
            raise UsageError(f"not a directory or map: {target}")
        if not os.path.exists(os.path.join(repo, REPO_MAP)):
            return OK
        cmap = repo_map(repo)
    out = []
    for path in paths:
        if cmap.home:
            forms = home_forms(path)
        else:
            rel = repo_relative(cmap.root, path)
            forms = set() if rel is None else {rel}
        hits = [c for c in cmap.components if any(c.matches(f) for f in forms)]
        if not hits:
            out.append(f"unmapped\t{path}")
        for comp in hits:
            out.append(f"match\t{path}\t{comp.id}\t{cmap.skill_label(comp)}\t{int(comp.provisional)}")
    print("\n".join(out))
    return OK


def cmd_review_pack(args):
    if len(args) != 3:
        raise UsageError("review-pack needs <repo> <base> <head>")
    repo = repo_root(args[0])
    changed = nul_list(git(repo, "diff", "--name-only", "--no-renames", "-z", f"{args[1]}...{args[2]}", "--"))
    if not os.path.exists(os.path.join(repo, REPO_MAP)):
        return OK
    cmap = repo_map(repo)
    blocks, rc = [], OK
    for comp in cmap.components:
        hit = [p for p in changed if comp.matches(p)]
        if not hit:
            continue
        skill = cmap.skill_label(comp)
        head = f"## Component {comp.id}{' (provisional)' if comp.provisional else ''}\n"
        head += f"Skill: {skill}\nChanged paths: {', '.join(hit)}\n"
        try:
            review = sections(read_skill(skill)[1]).get(REVIEW, [""])[0].strip()
            if not review:
                raise ValueError(f"no '## {REVIEW}' section")
        except ValueError as exc:
            review = f"Review checklist unavailable: {exc}."
            rc = FINDINGS
        blocks.append(head + "\n" + review)
    if blocks:
        print("\n\n".join(blocks))
    return rc


def map_arg(target, cmd):
    """The map a <repo|map> argument names: a repository top level's map (None
    when it has none), that map given as a file, or a home map file."""
    if os.path.isdir(target):
        repo = repo_root(target)
        return repo_map(repo) if os.path.exists(os.path.join(repo, REPO_MAP)) else None
    if os.path.isfile(target):
        if is_repo_map(target):
            return repo_map(git_toplevel(os.path.dirname(os.path.abspath(target))))
        return load_map(target, True, None)
    raise UsageError(f"{cmd}: no such repository or map: {target}")


def cmd_goal(args):
    if len(args) != 2:
        raise UsageError("goal needs <repo|map> and one <id>")
    cmap = map_arg(args[0], "goal")
    if cmap is None:
        print(f"{REPO_MAP}: no component map", file=sys.stderr)
        return MAP_UNUSABLE
    comp = next((c for c in cmap.components if c.id == args[1]), None)
    if comp is None:
        raise UsageError(f"goal: no component {args[1]!r} in {cmap.path}")
    skill = cmap.skill_label(comp)
    try:
        goal = sections(read_skill(skill)[1]).get(GOAL, [""])[0].strip()
        if not goal:
            raise ValueError(f"no '## {GOAL}' section")
    except ValueError as exc:
        print(f"{skill}: {exc}", file=sys.stderr)
        return FINDINGS
    print(goal)
    return OK


def cmd_drift(args):
    if len(args) != 1:
        raise UsageError("drift needs exactly <repo|map>")
    cmap = map_arg(args[0], "drift")
    if cmap is None:
        return OK
    owners = {}
    for comp in cmap.components:
        owners.setdefault(cmap.skill_label(comp), []).append(comp.id)
    out = []
    for skill, ids in owners.items():
        label = ",".join(ids)
        try:
            fm, _ = read_skill(skill)
        except ValueError as exc:
            out.append(f"unreadable\t{label}\t{skill}\t{exc}")
            continue
        for pin in pins(fm):
            if not isinstance(pin, dict) or not isinstance(pin.get("path"), str) or not isinstance(pin.get("sha256"), str):
                out.append(f"unreadable\t{label}\t{skill}\tmalformed metadata.sources entry")
                continue
            src = source_path(skill, pin["path"])
            try:
                now = sha256_file(src)
            except FileNotFoundError:
                out.append(f"vanished\t{label}\t{skill}\t{src}")
                continue
            except OSError as exc:
                out.append(f"unreadable\t{label}\t{skill}\t{src}: {exc.strerror}")
                continue
            if now != pin["sha256"]:
                out.append(f"changed\t{label}\t{skill}\t{src}\t{pin['sha256']}\t{now}")
    if out:
        print("\n".join(out))
        return FINDINGS
    return OK


COMMANDS = {"check": cmd_check, "touched": cmd_touched, "goal": cmd_goal, "review-pack": cmd_review_pack,
            "drift": cmd_drift}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print("fm-component-map: unknown or missing subcommand (see --help)", file=sys.stderr)
        return USAGE
    try:
        return COMMANDS[argv[0]](argv[1:])
    except UsageError as exc:
        print(f"fm-component-map: {exc}", file=sys.stderr)
        return USAGE
    except MapError as exc:
        for problem in exc.problems:
            print(f"{exc.path}: {problem}", file=sys.stderr)
        return MAP_UNUSABLE


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001 - any crash is "could not run", never a finding
        print(f"fm-component-map: internal error: {exc!r}", file=sys.stderr)
        sys.exit(USAGE)
