# Data gate

The data gate is a user-level PreToolUse hook with two rules.
The scan rule stops an agent from recursively scanning bulk run data, a Firstmate home root, the user's home, or a whole drive.
The size rule stops an agent from reading one named file over the size limit (200 MiB by default) whole.
It is installed once per machine for every supported harness, so it fires in every session wherever its working directory is, including worker sessions in project worktrees that carry no project hooks of their own.
It is one layer of the data-storage plan: the bulk store's unlistable directories, ignore files, and the `lattice-data` catalog tool are the others, and none of them relies on an agent remembering a rule.

`bin/fm-data-gate.sh` is the entry point every adapter calls, and its header owns the exit and output contract.
`bin/fm-data-gate-policy.mjs` owns both decisions, and `bin/fm-data-gate-install.sh` owns installation.

## What the scan rule refuses and what it allows

The gate looks at shell commands and at the Grep and Glob tools.
In a shell command it recognizes `grep`, `egrep` and `fgrep` with `-r`, `-R`, `--recursive` or `-d recurse`, and `rg`, `ugrep`, `ug`, `ag`, `find`, `du`, `tree` and `ls -R`.
It finds them inside pipelines, `&&`, `||` and `;` chains, subshells, command substitutions, `bash -c` and `sh -c` payloads, `xargs`, and wrappers such as `sudo`, `env`, `timeout`, `nice` and `ionice`.
A `cd X` earlier in the same command moves the effective directory for the scans after it.
A scan with no explicit path targets the effective directory, except that a pathless `rg`, `ag`, `ugrep` or `ug` reading a pipe or a `<` redirect searches its input and passes.
The Grep and Glob tools always count as a scan of their `path`, or of the working directory when they have none; a Glob pattern that is absolute or starts with `~` counts as a scan of its static prefix (the part before the first glob character) instead.

Each target is resolved against the working directory (itself resolved through symlinks), with `~` and `$HOME` expanded, globs expanded one directory level at a time, and symlinks followed.
A target is refused only when it is, or is an ancestor of, one of these protected roots:

- `~/lattice-store` and its kind or bucket directories, but not one named item inside it (`items/<kind>/<item-id>/`, `quarantine/<item-id>/`);
- any Firstmate home root, and that home's `data/` root;
- any bulk directory matching a line of a home's `data/bulk-paths.txt`, matched at decision time so a bulk directory created after the roots cache was built is covered too;
- `~/lattice-ledger/search-recording` and `~/lattice-ledger/diagnostics`;
- `~`, `/`, `/mnt/c` (and so `/mnt`), and `~/.cache`.

Everything else passes, including reading an exact file, `ls` of a named folder, `grep` or `rg` inside a small named folder such as `rg foo data/<task>/`, a search inside one store item or one ledger folder, and `find` or `tree` limited to depth 0 or 1.
A scan whose target is a regular file always passes.
Over `ssh`, a remote `find` or recursive `grep` is refused when its remote target is `/`, the remote home (including no path), `/home`, `/home/<user>`, `/mnt` or `/mnt/c`; a remote `cd` earlier in the same remote command moves the directory relative targets resolve against.

`data/bulk-paths.txt` holds one path per line, relative to that `data/` or absolute, and may use globs.
The installer generates a marked block in it from the one bulk definition, `DEFAULT_BULK` in `bin/fm-data-gate-policy.mjs` (`rolling-runs-*/slices/`, `*/tetjet-results/`, `shell-contact-first-runs/runs*/`); lines outside that block are the home's own.
The same file feeds both the gate's protected set and the `.ignore` and `.rgignore` files.

Firstmate homes are discovered without any recursive scan: the main home at `~/Tools/firstmate`, every treehouse pool worktree under `~/.treehouse/*/treehouse-state.json` that carries a `.fm-secondmate-home` marker, and every `home:` in a discovered home's `data/secondmates.md`.
A task worktree in a pool is not a home, so a worker can still search its own worktree.
The result is cached in `~/.local/state/lattice-data-gate/roots.json`, which the installer refreshes and the gate itself rediscovers when it is more than six hours old.
Run `bin/fm-data-gate.sh roots` to print the effective protected roots and bulk patterns, or `bin/fm-data-gate.sh refresh` to rediscover them now.

## What the size rule refuses and what it allows

The size rule refuses a whole-file read of one named regular file larger than the limit.
It never walks a directory: each named file costs one `stat`.
A whole-file read is:

- the Read tool (Claude `Read`, OpenCode and Pi `read`) with neither an offset nor a limit;
- `cat`, `tac`, `nl`, `less`, `more`, `bat`, `grep`, `egrep`, `fgrep`, `rg`, `ag`, `ugrep`, `awk`, `sed`, `wc`, `sort`, `uniq`, `cut`, `paste`, `jq`, `diff`, `cmp`, `strings`, `base64`, the `sha*sum`, `md5sum`, `b2sum` and `cksum` checksums, `xxd`, `od`, `hexdump`, `zcat` and its siblings, `gzip`, `xz`, `zstd` or `bzip2` with `-c`, `-t` or `-l`, and `dd if=`, each on its named file operands;
- `python` or `python3` with `-c` code or a heredoc script that calls `open()` or `Path()` on a literal path;
- any command's `< FILE` stdin redirect.

