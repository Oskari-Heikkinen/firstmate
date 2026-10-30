#!/usr/bin/env bash
# fm-helper-equiv.sh - compare how two versions of a pinned helper answer one
# consumer's calls, as evidence for the reviewer of a helper update.
#
# Usage:
#   fm-helper-equiv.sh report --calls <file> --old <version> --new <version> --out <dir>
#                             [--repo <dir>] [--helper <path>] [--deadline <seconds>]
#   fm-helper-equiv.sh --help
#
# docs/helper-consumers.md ("Consumer call sets") owns the call-set format and
# what the report means; this header owns the commands and exit codes.
#
# <version> is sha256:<hex> (at least 8 hex digits of the helper's sha256,
# matched against the helper's versions in the last 2000 commits of --repo that
# touched it, newest first; an ambiguous prefix refuses) or a git revision of
# --repo (default: the current directory's checkout). --helper picks the call
# set's helper= section; it may be left out when the call set has one.
#
# report, in order:
#   - parses the call set strictly; a missing, unreadable or malformed file
#     refuses, naming the file (and the line);
#   - extracts the helper's directory at each version's commit from git into
#     a private temporary run directory, checks the helper's sha256, and makes
#     the copies read-only; it never runs a helper from a checkout or a home;
#   - for each state, runs every call against the old version, the old version
#     again, then the new one; each run gets a fresh sandbox and a fresh copy of
#     the fixture, at the same paths for every version, so the calls in one run
#     share state but runs never do; calls run under env -i with the call set's
#     environment, stdin from /dev/null, and no network when unshare --net or
#     bwrap --unshare-net works here (the report says which, or that it ran
#     with the network);
#   - after each call it records the rc, a hash of the full stdout and stderr,
#     and the state left in the sandbox and fixture (type, mode, size and
#     sha256 of each path), and keeps the first 64 KiB of each stream and the
#     state listing under <dir>/captures/, within a 32 MiB budget;
#   - writes <dir>/report.md: a header, then one table row per call, state and
#     aspect (rc, stdout, stderr, state) that differs between old and new, or
#     that is unknown: a timed-out or failed call, an unreadable state, the
#     deadline, or an old result that changed between its two runs. Identical
#     results give no row. A difference is a finding for the reviewer and an
#     unknown is never counted as equal; neither changes the exit code.
# Each call is bounded by the call set's timeout= (default 60 s) and the whole
# run by --deadline (default 900 s); calls past the deadline are unknown.
# It runs at nice 19 and ionice -c3, and the report records what took effect.
# The temporary run directory is removed when it finishes.
#
# Output: one line, `equiv: report <dir>/report.md: <helper> <old>..<new> for
# <consumer>: <n> differences, <n> unknown, network <isolated|not>`, or
# `equiv: refused: <reason>`.
#
# Exit codes: 0 the report was written, whatever it found; 2 refused (usage
# error, call set missing or malformed, version not found or ambiguous, an
# extracted helper that fails its sha256 check, an --out that exists and is not
# an empty directory, or python3 missing).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

case "${1:-}" in
  report) shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) printf 'equiv: refused: unknown command: %s (see --help)\n' "$1"; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { printf 'equiv: refused: python3 is not on PATH\n'; exit 2; }
low=(nice -n 19)
command -v ionice >/dev/null 2>&1 && low+=(ionice -c3)
exec "${low[@]}" python3 -I "$SCRIPT_DIR/fm-helper-equiv.py" "$@"
