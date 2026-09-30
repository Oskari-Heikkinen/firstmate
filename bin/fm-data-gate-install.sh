#!/usr/bin/env bash
# fm-data-gate-install.sh - install, remove, or inspect the user-level data gate.
#
# Usage: fm-data-gate-install.sh install|uninstall|status [--dry-run] [--gate PATH]
#
# install   Merges one gate entry into each existing harness's user-level hook
#           settings (settings.json PreToolUse Bash|Grep|Glob|Read in ~/.claude,
#           ~/.claude-work and every Claude login folder in a discovered home's
#           config/accounts; ~/.codex/hooks.json PreToolUse Bash plus its trust
#           hash in ~/.codex/config.toml) and writes global Grok, OpenCode, Pi
#           and OMP hook or plugin files, only for harnesses whose user config
#           directory exists. Existing entries are kept. It generates the bulk
#           block in every discovered home's data/bulk-paths.txt and writes a
#           marked .ignore/.rgignore block listing those bulk dirs into that
#           data/ and ~/lattice-ledger,
#           writes ~/.config/lattice-data-gate/mode as `log` plus `size log`
#           when absent (both rules log; an existing file is never edited), and
#           refreshes the roots cache. Every file it changes is copied first
#           to ~/.local/state/lattice-data-gate/backups/<timestamp>/, and the
#           original bytes are recorded in install-manifest.json there.
#           Re-running changes nothing that is already current.
# uninstall Restores each file to its exact pre-install bytes (or deletes a
#           file install created) when it still holds what the first install
#           wrote; otherwise removes only the gate entries. The decision log
#           stays.
# status    Prints the mode, the log, the roots cache, and each target's state,
#           including the Codex trust entry for the gate hook.
# --dry-run Prints the per-file summary and writes nothing.
# --gate    The gate script the hooks call; default: this checkout's
#           bin/fm-data-gate.sh. Install from a durable checkout, never from
#           a disposable task worktree.
#
# Codex re-trust: Codex refuses a new or changed hook until it is trusted
# ("Hooks need review"), which Firstmate's key plane cannot answer, so install
# records the trust hash for exactly the gate hook and uninstall removes it.
# Every target is derived from $HOME and the registries of homes under it.
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
