#!/usr/bin/env python3
# fm-view-bundle.py - prepare/verify immutable read-service code, never start it.
# Usage: fm-view-bundle.py requirements
#        fm-view-bundle.py prepare --repo ABS --commit FULL_SHA --store ABS --home ABS
#        fm-view-bundle.py verify --bundle ABS [--identity SHA256]
# Linux/Python 3.9+ only. The existing owned 0700 store must be outside any Git
# checkout and the operational home. Only pinned regular Git blobs in the fixed
# native/tmux passive dependency closure are copied (1 MiB/file, 32 MiB total).
# prepare refuses dirty tracked inputs and atomically publishes a read-only,
# content-addressed version without replacing/repairing any existing version.
# Identical existing versions are fully verified and reused. No pruning occurs.
# JSON success goes to stdout; a refusal exits 1 with a diagnostic on stderr.
# The invoking owner consumes either result and routes failures through its
# existing status/wake path. This is no service installer, actor or mode switch.
import argparse
import json
import sys

from fm_view_bundle import BundleRefused, FILES, SCHEMA, prepare, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__ or "Immutable read-service code preparation, without installation")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("requirements", help="print the fixed native/passive dependency paths")
    build = commands.add_parser("prepare", help="prepare regular blobs from a full pinned Git commit")
    for name in ("repo", "commit", "store", "home"):
        build.add_argument("--" + name, required=True)
    check = commands.add_parser("verify", help="revalidate every member of an existing immutable version")
    check.add_argument("--bundle", required=True)
    check.add_argument("--identity")
    args = parser.parse_args()
    try:
        if args.command == "requirements":
            result = {"schema": SCHEMA, "files": FILES}
        elif args.command == "prepare":
            path = prepare(args.repo, args.commit, args.store, args.home)
            result = {"schema": SCHEMA, "bundle": str(path), "identity": path.name}
        else:
            manifest = verify(args.bundle, args.identity)
            result = {"schema": SCHEMA, "identity": args.bundle.rstrip("/").rsplit("/", 1)[-1],
                      "commit": manifest["commit"], "tree": manifest["tree"], "verified": True}
        print(json.dumps(result, sort_keys=True), flush=True)
        return 0
    except (OSError, ValueError, TypeError, KeyError, BundleRefused) as exc:
        print("fm-view-bundle: refused: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
