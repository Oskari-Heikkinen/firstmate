#!/usr/bin/env python3
# fm-view-capabilities.py - inspect read primitives, never install/start a service.
# Usage: fm-view-capabilities.py --bundle ABS --identity SHA256 --home ABS
# Python 3.9+/Linux only. Revalidates the whole immutable bundle and requires
# its inspector/protocol bytes to match this inspector before probing local
# pidfd/nonreaping-wait and private peer-UID facilities. The store must be owned
# 0700, outside the selected operational home and every Git checkout.
# Emits one fm-view-capabilities.v1 JSON response on stdout; exits 1 and emits
# only a stderr refusal on missing/unsupported/corrupt inputs. Exit 2 is usage.
# No files/listeners/children/actors/modes are created; probes use this process
# only (signal 0, never TERM/KILL). No health or startup/stop authority is given.
# Invoking owners consume the result/refusal and route failure via their own
# status/wake path. Never persist or use this response as monitoring health.
import argparse
import json
import sys

sys.dont_write_bytecode = True

from fm_view_capabilities import inspect  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Read-only primitive preflight without installation authority")
    for name in ("bundle", "identity", "home"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    try:
        result = inspect(args.bundle, args.identity, args.home)
        print(json.dumps(result, sort_keys=True, allow_nan=False), flush=True)
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, NotImplementedError) as exc:
        print("fm-view-capabilities: refused: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
