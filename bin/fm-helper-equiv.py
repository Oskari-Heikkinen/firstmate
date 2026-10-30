#!/usr/bin/env python3
"""fm-helper-equiv.py - the engine behind bin/fm-helper-equiv.sh.

The shell script's header owns the commands, the output and the exit codes;
docs/helper-consumers.md ("Consumer call sets") owns the call-set format. This
file only implements them.
"""

import argparse
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

SCHEMA = "fm-helper-calls/v1"
MAX_CALLSET_BYTES = 64 * 1024
MAX_CALLS = 200
MAX_STATES = 8
DEFAULT_TIMEOUT = 60
MAX_TIMEOUT = 600
DEFAULT_DEADLINE = 900
HISTORY_LIMIT = 2000
KEEP_BYTES = 64 * 1024
CAPTURE_BUDGET = 32 * 1024 * 1024
MAX_STATE_ENTRIES = 10000
PREVIEW = 160
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
ENV_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
SHA_RE = re.compile(r"^sha256:([0-9a-f]{8,64})$")
ASPECTS = ("rc", "stdout", "stderr", "state")
RUNS = ("old", "old2", "new")


class Refused(Exception):
    """A refusal: the outcome line names the reason and the tool exits 2."""


def one_line(text, n=PREVIEW):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "~"


# ---------------------------------------------------------------- call sets

