#!/usr/bin/env bash
# Isolated native fold/crew-state/captured-presentation/IPC/admission tests,
# plus real drain/client stdout/cursor/fallback transaction checks.
# Queued annotations consume the same captured span as the fold, preserve byte
# rendering and append boundaries, and never reopen its cursor/span readers.
# Malformed client annotation groups fall back before native selection.
# Native offset batching reads real owner-written cursor/marker bytes, refuses
# unmigrated legacy cursors and leaves all publication/commit authority intact.
# Real-client corrupt replies exercise observed-offset validation plus the
# independent owner-side lower bound before native selection or stdout.
# Presentation compares unread rows, decisions and suggested contiguous cursor
# endpoints to the existing shell transaction APIs; no live home or backend.
# The full P1 current-state/drain/snapshot migration is NOT certified by this test.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || fail 'Python 3.9+ required for view-engine tests'
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/fixtures/supervision-views/check.py"
