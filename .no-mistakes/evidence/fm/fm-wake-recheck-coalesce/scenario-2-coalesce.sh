#!/usr/bin/env bash
# S4: co-due declared-wait rechecks across four lanes (two paused lanes whose task copies
# went dirty, two attended captain-held lanes) are delivered as ONE wake.
export LAB=/tmp/fmlive-s2; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
lane a 'paused: waiting for vendor reply on the API quota'
lane b 'paused: waiting for the upstream release'
lane c 'captain-held: the captain is choosing the release channel'
lane d 'captain-held: the captain owns the pricing decision'
sleep 1
KN=(FM_PAUSE_RESURFACE_SECS=40)
prime "${KN[@]}"
say "first sight: watcher armed, lanes aged $(age_of_status a)s; queue rows after ack: $(wc -l < $STATE/.wake-queue)"
sleep 6
say "lanes a and b change under their declarations: their task copies go dirty"
touch "$LAB/wt/a/notes.txt" "$LAB/wt/b/draft.txt"
if watch_wait 60; then say "watcher woke once, lanes aged $(age_of_status a)s. printed wake reasons:"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else say "FAIL: no wake"; watch_stop; fi
echo "number of wake reason lines printed by this arm: $(grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -c '^stale: ')"
for w in a b c d; do echo "queued stale rows for fmlive:fm-$w: $(stale_rows fmlive:fm-$w)"; done
say "drained by the supervisor:"; drain_ack
grep -E 'queued declared-wait' "$STATE/.watch-triage.log"
lab_teardown
