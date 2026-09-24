# Live run: second-mate routine-line typing (throwaway FM_HOME /tmp/fmlive-x6Px/home, private tmux server, real bin/fm-send.sh, bin/fm-watch.sh, bin/fm-wake-drain.sh)

## 1. fm-send records the expectation kind
$ fm-send.sh mate --expect ack "standing note: prefer small PRs"
exit=0
$ fm-send.sh mate "what did the ledger audit find?"
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
exit=0
-- state/pending-replies/b7065ccb11625ee9
corr_id=b7065ccb11625ee9
request_summary=standing note: prefer small PRs
expect=ack
-- state/pending-replies/d9f192b97a80b03a
corr_id=d9f192b97a80b03a
request_summary=what did the ledger audit find?
expect=answer

## 2. uncorrelated note wakes (watch.01)
watcher printed: signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237517	2	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 2 --recovery-generation 1229606.1790237517.hoIYyO
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: note: mate bootstrapped and read its charter
  drain| UNREAD STATUS (new since last drain, not re-printed after this presentation):
  drain| mate note: mate bootstrapped and read its charter
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

## 3. ack-typed correlated note + uncorrelated working line absorbed; ack record resolved silently
appended: note [corr=b7065ccb11625ee9]: taken up, will keep PRs small from now on
appended: working: auditing the release-notes ledger for alpha
  triage| [2026-09-24T10:12:15+0200] absorbed benign signal: /tmp/fmlive-x6Px/home/state/mate.status
  triage| [2026-09-24T10:12:21+0200] absorbed benign signal: /tmp/fmlive-x6Px/home/state/mate.status
  record b7065ccb11625ee9 after: expect=ack phase=resolved resolved_via=status (no wake queued)

## 4. answer-typed correlated note wakes; drain presents the absorbed lines in UNREAD STATUS
watcher printed: signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237558	4	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 4 --recovery-generation 1278401.1790237558.Tolf9H
  drain| wake annotation: unread wake-EVENT since last drain, not current state: mate.status: note [corr=b7065ccb11625ee9]: taken up, will keep PRs small from now on
  drain| wake annotation: unread wake-EVENT since last drain, not current state: mate.status: working: auditing the release-notes ledger for alpha
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: note [corr=d9f192b97a80b03a]: the ledger audit found two stale release entries; details in data/audit.md
  drain| UNREAD STATUS (new since last drain, not re-printed after this presentation):
  drain| mate note [corr=b7065ccb11625ee9]: taken up, will keep PRs small from now on
  drain| mate working: auditing the release-notes ledger for alpha
  drain| mate note [corr=d9f192b97a80b03a]: the ledger audit found two stale release entries; details in data/audit.md
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

## 5. correlated working line on an answer request wakes
watcher printed: signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237585	6	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 6 --recovery-generation 1297802.1790237585.svwSUM
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: working [key=audit]: corr=460fd76d5e14fec2 started the ledger audit
  drain| UNREAD STATUS (new since last drain, not re-printed after this presentation):
  drain| mate working [key=audit]: corr=460fd76d5e14fec2 started the ledger audit
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

## 6. done reply to an ack request wakes
watcher printed: signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237597	8	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 8 --recovery-generation 1314120.1790237597.o9N8OC
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [corr=243222d0e76971b4]: pinned the flaky CI note and paused merges on alpha
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [corr=243222d0e76971b4]: pinned the flaky CI note and paused merges on alpha
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

## 7. duplicate outcome lines (note: d3 exited on check: rearm-resurface because the previous absorbing watcher was killed by the harness; d4 therefore classified both merged lines together. Re-driven as m1/m2 with a watcher kept alive.)
### d1-first-ready
appended: done [key=child-pr-kid]: child kid PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/77 mode=no-mistakes yolo=off
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237623	10	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 10 --recovery-generation 1337548.1790237623.942Kum
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=child-pr-kid]: child kid PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/77 mode=no-mistakes yolo=off
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=child-pr-kid]: child kid PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/77 mode=no-mistakes yolo=off
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### d2-ledger-repeat
appended: done [key=child-outcome-kid-done-0123abcd]: child kid done: shipped the ledger fix pr=https://github.com/Oskari-Heikkinen/firstmate/pull/77 mode=no-mistakes yolo=off
RESULT: ABSORBED (watcher still blocking) triage: [2026-09-24T10:13:53+0200] absorbed benign signal: /tmp/fmlive-x6Px/home/state/mate.status

### d3-first-merged
appended: done [key=merged-kid]: merged kid https://github.com/Oskari-Heikkinen/firstmate/pull/77
RESULT: WOKE -> check: rearm-resurface
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=merged-kid]: merged kid https://github.com/Oskari-Heikkinen/firstmate/pull/77
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation 1360724.1790237641.gwTZCU

