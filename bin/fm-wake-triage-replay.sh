#!/usr/bin/env bash
# fm-wake-triage-replay.sh - replay one UTC day's recorded main-only wake rows
# through the wake-triage contract, off the live wake path, and score the
# result against main's recorded handling.
#
# Usage:
#   fm-wake-triage-replay.sh replay --home <main home> --day <YYYY-MM-DD>
#                                   --engine claude|pi --model <id> [--effort <level>]
#                                   --settle-list <file> --out <file> [--host-log <file>]
#                                   [--probe-lag <seconds>] [--jobs <n>]
#                                   [--turn-timeout <seconds>] [--audit-fast-relay]
#                                   [--skill <file>]
#   fm-wake-triage-replay.sh score --home <main home> [--host-log <file>]
#                                  --replay <file> [--replay <file>]...
#                                  --transcript <jsonl> [--transcript <jsonl>]... --out <md>
#   fm-wake-triage-replay.sh --help
#
# The wake-triage skill (.agents/skills/wake-triage/SKILL.md) owns the row
# classes, the settle list format, the probes, the answer line and the shadow
# log line; this header owns the commands and exit codes.
#
# replay reads --host-log (default <home>/state/.supervision-host.log),
# read-only, and takes every `pass-through attended main-only` line of --day
# as one row; its seq is h<line number in that log>, because the wake queue's
# own seq is not logged. The host trims its log from the front, which
# renumbers every seq, so replay and score of an older day read a saved copy
# of the log through --host-log, the same copy for both.
# The recorded main-only verdict is the routing input: a main-only signal row
# is decision-span, and nothing is re-derived. For each row it:
#   - names the row's class (the skill's "Row classes");
#   - reads the class's probe, when the tool has a recorded reader for it, from
#     the home's state as of the row time plus --probe-lag (default 180 s, the
#     planned (D3a) relay deadline, by which a held row may be re-probed):
#     stale:stuck-busy-inbox passes only when the inbox record's handled/ copy
#     is dated by then, and its message also carries the record's first body
#     line; check:loop-alerts from state/loop-alerts/log passes when the
#     alert's last event by then is cleared or removed, or an ack from before
#     the row, while an ack after the row reads unknown, because in the
#     recording that ack is main's or the operator's handling of this wake;
#     check:rearm-resurface and any other class read unknown, because what
#     they need is not recorded; a pass records passed_at=, the epoch of the
#     event it rests on;
#   - fast-relays a row whose class is not on --settle-list by code, with no
#     engine turn (route=code, model=code);
#   - presents a listed row to one classify-only engine turn with no tools, no
#     session and no project context: the system prompt is a fixed replay
#     preamble plus the skill verbatim (its sha256 prefix is logged), and the
#     message carries the row, the settle list and the probe result;
#   - with --audit-fast-relay, also asks the engine about each code-routed row,
#     for audit only, and records its answer as audit= without changing the
#     row's action; a signal row's message then carries the status lines it
#     presented (each named status file's lines stamped after that file's
#     previous presentation in the host log, and at or before the row).
# Engines: claude runs `claude -p --safe-mode --tools "" --model <id>
# [--effort <level>]`; pi runs `pi -p --no-session --no-tools ... --model <id>
# [--thinking <level>]`; FM_WAKE_TRIAGE_CLAUDE_BIN and FM_WAKE_TRIAGE_PI_BIN
# replace the binaries. Only existing logins are used. Each turn is bounded by
# --turn-timeout (default 600 s); --jobs (default 4) turns run at once.
# A failed, timed-out or unparsable turn, one whose JSON has a shape the
# reader does not expect, one whose output raises anything else (bytes that
# are not UTF-8), or one that used a tool (claude's num_turns above 1, or a pi
# tool call), writes the row as action=relay with error=, never as a settle;
# a failed audit turn writes audit=error: and keeps the fast relay.
# tests/fm-wake-triage-replay-live-e2e.test.sh checks both real engines
# against this.
#
# --out gets one shadow log line per row, written as each row finishes and
# sorted by row time at the end; <out>.log gets one plain-language line per
# event. A rerun with the same --out skips rows already written and retries
# rows written with error= or audit=error:, so a stopped run resumes. An --out
# with a line that is not a shadow log line, one in a folder that does not
# exist, one written by a different model, or one written under a different
# effort, skill, settle list, probe lag, --audit-fast-relay or host log copy
# (each line's run= fingerprint) refuses, and so does a --day that is not
# YYYY-MM-DD. A missing, unreadable or malformed --settle-list (a line that is
# not a class token, or a class the skill always sends to main) refuses,
# naming the file and line; an empty one fast-relays every row.
#
# score reads only --host-log (--home names its default), the replay files
# and the transcripts. It refuses a replay line that is not a shadow log line,
# whose seq is not a main-only row of --host-log, or is one at another time
# (another copy of the log), and replay files that recorded different
# evidence for one row. It joins main's wake turns in the --transcript files
# to the log's rows: each head line of each turn, in time order, binds to the
# latest row whose whole headline it is, at or before the turn (5 s skew,
# within an hour), so an earlier identical row with no turn of its own stays
# unmatched. A turn is typed V (final text over 60 characters and not a
# "nothing new" reply), R (fm-send, fm-control, fm-spawn, fm-tasks add,
# fm-pack or fm-update), M (more than 2 tool calls or a mark-processed) or N,
# in that order; a row several turns hit takes the strongest type (V, R, M,
# then N), and a row with no turn is unmatched. A stale:stuck-busy-inbox row
# whose replay lines recorded a pass (its message handled by the replay's
# probe time) is typed S instead, whatever main's turn was: it cleared on its
# own, and a note that it cleared is not for the operator. M, N and S are rows
# the operator needed nothing from. A pass may be main's own doing, so it
# types no S and fails a settle, when its passed_at is after the start of a
# wake turn on the row that ran fm-send, fm-control or an fm-loop ack, or
# when any main command from a minute before the row up to passed_at, in any
# turn, sent to or controlled the stuck worker or acked the alert. It
# writes --out, answer first: the S1a exit test per model (met when every row
# of the replayed days has exactly one line, every code-routed row was
# fast-relayed, and every would-settle row had passing recorded evidence with
# a recorded pass time that main's own turn did not produce, and main
# handling M, N or S), then agreement with main's handling per model
# (agreement over matched rows, split by route, misses, needless relays and
# settles), per-run counts, main's handling per class, the engine-routed rows
# side by side and the audit counts.
#
# Both commands run at nice 19 and ionice -c3, and change nothing in --home.
#
# Output: one line, `replay: <out>: <n> row(s) for <day> (<n> fast-relay, <n>
# relay, <n> settle), <n> engine error(s) this run, <engine>/<model>, cost $<x>`,
# `score: <out>: <n> run(s) over <days>`, or `wake-triage-replay: refused:
# <reason>`.
#
# Exit codes: 0 done; 1 replay finished but at least one engine turn failed
# (triage rows are written as relay with error=, audit answers as
# audit=error:; rerun to retry them); 2 refused (usage error; an unreadable
# host log, settle list, skill, replay file or transcript; an --out from
# another model or other settings, holding a stray line or in a missing
# folder; a malformed --day; a replay line that is not a shadow log line or
# not a main-only row; replay files that disagree on evidence; or python3
# missing).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

case "${1:-}" in
  replay|score) ;;
  -h|--help|'') usage; exit 0 ;;
  *) printf 'wake-triage-replay: refused: unknown command: %s (see --help)\n' "$1"; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { printf 'wake-triage-replay: refused: python3 is not on PATH\n'; exit 2; }
low=(nice -n 19)
command -v ionice >/dev/null 2>&1 && low+=(ionice -c3)
exec "${low[@]}" python3 -I "$SCRIPT_DIR/fm-wake-triage-replay.py" "$@"
