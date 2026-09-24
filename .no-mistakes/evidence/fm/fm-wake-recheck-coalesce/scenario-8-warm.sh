#!/usr/bin/env bash
# S7: a routine recheck falling due while the supervisor is cold is held; the moment the
# supervisor takes a turn (Claude's turn-end ledger state/.claude-autoarm-epoch moves) it is delivered.
# Warm window compressed to 8s via the watcher's FM_TEST_RECHECK_WARM_SECS hook (production: 3300s).
export LAB=/tmp/fmlive-s8; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
lane h 'captain-held: the captain is choosing the release channel'
sleep 1
KN=(FM_PAUSE_RESURFACE_SECS=30 FM_TEST_RECHECK_WARM_SECS=8)
prime "${KN[@]}"
say "watcher armed at lane age $(age_of_status h)s; recheck due at 30s, i.e. well after the 8s warm window"
n=0; until [ -e "$STATE/.recheck-due-fmlive_fm-h" ] || [ $n -gt 600 ]; do sleep 0.1; n=$((n+1)); done
say "recheck due at lane age $(age_of_status h)s: held record $(ls $STATE/.recheck-due-* 2>/dev/null); watcher alive: $(kill -0 $WPID 2>/dev/null && echo yes || echo no)"
sleep 8
say "8s later: watcher alive (no wake): $(kill -0 $WPID 2>/dev/null && echo yes || echo no); wake-queue rows: $(grep -c . $STATE/.wake-queue 2>/dev/null || echo 0)"
say "the supervisor takes a turn: state/.claude-autoarm-epoch moves"
: > "$STATE/.claude-autoarm-epoch"
if watch_wait 10; then say "watcher woke:"; grep -A20 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep -v '^---'; else echo "FAIL no wake"; watch_stop; fi
drain_ack
lab_teardown
