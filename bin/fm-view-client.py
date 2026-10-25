#!/usr/bin/env python3
"""Bounded read compatibility client (Python 3.9+, no installation or actions).

Usage: fm-view-client.py crew-state TASK
       fm-view-client.py status-presentation < captured-rows.tsv
       fm-view-client.py drain-presentation < captured-snapshot.tsv

Explicit FM_VIEW_SOCKET, FM_VIEW_EPOCH and canonical FM_HOME select an already
owner-managed read service. There is no discovery, startup, mode switch or PID
signal here. Refusal exits 1 on stderr; the invoking shell retains its legacy
fallback. Unsupported state/data/captured-input overrides refuse, never read a
different root. stdin presentation rows are task/end/strong-identity/offset/
classified/fully-presented (0 or 1), tab-separated. drain-presentation instead
accepts task/end/strong-identity/fully-presented, and reads offsets in one native
batch through the existing cursor/marker formats. Output tagged TSV contains
A acknowledgement suggestions, U unread facts, O open-decision facts and N
captured annotation lines only;
it is private call output, not a durable acknowledgement or receipt. Strong
identities pass through unchanged to the existing commit transaction owner.
"""
import os
from pathlib import Path
import re
import sys

from fm_view_engine import MAX_MESSAGE, client, require
from fm_view_offsets import observation_identity


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


def presentation_rows(raw, from_state=False):
    rows, originals = [], []
    for line in raw.decode("utf-8", "surrogateescape").split("\n"):
        if not line:
            continue
        parts = line.split("\t")
        require(len(parts) == (4 if from_state else 6), "invalid captured presentation row")
        task, end, strong = parts[:3]
        fully = parts[-1]
        values = [end] if from_state else [end, parts[3], parts[4]]
        require(all(re.fullmatch(r"[0-9]{1,16}", value) for value in values)
                and fully in ("0", "1"), "invalid captured offsets")
        row = {"task": task, "end": int(end), "identity": observation_identity(strong),
               "fully_presented": fully == "1"}
        if from_state:
            row["strong_identity"] = strong
        else:
            row.update(offset=int(parts[3]), classified=int(parts[4]))
        rows.append(row)
        originals.append(strong)
    return rows, originals


def presentation_output(result, rows, originals):
    require(type(result) is dict and type(result.get("rows")) is list
            and len(result["rows"]) == len(rows), "presentation reply row mismatch")
    output = []
    for returned, expected, strong in zip(result["rows"], rows, originals):
        require(type(returned) is dict and all(returned.get(name) == expected[name]
                    for name in ("task", "end", "identity")), "presentation reply capture mismatch")
        observed = returned.get("observed_offset")
        require(type(observed) is int and 0 <= observed <= expected["end"],
                "presentation reply observed offset invalid")
        if "offset" in expected:
            require(observed == expected["offset"], "presentation reply observed offset mismatch")
        endpoint = returned.get("acknowledged_end")
        require(type(endpoint) is int and observed <= endpoint <= expected["end"],
                "presentation reply endpoint invalid")
        task = expected["task"]
        output.append(f"A\t{task}\t{endpoint}\t{strong}\n")
        require(type(returned.get("unread")) is list and type(returned.get("open")) is list
                and type(returned.get("new_lines")) is list, "presentation reply facts invalid")
        for line in returned["new_lines"]:
            require(type(line) is str and "\n" not in line, "invalid annotation reply line")
        for line in returned["unread"]:
            require(type(line) is str and "\n" not in line, "invalid unread reply line")
            output.append(f"U\t{task}\t{line}\n")
        for opened in returned["open"]:
            require(type(opened) is dict and all(type(opened.get(field)) is str and "\n" not in opened[field]
                        for field in ("key", "verb", "summary")), "invalid open reply line")
            output.append("O\t" + task + "\t" + "\t".join(opened[field] for field in ("key", "verb", "summary")) + "\n")
    # Group annotation lines in byte-sorted task order for the shell renderer's
    # per-call binary index. Rendering keeps queue/manifest order, not this order.
    for returned in sorted(result["rows"], key=lambda row: row["task"]):
        for line in returned["new_lines"]:
            output.append(f'N\t{returned["task"]}\t{line}\n')
    return "".join(output)


def main(arguments, environment):
    path, home, epoch = binding(environment)
    require(arguments and arguments[0] in ("crew-state", "status-presentation", "drain-presentation"), "unsupported client operation")
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
    rows, originals = presentation_rows(raw, from_state=verb == "drain-presentation")
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
