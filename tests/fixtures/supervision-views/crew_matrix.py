"""CI-only native client for the existing complete crew-state behavior matrix.

Invoked only by the suite-generated absolute-interpreter wrapper. Every service
is scoped to one suite-owned case home and one request, with fake external tools
from that case. No endpoint discovery, production service or installed actor.
Unsupported integrations explicitly retain the original legacy executable; an
unexpected refusal fails rather than quietly converting the matrix to legacy.
"""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "bin"))
from fm_view_engine import serve

LEGACY = str(ROOT / "bin/fm-crew-state.sh")
CLIENT = str(ROOT / "bin/fm-view-client.py")


def record(root, task, outcome, detail=""):
    # Distinct per-invocation files avoid a shared append/lock across case jobs.
    name = root / ".view-matrix-metrics" / (uuid.uuid4().hex + ".json")
    with name.open("x") as stream:
        json.dump({"task": task, "outcome": outcome, "detail": detail}, stream)


def allowed_refusal(error):
    prefix = b"fm-view-client: read refused; use legacy: "
    if not error.startswith(prefix):
        return False
    reason = error[len(prefix):].decode("utf-8", "replace").strip()
    return reason in (
        "captured crew inputs require legacy", "custom classifier/input reader requires legacy",
        "nonstandard input root requires legacy",
        "service refused: configured no-mistakes home resolver requires legacy",
        "service refused: passive adapter bound unsupported; use legacy",
        "service refused: custom ERE classification remains with legacy",
        "service refused: relative worktree spelling remains with legacy",
        "service refused: remote endpoint observation remains with legacy owner",
    ) or re.fullmatch(r"service refused: passive (backend|saved-custody|done-proof|forge) integration unsupported; use legacy", reason) is not None


async def candidate(home, arguments, environment):
    with tempfile.TemporaryDirectory(prefix=".view-matrix-", dir=home) as temporary:
        os.chmod(temporary, 0o700)
        path = str(Path(temporary) / "read.sock")
        epoch = uuid.uuid4().hex
        stop = asyncio.Event()
        # serve's readiness JSON is not part of the crew-state CLI's stdout.
        with contextlib.redirect_stdout(io.StringIO()):
            service = asyncio.create_task(serve(str(home), path, epoch, stop))
            process = None
            try:
                for _ in range(500):
                    if os.path.exists(path):
                        break
                    if service.done():
                        await service
                    await asyncio.sleep(.01)
                if not os.path.exists(path):
                    raise RuntimeError("native matrix service did not bind within fixture bound")
                env = dict(environment, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / "state"),
                           FM_VIEW_SOCKET=path, FM_VIEW_EPOCH=epoch)
                process = await asyncio.create_subprocess_exec(
                    sys.executable, CLIENT, "crew-state", *arguments, env=env,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                output, error = await asyncio.wait_for(process.communicate(), 40)
                return process.returncode, output, error
            finally:
                if process is not None and process.returncode is None:
                    process.kill()
                    await process.communicate()
                stop.set()
                await asyncio.wait_for(service, 5)


def main(arguments):
    root = Path(os.environ["FM_VIEW_MATRIX_ROOT"]).resolve(strict=True)
    if arguments == ["--summary"]:
        counts, reasons = {}, {}
        for path in sorted((root / ".view-matrix-metrics").glob("*.json")):
            row = json.loads(path.read_text())
            outcome = row["outcome"]
            counts[outcome] = counts.get(outcome, 0) + 1
            if outcome != "native":
                reasons[row["detail"]] = reasons.get(row["detail"], 0) + 1
        print("native crew matrix: " + json.dumps({"counts": counts, "legacy_or_refusal_reasons": reasons}, sort_keys=True))
        return 0 if counts.get("native", 0) > 0 and counts.get("unexpected-refusal", 0) == 0 else 1
    if not arguments:
        # Preserve the original CLI usage case without accessing any home.
        return subprocess.call(["bash", LEGACY])
    selected = os.environ.get("FM_STATE_OVERRIDE", "")
    if not selected:
        raise ValueError("matrix invocation requires its suite-owned explicit state root")
    state = Path(selected).resolve(strict=True)
    home = state.parent
    home.relative_to(root)  # refuse anything outside this suite's own temporary tree
    if state.name != "state" or home == root:
        raise ValueError("matrix state is not an isolated case home")
    original = dict(os.environ)
    original.pop("FM_VIEW_SOCKET", None)
    original.pop("FM_VIEW_EPOCH", None)
    if original.get("FM_VIEW_MATRIX_LEGACY_READER") == "1":
        # Only the legacy subprocess reader executes the case's fake Python.
        # Native SQLite contention has its own real-input parity regression;
        # do not claim this interpreter-injection seam as native coverage.
        record(root, arguments[0], "legacy", "explicit legacy interpreter-timeout seam")
        return subprocess.call(["bash", LEGACY, *arguments], env=original)
    if not shutil.which("python3"):
        # The public compatibility entrypoint cannot select a client without
        # an interpreter; keep the no-optional-reader matrix cases unchanged.
        record(root, arguments[0], "legacy", "missing client interpreter")
        return subprocess.call(["bash", LEGACY, *arguments], env=original)
    code, output, error = asyncio.run(candidate(home, arguments, original))
    if code == 0:
        record(root, arguments[0], "native")
        sys.stdout.buffer.write(output)
        sys.stderr.buffer.write(error)
        return 0
    if not output and code == 1 and allowed_refusal(error):
        record(root, arguments[0], "legacy", error.decode("utf-8", "replace").strip())
        sys.stderr.buffer.write(error)
        return subprocess.call(["bash", LEGACY, *arguments], env=original)
    record(root, arguments[0], "unexpected-refusal", error.decode("utf-8", "replace")[:1000])
    sys.stderr.buffer.write(error)
    print("native crew matrix: unexpected refusal (not an admitted legacy integration)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError, asyncio.TimeoutError) as error:
        print("native crew matrix: " + str(error), file=sys.stderr)
        sys.exit(1)
