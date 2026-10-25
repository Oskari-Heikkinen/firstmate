#!/usr/bin/env bash
# Isolated native fold/crew-state/captured-presentation/IPC/admission tests,
# including missing-SQLite unknowns and real SQLite contention/recovery parity;
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
# Native task-row snapshot composition compares complete legacy JSON rows,
# generation discard, fresh pane evidence, fixed-pool fairness and real-client
# whole-batch fallback; existing publication and dirty-trigger owners stay shell.
# Full public snapshot parity retains captured parent activity/mtime/metadata;
# malformed captures or unsafe private staging refuse before native selection.
# The existing complete crew-state behavior matrix is also executed through a
# fresh real native socket/client per isolated case request; only explicitly
# unsupported integrations may fall back, with every reason counted in output.
# Complete existing snapshot/view and drain/open-decision matrices also run
# through isolated native selection, retaining the real stdout descriptor so
# failed-output/commit assertions still exercise the transaction owner.
# Legacy persistent-cache/probe assertions are explicitly selected and counted
# separately; real-client resident growth/rotation/kind/cache-independence and
# complete over-bound/backend fallback parity cover the native boundary.
# The complete queue safety case pool also selects the native drain, retaining
# concurrent append/ack, branch/main actor exclusion and interrupted ownership.
# The full P1 current-state/drain/snapshot migration is NOT certified by this test.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v python3 >/dev/null 2>&1 || fail 'Python 3.9+ required for view-engine tests'
rc=0
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/fixtures/supervision-views/check.py" || rc=1
FM_VIEW_CREW_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-crew-state.test.sh" || rc=1
FM_VIEW_COMPAT_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-fleet-snapshot-view.test.sh" || rc=1
FM_VIEW_COMPAT_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-wake-drain-open-decisions.test.sh" || rc=1
FM_VIEW_COMPAT_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-wake-queue.test.sh" || rc=1
exit "$rc"
