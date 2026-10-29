# Safe Claude Code updates

`bin/fm-claude-update.sh` keeps Claude Code current on this laptop without ever replacing the working copy in place.
Each release is installed into its own folder, verified there, and only then made live through one symlink rename, with the previous version kept for an instant rollback.
The agent procedure is the `claude-update` skill; the script's header owns the exact commands, settings and exit codes.

## Why not `npm install --global` in place

The old daily job ran `npm install --global @anthropic-ai/claude-code` over the live install.
The package's `bin/claude.exe` is a small stub until the package's postinstall script copies the native binary from the optional dependency `@anthropic-ai/claude-code-<platform>` over it.
When that native package is not fetched, or the script does not run, the install still reports success and leaves the stub, so every new Claude session fails until someone repairs it by hand.
npm 11 also documents unreviewed dependency install scripts as skipped by default, so relying on them running unannounced is fragile.
An in-place install also overwrites the only working copy, so there is nothing to go back to.

## Design

- One npm `--global` prefix per version under `~/.local/share/claude-code/versions/<version>/`.
- `current` and `previous` are relative symlinks to two of those folders; `current/bin/claude` is the stable path to run.
- An install goes into `staging/`, runs with `--allow-scripts=@anthropic-ai/claude-code --foreground-scripts --include=optional`, and keeps its full verbose npm output in the version's `.fm-claude-update/install.log`, where a dropped optional package shows as `reify failed optional dependency`.
- npm reports success even when the optional native package's download failed, and on this laptop's WSL network a large download can fail its TLS check mid-stream, so an attempt that fails or leaves the stub is rerun into the same folder, up to five attempts (`FM_CLAUDE_UPDATE_INSTALL_TRIES`), before the install fails.
- Verification requires `bin/claude` to resolve to a regular executable inside the version folder, at least 50 MB (the stub is under 4 KB), whose `--version` prints exactly the version installed.
- Only a verified folder is renamed into `versions/`, and only then is `previous` pointed at the old version and `current` at the new one, each by one atomic rename.
- `current` is verified again after the switch and switched back if that fails.
- A failed install, stub or wrong version moves to `failed/` with its log and reason, leaves `current` and `previous` untouched, and raises the alarm.
- Runs take a lock, run at `nice 19` and `ionice -c3`, and refuse when under 2 GiB is free.
- Versions other than `current` and `previous` are pruned down to three kept versions; the newest three failed folders are kept.

## Release age

The timer installs the newest release at or below the `latest` dist-tag that is at least 24 hours old (`FM_CLAUDE_UPDATE_MIN_AGE_HOURS`).
Releases often arrive more than once a day and a broken one is usually superseded within hours, while a release a day old has had time for its platform packages to publish and for breakage to surface.
The lag keeps this laptop within about a day of upstream fixes.
`install VERSION` ignores the age when a specific release is needed sooner.
The timer never downgrades below the live version.

## Rollback

`fm-claude-update.sh rollback` verifies the previous version and swaps it back in one rename.
The version rolled back from is added to `~/.local/state/claude-update/skipped-versions` so the timer does not take it again; delete its line, or run `install VERSION`, to allow it again.

## Alerts

Every event is one plain line in `~/.local/state/claude-update/log`.
A failure writes the standing alarm to `~/.local/state/claude-update/alarm`, naming what failed, the evidence path, that live Claude is unchanged, and what to do next.
`fm-claude-update.sh arm` registers the `check` subcommand as a custom watcher check in the main Firstmate home, so a new alarm wakes firstmate, a standing one repeats every 6 hours, a cleared one is reported once, and no healthy run within 50 hours is reported as stale.

## Install on this laptop

- The user timer `claude-update.timer` runs `claude-update.service` daily at 05:30 with `Persistent=true`.
- The service runs `~/Tools/firstmate/bin/fm-claude-update.sh run`, which follows the green pointer.
- `~/.local/npm/bin/claude`, the path the `~/.local/bin/claude` launcher and other callers run, is a symlink to `~/.local/share/claude-code/current/bin/claude`.
- The old global npm package stays installed under `~/.local/npm/lib/node_modules/` as a last-resort fallback that only a hand-made link change would use.
- `fm-claude-update.sh status` shows the live and previous versions, the last healthy run and any standing alarm.
