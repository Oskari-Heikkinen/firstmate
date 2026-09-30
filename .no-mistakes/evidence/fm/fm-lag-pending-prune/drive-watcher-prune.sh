#!/usr/bin/env bash
# Drive the real bin/fm-watch.sh in a throwaway FM_HOME seeded with pending-reply
# records, and report which records survive the watcher's own cycles.
# usage: drive-watcher-prune.sh <repo-root> <label> [extra env assignments...]
set -u
ROOT=$1 LABEL=$2; shift 2
H=$(mktemp -d /tmp/fm-prune-live.XXXXXX)
S="$H/state"; D="$S/pending-replies"; FB="$H/fakebin"
mkdir -p "$D" "$H/config" "$H/data" "$FB"
# Backend stubs: nothing in this home may reach a real tmux/herdr session.
for b in tmux herdr; do printf '#!/bin/sh\necho "$0 $*" >> "%s/backend-calls.log"\nexit 1\n' "$H" > "$FB/$b"; chmod +x "$FB/$b"; done
now=$(date +%s); old=$((now - 2*86400)); hour=$((now - 3600)); two_h=$((now - 7200))
rec() {  # corr task phase created resolved escalated closed delivered
  printf '%s\n' "schema=fm-pending-reply.v1" "corr_id=$1" "task_id=$2" \
    "parent_status=$S/$2.status" "created_epoch=$4" "delivered_epoch=${8-$4}" \
    "phase=$3" "resolved_epoch=$5" "escalated_epoch=${6-}" \
    "escalation_closed_epoch=${7-}" > "$D/$1"
}
N=${BULK:-1500}
for ((i = 0; i < N; i++)); do
  c=$(printf 'c%015x' "$i"); rec "$c" bulk resolved $((old - 100)) "$old"
  [ $((i % 10)) -ne 0 ] || printf 'confirmed=%s\n' "$old" > "$D/.delivery-confirmed-$c"
done
rec aaaaaaaaaaaaaa01 keep resolved $((hour - 100)) "$hour"          # recent: keep
rec aaaaaaaaaaaaaa02 keep resolved $((two_h - 100)) "$two_h"        # 2h old: keep at default, prune at 3600
rec aaaaaaaaaaaaaa03 keep resolved $((old - 100)) ''                # no resolved_epoch (mid-resolve shape): keep
rec aaaaaaaaaaaaaa04 keep resolved $((old - 100)) "$old" $((old-50)) ''  # open escalation: close first
rec aaaaaaaaaaaaaa05 keep resolved $((old - 100)) "$old"            # named by handoff marker: keep
printf 'confirmed:aaaaaaaaaaaaaa05\n' > "$S/.backlog-handoff-keep.wake-pending"
rec bbbbbbbbbbbbbb01 open awaiting_report $((old - 100)) '' '' '' $((old - 100))
rec bbbbbbbbbbbbbb02 open delivery_unknown $((old - 100)) '' '' '' ''
rec bbbbbbbbbbbbbb03 open escalated $((old - 100)) '' $((old - 50)) '' $((old - 100))
rec bbbbbbbbbbbbbb04 open recovery_sent $((old - 100)) '' '' '' $((old - 100))
confirm_before=$(find "$D" -name '.delivery-confirmed-*' | wc -l)
echo "== [$LABEL] seeded $(find "$D" -maxdepth 1 -type f ! -name '.*' | wc -l) records, $confirm_before delivery confirmations in $H"
start=$(date +%s.%N)
# Run the watcher the way the arm loop does: relaunch after each exit, up to
# ${LAUNCHES:-3} launches; each launch runs until it exits on a wake or its 4th cycle.
for launch in $(seq 1 "${LAUNCHES:-3}"); do
env PATH="$FB:$PATH" FM_HOME="$H" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_HOME_SUMMARY_INTERVAL=999999 "$@" "$ROOT/bin/fm-watch.sh" > "$H/watch.out" 2> "$H/watch.err" &
wp=$!
beats=0; last=''; t0=$SECONDS
while [ $((SECONDS - t0)) -lt 240 ] && kill -0 "$wp" 2>/dev/null; do
  m=$(stat -c %y "$S/.last-watcher-beat" 2>/dev/null || true)
  if [ -n "$m" ] && [ "$m" != "$last" ]; then beats=$((beats+1)); last=$m
    printf '   launch %d cycle-top %d at +%.1fs, records left=%d\n' "$launch" "$beats" "$(echo "$(date +%s.%N) - $start" | bc)" \
      "$(find "$D" -maxdepth 1 -type f ! -name '.*' | wc -l)"
  fi
  [ "$beats" -ge 4 ] && break
  sleep 0.2
done
alive=no; kill -0 "$wp" 2>/dev/null && alive=yes
kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
printf '   launch %d ended at +%.1fs (still running when stopped: %s), records left=%d\n' "$launch" "$(echo "$(date +%s.%N) - $start" | bc)" "$alive" "$(find "$D" -maxdepth 1 -type f ! -name '.*' | wc -l)"
sed 's/^/   watcher stdout: /' "$H/watch.out" | head -3
sed 's/^/   watcher stderr: /' "$H/watch.err" | head -5
rm -rf "$S/.watch.lock"
done
echo "   bulk aged records left: $(find "$D" -maxdepth 1 -name 'c*' -type f | wc -l) / $N"
echo "   delivery confirmations left: $(find "$D" -name '.delivery-confirmed-*' | wc -l) / $confirm_before"
for c in aaaaaaaaaaaaaa01 aaaaaaaaaaaaaa02 aaaaaaaaaaaaaa03 aaaaaaaaaaaaaa04 aaaaaaaaaaaaaa05 bbbbbbbbbbbbbb01 bbbbbbbbbbbbbb02 bbbbbbbbbbbbbb03 bbbbbbbbbbbbbb04; do
  if [ -f "$D/$c" ]; then st="KEPT   (phase=$(grep '^phase=' "$D/$c" | tail -1 | cut -d= -f2), esc_closed=$(grep '^escalation_closed_epoch=' "$D/$c" | tail -1 | cut -d= -f2))"; else st=PRUNED; fi
  echo "   $c $st"
done
echo "   backend stub calls: $(cat "$H/backend-calls.log" 2>/dev/null | wc -l)"
rm -rf "$H"