def unescape(token, where):
    out, i = [], 0
    while i < len(token):
        c = token[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = token[i + 1: i + 2]
        if nxt == "s":
            out.append(" ")
        elif nxt == "t":
            out.append("\t")
        elif nxt == "\\":
            out.append("\\")
        elif nxt == "e":
            if token != "\\e":
                raise Refused("%s: \\e must stand alone as an empty argument" % where)
        else:
            raise Refused("%s: unknown escape \\%s" % (where, nxt))
        i += 2
    return "".join(out)


def split_words(text, where):
    return [unescape(t, where) for t in text.split(" ") if t != ""]


def split_env(words, where):
    env, i = [], 0
    while i < len(words):
        m = ENV_RE.match(words[i])
        if not m:
            break
        env.append((m.group(1), m.group(2)))
        i += 1
    if i < len(words) and words[i] == "--":
        i += 1
    return env, words[i:]


def parse_callset(path):
    """Parse a call-set file; any malformed line refuses, naming file and line."""
    if not os.path.lexists(path):
        raise Refused("call set not found: %s" % path)
    if not os.path.isfile(path):
        raise Refused("call set is not a regular file: %s" % path)
    try:
        with open(path, "rb") as fh:
            raw = fh.read(MAX_CALLSET_BYTES + 1)
    except OSError as exc:
        raise Refused("call set unreadable: %s: %s" % (path, exc.strerror))
    if len(raw) > MAX_CALLSET_BYTES:
        raise Refused("call set larger than %d bytes: %s" % (MAX_CALLSET_BYTES, path))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise Refused("call set is not UTF-8: %s" % path)
    stem = os.path.basename(path)
    if not stem.endswith(".calls"):
        raise Refused("call set name must end in .calls: %s" % path)
    stem = stem[: -len(".calls")]
    base = os.path.dirname(os.path.abspath(path))
    cs = {"path": path, "sha256": hashlib.sha256(raw).hexdigest(), "consumer": None, "sections": []}
    sec = None
    seen_schema = False
    for no, line in enumerate(text.split("\n"), 1):
        where = "%s:%d" % (path, no)
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            raise Refused("%s: not key=value" % where)
        key, val = line.split("=", 1)
        if not seen_schema:
            if key != "schema" or val != SCHEMA:
                raise Refused("%s: first line must be schema=%s" % (where, SCHEMA))
            seen_schema = True
            continue
        if key == "consumer":
            if cs["consumer"] is not None or sec is not None:
                raise Refused("%s: consumer= must appear once, before any helper=" % where)
            if val != stem:
                raise Refused("%s: consumer=%s does not match the file name %s.calls" % (where, val, stem))
            cs["consumer"] = val
        elif key == "helper":
            if cs["consumer"] is None:
                raise Refused("%s: helper= before consumer=" % where)
            parts = val.split("/")
            if not val or val.startswith("/") or any(p in ("", ".", "..") for p in parts):
                raise Refused("%s: helper= must be a plain repository-relative path" % where)
            if any(s["helper"] == val for s in cs["sections"]):
                raise Refused("%s: helper %s appears twice" % (where, val))
            sec = {"helper": val, "fixture": None, "env": [], "states": [], "calls": [], "timeout": None}
            cs["sections"].append(sec)
        elif sec is None:
            raise Refused("%s: %s= before any helper=" % (where, key))
        elif key == "fixture":
            if sec["fixture"] is not None:
                raise Refused("%s: fixture= appears twice" % where)
            fx = os.path.normpath(os.path.join(base, val))
            if not val or val.startswith("/") or not os.path.isdir(fx):
                raise Refused("%s: fixture %s is not a directory beside the call set" % (where, val))
            sec["fixture"] = fx
        elif key == "env":
            m = ENV_RE.match(val)
            if not m:
                raise Refused("%s: env= needs NAME=VALUE" % where)
            sec["env"].append((m.group(1), m.group(2)))
        elif key == "state":
            words = split_words(val, where)
            if not words or not NAME_RE.match(words[0]):
                raise Refused("%s: state= needs a name of lowercase letters, digits and dashes" % where)
            if any(s["name"] == words[0] for s in sec["states"]):
                raise Refused("%s: state %s appears twice" % (where, words[0]))
            env, rest = split_env(words[1:], where)
            if rest:
                raise Refused("%s: state= takes only NAME=VALUE after its name" % where)
            sec["states"].append({"name": words[0], "env": env})
            if len(sec["states"]) > MAX_STATES:
                raise Refused("%s: more than %d states" % (where, MAX_STATES))
        elif key == "call":
            env, args = split_env(split_words(val, where), where)
            if not args:
                raise Refused("%s: call= has no arguments" % where)
            sec["calls"].append({"text": val, "env": env, "args": args})
            if len(sec["calls"]) > MAX_CALLS:
                raise Refused("%s: more than %d calls" % (where, MAX_CALLS))
        elif key == "timeout":
            if sec["timeout"] is not None or not val.isdigit() or not 1 <= int(val) <= MAX_TIMEOUT:
                raise Refused("%s: timeout= must appear once, 1-%d seconds" % (where, MAX_TIMEOUT))
            sec["timeout"] = int(val)
        else:
            raise Refused("%s: unknown key %s" % (where, key))
    if not seen_schema:
        raise Refused("%s: empty call set" % path)
    if cs["consumer"] is None:
        raise Refused("%s: no consumer= line" % path)
    if not cs["sections"]:
        raise Refused("%s: no helper= section" % path)
    for s in cs["sections"]:
        if not s["calls"]:
            raise Refused("%s: helper %s has no call= lines" % (path, s["helper"]))
        if not s["states"]:
            s["states"].append({"name": "default", "env": []})
        if s["timeout"] is None:
            s["timeout"] = DEFAULT_TIMEOUT
    return cs


# ---------------------------------------------------------------- versions

def git(repo, *args, **kw):
    return subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False, **kw)


def blob_sha256(repo, blobs):
    """sha256 of each blob id, read through one git cat-file --batch."""
    if not blobs:
        return {}
    p = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = {}
    try:
        p.stdin.write("".join(b + "\n" for b in blobs).encode())
        p.stdin.close()
        for b in blobs:
            header = p.stdout.readline().decode().split()
            if len(header) != 3 or header[1] != "blob":
                raise Refused("git cat-file could not read blob %s" % b)
            size = int(header[2])
            h = hashlib.sha256()
            left = size
            while left:
                chunk = p.stdout.read(min(left, 1 << 20))
                if not chunk:
                    raise Refused("git cat-file stopped inside blob %s" % b)
                h.update(chunk)
                left -= len(chunk)
            p.stdout.read(1)
            out[b] = h.hexdigest()
    finally:
        p.stdout.close()
        p.wait()
    return out


