# Fleet board

The fleet board is a local, read-only page that shows where the fleet stands and where it is blind, with no agent in the loop.
[`bin/fm-board.sh`](../bin/fm-board.sh) builds it and its header owns usage; [`bin/fm-board.py`](../bin/fm-board.py) owns the item shape, panels and blind-spot rules; [`bin/fm_board_tokens.py`](../bin/fm_board_tokens.py) owns the token reader.

## Building and viewing

Run `bin/fm-board.sh` in a home, or pass `--home DIR`; the home defaults to `FM_HOME`.
The page is `<home>/state/board/index.html`, a static file with no scripts that reloads itself every five minutes and follows the system light or dark theme.
`<home>/state/board/board.json` holds the same items for other readers.
A build runs under `nice -n 19 ionice -c3` and stops at 60 seconds; a build that stops early leaves the previous page in place.

`bin/fm-board.sh install-timer` writes a systemd user service and timer that rebuild the page every five minutes for the selected home, pinned to the code root it was run from, and enables the timer.
The service is a niced, idle-priority oneshot with a memory cap.
`bin/fm-board.sh uninstall-timer` disables the timer and removes both units.

## What it reads

The board reads published summaries only, never raw status logs, watcher internals or backlog markdown.

- Main plus every local home in main's `data/secondmates.md`, each through its `state/home-summary.json`; a remote home is shown as not read.
- Each home's `state/spawn-starts.jsonl`, written by every spawn and kept through cleanup, to tell which task ran in a reused working copy.
- Project feeds, detector thresholds, session roots and scheduled units listed in `config/board-feeds` (docs/configuration.md "Fleet board feeds").
- Claude Code session records in the named session roots, one folder level at a time, never recursively.

Each source has a five-second limit.
A source that is missing, stale, unreadable or of an unknown version becomes a blind-spot line on the Health panel naming the source and its owner.
Facts no owner publishes yet (why a spawn was refused, which heavy job holds the shared slot, status text volume) are listed as blind spots rather than guessed.

## Panels

- **Decisions**: calls waiting on the captain, answered calls whose mirror is still open, questions between areas, and calls parked on purpose until their date.
  A captain call mirrored up from a second mate is judged by that second mate's own summary, so it is counted once.
- **Health**: each area's monitoring verdict, incomplete summaries, stopped second mates, scheduled jobs, the merge train and blind spots.
- **Work**: per area, what is working, idle, parked with no agent, or finished with its tab still open, and every task whose last word is "working" with no agent.
- **Pipeline**: owner feeds such as the hypothesis register, the job queue and the merge train, plus queued work per area.
- **Waste**: habits where an agent does a script's job, from the token reader's rules and the work records.
- **Tokens**: today's token counts per area, kind of agent, task and agent, and the seven detector rules.

## Tokens

The reader keeps a byte cursor per session file and reads only lines appended since the last build; a replaced or shortened file is read again from the start.
Usage is counted once per message, because the parts of one multi-part turn repeat the same usage.
It stores and shows only counts, tool names, rule labels and hashes: never transcript content, command text, prompts, hosts or secrets.
It shows token counts only, never money, spend, remaining allowance, quota or run-out.
Each new message also becomes an `fm-usage.v1` row under `state/board/usage/`, which `bin/fm-usage-audit.sh --usage` reads.

Sessions are credited to a task in this order: a home root is that area's supervisor, then the latest spawn record for the same working copy that started before the session, then an `fm/<task>` branch, then the home the folder sits in, then the validation pipeline.
Sessions of tasks spawned before spawn records existed are credited to their area only.

Behavioral verification lives in `tests/fm-board.test.sh`.
