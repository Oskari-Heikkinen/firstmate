#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-on-positive-evidence: a wake
# is absorbed only when the crew shows it is still working through an actively
# running no-mistakes step or a backend busy signal. A home that opts in with
# config/turnend-churn-absorb lets a bare turn-end also use bounded pane churn
# since the previous poll. Every other no-verb wake surfaces, so a crew
# that finishes (or stops and waits) is never silently swallowed. A declared wait,
# either a paused: external wait or a verified captain-held transfer, is the
# separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# That cadence is hours long and condition-aware: a paused: line naming
# `until <UTC ISO 8601>` is rechecked when that time passes, but a declared time
# beyond FM_PAUSE_RESURFACE_SECS cannot extend the ordinary recheck cadence, and
# while an away record (state/.afk-contract, never quiet mode's) exists an
# item held for the captain is never rechecked at all, in either posture.
# Quiet waits: in normal mode, while a task's newest status is a `paused:` wait
# whose machine-checkable condition still holds (status_declared_wait_check in
# bin/fm-classify-lib.sh owns the [wait=...] vocabulary), a bare turn-end or a
# stale pane for that task is acknowledged here and recorded in
# state/.quiet-wait-acks instead of waking the supervisor. A new status line, a
# condition that stops holding, an endpoint with no agent, the standing-waits
# ceiling, and heartbeats still wake it; captain-relevant and check wakes are
# never touched.
# Outside afk, routine signals, declared-wait rechecks, and rearm-resurface are
# held in one wake batch (FM_WAKE_BATCH_SECS, wake_batch_due) while urgent
# status lines still wake at once.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          span has a captain-relevant event OR a no-verb signal lacks
#                          positive execution evidence, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause or verified captain-held transfer is
#                          absorbed instead with its own long re-surface cadence,
#                          never as a wedge, and that recheck reason names which
#                          human the wait is on. Only when neither absorb class
#                          applies does the log's latest recognized status event decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A pane about to escalate
#                          that can account for its quiet - a `paused:` external
#                          wait or a verified `captain-held` transfer its worker
#                          declared, or, where config/wedge-defer-parked-gate
#                          arms it, a validation gate of its own awaiting a
#                          supervisor decision nobody has answered yet - is
#                          deferred to that same long recheck cadence instead
#                          (wedge_wait_evidence), and a pane whose own task
#                          worktree was written during the quiet window is
#                          deferred rather than escalated (wedge_defer_writing),
#                          because files appearing there are liveness the pane and
#                          the run step cannot show; that deferral still
#                          re-surfaces once per PAUSE_RESURFACE_SECS, and a pane
#                          that writes nothing keeps the unchanged schedule.
#                          A pane whose recorded endpoint holds no agent at all is
#                          not a wedge and is reported ONCE instead of escalating
#                          on that cadence forever (wedge_dead_record); only the
#                          two recovery-grade verdicts license it, and every other
#                          verdict escalates unchanged.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (state/<id>.turn-ended, or the spawn record before any
#                          turn completes). Past that bound, a declared external
#                          wait or verified captain-held transfer uses the long
#                          pause recheck cadence; under daemon-backed afk an
#                          external wait is instead handed to the daemon as this
#                          plain reason once per declaration, while captain-held
#                          work stays silent until return
#                          (busy_turn_bound_check owns that split);
#                          every other pane goes through the same wedge timer,
#                          the dead-record probe above included, and surfaces
#                          with the identical "stale: ..." reason, escalation
#                          count, and demand-deep-inspection marker for a live
#                          agent, for human inspection only - never an automatic
#                          interrupt, signal, or restart of the worker or its
#                          tool process.
#   stale: <window> (unread firstmate instruction: ...)
#   stale: <window> (steering-inbox ladder bookkeeping unwritable: ...)
#   stale: <window> (steering-inbox busy bookkeeping unwritable: ...)
#                          steering-inbox recovery; bin/fm-task-inbox-lib.sh owns
#                          delivery-attempt, busy-deferral, and unavailable-endpoint policy
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: process-event source stranded: <keys>
#                          a registered process-to-event source has a claim
#                          reconcile will not displace and nothing collecting
#                          for it (bin/fm-procevent.sh reconcile queues it
#                          once per stranded claim generation); the queued
#                          payload names what clears it
#   check: process-event source failed to start: <keys>
#                          a registered process-to-event source was launched by
#                          reconcile and did not prove it took the claim within
#                          the confirm window, so nothing is confirmed to be
#                          collecting for it and every cycle will relaunch it
#                          (bin/fm-procevent.sh reconcile queues it once per
#                          failure episode, and a later cycle that finds the
#                          source owned closes that episode); the queued
#                          payload names what to check. These three kinds are
#                          joined with `;` when more than one surfaces in a cycle
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
#   check: secondmate wake-loop stalled: mate=<id> row=<seq> idle=<seconds>s
#                          an actionable row in an endpoint-recorded local
#                          secondmate home's durable wake queue did not advance
#                          between observations for FM_SECONDMATE_WAKE_STALL_SECS
#                          while the mate was not in an active turn (a busy mate
#                          is exempt only until the queue has been frozen for
#                          BUSY_TURN_MAX_SECS); declared external-wait pause
#                          rows do not feed this escalation; a mate whose
#                          semantic busy class is exactly idle, whose agent is
#                          alive, and whose composer is not pending is rung
#                          once so its own home can drain, and the parent
#                          notification is withheld until that same row stays
#                          frozen for another stall interval; unknown or
#                          ring-unsafe panes keep the parent alarm; empty
#                          inbox and a fresh child beacon are not idle proof;
#                          the foreign queue itself stays read-only, and one
#                          parent notification covers each no-progress episode
#   check: secondmate <id> auto-relaunched after <cause> (<where>)
#                          the liveness tick probed a registered secondmate's
#                          recorded endpoint, got the recovery-grade `dead` or
#                          `missing` verdict, and relaunched it through the
#                          same guarded fm-spawn.sh --secondmate path the
#                          session-start sweep uses; one wake per relaunch, and
#                          state/.secondmate-relaunch-<id> keeps the durable
#                          per-mate count (bin/fm-secondmate-liveness-lib.sh)
#   check: secondmate <id> auto-relaunch failed after <cause>: <detail>
#                          the same verdict authorized recovery but the
#                          relaunch itself failed; the attempt is ledgered and
#                          counts toward the bound below
#   check: secondmate <id> auto-relaunch paused after <n> attempts in <s>s; ...
#                          a mate that kept dying exceeded its bounded relaunch
#                          budget and is parked until a probe reads it live
#                          again (FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS and
#                          FM_SECONDMATE_LIVENESS_WINDOW_SECS)
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock. A live holder whose beacon is stale
# past the grace (FM_WATCHER_STALE_GRACE, default max(300, FM_POLL+60)) is
# refused with "lock held by live pid ... but heartbeat is stale"; one stale past
# the hard bound FM_WATCHER_STALL_BOUND (default 3x that grace) is instead
# evicted with TERM after its recorded identity is re-verified, and this arm
# starts in its place, printing "watcher: replaced stalled pid <N> (...)". A
# holder that survives TERM keeps the refusal and the nonzero exit.
# Once per poll the watcher also checks that its home (when it existed at
# start), its state directory, and its own bin directory still exist; when one
# is gone it logs "watcher: exiting - <what> no longer exists: <path>" to stderr
# and exits 1, so a watcher whose temporary home or disposable checkout was
# deleted stops itself instead of running on as an orphan. That check is scoped
# to this process alone and never signals another watcher.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"
# A home that never existed (a state-only test fixture) is not a home that
# disappeared, so the per-poll home-gone exit below applies only when it did.
WATCH_HOME_EXISTED=0
[ ! -d "$FM_HOME" ] || WATCH_HOME_EXISTED=1

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime needlessly spends per-root CI lint memory while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Only for the arm-time check on FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS below;
# the per-cycle reconcile itself runs as a separate process.
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# Single owner of durable merge-outcome publication, shared with
# bin/fm-pr-merge.sh so self and poll origins use the same role-routed outcome.
# The watcher still owns immediate delivery of its actionable poll result and
# poll retirement.
# This library is a canonical lint root in its own right, and it reaches the
# wake queue, PR identity, and secondmate parent libraries. Keep it an analysis
# boundary here for the same reason as the transition and inbox owners above and
# below: following its graph from this large runtime needlessly spends per-root
# CI lint memory while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# The durable merge-authority owner is shared with bin/fm-pr-merge.sh. The
# watcher consumes only its identity-bound record after a poll observes landing.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-merge-authority-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# Steering-inbox loss detection: bin/fm-task-inbox-lib.sh owns the record,
# doorbell, re-ring ladder, and unavailable-endpoint contracts; this watcher
# supplies their live endpoint and busy checks plus wake emission
# (inbox_steer_check below).
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# The away-posture record (state/.afk-contract) is the posture in both the
# attended and the afk session; bin/fm-afk-contract.sh owns its schema and its
# away-or-quiet reading, which is all this watcher reads (away_record_present
# below).
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# Persistent-secondmate endpoint liveness: the shared probe/relaunch library is
# the same one bin/fm-bootstrap.sh's session-start sweep drives, so ordinary
# supervision recovers a positively dead or missing mate through the identical
# guarded path. The watcher contributes only the cadence, the relaunch bound,
# and wake emission (secondmate_liveness_tick below).
# shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
# On Darwin, call /usr/bin/stat rather than PATH-resolved stat so GNU coreutils
# cannot shadow the BSD `-f` syntax.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# bin/fm-classify-lib.sh owns status reported-state signatures and presentation
# markers, while bin/fm-wake-lib.sh owns their wake-facing routing, the legacy
# turn-ended signature, annotation staleness checks, and guarded bookkeeping writes.

POLL=${FM_POLL:-15}                   # seconds between cycles
# The liveness beacon is touched at the top of every cycle and refreshed at its
# step boundaries (see watcher_beat), including just before the terminal wait
# (event_wait_or_sleep), so a healthy cycle's beacon ages by at most its
# longest single step or POLL.
# fm_poll_derived_grace (bin/fm-wake-lib.sh, already sourced
# transitively above) is the single owner of the max(300, poll+60)
# derivation - see docs/turnend-guard.md "Guard grace and the poll cadence".
# This recomputes the library default above now that the real configured
# POLL is known.
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-$(fm_poll_derived_grace "$POLL")}}
# Hard bound on a live holder's beacon age. Under it a re-arm refuses and asks
# for inspection (the grace above); at or past it the re-arm evicts the holder
# instead, because a watcher whose beacon has stalled that long is not polling
# and nothing else would ever replace it (evict_stalled_holder below).
# fm_watcher_stall_bound (bin/fm-wake-lib.sh) owns the derivation, shared with
# the arm that follows this watcher.
WATCHER_STALL_BOUND=$(fm_watcher_stall_bound "$POLL")
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
HOME_SUMMARY_INTERVAL=${FM_HOME_SUMMARY_INTERVAL:-300}
case "$HOME_SUMMARY_INTERVAL" in
  ''|*[!0-9]*|0) HOME_SUMMARY_INTERVAL=300 ;;
esac
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Urgent-bypass wake batching (wake_batch_due below). A routine signal batch, a
# declared-wait recheck, and a rearm-resurface are held for up to this many
# seconds from the first held item, then woken together. needs-decision,
# blocked, failed, captain-held, and every other captain-relevant line except
# a plain done: still wake at once, carrying the held signal lines with them.
# FM_WAKE_BATCH_SECS wins over the home's config/wake-batch-secs; unset means
# 180, 0 keeps the immediate wake, and an unreadable value fails to 0.
WAKE_BATCH_SECS=${FM_WAKE_BATCH_SECS-$(cat "$CONFIG/wake-batch-secs" 2>/dev/null || true)}
WAKE_BATCH_SECS=${WAKE_BATCH_SECS//[[:space:]]/}
case "$WAKE_BATCH_SECS" in
  '') WAKE_BATCH_SECS=180 ;;
  *[!0-9]*) WAKE_BATCH_SECS=0 ;;
  *) WAKE_BATCH_SECS=$((10#$WAKE_BATCH_SECS)) ;;
esac
WAKE_BATCH_MARKER="$STATE/.wake-batch-since"
# A held rearm-resurface, kept on disk so a restarted watcher still owes it.
WAKE_BATCH_RESURFACE="$STATE/.wake-batch-resurface"
WAKE_BATCH_HELD=0
WATCHER_RESURFACE_HELD=0
CLEANUP_LOCK_BOUND=${FM_WATCHER_CLEANUP_LOCK_BOUND:-2}  # seconds EXIT cleanup may
                                      # wait on the downtime-marker lock; a live
                                      # foreign holder must not strand a TERM'd
                                      # watcher inside its own trap
case "$CLEANUP_LOCK_BOUND" in
  ''|*[!0-9]*) CLEANUP_LOCK_BOUND=2 ;;
  *) CLEANUP_LOCK_BOUND=$((10#$CLEANUP_LOCK_BOUND)) ;;
esac
[ "$CLEANUP_LOCK_BOUND" -gt 0 ] || CLEANUP_LOCK_BOUND=2
TURNEND_CHURN_ABSORB_SECS=${FM_TURNEND_CHURN_ABSORB_SECS:-900}  # longest a task's
                                      # bare turn-ends may be deferred on pane-churn
                                      # evidence alone (signal_turnend_panes_churned)
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-on-positive-evidence. The shared proof is an actively
# running no-mistakes step or a busy pane via crew_is_provably_working over
# fm-crew-state.sh; where config/turnend-churn-absorb opts in, a bare turn-end alone
# may also use bounded pane churn since the previous poll.
# Every other crew that stopped its turn is SURFACED, so a finish reported
# only through interactive pane menus (no done: status) is never swallowed. An
# ACTIONABLE wake (a captain-relevant signal, a no-verb signal without either
# eligible proof, any check, a stale pane whose crew is not provably working, a
# provably-working stale past the threshold, or anything unknown) is written to
# the durable queue and exits. That wakes the LLM through the background-task
# completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go without a completed turn or explicit native-harness progress (the
# marker-selection contract is in busy_turn_over_age below). Once this bound
# is crossed, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. Set generously above
# any legitimate interval without observable progress, including silent long
# tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# Idle park nudge: a ship or scout pane gone quiet with no declared wait, no
# captain call, and nothing provably working is first told, once, to park
# (bin/fm-park.sh) or finish, instead of waking firstmate at once. The idle bound
# is the stale threshold itself (FM_WATCHER_STALE_GRACE). If the pane is still
# idle IDLE_PARK_GRACE seconds after the nudge, firstmate is woken with the
# ordinary stale wake naming the ignored nudge; a later idle episode inside
# IDLE_PARK_REPEAT of that nudge wakes firstmate directly rather than nudging
# again. FM_IDLE_PARK_NUDGE=off restores the immediate wake.
IDLE_PARK_NUDGE=${FM_IDLE_PARK_NUDGE:-on}
IDLE_PARK_GRACE=${FM_IDLE_PARK_GRACE:-}
case "$IDLE_PARK_GRACE" in ''|*[!0-9]*) IDLE_PARK_GRACE=600 ;; esac
IDLE_PARK_REPEAT=${FM_IDLE_PARK_REPEAT:-}
case "$IDLE_PARK_REPEAT" in ''|*[!0-9]*) IDLE_PARK_REPEAT=3600 ;; esac
# A local secondmate's foreign queue is checked on every poll, but only after this
# bounded interval with no drain progress can it produce a parent notification.
# A healthy mate drains its queue between turns, not inside one, so this default
# sits above a real turn; it is only the backstop behind the active-turn gate in
# secondmate_wake_stall_tick, never a substitute for it.
SECONDMATE_WAKE_STALL_SECS=${FM_SECONDMATE_WAKE_STALL_SECS:-}
case "$SECONDMATE_WAKE_STALL_SECS" in ''|*[!0-9]*|0) SECONDMATE_WAKE_STALL_SECS=180 ;; esac
# Secondmate ENDPOINT liveness (distinct from the wake-loop stall observation
# above): on this cadence the watcher probes each registered mate's recorded
# endpoint through fm-secondmate-liveness-lib.sh and relaunches only on the
# same recovery-grade `dead` or `missing` verdicts the session-start sweep
# uses. The cadence survives watcher restarts via a state marker's mtime, so a
# relaunch wake cannot restart the probe into a tight loop.
SECONDMATE_LIVENESS_SECS=${FM_SECONDMATE_LIVENESS_SECS:-}
case "$SECONDMATE_LIVENESS_SECS" in ''|*[!0-9]*|0) SECONDMATE_LIVENESS_SECS=60 ;; esac
# Per-relaunch wall-clock bound, so a wedged spawn cannot stall the poll.
SECONDMATE_LIVENESS_TIMEOUT=${FM_SECONDMATE_LIVENESS_TIMEOUT:-}
case "$SECONDMATE_LIVENESS_TIMEOUT" in ''|*[!0-9]*|0) SECONDMATE_LIVENESS_TIMEOUT=120 ;; esac
# Relaunch bound: at most this many automatic attempts per window per mate,
# counted from the durable attempt ledger the shared library appends to. A mate
# that keeps dying past the bound wakes once and is parked until a probe reads
# it alive again, so a flapping endpoint cannot relaunch forever unseen.
SECONDMATE_LIVENESS_MAX_ATTEMPTS=${FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS:-}
case "$SECONDMATE_LIVENESS_MAX_ATTEMPTS" in ''|*[!0-9]*|0) SECONDMATE_LIVENESS_MAX_ATTEMPTS=3 ;; esac
SECONDMATE_LIVENESS_WINDOW_SECS=${FM_SECONDMATE_LIVENESS_WINDOW_SECS:-}
case "$SECONDMATE_LIVENESS_WINDOW_SECS" in ''|*[!0-9]*|0) SECONDMATE_LIVENESS_WINDOW_SECS=3600 ;; esac
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew uses that same bounded cadence for every
# agent-liveness verdict, including alive and unknown; a dead agent stays on
# the recheck rather than surfacing promptly (issue 2713).
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten wait cannot rot
# invisibly - except an item held for the captain while the away-posture record
# exists, which is never rechecked (away_record_present below).
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# A declared-wait recheck that falls due is never delivered on its own the
# moment it is due. Every due recheck is queued as pending and all of them are
# delivered together as ONE wake (recheck_flush), because each wake costs a
# supervisor turn and a turn after a long idle rewrites the supervisor's whole
# prompt cache. The pending set is delivered at once while the supervisor's
# cache is still warm - it took a turn within RECHECK_WARM_SECS, read from this
# watcher's own start (a supervisor arms the watcher at the end of a turn) and
# Claude's turn-end auto-arm ledger - and otherwise rides along with the next
# wake this watcher raises for any other reason. Only when neither happens does
# it wake on its own, once a pending wait has gone STANDING_WAITS_CEILING_SECS
# without being shown to the supervisor, so a forgotten wait still cannot rot
# invisibly. A lane whose fingerprint changed and the first recheck after a
# paused wait's declared `until` time passes are delivered when due, still
# coalesced with whatever else is pending. While the away-mode daemon owns
# triage it owns this whole schedule too: the watcher hands it each due recheck
# as the plain stale wake it classifies itself, and leaves the fingerprint
# baseline and the delivery time it compares against untouched.
RECHECK_WARM_SECS=3300
STANDING_WAITS_CEILING_SECS=${FM_STANDING_WAITS_CEILING_SECS:-$FM_STANDING_WAITS_CEILING_SECS_DEFAULT}
case "$STANDING_WAITS_CEILING_SECS" in ''|*[!0-9]*|0) STANDING_WAITS_CEILING_SECS=$FM_STANDING_WAITS_CEILING_SECS_DEFAULT ;; esac
WATCH_STARTED_EPOCH=$(date +%s)
# A declared wait that names WHEN it clears (`paused: ... until <UTC ISO 8601>`,
# status_paused_until in fm-classify-lib.sh) is condition-aware: it is not
# rechecked before that time, and it is rechecked once as soon as that time
# passes even when the flat cadence has not elapsed, then held to the cadence.
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# away_record_present: 0 while an away record exists (the captain is away, in
# either supervision shape); quiet mode's record is a present captain, so it
# reads 1 (fm_afk_contract_away_present). "The away-posture record exists"
# below means this. While it exists an item held for the captain is never
# rechecked: there is nobody to answer it, the return brief lists it, and a
# recheck would only churn (the 2026-09-07 away-window audit counted hourly
# rechecks of captain-held items as pure noise). Declared external waits keep
# their condition-aware cadence in both postures.
away_record_present() { fm_afk_contract_away_present "$STATE"; }

# captain_held_silenced <status-line>: 0 when the line declares a captain-held
# transfer and an away record exists, so every stale path absorbs the pane
# silently instead of rechecking it.
captain_held_silenced() {  # <status-line>
  status_is_captain_held "$1" && away_record_present
}

# hash_pane_to <output-variable> <text>: the md5 hex of <text> as printf '%s'
# writes it, which the .hash- and .stale- markers hold. The tool is chosen once,
# md5 where it exists, and md5sum's file column is cut in the shell.
if command -v md5 >/dev/null 2>&1; then
  hash_pane_to() {
    local _hp_sum
    _hp_sum=$(printf '%s' "$2" | md5 -q)
    printf -v "$1" '%s' "$_hp_sum"
  }
else
  hash_pane_to() {
    local _hp_sum
    _hp_sum=$(printf '%s' "$2" | md5sum)
    printf -v "$1" '%s' "${_hp_sum%% *}"
  }
fi