def resolve(repo, helper, spec):
    """Return (commit, sha256) for a version spec: sha256:<hex prefix> or a git revision."""
    m = SHA_RE.match(spec)
    if not m:
        r = git(repo, "rev-parse", "--verify", "--quiet", spec + "^{commit}")
        if r.returncode != 0:
            raise Refused("not a revision in %s: %s" % (repo, spec))
        commit = r.stdout.decode().strip()
        r = git(repo, "rev-parse", "--verify", "--quiet", "%s:%s" % (commit, helper))
        if r.returncode != 0:
            raise Refused("%s has no %s" % (spec, helper))
        blob = r.stdout.decode().strip()
        return commit, blob_sha256(repo, [blob])[blob]
    prefix = m.group(1)
    r = git(repo, "log", "--all", "--no-renames", "--raw", "--no-abbrev", "--format=C %H",
            "-n", str(HISTORY_LIMIT), "--", helper)
    if r.returncode != 0:
        raise Refused("git log failed in %s: %s" % (repo, one_line(r.stderr.decode(errors="replace"))))
    order, commit = [], None
    for line in r.stdout.decode(errors="replace").splitlines():
        if line.startswith("C "):
            commit = line[2:]
        elif line.startswith(":") and commit:
            fields = line.split("\t", 1)[0].split()
            if len(fields) >= 4 and set(fields[3]) != {"0"}:
                order.append((commit, fields[3]))
    shas = blob_sha256(repo, sorted({b for _, b in order}))
    matches = sorted({shas[b] for _, b in order if shas[b].startswith(prefix)})
    if not matches:
        raise Refused("no %s with sha256 %s in the last %d commits that touched it in %s"
                      % (helper, prefix, HISTORY_LIMIT, repo))
    if len(matches) > 1:
        raise Refused("sha256 prefix %s is ambiguous for %s" % (prefix, helper))
    for c, b in order:
        if shas[b] == matches[0]:
            return c, matches[0]
    raise Refused("internal: lost the commit of sha256 %s" % prefix)


