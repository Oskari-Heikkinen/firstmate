#!/usr/bin/env bash
# fm-data-gate-report.sh - daily one-screen report of the data gate's measurements.
#
# Usage: fm-data-gate-report.sh [--date YYYY-MM-DD | --today] [--no-write]
#                               [--baseline FILE] [--digest-window-min N]
#
# Reads, one streaming pass each, for the local calendar day (default:
# yesterday, so a timer shortly after midnight reports the finished day):
#   ~/.local/state/lattice-data-gate/reads.jsonl      agent file reads (bin/fm-data-gate.sh)
#   ~/.local/state/lattice-data-gate/decisions.jsonl  gate decisions, grouped by their
#                                                     `rule` field (absent means scan)
#   ~/.local/state/lattice-data-gate/samples.jsonl    PSI, disk used and disk IO counters
#                                                     (~/.local/bin/fm-io-sample)
# and writes ~/.local/state/lattice-data-gate/reports/<date>.md, then prints
# exactly one relay line on stdout: bytes read by agents, the largest read,
# scan and size would-blocks and blocks, whole-file reads over 200 MB, the
# DIGEST.md hit rate, disk growth and IO pressure, and the transcript
# baseline's headline when --baseline (default
# $FM_HOME/data/fm-read-baseline/report.md, else ~/Tools/firstmate/...) exists.
#
# A DIGEST.md read is a miss when the same session (else task, else cwd) reads
# a file over 10 MB in the same folder within --digest-window-min minutes
# (default 30); otherwise it is a hit.
# --no-write prints the relay line without writing the report file.
# Missing inputs count as empty. Exit 1 on a bad argument.
# bin/fm-data-gate-reads.mjs owns the computation; docs/data-gate.md owns the contract.
set -u
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d'; exit 0 ;;
esac
command -v node >/dev/null 2>&1 || { echo "fm-data-gate-report: node is required" >&2; exit 1; }
exec nice -n 19 node "$HERE/fm-data-gate-reads.mjs" report "$@"
