#!/usr/bin/env python3
"""fm-view-lifecycle.py - inspect reader-first lifecycle contracts, no effects.

Usage:
  fm-view-lifecycle.py candidate --home DIR --owner ID --inbox DIR --outbox DIR --policy FILE
  fm-view-lifecycle.py request --home DIR --fragment FILE --input FILE
  fm-view-lifecycle.py owner --input FILE
  fm-view-lifecycle.py receipt --home DIR --fragment FILE --input FILE --state STATE --seq N [--code CODE]

All inputs are bounded owned single-link mode-0600 regular JSON files. Policy
contains exactly bounds (accepted/waiting/held durations), retry_limit and the
protocol cleanup object defined by docs/handoff-coverage.md. Candidate emits a
PLANNED fragment; it does not publish it. Request/owner emit validated structural
observations, NOT readiness or signal authority. Receipt emits a candidate
handoff-receipt/v1, NOT a committed outcome; a caller must validate and persist
it before effects and consume every refusal through its existing wake path.

No command creates a root, writes a record, installs an actor, starts/stops a
service, sends a signal or changes a home's read selection. These commands
cannot complete the unfinished foreground owner's live identity/effect gates.
Exit: 0 complete JSON on stdout; 1 refusal on stderr/empty stdout; 2 usage.
"""
import argparse
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from fm_view_bundle import directory
from fm_view_lifecycle import candidate, owner_record, read_json, receipt, request_record


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    draft = commands.add_parser("candidate")
    for flag in ("home", "owner", "inbox", "outbox", "policy"):
        draft.add_argument("--" + flag, required=True)
    for operation in ("request", "receipt", "owner"):
        command = commands.add_parser(operation)
        command.add_argument("--input", required=True)
        if operation != "owner":
            command.add_argument("--home", required=True)
            command.add_argument("--fragment", required=True)
        if operation == "receipt":
            command.add_argument("--state", required=True)
            command.add_argument("--seq", required=True, type=int)
            command.add_argument("--code")
    args = parser.parse_args(argv)
    try:
        if args.command == "candidate":
            result = candidate(args.home, args.owner, args.inbox, args.outbox, read_json(args.policy))
        elif args.command == "owner":
            result = {"structurally_valid": True, "authority": False, "owner": owner_record(read_json(args.input))}
        else:
            home, _ = directory(Path(args.home))
            fragment, request = read_json(args.fragment), read_json(args.input)
            if args.command == "request":
                result = {"structurally_valid": True, "authority": False,
                          "request": request_record(request, fragment, home)}
            else:
                result = receipt(request, fragment, home, args.state, args.seq, args.code)
        output = json.dumps(result, sort_keys=True, ensure_ascii=True, allow_nan=False) + "\n"
    except (OSError, ValueError, TypeError, KeyError, RecursionError, OverflowError) as exc:
        print("fm-view-lifecycle: refused: " + str(exc), file=sys.stderr)
        return 1
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
