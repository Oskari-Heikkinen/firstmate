#!/usr/bin/env python3
"""CI-only paired checkpoint diagnostic; never imported by production.

Usage: p1-checkpoint.py --base DIR --head DIR --output DIR
                         --mode {control,instrumented}
Runs the unchanged ledger fixture alone, sequentially, on counterbalanced exact
base/head checkouts. Instrumented mode inserts builtin-only phase markers in two
runner-only production copies. It changes no assertion, deadline or exit policy.
The diagnostic ref and these runner copies must never land. No local execution.
Every sample has an outer 60-second bound and ten-second cleanup grace, separate
from the unchanged fixture/production bounds. Failures do not stop later samples.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import time

PINS = {
    "base": "8d3d61bfb07fd50c6045682f4c755d4fd37ea59e",
    "head": "9d6a47fa61d9411237c2c9f86beb561309b29d4e",
}
EVENT = "_sr_p1_checkpoint_diag_event"
HELPER = f'''\n# Diagnostic-only builtin markers, outside all landing refs.
{EVENT}() {{
  printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$EPOCHREALTIME" "${{BASHPID:-$$}}" \\
    "${{FM_HOME:-}}" "${{0##*/}}" "$1" "${{2:-}}" >> "$FM_CHECKPOINT_DIAG_LOG"
}}
'''


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"diagnostic anchor not unique: {old!r}")
    return text.replace(old, new, 1)


def instrument(root):
    watcher = root / "bin/fm-watch.sh"
    text = watcher.read_text()
    text = replace_once(text, "set -u\n", f"set -u\n{HELPER}\n{EVENT} watcher-entry\n")
    for library in (
        "fm-push-transition-lib.sh", "fm-pr-lib.sh", "fm-procevent-lib.sh",
        "fm-merge-outcome-lib.sh", "fm-merge-authority-lib.sh", "fm-x-lib.sh",
        "fm-check-lib.sh", "fm-pending-reply-lib.sh", "fm-busy-lib.sh",
        "fm-task-inbox-lib.sh", "fm-afk-contract.sh",
        "fm-secondmate-liveness-lib.sh", "fm-home-summary-refresh-lib.sh",
    ):
        anchor = f'. "$SCRIPT_DIR/{library}"\n'
        text = replace_once(text, anchor,
                            f'{EVENT} source-begin {library}\n{anchor}'
                            f'{EVENT} source-end {library}\n')
    text = replace_once(text, '  trap \'exit 1\' INT\n',
                        f"  trap '{EVENT} interrupt; exit 1' INT\n")
    text = replace_once(text, 'while ! fm_lock_try_acquire "$WATCH_LOCK"; do\n',
                        f'{EVENT} lock-begin\n'
                        'while ! fm_lock_try_acquire "$WATCH_LOCK"; do\n')
    text = replace_once(text, 'if [ -n "$EVICTED_PID" ]; then\n',
                        f'{EVENT} lock-acquired\nif [ -n "$EVICTED_PID" ]; then\n')
    text = replace_once(text, 'watcher_cleanup() {\n',
                        f'watcher_cleanup() {{\n  {EVENT} cleanup-entry\n')
    start = text.index("watcher_cleanup() {\n")
    end = text.index("\ntrap watcher_cleanup EXIT", start)
    cleanup = text[start:end]
    for anchor, label in (
        ("  watcher_watchdog_stop\n", "cleanup-watchdog"),
        ("  pr_poll_control_release || cleanup_status=1\n", "cleanup-pr-locks"),
        ("  fm_active_check_stop || cleanup_status=1\n", "cleanup-active-check"),
        ("  fm_custom_check_snapshot_cleanup\n", "cleanup-captures"),
    ):
        cleanup = replace_once(cleanup, anchor, anchor + f"  {EVENT} {label}\n")
    cleanup = replace_once(cleanup, '  return "$cleanup_status"\n',
                           f'  {EVENT} cleanup-return "$cleanup_status"\n'
                           '  return "$cleanup_status"\n')
    text = text[:start] + cleanup + text[end:]
    text = replace_once(text, "trap watcher_cleanup EXIT\nwatcher_stop_signals\n",
                        f"trap watcher_cleanup EXIT\nwatcher_stop_signals\n{EVENT} traps-ready\n")
    text = replace_once(text, "  WATCHER_CYCLE=$((WATCHER_CYCLE + 1))\n",
                        "  WATCHER_CYCLE=$((WATCHER_CYCLE + 1))\n"
                        f'  {EVENT} cycle "$WATCHER_CYCLE"\n')
    watcher.write_text(text)

    checkpoint = root / "bin/fm-watch-checkpoint.sh"
    text = checkpoint.read_text()
    text = replace_once(text, "set -u\n", f"set -u\n{HELPER}\n{EVENT} checkpoint-entry\n")
    text = replace_once(text, 'run_bounded "$SECONDS_ARG" INT 5 "$SCRIPT_DIR/fm-watch.sh"',
                        f'{EVENT} checkpoint-bound "$SECONDS_ARG"\n'
                        'run_bounded "$SECONDS_ARG" INT 5 "$SCRIPT_DIR/fm-watch.sh"')
    text = replace_once(text, "RC=$?\nset -e\n",
                        f'RC=$?\n{EVENT} checkpoint-return "$RC"\nset -e\n')
    # The original GNU timeout deadlines/signals stay untouched. Verbose only
    # adds delivered-signal diagnostics to the already-captured stderr stream.
    text = replace_once(text,
                        '      timeout --signal="$signal" --kill-after="${kill_after}s"',
                        '      timeout --verbose --signal="$signal" --kill-after="${kill_after}s"')
    checkpoint.write_text(text)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def host_state():
    result = {}
    for path in ("/proc/loadavg", "/proc/pressure/cpu", "/proc/pressure/memory", "/proc/stat"):
        result[path] = Path(path).read_text()
    return result


def dist(values):
    if not values:
        return {"n": 0}
    values = sorted(values)
    return {"n": len(values), "min": min(values), "median": statistics.median(values),
            "p95": values[max(0, (95 * len(values) + 99) // 100 - 1)], "max": max(values)}


def phases(log):
    if not log.exists():
        return []
    groups = {}
    for line in log.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) != 6:
            raise RuntimeError(f"malformed diagnostic marker: {line!r}")
        stamp, pid, home, script, event, detail = fields
        groups.setdefault(home, []).append((float(stamp), pid, script, event, detail))
    result = []
    for home, events in groups.items():
        # Watchdog/subshell identities are retained in raw evidence. Restrict
        # measurements to the watcher main shell selected by watcher-entry.
        entries = [e for e in events if e[3] == "watcher-entry"]
        bounds = [e for e in events if e[3] == "checkpoint-bound"]
        if len(entries) != 1 or len(bounds) != 1:
            result.append({"home": home, "error": "missing/duplicate entry or bound", "events": events})
            continue
        entry, bound = entries[0], bounds[0]
        main = [e for e in events if e[1] == entry[1]]
        row = {"home": home, "ledger": "off" if "/off-lifecycle/" in home else "on",
               "watcher_pid": entry[1], "markers": {e[3]: e[0] for e in main}}
        for label, first, last in (
            ("startup_ms", "watcher-entry", "traps-ready"),
            ("first_cycle_ms", "watcher-entry", "cycle"),
            ("cleanup_ms", "cleanup-entry", "cleanup-return"),
        ):
            left = next((e[0] for e in main if e[3] == first), None)
            right = next((e[0] for e in main if e[3] == last), None)
            row[label] = (right - left) * 1000 if left is not None and right is not None else None
        interrupt = next((e[0] for e in main if e[3] == "interrupt"), None)
        row["interrupt_after_bound_ms"] = ((interrupt - bound[0] - float(bound[4])) * 1000
                                            if interrupt is not None else None)
        returned = next((e for e in events if e[3] == "checkpoint-return"), None)
        row["checkpoint_ms"] = (returned[0] - bound[0]) * 1000 if returned else None
        row["checkpoint_rc"] = returned[4] if returned else None
        row["source_ms"] = {}
        for begin in (e for e in main if e[3] == "source-begin"):
            finish = next((e for e in main if e[3] == "source-end" and e[4] == begin[4]), None)
            row["source_ms"][begin[4]] = (finish[0] - begin[0]) * 1000 if finish else None
        result.append(row)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--head", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=("control", "instrumented"), required=True)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("CI-only diagnostic: local test execution refused")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    roots = {"base": args.base.resolve(), "head": args.head.resolve()}
    manifest = {"pins": PINS, "mode": args.mode, "platform": platform.platform(),
                "driver_sha256": digest(Path(__file__)), "job": os.environ.get("GITHUB_JOB"),
                "run": os.environ.get("GITHUB_RUN_ID"), "inputs": {}}
    for name, root in roots.items():
        if git(root, "rev-parse", "HEAD") != PINS[name] or git(root, "status", "--porcelain"):
            raise RuntimeError(f"not a clean pinned checkout: {name}")
        paths = ("bin/fm-watch.sh", "bin/fm-watch-checkpoint.sh", "tests/fm-fleet-ledger.test.sh")
        before = {p: digest(root / p) for p in paths}
        if args.mode == "instrumented":
            instrument(root)
        after = {p: digest(root / p) for p in paths}
        if before[paths[-1]] != after[paths[-1]]:
            raise RuntimeError("fixture bytes changed")
        (out / f"{name}-instrumentation.diff").write_text(git(root, "diff", "--", *paths) + "\n")
        manifest["inputs"][name] = {"before": before, "after": after}
        # Syntax-only, never a local suite. Both pinned Bash scripts must parse
        # with exactly the instrumentation recorded above before any sample.
        for path in paths[:2]:
            subprocess.run(["bash", "-n", str(root / path)], check=True)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    samples = []
    started = time.monotonic()
    repetitions = 20 if args.mode == "instrumented" else 5
    for pair in range(repetitions):
        order = ("base", "head") if pair % 2 == 0 else ("head", "base")
        for position, name in enumerate(order):
            sample = out / f"pair-{pair + 1:02d}-{position}-{name}"
            sample.mkdir()
            if time.monotonic() - started > 3300:
                samples.append({"pair": pair + 1, "name": name, "skipped": "55-minute diagnostic bound"})
                continue
            root = roots[name]
            expected = manifest["inputs"][name]["after"]
            if any(digest(root / p) != h for p, h in expected.items()):
                raise RuntimeError("sample inputs changed between repetitions")
            environment = os.environ.copy()
            environment["FM_CHECKPOINT_DIAG_LOG"] = str(sample / "events.tsv")
            environment["TMPDIR"] = str(sample / "tmp")
            (sample / "tmp").mkdir()
            row = {"pair": pair + 1, "position": position, "name": name,
                   "mode": args.mode, "before": host_state(), "wall_start": time.time()}
            begin = time.monotonic()
            with (sample / "fixture.log").open("w") as log:
                process = subprocess.Popen(["bash", "tests/fm-fleet-ledger.test.sh"], cwd=root,
                                           env=environment, stdout=log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                try:
                    row["rc"] = process.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    row["outer_timeout"] = True
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        row["rc"] = process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        row["rc"] = process.wait()
            row["wall_ms"] = (time.monotonic() - begin) * 1000
            row["after"] = host_state()
            row["phases"] = phases(sample / "events.tsv")
            samples.append(row)
            (sample / "result.json").write_text(json.dumps(row, indent=2) + "\n")
            (out / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
            print(json.dumps({k: row[k] for k in ("pair", "position", "name", "rc", "wall_ms")}), flush=True)
    summary = {}
    for name in roots:
        rows = [r for r in samples if r["name"] == name and "rc" in r]
        summary[name] = {"samples": len(rows), "failures": sum(r["rc"] != 0 for r in rows),
                         "wall_ms": dist([r["wall_ms"] for r in rows]), "ledger": {}}
        for ledger in ("on", "off"):
            events = [p for r in rows for p in r["phases"] if p.get("ledger") == ledger]
            summary[name]["ledger"][ledger] = {"observed": len(events)}
            for key in ("startup_ms", "first_cycle_ms", "cleanup_ms", "interrupt_after_bound_ms", "checkpoint_ms"):
                summary[name]["ledger"][ledger][key] = dist([p[key] for p in events if p.get(key) is not None])
            for library in sorted({lib for p in events for lib in p["source_ms"]}):
                summary[name]["ledger"][ledger][library] = dist([p["source_ms"][library] for p in events
                                                               if p["source_ms"].get(library) is not None])
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    # No fail-fast across samples, but no success verdict hides any failure,
    # skipped sample, missing timing marker, or corrupted instrumentation.
    failed = any(r.get("rc") != 0 for r in samples)
    if args.mode == "instrumented":
        failed = failed or any(len(r.get("phases", [])) != 2 or any(
            "error" in p or p.get("startup_ms") is None or p.get("cleanup_ms") is None
            for p in r.get("phases", [])) for r in samples)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
