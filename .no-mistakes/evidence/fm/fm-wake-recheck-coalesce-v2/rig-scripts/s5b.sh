. /tmp/fmlive/rig.sh
echo "===== S5b: two live lanes changed while the watcher was down; both due when it re-arms -> one wake"
rig_reset s5b; lane a; lane b
watch_start FM_PAUSE_RESURFACE_SECS=15
sleep 4; watch_stop; drain_ack >/dev/null
echo "--- first-sight baselines recorded:"; for k in a b; do sed -n 2p "$S/.recheck-fp-fmlab_fm-$k" | sed 's/status=[^ ]* //'; done
for t in a b; do git -C "$LAB/s5b/wt-$t" -c user.email=l@l -c user.name=l commit -q --allow-empty -m moved; done
T=$(( $(date +%s) - 20 )); touch -m -d "@$T" "$S/a.status" "$S/b.status"
echo "--- both task copies committed; both waits now 20s old (past the 15s cadence). Re-arming watcher at $(date +%T)"
: > "$S/.watch-triage.log"
watch_start FM_PAUSE_RESURFACE_SECS=15
if wait_exit 30; then echo "RESULT S5b: watcher woke at $(date +%T)"; else echo "RESULT S5b: NO WAKE"; watch_stop; fi
show | grep -v 'absorbed stale (paused'
echo "--- wake queue:"; cat "$S/.wake-queue"
echo "--- stdout wake-reason lines: $(grep -c '^stale: ' "$LAB/s5b/watch.out")"
