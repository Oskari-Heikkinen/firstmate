# Standing budgets and over-budget gate rows

A standing budget is a resource envelope the captain approved once, so requests inside it run without a new decision.
A request over it opens one captain-held gate row whose packet carries the budget's default and deadline.
[`bin/fm-budget-lib.sh`](../bin/fm-budget-lib.sh) owns the record, spend, shadow, and check formats and the cap arithmetic.
[`bin/fm-budget.sh`](../bin/fm-budget.sh) is the command, and its header is the reference for every option.
The captain-held task and its packet follow [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md).

## The budget record

A budget is one `key: value` file at `config/budgets/<id>.budget`, schema `fm-budget.v1`:

| Key | Meaning |
| --- | --- |
| `schema` | `fm-budget.v1`. |
| `id` | The budget id, matching the file name. |
| `covers` | `campaign <slug>` or `kind <slug>`: what the budget is for. |
| `owner` | The home that owns the budget policy. |
| `core-hours` | The core-hour cap, up to three decimals, or `none`. |
| `disk-bytes` | The disk cap in bytes, or `none`. |
| `end-date` | The last UTC day a request may run, as `YYYY-MM-DD`. |
| `over-budget-default` | `approve` or `refuse`: the gate row's default. |
| `deadline-offset` | `<N>h` or `<N>d` after the gate row opens, when the default applies. |
| `shadow` | `on` (the default) or `off`. |
| `approved-at` | The UTC time the captain approved the budget. |
| `quote` | One or more lines holding the captain's approving words verbatim. |

A record with no `quote` line is refused by every command, because a budget nobody approved in words is not a standing budget.
A malformed or unknown key is refused too.
No budget exists until someone writes one; the command creates none.

## Checking a request (`check`)

`check <id> --core-hours <N> --disk-bytes <N> --date <YYYY-MM-DD>` is read-only.
It reports `inside` or `over`, the caps exceeded, and one line per cap with its spent, requested, and remaining amount.
`--json` prints the same as one `fm-budget-check.v1` object.
Spend comes from the `--spend-file` records it is given, or else from this home's own ledger at `data/budgets/<id>.spend.jsonl`.
It counts only records of this budget, each request id once, and refuses a malformed record rather than count it as nothing.
`spend <id> --request <rid> --core-hours <N> --disk-bytes <N>` appends to that ledger once per request id.

## Opening a gate row (`open-gate`)

`open-gate <id> --request <rid> --requester <home> ...` runs the same check.
Inside the budget it opens nothing.
Over it, it holds task `budget-gate-<id>-<rid>` and attaches a packet under authority `budget.<id>`.
The packet's recommendation and default are the budget's `over-budget-default`, and its deadline is the budget's `deadline-offset`.
Its evidence is the check and the budget's approval, and its prerequisite tells the requester to hold the request.
A rerun while the gate is open leaves it, and its deadline, as they are.

The default applies only through `bin/fm-captain-hold.sh apply-defaults`, is logged as `defaulted`, and stays reversible with `reverse`.
`apply-defaults` re-reads the budget, so a budget whose quote was removed or whose default changed applies nothing.

## Shadow mode

While `shadow` is `on`, `check` and `open-gate` append one `fm-budget-shadow.v1` record to `data/budgets/<id>.shadow.jsonl` and open nothing.
The record says what the command would have done: `no-gate`, or `open-gate` with the task, default, and deadline offset.
`shadow-log <id>` prints it.
A budget goes live only when its record is changed to `shadow: off`.
