"""Read-only status classifier for the view engine (Python 3.9+).

No cursors, acknowledgements or authoritative records are written here.
The legacy shell fold remains the comparison oracle until migration parity is
proved. See docs/supervision-views.md for the opt-in service boundary.
"""
from collections import OrderedDict
from dataclasses import dataclass
import re

SPACE = " \t\r\v\f"
SLUG = re.compile(r"[A-Za-z0-9._-]+\Z")
CORR = re.compile(r"corr=[0-9A-Fa-f]{16}\Z")
DEFAULT_RE = r"done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged"
RESERVED = ("pending-reply-", "handoff-pickup-", "handoff-tj-")


def unstamped(line):
    """Remove complete at/wait tags only before the real head separator."""
    kept = ""
    while True:
        matches = [m for m in (re.search(r"\[at=[^\]]*\]", line),
                                re.search(r"\[wait=[^\]]*\]", line)) if m]
        if not matches:
            return kept + line
        match = min(matches, key=lambda m: m.start())
        before = line[:match.start()]
        if ":" in before:
            return kept + line
        kept += before[:-1] if before.endswith(" ") else before
        line = line[match.end():]


def head(line):
    kept = ""
    while True:
        match = re.search(r"\[wait=[^\]]*\]", line)
        if not match or ":" in line[:match.start()]:
            return kept + line.split(":", 1)[0]
        kept += line[:match.end()]
        line = line[match.end():]


def verb(line):
    prefix = line.split(":", 1)[0].split("[", 1)[0].strip(SPACE)
    if "corr=" not in prefix:
        return prefix
    words = re.split(r"[ \t\r\v\f]+", prefix)
    return " ".join(words[:1] + [word for word in words[1:] if not CORR.fullmatch(word)])


def key(line, keyless="default"):
    clean = unstamped(line)
    before, colon, after = clean.partition(":")
    match = re.search(r"\[key=([^\]]*)\]", before)
    if not match and colon:
        match = re.match(r"[ \t\r\v\f]*\[key=([^\]]*)\]", after)
    if not match:
        return keyless
    value = match.group(1)
    return value if SLUG.fullmatch(value) else None


def note(line):
    clean = unstamped(line)
    before, colon, after = clean.partition(":")
    if not colon:
        return clean
    after = after.lstrip(SPACE)
    match = re.match(r"\[key=([^\]]*)\]", after)
    if not re.search(r"\[key=[^\]]*\]", before) and match and SLUG.fullmatch(match.group(1)):
        after = after[match.end():].lstrip(SPACE)
    return after


def at_epoch(line):
    if ":" not in line:
        return None
    tags = re.findall(r"\[at=([^\]]*)\]", head(line))
    if len(tags) != 1 or not re.fullmatch(r"(?:0|[1-9][0-9]{0,11})", tags[0]):
        return None
    return int(tags[0])


@dataclass(frozen=True)
class Vocabulary:
    paused: str = "paused"
    resolved: str = "resolved"
    held: str = "captain-held"
    relevant: str = DEFAULT_RE
    reserved: tuple = RESERVED

    @property
    def recognized(self):
        return ("working", "needs-decision", "blocked", "done", "failed", "note",
                self.paused, self.resolved, self.held)

    def unrecognized_prefix(self, line):
        clean = unstamped(line)
        before, colon, after = clean.partition(":")
        if not colon or (after and after[0] not in SPACE):
            return False
        value = verb(clean)
        if not value or value in self.recognized:
            return False
        words = re.split(r"[ \t\r\v\f]+", value)
        if len(words) == 1:
            return re.fullmatch(r"[a-z][a-z-]*", words[0]) is not None
        corr_attempt = lambda s: s == "corr" or s.startswith("corr=")
        if corr_attempt(words[0]):
            if words[1] not in self.recognized:
                return False
            words = words[2:]
        else:
            if words[0] not in self.recognized:
                return False
            words = words[1:]
        return all(corr_attempt(word) for word in words)

    def is_event(self, line):
        return ((":" in line and verb(line) in self.recognized)
                or self.unrecognized_prefix(line)
                or re.search(r"^[ \t\r\v\f]*(?:" + self.relevant + ")",
                             unstamped(line), re.IGNORECASE) is not None)

    def is_relevant(self, line):
        value = verb(line)
        if value in ("working", "resolved", "captain-held", self.paused):
            return False
        if self.unrecognized_prefix(line):
            return True
        if self.relevant == DEFAULT_RE and value in ("done", "needs-decision", "blocked", "failed"):
            return True
        return re.search(self.relevant, unstamped(line), re.IGNORECASE) is not None

    def transition_allowed(self, decision_key, summary):
        for prefix in self.reserved:
            if decision_key.startswith(prefix):
                return summary.startswith(prefix) and ":" in summary
        return True


