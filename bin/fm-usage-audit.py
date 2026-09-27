#!/usr/bin/env python3
"""Repeatable home-local metadata-only usage/repetition audit (classifier v1).

Usage: fm-usage-audit.sh --home DIR [--also-root DIR] [--usage JSONL] [--events JSONL]
       [--status FILE] [--scripts DIR] [--inventory DIR] [--queue-log FILE]
       [--since EPOCH] [--until EPOCH] [--line-limit N]
Flags selecting inputs repeat; no implicit scans, remote IO or transcript export.
Relative inputs resolve inside the selected home; an absolute input must resolve
inside the home or an explicitly selected --also-root (for example a sibling home
or a local queue-log directory). Symlinks escaping every selected root are
refused, script scans ignore symlinks. File IDs digest root index plus relative
path. Output is JSON on stdout, no files changed.

Approved usage export rows: schema=fm-usage.v1, id, role, ts (Unix seconds),
input_tokens, output_tokens, cached_input_tokens, context_tokens (nonnegative
integers; cached input is a SUBSET, never added to input), optional cycle_kind
(receipt-only/wait-renewal/work/unknown). One row represents one measured call.
Identity is id within this home; duplicate IDs are counted once, conflicting
IDs are excluded and reported. Role is a metadata label [A-Za-z0-9_.-]+.
Cycle kinds are exporter assertions, not proof of wasted calls. Missing metrics
are rejected rather than invented. No usage input means actual use is unknown.

Event inputs accept the existing fleet-ledger v1 and fm-audit-event.v1 receipts.
Audit receipts: id, task, spawn_gen, correlation, event (produced/consumed), ts,
consumer (required for consumed). Latency joins exact task/generation/correlation,
not status prose, and excludes ambiguous multiple production/consumption records
or negative durations. Fleet-ledger records have no durable IDs/gap detection:
exact duplicate fingerprints are a LOWER-BOUND projection only; raw counts are
also reported. Truncated tails, invalid rows, duplicates and unknown event kinds
are counted. A valid unterminated last row is treated as an incomplete tail.

Status input preserves this audit's numeric [at=EPOCH] window, line/character
counts (both with and without line endings) and per-verb counts; unknown-time
lines are separate. --line-limit selects a fixed prefix of each line input.
Queue logs count HANDOFF/RESULT, explicit outcome= tokens and distinct main=
commit identities for landed results; their window is prefix-only, never inferred
from human timestamps. Inventory counts immediate regular files by suffix,
including .public.json/.release.json and .ack, without reading their contents. Paused/ack counts
are inferred wait/receipt candidates, NOT calls, renewals or useful/wasted work.
Identical scripts are grouped by full-file SHA-256; paths are output only as
home-relative digest IDs. Samples contain file digest ID, line and class, never
status prose, prompts or commands. No historical studies are added together.
Snapshot file hashes/byte lengths and window/classifier identity make reruns
reviewable. Active append/rotation can still change future inputs; coverage of a
truncated or previously rotated ledger is always unknown. Limits: 64 MiB/file,
1 MiB/line, 100k rows/file, 10k files/script directory; exceeding bounds refuses
rather than quietly sampling. UTF-8 input only. No external classifier is used.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
from fm_receipt_io import canonical, digest, emit, local_path, number, text

MAX_BYTES = 64 * 1024 * 1024


def bytes_at(path):
    if not path.is_file():
        raise ValueError("input must be a regular file")
    with path.open("rb") as stream:
        value = stream.read(MAX_BYTES + 1)
    if len(value) > MAX_BYTES:
        raise ValueError("input exceeds 64 MiB")
    return value


def rows_at(raw):
    lines = raw.splitlines(keepends=True)
    if len(lines) > 100000 or any(len(line) > 1024 * 1024 for line in lines):
        raise ValueError("input row bound exceeded")
    for n, line in enumerate(lines, 1):
        yield n, line.decode("utf-8"), line.endswith(b"\n")


def integer(value):
    number(value)
    if not isinstance(value, int):
        raise ValueError("token metric must be an integer")
    return value


def label(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", text(value)):
        raise ValueError("invalid role metadata label")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", required=True)
    parser.add_argument("--also-root", action="append", default=[])
    for flag in ("usage", "events", "status", "scripts", "inventory", "queue-log"):
        parser.add_argument(f"--{flag}", action="append", default=[])
    parser.add_argument("--line-limit", type=int)
    parser.add_argument("--since", type=float, default=0)
    parser.add_argument("--until", type=float, default=99999999999)
    args = parser.parse_args()
    number(args.since)
    number(args.until)
    if args.since > args.until or (args.line_limit is not None and args.line_limit < 1):
        raise ValueError("invalid window/prefix")
    home = Path(args.home).resolve(strict=True)
    roots = [home] + [Path(r).resolve(strict=True) for r in args.also_root]

    def contained(value):
        # Relative inputs name the home; absolute ones may sit in any selected root.
        candidates = roots if Path(value).is_absolute() else roots[:1]
        for index, base in enumerate(candidates):
            try:
                path = local_path(base, value)
            except ValueError:
                continue
            return path, digest(f"{index}:{path.relative_to(base)}".encode())
        raise ValueError("input outside selected roots")
    counts = Counter()
    inputs, samples = [], []
    usages, conflicts, events, event_conflicts = {}, set(), {}, set()
    poisoned_correlations = set()
    ledger_raw, ledger_unique = Counter(), {}
    status_counts = Counter()
    status_characters = 0
    status_characters_with_newlines = 0
    scripts = defaultdict(list)
    script_counts = Counter()
    inventories = []
    queue_kinds, queue_outcomes, landed_commits = Counter(), Counter(), set()
    visited = set()

    def selected(ts):
        return args.since <= number(ts) <= args.until

    def sample(fid, line, classification):
        if len(samples) < 30:
            samples.append({"file_id": fid, "line": line, "class": classification})

    for kind in ("usage", "events", "status", "scripts", "inventory", "queue_log"):
        paths = []
        for value in getattr(args, kind):
            path, root_fid = contained(value)
            if kind == "inventory":
                if (kind, path) in visited:
                    counts["duplicate_input_paths"] += 1
                    continue
                visited.add((kind, path))
                entries = []
                for p in path.iterdir():
                    entries.append(p)
                    if len(entries) > 10000:
                        raise ValueError("inventory entry bound exceeded")
                entries.sort()
                suffixes = Counter()
                manifest = []
                for p in entries:
                    if p.is_file() and not p.is_symlink():
                        suffix = next((s for s in (".public.json", ".release.json", ".json", ".ack", ".py", ".sh")
                                       if p.name.endswith(s)), "other")
                        suffixes[suffix] += 1
                        manifest.append({"name_digest": digest(p.name.encode()), "bytes": p.stat().st_size})
                inventories.append({"directory_id": root_fid,
                                    "manifest_sha256": digest(canonical(manifest)),
                                    "files": len(manifest), "by_suffix": suffixes})
            elif kind == "scripts":
                if not path.is_dir():
                    raise ValueError("script input must be a directory")
                candidates = []
                for visited_count, p in enumerate(path.rglob("*"), 1):
                    if visited_count > 100000:
                        raise ValueError("script traversal bound exceeded")
                    if p.is_file() and not p.is_symlink() and p.suffix in (".sh", ".py"):
                        candidates.append(p)
                        if len(candidates) > 10000:
                            raise ValueError("script file bound exceeded")
                paths.extend(sorted(candidates))
            else:
                paths.append(path)
        for path in paths:
            path, fid = contained(str(path))
            if (kind, path) in visited:
                counts["duplicate_input_paths"] += 1
                continue
            visited.add((kind, path))
            raw = bytes_at(path)
            inputs.append({"kind": kind, "file_id": fid, "sha256": digest(raw), "bytes": len(raw)})
            if kind == "scripts":
                script_counts[path.suffix] += 1
                scripts[digest(raw)].append({"file_id": fid, "bytes": len(raw)})
                continue
            for line_no, line, complete in rows_at(raw):
                if args.line_limit is not None and line_no > args.line_limit:
                    counts["prefix_limited_inputs"] += 1
                    break
                if not complete:
                    counts["incomplete_tails"] += 1
                    sample(fid, line_no, "incomplete-tail")
                    continue
                if kind == "queue_log":
                    verb = line.split(maxsplit=1)[0] if line.strip() else "unknown"
                    queue_kinds[verb if verb in {"HANDOFF", "RESULT"} else "unknown"] += 1
                    outcome = re.search(r"(?:^|\s)outcome=(\w+)(?=\s|$)", line)
                    if verb == "RESULT" and outcome:
                        label_value = outcome[1] if outcome[1] in {"taken", "landed", "culprit", "conflict", "dropped"} else "unknown"
                        queue_outcomes[label_value] += 1
                        main = re.search(r"(?:^|\s)main=([0-9a-f]{7,64})(?=\s|$)", line)
                        if label_value == "landed" and main:
                            landed_commits.add(main[1])
                    continue
                if kind == "status":
                    stamp = re.search(r"\[at=([0-9]+)\]", line)
                    if stamp is None:
                        counts["status_unknown_time"] += 1
                        continue
                    if not selected(int(stamp[1])):
                        continue
                    match = re.match(r"([a-z-]+)(?:\s|:)", line)
                    verb = match[1] if match else "unknown"
                    # Only fixed labels are emitted; arbitrary status words stay private.
                    if verb not in {"working", "paused", "ack", "note", "done", "failed",
                                    "blocked", "needs-decision", "resolved"}:
                        verb = "unknown"
                    status_counts[verb] += 1
                    status_characters += len(line.rstrip("\r\n"))
                    status_characters_with_newlines += len(line)
                    if verb in {"paused", "ack"}:
                        sample(fid, line_no, f"inferred-{verb}-candidate")
                    continue
                try:
                    row = json.loads(line)
                    if not selected(row["ts"]):
                        continue
                    if kind == "usage":
                        if row["schema"] != "fm-usage.v1":
                            raise ValueError("unknown usage schema")
                        rid = text(row["id"])
                        clean = {"role": label(row["role"]), "ts": row["ts"]}
                        for metric in ("input_tokens", "output_tokens", "cached_input_tokens", "context_tokens"):
                            clean[metric] = integer(row[metric])
                        if clean["cached_input_tokens"] > clean["input_tokens"]:
                            raise ValueError("cached input exceeds total input")
                        cycle = row.get("cycle_kind", "unknown")
                        clean["cycle_kind"] = cycle if cycle in {"receipt-only", "wait-renewal", "work"} else "unknown"
                        if rid in usages:
                            counts["duplicate_usage_ids"] += 1
                            if usages[rid] != clean:
                                conflicts.add(rid)
                        else:
                            usages[rid] = clean
                    elif row.get("schema") == "fm-audit-event.v1":
                        rid = text(row["id"])
                        clean = {k: text(row[k]) for k in ("task", "spawn_gen", "correlation", "event")}
                        if clean["event"] not in ("produced", "consumed"):
                            raise ValueError("unknown audit event")
                        clean["ts"] = row["ts"]
                        clean["consumer"] = text(row["consumer"]) if clean["event"] == "consumed" else None
                        if rid in events:
                            counts["duplicate_event_ids"] += 1
                            if events[rid] != clean:
                                event_conflicts.add(rid)
                                for conflicting in (events[rid], clean):
                                    poisoned_correlations.add(tuple(conflicting[k] for k in ("task", "spawn_gen", "correlation")))
                        else:
                            events[rid] = clean
                    elif row.get("v") == 1:
                        event = row.get("event")
                        if event not in {"task.dispatched", "task.status", "task.pr_ready", "task.merged", "task.cleaned_up"}:
                            counts["unknown_ledger_events"] += 1
                            continue
                        text(row["task"])
                        ledger_raw[event] += 1
                        key = digest(canonical(row))
                        if key in ledger_unique:
                            counts["exact_ledger_duplicates"] += 1
                        ledger_unique[key] = event
                    else:
                        raise ValueError("unknown event schema")
                except (ValueError, KeyError, TypeError):
                    counts[f"invalid_{kind}_rows"] += 1
                    sample(fid, line_no, f"invalid-{kind}")
    roles = {}
    for rid, row in usages.items():
        if rid in conflicts:
            continue
        role = roles.setdefault(row["role"], {"calls": 0, "input_tokens": 0, "output_tokens": 0,
                                             "cached_input_tokens": 0, "context_tokens": 0,
                                             "max_context_tokens": 0, "exporter_cycle_kinds": Counter()})
        role["calls"] += 1
        for metric in ("input_tokens", "output_tokens", "cached_input_tokens", "context_tokens"):
            role[metric] += row[metric]
        role["max_context_tokens"] = max(role["max_context_tokens"], row["context_tokens"])
        role["exporter_cycle_kinds"][row["cycle_kind"]] += 1
    for role in roles.values():
        role["mean_context_tokens"] = role["context_tokens"] / role["calls"]
    groups = defaultdict(list)
    for rid, event in events.items():
        if rid not in event_conflicts:
            groups[tuple(event[k] for k in ("task", "spawn_gen", "correlation"))].append(event)
    latencies = []
    for key, group in groups.items():
        if key in poisoned_correlations:
            counts["conflicted_latency_correlations"] += 1
            continue
        producers = [r for r in group if r["event"] == "produced"]
        consumers = defaultdict(list)
        for row in group:
            if row["event"] == "consumed":
                consumers[row["consumer"]].append(row)
        if len(producers) != 1:
            counts["ambiguous_or_missing_production"] += 1
            continue
        if not consumers:
            counts["unconsumed_production"] += 1
        for consumer, rows in consumers.items():
            if len(rows) != 1 or rows[0]["ts"] < producers[0]["ts"]:
                counts["ambiguous_or_negative_latency"] += 1
                continue
            latencies.append({"identity_digest": digest(canonical([*key, consumer])),
                              "seconds": rows[0]["ts"] - producers[0]["ts"]})
    counts["conflicting_usage_ids"] = len(conflicts)
    counts["conflicting_event_ids"] = len(event_conflicts)
    emit({"schema": "fm-usage-audit.v1", "classifier": "local-metadata-v1",
          "window": {"since": args.since, "until": args.until, "line_limit": args.line_limit}, "inputs": inputs,
          "actual_usage": {"available": bool(usages.keys() - conflicts), "by_role": roles},
          "status_observations": {"lines": sum(status_counts.values()), "characters": status_characters,
                                  "characters_with_newlines": status_characters_with_newlines,
                                  "by_verb": status_counts},
          "script_inventory": {"files": sum(script_counts.values()), "by_suffix": script_counts},
          "directory_inventories": inventories,
          "queue_log": {"window": "fixed prefix only", "by_kind": queue_kinds, "outcomes": queue_outcomes,
                        "distinct_landed_main_commits": len(landed_commits)},
          "fleet_ledger": {"raw_counts": ledger_raw, "exact_unique_lower_bound": Counter(ledger_unique.values()),
                           "coverage": "unknown; ledger has no gap/rotation identity"},
          "event_to_consumer_latency": latencies,
          "identical_scripts": [{"sha256": sha, "copies": copies} for sha, copies in sorted(scripts.items()) if len(copies) > 1],
          "quality": counts, "review_samples": samples,
          "limitations": ["No status line count is a measured call/token count.",
                          "Exporter cycle kinds and inferred candidates do not prove waste or usefulness.",
                          "Windows/classifiers and workload/model confounds must be reviewed before comparison.",
                          "No extrapolated savings or historical totals are added."]})


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        # Input paths and prose can contain private material; keep errors metadata-only.
        print(f"fm-usage-audit: invalid/unreadable input ({type(error).__name__}); see --help", file=sys.stderr)
        sys.exit(1)
