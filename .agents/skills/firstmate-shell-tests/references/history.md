# Fix history behind each trap

Each section of `../SKILL.md` was written from repeated fixes.
This file keeps the evidence by commit hash, so a reader can see the failure each rule prevents; `git show <hash>` gives the detail.

| Section | Class | Fixing commits |
|---|---|---|
| 1. Waits | Tests asserted inside wall-clock windows, read receipts before they were written, or raced fixture startup, and failed only on loaded CI runners (about 41 fixes). | a5d78f8b, 897c231d, 8d8d67e7, 57014999, 26ed1489, 940ef97f, bc5e0153, b656ee89, dd72fffa, f671d2b2; revert d14ed72f (concurrent shards) |
| 3. Hermetic world | Fixtures inherited host Git config or `GIT_DIR`, a shared `FM_HOME` or store, or a host updater, and passed or failed by machine. | eb0ea3ab, fb75c1f9, 1d59c230, 8c47279f, ef595d8d, 29213a09, 9296f9b9, 62d643c7 |
| 4. bash 3.2 and BSD | Code broke on stock macOS bash 3.2 (empty arrays under `set -u`, `${x@Q}`, deferred TERM inside `$()`, `$BASHPID`), on GNU-only `grep -Z` and `stat -c`, and on bash 5.2 `patsub_replacement` (upstream issue 7786). | 0f34fab4, 5838f105, c562be1a, e213343c, 8fd5575b, d1a332cd, 589ccec8, 98b37d40, c034b268, 329ad4ed |
| 5. Pipes and stderr | Early-exit pipe readers printed broken-pipe errors under CI's ignored SIGPIPE (the same function fixed twice), redirection errors escaped `2>/dev/null`, and diagnostics repeated per tick. | a774c448 then a8e83fda, 56cb6eb9, 87ebb480, 7c09869b, 5c958cdb, e03ff674, 5c36434c, ff3dae09 |
| 6. Size limits | Whole backlog or task JSON passed to `jq --argjson` overflowed the per-argument limit on large fleets, and socket paths grew too long under deep homes. | 31cba0db, 712f38e8 then 1a868710, 072a7da3, a452a79e, 23e55847, f93f0d3a |
| 7. Lint | Duplicate `# shellcheck source=` directives re-expanded heavy source closures until lint ran out of memory. | a29cdcef, 930792b6, 503ba82b, 3397c49c, d719ef3d, 72b63eee, a24fe663 |
| 8. Assertions | Assertions used a regex `grep` on text holding metacharacters. | 09b99b91, 56a5c3e0, 8d15cf43, cc71f715, 136ef7bf |
