# Local ShellCheck option A measurement

The 2026-09-05 lint-cost audit measured the seven roots from the missed-reply incident at commit `f09de8a3d3a550b13b4d535346fbc7b9ac0d6c19`:

```text
bin/fm-brief.sh
bin/fm-parent-channel-lib.sh
bin/fm-pending-reply-lib.sh
bin/fm-secondmate-report.sh
tests/fm-brief.test.sh
tests/fm-classify-corr-token.test.sh
tests/fm-pending-reply.test.sh
```

ShellCheck was the repository-pinned 0.11.0 Darwin arm64 build.
The baseline was one source-aware invocation containing all seven roots.
Option A used one process per root, omitted `--external-sources`, retained extended dataflow, and applied the local cross-file exclusion list.
Both variants were measured in the same quiet-host window:

| Variant | User + system CPU | Reduction | Worst-process RSS | Reduction |
| --- | ---: | ---: | ---: | ---: |
| source-aware baseline | 140.1 s | n/a | 8.30 GB | n/a |
| option A, per-root processes | 9.8 s | 93.0% | 0.56 GB | 93.3% |

## Reproduction

Check out the recorded commit, install the pinned binary with `bin/fm-install-shellcheck.sh`, put it first on `PATH`, and run the following on macOS.
No `--extended-analysis=false` flag is present, so dataflow remains on.
Diagnostics are discarded because only process cost is under measurement.

```bash
set -eu
[ "$(bin/fm-lint.sh --required-version)" = "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" ]
roots=(
  bin/fm-brief.sh
  bin/fm-parent-channel-lib.sh
  bin/fm-pending-reply-lib.sh
  bin/fm-secondmate-report.sh
  tests/fm-brief.test.sh
  tests/fm-classify-corr-token.test.sh
  tests/fm-pending-reply.test.sh
)
rm -rf .lint-option-a-measurement
mkdir .lint-option-a-measurement
/usr/bin/time -lp -o .lint-option-a-measurement/baseline.time \
  shellcheck --norc --external-sources -- "${roots[@]}" >/dev/null || true
index=0
for root in "${roots[@]}"; do
  index=$((index + 1))
  /usr/bin/time -lp -o ".lint-option-a-measurement/option-a.$index.time" \
    shellcheck --norc --exclude=SC1091,SC2034,SC2153,SC2329 -- "$root" \
    >/dev/null || true
done
awk '
  /^user / {cpu += $2}
  /^sys / {cpu += $2}
  /maximum resident set size/ {if ($1 > rss) rss=$1}
  /bytes allocated/ {allocated += $1}
  END {printf "cpu_seconds=%.2f worst_rss_bytes=%.0f bytes_allocated=%.0f\n", cpu, rss, allocated}
' .lint-option-a-measurement/baseline.time
awk '
  /^user / {cpu += $2}
  /^sys / {cpu += $2}
  /maximum resident set size/ {if ($1 > rss) rss=$1}
  /bytes allocated/ {allocated += $1}
  END {printf "cpu_seconds=%.2f worst_rss_bytes=%.0f bytes_allocated=%.0f\n", cpu, rss, allocated}
' .lint-option-a-measurement/option-a.*.time
```

CPU and RSS vary with host load, so percentage claims must compare runs from one measurement window.
When results must be compared across windows, use the reported `bytes_allocated` totals as the stable work proxy rather than quoting a CPU or RSS ratio.

## Local split passes

Option A alone drops every cross-file code, so local changed-file and explicit-path runs now pair it with a second cheap pass.
`bin/fm-lint.sh`'s header owns the split's definition and the finding classes it can still miss relative to CI.
The 2026-09-24 measurement ran the repository-pinned ShellCheck 0.11.0 Linux x86_64 build at commit `9296f9b9d2566797b9a9aecaa5956bb8e471d2cd` against `bin/fm-spawn.sh`, the largest source closure, one invocation at a time:

```bash
C=SC1091,SC2034,SC2153,SC2154,SC2329
/usr/bin/time -f '%e s %M KiB' shellcheck --norc --external-sources -- bin/fm-spawn.sh >/dev/null
/usr/bin/time -f '%e s %M KiB' shellcheck --norc --exclude="$C" -- bin/fm-spawn.sh >/dev/null
/usr/bin/time -f '%e s %M KiB' shellcheck --norc --external-sources --extended-analysis=false \
  --include="$C" -- bin/fm-spawn.sh >/dev/null
```

```text
32.19 s 5459328 KiB
5.53 s 1571328 KiB
8.30 s 381312 KiB
```

The first line is CI's full pass, the second is the split's dataflow pass, and the third is its source-following pass.
The split's worst process therefore needs about 29% of the full pass's peak memory, and the two passes together took about 43% of its wall time.