# hash_pane_memo_to <output-variable> <slot> <text>: hash_pane_to for the
# per-window staleness pass, where <slot> is the window's position in that pass.
# Each slot keeps the last text it hashed and that text's hash, so a pane that
# has not changed since the previous pass (idle, parked or wedged) is answered
# without the md5 pipeline; a busy pane's footer changes every pass and is
# hashed as before. The whole text is compared, so a hit is exactly what
# hash_pane_to returns, a reordered window list only costs a recompute, and a
# restarted watcher starts with no memory. A result that is not an md5 hex is
# never kept, so a failed hash is recomputed on the next pass.
PANE_HASH_MEMO_TEXTS=()
PANE_HASH_MEMO_SUMS=()
hash_pane_memo_to() {  # <output-variable> <slot> <text>
  local _hm_sum
  if [ -n "${PANE_HASH_MEMO_SUMS[$2]-}" ] && [ "${PANE_HASH_MEMO_TEXTS[$2]}" = "$3" ]; then
    printf -v "$1" '%s' "${PANE_HASH_MEMO_SUMS[$2]}"
    return 0
  fi
  hash_pane_to _hm_sum "$3"
  if [[ $_hm_sum =~ ^[0-9a-f]{32}$ ]]; then
    PANE_HASH_MEMO_TEXTS[$2]=$3
    PANE_HASH_MEMO_SUMS[$2]=$_hm_sum
  else
    PANE_HASH_MEMO_SUMS[$2]=
  fi
  printf -v "$1" '%s' "$_hm_sum"
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is passed
# into the contract's harness-scoped rendered-text checks: the Grok/Rovo/AGY
# busy fallbacks and the launch-prompt backstop that keeps a launch pinned at
# its fm-spawn seed from reading as provably working. It runs on every polled
# window, so it takes the verdict through the contract's *_to forms, in this
# shell, rather than a subshell per window.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 meta verdict
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL
  window_resolve "$w"
  meta="$STATE/$WR_TASK.meta"
  if [ -n "$WR_TASK" ] && [ -f "$meta" ]; then
    fm_busy_classify_meta_to verdict "$meta" "$WR_TASK" "$STATE" "$tail40"
  else
    fm_busy_classify_to verdict "$WR_BACKEND" "$w" "$WR_HARNESS" \
      "${WR_TASK:-unknown}" "$STATE" "$tail40"
  fi
  [ "${verdict%% *}" = busy ]
}

# window_resolve: what the watcher reads about <window> from the task metas, in
# one pass in the watcher's own shell instead of a subshell plus grep and cut per
# field, each of which re-read every meta. The meta is the first in glob order
# whose last window= or terminal= is <window>, as in window_to_task and
# fm_backend_meta_for_window. It sets:
#   WR_TASK     window_to_task's answer, including its name fallback
#   WR_KIND     the meta's kind= values, ship when it has none; unknown with no meta
#   WR_BACKEND  the meta's backend= values, tmux when it has none or there is no
#               meta (absent backend= means tmux; the P1 compatibility contract)
#   WR_HARNESS  the meta's harness= values, or empty
#   WR_LABEL    fm-<task>, or empty when there is no task
# Kind, backend and harness keep the reading the watcher's window_* readers
# always had: every value of the key, newline-joined, as `grep '^key=' | cut
# -d= -f2-` printed them into $(...). An empty <window> names no meta for them, as
# fm_backend_meta_for_window never matches an empty target. The pane-stale pass
# resolves its current window once and reads these globals for the rest of that
# window's turn; every other caller declares them local first, as the readers
# below do, so it never overwrites the pass's answer.
window_resolve() {  # <window>
  local _wr_meta _wr_line _wr_mw _wr_mt _wr_kind _wr_backend _wr_harness _wr_nl=$'\n'
  WR_TASK='' WR_KIND=unknown WR_BACKEND=tmux WR_HARNESS='' WR_LABEL=''
  for _wr_meta in "$STATE"/*.meta; do
    [ -e "$_wr_meta" ] || continue
    _wr_mw='' _wr_mt='' _wr_kind='' _wr_backend='' _wr_harness=''
    {
      while IFS= read -r _wr_line || [ -n "$_wr_line" ]; do
        case "$_wr_line" in
          window=*) _wr_mw=${_wr_line#window=} ;;
          terminal=*) _wr_mt=${_wr_line#terminal=} ;;
          kind=*) _wr_kind=$_wr_kind${_wr_line#kind=}$_wr_nl ;;
          backend=*) _wr_backend=$_wr_backend${_wr_line#backend=}$_wr_nl ;;
          harness=*) _wr_harness=$_wr_harness${_wr_line#harness=}$_wr_nl ;;
        esac
      done < "$_wr_meta"
    } 2>/dev/null
    [ "$_wr_mw" = "$1" ] || [ "$_wr_mt" = "$1" ] || continue
    WR_TASK=${_wr_meta##*/}
    WR_TASK=${WR_TASK%.meta}
    if [ -n "$1" ]; then
      window_resolve_chomp _wr_kind
      window_resolve_chomp _wr_backend
      window_resolve_chomp _wr_harness
      WR_KIND=${_wr_kind:-ship}
      WR_BACKEND=${_wr_backend:-tmux}
      WR_HARNESS=$_wr_harness
    fi
    break
  done
  if [ -z "$WR_TASK" ]; then
    WR_TASK=${1##*:}
    WR_TASK=${WR_TASK#fm-}
  fi
  [ -z "$WR_TASK" ] || WR_LABEL=fm-$WR_TASK
}

# Cut every trailing newline from the named variable, as $(...) does.
window_resolve_chomp() {  # <variable>
  local _wrc_value=${!1} _wrc_nl=$'\n'
  while :; do
    case "$_wrc_value" in
      *"$_wrc_nl") _wrc_value=${_wrc_value%"$_wrc_nl"} ;;
      *) break ;;
    esac
  done
  printf -v "$1" '%s' "$_wrc_value"
}

window_kind() {
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL
  window_resolve "$1"
  echo "$WR_KIND"
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL
  window_resolve "$1"
  echo "$WR_BACKEND"
}

window_label() {
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL
  window_resolve "$1"
  [ -n "$WR_LABEL" ] && printf '%s' "$WR_LABEL"
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .writing-*, .waiting-*), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once. window_key_to assigns what window_key prints.
window_key_to() {  # <output-variable> <window>
  local _wk_key=${2//:/_}
  _wk_key=${_wk_key//\//_}
  printf -v "$1" '%s' "${_wk_key//./_}"
}

window_key() {  # <window>
  local _wk_out
  window_key_to _wk_out "$1"
  printf '%s' "$_wk_out"
}

inbox_steer_escalate_unavailable() {  # <window> <task> <record>
  local w=$1 task=$2 rec=$3 reason
  reason="stale: $w (unread firstmate instruction: $rec is unhandled and the worker's agent has exited or its endpoint is missing, so the doorbell was not typed; recover the worker)"
  if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
    fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
    return 0
  fi
  fm_wake_append stale "$w" "$reason" || exit 1
  if ! fm_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
    echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
    exit 1
  fi
  wake "$reason"
}

# Steering-inbox loss detection, one cheap check per recorded window per poll.
# bin/fm-task-inbox-lib.sh owns delivery, busy-deferral, retry, and escalation policy.
# Endpoint and busy checks precede delivery so recovery never types into a busy,
# dead, or missing worker; the ring helper protects pending composer text.
# Normal retries keep the watcher blocking rather than waking firstmate.
# Runs for secondmates too: their pane-staleness exemption is about quiet panes
# being healthy, while an unacknowledged instruction can still be a stuck steer.
inbox_steer_check() {  # <window> <task>
  local w=$1 task=$2 action verb rec count tail40 reason='' ring_rc backend agent_state
  fm_task_inbox_due_action_to action "$STATE" "$task" || return 0
  verb=${action%% *}
  [ "$verb" != quiet ] || return 0
  if [ "$verb" = retry ] && [ -n "$(status_own_open_decisions "$STATE/$task.status")" ]; then
    return 0
  fi
  rec=${action#* }
  count=
  case "$verb" in
    escalate)
      count=${rec##* }
      rec=${rec% *}
      ;;
  esac
  if [ "$verb" = stale-generation ]; then
    reason=$(fm_task_inbox_quarantine_stale "$STATE" "$task" "$w") || exit 1
    [ -z "$reason" ] || wake "$reason"
    return 0
  fi
  backend=$(window_backend "$w")
  agent_state=$(fm_backend_agent_state "$backend" "$w" 2>/dev/null || true)
  case "$agent_state" in
    dead|missing)
      if [ "$verb" = retry ]; then
        fm_task_inbox_clear_retry "$STATE" "$task" "$rec" || true
      else
        inbox_steer_escalate_unavailable "$w" "$task" "$rec"
      fi
      return 0
      ;;
  esac
  watcher_capture "$backend" "$w" 40 "$(window_label "$w")" || WATCHER_CAPTURE=
  tail40=$WATCHER_CAPTURE
  if window_is_busy "$w" "$tail40"; then
    [ "$verb" != retry ] || return 0
    if ! count=$(fm_task_inbox_record_busy "$STATE" "$task" "$rec"); then
      [ -f "$rec" ] || return 0
      reason="stale: $w (steering-inbox busy bookkeeping unwritable: ${rec%/*}/.busy-state cannot be written while $rec stays unhandled; inspect the inbox directory)"
    elif [ "$count" -ge "$(fm_task_inbox_busy_max)" ]; then
      reason="stale: $w (unread firstmate instruction: stuck-busy after $count consecutive busy-deferred due doorbells; $rec stays unhandled and no doorbell was typed; inspect the worker)"
    else
      return 0
    fi
    verb=escalate
  elif [ "$verb" != retry ] && ! fm_task_inbox_clear_busy "$STATE" "$task"; then
    reason="stale: $w (steering-inbox busy bookkeeping unwritable: ${rec%/*}/.busy-state cannot be reset after a non-busy check; inspect the inbox directory)"
    verb=escalate
  fi
  case "$verb" in
    ring)
      ring_rc=0
      fm_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")" || ring_rc=$?
      if [ "$ring_rc" -eq 3 ]; then
        inbox_steer_escalate_unavailable "$w" "$task" "$rec"
        return 0
      fi
      if ! fm_task_inbox_record_ring "$STATE" "$task" "$rec"; then
        if [ ! -f "$rec" ]; then
          fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
          return 0
        fi
        if [ -d "${rec%/*}" ]; then
          reason="stale: $w (steering-inbox ladder bookkeeping unwritable: ${rec%/*}/.ring-state cannot be written while $rec stays unhandled; the doorbell cannot advance toward escalation - inspect the inbox directory)"
          fm_wake_append stale "$w" "$reason" || exit 1
          wake "$reason"
        fi
      fi
      triage_log "steer-inbox delivery attempt: $task ${rec##*/} result=$ring_rc"
      ;;
    retry)
      ring_rc=0
      fm_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")" || ring_rc=$?
      if ! fm_task_inbox_clear_retry "$STATE" "$task" "$rec" && [ -f "$rec" ]; then
        reason="stale: $w (steering-inbox retry mark unremovable: ${rec%/*}/.retry-ring cannot be removed, so $rec would ring on every poll - inspect the inbox directory)"
        fm_wake_append stale "$w" "$reason" || exit 1
        wake "$reason"
      fi
      triage_log "steer-inbox retry ring: $task ${rec##*/} result=$ring_rc"
      ;;
    escalate)
      reason=${reason:-"stale: $w (unread firstmate instruction: $rec still unhandled after $count doorbell delivery attempts with an idle pane; inspect the worker)"}
      if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
        fm_task_inbox_due_action "$STATE" "$task" >/dev/null || true
        return 0
      fi
      fm_wake_append stale "$w" "$reason" || exit 1
      if ! fm_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
        echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
        exit 1
      fi
      wake "$reason"
      ;;
  esac
}