The shell parsing is the scan rule's (pipelines, chains, subshells, substitutions, `bash -c`, wrappers, `cd`), plus literal `NAME=value` and `export NAME=value` assignments earlier in the same command, so `D=~/x; sed -n 1,9p $D/f` resolves.

These always pass:

- bounded reads: `head` and `tail` (also fed by `<`), the Read tool with an offset or a limit, `sed` whose script quits (`sed -n 'A,Bp;Bq'`), `xxd -l`, `od -N`, `hexdump -n`, `cmp -n`, `bat -r`, `dd` with `count=`, a Python script that seeks or reads a counted amount, and a streamer (`cat`, `tac`, `nl`, `zcat` and its siblings, `xxd`, `od`, `hexdump`, `strings`, `base64`) piped straight into `head`;
- a niced one-off read, run under both `nice -n 19` and `ionice -c3`, which is the data-access skill's last-resort procedure;
- anything that is not a regular file (directories, `/dev`, `/proc`), a missing file, and a path the gate cannot resolve (an unknown variable, a command substitution, `sys.argv`);
- commands that are not reads of the file into the agent: `cp`, `mv`, `rsync`, `tar`, `lattice-data`, `python -m`, and a script file run by path.

Our own verified jobs are not agent tool calls and are never gated here; the disk-speed cap covers them.
A path listed in `SIZE_ALLOW` in `bin/fm-data-gate-policy.mjs` passes at any size (see Adding an allow rule).

## Modes

Each rule has its own mode, read from `~/.config/lattice-data-gate/mode`:

| Rule | Environment override | Line in the mode file | Default |
| --- | --- | --- | --- |
| scan | `LATTICE_DATA_GATE` | the file's first word | `log` |
| size | `LATTICE_DATA_GATE_SIZE` | `size log` or `size enforce` | `enforce` |

`bin/fm-data-gate.sh mode` prints the scan rule's effective mode and `bin/fm-data-gate.sh mode size` the size rule's.

- `log` is the trial mode: every call is allowed, and each scan-shaped call or read of a file over the limit is recorded.
- `enforce` refuses a call that rule would block, with the message below, and still records it.

Any other value means `log`.
A rule in `log` never refuses, even while the other rule enforces.

The size limit comes from `LATTICE_DATA_GATE_SIZE_LIMIT`, otherwise a `size-limit N` line in the same file, otherwise `200M`.
`N` is bytes, or a number with `K`, `M` or `G` (binary units); an invalid value means `200M`.
`bin/fm-data-gate.sh size-limit` prints the effective limit in bytes.
For example, a mode file holding `enforce`, `size log` and `size-limit 200M` on three lines enforces the scan rule and logs the size rule at 200 MiB.

A new rule goes live the moment the Firstmate checkout the hooks call is updated, before any re-install, because every hook calls the gate by its absolute path.
So a rule that should start in `log` needs its line in the mode file before that update lands; the installer writes `size log` only into a mode file it creates.

The scan refusal names the sanctioned access path:

```
BLOCKED (data gate): recursive <tool> over <path> would scan bulk run data.
Use:  lattice-data find --task|--batch|--slice|--entry …   (catalog: ~/lattice-store/catalog.jsonl)
      lattice-data grep <item-id> PATTERN                   (search inside one item)
      ~/lattice-ledger/index.json and runs/<entry_id>.md    (run results)
See skill data-access. Override for a named small folder: search that folder directly.
```

The size refusal names the file, its size and the limit, and points at the procedure in the `data-access` skill's "Blocked large read" section, whose source is [`data-access-blocked-large-read.md`](data-access-blocked-large-read.md):

```
BLOCKED (data gate): <tool> would read all of <path> (<size> MiB; the whole-file limit is <limit> MiB).
Use:  the file's DIGEST.md or its catalog entry first         (lattice-data find …)
      a bounded window: Read with offset and limit, head -c, tail -c, sed -n 'A,Bp;Bq'
      a niced one-off read: nice -n 19 ionice -c3 <command>, recorded in your report
See skill data-access, section "Blocked large read". If none of these fits, ask main.
```

The gate never walks a directory tree, and each decision is bounded to five seconds.
When the gate itself fails (Node missing, the policy erroring or timing out, an unparseable payload), it allows the call, even in `enforce` mode, and records the error.

## The decision log

