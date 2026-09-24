#!/usr/bin/env bash
# S10: a declared wait on a real GitHub PR (read-only `gh pr view` against the fork's open PR #5)
#      is absorbed at its due recheck while the PR is unchanged.
# S10b: the PR goes red / its head moves / it closes -> the due recheck wakes naming `pr`.
#      The real PR cannot be mutated, so a pass-through gh wrapper rewrites one field of the
#      REAL gh response for these three cases (marked as such).
export LAB=/tmp/fmlive-s6; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
mkdir -p "$LAB/ghwrap"
REALGH=$(command -v gh)
cat > "$LAB/ghwrap/gh" <<SH
#!/usr/bin/env bash
out=\$("$REALGH" "\$@") || exit \$?
m=\$(cat $LAB/pr-mode 2>/dev/null)
case "\$m" in *red*) out=\$(printf '%s' "\$out" | jq -c '.statusCheckRollup[0].conclusion="FAILURE"') ;; esac
case "\$m" in *moved*) out=\$(printf '%s' "\$out" | jq -c '.headRefOid="0000000000000000000000000000000000000001"') ;; esac
case "\$m" in *closed*) out=\$(printf '%s' "\$out" | jq -c '.state="CLOSED"') ;; esac
printf '%s\n' "\$out"
SH
chmod +x "$LAB/ghwrap/gh"; export PATH="$LAB/ghwrap:$PATH"
PR=https://github.com/Oskari-Heikkinen/firstmate/pull/5
lane p "paused: waiting for the maintainer to merge $PR"
printf 'pr=%s\n' "$PR" >> "$STATE/p.meta"
sleep 1
KN=(FM_PAUSE_RESURFACE_SECS=25 FM_TEST_RECHECK_WARM_SECS=0)
prime "${KN[@]}"
say "real PR read: $(gh pr view $PR --json state,headRefOid | tr -d '\n')"
say "baseline: $(sed -n 2p $STATE/.recheck-fp-fmlive_fm-p | grep -o 'pr=.*')"
wait_age p 30; sleep 3
if kill -0 $WPID 2>/dev/null; then echo "S10 PASS: unchanged real PR, due recheck absorbed, no wake (lane age $(age_of_status p)s)"; else echo "S10 FAIL: $(tail -2 $LAB/watch.out)"; fi
grep -E 'fingerprint unchanged' "$STATE/.watch-triage.log"
for mode in red moved closed; do
  say "S10b[$mode]: the (wrapped) PR read now reports $mode"
  echo "$mode" >> "$LAB/pr-mode"
  if watch_wait 40; then grep -A5 -F -- "--- watcher armed pid=$WPID" $LAB/watch.out | grep '^stale:'; else echo "[$mode] no wake"; watch_stop; fi
  drain_ack >/dev/null
  watch_start "${KN[@]}"
done
watch_stop; drain_ack >/dev/null
lab_teardown
