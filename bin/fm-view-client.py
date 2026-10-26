#!/usr/bin/env python3
"""Bounded read compatibility client (Python 3.9+, no installation or actions).

Usage: fm-view-client.py crew-state TASK
       fm-view-client.py status-presentation < captured-rows.tsv
       fm-view-client.py drain-presentation < captured-snapshot.tsv
       fm-view-client.py snapshot-tasks OBSERVED_AT EPOCH CONCURRENCY TASK_TIMEOUT CAPTURE_DIR

Explicit FM_VIEW_SOCKET, FM_VIEW_EPOCH and canonical FM_HOME select an already
owner-managed read service. There is no discovery, startup, mode switch or PID
signal here. Refusal exits 1 on stderr; the invoking shell retains its legacy
fallback. Unsupported state/data/captured-input overrides refuse, never read a
different root. stdin presentation rows are task/end/strong-identity/offset/
classified/fully-presented (0 or 1), tab-separated. drain-presentation instead
accepts task/end/strong-identity/fully-presented, and reads offsets in one native
batch through the existing cursor/marker formats. Output tagged TSV contains
A acknowledgement suggestions, U unread facts, O open-decision facts, N
captured annotation lines and (for drain-presentation) M classification-marker
evidence. M rows are task plus '-' for missing or 'h:' plus lowercase hex of
normalized marker text (NULs/trailing newlines removed, at most 4096 bytes);
it is private call output, not a durable acknowledgement or receipt. Strong
identities pass through unchanged to the existing commit transaction owner.
Snapshot calls stage their validated captured metadata/status in the invoking
owner's empty private CAPTURE_DIR before emitting task JSON. The existing
cross-home collector consumes those bytes and original status mtimes; these are
disposable transport files, never authoritative state or service-owned writes.
"""
import os
from pathlib import Path
import re
import stat
import sys

from fm_view_engine import MAX_MESSAGE, TASK_ID, client, encoded, require
from fm_view_offsets import MAX_MARKER_TEXT, observation_identity


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


def presentation_output(result, rows, originals, from_state=False):
    require(type(result) is dict and type(result.get("rows")) is list
            and len(result["rows"]) == len(rows), "presentation reply row mismatch")
    output = []
    # Validate the entire evidence inventory before any private TSV is emitted.
    # It is required for drain batches, never inferred from a suggestion alone.
    if from_state:
        markers = result.get("classification_markers")
        require(type(markers) is list and len(markers) == len(rows), "classification marker evidence count mismatch")
        for marker, expected in zip(markers, rows):
            require(type(marker) is dict and set(marker) == {"task", "text"}
                    and marker["task"] == expected["task"], "classification marker evidence binding mismatch")
            raw = marker["text"]
            require(raw is None or type(raw) is str and "\0" not in raw and not raw.endswith("\n")
                    and len(raw.encode("utf-8", "surrogateescape")) <= MAX_MARKER_TEXT,
                    "invalid classification marker evidence")
            proof = "-" if raw is None else "h:" + raw.encode("utf-8", "surrogateescape").hex()
            output.append(f'M\t{expected["task"]}\t{proof}\n')
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


def stage_snapshot(result, directory):
    rows, captures = result["tasks"], result.get("captures")
    require(type(captures) is list and len(captures) == len(rows), "snapshot capture count mismatch")
    for row, capture in zip(rows, captures):
        require(type(capture) is dict and set(capture) == {"task", "meta", "status", "status_mtime_ns"}
                and capture["task"] == row["id"] and type(capture["meta"]) is str,
                "invalid snapshot capture binding")
        present = capture["status"] is not None
        require(present == row["paths"]["status_log"]["present"], "snapshot captured status presence mismatch")
        require((present and type(capture["status"]) is str and type(capture["status_mtime_ns"]) is int
                 and -(2 ** 63) <= capture["status_mtime_ns"] < 2 ** 63)
                or (not present and capture["status_mtime_ns"] is None), "invalid snapshot captured status")
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
                and not os.listdir(fd), "snapshot capture directory must be empty, private and owned")
        for capture in captures:
            for suffix in ("meta", "status"):
                text = capture[suffix]
                if text is None:
                    continue
                name = capture["task"] + "." + suffix
                output = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
                with os.fdopen(output, "wb") as stream:
                    stream.write(text.encode("utf-8", "surrogateescape"))
                if suffix == "status":
                    stamp = capture["status_mtime_ns"]
                    os.utime(name, ns=(stamp, stamp), dir_fd=fd, follow_symlinks=False)
        selected = os.stat(directory, follow_symlinks=False)
        require((selected.st_dev, selected.st_ino) == (info.st_dev, info.st_ino),
                "snapshot capture directory replaced")
    finally:
        os.close(fd)


