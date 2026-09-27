#!/usr/bin/env bash
# Local read-only, metadata-only usage and repetition audit.
# Usage: fm-usage-audit.sh --home DIR [--usage JSONL] [--events JSONL]
#        [--status FILE] [--scripts DIR] [--since EPOCH] [--until EPOCH]
# See --help (bin/fm-usage-audit.py) for the versioned export and classifier contract.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-usage-audit.py" "$@"
