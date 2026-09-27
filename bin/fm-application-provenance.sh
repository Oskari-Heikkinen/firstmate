#!/usr/bin/env bash
# Join a fleet-sync receipt with owner-supplied build/server/browser observations.
# Usage: fm-application-provenance.sh RECEIPT [--application FILE] [--max-age SECONDS]
# Read-only; bin/fm-fleet-provenance.py --help owns the input/output schema.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-fleet-provenance.py" read "$@"
