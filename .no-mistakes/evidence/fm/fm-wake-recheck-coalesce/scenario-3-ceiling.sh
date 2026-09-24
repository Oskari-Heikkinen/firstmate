#!/usr/bin/env bash
# S5: two unchanged paused waits under a cold supervisor are absorbed at every due recheck,
# then at the standing-waits ceiling exactly one wake lists every standing wait.
export LAB=/tmp/fmlive-s3; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
lane e 'paused: waiting for vendor reply on the API quota'
lane f 'paused: waiting for the design review'
sleep 1
KN=(FM_PAUSE_RESURFACE_SECS=25 FM_STANDING_WAITS_CEILING_SECS=80 FM_TEST_RECHECK_WARM_SECS=0)
prime "${KN[@]}"
say "armed cold (warm window 0) with a 25s recheck cadence and an 80s standing-waits ceiling"
if watch_wait 120; then say "watcher woke, lanes aged $(age_of_status e)s:"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else say FAIL; watch_stop; fi
echo "wake reason lines printed: $(grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -c '^stale: ')"
for w in e f; do echo "queued stale rows for fmlive:fm-$w: $(stale_rows fmlive:fm-$w)"; done
say "triage log (absorbed rechecks before the ceiling):"
grep -E 'fingerprint unchanged|queued' "$STATE/.watch-triage.log"
say "drained by the supervisor:"; drain_ack
lab_teardown
