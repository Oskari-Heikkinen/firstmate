#!/usr/bin/env bash
# Isolated native fold/crew-state/captured-presentation/IPC/admission tests,
# including missing-SQLite unknowns and real SQLite contention/recovery parity;
# plus real drain/client stdout/cursor/fallback transaction checks.
# Queued annotations consume the same captured span as the fold, preserve byte
# rendering and append boundaries, and never reopen its cursor/span readers.
# Malformed client annotation groups fall back before native selection.
# Explicit native drains batch strong Linux snapshot identities in one stat;
# whole-byte legacy parity covers weak birth times, rotation, parent bindings,
# atomic malformed/deleted/symlink recapture and complete real-client output.
# The existing shell commit owner joins fresh strong proofs/cursors once after
# stdout; per-row tripwires and whole manifests cover backstop/growth parity,
# mutation refusal and full legacy fallback on a corrupt commit-time capture.
# Fresh annotation-time historical signatures share their owner's parser/encoder;
# late append/marker-update races and complete-filter fallback match legacy.
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
# Whole home-summary JSON and the atomic published ledger match legacy on a
# pinned wall timestamp; native publication timeout preserves the prior complete
# ledger and owed trigger, then a fresh retry publishes the updated decision.
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
# Independently exercise the ordinary legacy transaction with the optional
# batch reader forbidden; native matrix success must not change its selection.
if bash -s -- "$ROOT" <<'SH'
set -u
. "$1/bin/fm-classify-lib.sh"
home=$(mktemp -d) || exit 1
trap 'rm -rf -- "$home"' EXIT
mkdir "$home/state" || exit 1
printf 'note: legacy commit\n' > "$home/state/task.status"
snapshot=$(status_presentation_snapshot "$home/state") || exit 1
ident=${snapshot##*$'\t'}
endpoint=${snapshot#*$'\t'}; endpoint=${endpoint%%$'\t'*}
status_presentation_snapshot_batch() { echo 'unexpected legacy commit batch' >&2; return 85; }
status_commit_presentation_snapshot "$home/state" "$snapshot" || exit 1
expected=$(printf 'task\t%s\t%s\t0' "$ident" "$endpoint")
actual=$(cat "$home/state/.status-presentation-cursor") || exit 1
[ "$actual" = "$expected" ]
SH
then
  pass 'ordinary legacy presentation commit never selects the optional batch'
else
  printf 'not ok - ordinary legacy presentation commit selection\n' >&2
  rc=1
fi
# A separate public legacy renderer probe must not become an optional-batch
# test accidentally; both missing and matching reported markers keep their owner.
if bash -s -- "$ROOT" <<'SH'
set -u
. "$1/bin/fm-wake-lib.sh"
_fm_wake_require_classify || exit 1
home=$(mktemp -d) || exit 1
trap 'rm -rf -- "$home"' EXIT
STATE="$home/state"
mkdir "$STATE" || exit 1
printf 'working: legacy annotation\n' > "$STATE/task.status"
snapshot=$(status_presentation_snapshot "$STATE") || exit 1
rows=$(printf '100\t1\tsignal\ttask.turn-ended\tsignal: historical\n')
status_observed_signatures_batch() { : > "$home/unexpected-batch"; return 85; }
actual=$(fm_wake_print_annotations "$rows" "$snapshot") || exit 1
[ "$actual" = 'wake annotation: latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: task.status: working: legacy annotation' ] || exit 1
fm_wake_status_mark_current "$STATE" "$STATE/task.status" || exit 1
actual=$(fm_wake_print_annotations "$rows" "$snapshot") || exit 1
[ -z "$actual" ] && [ ! -e "$home/unexpected-batch" ]
SH
then
  pass 'ordinary legacy annotations retain reported-marker checks without the optional batch'
else
  printf 'not ok - ordinary legacy annotation selection\n' >&2
  rc=1
fi
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/fixtures/supervision-views/check.py" || rc=1
FM_VIEW_CREW_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-crew-state.test.sh" || rc=1
FM_VIEW_COMPAT_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-fleet-snapshot-view.test.sh" || rc=1
FM_VIEW_COMPAT_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-wake-drain-open-decisions.test.sh" || rc=1
FM_VIEW_COMPAT_MATRIX=1 PYTHONDONTWRITEBYTECODE=1 bash "$ROOT/tests/fm-wake-queue.test.sh" || rc=1
exit "$rc"
