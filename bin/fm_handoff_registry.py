"""Home discovery and fragment loading shared by fm-handoff-watch and fm-loop.

docs/handoff-coverage.md owns the handoff-registry/v1 format and says which
homes a watcher reads; bin/fm-handoff-validate.py owns the checks a fragment
must pass. This module only finds homes and fragments and applies those checks.
"""
import importlib.util
import os
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
HOME_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
# data/secondmates.md routing lines; a line with host: is a remote home.
SECONDMATE_HOME_RE = re.compile(r"^- ([a-z0-9][a-z0-9-]{0,63}) - .*\(home: (/[^;)]+)[;)]")


def validator():
    """The fm-handoff-validate.py module (its file name has a hyphen)."""
    spec = importlib.util.spec_from_file_location("fm_handoff_validate", HERE / "fm-handoff-validate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def home_id(home):
    """A home's identity: its .fm-secondmate-home marker, else main."""
    try:
        text = (Path(home) / ".fm-secondmate-home").read_text(encoding="utf-8").strip()
    except OSError:
        return "main"
    return text if HOME_ID_RE.match(text) else None


def local_parent(home):
    """The parent home path from a local .fm-secondmate-parent record, else None."""
    record = Path(home) / ".fm-secondmate-parent"
    if record.is_symlink():
        return None
    try:
        lines = record.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return None
    fields = {}
    for line in lines:
        key, sep, value = line.partition("=")
        if sep:
            fields.setdefault(key, []).append(value)
    if fields.get("route") != ["local"] or len(fields.get("parent_home", [])) != 1:
        return None
    parent = fields["parent_home"][0]
    return Path(parent) if parent.startswith("/") else None


def listed_homes(home):
    """(id, path) pairs from <home>/data/secondmates.md (local homes only) and <home>/config/handoff-homes."""
    out = []
    try:
        lines = (Path(home) / "data/secondmates.md").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        lines = []
    for line in lines:
        match = SECONDMATE_HOME_RE.match(line)
        if match and "(host:" not in line:
            out.append((match.group(1), Path(match.group(2))))
    try:
        lines = (Path(home) / "config/handoff-homes").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) == 2 and not line.lstrip().startswith("#") and HOME_ID_RE.match(parts[0]) \
                and parts[1].startswith("/"):
            out.append((parts[0], Path(parts[1])))
    return out


def discover(home, root=None):
    """Return (self_id, {id: path}) for the homes this machine's watcher reads.

    With root, every directory under root named like a home id is that home,
    and home must be one of them. Otherwise the homes are this one, its local
    parent, and the homes either of them lists (docs/handoff-coverage.md
    "Fragment discovery").
    """
    home = Path(home).resolve()
    if root is not None:
        root = Path(root).resolve()
        homes = {}
        for entry in sorted(os.listdir(root)):
            if HOME_ID_RE.match(entry) and (root / entry).is_dir():
                homes[entry] = root / entry
        if home.parent != root or home.name not in homes:
            raise ValueError(f"{home} is not a home directory directly under {root}")
        return home.name, homes
    self_id = home_id(home)
    if self_id is None:
        raise ValueError(f"{home}/.fm-secondmate-home does not hold a home id")
    homes = {self_id: home}
    sources = [home]
    parent = local_parent(home)
    if parent is not None and parent.is_dir():
        pid = home_id(parent)
        if pid:
            homes.setdefault(pid, parent.resolve())
            sources.append(parent)
    for source in sources:
        for hid, path in listed_homes(source):
            homes.setdefault(hid, path)
    return self_id, homes


def first_declared(kept):
    """Pick each protocol's declaration from the watcher's fragment cache entries.

    kept maps a fragment path to {"home", "doc"}; the first declaration by home
    and path wins. Returns (protocols by id, (home, path) by id, duplicates as
    (protocol id, first (home, path), later (home, path))).
    """
    protocols, declared, duplicates = {}, {}, []
    for key in sorted(kept, key=lambda k: (kept[k]["home"], k)):
        for proto in (kept[key].get("doc") or {}).get("protocols", []):
            pid = proto["id"]
            if pid in protocols:
                duplicates.append((pid, declared[pid], (kept[key]["home"], key)))
                continue
            protocols[pid] = proto
            declared[pid] = (kept[key]["home"], key)
    return protocols, declared, duplicates


def fragment_files(home):
    """Fragment paths in <home>/state/handoff-registry/, sorted; dot names skipped. Raises OSError."""
    folder = Path(home) / "state/handoff-registry"
    if not folder.is_dir():
        return []
    return [folder / name for name in sorted(os.listdir(folder))
            if not name.startswith(".") and name.endswith(".json")]


def check_fragment(module, schema, path):
    """Return (doc, problem): a valid fragment and None, or None and one sentence.

    A fragment marked "example": true is never loaded and returns (None, None).
    """
    try:
        doc, bad = module.load_json(str(path))
    except module.Unreadable as exc:
        return None, f"cannot be read ({exc})"
    if bad:
        return None, bad
    if isinstance(doc, dict) and doc.get("example") is True:
        return None, None
    if isinstance(doc, dict) and doc.get("format") != module.REGISTRY_FORMAT:
        return None, f"has unknown format {doc.get('format')!r}"
    problems = schema.errors(doc) or module.fragment_problems(doc)
    if problems:
        where, what = problems[0]
        more = f" (and {len(problems) - 1} more)" if len(problems) > 1 else ""
        return None, f"is invalid at {where}: {what}{more}"
    return doc, None
