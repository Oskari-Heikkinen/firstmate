"""Captured status presentation, with no cursor or acknowledgement authority.

The existing presentation transaction captures strong file identities, cursor
and classified offsets and the annotation's fully-presented set. This module
returns facts/suggested contiguous endpoints only. Its device/inode checks are
NOT a replacement for that owner's strong birth-time identity check at commit.
All rows in a batch succeed together or refuse; no partial successful reply.
"""
from fm_view_status import SPACE, Vocabulary, key, note, verb

MAX_ROWS = 256


def unread_surface(line, kind, vocabulary):
    value = verb(line)
    if value == "note" or (value == "working" and kind == "secondmate"):
        return True
    if value not in (vocabulary.resolved, vocabulary.held):
        return False
    decision_key = key(line)
    return (decision_key is not None
            and any(decision_key.startswith(prefix) for prefix in vocabulary.reserved)
            and vocabulary.transition_allowed(decision_key, note(line)))


def has_correlation(line):
    # Legacy _fm_status_line_has_corr searches the whole line, not just its
    # leading verb. This also deliberately accepts a lowercase hex substring
    # of a longer token: it is presentation absorption, not request authority.
    import re
    return re.search(r"corr=[0-9a-fA-F]{16}", line) is not None


class Presentation:
    def __init__(self, inputs):
        self.inputs = inputs

    def read_from_snapshot(self, snapshots):
        from fm_view_engine import require
        from fm_view_offsets import Offsets
        require(type(snapshots) is list and len(snapshots) <= MAX_ROWS, "presentation row bound exceeded")
        offsets = Offsets(self.inputs)
        rows, captured = offsets.capture(snapshots)
        result = self.read(rows)
        offsets.verify(captured)
        # Evidence, not authority: the shell owner rechecks these exact marker
        # texts at its original post-annotation acknowledgement boundary.
        result["classification_markers"] = offsets.markers
        return result

    def read(self, rows, vocabulary=None):
        # Imports are local to avoid a cycle through the engine's input owner.
        from fm_view_engine import MAX_FILE, fields, require
        vocabulary = vocabulary or Vocabulary()
        require(type(rows) is list and len(rows) <= MAX_ROWS, "presentation row bound exceeded")
        captured, seen = [], set()
        total = 0
        self.inputs.check()
        for row in rows:
            require(type(row) is dict and set(row) == {
                "task", "end", "offset", "identity", "classified", "fully_presented"},
                "invalid presentation row")
            task = row["task"]
            self.inputs.task_path(task, ".status")
            require(task not in seen, "duplicate presentation task")
            seen.add(task)
            for field in ("end", "offset", "classified"):
                require(type(row[field]) is int and 0 <= row[field] <= MAX_FILE,
                        "invalid presentation offset")
            require(row["offset"] <= row["end"], "presentation cursor past captured endpoint")
            require(type(row["fully_presented"]) is bool, "invalid annotation presentation flag")
            require(type(row["identity"]) is list and len(row["identity"]) == 2
                    and all(type(i) is int and i >= 0 for i in row["identity"]),
                    "invalid presentation capture identity")
            meta = self.inputs.metadata(task)
            selected = fields(meta["bytes"]) if meta else {}
            kind = (selected.get("kind") or "ship") if meta else "unknown"
            if kind not in ("ship", "scout", "secondmate"):
                kind = "unknown"
            status = self.inputs.state_read(task, ".status")
            require(status is not None and status["identity"] == row["identity"],
                    "presentation status identity changed")
            require(row["end"] <= status["size"], "presentation status truncated")
            # This is a CAPTURED span API, not a current-state answer. Concurrent
            # appends remain for the next owner snapshot; never fold past end.
            data = status["bytes"][:row["end"]]
            total += status["size"]
            require(total <= 16 * MAX_FILE, "presentation batch byte bound exceeded")
            protected, protect_all = self.inputs.protection(task)
            folded = self.inputs.status_index.fold(task, status["identity"], data, kind,
                                                    vocabulary, protected, protect_all)
            # Bash command substitution drops NULs and trailing newlines; its
            # read loop keeps all other bytes, including an unfinished line.
            lines = data[row["offset"]:].replace(b"\0", b"").decode("utf-8", "surrogateescape").split("\n")
            lines = [line for line in lines if line.strip(SPACE)]
            unread = [line for line in lines if unread_surface(line, kind, vocabulary)]
            safe = row["fully_presented"]
            absorbable = False
            for line in unread:
                if kind == "secondmate" and (verb(line) == "working" or
                                               (verb(line) == "note" and has_correlation(line))):
                    absorbable = True
                else:
                    safe = True
            acknowledged = row["end"] if safe else row["offset"]
            if not safe and absorbable:
                acknowledged = max(row["offset"], min(row["end"], row["classified"]))
            result = {"task": task, "identity": row["identity"], "end": row["end"],
                      "generation": selected.get("spawn_gen", ""), "new_lines": lines,
                      "unread": unread, "open": folded["open"], "observed_offset": row["offset"],
                      "acknowledged_end": acknowledged}
            captured.append((task, meta, status, result))
        # All metadata generations and status identities must still match at
        # the batch barrier. Appends are allowed but replacing/truncating a
        # captured prefix refuses every row, rather than mixing generations.
        for task, meta, status, result in captured:
            require(self.inputs.metadata(task) == meta, "presentation task generation changed")
            now = self.inputs.state_read(task, ".status")
            require(now is not None and now["identity"] == status["identity"]
                    and now["bytes"][:result["end"]] == status["bytes"][:result["end"]],
                    "presentation captured prefix changed")
        self.inputs.check()
        return {"rows": [result for _, _, _, result in captured]}
