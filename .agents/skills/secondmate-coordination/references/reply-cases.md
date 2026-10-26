# Reply cases for marked requests

Each case below recurred at least once before the turn-end rule was written into the charter.
In every one, the request's `.msg` was moved to `handled/` with no correlated line, and a `REPOST REQUIRED` followed within minutes.
The examples use `bin/fm-secondmate-report.sh`, run from the secondmate home with `FM_HOME` set; a plain `echo` of the same line to the parent channel is equally valid.

## A heads-up that asks for a reply only if affected

The request still gets a line, because the guard cannot tell "not affected" from "never read".

```sh
bin/fm-secondmate-report.sh note <corr_id> "not affected: no task in this home uses the restarted service"
```

## A request answered by dispatching a worker

The dispatch is the start of the work, not the answer.
Name the worker and where its result will appear, then carry the token into the worker's brief or the wait record so the final answer can quote it.

```sh
bin/fm-secondmate-report.sh working <corr_id> "dispatched scout ci-status-check; report lands at <absolute data path>"
```

When the scout reports, answer with the same token.

## A relayed approval or a deferred landing

Relaying an approval to a worker, or waiting for a merge train to land a car, leaves the answer for later.
Post what was relayed and what follows in the same turn.

```sh
bin/fm-secondmate-report.sh working <corr_id> "approval relayed to the worker; landing follows through the merge train"
```

## A watch armed for the final result

An armed watch is invisible to the guard, so it is not a reply either.
Name the watch in the turn-end line, and give the watch's action the token so its outcome answers the request.

## A detailed answer

Write the answer to a doc under this home's `data/`, then point to it in one line.

```sh
bin/fm-secondmate-report.sh --doc done <corr_id> data/<task>/answer.md "review finished; two findings"
```

## After a REPOST REQUIRED arrives

The recovery message names the same `corr=<id>`.
Post the line the original request needed, in whichever form the situation above calls for, and post it once.
If the reply was written but landed in this home's own `state/<task>.status` instead of the parent channel, the parent's guard repairs that one mixup itself; any other misplaced line still needs reposting through the helper.
If the recovery turn also ends without a correlated line, the parent escalates once, opening a keyed decision that closes when a correlated reply arrives.
