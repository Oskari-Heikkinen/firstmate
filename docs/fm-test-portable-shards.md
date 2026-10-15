# Firstmate test tiers and CI shards

[`tests/tiers.list`](../tests/tiers.list) gives every `tests/*.test.sh` exactly one tier.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) owns tier selection, the changed-file map, shard packing, and the coverage guard; its header and `--help` own the exact flags and output fields.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) owns the executable job wiring described here.

## Tiers

The tiers follow risk: the checks every push must pass come first, and tests for features not in daily use run weekly.

| Tier | Contents | Runs |
|---|---|---|
| `static` | repository structure checks | every run, in the static job |
| `gate` | the safety core in `tests/safety-core.list`, feature smokes, and real-Herdr smokes | every push |
| `full` | the rest of the landing suite | every `main` and `ci/full/**` push; on other `ci/**` pushes only the tests mapped to changed files |
| `weekly` | tests for features not in daily use | the weekly run and on demand |
| `live` | credentialed or opt-in live guards behind `fm_live_gate` in `tests/lib.sh` | the weekly run, where only token-free guards do work; prompt-submitting guards run on demand |

A new test needs a line in `tests/tiers.list` before CI passes.
Put it in `gate` only when it guards a safety property or is the one smoke for a feature; otherwise `full`.

## Triggers and layouts

The `plan` job picks one layout for each run.

| Trigger | Layout | Jobs |
|---|---|---|
| push to `ci/**` | `ci` | static, lint partitions, three gate shards, one changed-area job, and the real-Herdr job running the gate members plus the changed area |
| push to `ci/full/**` | `full` | static, lint partitions, seven shards of `gate` and `full`, and the real-Herdr job running its `gate` and `full` members |
| push to `main` | `full`, or `skip` | as `ci/full/**`; `skip` when the same commit already passed this workflow on a `ci/full/**` push, and then only the static job runs |
| weekly schedule or manual dispatch | `weekly` | static, five shards of `weekly` and `live`, stock macOS Bash, the full test-file lint, and the failure alert |

The changed-area selection is `bin/fm-test-run.sh --changed --tier full,weekly`, so a change to a weekly feature still runs that feature's tests before landing.
A changed path the map cannot place, or a change selecting more than 30 tests (a widely sourced library), escalates a `ci/**` push to the `full` layout.
Lint and test jobs wait only on `plan`, the static job waits on nothing, and the timing aggregate and the weekly alert wait on the test jobs.

`main` runs the full suite on every push that did not already pass it, and `green-pointer.yml` advances only on a successful `push` run, so a weekly run never moves the green pointer.
Landing after a green `ci/**` run is allowed; `main` then catches tier-2 regressions outside the changed area.

A red weekly run opens, or comments on, one open issue titled `Weekly CI run failed` in the repository, so it reaches someone instead of sitting in the Actions tab.
Where repository issues are disabled, the alert job instead fails with an error annotation and a job summary naming the run, so GitHub's failed-run notification carries it.

The `live` tier's real-Herdr guard runs on demand only, because the weekly run starts no Herdr job.

## Shard packing

`--shard k/n` packs the selection by longest-processing-time over measured durations, so no hint table is committed.
The measurements come from the `fm-test-timing-aggregate` artifact of the newest successful `main` or `ci/full/**` run, merged with the newest successful weekly run's.
The `plan` job fetches them and hands them to every shard as `fm-timing-baseline`; without one, every test weighs the same and coverage is unaffected.
Packing only affects balance: the `n` shards of one selection are always disjoint and together equal it.

Inside a shard, `--jobs 4` overlaps only the proven-isolated set from [fm-test-isolation-proof.md](fm-test-isolation-proof.md); every other script runs alone after it.
Family concurrency proofs apply to local runs only, because the 4-wide family phases on the four-vCPU runner were where CI timing flakes happened.

The real-Herdr family runs serially in one job, in path order.

## Coverage and safety guards

`bin/fm-test-run.sh --check-coverage` verifies that `tests/tiers.list` names every test exactly once with a known tier and nothing else.
`bin/fm-safety-guard.sh core` verifies that the gate tier selects every safety-core entry; the script owns its other guards.
Both run in the static job on every run.

## Timing artifacts

Each test job uploads runner-generated timing JSON named `fm-test-timing-<job>`, and the timing aggregate merges them with `bin/fm-test-run.sh --aggregate-json` into `fm-test-timing-aggregate`.
That aggregate is the next run's packing baseline, so a test that grows rebalances the shards without a code change.
Observed maxima are packing weights, not future upper bounds, and a timed-out shard may upload no artifact.

## Lint partitions

Every ci/** push lints only its changed `bin/` and `tests/` shell files with `bin/fm-lint.sh --changed`, a full source-aware pass over just those files.
The main layout lints all of `bin/` in the canonical partitions `bin/fm-lint.sh` owns (`--partition <k>of<n>`; the plan job sets the scopes), each running full source-aware ShellCheck analysis with two workers, workflow validation, and backend-purity checks.
A changed library's findings in unchanged scripts that source it surface on that main-layout lint.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope and per-root execution contract.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots and unchanged analysis flags.
The workflow uploads each lint scope's telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
The weekly test-file lint runs `bin/fm-lint.sh tests/*.sh`, which is a full pass over those paths in CI.

## Mutation testing

[`bin/fm-mutate.sh`](../bin/fm-mutate.sh) is a small mutation tester for the risky-area scripts in `tests/risky-areas.list`; its header owns the operators, the subcommands and the output fields.
A mutant breaks one guard (an exit code, a negation, an `&&`/`||`, a comparison, a `-z`/`-n`, or a whole guard statement), and the tests guarding that script should then fail.
A mutant every guarding test still passes is a survivor: a guard no test notices breaking.

[`.github/workflows/mutation-audit.yml`](../.github/workflows/mutation-audit.yml) runs the one-off sampled audit, never as a gate.
A push to `audit/mutation/**` starts it, a ref ending in `/pilot` runs a small pilot, and a manual dispatch can name scripts and a sample size.
Each script gets 5 to 12 mutants, fewer where its test set is heavy, and each mutant runs against the current gate and full tests that name the script and against the old safety core at the last pre-remake commit.
The report is a kill matrix plus a parity result: parity holds when every mutant the old safety core killed is still killed by a current gate-tier test.
A mutant the old core killed but the gate missed is rerun on both sides once, so a flake on either side cannot decide parity.
Its mutate jobs run up to 300 minutes each, because every mutant runs its whole test set twice; the audit is rare and off the landing path, so that bound sits outside the timeout policy below.

The "Mutation check on changed risky lines" job in `ci.yml` runs on `ci/**` pushes that change a risky-area script.
It samples up to 20 mutants on the changed lines and runs each against the script's gate-tier tests, stopping at the first kill, within a 15-minute budget.
It is non-blocking: survivors show in the job summary, and the job cannot fail the run.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns the tier, shard, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A job that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | plan, static checks, timing aggregate, weekly alert | 5 to 10 minutes | Seconds-long work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, test shards, changed area, mutation check, macOS stock Bash, test-file lint | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint job on the same policy instead of letting packing estimates or one-off caps set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | The step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
`bin/fm-lint-workflows.sh` requires a positive job timeout on every job of a push-triggered workflow and refuses any concurrency setting that could cancel or replace a push run.
`tests/fm-test-run.test.sh` keeps the Herdr family-run step's 20-minute tripwire.
