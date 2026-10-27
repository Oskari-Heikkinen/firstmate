# Fixes behind the added rules

Several rules in `../SKILL.md` were added after the same mistake was fixed more than once in different tools.
This file keeps the evidence by commit hash or issue, so a reader can see the failure each rule prevents; `git show <hash>` gives the detail.

| Rule | Section | Class | Fixes |
|---|---|---|---|
| Absent differs from present but empty, unreadable or partial | 1 | Readers took a default or a healthy verdict from an empty, unreadable or partially scanned input. | 7e11aa7f, 8fd1acdf, 73d9a02e |
| An operator override lives in a config file the tool reads | 1 | Overrides were hand-edited into generated checks or environment and were lost on the next rebuild. | 35cacd81, d085d587, 7e11aa7f |
| One alarm per occurrence, held as a level | 1 | A failure record was re-escalated on every tick instead of raised once. | 9bc051ff |
| Locks in one documented order, exec-stable ownership | 7 | Two locks taken in opposite orders, and arm ownership published before it was proven. | fd88ea0f, 886fe4d8 |
| Liveness from progress beacons, not a fixed grace window | 7 | A supervision host gave up on a live successor after a fixed window under load. | upstream issue 7791 |
| Temp files inside a per-run directory a sweep owns | 7 | Killed runs and torn-down tasks left temp files, markers, journals or wake rows in live state. | 87ebb480, b675126a, 6b0f5a07, 7e0e60a2 |
| One outcome table per vocabulary | 5 | A new passing outcome was recognized in one reader and missed in its siblings. | c5131a33, 7c8f9eec, 1a6ab4fd |
