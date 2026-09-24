. /tmp/fmlive/rig.sh
echo "===== S2+S3: warm supervisor, resurface cadence 15s, live worker under paused:"
rig_reset s2; lane a
watch_start FM_PAUSE_RESURFACE_SECS=15
sleep 3; echo "--- baseline recorded at first sight (.recheck-fp-fmlab_fm-a):"; cat "$S/.recheck-fp-fmlab_fm-a"
if wait_exit 35; then echo "RESULT S2: watcher EXITED early"; show; exit 1; fi
echo "RESULT S2: after 35s (recheck due at 15s and 30s) no wake; watcher still running"
grep -c 'absorbed paused recheck (fingerprint unchanged' "$S/.watch-triage.log" | sed 's/^/absorbed-unchanged recheck count: /'
grep 'absorbed paused recheck' "$S/.watch-triage.log"
echo "--- S3: make a real commit in the task copy (HEAD moves) at $(date +%T)"
git -C "$LAB/s2/wt-a" -c user.email=l@l -c user.name=l commit -q --allow-empty -m 'upstream released'
if wait_exit 40; then echo "RESULT S3: watcher woke at $(date +%T)"; else echo "RESULT S3: NO WAKE within 40s"; watch_stop; fi
show
echo "--- wake queue:"; cat "$S/.wake-queue"
