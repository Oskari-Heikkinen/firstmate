#!/usr/bin/env bash
# Read-only disk inventory writing the KEEP / REMOVE / other-homes tables for a
# firstmate home plus the shared pools; it deletes, moves and changes nothing.
# Usage: fm-disk-inventory.sh [--home DIR] [--out FILE | --stdout] [--also-home DIR]...
#        [--pool-root DIR]... [--nm-root DIR] [--tmp-root DIR] [--idle-hours N]
#        [--du-timeout SECS] [--git-timeout SECS] [--date YYYY-MM-DD]
# See --help (bin/fm-disk-inventory.py) for every check and the output path rule.
# The whole scan runs at nice 19 and, where ionice exists, idle I/O class (-c3).
# Periodic runs are opt-in: docs/configuration.md "Disk inventory" owns the
# example user timer; nothing schedules this by default.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v ionice >/dev/null 2>&1; then
  exec nice -n 19 ionice -c3 python3 "$SCRIPT_DIR/fm-disk-inventory.py" "$@"
fi
exec nice -n 19 python3 "$SCRIPT_DIR/fm-disk-inventory.py" "$@"