def main(arguments, environment):
    path, home, epoch = binding(environment)
    require(arguments and arguments[0] in ("crew-state", "status-presentation", "drain-presentation", "snapshot-tasks"), "unsupported client operation")
    verb = arguments[0]
    if verb == "snapshot-tasks":
        require(len(arguments) == 6 and all(re.fullmatch(r"[0-9]{1,13}", value) for value in arguments[2:5]),
                "invalid snapshot client arguments")
        options = {name: environment[name] for name in (
            "FM_CREW_STATE_NM_TIMEOUT", "FM_CREW_STATE_RUNS_LIMIT", "FM_CREW_STATE_NO_FORGE") if name in environment}
        result = client(path, home, epoch, verb, {"observed_at": arguments[1], "epoch": int(arguments[2]),
            "concurrency": int(arguments[3]), "task_timeout": int(arguments[4]), "options": options}, timeout=30)
        require(type(result) is dict and set(result) == {"tasks", "captures"} and type(result["tasks"]) is list
                and len(result["tasks"]) <= 256, "invalid snapshot reply")
        previous = ""
        for row in result["tasks"]:
            require(type(row) is dict and type(row.get("id")) is str and TASK_ID.fullmatch(row["id"])
                    and row["id"] > previous, "invalid snapshot task ordering")
            previous = row["id"]
            require(set(row) == {"id", "kind", "harness", "mode", "yolo", "branch", "project", "spawn_gen", "backend",
                    "remote", "paths", "secondmate_projects", "current_state", "endpoint", "pr", "hints", "actions"},
                    "invalid snapshot row fields")
            require(all(type(row[name]) is str for name in ("kind", "harness", "mode", "yolo", "project", "backend"))
                    and all(row[name] is None or type(row[name]) is str for name in ("branch", "spawn_gen"))
                    and type(row["secondmate_projects"]) is list
                    and all(type(value) is str for value in row["secondmate_projects"]), "invalid snapshot scalar fields")
            for name in ("paths", "current_state", "endpoint", "pr", "hints", "actions"):
                require(type(row.get(name)) is dict, "invalid snapshot row object")
            require(set(row["paths"]) == {"meta", "status_log", "worktree", "home", "report"}, "invalid snapshot paths")
            for name, value in row["paths"].items():
                require(type(value) is dict and (value.get("path") is None or type(value.get("path")) is str)
                        and (type(value.get("present")) is bool or name == "home" and value.get("present") is None),
                        "invalid snapshot path value")
            require(row["paths"]["meta"]["path"] == home + "/state/" + row["id"] + ".meta"
                    and row["paths"]["status_log"]["path"] == home + "/state/" + row["id"] + ".status"
                    and row["paths"]["report"]["path"] == home + "/data/" + row["id"] + "/report.md",
                    "snapshot task path binding mismatch")
            current = row["current_state"]
            require(all(type(current.get(name)) is str for name in ("state", "source", "detail", "raw"))
                    and current.get("observed_at") == arguments[1] and current.get("freshness") == "fresh",
                    "invalid snapshot current-state reply")
            require(current["state"] in ("working", "parked", "blocked", "paused", "done", "failed", "unknown")
                    and current["source"] in ("none", "status-log", "pane", "run-step", "park")
                    and "\n" not in current["raw"], "invalid snapshot current-state values")
            endpoint = row["endpoint"]
            require((type(endpoint.get("exists")) is bool or endpoint.get("exists") is None)
                    and endpoint.get("agent_alive") in ("not_checked", "unknown", "alive", "dead")
                    and endpoint.get("status") in ("unknown", "absent", "alive", "dead")
                    and endpoint.get("observed_at") == arguments[1] and endpoint.get("freshness") == "fresh",
                    "invalid snapshot endpoint")
            require(type(row["hints"].get("open_decisions")) is list
                    and type(row["hints"].get("pending_decision")) is bool
                    and type(row["hints"].get("blocked_event")) is bool, "invalid snapshot hints")
            for opened in row["hints"]["open_decisions"]:
                require(type(opened) is dict and all(type(opened.get(name)) is str for name in ("key", "verb", "summary"))
                        and opened["verb"] in ("blocked", "needs-decision"), "invalid snapshot decision")
        output = encoded(result["tasks"]).decode("ascii")
        stage_snapshot(result, arguments[5])
        return output
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
    return presentation_output(result, rows, originals, from_state=verb == "drain-presentation")


if __name__ == "__main__":
    try:
        output = main(sys.argv[1:], os.environ)
        sys.stdout.buffer.write(output.encode("utf-8", "surrogateescape"))
        sys.stdout.buffer.flush()
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print("fm-view-client: read refused; use legacy: " + str(exc)[:500], file=sys.stderr)
        sys.exit(1)
