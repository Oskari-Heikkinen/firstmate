#!/usr/bin/env bash
# Render a receipt-derived resume packet, without rewriting intent or state.
# Usage: fm-resume-packet.sh --manifest FILE [--snapshot FILE] [--json]
# bin/fm-current-view.py --help owns the manifest/reference and projection schema.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-current-view.py" resume "$@"
