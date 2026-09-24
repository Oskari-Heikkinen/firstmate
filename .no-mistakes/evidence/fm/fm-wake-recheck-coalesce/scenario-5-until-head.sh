#!/usr/bin/env bash
# S8: a passed `until` time wakes a cold supervisor once; the next recheck of the unchanged lane is absorbed.
# S9: a task-copy HEAD move under a declared wait wakes a cold supervisor at the due recheck, naming `head`.
export LAB=/tmp/fmlive-s5; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
until_at=$(date -u -d "@$(( $(date +%s) + 25 ))" +%Y-%m-%dT%H:%M:%SZ)
lane u "paused: vendor reply expected until $until_at"
lane k 'paused: waiting for the upstream release'
sleep 1
KN=(FM_PAUSE_RESURFACE_SECS=40 FM_TEST_RECHECK_WARM_SECS=0)
prime "${KN[@]}"
say "armed cold; lane u declared until $until_at"
if watch_wait 60; then say "watcher woke at $(date -u +%T)Z:"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else echo FAIL; watch_stop; fi
drain_ack >/dev/null
say "S9: lane k's task copy gets a new commit; re-armed cold; waiting past the next due rechecks"
git -C "$LAB/wt/k" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'worker progress'
watch_start "${KN[@]}"
if watch_wait 70; then say "watcher woke (lane u aged $(age_of_status u)s):"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else echo "no wake"; watch_stop; fi
for w in u k; do echo "queued stale rows for fmlive:fm-$w in this wake: $(stale_rows fmlive:fm-$w)"; done
drain_ack
say "S8b: re-armed cold; wait until lane u's next recheck after the until time is due"
watch_start "${KN[@]}"
wait_age u 75; sleep 3
if kill -0 $WPID 2>/dev/null; then echo "S8b PASS: no wake at lane u age $(age_of_status u)s"; else echo "S8b FAIL: $(tail -2 $LAB/watch.out)"; fi
watch_stop; drain_ack >/dev/null
say "triage log for lane u after its until time:"
grep -E 'fm-u' "$STATE/.watch-triage.log" | grep -E 'queued|fingerprint' 
lab_teardown
