#!/usr/bin/env bash
# S6: a cold supervisor is not woken by a routine due recheck (captain-held h); the held
#     recheck rides along with the next real wake (lane j needs a decision); an unchanged
#     paused lane (i) is absorbed and does not ride along.
# S7: a held recheck is delivered as soon as the supervisor takes a turn (Claude turn-end ledger touched).
export LAB=/tmp/fmlive-s4; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
lane h 'captain-held: the captain is choosing the release channel'
lane i 'paused: waiting for vendor reply on the API quota'
sleep 1
KN=(FM_PAUSE_RESURFACE_SECS=30 FM_TEST_RECHECK_WARM_SECS=0)
prime "${KN[@]}"
say "armed cold (warm window 0), 30s cadence; waiting until both waits are due and 20s beyond"
wait_age h 50
if kill -0 $WPID 2>/dev/null; then echo "S6a PASS: no wake at age $(age_of_status h)s though both rechecks are due"; else echo "S6a FAIL: $(tail -2 $LAB/watch.out)"; fi
ls $STATE | grep -E '^\.recheck-(due|absorbed)' | sed 's/^/  held record: /'
grep -E 'queued declared-wait|fingerprint unchanged' "$STATE/.watch-triage.log"
say "a third lane raises a real, captain-relevant signal"
printf 'window=fmlive:fm-j\nbackend=tmux\nkind=ship\n' > "$STATE/j.meta"
printf 'needs-decision: pick a release channel for the SDK\n' > "$STATE/j.status"
if watch_wait 30; then say "watcher woke:"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else echo FAIL; watch_stop; fi
for w in h i; do echo "queued stale rows for fmlive:fm-$w: $(stale_rows fmlive:fm-$w)"; done
say "drained by the supervisor:"; drain_ack
rm -f "$STATE/j.meta"
say "S7: re-arm with an 8s warm window; wait for h's next recheck to be held cold"
watch_start FM_PAUSE_RESURFACE_SECS=30 FM_TEST_RECHECK_WARM_SECS=8
n=0; until [ -e "$STATE/.recheck-due-fmlive_fm-h" ] || [ $n -gt 600 ]; do sleep 0.1; n=$((n+1)); done
echo "held: $(ls $STATE/.recheck-due-* 2>/dev/null)  watcher alive: $(kill -0 $WPID 2>/dev/null && echo yes || echo no)"
sleep 5; echo "5s later, still no wake: $(kill -0 $WPID 2>/dev/null && echo yes || echo no)"
say "the supervisor takes a turn (Claude turn-end ledger state/.claude-autoarm-epoch moves)"
: > "$STATE/.claude-autoarm-epoch"
if watch_wait 10; then say "watcher woke:"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else echo FAIL; watch_stop; fi
drain_ack
lab_teardown
