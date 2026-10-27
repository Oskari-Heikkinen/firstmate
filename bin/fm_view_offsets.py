"""Read-only drain offsets from the existing presentation owner's records.

One manifest read per batch, no cursor/marker writes. The invoking transaction
supplies the exact strong identities it will verify again at commit. Native
observations do not mint those identities or replace their birth-time proof.
The legacy migration-cursor format remains legacy-owned: if it exists without
a presentation manifest, refuse the native batch until that owner migrates it.
"""
import re

from fm_view_engine import MAX_FILE, require

MAX_MARKER_TEXT = 4096

LEGACY_STRONG = re.compile(r"strong:([0-9]+):([0-9]+):([^\t\n]+)\Z")
CURRENT_STRONG = re.compile(r"strong:([0-9]+):([^\t\n]+)\Z")
WEAK_IDENTITY = re.compile(r"weak:([0-9]+):([0-9]+)\Z")


def canonical_identity(value):
    # Compatibility projection of the shell owner's _fm_file_ident_canon_to.
    # Only the old strong form loses its device. Weak forms never do.
    match = LEGACY_STRONG.fullmatch(value) if type(value) is str else None
    return "strong:" + match.group(2) + ":" + match.group(3) if match else value


def same_identity(stored, current):
    return bool(stored and current and canonical_identity(stored) == canonical_identity(current))


def observation_identity(strong, state_device=None):
    require(type(strong) is str, "unsupported captured file identity")
    match = LEGACY_STRONG.fullmatch(strong) or WEAK_IDENTITY.fullmatch(strong)
    if match:
        return [int(match.group(1)), int(match.group(2))]
    match = CURRENT_STRONG.fullmatch(strong)
    require(match is not None and type(state_device) is int and state_device >= 0,
            "unsupported captured file identity")
    # A canonical strong identity no longer carries a device. Admit only the
    # state root's identity-bound filesystem: the native regular-file capture
    # must independently MATCH this pair before any facts can succeed. A file
    # mounted from a different device refuses for complete legacy fallback.
    # This prediction grants no birth-time proof or cursor authority.
    return [state_device, int(match.group(1))]


def text(captured):
    # Match Bash command substitution's NUL/trailing-newline handling.
    return captured["bytes"].replace(b"\0", b"").decode("utf-8", "surrogateescape").rstrip("\n")


def number(value):
    require(re.fullmatch(r"[0-9]{1,16}", value), "invalid presentation cursor offset")
    return int(value)


def manifest_rows(captured, backstops=False):
    result = {}
    if captured is None:
        return result
    for line in text(captured).split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        require(len(parts) in (3, 4) and parts[0] and parts[1], "invalid presentation cursor row")
        task, identity, offset = parts[:3]
        require(task not in result, "duplicate presentation cursor task")
        backstop = number(parts[3]) if len(parts) == 4 and parts[3] else 0
        result[task] = ((identity, number(offset), backstop) if backstops
                        else (identity, number(offset)))
    return result


def signature_valid(value):
    if value == "unverifiable" or re.fullmatch(r"r1:[0-9a-f]+", value):
        return True
    size, separator, identity = value.partition("@")
    return bool(separator and re.fullmatch(r"[0-9]+", size) and identity
                and "\t" not in identity and "\n" not in identity)


def marker_offset(captured, strong):
    if captured is None:
        return 0
    raw = text(captured)
    if raw.startswith("v2\t"):
        parts = raw.split("\t")
        if len(parts) != 3 or not signature_valid(parts[1]):
            return 0
        classified = parts[2]
        if classified == "-":
            return 0
    else:
        classified = raw
    if (not signature_valid(classified) or classified == "unverifiable"
            or classified.startswith("r1:")):
        return 0
    offset, _, identity = classified.partition("@")
    # Arbitrary/corrupt integer widths fall back to legacy rather than allowing
    # unbounded integer parsing in the resident reader.
    return number(offset) if same_identity(identity, strong) else 0


def snapshot_row(snapshot, inputs):
    require(type(snapshot) is dict and set(snapshot) == {
        "task", "end", "identity", "strong_identity", "fully_presented"}, "invalid drain snapshot row")
    inputs.task_path(snapshot["task"], ".status")
    require(type(snapshot["identity"]) is list and len(snapshot["identity"]) == 2
            and all(type(value) is int and value >= 0 for value in snapshot["identity"])
            and snapshot["identity"] == observation_identity(snapshot["strong_identity"], inputs.state_identity[0]),
            "drain snapshot identity mismatch")
    require(type(snapshot["end"]) is int and 0 <= snapshot["end"] <= MAX_FILE,
            "invalid drain snapshot endpoint")
    require(type(snapshot["fully_presented"]) is bool, "invalid annotation presentation flag")


class Offsets:
    def __init__(self, inputs):
        self.inputs = inputs

    def capture(self, snapshots):
        captured = self.inputs.state_named_read(".status-presentation-cursor")
        manifest = manifest_rows(captured)
        rows, self.markers = [], []
        for snapshot in snapshots:
            snapshot_row(snapshot, self.inputs)
            task, strong = snapshot["task"], snapshot["strong_identity"]
            if captured is None:
                require(self.inputs.state_named_read("." + task + ".open-decisions-cursor") is None,
                        "legacy migration cursor requires legacy presentation")
            identity, offset = manifest.get(task, (strong, 0))
            if not same_identity(identity, strong) or offset > snapshot["end"]:
                offset = 0
            # The signal marker's historical path maps every dot in the full
            # status filename, not just in the task id.
            marker = self.inputs.state_named_read(".seen-" + (task + ".status").replace(".", "_"))
            marker_text = text(marker) if marker is not None else None
            require(marker_text is None or len(marker_text.encode("utf-8", "surrogateescape")) <= MAX_MARKER_TEXT,
                    "classification marker evidence bound exceeded")
            self.markers.append({"task": task, "text": marker_text})
            row = {name: snapshot[name] for name in ("task", "end", "identity", "fully_presented")}
            row.update(offset=offset, classified=marker_offset(marker, strong))
            # The folding interface bounds classified endpoints to its file
            # bound; refusal retains the legacy route for larger old markers.
            rows.append(row)
        return rows, captured

    def verify(self, captured):
        require(self.inputs.state_named_read(".status-presentation-cursor") == captured,
                "presentation cursor changed during observation")
