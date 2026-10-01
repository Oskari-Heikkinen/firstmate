#!/usr/bin/env bash
# Live adversarial scenarios for the wedge watchdog, two lab homes side by side:
#  A. home A wedges (pipe hold); its watchdog stops A only - home B's healthy
#     watcher (same code, same grace) is never signalled.
#  B. a wall-clock jump (B's beacon backdated 1000s, as after host suspend) does
#     not make B's watchdog stop a watcher that keeps beating.
#  C. a frozen holder (SIGSTOP on B's watcher, live but never beating) is
#     recovered without a manual kill: the watchdog stops it, and the owner
#     path (fm-watch-arm.sh) starts a fresh watcher.
# usage: scenario-watchdog-adversarial.sh <code-root> <home-A> <home-B>
set -u
CODE=$1 A=$2 B=$3
export FM_GUARD_GRACE=8 FM_POLL=2 FM_WATCHER_WATCHDOG_INTERVAL=2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=6
REAL_TMUX=$(command -v tmux)
alive() { kill -0 "$1" 2>/dev/null && [ "$(awk '{print $3}' /proc/$1/stat 2>/dev/null)" != Z ]; }
mkdir -p "$A/shim"
cat > "$A/shim/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then "$REAL_TMUX" "\$@"; sleep 600 & printf '%s\n' "\$!" > "$A/holder.pid"; exit 0; fi
exec "$REAL_TMUX" "\$@"
SH
chmod +x "$A/shim/tmux"
"$REAL_TMUX" new-window -d -n fm-wedgeA 'bash --norc'
S=$("$REAL_TMUX" display-message -p '#S')
printf 'window=%s\nkind=ship\n' "$S:fm-wedgeA" > "$A/state/wa.meta"
FM_HOME=$B "$CODE/bin/fm-watch-arm.sh" > "$B/arm1.out" 2>&1 & BARM=$!
sleep 2
FM_HOME=$A PATH="$A/shim:$PATH" "$CODE/bin/fm-watch-arm.sh" > "$A/arm1.out" 2>&1 & AARM=$!
sleep 2
WA=$(cat "$A/state/.watch.lock/pid"); WB=$(cat "$B/state/.watch.lock/pid")
echo "home A watcher=$WA ($(head -1 "$A/arm1.out"));  home B watcher=$WB ($(head -1 "$B/arm1.out"))"
echo "== A: wedge home A, home B healthy =="
for t in $(seq 1 16); do
  echo "t=${t}s A alive=$(alive $WA && echo yes || echo no) A_wchan=$(cat /proc/$WA/wchan 2>/dev/null) | B alive=$(alive $WB && echo yes || echo no) B_beacon_age=$(( $(date +%s) - $(stat -c %Y "$B/state/.last-watcher-beat") ))s"
  alive $WA || break
  sleep 1
done
echo "A triage: $(grep watchdog "$A/state/.watch-triage.log")"
echo "B triage watchdog lines: $(grep -c watchdog "$B/state/.watch-triage.log" 2>/dev/null || echo 0)"
echo "RESULT A: home A stopped=$(alive $WA && echo no || echo yes), home B watcher $WB still alive=$(alive $WB && echo yes || echo no)"
kill "$(cat "$A/holder.pid")" 2>/dev/null
echo "== B: wall-clock jump on home B's beacon =="
touch -d "@$(( $(date +%s) - 1000 ))" "$B/state/.last-watcher-beat"
echo "backdated B beacon: age now $(( $(date +%s) - $(stat -c %Y "$B/state/.last-watcher-beat") ))s"
for t in $(seq 1 12); do
  echo "t=${t}s B alive=$(alive $WB && echo yes || echo no) B_beacon_age=$(( $(date +%s) - $(stat -c %Y "$B/state/.last-watcher-beat") ))s"
  sleep 1
done
echo "RESULT B: B watcher survived jump=$(alive $WB && echo yes || echo no); watchdog lines=$(grep -c watchdog "$B/state/.watch-triage.log" 2>/dev/null || echo 0)"
echo "== C: SIGSTOP home B's watcher (live pid, never beats) =="
kill -STOP "$WB"
for t in $(seq 1 20); do
  st=$(awk '{print $3}' /proc/$WB/stat 2>/dev/null || echo gone)
  echo "t=${t}s B watcher state=$st beacon_age=$(( $(date +%s) - $(stat -c %Y "$B/state/.last-watcher-beat") ))s"
  [ "$st" = T ] || break
  sleep 1
done
sleep 1
echo "B triage: $(grep watchdog "$B/state/.watch-triage.log" | tr '\n' ' ')"
echo "B lock now: $(cat "$B/state/.watch.lock/pid" 2>/dev/null || echo '<none>')  old watcher alive=$(alive $WB && echo yes || echo no)"
FM_HOME=$B "$CODE/bin/fm-watch-arm.sh" > "$B/arm2.out" 2>&1 & BARM2=$!
i=0; while [ "$i" -lt 40 ] && [ ! -s "$B/arm2.out" ]; do sleep 0.2; i=$((i+1)); done
echo "RESULT C: owner-path re-arm on B: $(head -1 "$B/arm2.out")"
WB2=$(cat "$B/state/.watch.lock/pid" 2>/dev/null)
echo "--- B cycle-exit ledger ---"; cut -f2,6-10 "$B/state/.watch-cycle-exits.log" 2>/dev/null
kill -TERM "$BARM2" "$WB2" "$BARM" "$AARM" 2>/dev/null; kill -KILL "$WB" "$WA" 2>/dev/null; sleep 3
echo "--- leftover processes referencing either lab home ---"
for p in /proc/[0-9]*; do grep -qsE "$A|$B" "$p/environ" 2>/dev/null && echo "$(basename $p) $(tr '\0' ' ' < $p/cmdline)"; done | grep -v scenario-watchdog || echo "(none)"
