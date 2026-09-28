#!/usr/bin/env bash
# fm-data-gate-install.sh - install, remove, or inspect the user-level data gate.
#
# Usage: fm-data-gate-install.sh install|uninstall|status [--dry-run] [--gate PATH]
#
# install   Merges one gate entry into each existing harness's user-level hook
#           settings (~/.claude/settings.json and ~/.claude-work/settings.json
#           PreToolUse Bash|Grep|Glob, ~/.codex/hooks.json PreToolUse Bash) and
#           writes global Grok, OpenCode, Pi and OMP hook or plugin files, only
#           for harnesses whose user config directory exists. Existing entries
#           are kept. It writes a marked .ignore/.rgignore block listing bulk
#           dirs into every discovered home's data/ and ~/lattice-ledger,
#           writes ~/.config/lattice-data-gate/mode = log when absent, and
#           refreshes the roots cache. Every file it changes is copied first
#           to ~/.local/state/lattice-data-gate/backups/<timestamp>/, and the
#           original bytes are recorded in install-manifest.json there.
#           Re-running changes nothing that is already current.
# uninstall Restores each file to its exact pre-install bytes (or deletes a
#           file install created) when it still holds what install wrote;
#           otherwise removes only the gate entries. The decision log stays.
# status    Prints the mode, the log, the roots cache, and each target's state,
#           including whether Codex has recorded trust for the gate hook.
# --dry-run Prints the per-file summary and writes nothing.
# --gate    The gate script the hooks call; default: this checkout's
#           bin/fm-data-gate.sh. Install from a durable checkout, never from
#           a disposable task worktree.
#
# Codex re-trust: Codex refuses a new or changed hook until an operator
# approves it once ("Hooks need review") in an interactive session. This
# installer never writes Codex's trust store, because that would manufacture
# consent. Every target is derived from $HOME only.
# docs/data-gate.md owns the operator contract.
set -u
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
case "${1:-}" in
  install|uninstall|status) ;;
  -h|--help|"")
    sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d'
    [ -n "${1:-}" ]; exit $? ;;
  *) echo "fm-data-gate-install: unknown subcommand: $1 (expected install|uninstall|status)" >&2; exit 2 ;;
esac
command -v node >/dev/null 2>&1 || { echo "fm-data-gate-install: node is required" >&2; exit 1; }
exec node "$HERE/fm-data-gate-install.mjs" "$@"
