. /tmp/fmlive/rig.sh
echo "===== S6: COLD supervisor; due captain-held recheck is held, then rides along with the next real wake"
rig_reset s6; lane a 'captain-held: the captain is choosing the release channel'
lane b 'paused: waiting on the upstream release'
age_status a 30
watch_start FM_PAUSE_RESURFACE_SECS=15 FM_TEST_RECHECK_WARM_SECS=0
if wait_exit 15; then echo "RESULT S6a: watcher EXITED - cold supervisor woken for a routine recheck"; show; exit 0; fi
echo "RESULT S6a: 15s later no wake; held recheck file:"; cat "$S/.recheck-due-fmlab_fm-a"; echo
echo "--- lane c (live) now appends needs-decision at $(date +%T)"
lane c 'working: building' ; sleep 1
printf 'needs-decision: pick a release channel\n' >> "$S/c.status"
if wait_exit 20; then echo "RESULT S6b: watcher woke at $(date +%T)"; else echo "RESULT S6b: NO WAKE"; watch_stop; fi
show | grep -v 'absorbed stale (paused'
echo "--- wake queue:"; cat "$S/.wake-queue"
echo "--- held file remaining: $(ls "$S"/.recheck-due-* 2>/dev/null || echo none)"