# 0 (benign/absorb) if EVERY task in a no-verb "signal:" wake has positive work
# evidence; 1 otherwise. Each task may satisfy the authoritative working proof,
# or an eligible bare turn-end may use the opt-in pane-churn proof below.
#
# OFF unless the home creates config/turnend-churn-absorb. The first two proofs
# read a verdict the harness itself vouches for; this one infers execution from
# rendered bytes, which is weaker, so widening the absorb is a home's choice to
# make rather than a default every fleet inherits. With the flag absent this
# delegates to the unchanged all-tasks authoritative proof.
#
# It exists because the first two are unreachable for a harness whose semantic
# busy state has no verified source: bin/fm-crew-state.sh can only answer unknown
# for such an adapter, crew_is_provably_working is therefore never satisfiable,
# and every worker turn boundary surfaced a wake with nothing to act on - the cost
# scaling with the number of workers in flight. Pane churn needs no harness
# cooperation, so it restores the absorb branch for those adapters without
# fabricating a busy verdict any adapter has not earned.
#
# The evidence is the one the pane-staleness backbone below already trusts for
# liveness: this compares a fresh capture against the .hash- marker that backbone
# recorded on the previous poll, which is why the derivation lives here with the
# marker format rather than in the shared classifier. Absorbing here DEFERS a wake
# rather than swallowing it, and the deferral is BOUNDED: a task's turn-ends may
# ride churn evidence for at most FM_TURNEND_CHURN_ABSORB_SECS, tracked per window
# in .churn-since-, after which the wake surfaces and the window restarts. The
# bound is what keeps churn from muting supervision outright. A pane that renders
# continuously - a clock, a spinner, a shell heartbeat, a harness that leaves a
# background renderer alive after its agent yields - never presents the two
# identical consecutive hashes the staleness backbone needs either, so without the
# bound a worker that had genuinely stopped behind such a renderer would be
# deferred here forever with no fallback path left to surface it. Churn and
# staleness read the same pane, so neither can be the other's only backstop.
# Within the bound, an ordinary crew that stops renders nothing more, its pane
# hash stops moving, and the staleness backbone surfaces it within a couple of
# polls; any captain-relevant status verb still surfaces immediately through
# signal_files_actionable. That is why this widens the proof instead of
# bounding the wake rate, which would have suppressed genuinely stopped workers.
#
# Every negative outcome returns 1, so absence of evidence surfaces exactly as
# before: any batch that references a secondmate, an unresolvable task, a task
# with no uniquely attributable recorded endpoint, no previous hash to compare
# against (nothing has been polled yet), a capture that fails or comes back empty,
# an exhausted deferral bound, and of course an unchanged pane. Any .status file
# also returns 1: an authored append is content the
# supervisor may need to read, so only the mechanical turn-end marker gets the
# fallback.
#
# NOT a pure read: one bounded pane capture per referenced task that lacks
# authoritative proof. Once EVERY task passes, each churn-proven pane's prior
# .stale- classification and wedge-escalation count are cleared because churn
# begins a new quiet interval; retaining either would make the new interval
# inherit the prior one. Reached only for a non-afk, no-captain-verb signal, so
# it never runs on the ordinary per-wake path.
signal_turnend_panes_churned() {  # <file> ...
  [ -e "$CONFIG/turnend-churn-absorb" ] || return 1
  local f base task meta kind w key backend label terminal prev now since now_s absorb_secs marker age
  local rec_task task_index i j count hash_file hash_bytes created now_hash
  local max_absorb_secs=9223372036854775807
  local -a signal_tasks=() signal_statuses=() snapshot_tasks=() snapshot_kinds=()
  local -a snapshot_windows=() snapshot_keys=() snapshot_backends=() snapshot_labels=()
  local -a signal_indexes=() churn_indexes=() churned_keys=() missing_keys=() created_keys=()
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     return 1 ;;
      *.turn-ended) task=${base%.turn-ended}; kind=turn-ended ;;
      *)            return 1 ;;
    esac
    [ -n "$task" ] || return 1
    task_index=-1
    for ((i = 0; i < ${#signal_tasks[@]}; i++)); do
      [ "${signal_tasks[$i]}" = "$task" ] && { task_index=$i; break; }
    done
    if [ "$task_index" -lt 0 ]; then
      signal_tasks+=("$task")
      [ "$kind" = status ] && signal_statuses+=(1) || signal_statuses+=(0)
    elif [ "$kind" = status ]; then
      signal_statuses[task_index]=1
    fi
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    rec_task=${meta##*/}
    rec_task=${rec_task%.meta}
    kind=$(fm_meta_get "$meta" kind)
    backend=$(fm_backend_of_meta "$meta")
    if [ "$backend" = orca ]; then
      terminal=$(fm_meta_get "$meta" terminal)
      w=${terminal:-$(fm_meta_get "$meta" window)}
    else
      w=$(fm_meta_get "$meta" window)
    fi
    key=
    [ -n "$w" ] && window_key_to key "$w"
    label="fm-$rec_task"
    snapshot_tasks+=("$rec_task")
    snapshot_kinds+=("$kind")
    snapshot_windows+=("$w")
    snapshot_keys+=("$key")
    snapshot_backends+=("$backend")
    snapshot_labels+=("$label")
  done
  # These linear lookups deliberately support stock macOS Bash 3.2.57, enforced
  # by macos-stock-bash, and this repository uses no associative arrays in bin/
  # or tests/. A batch is normally one to three tasks and captures dominate its
  # cost; indexed lookup is the upgrade path if coalesced batches grow large.
  for task in "${signal_tasks[@]}"; do
    task_index=-1
    for ((i = 0; i < ${#snapshot_tasks[@]}; i++)); do
      [ "${snapshot_tasks[$i]}" = "$task" ] && { task_index=$i; break; }
    done
    [ "$task_index" -ge 0 ] || return 1
    w=${snapshot_windows[$task_index]}
    key=${snapshot_keys[$task_index]}
    [ -n "$w" ] && [ -n "$key" ] || return 1
    count=0
    for ((j = 0; j < ${#snapshot_keys[@]}; j++)); do
      [ "${snapshot_keys[$j]}" = "$key" ] && count=$((count + 1))
    done
    [ "$count" -eq 1 ] || return 1
    signal_indexes+=("$task_index")
  done
  for task_index in "${signal_indexes[@]}"; do
    [ "${snapshot_kinds[$task_index]}" != secondmate ] || return 1
  done
  for ((i = 0; i < ${#signal_tasks[@]}; i++)); do
    task=${signal_tasks[$i]}
    crew_is_provably_working "$task" && continue
    task_index=${signal_indexes[$i]}
    churn_indexes+=("$task_index")
  done
  [ "${#churn_indexes[@]}" -gt 0 ] || return 0
  [[ $TURNEND_CHURN_ABSORB_SECS =~ ^[1-9][0-9]*$ ]] || return 1
  if [ "${#TURNEND_CHURN_ABSORB_SECS}" -gt "${#max_absorb_secs}" ] \
    || { [ "${#TURNEND_CHURN_ABSORB_SECS}" -eq "${#max_absorb_secs}" ] \
      && [[ $TURNEND_CHURN_ABSORB_SECS -gt $max_absorb_secs ]]; }; then
    return 1
  fi
  absorb_secs=$((10#$TURNEND_CHURN_ABSORB_SECS))
  for task_index in "${churn_indexes[@]}"; do
    w=${snapshot_windows[$task_index]}
    key=${snapshot_keys[$task_index]}
    backend=${snapshot_backends[$task_index]}
    label=${snapshot_labels[$task_index]}
    hash_file="$STATE/.hash-$key"
    hash_bytes=$(LC_ALL=C wc -c 2>/dev/null < "$hash_file") || return 1
    hash_bytes=${hash_bytes//[[:space:]]/}
    [ "$hash_bytes" = 32 ] || return 1
    prev=$(cat "$hash_file" 2>/dev/null) || return 1
    [[ $prev =~ ^[0-9a-f]{32}$ ]] || return 1
    watcher_capture "$backend" "$w" 40 "$label" || return 1
    now=$WATCHER_CAPTURE
    [ -n "$now" ] || return 1
    hash_pane_to now_hash "$now"
    [ "$now_hash" != "$prev" ] || return 1
    churned_keys+=("$key")
  done
  # Enforce the deferral bound BEFORE any .stale- state is touched, so a wake that
  # surfaces here leaves the staleness backbone's own classification alone.
  now_s=$(date +%s)
  for key in "${churned_keys[@]}"; do
    marker="$STATE/.churn-since-$key"
    if [ ! -e "$marker" ]; then
      [ ! -L "$marker" ] || return 1
      missing_keys+=("$key")
      continue
    fi
    since=$(cat "$marker" 2>/dev/null) || return 1
    [[ $since =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    if [ "${#since}" -gt "${#now_s}" ] \
      || { [ "${#since}" -eq "${#now_s}" ] && [[ $since > $now_s ]]; }; then
      return 1
    fi
    age=$((10#$now_s - 10#$since))
    if [ "$age" -ge "$absorb_secs" ]; then
      rm -f "$marker"
      return 1
    fi
  done
  for key in "${missing_keys[@]+"${missing_keys[@]}"}"; do
    marker="$STATE/.churn-since-$key"
    if (set -C; printf '%s' "$now_s" > "$marker") 2>/dev/null; then
      created_keys+=("$key")
      continue
    fi
    for created in "${created_keys[@]+"${created_keys[@]}"}"; do
      rm -f "$STATE/.churn-since-$created"
    done
    return 1
  done
  for key in "${churned_keys[@]}"; do
    if ! rm -f "$STATE/.stale-$key" "$STATE/.wedge-escalations-$key"; then
      for created in "${created_keys[@]+"${created_keys[@]}"}"; do
        rm -f "$STATE/.churn-since-$created"
      done
      return 1
    fi
  done
  return 0
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    fm_backend_target_of_meta_to w "$meta" || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Print the oldest structurally valid ACTIONABLE row in a local secondmate's
# foreign queue. A stale recheck that explicitly identifies itself as a declared
# external-wait pause is not evidence that the mate's wake loop is stuck: the
# pause cadence already owns that bounded visibility, and blocked waits remain
# actionable because they do not carry this declaration. This is a read-only
# observation: the receiving home owns acknowledgement and this parent never
# changes the row or the foreign queue.
secondmate_oldest_queue_row() {  # <queue-path>
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    function declared_external_pause(kind, payload) {
      return kind == "stale" \
        && payload ~ /^stale: .*\(paused [0-9]+s, awaiting external - declared (pause,|paused\))/
    }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ \
      && !declared_external_pause($3, $5) {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# 0 iff <task> is demonstrably inside an active turn, through the watcher's own
# busy-state knowledge: an exact busy verdict from the semantic contract, bounded
# by the same BUSY_TURN_MAX_SECS that stops a busy pane from proving liveness
# forever. A mate mid-turn has not stopped draining its queue - it simply drains
# between turns - so this gate, not the elapsed interval, is what separates a
# healthy mate from a frozen wake loop. The bound is measured on <idle>, how long
# the queue's drain position has not moved, because a mate's turns end in its own
# home and this home holds no completed-turn evidence to age them by
# (busy_turn_over_age, whose spawn-record fallback would age every mate from its
# launch). Any absence of proof (no window, a failed capture, an idle or unknown
# verdict, a queue frozen past the bound) is NOT an active turn, so a frozen
# queue still escalates.
secondmate_in_active_turn() {  # <window> <idle>
  local w=$1 idle=$2 tail40
  [ -n "$w" ] || return 1
  [ "$idle" -lt "$BUSY_TURN_MAX_SECS" ] || return 1
  watcher_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" || return 1
  tail40=$WATCHER_CAPTURE
  window_is_busy "$w" "$tail40"
}

# Set SECONDMATE_BUSY_CLASS to the first token of the semantic busy
# classification for <window>: busy, idle, unknown, or dead. Capture failure and
# a missing window are unknown, never idle. Empty inbox and a fresh watcher
# beacon are not consulted. Call it directly, never in $(...), so its pane
# capture runs in the watcher's own shell.
SECONDMATE_BUSY_CLASS=
secondmate_busy_class() {  # <window>
  local w=$1 task meta tail40 verdict
  SECONDMATE_BUSY_CLASS=unknown
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -z "$w" ] || [ -z "$task" ] || [ ! -f "$meta" ]; then
    return 0
  fi
  watcher_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" || return 0
  tail40=$WATCHER_CAPTURE
  verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  SECONDMATE_BUSY_CLASS=${verdict%% *}
}

# 0 iff a child ring is authorized: exact idle, a live agent, and a composer
# that is not proven pending. Busy, unknown, dead, missing, and pending
# composer all refuse, so a Kimi or Claude pane without an exact idle
# verdict is never typed into.
secondmate_idle_ring_safe() {  # <window>
  local w=$1 backend agent_state cstate
  [ -n "$w" ] || return 1
  secondmate_busy_class "$w"
  [ "$SECONDMATE_BUSY_CLASS" = idle ] || return 1
  backend=$(window_backend "$w")
  agent_state=$(fm_backend_agent_state "$backend" "$w" 2>/dev/null || true)
  [ "$agent_state" = alive ] || return 1
  cstate=$(fm_backend_composer_state "$backend" "$w" "$(window_label "$w")" 2>/dev/null) || cstate=unknown
  [ "$cstate" != pending ] || return 1
  return 0
}

# Write one fire-and-forget drain steer and ring the child's doorbell. The
# steer carries the same from-firstmate fire-and-forget carrier fm-send uses
# for a secondmate (marker, then delivery=<16-hex-id>, then the text), so the
# mate reads it as a parent request that expects no reply, never as captain
# intervention. The worker's ordinary wake-handling turn drains its own home's
# wake queue; this parent never rewrites that foreign queue. 0 iff the ring
# call returned 0.
secondmate_ring_to_drain() {  # <task> <window>
  local task=$1 w=$2 rec backend delivery_id
  backend=$(window_backend "$w")
  delivery_id=$(LC_ALL=C od -An -v -tx1 -N 8 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$delivery_id" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#delivery_id}" -eq 16 ] || return 1
  rec=$(fm_task_inbox_write "$STATE" "$task" \
    "${FM_FROMFIRST_MARK}delivery=${delivery_id} Drain pending rows in this home's wake queue, then resume idle supervision." \
    fire-and-forget) || return 1
  fm_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")"
}

# Surface one durable parent check when the foreign queue's drain position has
# not moved for the bounded interval. The progress marker records that position
# as the same epoch-sequence row identity the stall receipts use, so the timer
# restarts whenever a different row becomes the oldest actionable one - as the
# mate drains, and as a queue reprovisioned under the same task id starts its
# own generation of rows at whatever sequence it restarts, and neither is a
# continued no-progress episode; row creation time belongs to that identity but
# never to the interval. A moved position ends an alerted episode and starts a
# new observation interval, so a newly-oldest row cannot alert immediately while
# a later genuine freeze remains visible. A mate demonstrably inside an active
# turn defers its escalation, but only while this same interval is under
# BUSY_TURN_MAX_SECS, so a turn that never ends cannot hide a frozen queue.
# A mate whose busy class is exactly idle, whose agent is alive, and whose
# composer is not pending is rung once so its own home can drain, and the
# parent notification is withheld until that same row stays frozen for another
# stall interval. Unknown, busy-over-bound, and ring-unsafe panes keep the
# parent alarm. Empty inbox and a fresh child beacon are not idle proof.
# Receipts close the append-before-marker crash window without changing the
# foreign queue.
secondmate_wake_stall_tick() {
  local now=$(( $(date +%s) )) threshold=$SECONDMATE_WAKE_STALL_SECS
  local meta task kind remote_host home queue row epoch seq row_key marker progress_marker ring_marker progress observed_at observed_key
  local receipt receipt_dir notify_key queued idle reason episode_alerted already_rung w
  # Endpoint metadata admits this queue-loop check; secondmate-liveness owns registered mates whose endpoint is missing or dead.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    fm_meta_get_to kind "$meta" kind
    [ "$kind" = secondmate ] || continue
    fm_meta_get_to remote_host "$meta" remote_host
    [ -z "$remote_host" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    fm_meta_get_to home "$meta" home
    [ -n "$home" ] || continue
    [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || continue
    [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$task" ] || continue
    queue="$home/state/.wake-queue"
    row=$(secondmate_oldest_queue_row "$queue")
    marker="$STATE/.secondmate-wake-stall-$task"
    progress_marker="$STATE/.secondmate-wake-progress-$task"
    ring_marker="$STATE/.secondmate-wake-ring-$task"
    receipt_dir="$STATE/.secondmate-wake-stall-receipts/$task"
    if [ -z "$row" ]; then
      rm -f "$marker" "$progress_marker" "$ring_marker"
      if [ -e "$receipt_dir" ] || [ -L "$receipt_dir" ]; then
        [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
        rm -rf -- "$receipt_dir" || return 1
      fi
      continue
    fi
    IFS=$(printf '\t') read -r epoch seq _row_kind _row_key _row_payload <<EOF
$row
EOF
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    row_key="$epoch-$seq"
    episode_alerted=0
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
      episode_alerted=1
    fi
    progress=$(cat "$progress_marker" 2>/dev/null || true)
    observed_at=${progress%%[[:space:]]*}
    observed_key=${progress#*[[:space:]]}
    if [ "$observed_at" = "$progress" ]; then
      observed_key=
    else
      observed_key=${observed_key%%[[:space:]]*}
    fi
    case "$observed_at" in ''|*[!0-9]*) observed_at= ;; esac
    case "$observed_key" in ''|*[!0-9-]*) observed_key= ;; esac
    if [ -z "$observed_at" ] || [ -z "$observed_key" ] \
      || [ "$now" -lt "$observed_at" ] || [ "$row_key" != "$observed_key" ]; then
      fm_wake_secondmate_progress_marker_write "$task" "$now" "$row_key" || return 1
      [ "$episode_alerted" -eq 0 ] || rm -f "$marker" || return 1
      rm -f "$ring_marker" || return 1
      continue
    fi
    [ "$episode_alerted" -eq 0 ] || continue
    idle=$((now - observed_at))
    [ "$idle" -ge "$threshold" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    ! secondmate_in_active_turn "$w" "$idle" || continue
    already_rung=0
    if [ -e "$ring_marker" ] || [ -L "$ring_marker" ]; then
      [ -f "$ring_marker" ] && [ ! -L "$ring_marker" ] || return 1
      [ "$(cat "$ring_marker" 2>/dev/null || true)" = "$row_key" ] && already_rung=1
    fi
    if [ "$already_rung" -eq 0 ] && secondmate_idle_ring_safe "$w"; then
      if secondmate_ring_to_drain "$task" "$w"; then
        fm_wake_secondmate_ring_marker_write "$task" "$row_key" || return 1
        fm_wake_secondmate_progress_marker_write "$task" "$now" "$row_key" || return 1
        continue
      fi
    fi
    receipt="$receipt_dir/$row_key"
    if [ "$(cat "$receipt" 2>/dev/null || true)" = "$row_key" ]; then
      fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
      continue
    fi
    notify_key="secondmate-wake-loop-$task-$row_key"
    reason="check: secondmate wake-loop stalled: mate=$task row=$seq idle=${idle}s"
    queued=$(fm_wake_queued_keys check)
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      fm_wake_append check "$notify_key" "$reason" || return 1
    fi
    fm_wake_secondmate_stall_receipt_write "$task" "$row_key" || return 1
    fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
    wake "$reason"
  done
  return 0
}

# The ordinary-supervision half of the secondmate liveness guarantee, paired
# with bin/fm-bootstrap.sh's session-start sweep over the shared library in
# bin/fm-secondmate-liveness-lib.sh (which owns the state contract, the remote
# probe rules, the kill ordering, and the guarded relaunch). On a bounded
# cadence each registered mate's recorded endpoint is probed once; only a
# recovery-grade `dead` or `missing` verdict relaunches, every relaunch
# (success or failure) becomes exactly one durable `check` wake row, and every
# other verdict lands only in the triage log. The tick finishes every mate
# before it wakes once on the first outcome, so one dead mate never delays
# another's recovery; the drain surfaces every queued row. A mate that keeps
# dying is parked after SECONDMATE_LIVENESS_MAX_ATTEMPTS ledgered attempts
# inside SECONDMATE_LIVENESS_WINDOW_SECS: the bound marker wakes once, further
# probes stay silent, and a later live probe ledgers a `rearmed` row and clears
# the marker so a manually recovered mate rejoins the guarantee with a full
# budget. The per-mate liveness lock serializes this tick against a concurrent
# session-start sweep, so neither side can kill or re-probe an endpoint the
# other is mid-relaunch on. An optional <on-mate> command runs before each mate,
# so a caller can report progress through a pass whose bounded relaunches
# together outlast the watcher's grace.
secondmate_liveness_tick() {  # [on-mate]
  local on_mate=${1:-} tick_age
  local tick_marker="$STATE/.secondmate-liveness-tick"
  age_of_to tick_age "$tick_marker"
  [ "$tick_age" -ge "$SECONDMATE_LIVENESS_SECS" ] || return 0
  touch "$tick_marker" || return 1
  local now=$(( $(date +%s) )) meta id kind
  local bound_marker attempts notify_key reason queued err first_reason='' failed=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    fm_meta_get_to kind "$meta" kind
    [ "$kind" = secondmate ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ -z "$on_mate" ] || "$on_mate"
    fm_secondmate_liveness_lock "$id" || continue
    fm_secondmate_liveness_probe "$meta" "$id" poll
    bound_marker="$STATE/.secondmate-relaunch-bound-$id"
    reason='' notify_key='' err=''
    case "$FM_SM_LIVE_STATUS" in
      relaunchable)
        if [ -e "$bound_marker" ] || [ -L "$bound_marker" ]; then
          :
        elif ! attempts=$(fm_secondmate_liveness_recent_attempts "$id" "$SECONDMATE_LIVENESS_WINDOW_SECS"); then
          err="relaunch ledger is unreadable; endpoint left $FM_SM_LIVE_STATE"
        elif [ "$attempts" -ge "$SECONDMATE_LIVENESS_MAX_ATTEMPTS" ]; then
          if printf '%s\t%s\n' "$now" "$FM_SM_LIVE_STATE" > "$bound_marker"; then
            reason="check: secondmate $id auto-relaunch paused after $SECONDMATE_LIVENESS_MAX_ATTEMPTS attempts in ${SECONDMATE_LIVENESS_WINDOW_SECS}s; endpoint still $FM_SM_LIVE_STATE - relaunch it manually or retire the route"
            notify_key="secondmate-relaunch-bound-$id"
          else
            err="relaunch park marker could not be written; endpoint left $FM_SM_LIVE_STATE"
          fi
        elif fm_secondmate_liveness_relaunch "$meta" "$id" "$SECONDMATE_LIVENESS_TIMEOUT"; then
          reason="check: secondmate $id auto-relaunched after $FM_SM_LIVE_CAUSE ($FM_SM_LIVE_WHERE)"
          notify_key="secondmate-relaunch-$id-$now"
        elif [ "$FM_SM_LIVE_STATUS" = skipped ]; then
          err=$FM_SM_LIVE_REASON
        else
          reason="check: secondmate $id auto-relaunch failed after $FM_SM_LIVE_CAUSE: $(fm_sm_live_first_line "$FM_SM_LIVE_OUT")"
          notify_key="secondmate-relaunch-failed-$id-$now"
        fi
        ;;
      alive)
        if [ -e "$bound_marker" ] || [ -L "$bound_marker" ]; then
          if ! fm_secondmate_liveness_ledger_add "$id" rearmed; then
            err="relaunch ledger is unwritable; auto-relaunch stays paused"
          elif ! rm -f "$bound_marker"; then
            err="relaunch park marker could not be cleared; auto-relaunch stays paused"
          else
            triage_log "secondmate $id live again; auto-relaunch pause cleared"
          fi
        fi
        ;;
      skipped)
        triage_log "secondmate $id liveness: $FM_SM_LIVE_REASON"
        ;;
    esac
    if [ -n "$reason" ]; then
      queued=$(fm_wake_queued_keys check)
      if printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1 \
        || fm_wake_append check "$notify_key" "$reason"; then
        [ -n "$first_reason" ] || first_reason=$reason
      else
        err="check wake row could not be queued: $reason"
      fi
    fi
    fm_secondmate_liveness_unlock "$id"
    if [ -n "$err" ]; then
      echo "watcher: secondmate $id liveness: $err" >&2
      triage_log "secondmate $id liveness error: $err" || true
      failed=1
    fi
  done
  [ -z "$first_reason" ] || wake "$first_reason"
  [ "$failed" -eq 0 ]
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past PAUSE_RESURFACE_SECS the pane wakes once per window rather than every
# poll. An optional <scope> binds that cadence to its current declaration; callers
# without a scoped declaration keep the timestamp body. Shared by the
# declared-pause absorb and the worktree-write deferral so the two cadences cannot
# drift apart; each caller owns its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline. An optional
# <min-age> replaces the cadence as the absorb-age gate for one call (0 lets a
# declared `until` time that has just passed re-surface at once), while the
# throttle keeps the cadence between repeats.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason> [scope] [min-age]
  local win=$1 throttle=$2 age=$3 reason=$4 scope=${5-} min_age=${6:-$PAUSE_RESURFACE_SECS}
  if [ -z "$scope" ] || [ ! -e "$throttle" ] \
    || [ "$(cat "$throttle" 2>/dev/null || true)" = "$scope" ]; then
    [ "$age" -ge "$min_age" ] || return 0
    [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fi
  fm_wake_append stale "$win" "$reason" || exit 1
  if [ -n "$scope" ]; then printf '%s' "$scope" > "$throttle"; else date +%s > "$throttle"; fi
  wake "$reason"
}

# Defer ONE wedge escalation for a pane that went quiet while its own task
# worktree is demonstrably still being written (crew_worktree_written_since in
# fm-classify-lib.sh). The pane and the run step both say nothing is happening;
# the worktree says otherwise, and files appearing in it is the harder signal to
# fake, so the escalation is deferred rather than fired. Deliberately a DEFERRAL,
# not a cancellation: the idle timer restarts, so the next window probes again,
# and a .writing-since-<key> marker ages the whole deferral chain so the pane
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed above - literally the same bounded cadence a declared pause
# uses, throttled by its own .writing-resurfaced-<key> marker - and a crew whose
# worktree churns without real progress cannot stay invisible. The escalation
# counter is left alone: it is neither advanced (this is not an escalation) nor
# reset (a later genuine escalation must still carry the demand-deep-inspection
# history it had already earned).
wedge_defer_writing() {  # <window> <since-file> <triage-label> <idle-age>
  local win=$1 since_file=$2 label=$3 age=$4 key wsf wage
  window_key_to key "$win"
  wsf="$STATE/.writing-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.writing-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, writing its worktree for ${wage}s, rechecked on a long cadence not a wedge; confirm the writes are real progress)"
  triage_log "absorbed $label (worktree written since the idle window opened, idle ${age}s): $win"
}

# One wait record, carrying every field a recheck needs to be correct. Emitting
# them together is the point: a recheck that names the wrong human, or asks for
# an action that does not clear the lane, points the reader away from the only
# person who can end the wait, so a new kind of evidence must not be able to
# reach wedge_defer_wait without deciding all of them.
#   <kind>       what the evidence IS, as the recheck names it.
#   <subject>    WHO the wait is on, in the recheck's own words.
#   <whom>       `captain` when that subject is the captain, `supervisor` when
#                it is firstmate itself, `external` otherwise; this is what
#                applies the away-posture rule below, which only `captain` takes.
#   <action>     the one thing that clears the lane.
#   <age-record> the file whose mtime is when this wait started, or EMPTY when
#                the wait has no written record. Empty is a real answer, not a
#                degraded one: a gate the pipeline parked was never written down
#                by the worker, so there is no honest age to publish and the
#                deferral publishes none.
# The fields are joined with US (\037) rather than TAB because TAB is an IFS
# WHITESPACE character: consecutive tabs collapse under `read`, so a record with
# an empty middle field would not fail to parse, it would SHIFT every later field
# left into another field's position. US is not IFS whitespace, so consecutive
# delimiters yield genuinely empty fields and the record either parses as written
# or fails the deferral's guard.
wait_record() {  # <kind> <subject> <whom> <action> <age-record>
  printf '%s\037%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" "$5"
}

# The evidence that a quiet pane is a BOUNDED WAIT rather than a wedge suspect,
# read at the one moment it decides anything: when an escalation is about to
# fire. Two records answer it, and they are independent: the worker's own status
# line - a declared `paused:` external wait, or a verified `captain-held`
# transfer - and, when that line explains nothing, the crew's authoritative
# current state.
#
# The generated brief promises that declaring one buys the long recheck cadence
# instead of a wedge, and the wedge timer is reachable while that declaration
# stands: a crew that declares a wait and then has an active run or busy pane
# attributed to it is handed to the timer as provably-working, and the timer then
# escalates on elapsed idle time alone. The declaration is what the worker said
# about its OWN silence, so it outranks a liveness verdict that only says
# something is running.
#
# A declared clearing time that has ALREADY passed (`paused: ... until <t>`) is
# not evidence: the wait the worker described is over, so it no longer explains
# the silence, and the pane keeps the unchanged schedule. The records are read in
# this order rather than pooled because the routing already guarantees it is the
# right one: a pane whose last line is `paused:` or `captain-held:` reaches this
# timer only through pause_state_class answering `working`, so its crew state is
# a running step, never a parked gate.
#
# The second record is OFF unless the home creates config/wedge-defer-parked-gate,
# and that one guard is what makes an unconfigured home's behaviour identical to
# having no second record at all: it is read before the fold, so no fold or
# crew-state read is spent, no wait record exists to defer on, no recheck wording
# is reachable, and the lane keeps the unchanged escalation schedule, reason and
# demand-deep-inspection wording. Unlike the status line, which is the worker's
# own declaration about its own silence, this record is derived from a pipeline's
# gate state, so which lanes lose the ladder for it is a home's choice to make
# rather than a default every fleet inherits - the same reason
# config/turnend-churn-absorb gates its own widened absorb.
#
# The second record takes TWO signals, and needs both. The crew's authoritative
# current state must be a no-mistakes gate whose answer is owed by a HUMAN
# (crew_gate_awaits_human_decision in fm-classify-lib.sh, minted from the
# findings table's `action` column by position), AND the task's own decision fold
# must still hold an open `needs-decision` record whose key is `nm-<run>-<step>`
# for the run that verdict reports. The gate's table alone says only that the
# answer is owed by a human; the open decision bound to that run is the positive
# evidence that firstmate was actually told about THIS gate and has not answered
# yet, which is what makes the lane's quiet a wait rather than a suspected wedge.
# An open decision under any other key - an unrelated question never closed - is
# not that evidence, and neither is a verdict that names no run. The wait is owed
# by firstmate, not the captain: ask-user findings are routed to firstmate, which
# decides most of them itself, and one it escalates becomes a captain-held
# transfer that the first record above already catches. So the away-posture
# silence does not apply to it: under away posture the supervision branch is the
# actor allowed to answer it, and it is rechecked on the long cadence throughout.
# The two signals come apart in both directions, and the ladder is kept in each:
#   - the decision was ANSWERED and the crewmate has not yet relayed it with
#     `axi respond`: the gate is still reported parked and still carries the
#     ask-user row, but `fm-send --resolve-key` wrote the closing `resolved` line
#     at answer time, so the fold is empty and what is outstanding is the
#     crewmate's OWN next move;
#   - the crewmate parked at a human-owed gate and went quiet before escalating
#     it at all: nobody was ever told, so there is no wait to defer to.
# A `blocked` record does not count: a blocker is not an unanswered gate decision
# and a different action clears it. A gate awaiting the CREWMATE's own answer is
# deliberately NOT evidence either: a crewmate that goes quiet before answering
# its own gate is exactly the wedge this ladder exists to catch, so those keep
# the unchanged schedule, reason and demand-deep-inspection wording.
# Nothing here weakens detection for a pane with no wait at all - their
# escalation schedule, reason and wording are untouched, and every way this
# signal can come back empty (an unreadable status file, a fold with nothing
# open, a key convention nobody followed) escalates on the unchanged schedule
# rather than losing the ladder. The status-line and fold reads are file reads;
# the crew-state read is the costly one (it may make a bounded no-mistakes call),
# so it is taken only behind a first fold read that finds some open
# `needs-decision` at all, and only in the at-threshold branch - at most once per
# window per STALE_ESCALATE_SECS, never on an ordinary poll.
wedge_wait_evidence() {  # <task> -> one wait_record on stdout
  local task=$1 last statusf run wait_rc
  [ -n "$task" ] || return 1
  statusf="$STATE/$task.status"
  status_declared_wait_line_to last "$statusf"
  if status_is_captain_held "$last"; then
    wait_record 'captain-held' 'awaiting the captain - verified hold transfer' \
      captain 'answer the held decision or release the hold' "$statusf"
    return 0
  fi
  if status_is_paused "$last"; then
    # A declared condition that stopped holding (a passed until, a finished
    # heavy job) no longer explains the quiet; a plain pause still does.
    wait_rc=0
    status_declared_wait_check "$last" || wait_rc=$?
    [ "$wait_rc" -ne 1 ] || return 1
    wait_record 'declared wait' 'awaiting external' \
      external 'confirm the wait still holds' "$statusf"
    return 0
  fi
  [ -e "$CONFIG/wedge-defer-parked-gate" ] || return 1
  if status_has_open_needs_decision "$statusf" \
    && run=$(crew_gate_awaits_human_decision "$task") \
    && status_has_open_needs_decision "$statusf" "$run"; then
    wait_record 'verified wait at a parked gate' "awaiting firstmate's ask-user decision" \
      supervisor "decide the gate's ask-user finding and relay the decision to the crewmate" ''
    return 0
  fi
  return 1
}

# Defer ONE wedge escalation for a pane whose wait record explains the quiet
# (wedge_wait_evidence above). Deliberately the same shape as
# wedge_defer_writing: a DEFERRAL, not a cancellation, so the idle timer restarts
# and the next window probes the evidence again - a wait that ends is escalating
# again within one STALE_ESCALATE_SECS, which is why the worst-case detection
# time for a pane that stops waiting does not move.
# Every word of the recheck that could be wrong per kind of evidence - the human
# it names, the action it asks for, the age it publishes - is READ FROM THE
# RECORD rather than re-derived here, so this function cannot word one kind of
# wait as another.
# A wait with a written record is aged from that file, which is when the worker
# wrote the line - anchored there rather than on a per-window marker for the same
# reason handle_paused_stale is: an idle pane churns its display (a clock, a
# token counter), and a marker this deferral kept touching would let that churn
# reset the cadence. A wait with NO written record publishes no age at all: the
# quiet window is the only clock in hand and this deferral resets it on every
# pass, so a number read from it would never grow and would tell a supervisor
# that a day-old gate opened four minutes ago. The bounded re-surface still
# fires, governed by its own throttle instead of by a wait age.
# A CAPTAIN-facing wait is not rechecked at all while the away-posture record
# exists: the one human who can answer it is away, the return brief already lists
# it, and every other captain-facing path in this file absorbs it silently for
# that reason (handle_paused_stale, surface_nonterminal_stale,
# captain_call_stale_bound). That absorb arms no throttle and deliberately
# leaves the idle timer alone: a `captain` whom is minted only by the
# captain-held arm of wedge_wait_evidence, which returns before the
# wedge-defer-parked-gate flag test and therefore before any decision-fold or
# current-state read, so the only read that repeats under the away record is the
# one status-line read that predates this deferral. There is nothing costly to
# throttle there, so the recheck owed on return stays owed in full the moment the
# record is archived rather than starting a cadence nobody could act on. The
# costly parked-gate consult is owed to the supervisor instead, never silenced
# here, and its own deferral restarts the timer below.
# The escalation counter is left alone, exactly as the write deferral leaves it:
# this is not an escalation, and a later genuine one must keep the
# demand-inspection history it had already earned.
wedge_defer_wait() {  # <window> <since-file> <triage-label> <idle-age> <wait-record>
  local win=$1 since_file=$2 label=$3 age=$4 record=$5
  local kind subject whom action anchor key mtime wage min_age waited us ok
  us=$(printf '\037')
  IFS=$us read -r kind subject whom action anchor <<EOF
$record
EOF
  # Enforce the whole of the record's own contract here, which the US delimiter
  # now makes checkable: `kind`, `subject`, `whom` and `action` are each a field
  # the recheck prints and must be non-empty, `whom` is exactly one of the three
  # values the record contract names, only `anchor` may legitimately
  # be empty, and the record holds exactly four delimiters - a surplus one is
  # visible because `read` puts everything past the last field into `anchor`.
  # A record that fails any of these is refused rather than deferred: deferring
  # is what takes the ladder away, so the unparseable case must fall back to the
  # escalation the caller was about to make.
  ok=1
  case "$whom" in
    captain|supervisor|external) ;;
    *) ok=0 ;;
  esac
  case "$anchor" in
    *"$us"*) ok=0 ;;
  esac
  if [ -z "$kind" ] || [ -z "$subject" ] || [ -z "$action" ]; then ok=0; fi
  if [ "$ok" -eq 0 ]; then
    triage_log "refused a malformed wait record for $label: $win"
    return 1
  fi
  window_key_to key "$win"
  if [ "$whom" = captain ] && away_record_present; then
    triage_log "absorbed $label ($kind, never rechecked while the away-posture record exists): $win"
    return 0
  fi
  mtime=''
  [ -n "$anchor" ] && mtime=$(stat_mtime "$anchor")
  case "$mtime" in
    ''|*[!0-9]*)
      # No readable record of when the wait started - either none exists, or the
      # status file could not be read. Age from the quiet window already in hand
      # and publish nothing: anchoring on the current time instead would
      # recompute the wait age as 0 at every threshold, and the bounded
      # re-surface could then never fire at all - the one outcome this deferral
      # must not produce.
      wage=$age; min_age=0; waited=''
      ;;
    *)
      wage=$(( $(date +%s) - mtime ))
      [ "$wage" -ge 0 ] || wage=0
      min_age=$PAUSE_RESURFACE_SECS; waited=", waiting ${wage}s"
      ;;
  esac
  clear_write_tracking "$key"
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.waiting-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s${waited} - $kind, $subject, rechecked on a long cadence not a wedge; $action)" \
    '' "$min_age"
  triage_log "absorbed $label ($kind explains the quiet, idle ${age}s): $win"
  return 0
}

# Drop a window's write-deferral chain wherever its stale bookkeeping resets, so
# the bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished one cannot make the next deferral resurface immediately.
clear_write_tracking() {  # <window-key>
  local key=$1
  fm_rm_present "$STATE/.writing-since-$key" "$STATE/.writing-resurfaced-$key"
}

# The question the wedge timer never asked before it alarmed: is there still an
# agent here to BE wedged? A wedge is something stuck that might recover, so
# re-alarming it earns its cost; an agent that is gone never moves again, its pane
# never churns, the idle timer never resets, and the escalate path below clears its
# own timer and re-arms with nothing bounding the count.
# docs/architecture.md owns that contract and why only these two verdicts license
# it; what the code needs stated here is the rest.
#
# fm_backend_agent_state (bin/fm-backend.sh) owns the vocabulary and the
# process-level proof behind it. Every verdict short of proof - `alive`,
# `ambiguous`, `unreadable`, `unverified`, or a read that failed outright - keeps
# the unchanged escalation schedule, reason and count, so this narrows WHICH panes
# escalate and never how loudly the ones that still do.
#
# Deliberately NOT a deferral like the two above it. They restart the idle timer
# because the pane might still be working; this is terminal for as long as the
# endpoint stays gone, because there is nothing left to re-probe on a cadence and a
# repeat is exactly the noise it exists to stop. WHICH verdict fired is named for
# the same reason wedge_wait_evidence names its kind of wait: the two ask the supervisor
# for different things.
#
# The marker is owned entirely by this function and records the verdict together
# with the agent incarnation it was reported for: the task's per-incarnation busy
# gen (bin/fm-busy-lib.sh, state/<id>.busy-gen), which changes exactly when the
# agent is replaced, so a repeat is absorbed only while BOTH still match, a read
# that stops being gone still drops it, and no other reset site has to know this
# file exists. The incarnation half re-arms a relaunch: a successor's own later
# death is reported in full even when its dead display hashes identically to the
# reported one. Only when no incarnation token is readable for the task does the
# pane hash stand in as the discriminator - an unreadable token must never mean
# re-report on every threshold, so that fallback keeps today's hash-keyed absorb,
# with the residual that a record-less successor dying into a byte-identical dead
# display stays absorbed. Under one unchanged incarnation a dead pane's static
# display absorbs on every threshold either way.
# Returns 0 when it has handled the window, 1 to escalate on the unchanged path.
wedge_dead_record() {  # <window> <since-file> <triage-label> <idle-age> <pane-hash> <task>
  local win=$1 since_file=$2 label=$3 age=$4 hash=$5 task=$6 key marker agent_state detail reason gen id
  window_key_to key "$win"
  marker="$STATE/.dead-reported-$key"
  agent_state=$(fm_backend_agent_state "$(window_backend "$win")" "$win" 2>/dev/null) || agent_state=unreadable
  case "$agent_state" in
    dead) detail='the endpoint is still there with no agent running in it' ;;
    missing) detail='the recorded endpoint is gone' ;;
    *) rm -f "$marker"; return 1 ;;
  esac
  # Re-arm the idle timer on BOTH paths below, so the backend probe above stays on
  # its once-per-STALE_ESCALATE_SECS budget instead of running on every poll.
  date +%s > "$since_file"
  id=$hash
  if gen=$(fm_busy_current_gen "$STATE" "$task"); then
    id=$gen
  fi
  if [ "$(cat "$marker" 2>/dev/null || true)" = "$agent_state $id" ]; then
    triage_log "absorbed $label (agent $agent_state, already reported once, idle ${age}s): $win"
    return 0
  fi
  reason="stale: $win (idle ${age}s, agent $agent_state - $detail, so this is not a wedge; reported once and not re-escalated while it stays that way - reconcile this record, and check for unlanded work before any cleanup)"
  # Append before the marker, for the reason stale_wait_record gives: a marker
  # written ahead of a failed append outlives it, and the next sighting would then
  # absorb the retry - the one way this bound could swallow the report outright
  # rather than deliver it once.
  fm_wake_append stale "$win" "$reason" || exit 1
  printf '%s %s' "$agent_state" "$id" > "$marker"
  clear_write_tracking "$key"
  wake "$reason"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Shared by both places a hash
# can be absorbed this way: the plain non-terminal path, and the
# stale_is_terminal-overridden path (a captain-relevant status-log line that an
# active run/busy pane outranked).
# The wait-evidence consult (wedge_wait_evidence), the worktree write probe, and
# the dead-record probe (wedge_dead_record) run ONLY here, inside the
# at-threshold branch that is about to escalate: at most one each per window per
# STALE_ESCALATE_SECS, never on an ordinary poll. The crew-state read
# wedge_wait_evidence may take under config/wedge-defer-parked-gate keeps that
# same bound however long the wait lasts, because the deferral it feeds restarts
# the idle timer like every other deferral below; an unconfigured home never
# reaches that read at all. The wait consult runs first, because a pane that can
# account for its own quiet has nothing to prove through its worktree. The dead-record probe
# runs last of the three, so the two cheaper deferrals keep the panes they
# already own on their existing bounded cadences and only a pane that would
# otherwise alarm pays for a backend read.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <task> <pane-hash>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 task=$5 hash=$6 since age n reason evidence
  fm_file_text_to since "$since_file" || true
  case "$since" in
    ''|*[!0-9]*)
      # Publish the repaired timer only after its old write-deferral chain is
      # gone, so observers cannot mistake a new idle window for the old chain.
      clear_write_tracking "$(window_key "$win")"
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      fm_epoch_seconds_to age
      age=$(( age - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        if evidence=$(wedge_wait_evidence "$task") &&
           wedge_defer_wait "$win" "$since_file" "$label" "$age" "$evidence"; then
          return 0
        fi
        if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
          wedge_defer_writing "$win" "$since_file" "$label" "$age"
          return 0
        fi
        if wedge_dead_record "$win" "$since_file" "$label" "$age" "$hash" "$task"; then
          return 0
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        clear_write_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff the last completed turn or explicit native-harness
# progress is at least BUSY_TURN_MAX_SECS old. Progress is actual observed model
# or tool activity, never a timer or a busy footer. It does not emit a wake or
# change semantic busy state. Before either marker exists, age the spawn record.
# The caller checks busy state and routes a crossed bound through inspection.
busy_turn_over_age() {  # <task>
  local task=$1 f progress age
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  progress="$STATE/$task.progress"
  if [ -f "$progress" ] && [ "$progress" -nt "$f" ]; then f="$progress"; fi
  age_of_to age "$f"
  [ "$age" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Record one wake the watcher acknowledged itself because the task's declared
# wait still holds (status_declared_wait_check in fm-classify-lib.sh owns what
# holds). state/.quiet-wait-acks is the durable, bounded audit of those
# self-acknowledgements, one "<epoch>\t<task>\t<turn-ended|stale>\t<condition>"
# row each; nothing reads it back to decide anything.
QUIET_WAIT_ACKS_MAX_LINES=${FM_QUIET_WAIT_ACKS_MAX_LINES:-1000}
quiet_wait_record() {  # <task> <turn-ended|stale> <condition>
  local log="$STATE/.quiet-wait-acks" lines
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" >> "$log" 2>/dev/null || return 0
  lines=$(wc -l < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt "$QUIET_WAIT_ACKS_MAX_LINES" ]; then
    tail -n $(( QUIET_WAIT_ACKS_MAX_LINES / 2 )) "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
    rm -f "$log.tmp" 2>/dev/null || true
  fi
}

# Quiet-wait proof for a no-verb signal batch (signal_declared_wait_holds): 0
# after recording each acknowledged turn-end, 1 when the batch must surface.
signal_quiet_wait_ack() {  # <file> ...
  local held task cond win key base
  held=$(signal_declared_wait_holds "$@") || return 1
  # Prove every lane before recording any acknowledgement in a mixed batch.
  while IFS=$'\t' read -r task cond; do
    [ -n "$task" ] || continue
    [ -f "$STATE/$task.meta" ] || return 1
    win=$(fm_backend_target_of_meta "$STATE/$task.meta") || return 1
    [ -n "$win" ] || return 1
    window_key_to key "$win"
    base=$(declared_wait_scope "$STATE" "$task")
    quiet_wait_lane_check "$win" "$key" "$task" "$base" || return 1
  done <<EOF
$held
EOF
  while IFS=$'\t' read -r task cond; do
    [ -n "$task" ] || continue
    quiet_wait_record "$task" turn-ended "$cond"
  done <<EOF
$held
EOF
  return 0
}

# Both new quiet acknowledgement paths require this same fresh proof: a live
# agent and a readable unchanged lane. Never cache liveness across turn ends.
# First sight initializes the baseline; later changed or unreadable fingerprints
# return nonzero. The caller decides how to surface the wake, and can use the
# shared fingerprint outputs and QUIET_WAIT_AGENT_STATE to explain it.
QUIET_WAIT_AGENT_STATE=
quiet_wait_lane_check() {  # <window> <window-key> <task> <declaration>
  QUIET_WAIT_AGENT_STATE=$(fm_backend_agent_state "$(window_backend "$1")" "$1" 2>/dev/null) \
    || QUIET_WAIT_AGENT_STATE=unreadable
  [ -n "$QUIET_WAIT_AGENT_STATE" ] || QUIET_WAIT_AGENT_STATE=unreadable
  if [ "$QUIET_WAIT_AGENT_STATE" = dead ] && queue_park_proven "$3"; then
    return 0
  fi
  [ "$QUIET_WAIT_AGENT_STATE" = alive ] || return 2
  recheck_baseline "$2" "$3" "$4" once
  declared_wait_compare "$STATE" "$2" "$3" "$4"
}

# A stopped queue worker is intentional only with this incarnation's park,
# its merge-result tag and the exact still-registered adopted queue source.
# No other dead or unreadable endpoint receives an exemption.
queue_park_proven() {  # <task>
  local cond line
  status_declared_wait_line_to line "$STATE/$1.status"
  status_wait_tag "$line" cond || return 1
  case "$cond" in merge-result:*) ;; *) return 1 ;; esac
  fm_procevent_merge_queue_park_matches "$STATE" "$1" "${cond#merge-result:}" "$SCRIPT_DIR/fm-procevent-merge-queue.sh"
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# captain-held transfer, and queue a recheck once every
# PAUSE_RESURFACE_SECS so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it reads crew state only for the lane fingerprint of a `paused:` wait,
# on first sight and when its recheck falls due. The re-surface age is anchored
# on the status file mtime, not a per-hash marker, so a churny idle pane (a
# ticking clock, a token counter) cannot keep resetting the cadence the way a
# hash-tied timer would. A due `paused:` recheck is first matched against that
# fingerprint (recheck_fingerprint_due); a recheck it does not absorb is queued
# by recheck_queue below, throttled by this window's own
# .paused-resurfaced-<key> marker, and delivered by recheck_flush together with
# every other due recheck. Advances the stale suppressor to <hash> and flags
# the key paused.
#
# The recheck distinguishes the declared dependency from a captain decision:
# the legacy external-wait wording for paused: (bin/fm-classify-lib.sh), and the
# captain themself for a verified hold. Only the captain-held verb takes the second
# wording; a caller that reached the bounded cadence off pause tracking alone, with
# no declaring verb left on the log, keeps the external-wait wording it always had.
# The reason carries @AGE@ in place of the wait's age, filled in at delivery so a
# recheck that waited for a warm supervisor still reports how old the wait is.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age detail reason declaration last until now min_age kind=due base
  local wait_rc=2 wait_cond='' agent_state='' compare_rc=0
  window_key_to key "$win"
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.idle-nudge-$key"
  clear_write_tracking "$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  now=$(date +%s)
  age=$(( now - mtime ))
  status_declared_wait_line_to last "$statusf"
  min_age=$PAUSE_RESURFACE_SECS
  declaration=$(declared_wait_scope "$STATE" "$task")
  base=$declaration
  # Quiet waits. While the away-mode daemon owns triage it classifies declared
  # waits itself, so this is normal-mode only. A holding machine-checkable
  # condition acknowledges the stale wake here unless the endpoint has no agent
  # or the lane reached the standing-waits ceiling; a tagged condition that
  # stopped holding, or a holding one whose agent is gone, is due at once.
  if ! afk_present && status_is_paused "$last" && ! status_wait_untagged "$last"; then
    wait_rc=0
    status_declared_wait_check "$last" "$now" wait_cond || wait_rc=$?
    if [ "$wait_rc" -eq 0 ]; then
      quiet_wait_lane_check "$win" "$key" "$task" "$base" || compare_rc=$?
      agent_state=$QUIET_WAIT_AGENT_STATE
    fi
  fi
  if [ "$wait_rc" -eq 0 ] && [ "$agent_state" = dead ] && queue_park_proven "$task"; then
    if [ "$(cat "$STATE/.quiet-wait-seen-$key" 2>/dev/null || true)" != "$declaration" ]; then
      quiet_wait_record "$task" stale "$wait_cond"
      printf '%s' "$declaration" > "$STATE/.quiet-wait-seen-$key" 2>/dev/null || true
    fi
    triage_log "acknowledged stale (parked queue wait holds: $wait_cond): $win"
    return 0
  fi
  if [ "$wait_rc" -eq 0 ] && [ "$agent_state" = alive ]; then
    # Quiet only the periodic reminder, never a changed or unreadable lane.
    if [ "$compare_rc" -eq 0 ] \
      && [ "$(declared_wait_unseen_age "$STATE" "$key" "$task" age_of)" -lt "$STANDING_WAITS_CEILING_SECS" ]; then
      if [ "$(cat "$STATE/.quiet-wait-seen-$key" 2>/dev/null || true)" != "$declaration" ]; then
        quiet_wait_record "$task" stale "$wait_cond"
        printf '%s' "$declaration" > "$STATE/.quiet-wait-seen-$key" 2>/dev/null || true
      fi
      triage_log "acknowledged stale (declared wait holds: $wait_cond): $win"
      return 0
    fi
    if [ "$compare_rc" -ne 0 ]; then
      recheck_baseline "$key" "$task" "$base" set "$DECLARED_WAIT_FP"
      reason="paused @AGE@s, awaiting external - the lane changed since its wait was last shown (${DECLARED_WAIT_CHANGES:-unreadable lane}); confirm the wait still holds"
      recheck_queue "$win" "$key" "$age" "$mtime" urgent "stale: $win ($reason)" "$declaration"
      return 0
    fi
  fi
  if [ "$wait_rc" -eq 0 ] && [ "$agent_state" != alive ]; then
    detail="paused, declared wait holds but endpoint liveness is not proven ($agent_state)"
    reason="paused @AGE@s, awaiting external ($wait_cond) - the wait still holds but the endpoint has no running agent proven ($agent_state); reconcile the worker, and check for unlanded work before any cleanup"
    declaration="$declaration:$agent_state"
    if [ "$(cat "$STATE/.paused-resurfaced-$key" 2>/dev/null || true)" != "$declaration" ]; then
      kind=until
      min_age=0
    fi
  elif [ "$wait_rc" -eq 1 ] && ! status_wait_untagged "$last"; then
    status_wait_tag "$last" wait_cond || wait_cond='malformed wait tag'
    detail="paused, declared wait condition no longer holds"
    reason="paused @AGE@s, awaiting external - its declared wait condition ($wait_cond) no longer holds; confirm the wait cleared"
    declaration="$declaration:lapsed"
    if [ "$(cat "$STATE/.paused-resurfaced-$key" 2>/dev/null || true)" != "$declaration" ]; then
      kind=until
      min_age=0
    fi
  elif status_is_captain_held "$last"; then
    if away_record_present; then
      triage_log "absorbed stale (captain-held, never rechecked while the away-posture record exists): $win"
      return 0
    fi
    kind=held
    detail="captain-held, awaiting the captain"
    reason="captain-held @AGE@s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold"
  elif status_wait_untagged "$last" && until=$(status_paused_until "$last"); then
    if [ "$now" -lt "$until" ] && [ "$age" -lt "$PAUSE_RESURFACE_SECS" ]; then
      recheck_baseline "$key" "$task" "$base" once
      triage_log "absorbed stale (paused until $(( until - now ))s from now, declared time not reached): $win"
      return 0
    elif [ "$now" -lt "$until" ]; then
      # A prose ETA is not positive machine-checkable evidence. Do not let an
      # unchanged fingerprint extend its periodic four-hour bound.
      kind=until
      detail="paused, declared time beyond recheck cadence"
      reason="paused @AGE@s, awaiting external - the declared time is beyond the recheck cadence; confirm the wait still holds"
    else
      # The declared time has passed: recheck now, once per declaration, then
      # hold the cadence. The worker named this moment, so its first recheck
      # is delivered when due rather than held for a warm supervisor or matched
      # against the lane's fingerprint; later ones are ordinary rechecks.
      detail="paused, declared time reached"
      reason="paused @AGE@s, awaiting external - the declared clearing time has passed, rechecked on a long cadence not a wedge; confirm the wait cleared"
      declaration="$declaration:due"
      if [ "$(cat "$STATE/.paused-resurfaced-$key" 2>/dev/null || true)" != "$declaration" ]; then
        kind=until
        min_age=0
      fi
    fi
  else
    detail="paused, awaiting external"
    reason="paused @AGE@s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds"
  fi
  if afk_present; then
    resurface_absorbed "$win" "$STATE/.paused-resurfaced-$key" "$age" "stale: $win (${reason//@AGE@/$age})" "$declaration" "$min_age"
    triage_log "absorbed stale ($detail, age ${age}s): $win"
    return 0
  fi
  if ! recheck_is_due "$key" "$age" "$declaration" "$min_age"; then
    [ "$kind" = held ] || recheck_baseline "$key" "$task" "$base" once
    triage_log "absorbed stale ($detail, age ${age}s): $win"
    return 0
  fi
  case "$kind" in
    due) recheck_fingerprint_due "$win" "$key" "$task" "$age" "$mtime" "$reason" "$declaration" "$base" ;;
    until) recheck_baseline "$key" "$task" "$base" refresh
      recheck_queue "$win" "$key" "$age" "$mtime" urgent "stale: $win ($reason)" "$declaration" ;;
    held) recheck_queue "$win" "$key" "$age" "$mtime" due "stale: $win ($reason)" "$declaration" ;;
  esac
}

# 0 when the declared-wait recheck for this window is due, resurface_absorbed's
# gate exactly: while the throttle is absent or names this same declaration, the
# wait must be at least <min-age> seconds old and its last recheck
# PAUSE_RESURFACE_SECS old; a declaration other than the one last rechecked is
# due at once.
recheck_is_due() {  # <key> <age> <scope> <min-age>
  local key=$1 age=$2 scope=$3 min_age=$4 throttle
  throttle="$STATE/.paused-resurfaced-$key"
  if [ ! -e "$throttle" ] || [ "$(cat "$throttle" 2>/dev/null || true)" = "$scope" ]; then
    [ "$age" -ge "$min_age" ] || return 1
    [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 1   # 999999 when no prior re-surface
  fi
  return 0
}

# Record the lane's declared-wait baseline (declared_wait_baseline_record in
# fm-classify-lib.sh) that a later recheck of this declaration is compared with.
# The away-mode daemon owns the baseline while it owns triage.
recheck_baseline() {  # <key> <task> <declaration> <once|refresh|set> [fingerprint]
  ! afk_present || return 0
  declared_wait_baseline_record "$STATE" "$@" || exit 1
}

# A due recheck of a paused: wait. It is absorbed without waking anyone when
# the lane's fingerprint matches the baseline taken when the wait was declared
# or last shown, until the lane has gone STANDING_WAITS_CEILING_SECS unseen;
# then it is queued for the standing-waits digest. A changed fingerprint is
# queued for delivery when due, naming what changed, and one that cannot be
# compared (no baseline, or an unreadable part) is queued as an ordinary recheck.
recheck_fingerprint_due() {  # <window> <key> <task> <age> <anchor> <reason> <scope> <declaration>
  local win=$1 key=$2 task=$3 age=$4 anchor=$5 reason=$6 scope=$7 base=$8 kind=due standing rc=0
  standing="paused @AGE@s, awaiting external - standing wait, nothing about it changed since it was last shown; confirm the wait still holds"
  declared_wait_compare "$STATE" "$key" "$task" "$base" || rc=$?
  case "$rc" in
    0)
      if [ "$(declared_wait_unseen_age "$STATE" "$key" "$task" age_of)" -lt "$STANDING_WAITS_CEILING_SECS" ]; then
        printf '%s\n%s\n%s\n%s\n' absorbed "$win" "$anchor" "stale: $win ($standing)" > "$STATE/.recheck-absorbed-$key" || exit 1
        printf '%s' "$scope" > "$STATE/.paused-resurfaced-$key"
        triage_log "absorbed paused recheck (fingerprint unchanged, age ${age}s): $win"
        return 0
      fi
      kind=standing
      reason=$standing
      ;;
    1)
      kind=urgent
      reason="paused @AGE@s, awaiting external - the lane changed since its wait was last shown (${DECLARED_WAIT_CHANGES:-status}); confirm the wait still holds"
      ;;
  esac
  recheck_baseline "$key" "$task" "$base" set "$DECLARED_WAIT_FP"
  recheck_queue "$win" "$key" "$age" "$anchor" "$kind" "stale: $win ($reason)" "$scope"
}

# Queue one declared-wait recheck that has fallen due, for recheck_flush to
# deliver, replacing any absorbed record for the window. The throttle advances
# when the recheck is queued, after the queued record is written, so one due
# recheck is queued once rather than on every poll while it waits for delivery.
# <kind> is `urgent` for a recheck delivered as soon as it is due, `standing`
# for one that reached STANDING_WAITS_CEILING_SECS unseen and brings the
# standing-waits digest with it, and `due` for one recheck_flush may hold for a
# warm supervisor.
recheck_queue() {  # <window> <key> <age> <age-anchor-epoch> <urgent|standing|due> <reason> <scope>
  local win=$1 key=$2 age=$3 anchor=$4 kind=$5 reason=$6 scope=$7
  printf '%s\n%s\n%s\n%s\n' "$kind" "$win" "$anchor" "$reason" > "$STATE/.recheck-due-$key" || exit 1
  rm -f "$STATE/.recheck-absorbed-$key"
  printf '%s' "$scope" > "$STATE/.paused-resurfaced-$key"
  triage_log "queued declared-wait recheck ($kind, age ${age}s): $win"
}

# Seconds since the supervisor last took a turn, as far as this watcher can
# tell: the later of this watcher's own start, since a supervisor arms the
# watcher as a turn ends, and Claude's turn-end auto-arm ledger, which also
# moves on a turn that raised no wake. A turn this watcher cannot see only makes
# the supervisor look colder, so a recheck waits longer, never less.
supervisor_turn_age() {
  local age claude
  age=$(( $(date +%s) - WATCH_STARTED_EPOCH ))
  claude=$(age_of "$STATE/.claude-autoarm-epoch")
  [ "$claude" -lt "$age" ] && age=$claude
  printf '%s' "$age"
}

# Deliver the queued declared-wait rechecks together (see RECHECK_WARM_SECS
# above for the schedule). `poll` runs once per poll after the pane scan and
# raises one wake for the whole set when any queued recheck is urgent, any lane
# has reached STANDING_WAITS_CEILING_SECS unseen, the supervisor is warm, or
# the away-mode daemon owns triage; otherwise it leaves the set queued. `ride`
# runs from wake() for any other wake and queues the whole set with it, so the
# supervisor reads every due recheck in a turn it is taking anyway. A recheck
# absorbed because nothing about its lane changed is delivered only in the
# standing-waits digest: once any absorbed or queued lane reaches the ceiling,
# every absorbed lane comes with it, so the standing waits are listed together
# once rather than each on its own day. A recheck whose wait is no longer
# declared, or is a captain-held transfer the away-posture record silences, is
# dropped instead. Each delivered row is its own durable stale record for its
# window, so acknowledgement and away-mode classification see exactly the rows
# a single recheck used to produce.
RECHECK_FLUSHING=0
WAKE_QUEUE_LOCK_HELD=0
recheck_flush() {  # <poll|ride>
  local mode=$1 append f key kind win anchor reason task last now fire=0 standing=0 urgent=0 i n=0 first=''
  local -a keys=() wins=() reasons=() held_keys=() held_wins=() held_reasons=()
  [ "$RECHECK_FLUSHING" -eq 0 ] || return 0
  now=$(date +%s)
  for f in "$STATE"/.recheck-due-* "$STATE"/.recheck-absorbed-*; do
    [ -f "$f" ] || continue
    case "$f" in
      */.recheck-due-*) key=${f##*/.recheck-due-} ;;
      *) key=${f##*/.recheck-absorbed-}
        [ ! -e "$STATE/.recheck-due-$key" ] || continue ;;
    esac
    kind='' win='' anchor='' reason=''
    { IFS= read -r kind; IFS= read -r win; IFS= read -r anchor; IFS= read -r reason; } 2>/dev/null < "$f" || true
    task=
    [ -z "$win" ] || task=$(window_to_task "$win" "$STATE")
    last=
    [ -z "$task" ] || last_status_line_to last "$STATE/$task.status"
    if [ -z "$task" ] || [ -z "$reason" ] || ! status_is_paused_or_captain_held "$last" \
      || captain_held_silenced "$last"; then
      rm -f "$f"
      triage_log "dropped queued declared-wait recheck (wait no longer declared): ${win:-$key}"
      continue
    fi
    case "$anchor" in ''|*[!0-9]*) anchor=$now ;; esac
    reason=${reason//@AGE@/$(( now - anchor ))}
    [ "$kind" = standing ] && standing=1
    [ "$(declared_wait_unseen_age "$STATE" "$key" "$task" age_of)" -ge "$STANDING_WAITS_CEILING_SECS" ] && standing=1
    if [ "$kind" = absorbed ]; then
      held_keys+=("$key"); held_wins+=("$win"); held_reasons+=("$reason")
      continue
    fi
    keys+=("$key"); wins+=("$win"); reasons+=("$reason")
    [ "$kind" = urgent ] && fire=1 && urgent=1
  done
  if [ "$standing" -eq 1 ]; then
    fire=1
    for i in "${!held_keys[@]}"; do
      keys+=("${held_keys[$i]}"); wins+=("${held_wins[$i]}"); reasons+=("${held_reasons[$i]}")
    done
  fi
  [ "${#keys[@]}" -gt 0 ] || return 0
  if [ "$mode" = poll ] && [ "$fire" -eq 0 ]; then
    if afk_present || [ "$(supervisor_turn_age)" -lt "${FM_TEST_RECHECK_WARM_SECS:-$RECHECK_WARM_SECS}" ]; then
      fire=1
    else
      return 0
    fi
  fi
  # A recheck that would fire on its own joins the wake batch instead, unless
  # one is urgent (a changed or unreadable lane, a declared time reached) or a
  # lane reached the standing-waits ceiling; the .recheck-due-* records stay
  # queued, so the batch wake carries them.
  # Signals run earlier in the cycle, so a due batch has already classified
  # them and this wake may close it; an urgent or standing recheck wakes
  # without touching the open batch's deadline.
  if [ "$mode" = poll ] && [ "$urgent" -eq 0 ] && [ "$standing" -eq 0 ]; then
    if ! wake_batch_due "declared-wait recheck: ${wins[0]}"; then
      WAKE_BATCH_HELD=1
      return 0
    fi
    wake_batch_close
  fi
  append=fm_wake_append
  [ "$WAKE_QUEUE_LOCK_HELD" -eq 0 ] || append=fm_wake_append_locked
  RECHECK_FLUSHING=1
  for i in "${!keys[@]}"; do
    if ! "$append" stale "${wins[$i]}" "${reasons[$i]}"; then
      [ "$mode" = poll ] && exit 1
      triage_log "could not queue declared-wait rechecks alongside another wake; they stay queued"
      return 1
    fi
    afk_present || date +%s > "$STATE/.recheck-surfaced-${keys[$i]}"
    rm -f "$STATE/.recheck-due-${keys[$i]}" "$STATE/.recheck-absorbed-${keys[$i]}"
    n=$((n + 1))
    [ -n "$first" ] || first=${reasons[$i]}
  done
  if [ "$mode" = ride ]; then
    triage_log "queued $n declared-wait recheck(s) with another wake"
    return 0
  fi
  if [ "$standing" -eq 1 ]; then
    first="$first [standing-waits digest: $n declared wait(s) queued with this wake]"
  elif [ "$n" -gt 1 ]; then
    first="$first [+$((n - 1)) more declared-wait recheck(s) queued with this wake]"
  fi
  wake "$first"
}

recheck_ride_along() {  # <reason>
  # Any wake carries a held rearm-resurface, as it does in this process.
  rm -f "$WAKE_BATCH_RESURFACE"
  recheck_flush ride
}

# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WAKE_PRE_OUTPUT_ACTION=recheck_ride_along

# 0 when routine wakes may be held in a batch: a window is configured and the
# away-mode daemon, which wants every wake, does not own triage.
wake_batch_on() {
  [ "$WAKE_BATCH_SECS" -gt 0 ] && ! afk_present
}

# 0 when a held item should wake now: batching is off or the open batch is
# WAKE_BATCH_SECS old. Otherwise it opens the batch if none is open and returns
# 1, and the caller holds its item and sets WAKE_BATCH_HELD. The batch start is
# durable state, so a restarted watcher, or one re-armed after an unrelated
# wake, keeps the same deadline. The batch closes when its own wake goes out
# (wake_batch_close) or a cycle holds nothing (main loop).
wake_batch_due() {  # <what-is-held>
  local since now
  wake_batch_on || return 0
  now=$(date +%s)
  since=$(cat "$WAKE_BATCH_MARKER" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      printf '%s\n' "$now" > "$WAKE_BATCH_MARKER" || return 0
      triage_log "opened ${WAKE_BATCH_SECS}s wake batch: $1"
      return 1
      ;;
  esac
  [ "$since" -le "$now" ] && [ $((now - since)) -lt "$WAKE_BATCH_SECS" ] && return 1
  return 0
}

wake_batch_close() {
  rm -f "$WAKE_BATCH_MARKER"
}

# 0 when the not yet classified span of <status-file> must wake at once:
# needs-decision, blocked, failed, a captain-held declaration, a pending-reply
# escalation, any other captain-relevant event except a plain done:, or a span
# that cannot be classified. working:, paused:, note:, resolved:, and done:
# lines are routine.
signal_span_urgent() {  # <status-file>
  local f=$1 record='' needs=0 rc events event
  status_span_first_actionable_record "$f" \
    "$(fm_wake_signal_seen_size "$STATE" "$f")" record needs watcher_beat
  rc=$?
  [ "$rc" -ne 2 ] && [ "$needs" != 1 ] || return 0
  [ "$rc" -eq 0 ] || return 1
  events=${record#*$'\t'}; events=${events#*$'\t'}
  while :; do
    event=${events%% ; *}
    [ "$(status_line_verb "$event")" = "done" ] || return 0
    case "$events" in *' ; '*) events=${events#* ; } ;; *) return 1 ;; esac
  done
}

# 0 when this cycle's changed signals (scan_signals rows) are all routine and
# the wake batch still holds them. A held file's seen markers do not move, so
# it is rescanned every cycle, by a restarted watcher too, and the batch wake,
# or an urgent line's wake before it, classifies and queues every held line.
signal_batch_hold() {  # <scan-signals-rows>
  local sf sig f files=''
  wake_batch_on || return 1
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    files="$files $(basename "$f")"
    case "$f" in *.status) ;; *) continue ;; esac
    if signal_span_urgent "$f"; then
      triage_log "urgent signal bypasses the wake batch: $f"
      return 1
    fi
  done <<EOF
$1
EOF
  wake_batch_due "signal:$files" && return 1
  WAKE_BATCH_HELD=1
  return 0
}

# 0 when the durable wake queue a rearm-resurface re-announces holds a row that
# must not wait for the wake batch: any row other than a signal row or a
# declared-wait recheck (a stale row whose reason starts with paused), a
# needs-decision row, or a row whose task's status log has a line the
# supervisor has not been shown yet that is needs-decision, blocked, failed,
# captain-held, or any other captain-relevant line except a plain done:. A log
# whose unshown lines cannot be read counts as urgent.
wake_queue_rows_urgent() {
  local kind key payload task lines line
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  while IFS=$(printf '\t') read -r _ _ kind key payload; do
    case "$payload" in needs-decision:*) return 0 ;; esac
    case "$kind" in
      signal) task=${key%.status}; task=${task%.turn-ended} ;;
      stale)
        case "$payload" in "stale: $key (paused "*) ;; *) return 0 ;; esac
        task=$(window_to_task "$key" "$STATE") ;;
      *) return 0 ;;
    esac
    [ -n "$task" ] || continue
    lines=$(status_new_lines_since_cursor "$STATE/$task.status") || return 0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_is_captain_held "$line" && return 0
      if status_is_captain_relevant "$line" && [ "$(status_line_verb "$line")" != "done" ]; then
        return 0
      fi
    done <<EOF
$lines
EOF
  done < "$FM_WAKE_QUEUE"
  return 1
}

# Retire every per-window recheck record whose window no longer declares a wait
# on this poll, so a lane that resumed, finished, or was torn down cannot leave
# a queued recheck, a fingerprint baseline, or an old delivery time behind for a
# later declaration.
recheck_sweep() {  # <space-delimited declared window keys>
  local declared=$1 f key
  for f in "$STATE"/.recheck-due-* "$STATE"/.recheck-absorbed-* "$STATE"/.recheck-fp-* "$STATE"/.recheck-surfaced-*; do
    [ -e "$f" ] || continue
    key=${f##*/.recheck-}
    key=${key#*-}
    case "$declared" in *" $key "*) continue ;; esac
    rm -f "$f"
  done
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's OWN declared external wait. Prints/queues
# nothing itself; it only chooses which absorber owns the crossed bound.
# 0 when the declared-pause cadence took the pane, 1 when the wedge timer did.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A `paused:` declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by re-surfacing it once per PAUSE_RESURFACE_SECS.
# A pane that declared nothing falls through to the shared wedge timer, which,
# in a home that armed config/wedge-defer-parked-gate, applies the same rule to
# the one wait a busy pane cannot declare: a validation gate of its own awaiting
# a supervisor decision that is still open also takes the bounded recheck rather
# than the ladder, because who owes that answer does not depend on what the pane
# is rendering, and the recheck names that supervisor and the action that clears
# it. An unconfigured home keeps the unchanged ladder there.
# Away mode remains daemon-owned and receives the undecorated wake identity for
# its own classification, which is why the declaration is read before the afk
# branch rather than after it.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5 key statusf declared line
  statusf="$STATE/$task.status"
  status_declared_wait_line_to line "$statusf"
  if status_is_paused_or_captain_held "$line"; then
    if afk_present; then
      # Away mode is daemon-owned, so this bound hands off the PLAIN wake identity
      # and lets the daemon classify the declaration itself - the undecorated
      # identity the rest of this function's contract promises. Running the wedge
      # timer here instead would decorate the wake as a possible wedge, and that
      # decoration overrides the daemon's own pause verdict for the pane: the
      # ladder then climbs on every re-arm, escalating a crew that declared the
      # wait itself once per FM_STALE_ESCALATE_SECS for as long as the wait lasts.
      # The one-shot is keyed on the DECLARATION (the status log's signature),
      # never on the pane hash: a busy pane's harness footer ticks on every
      # capture, so a hash-keyed one-shot would re-fire on every poll and the
      # daemon, which relaunches the watcher after each handled wake, would be
      # woken in a loop for the whole declared wait. The suppressor therefore
      # advances to the declaration rather than the hash, and the daemon is woken
      # once per distinct declaration. The wedge timer, escalation count and
      # write-deferral chain are cleared exactly as handle_paused_stale clears
      # them, so an undeclared busy phase that had already started the timer does
      # not resume its count the moment the declaration is lifted. Normal-mode
      # pause tracking stays unwritten here, exactly as the idle away-mode handoff
      # leaves it, because the daemon owns that bookkeeping.
      window_key_to key "$win"
      rm -f "$since_file" "$escalation_file"
      clear_write_tracking "$key"
      declared=$(declared_wait_scope "$STATE" "$task")
      status_declared_wait_line_to line "$statusf"
      if captain_held_silenced "$line"; then
        printf '%s' "$declared" > "$STATE/.stale-$key"
        triage_log "absorbed busy over-age pane (captain-held, never rechecked while the away-posture record exists): $win"
        return 0
      fi
      if [ "$(cat "$STATE/.stale-$key" 2>/dev/null || true)" != "$declared" ]; then
        fm_wake_append stale "$win" "stale: $win" || exit 1
        printf '%s' "$declared" > "$STATE/.stale-$key"
        wake "stale: $win"
      fi
      return 0
    fi
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$task" "$h"
  return 1
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key" \
    "$STATE/.quiet-wait-seen-$key" "$STATE/.quiet-wait-probe-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_write_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" \
    "$STATE/.waiting-resurfaced-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# A standing declaration is kept for every fm_backend_agent_state verdict.
# Only a working crew-state class outranks it. Dead and unknown liveness stay
# on the bounded recheck; issue 2713 does not invent prompt dead-worker surfacing.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class
  window_key_to key "$win"
  status_declared_wait_line_to last "$STATE/$task.status"
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  # Recover paused classification for a declared wait that authoritative crew state
  # could not name, including a mate's status-declared `captain-held` transfer,
  # which has no current-state mapping and so arrives as `none`. Without this
  # recovery that wait would be silenced by every caller rather than taking the
  # bounded re-surface cadence, and a forgotten declaration would rot invisibly.
  date +%s > "$recheck_file"
  printf 'paused'
}

# The two records of one ordinary crew wait, and why its stale alarm reads both.
#
# status_is_paused_or_captain_held reads the status LINE a worker wrote, which is
# the only record when the worker itself is waiting. It is not the only record
# there is: once firstmate hands work to the captain, the wait is written into the
# BACKLOG by bin/fm-captain-hold.sh, and the worker's last line stays whatever it
# was - routinely `done` after a PR delivery, which no line predicate can
# read as a wait. An alarm bounded only by the line therefore re-fires for the
# captain's whole thinking time, on exactly the work they already have in hand.
#
# `open` is that record's own read-only predicate and owns its semantics: exit 0
# still an open captain call, 1 not, 2 could not be established. Only a 0 bounds
# an alarm here, so an unreadable backlog, an incompatible or absent tasks-axi,
# and a row this home does not carry all keep alarming exactly as they do today -
# a wait this watcher cannot prove is not a wait.
#
# The read costs one subprocess and runs only where the watcher is about to
# alarm, so at most once per distinct stale hash per window, beside the crew-state
# read the same paths already pay. The secondmate stale gate deliberately runs
# before this bound and admits only status-declared waits: a backlog-only hold
# whose mate still says `working:` or `done:` does not reach this read. Reaching
# it would put backlog reads into windows deliberately skipped on ordinary polls.
STALE_WAIT_DECLARATION=

CAPTAIN_CALL_IDENTITY=

task_captain_call_open() {  # <task>
  local task=$1
  CAPTAIN_CALL_IDENTITY=
  [ -n "$task" ] || return 1
  CAPTAIN_CALL_IDENTITY=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" \
    open "$task" --identity 2>/dev/null) || return 1
  return 0
}

# The identity a re-surface throttle is bound to for a captain call, carrying
# the CALL's own lifecycle identity beside the status signature. The status log
# is not enough on its own: a task can be answered with `--release` and held
# again as a genuinely different call without any status append, and binding the
# throttle to the signature alone let the second call inherit the first one's
# silence and absorbed its first sight.
# That first sight is the one alarm this bound must never swallow - a decision
# waiting on the captain that is never surfaced is invisible, where a delivery
# announced twice is merely noise.
captain_call_declaration() {  # <task> <call-identity>
  printf 'captain-hold:%s:%s' "$2" "$(fm_wake_signal_sig "$STATE/$1.status" || true)"
}

# 0 when <declaration> has already been alarmed for this window inside the
# current PAUSE_RESURFACE_SECS. A pure read: recording an alarm is the caller's,
# so the throttle is never advanced by a sighting it just absorbed.
stale_wait_throttled() {  # <window-key> <declaration>
  local throttle="$STATE/.paused-resurfaced-$1"
  [ "$(cat "$throttle" 2>/dev/null || true)" = "$2" ] \
    && [ "$(age_of "$throttle")" -lt "$PAUSE_RESURFACE_SECS" ]
}

# The same bound, for a stale window whose last line IS captain-relevant. That
# line is real and its first sight must still reach the captain, but a delivery
# they are already holding has nothing new to say on the next pane tick.
# Sets STALE_WAIT_DECLARATION to the scope this sighting is bound to, and leaves
# it EMPTY when no open captain call bounds it, so an unheld delivery, a blocker,
# and a failure alarm exactly as they do today.
# Returns 0 to absorb this sighting; 1 to alarm, after which the caller records
# the throttle through stale_wait_record once its own wake append has succeeded.
# Record a fired wake against the bounded cadence, and ONLY after that wake was
# durably appended. A marker written ahead of the append outlives a failed one:
# the watcher exits with no wake queued, and the next sighting reads the fresh
# marker and absorbs the retry, which is the single way this bound could swallow
# an alarm outright rather than delay it.
stale_wait_record() {  # <window-key>
  [ -n "$STALE_WAIT_DECLARATION" ] || return 0
  printf '%s' "$STALE_WAIT_DECLARATION" > "$STATE/.paused-resurfaced-$1"
}

# Bound a due stale alarm for an ordinary crew task held for the captain.
# Backlog-only secondmate holds are outside this guard because the earlier gate
# preserves their no-backlog-read hot path.
# While the away-posture record exists the bound is absolute: an open captain
# call is never rechecked, whatever the throttle says, because nobody is there
# to answer it and the return brief lists it.
captain_call_stale_bound() {  # <window-key> <task>
  local key=$1 task=$2
  STALE_WAIT_DECLARATION=
  task_captain_call_open "$task" || return 1
  STALE_WAIT_DECLARATION=$(captain_call_declaration "$task" "$CAPTAIN_CALL_IDENTITY")
  away_record_present && return 0
  stale_wait_throttled "$key" "$STALE_WAIT_DECLARATION"
}

# Surface a stale pane no classifier could resolve, so firstmate inspects it: it
# may have finished through an interactive menu that wrote no status, be waiting on
# a decision, or be wedged. A standing declared wait is admitted by
# pause_state_class for every liveness verdict and takes handle_paused_stale, so a
# parked worker does not reach this path on the declaration or on liveness.
#
# The FIRST sight still wakes, keeping the inspect-an-inconclusive-state intent,
# and the throttle is read BEFORE anything is queued and advanced only by a wake
# that really fires - a throttle written by the wake it should have prevented, or
# read after that wake was already appended, bounds nothing.
# An ordinary crew wait recorded only in the backlog (see task_captain_call_open
# above) still bounds this path: the worker's last line is often a delivery, which
# no line predicate can read as a wait.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task bounded=1 throttled=1 reason
  window_key_to key "$win"
  task=$(window_to_task "$win" "$STATE")
  STALE_WAIT_DECLARATION=
  IDLE_PARK_REASON=
  if captain_call_stale_bound "$key" "$task"; then
    bounded=0
    throttled=0
  elif [ -n "$STALE_WAIT_DECLARATION" ]; then
    bounded=0
  elif stale_worker_dialog "$win"; then
    : # Preserve existing wait/hold bounds; a launch dialog is not an idle nudge.
  elif idle_park_nudge "$win" "$key" "$task"; then
    printf '%s' "$h" > "$STATE/.stale-$key"
    rm -f "$STATE/.stale-since-$key"
    clear_write_tracking "$key"
    return 0
  fi
  reason="stale: $win${IDLE_PARK_REASON:+ ($IDLE_PARK_REASON)}"
  if [ "$throttled" -ne 0 ]; then
    fm_wake_append stale "$win" "$reason" || exit 1
    stale_wait_record "$key"
  fi
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  clear_write_tracking "$key"
  if [ "$bounded" -eq 0 ]; then
    # A backlog hold is NOT a declared pause, and must not be dressed up as one:
    # the loop-top reconciliation and pause_state_class both read the status LINE,
    # so a .paused-* flag this line does not support would be cleared on the next
    # poll - taking the throttle with it - and would hand the declared-wait
    # cadence a declaration it was never given. Only the shared re-surface
    # marker is kept, which is the whole of what this bound needs.
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key"
  else
    clear_pause_state "$key"
  fi
  if [ "$throttled" -eq 0 ]; then
    triage_log "absorbed non-terminal stale (open captain call already re-surfaced this window): $win"
    return 0
  fi
  wake "$reason"
}

# On first-sight stale (or an expired nudge), use the selected backend's existing
# composer read to name a Pi worker launch dialog. This is not a per-poll probe;
# its viewport/sink contract belongs to fm-composer-lib.sh and the backend.
# Keep the semantic busy classifier separate: a dialog is a reason to inspect,
# not a new source of idle or busy authority.
stale_worker_dialog() {  # <window>, sets IDLE_PARK_REASON on a match
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL dialog=''
  window_resolve "$1"
  case "$WR_KIND:$WR_HARNESS" in ship:pi|ship:pi-signed|scout:pi|scout:pi-signed) ;; *) return 1 ;; esac
  if ! fm_composer_dialog_sink_prepare; then
    IDLE_PARK_REASON='could not prepare the Pi worker dialog check; inspect the worker'
    return 0
  fi
  fm_backend_composer_state "$WR_BACKEND" "$1" "$WR_LABEL" >/dev/null || true
  dialog=$(fm_composer_blocking_dialog_noted) || dialog=''
  fm_composer_dialog_sink_release
  [ -n "$dialog" ] || return 1
  IDLE_PARK_REASON="blocked on a prompt: $dialog; inspect the worker"
}

# The idle park nudge (knobs above). Its one marker, .idle-nudge-<key>, holds
# "nudged <epoch>" or "escalated <epoch>" for the latest nudge; a declared wait
# (handle_paused_stale, which every park produces) removes it. Returns 0 when
# the stale is absorbed (just nudged, or still inside the grace), 1 when it must
# surface, with IDLE_PARK_REASON naming an ignored nudge when there was one.
idle_park_nudge() {  # <window> <key> <task>
  local win=$1 key=$2 task=$3 marker verdict='' at='' now age send text
  IDLE_PARK_REASON=
  [ "$IDLE_PARK_NUDGE" != off ] && [ -n "$task" ] || return 1
  case "$(fm_meta_get "$STATE/$task.meta" kind)" in ship|scout) ;; *) return 1 ;; esac
  marker="$STATE/.idle-nudge-$key"
  now=$(date +%s)
  [ ! -f "$marker" ] || read -r verdict at < "$marker" || true
  case "$at" in ''|*[!0-9]*) verdict='' ;; esac
  if [ -n "$verdict" ] && [ $(( now - at )) -lt "$IDLE_PARK_REPEAT" ]; then
    age=$(( now - at ))
    if [ "$verdict" = nudged ] && [ "$age" -lt "$IDLE_PARK_GRACE" ]; then
      triage_log "absorbed non-terminal stale (park-or-finish nudge ${age}s ago, inside the grace): $win"
      return 0
    fi
    printf 'escalated %s\n' "$at" > "$marker"
    IDLE_PARK_REASON="idle ${age}s after being told to park or finish, with no declared wait; inspect the worker"
    return 1
  fi
  send=${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
  text="Firstmate: you have gone idle with no declared wait. If you are waiting on an external result, park as your brief's park rule says (details: FM_HOME=$(printf %q "$FM_HOME") $(printf %q "$SCRIPT_DIR/fm-park.sh") --help); otherwise finish the task, or append the status line your instructions define for where you are."
  FM_HOME="$FM_HOME" "$send" "$task" "$text" >/dev/null 2>&1 || return 1
  printf 'nudged %s\n' "$now" > "$marker"
  triage_log "idle park nudge sent (no declared wait): $win"
  return 0
}

# 0 when this window's nudge is still unanswered, with IDLE_PARK_NUDGE_AGE set to
# its age: an unchanged idle pane is absorbed inside the grace and surfaces
# through surface_nonterminal_stale after it, never through the wedge timer.
# One marker read per poll.
idle_park_nudge_open() {  # <window-key>
  local verdict='' at='' now
  IDLE_PARK_NUDGE_AGE=
  [ "$IDLE_PARK_NUDGE" != off ] || return 1
  [ -f "$STATE/.idle-nudge-$1" ] && read -r verdict at < "$STATE/.idle-nudge-$1" || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$verdict" = nudged ] || return 1
  fm_epoch_seconds_to now
  IDLE_PARK_NUDGE_AGE=$(( now - at ))
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local _ao_age
  age_of_to _ao_age "$1"
  echo "$_ao_age"
}

# age_of_to <output-variable> <file>: assigns what $(age_of <file>) would, with
# the one stat fork: 999999 when the mtime cannot be read or lies in the future.
age_of_to() {
  local _aot_m _aot_now
  fm_path_mtime_to _aot_m "$2" || { printf -v "$1" '%s' 999999; return 0; }
  fm_epoch_seconds_to _aot_now
  [ "$_aot_m" -le "$_aot_now" ] || { printf -v "$1" '%s' 999999; return 0; }
  printf -v "$1" '%s' "$(( _aot_now - _aot_m ))"
}

# Layer 2 + 3 signal scan: status files and turn-end markers.
# Each file is compared against its persisted reported signature in .seen-* rather
# than mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one and same-second writes cannot slip through a strict
# -nt comparison.
# Status signatures include observable file and readability state, while turn-end
# markers retain their size-and-mtime signature.
# A status file is asked the wider wake question instead, so it also stays quiet
# when the only bytes it grew past the classified offset are this home's own
# bookkeeping appends; fm_wake_signal_seen_current (bin/fm-wake-lib.sh) owns that
# rule and every other signature change still reads as unreported.
# Pure read: prints one "<seen-file>\t<sig>\t<file>" line per changed file.
# Each file's signature is observed once per scan, and that one observation is
# both the one compared and the one printed.
# The caller records reported state only after surfacing or intentional absorption,
# and commits a status classification position only after a successful span read.
scan_signals() {
  local f sig sf exclude marker
  # A remote mate's own parent channel is not a self-home task status log; the
  # home-shape-aware exclusion and its precedent live in
  # status_scan_parent_channel_exclude (fm-classify-lib.sh).
  exclude=$(status_scan_parent_channel_exclude "$STATE")
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ "$f" = "$exclude" ] && continue
    if [ ! -e "$f" ]; then
      case "$f" in *.status) [ -L "$f" ] || continue ;; *) continue ;; esac
    fi
    fm_wake_signal_sig_to sig "$f" || continue
    [ -n "$sig" ] || continue
    fm_wake_signal_seen_path_to sf "$STATE" "$f"
    case "$f" in
      *.status) fm_wake_signal_seen_current "$STATE" "$f" "$sig" && continue ;;
      *)
        fm_file_text_to marker "$sf" || true
        [ "$sig" = "$marker" ] && continue
        ;;
    esac
    printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
  done
  return 0
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  WAKE_QUEUE_LOCK_HELD=0
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason captured="" stranded="" unstarted=""
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
    # A stranded source or one whose launch never proved itself is the opposite
    # of a captured result: nothing is collecting for it. Headlining either as
    # a capture would present it as healthy, which is the shape of defect
    # these wakes exist to surface.
    case "$key" in
      procevent:*:stranded:*) stranded="$stranded $key" ;;
      procevent:*:launch-failed:*) unstarted="$unstarted $key" ;;
      *) captured="$captured $key" ;;
    esac
  done < <(fm_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check:"
  [ -z "$captured" ] || reason="$reason process-event result captured:$captured"
  if [ -n "$stranded" ]; then
    [ "$reason" = "check:" ] || reason="$reason;"
    reason="$reason process-event source stranded:$stranded"
  fi
  if [ -n "$unstarted" ]; then
    [ "$reason" = "check:" ] || reason="$reason;"
    reason="$reason process-event source failed to start:$unstarted"
  fi
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  WAKE_QUEUE_LOCK_HELD=1
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

# Stop-signal dispositions, installed with the EXIT trap below. HUP and TERM
# keep bash's native fatal-signal handling, which runs watcher_cleanup through
# the EXIT trap and then exits on every supported bash. A trap body such as
# 'exit 1' is not reliable for them: bash 5.2 runs a pending trap inside the
# parse of the next command substitution, the body then fails to parse ("trap:
# line 2: unexpected EOF while looking for matching `)'", or nothing at all),
# and the signal is consumed, so a stop request could leave this watcher
# polling forever while its stopper waits (fixed upstream in bash 5.3). Bash
# 3.2 holds HUP and TERM until a running command substitution's child exits, so
# fm_backend_capture pane reads go through watcher_capture instead. INT keeps
# its trap because bash ignores a direct SIGINT while a child runs.
watcher_stop_signals() {
  trap - HUP TERM
  trap 'exit 1' INT
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  # Defer stop signals only until the check's process group is recorded for
  # watcher_cleanup. Keep command substitutions out of this window: bash 5.2
  # can drop a trap that is pending when one is parsed (watcher_stop_signals).
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  watcher_stop_signals
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

FM_CAPTURE_OUTPUT=
WATCHER_CAPTURE=

fm_capture_output_cleanup() {
  [ -z "$FM_CAPTURE_OUTPUT" ] || rm -f -- "$FM_CAPTURE_OUTPUT"
  FM_CAPTURE_OUTPUT=
}

# watcher_capture: fm_backend_capture into WATCHER_CAPTURE with its exit status.
# The read runs as a waited background process group rather than inside $(...),
# so a stop is not held for a blocked read (watcher_stop_signals). The group is
# recorded like a check's, so watcher_cleanup stops a read still in flight. Its
# process group and the captured text are read in the shell where it can
# (fm_pid_pgid_to, fm_file_text_to), since every window's poll runs a capture.
watcher_capture() {  # <backend> <target> <lines> [expected-label]
  local rc pgid
  fm_capture_output_cleanup
  WATCHER_CAPTURE=
  FM_CAPTURE_OUTPUT=$(mktemp "$STATE/.fm-capture-output.XXXXXX") || return 1
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  # The group's stderr is redirected before the fork: bash 3.2 on macOS can
  # print a harmless "child setpgid ... Operation not permitted" race from the
  # child before the command's own redirections apply.
  set -m
  { fm_backend_capture "$@" < /dev/null > "$FM_CAPTURE_OUTPUT" & } 2>/dev/null
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  watcher_stop_signals
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  fm_pid_pgid_to pgid "$FM_ACTIVE_CHECK_PID"
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_capture_output_cleanup
    return 1
  fi
  wait "$FM_ACTIVE_CHECK_PID"
  rc=$?
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || { fm_capture_output_cleanup; return 1; }
  fm_file_text_to WATCHER_CAPTURE "$FM_CAPTURE_OUTPUT" || true
  fm_capture_output_cleanup
  return "$rc"
}

# 0 when any signaled status file carries a captain-relevant event in the bytes
# appended since this watcher last classified it. The start offset is the
# classified-position field in that file's .seen-* marker, and fm-classify-lib.sh's
# status-span contract owns both that format and what counts as actionable in
# the span. Reading the SPAN rather than the last line is what stops a later
# routine append - a `working:` note landing inside SIGNAL_GRACE below - from
# hiding the `needs-decision`, `blocked`, `failed`, or `done` event that arrived
# just before it: the .seen-* marker advances either way, so an event absorbed
# here is never re-read. Non-.status arguments (.turn-ended markers, which carry
# no verb) are skipped. A 1 here is NOT "benign" on its own: a no-verb signal,
# including a newly declared captain hold, still needs the authoritative working
# proof or the eligible opt-in bare turn-end pane-churn proof before it is benign.
# Also populates FM_SIGNAL_NEEDS_DECISION_FILES (space-separated status-file
# paths) with exactly the files whose newly classified span carries one of the
# decision-owned classes defined by the status-span contract, so the caller can
# route those - and only those - signal rows as main-only
# (docs/pi-supervision-branch.md). Stale and heartbeat rows retain their existing
# eligibility rules.
signal_files_actionable() {  # <status-file> ...
  local f task record rest endpoint ident needs_decision rc found=1
  FM_SIGNAL_SURFACE_ENDPOINTS=''
  FM_SIGNAL_NEEDS_DECISION_FILES=''
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || [ -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    record=''; needs_decision=0
    status_span_first_actionable_record "$f" \
      "$(fm_wake_signal_seen_size "$STATE" "$f")" record needs_decision watcher_beat
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      # Could not classify this log. Surface it rather than absorbing it, and
      # record NO classified endpoint for it below, so its content is classified
      # again once it is readable. The wake signature still advances, which is
      # what bounds this to one report per distinct file state.
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    FM_SIGNAL_SURFACE_ENDPOINTS="${FM_SIGNAL_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    if [ "$needs_decision" -eq 1 ]; then
      FM_SIGNAL_NEEDS_DECISION_FILES="${FM_SIGNAL_NEEDS_DECISION_FILES} ${f}"
    fi
    if [ "$rc" -eq 0 ] || [ "$needs_decision" -eq 1 ]; then
      found=0
    fi
  done
  return "$found"
}

# The secondmate status files in this signal batch whose newly classified span
# is routine - progress lines, acknowledgements of requests sent expecting
# only an acknowledgement, and repeated outcomes - printed as a space-separated
# list. Called only for a batch with no captain-relevant span, and reads
# exactly the bytes signal_files_actionable just classified (FM_SIGNAL_SURFACE_ENDPOINTS), so a
# line appended after that classification is never absorbed with it.
# bin/fm-classify-lib.sh's status_span_secondmate_routine owns which lines are
# routine, and bin/fm-pending-reply-lib.sh's fm_pending_reply_line_acks owns
# what an acknowledgement is. A file absent from the list keeps today's rule:
# a secondmate's status append always wakes (signal_crew_provably_working).
signal_secondmate_routine_files() {
  local f endpoint ident task out=''
  while IFS=$(printf '\t') read -r f endpoint ident; do
    [ -n "$f" ] || continue
    [ "$(_fm_status_kind "$f")" = secondmate ] || continue
    task=$(basename "$f"); task="${task%.status}"
    status_span_secondmate_routine "$f" "$(fm_wake_signal_seen_size "$STATE" "$f")" \
      "$endpoint" "$ident" fm_pending_reply_line_acks --on-record watcher_beat "$STATE" "$task" || continue
    out="$out $f"
  done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
  printf '%s' "$out"
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark each actionable status log through the endpoint captured by the heartbeat
# scan. Called after the backstop enqueues its wake, so the same events are not
# re-surfaced by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f endpoint ident rc=0
  while IFS=$(printf '\t') read -r f endpoint ident; do
    [ -n "$f" ] || continue
    if [ "$endpoint" = ERROR ]; then
      mark_surface_reported "$f" "$ident" || rc=1
    else
      mark_surfaced "$f" "$endpoint" "$ident" || rc=1
    fi
  done <<EOF
$FM_HEARTBEAT_SURFACE_ENDPOINTS
EOF
  return "$rc"
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any status log carries a captain-relevant event past the position already
# surfaced to firstmate (.hb-surfaced-<task>). It walks every log rather than only
# those whose LAST line looks captain-relevant, because the event this backstop
# most needs to catch is precisely one a later routine append has already moved
# past. Pure detect, no side effects: the caller enqueues first, then marks
# surfaced. Because every captain-relevant signal/stale already marks itself
# surfaced when it wakes firstmate, this normally finds nothing and the heartbeat
# is absorbed; it surfaces only an event the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task record rest endpoint ident rc found=1 sig marker exclude
  # Same self-home exclusion as scan_signals: a remote mate's parent channel
  # must not come back through the heartbeat fail-safe backstop.
  exclude=$(status_scan_parent_channel_exclude "$STATE")
  FM_HEARTBEAT_SURFACE_ENDPOINTS=''
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=$(basename "$f"); task="${task%.status}"
    record=$(status_span_first_actionable_record "$f" "$(hb_surfaced_offset "$task")" '' '' watcher_beat)
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      sig=$(status_observed_signature "$f")
      marker=$(_hb_surfaced_path "$task")
      status_presentation_marker_reported_matches "$marker" "$sig" && continue
      FM_HEARTBEAT_SURFACE_ENDPOINTS="${FM_HEARTBEAT_SURFACE_ENDPOINTS}${f}"$'\t'"ERROR"$'\t'"${sig}"$'\n'
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    FM_HEARTBEAT_SURFACE_ENDPOINTS="${FM_HEARTBEAT_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    [ "$rc" -eq 0 ] && found=0
  done
  return "$found"
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local WR_TASK WR_KIND WR_BACKEND WR_HARNESS WR_LABEL
  local windows=()
  while IFS= read -r w; do
    window_resolve "$w"
    b=$WR_BACKEND
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$WR_KIND" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  local waited_from=$SECONDS left
  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep what
      # the failed wait left of the budget, so the cycle still beats once per
      # POLL, and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      left=$((POLL - (SECONDS - waited_from)))
      [ "$left" -le 0 ] || sleep "$left"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS is validated here, at arm time, and an
# unusable value refuses to arm. This is deliberately NOT symmetry with the
# tunables above, which this watcher only defaults and never validates. The
# reason is specific: every supervision cycle runs `fm-procevent.sh reconcile`
# with its output and exit status discarded, and reconcile refuses an unusable
# window by name before it launches anything. Under this watcher that refusal
# is invisible - every cycle would exit early, no source would ever start, and
# the whole home would sit disarmed while presenting as supervised. A watcher
# that refuses to arm is loud through an existing, independent, proven path:
# the liveness guard's WATCHER DOWN banner in firstmate's own session. The
# message shape is reconcile's own, so the operator reads one refusal in both
# places. The refusal goes to stdout because bin/fm-watch-arm.sh relays the
# child's stdout and recognises `watcher: FAILED` as the typed failure line.
if ! fm_procevent_launch_confirm_seconds >/dev/null; then
  echo "watcher: FAILED - FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS must be whole seconds from $FM_PROCEVENT_LAUNCH_CONFIRM_MIN_SECONDS to $FM_PROCEVENT_LAUNCH_CONFIRM_MAX_SECONDS"
  exit 1
fi

# evict_stalled_holder <pid>: retire a live lock holder whose beacon stalled past
# WATCHER_STALL_BOUND. The pid is signalled only while it still proves the
# lock's own recorded identity (fm_watcher_lock_matches_pid: this home, this
# script, and the starttime+cmdline proof the lock carries), so a recycled pid
# is never touched; TERM only, never KILL, and never a name or pattern match.
# Succeeds only once the holder has exited within the bounded wait.
evict_stalled_holder() {
  local pid=$1 i=0
  fm_watcher_lock_matches_pid "$STATE" "$WATCH_PATH" "$pid" "$FM_HOME" || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  while [ "$i" -lt 50 ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! fm_pid_alive "$pid"
}

EVICTED_PID=
EVICTED_BEAT_AGE=
BEAT="$STATE/.last-watcher-beat"
while ! fm_lock_try_acquire "$WATCH_LOCK"; do
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        # One eviction per arm: the retry re-reads the lock and beacon, so a
        # holder that exited leaves a dead-pid lock the normal reclaim takes,
        # and a rival arm that won first reads as a fresh running watcher.
        if [ -z "$EVICTED_PID" ] && [ "$beat_age" -ge "$WATCHER_STALL_BOUND" ] \
          && evict_stalled_holder "$FM_LOCK_HELD_PID"; then
          EVICTED_PID=$FM_LOCK_HELD_PID
          EVICTED_BEAT_AGE=$beat_age
          continue
        fi
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
done
if [ -n "$EVICTED_PID" ]; then
  echo "watcher: replaced stalled pid $EVICTED_PID (beacon ${EVICTED_BEAT_AGE}s past hard bound ${WATCHER_STALL_BOUND}s)"
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ] \
  && [ "${FM_WATCH_FOREGROUND_CHECKPOINT:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
# The announced episode reopens only over a non-empty queue, so a stopped
# watcher's held rearm-resurface is inherited from its durable record.
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ] \
  && [ "${FM_WATCH_FOREGROUND_CHECKPOINT:-0}" != 1 ] \
  && [ -e "$WAKE_BATCH_RESURFACE" ]; then
  WATCHER_RESURFACE_HELD=1
fi
# Side-band ledger publication, detached from the poll loop.
#
# The poll loop owns the liveness beacon below, and fm-guard.sh reads that
# beacon's freshness as proof that supervision is alive. Publication is a
# side-band nicety bounded by FM_HOME_SUMMARY_TIMEOUT, but that bound is far
# larger than one poll - so running it inline puts up to a full publication
# deadline between two beacon touches and can starve the guard's grace. Failed
# attempts are durably paced by the publisher (see its header). Nothing
# in the poll depends on the ledger, so start it and move on: the beacon keeps
# advancing no matter how slow the publication is.
#
# The trade the detachment makes: a reader can briefly see a ledger that
# predates the event this poll just surfaced, where the inline call published
# first. Publication is eventually consistent by design, while beacon freshness
# is what the whole supervision chain rests on.
# shellcheck source=bin/fm-home-summary-refresh-lib.sh
. "$SCRIPT_DIR/fm-home-summary-refresh-lib.sh"
HOME_SUMMARY_PID=
home_summary_refresh_detached() {
  # Remember a coalesced signal even while a producer is alive or retry-paced.
  # The publisher claims requests under its cross-watcher publication lock.
  if [ "${1:-}" = event ]; then
    (umask 077; : > "$STATE/.home-summary-refresh.pending") || \
      triage_log "home-summary: could not record an owed event refresh"
  fi
  if [ -n "$HOME_SUMMARY_PID" ]; then
    if kill -0 "$HOME_SUMMARY_PID" 2>/dev/null; then
      return 0
    fi
    wait "$HOME_SUMMARY_PID" 2>/dev/null || true
    HOME_SUMMARY_PID=
  fi
  fm_home_summary_retry_due "$STATE" "$HOME_SUMMARY_INTERVAL" || return 0
  FM_HOME_SUMMARY_IF_IDLE=1 FM_HOME_SUMMARY_INTERVAL="$HOME_SUMMARY_INTERVAL" \
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort </dev/null >/dev/null 2>&1 &
  HOME_SUMMARY_PID=$!
}

RECONCILE_REQUEST_PID=
reconcile_requests_pending() {
  local request
  [ -d "$STATE/reconcile-notify" ] && [ ! -L "$STATE/reconcile-notify" ] || return 1
  for request in \
    "$STATE/reconcile-notify"/.processing-request-*.json \
    "$STATE/reconcile-notify"/request-*.json; do
    [ -f "$request" ] && [ ! -L "$request" ] && return 0
  done
  return 1
}

reconcile_requests_detached() {
  if [ -n "$RECONCILE_REQUEST_PID" ]; then
    if kill -0 "$RECONCILE_REQUEST_PID" 2>/dev/null; then
      return 0
    fi
    if ! wait "$RECONCILE_REQUEST_PID" 2>/dev/null; then
      triage_log "secondmate reconcile notify request deferred"
    fi
    RECONCILE_REQUEST_PID=
  fi
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-secondmate-reconcile.sh" process-requests </dev/null >/dev/null 2>&1 &
  RECONCILE_REQUEST_PID=$!
}

PR_POLL_CONTROL_LOCK=
PR_POLL_PUBLISH_LOCK=

pr_poll_control_release() {
  [ -z "$PR_POLL_CONTROL_LOCK" ] || fm_lock_release "$PR_POLL_CONTROL_LOCK" || return 1
  PR_POLL_CONTROL_LOCK=
}

pr_poll_publish_release() {
  [ -z "$PR_POLL_PUBLISH_LOCK" ] || fm_lock_release "$PR_POLL_PUBLISH_LOCK" || return 1
  PR_POLL_PUBLISH_LOCK=
}

# Wedge watchdog. A step boundary refreshes the beacon (watcher_beat below), so
# a beacon this watchdog has seen stay unchanged for WATCHER_STALE_GRACE means
# this watcher is stuck inside one step - for example blocked forever reading a
# command substitution whose pipe a detached grandchild still holds open, with
# no child left to time out. A small sibling process started once per watcher
# observes the beacon and never touches it, so only the loop's own beats keep
# it fresh. Once it has counted that same grace of its own intervals without a
# beat (so a host suspend that ages the beacon's wall-clock mtime never reads
# as a wedge), it stops exactly this watcher: TERM so
# watcher_cleanup releases the lock and publishes downtime recovery, then KILL
# if the step still holds it, which leaves a dead-pid lock the next arm
# reclaims. It signals only while this home's lock still names this watcher
# with its recorded identity, so it can never touch a successor or another
# home's watcher, and it exits as soon as this watcher is gone or the lock names
# another pid. An identity read that fails while the lock still names this live
# watcher (a fork refused under memory pressure) is retried next interval rather
# than ending the watchdog for the watcher's whole life.
WATCHDOG_PID=
WATCHDOG_INTERVAL=${FM_WATCHER_WATCHDOG_INTERVAL:-15}
case "$WATCHDOG_INTERVAL" in ''|*[!0-9]*|0) WATCHDOG_INTERVAL=15 ;; esac
watcher_watchdog_owns() {
  local owner_pid
  fm_file_text_to owner_pid "$WATCH_LOCK/pid" || true
  [ "$owner_pid" = "$WATCHER_PID" ] \
    && fm_watcher_lock_matches_pid "$STATE" "$WATCH_PATH" "$WATCHER_PID" "$FM_HOME"
}
# Evidence is best effort and independent of the signal path: even a ps that
# never exits cannot postpone TERM or the existing KILL grace. The snapshot is
# initiated at stop time; exiting/reparented children may already be absent.
watcher_watchdog_record_stop() {  # <still> <cycle> <last-beat> <observer-pid>
  local still=$1 cycle=$2 step=$3 observer=$4 descendants
  trap '' HUP INT TERM
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # The whole snapshot (including filtering) has a hard bound. Never log the
  # machine-wide ps output: keep only this watcher's descendants, omitting the
  # watchdog/diagnostic subtree, at most 32 rows and 240 command bytes per row.
  # shellcheck disable=SC2016 # The snapshot shell expands its own arguments.
  if ! descendants=$(fm_run_timed 1 bash -c '
    set -o pipefail
    LC_ALL=C ps -ax -o pid=,ppid=,etime=,args= | LC_ALL=C awk -v root="$1" -v observer="$2" '\''
      function walk(parent, child) {
        for (child = first[parent]; child; child = next_child[child]) {
          if (child == observer) continue
          if (count == 32) { truncated = 1; return }
          printf "%spid=%s ppid=%s elapsed=%s command=%s", sep, child, parent, elapsed[child], command[child]
          sep = "; "; count++
          walk(child)
          if (truncated) return
        }
      }
      $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 4 {
        pid = $1; parent = $2; elapsed[pid] = $3
        $1 = $2 = $3 = ""; sub(/^ +/, "")
        command[pid] = substr($0, 1, 240)
        gsub(/[[:cntrl:]]/, "?", command[pid])
        next_child[pid] = first[parent]; first[parent] = pid
      }
      END {
        walk(root)
        if (!count) printf "none observed"
        if (truncated) printf "; [truncated after 32 descendants]"
        printf "\n"
      }
    '\''
  ' _ "$WATCHER_PID" "$observer" 2>/dev/null); then
    descendants='unavailable (snapshot failed or exceeded 1s bound)'
  fi
  triage_log "watchdog: stopping wedged watcher pid $WATCHER_PID (beacon unchanged for ${still}s >= ${WATCHER_STALE_GRACE}s); cycle=${cycle:-unknown} last-beat=${step:-unavailable}; descendants-at-stop=[$descendants]"
}
watcher_watchdog_start() {
  (
    # BASHPID is absent in stock macOS bash 3.2. Exec in the substitution makes
    # the short-lived sh's parent this watchdog, not an intermediate subshell.
    observer_pid=${BASHPID:-}
    [ -n "$observer_pid" ] || observer_pid=$(exec sh -c 'printf "%s\n" "$PPID"')
    nap=''
    trap - EXIT HUP INT
    trap '[ -z "$nap" ] || kill "$nap" 2>/dev/null; exit 0' TERM
    seen='' still=0 unproven=''
    while :; do
      sleep "$WATCHDOG_INTERVAL" &
      nap=$!
      wait "$nap" || exit 0
      nap=
      kill -0 "$WATCHER_PID" 2>/dev/null || exit 0
      lock_pid=
      read -r lock_pid < "$WATCH_LOCK/pid" 2>/dev/null || true
      [ "$lock_pid" = "$WATCHER_PID" ] || exit 0
      if ! watcher_watchdog_owns; then
        [ -n "$unproven" ] || triage_log "watchdog: could not confirm watcher pid $WATCHER_PID owns the lock; retrying next interval"
        unproven=1
        continue
      fi
      unproven=''
      fm_path_mtime_to mtime "$STATE/.last-watcher-beat" || true
      if [ "$mtime" != "$seen" ]; then
        seen=$mtime
        still=0
        continue
      fi
      still=$((still + WATCHDOG_INTERVAL))
      [ "$still" -ge "$WATCHER_STALE_GRACE" ] || continue
      cycle='' step=''
      { IFS= read -r cycle; IFS= read -r step; } < "$STATE/.last-watcher-beat" 2>/dev/null || true
      watcher_watchdog_record_stop "$still" "$cycle" "$step" "$observer_pid" &
      kill -TERM "$WATCHER_PID" 2>/dev/null || exit 0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$WATCHER_PID" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
      done
      if kill -0 "$WATCHER_PID" 2>/dev/null && watcher_watchdog_owns; then
        triage_log "watchdog: wedged watcher pid $WATCHER_PID ignored TERM; killing it"
        kill -KILL "$WATCHER_PID" 2>/dev/null || true
      fi
      exit 0
    done
  ) </dev/null >/dev/null 2>&1 &
  WATCHDOG_PID=$!
}
watcher_watchdog_stop() {
  [ -n "$WATCHDOG_PID" ] || return 0
  kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=
}

watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  watcher_watchdog_stop
  pr_poll_publish_release || cleanup_status=1
  pr_poll_control_release || cleanup_status=1
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_capture_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" \
      downtime "$CLEANUP_LOCK_BOUND"; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
watcher_stop_signals
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

# Shared by both the first-notification and already-notified paths below so
# the retirement sequence (bin/fm-pr-lib.sh) is stated once.
retire_merged_pr_poll() {  # <id>
  local id=$1
  if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" merged; then
    fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
      || triage_log "merged PR poll retirement remains recoverable for $id"
  else
    triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
  fi
}

# A poll armed before a state volume remount can fail capture only because its
# registration names the old device number; bin/fm-pr-lib.sh
# fm_pr_poll_registration_rerecord_device owns the proof and the rewrite.
# Returns 0 when a re-record was attempted under the control lock, so the caller
# captures again whatever the outcome: a concurrent re-arm may have published a
# valid poll instead, and the strict capture decides either way.
rerecord_device_shifted_pr_poll() {  # <id>
  local id=$1
  fm_pr_poll_registration_device_shifted "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  PR_POLL_CONTROL_LOCK="$STATE/.control-$id.lock"
  fm_lock_acquire_wait "$PR_POLL_CONTROL_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$id.lock"
  fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK" || exit 1
  if fm_pr_poll_registration_rerecord_device "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
    triage_log "re-recorded PR poll identity for $id after its state volume device number changed"
  else
    triage_log "PR poll identity for $id was not re-recorded; the locked proof or rewrite did not hold"
  fi
  pr_poll_publish_release || exit 1
  pr_poll_control_release || exit 1
  return 0
}

resurface_after_downtime() {
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ] && [ "$WATCHER_RESURFACE_HELD" -ne 1 ]; then
    # A quiet cycle answers from a lock-free read; the queue and marker locks
    # are taken only when that read finds a state the locked check changes.
    if ! fm_recovery_marker_arm_check_idle "$WATCHER_DOWNTIME_MARKER" \
      && ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  # The re-announcement joins the wake batch unless a queued row is urgent. A
  # consumed recovery marker is remembered here, since arm_check will not
  # report it again, and in WAKE_BATCH_RESURFACE for a restarted watcher.
  # This wake leaves the batch open: it runs before the signal scan, so the
  # next watcher still owes held signals their original deadline.
  if wake_batch_on && ! wake_queue_rows_urgent && ! wake_batch_due "check: rearm-resurface" \
    && : > "$WAKE_BATCH_RESURFACE"; then
    WATCHER_RESURFACE_HELD=1
    WAKE_BATCH_HELD=1
    return 0
  fi
  wake "check: rearm-resurface"
}

# Liveness beacon for fm-guard.sh and every arm/turn-end freshness check: a
# fresh mtime means this watcher is still making progress. One cycle can run
# many bounded steps (secondmate observation, registered checks, signal
# triage, one pane capture per window), and a busy home's steps together can
# outlast the guard grace, so touching only at the top of the cycle made a
# healthy watcher read stale mid-cycle and refused concurrent re-arms. The loop
# calls this at each step boundary and after completed classification batches
# (fm-classify-lib.sh owns that callback contract), never from a background
# timer, so a blocked read or parser still ages the beacon and reads wedged.
# The top of each cycle also records that cycle's sequence number as the
# beacon's first line, so a reader can tell a new cycle from a step beat. The
# second line records the caller location of the last published beat for wedge
# evidence, not an inference about which operation hung. The beacon's mtime has
# one-second resolution, so a beat within the same second as the previous one
# skips publication; one builtin printf replaces the old touch, adding neither
# a fork nor a file write per beat. Per-record callers still cost no process.
WATCHER_CYCLE=0
WATCHER_BEAT_AT=
lock_owner='' summary_age='' heartbeat_age=''  # set each pass by the *_to readers in the loop
watcher_beat() {
  [ "$SECONDS" != "$WATCHER_BEAT_AT" ] || return 0
  WATCHER_BEAT_AT=$SECONDS
  printf '%s\n%s:%s\n' "$WATCHER_CYCLE" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" > "$STATE/.last-watcher-beat"
}
watcher_beat
watcher_watchdog_start

while :; do
  # Home-gone exit: a deleted home, state directory, or code root means this
  # watcher's world is gone (a torn-down temporary home or a discarded
  # disposable checkout). Exit with a logged reason rather than writing state
  # into nothing, or into a live home from a checkout that no longer exists.
  # A detached helper this watcher started (home-summary refresh, reconcile)
  # can recreate a deleted state directory before the next poll, so a lock
  # with no holder at all is read as the same teardown: only a fresh watcher
  # ever recreates the lock, and that case is the self-eviction below.
  # Scoped to this process alone: no other watcher is signalled.
  if [ "$WATCH_HOME_EXISTED" -eq 1 ] && [ ! -d "$FM_HOME" ]; then
    echo "watcher: exiting - home no longer exists: $FM_HOME" >&2
    exit 1
  elif [ ! -d "$STATE" ]; then
    echo "watcher: exiting - state directory no longer exists: $STATE" >&2
    exit 1
  elif [ ! -e "$WATCH_LOCK/pid" ]; then
    echo "watcher: exiting - state directory was torn down (singleton lock removed): $STATE" >&2
    exit 1
  elif [ ! -d "$SCRIPT_DIR" ]; then
    echo "watcher: exiting - code root no longer exists: $SCRIPT_DIR" >&2
    exit 1
  fi

  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  fm_file_text_to lock_owner "$WATCH_LOCK/pid" || true
  if [ "$lock_owner" != "$WATCHER_PID" ]; then
    exit 0
  fi

  WATCHER_CYCLE=$((WATCHER_CYCLE + 1))
  printf '%s\n%s\n' "$WATCHER_CYCLE" 'cycle-start' > "$STATE/.last-watcher-beat"
  WAKE_BATCH_HELD=0

  # Opt-in fleet activity ledger (docs/fleet-ledger.md): pick up newly appended
  # status lines before this cycle can exit on a wake. Off costs one file test.
  [ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" capture || true

  age_of_to summary_age "$STATE/home-summary.json"
  if [ "$summary_age" -ge "$HOME_SUMMARY_INTERVAL" ] \
    || [ -e "$STATE/.home-summary-refresh.pending" ] \
    || [ -e "$STATE/.home-summary-refresh.owed" ]; then
    home_summary_refresh_detached
  fi

  # Bearings publishes reconcile asks as local one-shot request files and
  # returns before any mate delivery. Supervision owns their later delivery;
  # a skipped or failed request remains durable for another poll.
  if reconcile_requests_pending; then
    reconcile_requests_detached
  fi

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  # Incremental status readers use this callback for completed nested work too.
  fm_pending_reply_tick "$STATE" watcher_beat || true

  # Endpoint liveness runs before queue observation: a positively dead or
  # missing secondmate endpoint is relaunched here on a bounded cadence, which
  # is also what unsticks that mate's foreign wake queue. The tick's single
  # wake exits the cycle like every other wake, so its marker is stamped before
  # any relaunch and the restarted watcher will not re-probe early.
  secondmate_liveness_tick watcher_beat || {
    echo "watcher: secondmate liveness check failed" >&2
    exit 1
  }

  # A live secondmate endpoint does not prove that its own wake loop is alive.
  # Observe the foreign queue before the rest of this cycle so an aged row wakes
  # the parent without consuming or rewriting the receiving home's record.
  secondmate_wake_stall_tick || {
    echo "watcher: secondmate wake-loop observation failed" >&2
    exit 1
  }

  watcher_beat

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered.
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake firstmate or consume model tokens.
  # Test seam, honored only under tests/lib.sh's FM_TEST_SEAM=1:
  # FM_INACTIVE_RECONCILE_BIN lets a test that does not exercise this cadence
  # stub the per-poll scan.
  watcher_beat
  inactive_bin=$SCRIPT_DIR/fm-inactive-reconcile.sh
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_INACTIVE_RECONCILE_BIN:-}" ]; then
    inactive_bin=$FM_INACTIVE_RECONCILE_BIN
  fi
  inactive_out=
  if inactive_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$inactive_bin" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    contribution_check_output=
    alert_store_reason=
    # Dated-rule alarms (docs/dated-rule-schedule.md) run just before the tick,
    # so a store they change is projected in this same pass. The check skips
    # unchanged inputs itself and ends with a completion mark; its problem
    # lines are woken on with the tick's, after the custom checks. It also runs
    # while a store is left from a removed schedule folder, to retire it.
    if [ -d "$STATE/dated-rules" ] || [ -e "$STATE/dated-rules.alerts.json" ] \
      || [ -e "$STATE/dated-rules.escalated.json" ]; then
      watcher_beat
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATED_RULES_CHECK_MARK=1 \
        run_check_capture "$SCRIPT_DIR/fm-dated-rules.sh" check || exit 1
      case "$FM_CHECK_RESULT" in
        'dated-rules check: complete') FM_CHECK_RESULT= ;;
        *$'\n''dated-rules check: complete') FM_CHECK_RESULT=${FM_CHECK_RESULT%$'\n''dated-rules check: complete'} ;;
        *) FM_CHECK_RESULT="${FM_CHECK_RESULT:+$FM_CHECK_RESULT$'\n'}dated-rules check did not finish within ${CHECK_TIMEOUT}s, so dated rules are unchecked" ;;
      esac
      if [ -n "$FM_CHECK_RESULT" ]; then
        alert_store_reason="check: dated-rules: ${FM_CHECK_RESULT//$'\n'/; }"
        fm_wake_append check dated-rules "$alert_store_reason" || exit 1
      fi
    fi
    # The alert-store tick (docs/alert-store.md) runs first, so a waking custom
    # check below can never starve it: it re-posts every registered store's
    # active alerts missing from their status files, and those appends wake
    # through the signal scan. Its problem lines are queued at once and woken
    # on after the custom checks, so a broken store cannot starve them either.
    # The tick ends with a completion mark; a tick killed by the check timeout
    # or failing early never prints it, and that is a problem, not a quiet tick.
    if [ -d "$STATE/alert-stores" ]; then
      watcher_beat
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_ALERT_STORE_TICK_MARK=1 \
        run_check_capture "$SCRIPT_DIR/fm-alert-store.sh" tick || exit 1
      case "$FM_CHECK_RESULT" in
        'alert-store tick: complete') FM_CHECK_RESULT= ;;
        *$'\n''alert-store tick: complete') FM_CHECK_RESULT=${FM_CHECK_RESULT%$'\n''alert-store tick: complete'} ;;
        *) FM_CHECK_RESULT="${FM_CHECK_RESULT:+$FM_CHECK_RESULT$'\n'}alert-store tick did not finish within ${CHECK_TIMEOUT}s, so its stores are unchecked" ;;
      esac
      if [ -n "$FM_CHECK_RESULT" ]; then
        alert_store_line="check: alert-stores: ${FM_CHECK_RESULT//$'\n'/; }"
        fm_wake_append check alert-stores "$alert_store_line" || exit 1
        alert_store_reason="${alert_store_reason:+$alert_store_reason; }$alert_store_line"
      fi
    fi
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      watcher_beat
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
          || { rerecord_device_shifted_pr_poll "$id" \
            && fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; }; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          PR_POLL_CONTROL_LOCK="$STATE/.control-$id.lock"
          fm_lock_acquire_wait "$PR_POLL_CONTROL_LOCK" || exit 1
          if ! fm_pr_poll_snapshot_matches "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
            pr_poll_control_release || exit 1
            triage_log "PR poll for $id changed before its validated check; skipping the stale snapshot"
            continue
          fi
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        if [ "$(basename "$c")" = contributions.check.sh ]; then
          contribution_check_output=
          contribution_check_diagnostics=
          while IFS= read -r contribution_check_line; do
            case "$contribution_check_line" in
              'contribution-wake: check: contributions '*)
                contribution_check_output="${contribution_check_output}${contribution_check_line#contribution-wake: }"$'\n'
                ;;
              *) contribution_check_diagnostics="${contribution_check_diagnostics}${contribution_check_line}"$'\n' ;;
            esac
          done <<EOF
