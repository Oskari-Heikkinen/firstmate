. /tmp/fmlive/rig.sh
for which in base change; do
  if [ $which = base ]; then BIN=/tmp/fmlive/base/bin; else BIN=$ROOT/bin; fi
  echo "===== [$which] single live lane appends needs-decision"
  rig_reset dup-$which; lane c 'working: building'
  watch_start FM_PAUSE_RESURFACE_SECS=600
  sleep 3; printf 'needs-decision: pick a release channel\n' >> "$S/c.status"
  wait_exit 20 || { echo no wake; watch_stop; }
  cat "$LAB/$CASE/watch.out"; echo "--- queue:"; cat "$S/.wake-queue"
done