class Fold:
    """One coherent captured status span; partial final lines match whole-file reads.

    The caller supplies tool-owned protected keys (or protect_all on unknown
    registration/store state). This fact is deliberately NOT memoized against
    status bytes: a store can change without a status append.
    """
    def __init__(self, data, kind="unknown", vocabulary=None, protected=(), protect_all=False):
        self.vocabulary = vocabulary or Vocabulary()
        self.kind = kind
        self.protected = frozenset(protected)
        self.protect_all = protect_all
        self.open = OrderedDict()
        self.events = []
        self.lines = data.replace(b"\0", b"").decode("utf-8", "surrogateescape").split("\n")
        self.latest = ""
        fallback = ""
        for line in self.lines:
            if len(line) > 65536:
                raise ValueError("native status line bound exceeded; use legacy")
            if line.strip(SPACE):
                fallback = line
                if self.vocabulary.is_event(line):
                    self.events.append(line)
            self.apply(line)
        self.latest = self.events[-1] if self.events else fallback

    def protected_key(self, value):
        return (self.protect_all or value in self.protected
                or any(value.startswith(prefix) for prefix in self.vocabulary.reserved))

    def apply(self, line):
        value = verb(line)
        clean = unstamped(line)
        if ":" not in clean and not re.search(r"\[key=[^\]]*\]", clean):
            return
        if ":" in clean and value in ("done", "failed") and self.kind in ("ship", "scout"):
            self.open.clear()
            return
        if value == "note":
            tag = re.search(r"\[supersedes=([^\]]*)\]", head(line))
            if ":" in clean and tag and tag.group(1) in ("relaunch", "resume", "validation-run"):
                self.open = OrderedDict((k, row) for k, row in self.open.items()
                                        if row["verb"] != "blocked" or self.protected_key(k))
            return
        if value not in ("needs-decision", "blocked", self.vocabulary.resolved, self.vocabulary.held):
            return
        decision_key = key(line)
        if decision_key is None or not self.vocabulary.transition_allowed(decision_key, note(line)):
            return
        self.open.pop(decision_key, None)
        if value in ("needs-decision", "blocked"):
            self.open[decision_key] = {"key": decision_key, "verb": value,
                                      "summary": note(line), "opened_at_epoch": at_epoch(line)}

    def declared_wait(self):
        if verb(self.latest) in (self.vocabulary.paused, self.vocabulary.held):
            return self.latest
        if verb(self.latest) != self.vocabulary.resolved:
            return ""
        closed = set()
        for line in reversed(self.events):
            value = verb(line)
            if value not in (self.vocabulary.resolved, self.vocabulary.paused):
                return ""
            phase = key(line, "")
            if value == self.vocabulary.resolved:
                closed.add(phase)
            else:
                return "" if phase in closed else line
        return ""

    def current_line(self):
        if self.open:
            row = next(reversed(self.open.values()))
            return f'{row["verb"]} [key={row["key"]}]: {row["summary"]}'
        return self.declared_wait() or self.latest

    def result(self):
        return {"latest": self.latest, "current": self.current_line(),
                "declared_wait": self.declared_wait(), "open": list(self.open.values())}
