. /tmp/fmlive/rig.sh
echo "===== S8: live lane whose meta records pr= (real gh reads of https://github.com/Oskari-Heikkinen/firstmate/pull/6, read-only)"
rig_reset s8; lane a 'paused: waiting for review on https://github.com/Oskari-Heikkinen/firstmate/pull/6'
printf 'pr=https://github.com/Oskari-Heikkinen/firstmate/pull/6\n' >> "$S/a.meta"
watch_start FM_PAUSE_RESURFACE_SECS=15 FM_TEST_RECHECK_WARM_SECS=0
sleep 5; echo "--- baseline:"; sed -n 2p "$S/.recheck-fp-fmlab_fm-a" | sed 's/status=[^ ]* //'
if wait_exit 30; then echo "RESULT S8a: watcher EXITED on an unchanged PR"; show; exit 0; fi
echo "RESULT S8a: unchanged open PR -> no wake after 35s"; grep 'absorbed paused recheck' "$S/.watch-triage.log"
echo "--- S8b: the lane's recorded PR is repointed to merged PR #3 (real forge read returns MERGED) at $(date +%T)"
sed -i 's#^pr=.*#pr=https://github.com/Oskari-Heikkinen/firstmate/pull/3#' "$S/a.meta"
if wait_exit 30; then echo "RESULT S8b: watcher woke at $(date +%T)"; else echo "RESULT S8b: NO WAKE"; watch_stop; fi
cat "$LAB/s8/watch.out"; echo "--- baseline after delivery:"; sed -n 2p "$S/.recheck-fp-fmlab_fm-a" | sed 's/status=[^ ]* //'
