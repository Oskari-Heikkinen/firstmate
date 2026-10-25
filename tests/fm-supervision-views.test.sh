#!/usr/bin/env bash
# Isolated native fold/IPC/admission foundation tests; no live home or backend.
# The full P1 current-state/drain/snapshot migration is NOT certified by this test.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || { fail 'Python 3.9+ required for view-engine tests'; exit 1; }
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/fixtures/supervision-views/check.py"
