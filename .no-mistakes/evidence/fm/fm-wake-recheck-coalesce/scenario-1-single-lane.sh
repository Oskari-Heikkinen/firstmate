#!/usr/bin/env bash
# S1 first sight of a live worker's declared pause is absorbed (no wake);
# S2 its due recheck with an unchanged fingerprint is absorbed (no wake);
# S3 the agent crashes under the still-declared wait -> the next due recheck wakes, naming `agent`.
export LAB=/tmp/fmlive-s1
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
say() { printf '\n=== [%s] %s\n' "$(date +%T)" "$*"; }
KN=(FM_PAUSE_RESURFACE_SECS=40 FM_STANDING_WAITS_CEILING_SECS=100000)
say "ack the initial status signal (the real drain), then re-arm the watcher"
drain_ack
say "S1: re-armed over a live worker (agent state: $(bash -c "source $ROOT/bin/fm-backend.sh; fm_backend_agent_state tmux fmlive:fm-a")) whose last line is: $(tail -1 $STATE/a.status)"
watch_start "${KN[@]}"
if watch_wait 15; then echo "S1 FAIL: watcher woke: $(tail -3 $LAB/watch.out)"; else echo "S1 PASS: no wake in 15s of polling"; fi
grep -F 'test' /dev/null; grep -E 'fm-a' "$STATE/.watch-triage.log" | tail -3
echo "wake-queue rows: $(wc -l < $STATE/.wake-queue 2>/dev/null || echo 0) (after ack)"; echo "baseline $(cat $STATE/.recheck-fp-fmlive_fm-a 2>/dev/null | tr '\n' '|')"
say "S2: wait for the status line to age past the 40s recheck cadence with nothing changed"
while [ $(( $(date +%s) - $(stat -c %Y $STATE/a.status) )) -lt 45 ]; do sleep 1; done; sleep 4
if kill -0 $WPID 2>/dev/null; then echo "S2 PASS: watcher still armed; no wake for the due recheck"; else echo "S2 FAIL: woke: $(tail -3 $LAB/watch.out)"; fi
grep -E 'fingerprint unchanged' "$STATE/.watch-triage.log" | tail -2
say "S3: kill the agent process in the pane (a crash under the standing declaration)"
pkill -f "$LAB/bin/claude 1000000"; sleep 1
echo "agent state now: $(bash -c "source $ROOT/bin/fm-backend.sh; fm_backend_agent_state tmux fmlive:fm-a")"
if watch_wait 60; then echo "S3 watcher woke:"; else echo "S3 FAIL: no wake within 60s"; watch_stop; fi
sed -n '/re-arm/,$p' /dev/null; tail -2 $LAB/watch.out
drain_ack | sed 's/^/  drained: /'
grep -E 'fm-a' "$STATE/.watch-triage.log" | tail -4
