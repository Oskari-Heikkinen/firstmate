. /tmp/fmlive/rig.sh
echo "===== S4: COLD supervisor (FM_TEST_RECHECK_WARM_SECS=0), live worker under paused:, agent then crashes"
rig_reset s4; lane a
watch_start FM_PAUSE_RESURFACE_SECS=15 FM_TEST_RECHECK_WARM_SECS=0
sleep 4; echo "--- agent state before: $(bash -c ". $BIN/fm-backend.sh; fm_backend_agent_state tmux fmlab:fm-a")"
tmux send-keys -t fmlab:fm-a C-c; sleep 1
echo "--- agent killed with Ctrl-C at $(date +%T); agent state now: $(bash -c ". $BIN/fm-backend.sh; fm_backend_agent_state tmux fmlab:fm-a")"
if wait_exit 40; then echo "RESULT S4: watcher woke at $(date +%T)"; else echo "RESULT S4: NO WAKE within 40s"; watch_stop; fi
show | grep -v 'absorbed stale (paused'
echo "--- wake queue:"; cat "$S/.wake-queue"