def extract(repo, commit, helper, dest, want_sha):
    """Extract the helper's directory at commit into dest, verify the helper's sha256, make it read-only."""
    os.makedirs(dest)
    top = os.path.dirname(helper) or "."
    with tempfile.TemporaryFile() as tf:
        r = subprocess.run(["git", "-C", repo, "archive", "--format=tar", commit, "--", top],
                           stdout=tf, stderr=subprocess.PIPE, check=False)
        if r.returncode != 0:
            raise Refused("git archive %s %s failed: %s" % (commit[:12], top, one_line(r.stderr.decode(errors="replace"))))
        tf.seek(0)
        with tarfile.open(fileobj=tf) as tar:
            for member in tar.getmembers():
                name = os.path.normpath(member.name)
                if name.startswith("..") or os.path.isabs(name) or not (member.isfile() or member.isdir() or member.issym()):
                    raise Refused("unsafe archive entry at %s: %s" % (commit[:12], member.name))
            # The data filter (Python 3.12+) also refuses links that leave dest.
            tar.extractall(dest, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    path = os.path.join(dest, helper)
    with open(path, "rb") as fh:
        got = hashlib.sha256(fh.read()).hexdigest()
    if got != want_sha:
        raise Refused("extracted %s at %s has sha256 %s, expected %s" % (helper, commit[:12], got[:12], want_sha[:12]))
    if not os.access(path, os.X_OK):
        raise Refused("%s at %s is not executable" % (helper, commit[:12]))
    for root, dirs, files in os.walk(dest, topdown=False):
        for n in files + dirs:
            p = os.path.join(root, n)
            if not os.path.islink(p):
                os.chmod(p, stat.S_IMODE(os.lstat(p).st_mode) & ~0o222)
    os.chmod(dest, 0o555)


# ---------------------------------------------------------------- running

class Budget:
    def __init__(self):
        self.left = CAPTURE_BUDGET
        self.exhausted = False

    def take(self, data):
        if len(data) > self.left:
            self.exhausted = True
            data = data[: max(self.left, 0)]
        self.left -= len(data)
        return data


def drain(stream, slot):
    h, n, keep = hashlib.sha256(), 0, bytearray()
    try:
        while True:
            chunk = stream.read(65536)
            if not chunk:
                break
            h.update(chunk)
            n += len(chunk)
            if len(keep) < KEEP_BYTES:
                keep += chunk[: KEEP_BYTES - len(keep)]
        slot["value"] = (h.hexdigest(), n, bytes(keep))
    except OSError as exc:
        slot["error"] = "read failed: %s" % exc


def probe_net():
    """Pick a no-network wrapper that works here; return (prefix, description)."""
    candidates = []
    if shutil.which("unshare"):
        candidates.append((["unshare", "--net", "--map-current-user", "--"], "unshare --net"))
    if shutil.which("bwrap"):
        candidates.append((["bwrap", "--dev-bind", "/", "/", "--unshare-net", "--die-with-parent", "--"], "bwrap --unshare-net"))
    reasons = []
    for prefix, name in candidates:
        try:
            r = subprocess.run(prefix + ["/bin/sh", "-c", "exit 0"], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            reasons.append("%s: %s" % (name, one_line(exc, 80)))
            continue
        if r.returncode == 0:
            return prefix, "isolated (%s)" % name
        reasons.append("%s: %s" % (name, one_line(r.stderr.decode(errors="replace") or "exit %d" % r.returncode, 80)))
    return [], "NOT isolated (%s)" % ("; ".join(reasons) or "neither unshare nor bwrap is installed")


def priority():
    try:
        nice = "nice %d" % os.getpriority(os.PRIO_PROCESS, 0)
    except OSError:
        nice = "nice unknown"
    io = "I/O class unknown"
    if shutil.which("ionice"):
        try:
            r = subprocess.run(["ionice", "-p", str(os.getpid())], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=10, check=False)
            if r.returncode == 0:
                io = "I/O " + one_line(r.stdout.decode(errors="replace"), 40)
        except (OSError, subprocess.TimeoutExpired):
            pass
    return "%s, %s" % (nice, io)


def reraise(exc):
    raise exc


def snapshot(roots, run_dir):
    """One line per path under each root: type, mode, size and sha256 or link target."""
    lines = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for cur, dirs, files in os.walk(root, onerror=reraise):
            dirs.sort()
            for n in sorted(dirs + files):
                p = os.path.join(cur, n)
                rel = os.path.relpath(p, run_dir)
                st = os.lstat(p)
                mode = "%04o" % stat.S_IMODE(st.st_mode)
                if stat.S_ISLNK(st.st_mode):
                    lines.append("%s link -> %s" % (rel, os.readlink(p)))
                elif stat.S_ISDIR(st.st_mode):
                    lines.append("%s dir %s" % (rel, mode))
                elif stat.S_ISREG(st.st_mode):
                    h = hashlib.sha256()
                    with open(p, "rb") as fh:
                        for chunk in iter(lambda: fh.read(1 << 20), b""):
                            h.update(chunk)
                    lines.append("%s file %s %d %s" % (rel, mode, st.st_size, h.hexdigest()))
                else:
                    lines.append("%s other %s" % (rel, mode))
                if len(lines) > MAX_STATE_ENTRIES:
                    raise OSError("more than %d entries" % MAX_STATE_ENTRIES)
    return "\n".join(lines) + ("\n" if lines else "")


def subst(value, tokens):
    for k, v in tokens.items():
        value = value.replace(k, v)
    return value


def force_rmtree(path):
    def fix(func, p, _exc):
        try:
            os.chmod(os.path.dirname(p), 0o700)
            if os.path.isdir(p) and not os.path.islink(p):
                os.chmod(p, 0o700)
        except OSError:
            pass
        func(p)
    if os.path.lexists(path):
        if sys.version_info >= (3, 12):
            shutil.rmtree(path, onexc=fix)
        else:
            shutil.rmtree(path, onerror=fix)


def run_version(ctx, sec, state, tree, run_name):
    """Run every call of one section against one version in one state; return per-call results."""
    run_dir = ctx["run"]
    sandbox = os.path.join(run_dir, "sandbox")
    fixture = os.path.join(run_dir, "fixture")
    helper_dir = os.path.join(run_dir, "helper")
    results = []
    unknown_all = None
    force_rmtree(sandbox)
    force_rmtree(fixture)
    try:
        for d in ("home", "tmp"):
            os.makedirs(os.path.join(sandbox, d))
        if sec["fixture"]:
            shutil.copytree(sec["fixture"], fixture, symlinks=True)
        os.rename(tree, helper_dir)
    except OSError as exc:
        unknown_all = "setup failed: %s" % one_line(exc, 80)
    tokens = {"@SANDBOX@": sandbox, "@FIXTURE@": fixture, "@PID@": str(os.getpid())}
    base = {
        "PATH": "/usr/bin:/bin", "HOME": os.path.join(sandbox, "home"), "TMPDIR": os.path.join(sandbox, "tmp"),
        "XDG_CONFIG_HOME": os.path.join(sandbox, "home", ".config"),
        "XDG_STATE_HOME": os.path.join(sandbox, "home", ".local", "state"),
        "XDG_DATA_HOME": os.path.join(sandbox, "home", ".local", "share"),
        "XDG_CACHE_HOME": os.path.join(sandbox, "home", ".cache"),
        "LANG": "C", "LC_ALL": "C", "TZ": "UTC",
    }
    for k, v in sec["env"] + state["env"]:
        base[k] = subst(v, tokens)
    helper = os.path.join(helper_dir, sec["helper"])
    try:
        for idx, call in enumerate(sec["calls"], 1):
            res = {"unknown": {}, "values": {}}
            results.append(res)
            why = unknown_all
            if why is None and time.monotonic() >= ctx["deadline"]:
                why = "deadline of %ds reached before this call" % ctx["deadline_s"]
            if why is None:
                with open(helper, "rb") as fh:
                    if hashlib.sha256(fh.read()).hexdigest() != ctx["sha"][run_name[:3]]:
                        why = "helper bytes changed under the run"
            if why is not None:
                for a in ASPECTS:
                    res["unknown"][a] = why
                continue
            env = dict(base)
            for k, v in call["env"]:
                env[k] = subst(v, tokens)
            argv = ctx["net"] + [helper] + [subst(a, tokens) for a in call["args"]]
            limit = min(sec["timeout"], max(1, ctx["deadline"] - time.monotonic()))
            slots = {"stdout": {}, "stderr": {}}
            try:
                p = subprocess.Popen(argv, cwd=sandbox, env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            except OSError as exc:
                for a in ASPECTS:
                    res["unknown"][a] = "probe failed: %s" % one_line(exc, 80)
                continue
            threads = [threading.Thread(target=drain, args=(getattr(p, n), slots[n])) for n in ("stdout", "stderr")]
            for t in threads:
                t.start()
            timed_out = False
            try:
                rc = p.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(p.pid, 9)
                except OSError:
                    pass
                rc = p.wait()
            else:
                try:
                    os.killpg(p.pid, 9)
                except OSError:
                    pass
            for t in threads:
                t.join(30)
            if timed_out:
                for a in ASPECTS:
                    res["unknown"][a] = "timed out after %ds" % int(limit)
            else:
                res["values"]["rc"] = str(rc) if rc >= 0 else "signal %d" % -rc
                for n in ("stdout", "stderr"):
                    if "value" in slots[n]:
                        res["values"][n] = slots[n]["value"]
                    else:
                        res["unknown"][n] = slots[n].get("error", "stream not drained")
            try:
                res["values"]["state"] = snapshot([sandbox, fixture], run_dir)
            except OSError as exc:
                res["unknown"]["state"] = "state unreadable: %s" % one_line(exc, 80)
            save(ctx, state["name"], idx, run_name, res)
    finally:
        if os.path.isdir(helper_dir):
            os.rename(helper_dir, tree)
        force_rmtree(sandbox)
        force_rmtree(fixture)
    return results


def save(ctx, state, idx, run_name, res):
    d = os.path.join(ctx["out"], "captures", state)
    os.makedirs(d, exist_ok=True)
    stem = os.path.join(d, "%03d-%s" % (idx, run_name))
    v = res["values"]
    with open(stem + ".rc", "w") as fh:
        fh.write(v.get("rc", "unknown: " + res["unknown"].get("rc", "")) + "\n")
    for n, ext in (("stdout", ".out"), ("stderr", ".err")):
        if n in v:
            with open(stem + ext, "wb") as fh:
                fh.write(ctx["budget"].take(v[n][2]))
    if "state" in v:
        with open(stem + ".state", "wb") as fh:
            fh.write(ctx["budget"].take(v["state"].encode()))


# ---------------------------------------------------------------- report

def md(text):
    text = one_line(text)
    for c in ("\\", "|", "`", "*", "_", "<", ">", "[", "]"):
        text = text.replace(c, "\\" + c)
    return text or "(empty)"


def first_diff(a, b, run_dir):
    """The first differing line of each side, from a little before the first differing character."""
    if not a or not b:
        return ("(no output)" if not a else first_diff(a, b"\n", run_dir)[0],
                "(no output)" if not b else first_diff(b"\n", b, run_dir)[1])
    al = a.decode("utf-8", "replace").replace(run_dir, "@RUN@").split("\n")
    bl = b.decode("utf-8", "replace").replace(run_dir, "@RUN@").split("\n")
    for i in range(max(len(al), len(bl))):
        x = al[i] if i < len(al) else None
        y = bl[i] if i < len(bl) else None
        if x == y:
            continue
        col = 0
        while x is not None and y is not None and col < min(len(x), len(y)) and x[col] == y[col]:
            col += 1
        start = max(0, col - 40)

        def show(v):
            if v is None:
                return "line %d: (no line)" % (i + 1)
            return "line %d: %s%s" % (i + 1, "~" if start else "", v[start:])
        return show(x), show(y)
    return "(same first %d KiB)" % (KEEP_BYTES // 1024), "(same first %d KiB)" % (KEEP_BYTES // 1024)


def state_diff(a, b):
    sa, sb = set(a.splitlines()), set(b.splitlines())
    only_a, only_b = sorted(sa - sb), sorted(sb - sa)
    fa = "%d only here, e.g. %s" % (len(only_a), only_a[0]) if only_a else "(none only here)"
    fb = "%d only here, e.g. %s" % (len(only_b), only_b[0]) if only_b else "(none only here)"
    return fa, fb


def compare(ctx, sec, state, idx, runs):
    rows = []
    for a in ASPECTS:
        why = next((runs[r]["unknown"][a] for r in RUNS if a in runs[r]["unknown"]), None)
        if why:
            rows.append((a, "unknown: " + why, "", ""))
            continue
        o, o2, n = (runs[r]["values"][a] for r in RUNS)
        key = (lambda v: v[:2]) if a in ("stdout", "stderr") else (lambda v: v)
        if key(o) != key(o2):
            rows.append((a, "unknown: unstable, the old version differed between two runs", "", ""))
        elif key(o) != key(n):
            if a == "rc":
                po, pn = o, n
            elif a == "state":
                po, pn = state_diff(o, n)
            else:
                po, pn = first_diff(o[2], n[2], ctx["run"])
            rows.append((a, "differs", po, pn))
    return rows


def main():
    ap = argparse.ArgumentParser(prog="fm-helper-equiv.sh report")
    ap.add_argument("--calls", required=True)
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--helper")
    ap.add_argument("--deadline", type=int, default=DEFAULT_DEADLINE)
    args = ap.parse_args()
    work = None
    try:
        if not 1 <= args.deadline <= 86400:
            raise Refused("--deadline must be 1-86400 seconds")
        cs = parse_callset(args.calls)
        secs = cs["sections"]
        if args.helper:
            secs = [s for s in secs if s["helper"] == args.helper]
            if not secs:
                raise Refused("%s has no helper=%s section" % (args.calls, args.helper))
        elif len(secs) > 1:
            raise Refused("%s has several helpers (%s): pass --helper" % (args.calls, ", ".join(s["helper"] for s in secs)))
        sec = secs[0]
        r = git(args.repo, "rev-parse", "--show-toplevel")
        if r.returncode != 0:
            raise Refused("not a git checkout: %s" % args.repo)
        repo = r.stdout.decode().strip()
        old_c, old_sha = resolve(repo, sec["helper"], args.old)
        new_c, new_sha = resolve(repo, sec["helper"], args.new)
        out = os.path.abspath(args.out)
        if os.path.lexists(out) and (not os.path.isdir(out) or os.path.islink(out) or os.listdir(out)):
            raise Refused("output directory exists and is not empty: %s" % out)
        os.makedirs(out, exist_ok=True)
        work = tempfile.mkdtemp(prefix="fm-helper-equiv.")
        run = os.path.join(work, "run")
        os.makedirs(run)
        trees = {"old": os.path.join(run, ".tree-old"), "new": os.path.join(run, ".tree-new")}
        extract(repo, old_c, sec["helper"], trees["old"], old_sha)
        extract(repo, new_c, sec["helper"], trees["new"], new_sha)
    except Refused as exc:
        if work:
            force_rmtree(work)
        print("equiv: refused: %s" % exc)
        return 2
    except OSError as exc:
        if work:
            force_rmtree(work)
        print("equiv: refused: %s" % one_line(exc))
        return 2

    net, net_desc = probe_net()
    ctx = {"run": run, "out": out, "net": net, "budget": Budget(), "deadline_s": args.deadline,
           "deadline": time.monotonic() + args.deadline, "sha": {"old": old_sha, "new": new_sha}}
    rows = []
    try:
        for state in sec["states"]:
            runs = {}
            for name in RUNS:
                tree = trees["new" if name == "new" else "old"]
                runs[name] = run_version(ctx, sec, state, tree, name)
            for idx, call in enumerate(sec["calls"], 1):
                one = {r: runs[r][idx - 1] for r in RUNS}
                for aspect, result, po, pn in compare(ctx, sec, state, idx, one):
                    rows.append((state["name"], idx, call["text"], aspect, result, po, pn))
    finally:
        force_rmtree(work)

    diffs = sum(1 for r in rows if r[4] == "differs")
    unknowns = len(rows) - diffs
    lines = [
        "# Helper call equivalence: %s" % cs["consumer"],
        "",
        "A difference is a finding for the reviewer, never an automatic refusal or acceptance.",
        "An unknown is a measurement that could not be made, never an equal result.",
        "",
        "- Consumer: %s" % cs["consumer"],
        "- Call set: %s (sha256 %s)" % (os.path.abspath(args.calls), cs["sha256"]),
        "- Helper: %s" % sec["helper"],
        "- Old: sha256 %s, from commit %s" % (old_sha, old_c),
        "- New: sha256 %s, from commit %s" % (new_sha, new_c),
        "- States: %s" % ", ".join(s["name"] for s in sec["states"]),
        "- Calls: %d per state, each run old, old again, then new; an old result that changes between its two runs is unknown" % len(sec["calls"]),
        "- Network: %s" % net_desc,
        "- Priority: %s" % priority(),
        "- Captures: captures/<state>/<call>-<old|old2|new>.{rc,out,err,state}%s" % (
            ", some cut short by the %d MiB capture budget" % (CAPTURE_BUDGET >> 20) if ctx["budget"].exhausted else ""),
        "- Result: %d differences, %d unknown" % (diffs, unknowns),
        "",
    ]
    if rows:
        lines += ["| State | # | Call | Aspect | Result | Old | New |", "|---|---|---|---|---|---|---|"]
        for st, idx, text, aspect, result, po, pn in rows:
            lines.append("| %s | %d | %s | %s | %s | %s | %s |" % (
                md(st), idx, md(text), aspect, md(result), md(po) if po else "", md(pn) if pn else ""))
    else:
        lines.append("No differences and no unknowns: every call gave the same rc, stdout, stderr and state.")
    report = os.path.join(out, "report.md")
    with open(report, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("equiv: report %s: %s %s..%s for %s: %d differences, %d unknown, network %s" % (
        report, sec["helper"], old_sha[:12], new_sha[:12], cs["consumer"], diffs, unknowns, net_desc.split(" ")[0].lower()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
