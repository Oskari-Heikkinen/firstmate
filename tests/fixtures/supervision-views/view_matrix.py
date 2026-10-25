"""CI-only socket selection for complete existing drain/snapshot case matrices.

Each invocation owns one isolated read-only service. The real shell executable
inherits the caller's stdout descriptor, so failed-output tests still exercise
the transaction owner's write before commit, never a wrapper's buffered write.
No production home, installed actor, backend start or endpoint discovery.
"""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from crew_matrix import ROOT, allowed_refusal, record
from fm_view_engine import Engine, serve

COMMANDS = {"snapshot": "fm-fleet-snapshot.sh", "view": "fm-fleet-view.sh", "drain": "fm-wake-drain.sh"}


def admitted(error):
    return (allowed_refusal(error)
            or error == b"fm-view-client: read refused; use legacy: service refused: legacy migration cursor requires legacy presentation")


async def invoke(root, home, command, arguments):
    requests = []
    original = Engine.request

    async def observed(engine, operation, values, timeout):
        try:
            result = await original(engine, operation, values, timeout)
        except Exception as error:
            requests.append({"verb": operation, "ok": False, "reason": str(error)})
            raise
        requests.append({"verb": operation, "ok": True})
        return result

    # Keep AF_UNIX paths short even for the longest existing case directory.
    with tempfile.TemporaryDirectory(prefix="fm-vmatrix-") as temporary:
        os.chmod(temporary, 0o700)
        socket = str(Path(temporary) / "read.sock")
        epoch = uuid.uuid4().hex
        stop = asyncio.Event()
        with patch.object(Engine, "request", observed), contextlib.redirect_stdout(io.StringIO()):
            service = asyncio.create_task(serve(str(home), socket, epoch, stop))
            process = None
            try:
                for _ in range(500):
                    if os.path.exists(socket):
                        break
                    if service.done():
                        await service
                    await asyncio.sleep(.01)
                if not os.path.exists(socket):
                    raise RuntimeError("view matrix service did not bind within fixture bound")
                environment = dict(os.environ, FM_HOME=str(home), FM_VIEW_SOCKET=socket, FM_VIEW_EPOCH=epoch)
                # Inherit stdout exactly. Piping it here would make a failed
                # wrapper write occur AFTER the shell owner committed a cursor.
                process = await asyncio.create_subprocess_exec(
                    "bash", str(ROOT / "bin" / command), *arguments, env=environment,
                    stderr=asyncio.subprocess.PIPE)
                _, error = await asyncio.wait_for(process.communicate(), 120)
                refusals = [line for line in error.split(b"\n") if line.startswith(b"fm-view-client:")]
                unexpected = [line for line in refusals if not admitted(line)]
                # A failed native RPC must also reach the compatibility owner
                # as an explicit refusal, never disappear behind green output.
                failed = [row for row in requests if not row["ok"]]
                if unexpected or (failed and not refusals):
                    outcome = "unexpected-refusal"
                elif refusals:
                    outcome = "legacy"
                elif any(row["ok"] for row in requests):
                    outcome = "native"
                else:
                    outcome = "not-requested"
                detail = json.dumps({"command": command, "requests": requests,
                                     "refusals": [line.decode("utf-8", "replace") for line in refusals],
                                     "shell_exit": process.returncode}, sort_keys=True)
                record(root, str(home.relative_to(root)), outcome, detail)
                sys.stderr.buffer.write(error)
                if outcome == "unexpected-refusal":
                    print("native view matrix: unexpected refusal (not an admitted legacy integration)", file=sys.stderr)
                    return 1
                return process.returncode if process.returncode >= 0 else 128 - process.returncode
            finally:
                if process is not None and process.returncode is None:
                    process.kill()
                    await process.communicate()
                stop.set()
                await asyncio.wait_for(service, 5)


def main(arguments):
    root = Path(os.environ["FM_VIEW_COMPAT_MATRIX_ROOT"]).resolve(strict=True)
    if arguments == ["--summary"]:
        counts, reasons, verbs = {}, {}, {}
        for path in sorted((root / ".view-matrix-metrics").glob("*.json")):
            row = json.loads(path.read_text())
            outcome = row["outcome"]
            counts[outcome] = counts.get(outcome, 0) + 1
            detail = json.loads(row["detail"])
            for request in detail["requests"]:
                label = request["verb"] + (":native" if request["ok"] else ":refused")
                verbs[label] = verbs.get(label, 0) + 1
            for reason in detail["refusals"]:
                reasons[reason] = reasons.get(reason, 0) + 1
        print("native view matrix: " + json.dumps({"counts": counts, "requests": verbs,
                                                    "legacy_or_refusal_reasons": reasons}, sort_keys=True))
        return 0 if counts.get("native", 0) and not counts.get("unexpected-refusal", 0) else 1
    if not arguments or arguments[0] not in COMMANDS:
        raise ValueError("view matrix requires its declared executable selector")
    command = COMMANDS[arguments[0]]
    selected = os.environ.get("FM_STATE_OVERRIDE") if arguments[0] == "drain" else None
    home = Path(selected).resolve(strict=True).parent if selected else Path(os.environ["FM_HOME"]).resolve(strict=True)
    home.relative_to(root)
    if home == root or (selected and Path(selected).resolve().name != "state"):
        raise ValueError("view matrix requires an isolated suite-owned case home")
    return asyncio.run(invoke(root, home, command, arguments[1:]))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, KeyError, ValueError, RuntimeError, asyncio.TimeoutError) as error:
        print("native view matrix: " + str(error), file=sys.stderr)
        sys.exit(1)
