"""Deterministic, synthetic six/thirty-crew inputs; never starts an endpoint.

Imported only by the CI test. Generated corpora and clocks are identical for a
fixed crew count. Neither fixture is a live fleet inventory or a B0 measurement.
"""
import base64
import hashlib


def make(crews):
    home = {"id": "fixture", "owner": "fixture-owner", "published_at": "2000-01-01T00:00:00Z",
            "home": "/fixture", "state_root": "/fixture/state",
            "state_identity": {"device": 1, "inode": 2}, "machine": "ci-fixture", "remote": False,
            "code_root": "/fixture/code", "code_ref": "1" * 40, "primary_harness": "fixture",
            "backend": "fixture", "session_identity": "fixture-session", "parent_route": "none",
            "configuration_sha256": "2" * 64,
            "timers": [{"name": "FM_POLL", "interval_ms": 15000, "bound_ms": 15000}],
            "tasks": [{"id": "task-" + str(n), "spawn_generation": "g1", "kind": "ship",
                       "endpoint_identity": "fixture-" + str(n), "park_token": "",
                       "custody_phase": "retained"} for n in range(crews)],
            "sources": [], "checks": [], "unsupported_integrations": [], "capture_roots": []}
    enrollment = {"format": "fm-supervision-fleet-manifest.v1", "certified_complete": False,
                  "publisher": "fixture", "enrolled_homes": ["fixture"], "homes": [home]}
    events = []

    def event(kind, ident, argv=None, parent="", at=None):
        events.append({"kind": kind, "id": ident, "argv": argv or [], "parent": parent,
                       "at_ns": at if at is not None else len(events) + 1,
                       "home": "fixture" if kind == "seed" else "", "thread": False,
                       "executable": ("/bin/bash" if argv and argv[0] == "bash"
                                      else argv[0] if argv else ""),
                       "exec_evidence": {"seed": "proc-exe-cmdline", "birth": "none",
                                         "exec": "execve"}[kind]})

    event("seed", "root", ["bash", "/fixture/code/bin/fm-watch.sh"])
    event("birth", "summary", parent="root")
    event("exec", "summary", ["bash", "/fixture/code/bin/fm-fleet-snapshot.sh"])
    for n in range(crews):
        ident = "crew-" + str(n)
        event("birth", ident, parent="summary")
        event("exec", ident, ["bash", "/fixture/code/bin/fm-crew-state.sh", "task-" + str(n)])
        # High-cost shell composition vs one cheap direct observation on the
        # identical synthetic schedule, not a prediction of real per-call cost.
        for suffix in ("date", "stat", "capture"):
            event("birth", ident + "-" + suffix, parent=ident)
            event("exec", ident + "-" + suffix, ["/usr/bin/" + suffix])
    for family, arguments in (("wake-drain", []),
                              ("spawn", ["task-new", "/fixture/project", "--mode",
                                         "direct-push", "--yolo", "off"]),
                              ("control", ["task-0", "state"])):
        event("birth", family, parent="root")
        event("exec", family, ["bash", "/fixture/code/bin/fm-" + family + ".sh", *arguments])
    # Text mentioning a sourced spawn library is not an executable entry.
    event("birth", "sourced", parent="root")
    event("exec", "sourced", ["bash", "-c", ". /fixture/code/bin/fm-spawn.sh"])
    records = []
    for kind, name, raw in (("queue", "wake", b"1\t7\tsignal\tx.status\tpayload\n"),
                            ("status", "task-0", b"working [key=x]: utf8 \xc3\xa4\nblocked: partial\xff"),
                            ("claim", "source", b"token=abc\nsequence=4\nsequence=5\n")):
        records.append({"kind": kind, "name": name, "base64": base64.b64encode(raw).decode(),
                        "sha256": hashlib.sha256(raw).hexdigest()})
    losses = dict.fromkeys(("unknown_lines", "unfinished_calls", "unresolved_argv",
                           "unknown_parents", "attachment_gaps"), 0)
    trace = {"format": "fm-supervision-trace.v1", "synthetic": True, "start_ns": 0,
             "end_ns": 60000000000, "monotonic_duration_ns": 60000000000,
             "machine_births": 4 * crews + 8, "capture_complete": True,
             "losses": losses, "events": events}
    return {"format": "fm-supervision-replay.v1", "synthetic": True,
            "label": str(crews) + "-crew-synthetic-shell-composition", "manifest": enrollment,
            "trace": trace, "records": records,
            "requests": [{"id": "read-" + str(n), "task": "task-" + str(n), "at_ns": n,
                          "kind": "crew-state", "adapter_responses": [
                              {"adapter": "pane", "generation": "g1", "at_ns": n + 1,
                               "exit_status": 0, "stdout_base64": "cGFuZQD/", "stderr_base64": ""},
                              {"adapter": "forge", "generation": "g1", "at_ns": n + 2,
                               "exit_status": 75, "stdout_base64": "", "stderr_base64": "d2FpdAr/"}
                          ]} for n in range(crews)]}