$out
EOF
          if [ -n "$contribution_check_diagnostics" ]; then
            out=${contribution_check_diagnostics%$'\n'}
          elif [ -n "$contribution_check_output" ]; then
            continue
          fi
        fi
        reason="check: $c: $out"
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if [ "$(fm_meta_get "$STATE/$id.meta" kind)" = secondmate ]; then
            # A merge poll armed on a secondmate is residue: the mate is a
            # persistent worker, never landed work, and the merge it detected
            # belongs to a task in the mate's own home. Retire the poll with no
            # outcome and no wake; bin/fm-pr-check.sh refuses to arm another.
            retire_merged_pr_poll "$id"
            pr_poll_control_release || exit 1
            touch "$STATE/.last-check"
            triage_log "retired a merge poll armed on secondmate $id without reporting an outcome"
            continue
          fi
          if ! fm_merge_authority_read "$STATE" "$id" \
              "$provider" "$host" "$path" "$number"; then
            triage_log "no matching persisted merge authority for $id; recording an external merge outcome"
          fi
          merge_authority=$FM_MERGE_AUTHORITY
          merge_authority_record_identity=$FM_MERGE_AUTHORITY_RECORD_IDENTITY
          merge_outcome_rc=0
          fm_merge_outcome_report "$FM_HOME" "$STATE" "$id" "$url" poll \
            "$merge_authority" || merge_outcome_rc=$?
          if [ "$merge_outcome_rc" -ne 0 ]; then
            triage_log "merge outcome for $id could not be recorded (rc=$merge_outcome_rc)"
            exit 1
          fi
          if [ -n "$merge_authority_record_identity" ] \
            && ! fm_merge_authority_remove_if_matches "$STATE" "$id" \
              "$provider" "$host" "$path" "$number" "$merge_authority" \
              "$merge_authority_record_identity"; then
            triage_log "published merge outcome for $id but could not retire its authority record"
            exit 1
          fi
          retire_merged_pr_poll "$id"
          pr_poll_control_release || exit 1
          touch "$STATE/.last-check"
          if [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ]; then
            triage_log "absorbed duplicate merged PR poll result for $id"
            continue
          fi
          wake "$reason"
        fi
        pr_poll_control_release || exit 1
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
      pr_poll_control_release || exit 1
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
    if [ -n "$alert_store_reason" ]; then
      wake "$alert_store_reason"
    fi
    if [ -n "$contribution_check_output" ]; then
      wake "$contribution_check_output"
    fi
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  watcher_beat
  pending=$(scan_signals)
  if [ -n "$pending" ] && signal_batch_hold "$pending"; then
    pending=''
  fi
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    watcher_beat
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    # The final coalesced signal set is the watcher-carried status-change
    # trigger for this home's published summary. Start it before either
    # surfacing or absorbing the signal, but never wait on it: see
    # home_summary_refresh_detached for why publication stays off the beacon's
    # path. Publication failure stays side-band.
    home_summary_refresh_detached event
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file gained a captain-relevant event since it was last
    #     classified (its whole new span, not merely its last line);
    #   - or it is a no-verb wake (a bare turn-end, a working: note) with no
    #     positive evidence the crew is still executing, once any secondmate
    #     status file whose new span is only routine lines
    #     (signal_secondmate_routine_files) is set aside - the crew stopped its turn
    #     with no actively-running pipeline and no busy pane, so it may be done
    #     (even via an interactive menu that wrote no done: status), waiting on a
    #     decision, or wedged. Absorbing such a turn-end is exactly the
    #     swallowed-finish this change guards against.
    # Positive evidence is either an authoritative provably-working verdict or, in a
    # home that opts in with config/turnend-churn-absorb and for a BARE turn-end
    # alone, a pane that rendered something since the previous poll
    # (signal_turnend_panes_churned) - the only proof available to a harness whose
    # busy state has no verified semantic source, bounded so it cannot defer that
    # task's turn-ends forever. Absorb stays evidence-driven: with neither proof the
    # wake surfaces exactly as before.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew is still executing) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. Both evidence
    # checks are costly (a bounded no-mistakes call, then a pane capture), so the ||
    # ordering evaluates them ONLY for a non-afk signal with no captain-relevant
    # status span, and the capture only once the authoritative verdict comes up short.
    FM_SIGNAL_SURFACE_ENDPOINTS=''
    FM_SIGNAL_NEEDS_DECISION_FILES=''
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    signal_files_actionable $files
    signal_actionable=$?
    # Set aside a secondmate's routine-only span before asking for working
    # proof: an idle mate is healthy, so its progress line or acknowledgement
    # needs no crew evidence, and it rides along in the next drain's UNREAD
    # STATUS. Anything else in the batch still needs the proofs below; a batch
    # of only routine mate spans is benign outright.
    signal_rest=$files
    if [ "$signal_actionable" -ne 0 ] && ! afk_present; then
      signal_routine=$(signal_secondmate_routine_files)
      signal_rest=''
      for f in $files; do
        case " $signal_routine " in *" $f "*) ;; *) signal_rest="$signal_rest $f" ;; esac
      done
    fi
    # A decision-owned file's queued row payload is marked "needs-decision:"
    # instead of the ordinary "signal:" below (other files in the same batch
    # keep the ordinary payload). The wake reason line itself, and every
    # harness-arm consumer that pattern-matches it, stays byte-identical -
    # only the per-row payload changes. Two readers branch on that payload:
    # docs/pi-supervision-branch.md's Pi-only branch dispatcher, to keep a
    # decision-owned row off the supervision branch (fm-branch-dispatch.ts,
    # fm-primary-pi-watch.ts), and the away daemon, whose handle_durable_wakes
    # passes it to handle_wake (see the comment above handle_wake in
    # bin/fm-supervise-daemon.sh).
    # shellcheck disable=SC2086  # same space-separated status-path list
    if afk_present || [ "$signal_actionable" -eq 0 ] \
      || { [ -n "$signal_rest" ] && ! signal_quiet_wait_ack $signal_rest \
        && ! signal_crew_provably_working $signal_rest && ! signal_turnend_panes_churned $signal_rest; }; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        file_reason="$reason"
        case " $FM_SIGNAL_NEEDS_DECISION_FILES " in *" $f "*) file_reason="needs-decision:$files" ;; esac
        fm_wake_append signal "$(basename "$f")" "$file_reason" || exit 1
      done <<EOF