Records go to `~/.local/state/lattice-data-gate/decisions.jsonl`, one JSON object per line.
Only scan-shaped calls and reads of files over the size limit are recorded; ordinary commands and small reads never reach the log.
Each record carries `ts`, `harness`, `cwd`, `cmd`, `verdict` (what the gate did: `allow` or `block`), `would_block` (whether any rule would block under enforcement), `would_block_rules` (which: `scan`, `size`), `mode` (the scan rule's), `size_mode`, `size_limit`, and the resolved `targets`.
Each target names its `rule`; a size target also carries the file's `size` in bytes and, when it passed although over the limit, `why` (`bounded`, `niced` or `allow-rule`).
Error records carry an `error` field instead of `targets`.

While a rule runs in `log`, review its would-block lines before switching it to `enforce`, for example `grep '"would_block_rules":\["scan"' ~/.local/state/lattice-data-gate/decisions.jsonl` for the scan rule or `grep '"would_block_rules":\[[^]]*"size"' ~/.local/state/lattice-data-gate/decisions.jsonl` for the size rule.
Each false block becomes an allow rule and a test row before that rule switches to `enforce`.

## Install, status and uninstall

Run the installer from a durable Firstmate checkout, never a disposable task worktree, because every hook calls the gate by its absolute path.

```sh
bin/fm-data-gate-install.sh install --dry-run   # per-file summary, writes nothing
bin/fm-data-gate-install.sh install
bin/fm-data-gate-install.sh status
bin/fm-data-gate-install.sh uninstall
```

`install` touches only harnesses whose user config directory already exists, and merges one gate entry without disturbing existing entries.
It copies every file it changes to `~/.local/state/lattice-data-gate/backups/<timestamp>/` first, records the original bytes in `install-manifest.json` there, and prints what it did per file.
It also generates the bulk block in every discovered home's `data/bulk-paths.txt`, writes a marked block listing those bulk directories into `.ignore` and `.rgignore` in that `data/` and in `~/lattice-ledger`, writes `~/.config/lattice-data-gate/mode` as `log` plus `size log` when it is absent (an existing mode file is never edited), and refreshes the roots cache.
Re-running it changes nothing that is already current.
`uninstall` puts back the exact pre-install bytes of each file that still holds what the first `install` wrote, deletes files and directories `install` created, and removes only the gate entries from a file that changed since, including a change made between two installs; the decision log stays.

| Harness | Installed as | Covers |
| --- | --- | --- |
| Claude | PreToolUse entry matching `Bash\|Grep\|Glob\|Read` in `settings.json` of `~/.claude`, `~/.claude-work`, and every Claude login folder registered in a discovered home's `config/accounts` | Bash, Grep, Glob and Read |
| Codex | PreToolUse entry matching `Bash` in `~/.codex/hooks.json`, plus its trust entry in `~/.codex/config.toml` | shell commands |
| Grok | `~/.grok/hooks/lattice-data-gate.json`; global Grok hooks need no folder trust | shell commands |
| OpenCode | `~/.config/opencode/plugins/lattice-data-gate.js` (`tool.execute.before`) | bash, grep, glob and read |
| Pi and Pi-signed | `~/.pi/agent/extensions/lattice-data-gate.ts` (`tool_call`) | bash, grep, find and read |
| OMP | `~/.omp/agent/extensions/lattice-data-gate.ts` (`tool_call`) | bash, grep, find and read |

Codex refuses a new or changed hook until it is trusted ("Hooks need review"), and Firstmate's key plane cannot answer that review.
So the installer, run by the operator, records the trust hash for exactly the gate hook as `[hooks.state."<hooks.json>:pre_tool_use:<group>:<handler>"]` in `~/.codex/config.toml`, the same entry an interactive approval writes, and `uninstall` removes it; `status` reports whether it is present.
Known limit: Firstmate launches Codex workers and scouts with Codex's hook layer disabled, so the gate does not fire inside those sessions; the unlistable store directories still apply there.
The Claude entry stands down under Grok, which can also load Claude settings, so a Grok session is gated only by its own hook.
Cursor, Kimi, Gemini, Muse, Rovo, Antigravity and Devin get no adapter from this installer.

## Adding an allow rule

A false block is fixed in the policy, never by widening a protected root by hand in a settings file or by raising the size limit.
Add the case as an `allow` row in the matching table in `tests/fm-data-gate.test.sh`, then make the narrowest change in `bin/fm-data-gate-policy.mjs` that turns that row green without turning any `block` row red.
For the scan rule that is `classifyTarget` or the scanner parsing; for the size rule it is the reader parsing (`READERS`, what counts as bounded) or, for a file that may be read whole at any size, a path pattern in `SIZE_ALLOW`.
A folder that should become protected goes into the owning home's `data/bulk-paths.txt` outside the generated block, one path per line, relative to that `data/` or absolute; then run `bin/fm-data-gate.sh refresh` and re-run the installer so the ignore files list it too.
For a one-off search, the refusal itself names the override: search the named small folder directly instead of its parent.

## Verification

```sh
tests/fm-data-gate.test.sh
tests/fm-data-gate-install.test.sh
```

The first suite drives both rules' decision tables through a fake home: the scan table includes every read in the data-storage plan's legitimate-reads table as allowed, and the size tables replay the shapes of real recorded reads (the gate's decision log and lattice-research's S1r replay fixture) against 300 MiB sparse files and small ones.
The second runs the installer only against a temporary `HOME` and proves the dry run, idempotent re-install, byte-identical uninstall, and that each installed adapter calls the gate.
