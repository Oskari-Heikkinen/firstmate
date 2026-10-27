#!/usr/bin/env python3
"""fm-view-service.py - explicit foreground read-service owner, not installer.

Usage (from an already trusted, verified immutable code bundle):
  python3 -I -B <bundle>/bin/fm-view-service.py --home DIR --fragment FILE --input NAME

FILE must be this home's published, nonplanned lifecycle fragment; NAME is an
existing filename in its declared private input place. All roots must exist.
The input selects start (this process stays foreground) or pidfd-bound stop.
Start holds the SAME service singleton before ANY journal construction/admission
and through actual exit after effects; stop intake never takes that singleton.
A contended start refuses synchronously without a journal anchor or receipt.
No roots, actors, OS units, home modes, monitoring leases or recovery are
installed. Ordinary legacy read selection is unchanged.

Stdout: newline-delimited fm-view-service-result.v1 results. A start emits
ready/owner only after all gates and its completed start decision; foreground
return explicitly says exited=false (threads may still keep the process alive).
Stop emits exited=true only after actual pidfd-readable exit. Replayed terminal
decisions have fresh=false, never a new ready or effect. Refused decisions are
printed but exit nonzero. Accepted-without-completion refuses as ambiguous.
Runtime cleanup reports removed/absent/replacement-preserved per object;
capabilities and every immutable lifecycle decision remain for their owner.

The invoking owner MUST consume stdout, stderr AND process exit, and route any
refusal/failed startup/exit through its existing status/wake path. This is not
a fire-and-forget launcher or independently supervised installed actor.
Exit: 0 completed invocation; 1 refused/failed/unknown outcome; 2 usage. A start
return is not rollback proof: its observer must still witness actual exit.
"""
import argparse
from pathlib import Path
import sys

# Isolated Python ignores user/import-path environment; -B prevents pycache
# writes into immutable code. The selected tool itself must already be trusted.
if not sys.flags.isolated or not sys.dont_write_bytecode:
    print("fm-view-service: refused: use isolated Python with -I -B", file=sys.stderr)
    sys.exit(1)
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fm_view_bundle import packed  # noqa: E402
from fm_view_service import Operation, execute  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True)
    parser.add_argument("--fragment", required=True)
    parser.add_argument("--input", required=True)
    args = parser.parse_args()
    refused = False
    def emit(value):
        nonlocal refused
        refused |= value.get("receipt", {}).get("state") == "refused"
        sys.stdout.buffer.write(packed(value))
        sys.stdout.buffer.flush()
    try:
        execute(Operation(args.home, args.fragment, args.input), emit)
        return int(refused)
    except (OSError, ValueError, TypeError, KeyError, TimeoutError, RecursionError, OverflowError) as exc:
        print("fm-view-service: refused: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