### d4-merged-repeat
appended: done [key=merged-kid]: merged kid https://github.com/Oskari-Heikkinen/firstmate/pull/77
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237650	12	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 12 --recovery-generation 1371536.1790237650.GpJuvr
  drain| wake annotation: unread wake-EVENT since last drain, not current state: mate.status: done [key=child-outcome-kid-done-0123abcd]: child kid done: shipped the ledger fix pr=https://github.com/Oskari-Heikkinen/firstmate/pull/77 mode=no-mistakes yolo=off
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=merged-kid]: merged kid https://github.com/Oskari-Heikkinen/firstmate/pull/77
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=merged-kid]: merged kid https://github.com/Oskari-Heikkinen/firstmate/pull/77
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=merged-kid]: merged kid https://github.com/Oskari-Heikkinen/firstmate/pull/77
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### d5-kid2-ready
appended: done [key=child-pr-kid2]: child kid2 PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237659	14	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 14 --recovery-generation 1381996.1790237659.FSl7KK
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=child-pr-kid2]: child kid2 PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=child-pr-kid2]: child kid2 PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### d6-ledger-with-report
appended: done [key=child-outcome-kid2-done-89abcdef]: child kid2 done: shipped pr=https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off report=data/kid2/report.md
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237666	16	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 16 --recovery-generation 1395706.1790237666.Di0N2n
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=child-outcome-kid2-done-89abcdef]: child kid2 done: shipped pr=https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off report=data/kid2/report.md
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=child-outcome-kid2-done-89abcdef]: child kid2 done: shipped pr=https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off report=data/kid2/report.md
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### d7-failure-between
appended: failed: kid2 CI broke on main after merge
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237678	18	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 18 --recovery-generation 1403728.1790237678.GQLQR3
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: failed: kid2 CI broke on main after merge
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate failed: kid2 CI broke on main after merge
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### d8-ready-after-failure
appended: done [key=child-pr-kid2]: child kid2 PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237687	20	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 20 --recovery-generation 1412714.1790237687.9gSdUU
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=child-pr-kid2]: child kid2 PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=child-pr-kid2]: child kid2 PR ready: https://github.com/Oskari-Heikkinen/firstmate/pull/78 mode=no-mistakes yolo=off
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.


## 8. merged repeat, working absorbed, mixed span, needs-decision
### m1-first-merged
appended: done [key=merged-kid2]: merged kid2 https://github.com/Oskari-Heikkinen/firstmate/pull/78
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237709	22	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 22 --recovery-generation 1436489.1790237709.7tCoac
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: done [key=merged-kid2]: merged kid2 https://github.com/Oskari-Heikkinen/firstmate/pull/78
  drain| STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
  drain| mate done [key=merged-kid2]: merged kid2 https://github.com/Oskari-Heikkinen/firstmate/pull/78
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### m2-merged-repeat
appended: done [key=merged-kid2]: merged kid2 https://github.com/Oskari-Heikkinen/firstmate/pull/78
RESULT: ABSORBED (watcher still blocking) triage: [2026-09-24T10:15:19+0200] absorbed benign signal: /tmp/fmlive-x6Px/home/state/mate.status

### m3-working-absorbed
appended: working: rebasing kid3 onto the new main
RESULT: ABSORBED (watcher still blocking) triage: [2026-09-24T10:15:30+0200] absorbed benign signal: /tmp/fmlive-x6Px/home/state/mate.status

### m4-mixed-working-plus-note
appended: working: still on kid3
appended: note: the vendor changed their API; kid3 needs a new plan
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237742	24	signal	mate.status	signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 24 --recovery-generation 1481382.1790237742.SIptMm
  drain| wake annotation: unread wake-EVENT since last drain, not current state: mate.status: done [key=merged-kid2]: merged kid2 https://github.com/Oskari-Heikkinen/firstmate/pull/78
  drain| wake annotation: unread wake-EVENT since last drain, not current state: mate.status: working: rebasing kid3 onto the new main
  drain| wake annotation: unread wake-EVENT since last drain, not current state: mate.status: working: still on kid3
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: note: the vendor changed their API; kid3 needs a new plan
  drain| UNREAD STATUS (new since last drain, not re-printed after this presentation):
  drain| mate working: rebasing kid3 onto the new main
  drain| mate working: still on kid3
  drain| mate note: the vendor changed their API; kid3 needs a new plan
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.

### m5-needs-decision
appended: needs-decision [key=kid3-plan]: rewrite kid3 against v2 API or pin v1?
RESULT: WOKE -> signal: /tmp/fmlive-x6Px/home/state/mate.status
  drain| 1790237751	26	signal	mate.status	needs-decision: /tmp/fmlive-x6Px/home/state/mate.status
  drain| WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 26 --recovery-generation 1492174.1790237751.oFVzfL
  drain| wake annotation: latest wake-EVENT observed at drain, not current state: mate.status: needs-decision [key=kid3-plan]: rewrite kid3 against v2 API or pin v1?
  drain| OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
  drain| mate [key=kid3-plan] needs-decision: rewrite kid3 against v2 API or pin v1?
  drain| OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'
  drain| WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.


## 9. fm-send --expect refusals
$ fm-send.sh build --expect ack fix-the-test
error: --expect requires a recorded secondmate task selector; only a marked secondmate request carries a reply expectation
exit=1
$ fm-send.sh mate --expect maybe bad-kind
error: --expect must be ack or answer (got 'maybe')
exit=1
$ fm-send.sh mate --fire-and-forget fyi-1 --expect ack fyi
error: --fire-and-forget delivery id must be 16 lowercase hex characters
exit=1
$ fm-send.sh mate --expect ack --key Escape
error: --expect cannot accompany --key; a keystroke carries no request
exit=1
$ fm-send.sh mate --expect ack --expect answer twice
error: duplicate --expect
exit=1
$ FM_PENDING_REPLY_EXISTING_CORR=<ack-record expect=ack> fm-send.sh mate --expect answer resend
error: explicitly requested pending-reply correlation '243222d0e76971b4' is not reusable for mate; refusing to mint a replacement correlation
exit=1
$ fm-send.sh mate --fire-and-forget 0123456789abcdef --expect ack fyi
error: --expect cannot accompany --fire-and-forget, which expects no reply
exit=1
$ fm-send.sh mate --expect ack "FYI: freeze on alpha until Friday"
exit=0
new record 282cc322b205e728 expect=ack phase=awaiting_report 
$ FM_PENDING_REPLY_EXISTING_CORR=282cc322b205e728 fm-send.sh mate --expect answer 'resend'
error: --expect answer conflicts with the kind recorded on reused correlation 282cc322b205e728; resend without --expect to keep it
exit=1
record after: expect=ack phase=awaiting_report 
