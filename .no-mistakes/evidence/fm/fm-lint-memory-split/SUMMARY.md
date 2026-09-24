# fm-lint local split: live validation (2026-09-24, ShellCheck 0.11.0, WSL2 24 GB)

Every real ShellCheck process was run through a pass-through wrapper on PATH that logs argv and peak RSS (`/usr/bin/time -f %M`).

| Run | Mode banner | ShellCheck invocations | Peak RSS of worst process | ShellCheck wall |
|---|---|---|---|---|
| local `bin/fm-lint.sh bin/fm-spawn.sh` | local split mode | 2, sequential: `--exclude=<cross-file>` (dataflow) then `--external-sources --extended-analysis=false --include=<cross-file>` | **1,597,952 KiB (~1.5 GiB)** / 393,600 KiB | 5.5 s + 7.3 s |
| `CI=true bin/fm-lint.sh bin/fm-spawn.sh` | full extended analysis | 1: `--norc --external-sources` | **5,490,948 KiB (~5.2 GiB)** | 27.8 s |
| local no-arg (changed-file mode, 2 workers) | local split mode | 4 (2 per changed root; per worker the 2nd pass starts after the 1st ends) | 152,064 KiB | ~1.7 s |

Cross-file fixture (main.sh sources lib.sh): split and CI report the identical finding set {line6:SC2034, line8:SC2154, line11:SC2086}. There are no duplicates, and no false positives on the library-consumed var, the library-defined var, or dataflow-safe `$count`.
Exit status: a finding only in the dataflow pass → exit 1; a finding only in the cross-file pass → exit 1; a clean file → exit 0.
SIGINT/SIGTERM during the split's dataflow pass on fm-spawn.sh → exit 130/143, and 0 ShellCheck processes remain.
