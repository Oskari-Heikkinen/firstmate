---
name: claude-update
description: Load on a claude-update alarm, stale or recovered check line, when a Claude Code session fails to start after an update, and before installing, rolling back or pinning a Claude Code version.
---

# claude-update

Claude Code on this laptop is updated by `bin/fm-claude-update.sh`, which installs each release into its own folder, verifies it, and switches by one symlink rename while keeping the previous version.
[`docs/claude-update.md`](../../../docs/claude-update.md) owns the design and the install; the script's header owns the commands, settings and exit codes.

## What runs by itself

- The user timer `claude-update.timer` runs `fm-claude-update.sh run` daily at 05:30, taking the newest release that is at least 24 hours old.
- A failed run leaves the live version untouched and writes the alarm; the registered `claude-update` watcher check turns it into a `check:` wake.
- The check repeats a standing alarm every 6 hours, reports once when it clears, and reports a stale updater when no run was healthy for 50 hours.

## How agents use it

- Read the state with `fm-claude-update.sh status` and the log at `~/.local/state/claude-update/log`.
- On an alarm, open the evidence path the line names (usually a `failed/` folder's `.fm-claude-update/install.log` and `reason`) and report the cause with that path.
- A failed run needs no repair for Claude to keep working; the next daily run retries, and `fm-claude-update.sh run` retries now.
- If a newly switched version misbehaves, run `fm-claude-update.sh rollback`; it verifies the previous version first and refuses when none is kept.
- To take a specific release sooner, or again after a rollback, run `fm-claude-update.sh install VERSION`.
- To try a release without switching, run `fm-claude-update.sh stage VERSION`.

## What the lines mean

- "claude-update failed ... npm install ... exited" - npm itself failed; the install log names the npm error.
- "under the ... byte floor (a stub ...)" - the package's install step did not place the native binary on any of its attempts; `reify failed optional dependency` in the log means the platform package's download failed (on this laptop, TLS corruption on the WSL network path), and the postinstall output follows it.
- "printed '...', not VERSION" - the binary runs but is not the version installed.
- "version check failed" or "not enough room" - nothing was installed; fix the network or free space and rerun.
- "has had no healthy run since" or "no healthy run on record" - the timer is not running or keeps being skipped; check `systemctl --user status claude-update.timer` and the log.

## No longer done by hand

- `npm install --global @anthropic-ai/claude-code` over the live install: it replaces the only working copy and can leave a stub.
- Copying the native binary over `claude.exe` with `npm pack` after a broken update: roll back instead.
- Waiting on `~/.local/state/claude-update.running`: the new tool switches by rename, so a session never sees a half-installed copy.
