. /tmp/fmlive/rig.sh
echo "===== S7: COLD supervisor, 3 unchanged live waits (2 paused, 1 captain-held), cadence 15s, ceiling 45s"
rig_reset s7; lane a; lane b; lane h 'captain-held: the captain is choosing the release channel'
age_status b 0; age_status a 8; age_status h 5
watch_start FM_PAUSE_RESURFACE_SECS=15 FM_TEST_RECHECK_WARM_SECS=0 FM_STANDING_WAITS_CEILING_SECS=45
start=$(date +%s)
if wait_exit 60; then echo "RESULT S7: watcher woke $(( $(date +%s) - start ))s after arming (a's status reached 45s unseen at ~37s)"; else echo "RESULT S7: NO WAKE in 60s"; watch_stop; fi
show | grep -v 'absorbed stale ('
echo "--- wake queue:"; cat "$S/.wake-queue"
echo "--- stdout wake-reason lines: $(grep -c '^stale: ' "$LAB/s7/watch.out")"
