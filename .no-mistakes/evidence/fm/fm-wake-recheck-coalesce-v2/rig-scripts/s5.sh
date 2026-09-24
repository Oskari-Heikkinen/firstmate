. /tmp/fmlive/rig.sh
echo "===== S5: two live lanes change and fall due on the same poll -> one wake"
rig_reset s5; lane a; lane b
T=$(( $(date +%s) - 2 )); touch -m -d "@$T" "$S/a.status" "$S/b.status"
watch_start FM_PAUSE_RESURFACE_SECS=15
sleep 5
for t in a b; do git -C "$LAB/s5/wt-$t" -c user.email=l@l -c user.name=l commit -q --allow-empty -m moved; done
echo "--- committed in both task copies at $(date +%T)"
if wait_exit 30; then echo "RESULT S5: watcher woke at $(date +%T)"; else echo "RESULT S5: NO WAKE"; watch_stop; fi
show | grep -v 'absorbed stale (paused'
echo "--- wake queue (one row per lane, one wake):"; cat "$S/.wake-queue"
echo "--- stdout wake-reason lines: $(grep -c '^stale: ' "$LAB/s5/watch.out")"
