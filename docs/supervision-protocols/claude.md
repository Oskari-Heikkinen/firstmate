Mode: Claude Stop-hook-owned supervision.

1. The Stop hook (`bin/fm-claude-stop-autoarm.sh`) arms or attaches the one home-scoped watcher cycle at every turn end while supervision is needed; never arm it yourself, and never run `bin/fm-watch-arm.sh` after an ordinary wake.
2. A wake arrives as a `Stop hook feedback` message (`signal:`, `stale:`, `check:`, or `heartbeat`): run `bin/fm-wake-drain.sh` first and handle it; the next turn end re-arms automatically.
3. Do not invent a wake from an attach-status line alone; act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line.
4. A `firstmate watcher auto-arm FAILED ...` or `INTERRUPTED ...` notice, or a guard's repair line, says what the failure needs; follow its text and never turn it into a manual-arm loop ([`watcher-continuity.md`](../watcher-continuity.md) and [`turnend-guard.md`](../turnend-guard.md) own the mechanics).
