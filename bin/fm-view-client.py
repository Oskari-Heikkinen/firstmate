#!/usr/bin/env python3
"""Bounded read compatibility client (Python 3.9+, no installation or actions).

Usage: fm-view-client.py crew-state TASK
       fm-view-client.py status-presentation < captured-rows.tsv

Explicit FM_VIEW_SOCKET, FM_VIEW_EPOCH and canonical FM_HOME select an already
owner-managed read service. There is no discovery, startup, mode switch or PID
signal here. Refusal exits 1 on stderr; the invoking shell retains its legacy
fallback. Unsupported state/data/captured-input overrides refuse, never read a
different root. stdin presentation rows are task/end/strong-identity/offset/
classified/fully-presented (0 or 1), tab-separated. Output tagged TSV contains
A acknowledgement suggestions, U unread facts and O open-decision facts only;
it is private call output, not a durable acknowledgement or receipt. Strong
identities pass through unchanged to the existing commit transaction owner.
"""
import os
from pathlib import Path
import re
import sys

from fm_view_engine import MAX_MESSAGE, client, require


def binding(environment):
    home = environment.get("FM_HOME", "")
    require(home and str(Path(home)) == os.path.realpath(home), "canonical FM_HOME required")
    for variable, expected in (("FM_STATE_OVERRIDE", home + "/state"),
                               ("FM_DATA_OVERRIDE", home + "/data")):
        require(not environment.get(variable) or environment[variable] == expected,
                "nonstandard input root requires legacy")
    require(not environment.get("FM_CREW_STATE_META_OVERRIDE")
            and not environment.get("FM_CREW_STATE_STATUS_OVERRIDE"),
            "captured crew inputs require legacy")
    # The native modules have the default classifier contract. Do not silently
    # substitute it for a caller's custom vocabulary/identity observation seam.
    require(not any(value for name, value in environment.items()
                    if name.startswith("FM_CLASSIFY_") or name in (
                        "FM_STATUS_IDENTITY_READER", "FM_STATUS_SIZE_READER", "FM_STATUS_SPAN_READER")),
            "custom classifier/input reader requires legacy")
    path, epoch = environment.get("FM_VIEW_SOCKET", ""), environment.get("FM_VIEW_EPOCH", "")
    require(path and epoch, "explicit socket and epoch required")
    return path, home, epoch


def presentation_rows(raw):
    rows, originals = [], []
    for line in raw.decode("utf-8", "surrogateescape").split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        require(len(parts) == 6, "invalid captured presentation row")
        task, end, strong, offset, classified, fully = parts
        match = re.fullmatch(r"(?:strong|weak):([0-9]+):([0-9]+)(?::([^\t\n]+))?", strong)
        require(match is not None and (strong.startswith("strong:") == (match.group(3) is not None)),
                "unsupported captured file identity")
        require(all(re.fullmatch(r"[0-9]+", value) for value in (end, offset, classified))
                and fully in ("0", "1"), "invalid captured offsets")
        rows.append({"task": task, "end": int(end), "identity": [int(match.group(1)), int(match.group(2))],
                     "offset": int(offset), "classified": int(classified), "fully_presented": fully == "1"})
        originals.append(strong)
    return rows, originals


def presentation_output(result, rows, originals):
    require(type(result) is dict and type(result.get("rows")) is list
            and len(result["rows"]) == len(rows), "presentation reply row mismatch")
    output = []
    for returned, expected, strong in zip(result["rows"], rows, originals):
        require(type(returned) is dict and all(returned.get(name) == expected[name]
                    for name in ("task", "end", "identity")), "presentation reply capture mismatch")
        endpoint = returned.get("acknowledged_end")
        require(type(endpoint) is int and expected["offset"] <= endpoint <= expected["end"],
                "presentation reply endpoint invalid")
        task = expected["task"]
        output.append(f"A\t{task}\t{endpoint}\t{strong}\n")
        require(type(returned.get("unread")) is list and type(returned.get("open")) is list,
                "presentation reply facts invalid")
        for line in returned["unread"]:
            require(type(line) is str and "\n" not in line, "invalid unread reply line")
            output.append(f"U\t{task}\t{line}\n")
        for opened in returned["open"]:
            require(type(opened) is dict and all(type(opened.get(field)) is str and "\n" not in opened[field]
                        for field in ("key", "verb", "summary")), "invalid open reply line")
            output.append("O\t" + task + "\t" + "\t".join(opened[field] for field in ("key", "verb", "summary")) + "\n")
    return "".join(output)


def main(arguments, environment):
    path, home, epoch = binding(environment)
    require(arguments and arguments[0] in ("crew-state", "status-presentation"), "unsupported client operation")
    verb = arguments[0]
    if verb == "crew-state":
        require(len(arguments) == 2, "crew-state requires one task")
        options = {name: environment[name] for name in (
            "FM_CREW_STATE_NM_TIMEOUT", "FM_CREW_STATE_RUNS_LIMIT", "FM_CREW_STATE_NO_FORGE") if name in environment}
        result = client(path, home, epoch, verb, {"task": arguments[1], "options": options}, timeout=30)
        require(type(result) is dict and type(result.get("raw")) is str
                and result["raw"].startswith("state: ") and "\n" not in result["raw"], "invalid crew reply")
        return result["raw"] + "\n"
    require(len(arguments) == 1, "unexpected presentation argument")
    raw = sys.stdin.buffer.read(MAX_MESSAGE + 1)
    require(len(raw) <= MAX_MESSAGE, "presentation input exceeds bound")
    rows, originals = presentation_rows(raw)
    result = client(path, home, epoch, verb, {"rows": rows}, timeout=30)
    return presentation_output(result, rows, originals)


if __name__ == "__main__":
    try:
        output = main(sys.argv[1:], os.environ)
        sys.stdout.buffer.write(output.encode("utf-8", "surrogateescape"))
        sys.stdout.buffer.flush()
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print("fm-view-client: read refused; use legacy: " + str(exc)[:500], file=sys.stderr)
        sys.exit(1)
