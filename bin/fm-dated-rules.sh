#!/usr/bin/env bash
# fm-dated-rules.sh - raise a home's dated-rule alarms and look up a rule's date.
#
# Usage:
#   fm-dated-rules.sh check [--today YYYY-MM-DD]
#   fm-dated-rules.sh lookup [--json] RULE
#
# The shell entry point bin/fm-watch.sh runs as a slow check; it runs
# bin/fm-dated-rules.py, whose header owns the commands, environment and exit
# codes. docs/dated-rule-schedule.md owns the format and the alarms.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I "$SCRIPT_DIR/fm-dated-rules.py" "$@"
