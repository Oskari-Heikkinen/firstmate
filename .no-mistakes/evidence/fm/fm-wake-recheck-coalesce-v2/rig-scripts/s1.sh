. /tmp/fmlive/rig.sh
for which in base change; do
  if [ $which = base ]; then BIN=/tmp/fmlive/base/bin; else BIN=$ROOT/bin; fi
  echo "===== S1 [$which watcher: $BIN] live worker (claude alive in tmux) declared paused:, fresh status"
  rig_reset s1-$which; lane a
  watch_start FM_PAUSE_RESURFACE_SECS=600
  if wait_exit 12; then echo "RESULT: watcher EXITED (woke the supervisor)"; else echo "RESULT: watcher still running after 12s - no wake"; watch_stop; fi
  show
  echo "--- wake queue:"; cat "$S/.wake-queue" 2>/dev/null
done
