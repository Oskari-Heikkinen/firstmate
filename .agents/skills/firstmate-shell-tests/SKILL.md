---
name: firstmate-shell-tests
description: Load first, before reading the code, whenever you will write or change a test under tests/ (including extending an existing test file) or a shell script or library under bin/ in the Firstmate repository (including a new helper, passing data to jq or another tool, or porting to stock macOS bash 3.2), and before fixing a flaky, timing-dependent, load-dependent or CI-only failure there (a broken-pipe line, exit 141, "Argument list too long", a ShellCheck SC1091 or out-of-memory lint). Holds the traps test and script authors keep meeting again - waits on the observable condition rather than a fixed sleep, a hermetic fixture world, the bash 3.2 and BSD denylist, SIGPIPE on early-exit readers, argv and socket-path limits, one ShellCheck source directive per library, the assert helpers' fixed-string semantics, and the tier line for a new test. Use it even for a one-line test fix or a small helper.
user-invocable: false
metadata:
  internal: true
---

# firstmate-shell-tests

Why this skill exists: the shell and timing traps below were recorded only in the commits that fixed them, so each new test or helper met them again (root cause R1); and a written wait rule kept failing under load because nothing at the edit site applied it (R3).
Each trap here was fixed several times in different files; [`references/history.md`](references/history.md) lists the fixing commits by hash.

`CONTRIBUTING.md` "Testing" owns the shared test helpers, the tiers and the timeout and wait rule; this skill points at them rather than restating them.
`builder-self-check` owns the pre-handoff checks (counterfactuals, adversarial inputs, exact-head evidence), and `tool-design` owns how a tool's alarms and reads behave.

## 1. Wait on the condition, not on time

A test waits for the observable condition its assertion reads - a receipt file, a beacon, a status or log line, a process exit - and never for a fixed sleep or a fixed window.
The wall-clock cap on that wait is only a hang guard, set far above what the work costs on a loaded CI runner, and `CONTRIBUTING.md` "Testing" owns the exact rule for shortened production timeouts.
Tests are usually written on an idle machine, where a fork, exec, lock or beacon takes no visible time; a loaded runner stretches all of them, which is why a sized window passes locally and flakes in CI.
Read a receipt only after the wait for its existence has ended, and never assert on a file the code under test may still be writing.

## 2. Control the clock

Where the code under test reads the time, inject it through the script's own override (the `FM_*_NOW` variables, or the clock seam its header documents) rather than racing the wall clock across processes.
Two processes that each read `date` cannot agree on a boundary under load.

## 3. Build a hermetic world

- Source `tests/lib.sh` and use its temp roots (`fm_test_tmproot`), so cleanup and orphan reaping are shared.
- Use `tests/git-config-helpers.sh` (already sourced by `tests/lib.sh`) so fixture Git ignores the host's global and system config and any inherited `GIT_DIR`.
- Give each case its own `FM_HOME`, state directory and fake toolchain from `tests/fixtures.sh`, and scrub inherited `FM_*`, `HOME` and `PATH` pieces the case does not set on purpose.
- Keep every case safe to run alongside others in a pool: no fixed ports, no shared temp names, no live lane, home or state.
- A fixture that simulates a missing tool uses `fm_test_base_path_sans`, because the host may have the real binary on its base `PATH`.

## 4. Stock bash 3.2 and BSD userland

Everything under `bin/` must run on stock macOS bash 3.2 and BSD tools; CI checks only a hand-picked set of regressions there, once a week, so a break lands first and is found days later.
Avoid these, or use the replacement:

| Avoid | Use instead |
|---|---|
| `${x@Q}`, `${x,,}`, `${x^^}` | `printf '%q'`, `tr` |
| `declare -A` | parallel indexed arrays or a lookup function |
| `mapfile` / `readarray` | a `while IFS= read -r` loop |
| bare `$BASHPID` | `${BASHPID:-$(exec sh -c 'printf "%s\n" "$PPID"')}`, as `bin/fm-wake-lib.sh` does; `$$` names the parent shell inside every subshell |
| `"${arr[@]}"` on a possibly empty array under `set -u` | `${arr[@]+"${arr[@]}"}` |
| `grep -Z`, `grep -P` | NUL handling outside grep, `grep -E` |
| `stat -c` alone | try BSD `stat -f` and GNU `stat -c` both, or read what you need another way |
| `date -d` | `date +%s` and arithmetic on epoch seconds |
| `readlink -f` | `cd -P` in a subshell and `pwd -P` |
| `sed -i` without a suffix | `sed -i.bak` and remove the backup, or write a temp file |
| signal-sensitive work inside `$()` | run it in the foreground; bash 3.2 defers TERM while a command substitution runs |
| `&` in a `${var//pat/rep}` replacement | quote the replacement; bash 5.2's `patsub_replacement` expands `&` |

Run production-library tests and anything that sources `bin/` under `bash` explicitly, never the tool shell's default interpreter.

## 5. Pipes and stderr

- Never return early from a loop that reads a pipe or process substitution whose writer is still running: GitHub runners start processes with SIGPIPE ignored, so the writer prints a broken-pipe error that only CI sees.
  Capture the output first (a variable or here-string) and read that.
- Wrap a file redirection whose target may be missing as `{ cmd <"$f"; } 2>/dev/null`, because the redirection error prints before the command's own `2>/dev/null` applies.
- Keep a helper's stderr empty on every non-failure path, and print a repeated diagnostic once, not once per tick; callers capture stderr and tests assert single diagnostic lines.

## 6. Size limits

- Pass any document that grows with the fleet (backlog, task, status or store JSON) through a file or stdin - `jq --slurpfile`, `--rawfile` or a pipe - never through argv, which the kernel caps per argument at 128 KiB.
- Build socket and doorbell paths from a short fixed root, not from the home path, because Unix socket paths cap near 104 bytes.

## 7. Lint

- Add a `# shellcheck source=` directive only for a library the file does not already reach through another sourced library: each directive re-expands that library's whole source closure, and duplicates have run lint out of memory locally and in CI.
- Run `bin/fm-lint.sh` on the touched files; its header owns the lint definition and why local runs split the passes.

## 8. Assertions

- `assert_grep` and `assert_no_grep` in `tests/lib.sh` are fixed-string matches, and `assert_contains` and `assert_not_contains` match substrings; use them for literal output, and never a bare `grep` whose pattern holds regex metacharacters.
- Assert behavior through an executable or public interface, never the implementation's source bytes (`firstmate-coding-guidelines` owns that rule).

## 9. A new test file

A new `tests/<subject>.test.sh` needs its tier line in `tests/tiers.list` before CI passes; keep slow, live or load-heavy cases out of the gate tier, so the per-push gate stays fast.
A test that needs a real optional backend or an opt-in skips itself and prints the gate that enables it.