$pending
EOF
      # The wake signature advances for every file in this batch, including one
      # whose span could not be classified: it has now been reported, and this is
      # what bounds an unreadable log to one report per distinct file state. Only
      # a SUCCESSFULLY classified log commits a classification position below, so
      # an unreadable log's content is still classified once it becomes readable.
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in
          *.status)
            fm_wake_status_reported_commit "$STATE" "$f" "$sig" || true
            mark_surface_reported "$f" "$sig" || true
            ;;
          *) printf '%s' "$sig" > "$sf" ;;
        esac
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" || true
        mark_surfaced "$f" "$surface_end" "$surface_ident"
      done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
      wake_batch_close
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in *.status) ;; *) printf '%s' "$sig" > "$sf" ;; esac
      done <<EOF
$pending
EOF
      signal_commit_error=0
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" \
          || signal_commit_error=1
      done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
      if [ "$signal_commit_error" -ne 0 ]; then
        while IFS=$(printf '\t') read -r sf sig f; do
          [ -n "$sf" ] || continue
          fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
        done <<EOF
$pending
EOF
        wake_batch_close
        wake "$reason"
      fi
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified, or the declaration a busy pane's
  # crossed turn bound already handed to the away-mode daemon).
  recheck_declared_keys=' '
  pane_slot=0
  while IFS= read -r w; do
    pane_slot=$((pane_slot + 1))
    watcher_beat
    window_resolve "$w"
    kind=$WR_KIND
    task=$WR_TASK
    # Steering-inbox loss detection runs before the secondmate stale
    # exemption below, because a mate's steers land in an inbox too.
    [ -z "$task" ] || inbox_steer_check "$w" "$task"
    window_key_to key "$w"
    status_declared_wait_line_to last "$STATE/$task.status"
    if status_is_paused_or_captain_held "$last"; then
      recheck_declared_keys="$recheck_declared_keys$key "
    elif [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$key"
    fi
    # An idle secondmate endpoint is healthy by design, so a mate is admitted to
    # the pane-stale path ONLY to serve a status-declared wait's bounded
    # re-surface. This gate reads the shared predicate rather than the pause verb
    # alone so it includes a declared `captain-held` status. A hold recorded only
    # in the backlog while the mate still says `working:` or `done:` is outside
    # this guard: reaching it would require backlog reads for windows this gate
    # deliberately skips, putting that read on the ordinary poll hot path.
    if [ "$kind" = secondmate ] && ! status_is_paused_or_captain_held "$last"; then
      continue
    fi
    watcher_capture "$WR_BACKEND" "$w" 40 "$WR_LABEL" || continue
    tail40=$WATCHER_CAPTURE
    hash_pane_memo_to h "$pane_slot" "$tail40"
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    seen_hash=                 # the hash $sf holds, read where a stale hash is classified
    fm_file_text_to prev "$hf" || true
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if [ "$h" = "$prev" ]; then
      fm_file_text_to n "$cf" || n=0
      n=$(( n + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$key" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before,
          # except that a captain-held pane is never handed over while the
          # away-posture record exists (captain_held_silenced).
          if captain_held_silenced "$last"; then
            printf '%s' "$h" > "$sf"
            triage_log "absorbed stale (captain-held, never rechecked while the away-posture record exists): $w"
          elif { fm_file_text_to seen_hash "$sf"; [ "$seen_hash" != "$h" ]; }; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's latest status event is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if { fm_file_text_to seen_hash "$sf"; [ "$seen_hash" != "$h" ]; }; then
            if crew_is_provably_working "$WR_TASK"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              clear_write_tracking "$key"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            elif captain_call_stale_bound "$key" "$task"; then
              # The line is captain-relevant and stays so, but the backlog says
              # the captain already holds this work: further NEW pane hashes with
              # the same status-log state have nothing to add while they are
              # deciding. Only that new-hash repetition is bounded - the first
              # sight already alarmed, a new hash inside the window is absorbed,
              # and a new hash after it alarms again. A stable hash stays as inert
              # here as it already was after a first terminal alarm.
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              clear_write_tracking "$key"
              triage_log "absorbed stale (open captain call already surfaced for this status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              stale_wait_record "$key"
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              clear_write_tracking "$key"
              stale_status="$STATE/$WR_TASK.status"
              stale_record=$(status_span_first_actionable_record "$stale_status" 0 '' '' watcher_beat)
              case $? in
                0|1) stale_end=${stale_record%%$'\t'*}; stale_rest=${stale_record#*$'\t'}; stale_ident=${stale_rest%%$'\t'*} ;;
                *) stale_end=''; stale_ident='' ;;
              esac
              mark_surfaced "$stale_status" "$stale_end" "$stale_ident"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$task" "$h"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: a declared wait pause_state_class admits for every liveness
          #     verdict, so absorb on the long PAUSE_RESURFACE_SECS cadence instead of
          #     wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no admitted declared wait.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if { fm_file_text_to seen_hash "$sf"; [ "$seen_hash" != "$h" ]; }; then
            task=$WR_TASK
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$WR_TASK
            if [ -e "$pf" ] \
              || { status_declared_wait_line_to declared_line "$STATE/$task.status"; status_is_paused_or_captain_held "$declared_line"; }; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$key"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" "$task" "$h"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            elif [ ! -e "$ssf" ] && idle_park_nudge_open "$key"; then
              if [ "$IDLE_PARK_NUDGE_AGE" -ge "$IDLE_PARK_GRACE" ]; then
                surface_nonterminal_stale "$w" "$h"
              else
                triage_log "absorbed non-terminal stale (park-or-finish nudge ${IDLE_PARK_NUDGE_AGE}s ago, inside the grace): $w"
              fi
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$task" "$h"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through busy_turn_bound_check, which hands the crossed
        # bound to the same wedge timer unless the crew declared the wait itself.
        paused_bound=1
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
        else
          fm_rm_present "$ssf" "$ewf"
          clear_write_tracking "$key"
        fi
        # A busy pane normally means real work resumed, so stale pause bookkeeping
        # is cleared - but not in the same poll the declared-pause cadence just
        # recorded it, or the re-surface throttle it depends on would be erased and
        # the pause would re-surface every poll instead of once per long cadence.
        if [ "$paused_bound" -ne 0 ] && [ -e "$pf" ] && { [ "$n" -ge 2 ] \
          || { status_declared_wait_line_to declared_line "$STATE/$WR_TASK.status"; ! status_is_paused_or_captain_held "$declared_line"; }; }; then
          clear_pause_tracking "$key"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      paused_bound=1
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
      else
        fm_rm_present "$ssf" "$ewf"
        clear_write_tracking "$key"
      fi
      task=$WR_TASK
      declared_line=
      if [ "$busy_now" -ne 0 ] && ! afk_present \
        && { status_declared_wait_line_to declared_line "$STATE/$task.status"; status_is_paused_or_captain_held "$declared_line"; }; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$key" ;;
        esac
      elif [ "$paused_bound" -ne 0 ] && [ -e "$pf" ]; then
        # Same rule as the stable-hash branch: never clear pause bookkeeping the
        # declared-pause cadence recorded on this very poll.
        clear_pause_tracking "$key"
      fi
    fi
  done < <(recorded_windows)
  recheck_sweep "$recheck_declared_keys"
  recheck_flush poll

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  watcher_beat
  fm_file_text_to streak "$STATE/.heartbeat-streak" || streak=0
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  age_of_to heartbeat_age "$STATE/.last-heartbeat"
  if [ "$heartbeat_age" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant event the per-wake path absorbed by mistake.
      # Enqueue first, then record every status log surfaced through its end so the
      # next heartbeat does not re-fire it (enqueue-before-suppress preserved);
      # this wake sends firstmate to the whole fleet, so every log is read.
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced || true
      wake "heartbeat"
    else
      if ! mark_all_captain_relevant_surfaced; then
        fm_wake_append heartbeat heartbeat heartbeat || exit 1
        touch "$STATE/.last-heartbeat"
        wake "heartbeat"
      fi
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # A cycle that held nothing closes the wake batch, so the next routine item
  # opens a full window rather than inheriting an old deadline.
  [ "$WAKE_BATCH_HELD" -eq 1 ] || fm_rm_present "$WAKE_BATCH_MARKER"

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  watcher_beat
  event_wait_or_sleep
done
