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

STRONG_IDENTITY = re.compile(r"(?:strong:([0-9]+):([0-9]+):([^\t\n]+)|weak:([0-9]+):([0-9]+))\Z")


def observation_identity(strong):
    match = STRONG_IDENTITY.fullmatch(strong) if type(strong) is str else None
    require(match is not None, "unsupported captured file identity")
    return [int(match.group(1) or match.group(4)), int(match.group(2) or match.group(5))]


def text(captured):
    # Match Bash command substitution's NUL/trailing-newline handling.
    return captured["bytes"].replace(b"\0", b"").decode("utf-8", "surrogateescape").rstrip("\n")


def number(value):
    require(re.fullmatch(r"[0-9]{1,16}", value), "invalid presentation cursor offset")
    return int(value)


def manifest_rows(captured):
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
        if len(parts) == 4 and parts[3]:
            number(parts[3])
        result[task] = (identity, number(offset))
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
    return number(offset) if identity == strong else 0


class Offsets:
    def __init__(self, inputs):
        self.inputs = inputs

    def capture(self, snapshots):
        captured = self.inputs.state_named_read(".status-presentation-cursor")
        manifest = manifest_rows(captured)
        rows, self.markers = [], []
        for snapshot in snapshots:
            require(type(snapshot) is dict and set(snapshot) == {
                "task", "end", "identity", "strong_identity", "fully_presented"}, "invalid drain snapshot row")
            task, strong = snapshot["task"], snapshot["strong_identity"]
            self.inputs.task_path(task, ".status")
            require(snapshot["identity"] == observation_identity(strong), "drain snapshot identity mismatch")
            require(type(snapshot["end"]) is int and 0 <= snapshot["end"] <= MAX_FILE,
                    "invalid drain snapshot endpoint")
            if captured is None:
                require(self.inputs.state_named_read("." + task + ".open-decisions-cursor") is None,
                        "legacy migration cursor requires legacy presentation")
            identity, offset = manifest.get(task, (strong, 0))
            if identity != strong or offset > snapshot["end"]:
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
