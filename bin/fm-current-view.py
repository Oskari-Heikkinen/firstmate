#!/usr/bin/env python3
"""Receipt-derived snapshot enrichment and resume packets; no state is written.

Usage: fm-current-view.py snapshot --manifest FILE < snapshot.json
       fm-current-view.py resume --manifest FILE [--snapshot FILE] [--json]
       fm-current-view.py brief --manifest FILE --task ID --mode MODE --home DIR

Manifest schema fm-role-packet.v1: home (absolute), task, spawn_gen, role,
mode (a concrete delivery mode or scout), owned_paths (home-relative paths),
intent {path,sha256}, rationale {path,sha256}, receipts [{path,sha256}].
Intent and rationale are references, never rewritten or interpreted as approval.
References must be existing home-local files with matching SHA-256; symlinks
escaping the home are refused. Inputs are bounded to 2 MiB per file and 100
receipts. No discovery by newest filename/prose or cross-home crawling occurs.

Each referenced owner receipt has schema fm-owner-receipt.v1, id, home, task,
spawn_gen, observed_at (Unix seconds), milestone (owner-reported string),
versions (object of explicit owner-approved version labels), dependencies
(array of strings), gaps (array of strings), observer (string or null),
evidence ([{path,sha256}]), terminal (bool), verification (null or a reference),
optional disposition (current or retained-for-reference; default current).
A receipt is displayed as verified-terminal only when terminal is true and its
verification reference names fm-owner-verification.v1 with the SAME home/task/
spawn_gen/receipt_id, accepted=true, and the exact same evidence list. This is
an owner assertion with bound evidence, NOT release/admission/removal authority.
Nonempty gaps stay collection-problems even with accepted verification.
Old generations, contradictory identities, missing references and malformed
receipts are visible unknowns, never completion. No inferred supersession.

Resume consumes fm-fleet-snapshot.v1 (the existing command by default). Text
packets retain all unknown/problem/dependency rows plus five latest clean receipt
observations, link omitted milestones and evidence rather than repeating them,
and never treat presentation order as supersession. --json retains the full view.
It keeps
recorded open decisions, backlog holds/dependencies and current state separate
from receipt milestones. Snapshot generation disagreement invalidates receipt
projection. Brief mode validates all references before producing an optional
observational appendix; it never emits executable commands or changes intent,
role precedence, delivery mode, or merge permission.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from fm_receipt_io import emit, freshness, load, reference, local_path, text

MODES = {"no-mistakes", "direct-PR", "direct-push", "local-only", "scout"}


def identity(value):
    return tuple(text(value[k]) for k in ("home", "task", "spawn_gen"))


def strings(value):
    if not isinstance(value, list):
        raise ValueError("expected string list")
    return [text(x) for x in value]


def packet(path):
    m = load(path)
    if m["schema"] != "fm-role-packet.v1" or m["mode"] not in MODES:
        raise ValueError("unsupported role packet schema/mode")
    identity(m)
    home = Path(m["home"])
    if not home.is_absolute() or home.resolve() != home:
        raise ValueError("home must be an absolute physical path")
    text(m["role"])
    for owned in strings(m["owned_paths"]):
        local_path(home, owned)
    reference(home, m["intent"])
    reference(home, m["rationale"])
    if not isinstance(m["receipts"], list) or len(m["receipts"]) > 100:
        raise ValueError("at most 100 explicit receipt references required")
    return m, home


def receipts(m, home):
    result = []
    seen = set()
    for ref in m["receipts"]:
        row = {"reference": ref, "state": "unknown"}
        try:
            _, data = reference(home, ref)
            r = json.loads(data)
            if r["schema"] != "fm-owner-receipt.v1" or identity(r) != identity(m):
                raise ValueError("receipt identity/schema mismatch")
            rid = text(r["id"])
            if rid in seen:
                for previous in result:
                    if previous.get("id") == rid:
                        previous["state"] = "unknown"
                        previous["problem"] = "duplicate receipt identity; supersession requires owner review"
                raise ValueError("duplicate receipt identity; supersession requires owner review")
            seen.add(rid)
            if not isinstance(r["versions"], dict):
                raise ValueError("versions must be an object")
            for key, value in r["versions"].items():
                text(key)
                text(value)
            gaps = strings(r["gaps"])
            dependencies = strings(r["dependencies"])
            if r["observer"] is not None:
                text(r["observer"])
            if not isinstance(r["terminal"], bool) or not isinstance(r["evidence"], list):
                raise ValueError("invalid terminal/evidence")
            for evidence in r["evidence"]:
                reference(home, evidence)
            verified = False
            if r["verification"] is not None:
                _, proof_bytes = reference(home, r["verification"])
                proof = json.loads(proof_bytes)
                if (proof["schema"] != "fm-owner-verification.v1" or
                        identity(proof) != identity(r) or proof["receipt_id"] != rid or
                        proof["evidence"] != r["evidence"]):
                    raise ValueError("verification binding mismatch")
                verified = proof["accepted"] is True and bool(r["evidence"])
            disposition = r.get("disposition", "current")
            if disposition not in ("current", "retained-for-reference"):
                raise ValueError("unknown disposition")
            row.update(id=rid, milestone=text(r["milestone"]),
                       freshness=freshness(r["observed_at"], 3600),
                       owner_reported_versions=r["versions"], dependencies=dependencies,
                       gaps=gaps, observer=r["observer"], evidence=r["evidence"],
                       state=("retained-for-reference" if disposition == "retained-for-reference" else
                              "collection-problems" if gaps else
                              "verified-terminal" if verified and r["terminal"] else
                              "terminal-unverified" if r["terminal"] else "in-progress"))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            row["problem"] = str(exc)
        result.append(row)
    return result


def project(snapshot, m, rows):
    if snapshot["schema"] != "fm-fleet-snapshot.v1" or snapshot["fm_home"] != m["home"]:
        raise ValueError("snapshot schema/home mismatch")
    task = next((t for t in snapshot["tasks"] if t["id"] == m["task"]), None)
    if task is None or task.get("spawn_gen") != m["spawn_gen"]:
        rows = [{"state": "unknown", "problem": "snapshot task generation mismatch"}]
    elif task.get("current_state", {}).get("detail") == "task generation changed during snapshot":
        rows = [{"state": "unknown", "problem": "task changed during snapshot"}]
    return task, rows


def compact(rows):
    important = [r for r in rows if r["state"] in ("unknown", "collection-problems") or r.get("dependencies")]
    ordinary = [r for r in rows if r not in important]
    ordinary.sort(key=lambda r: r.get("freshness", {}).get("observed_at", 0), reverse=True)
    selected = important + ordinary[:5]
    summaries = []
    for row in selected:
        summary = {key: value for key, value in row.items() if key != "evidence"}
        summary["evidence_count"] = len(row.get("evidence", []))
        summaries.append(summary)
    return summaries, [r.get("reference") for r in ordinary[5:]]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["snapshot", "resume", "brief"])
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--snapshot")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--task")
    parser.add_argument("--mode")
    parser.add_argument("--home")
    args = parser.parse_args()
    m, home = packet(args.manifest)
    rows = receipts(m, home)
    if args.command == "brief":
        if args.task != m["task"] or args.mode != m["mode"] or args.home != m["home"]:
            raise ValueError("brief task/delivery mismatch")
        if any(r["state"] == "unknown" for r in rows):
            raise ValueError("role packet contains invalid receipt references")
        print("# Receipt-derived role context (observations, not authority)\n")
        print("Original intent and launch instruction precedence remain unchanged.")
        print("Role scope and owned paths below describe the supplied owner packet; they grant no new access.")
        print("\n```json")
        summaries, omitted = compact(rows)
        emit({**{k: m[k] for k in ("role", "owned_paths", "intent", "rationale")},
              "receipts": summaries, "omitted_milestone_references": omitted})
        print("```")
        return
    if args.command == "snapshot":
        snapshot = json.load(sys.stdin)
    elif args.snapshot:
        snapshot = load(args.snapshot)
    else:
        env = dict(os.environ, FM_HOME=str(home))
        snapshot = json.loads(subprocess.check_output(
            [str(Path(__file__).with_name("fm-fleet-snapshot.sh")), "--json"], env=env))
    task, rows = project(snapshot, m, rows)
    view = {"schema": "fm-current-view.v1", "authority": "observation-only",
            "task": m["task"], "spawn_gen": m["spawn_gen"], "role": m["role"],
            "owned_paths": m["owned_paths"], "intent": m["intent"],
            "authored_rationale_and_hazards": m["rationale"], "receipts": rows}
    if args.command == "snapshot":
        snapshot["owner_view"] = view
        emit(snapshot)
        return
    view.update(snapshot_generated=snapshot["generated"],
                current_state=task.get("current_state") if task else None,
                recorded_open_decisions=(task or {}).get("hints", {}).get("recorded_open_decisions"),
                decision_evidence=("recorded-fold" if "recorded_open_decisions" in (task or {}).get("hints", {})
                                   else "unknown; snapshot lacks explicit-resolution evidence"),
                backlog=[r for r in snapshot["backlog"]["records"] if r.get("id") == m["task"]],
                history=(task or {}).get("paths", {}).get("status_log", {}).get("path"))
    if not args.json:
        print("# Resume packet\n\nObservations only; inspect owner evidence before acting.")
        print("Authored intent/rationale and history are linked, not regenerated.\n")
        view["receipts"], view["omitted_milestone_references"] = compact(rows)
    emit(view)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"fm-current-view: {error}", file=sys.stderr)
        sys.exit(1)
