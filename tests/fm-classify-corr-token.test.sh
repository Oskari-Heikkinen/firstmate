#!/usr/bin/env bash
# tests/fm-classify-corr-token.test.sh - a status line may carry the correlation
# token bin/fm-pending-reply-lib.sh embeds in a marked request and a secondmate
# echoes back (bin/fm-brief.sh), between the verb and the rest of the line. Every
# verb-driven classification must read straight through that token, in BOTH
# directions: a verb parse that keeps the token glued on matches no arm of the
# decision fold, so the opener never opens, the closer never closes, and a
# decision the captain is owed never reaches him.
#
# The parse is deliberately strict, and these tests defend that strictness as
# hard as they defend the fix: only the exact token a firstmate library writes is
# read through. Prose, a malformed or wrong-length token, and an arbitrary
# name=value word all keep their extra words and therefore stay non-transitions.
#
# Coverage is split by the interface each claim lives behind: the fold is driven
# through the REAL bin/fm-wake-drain.sh, the classifier predicates through the
# library's own sourced entry points (as tests/fm-watch-triage.test.sh does), and
# the token grammar itself is pinned against the REAL writers so this library's
# second statement of the shape cannot drift from the one that owns it.
#
# The same file covers the rest of that status-line grammar: decision-key
# position tolerance in the open-decisions fold. A "[key=<slug>]" token is
# documented between the verb and the colon (needs-decision [key=x]: note), but
# workers commonly write the colon first (needs-decision: [key=x] note); that
# stated key must be honored, never silently folded into the shared "default"
# bucket where an answer can close the wrong record (issue #2109). Also covers
# status_line_verb's bracket-tag stripping: a remote secondmate reply prepends
# a "[corr=...]" correlation tag before (or without) "[key=...]", and every
# such tag before the colon must be stripped so the leading word is the bare
# verb, regardless of order or count. Those cases drive the REAL
# status_line_verb / status_open_decisions / status_open_decisions_incremental
# functions over crafted status files and assert their folded output, never the
# fold's own source text. Also covers status_event_recorded: a recorded line
# stays recorded across a later resolved line for its key. Also covers
# status_key_closing_verb, which reports how the status side currently reads
# one key so a consumer can tell a settled key from one handed to a durable
# captain-held task (bin/fm-captain-hold.sh diverged). Cross-drain cursor
# persistence, the incremental cost bound, and the drain wiring live in
# tests/fm-wake-drain-open-decisions.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-corr-token-tests)

# A syntactically valid correlation token payload: 16 hex characters.
CORR=c44897ee2db4326b
CORR2=7ab3e5dd13c9a993

# Print the drain's OPEN DECISIONS view of <state>, or the empty string when the
# drain reports nothing open. Keeps each case's assertions about the CONTRACT
# (which decisions are open) rather than about the section's layout.
drain_open() {  # <state> <out>
  local state=$1 out=$2
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed over $state"
  grep -F 'OPEN DECISIONS' "$out" >/dev/null || return 0
  cat "$out"
}

# --- the fold, both directions ----------------------------------------------

test_tokened_opener_opens_and_tokened_closer_closes() {
  local dir state out view
  dir=$(make_case tokened-both-directions)
  state="$dir/state"
  out="$dir/drain.out"

  # OPENER. The half that loses a captain decision outright: it never appears in
  # any listing, so nobody knows it is owed.
  printf 'needs-decision corr=%s [key=texte-du-mur]: propose the wall text\n' "$CORR" \
    > "$state/task-open.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-open'*'[key=texte-du-mur]'*'propose the wall text'*) : ;;
    *) fail "a needs-decision carrying a correlation token did not open its key: $view" ;;
  esac

  # CLOSER. The half that leaves an answered decision on the captain's board.
  printf 'resolved corr=%s [key=texte-du-mur]: captain chose the third wording\n' "$CORR" \
    >> "$state/task-open.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'texte-du-mur'*) fail "a resolved carrying a correlation token did not close its key: $view" ;;
  esac

  # A blocked opener and a captain-held transfer close the same way.
  printf 'blocked corr=%s [key=sortie-plan]: the only lever exceeds the ruling\n' "$CORR2" \
    > "$state/task-blocked.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-blocked'*'[key=sortie-plan]'*) : ;;
    *) fail "a blocked carrying a correlation token did not open its key: $view" ;;
  esac
  printf 'captain-held corr=%s [key=sortie-plan]: tracked as a captain hold\n' "$CORR2" \
    >> "$state/task-blocked.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'sortie-plan'*) fail "a captain-held carrying a correlation token did not close its key: $view" ;;
  esac

  pass "a correlation token between the verb and the key breaks neither opening nor closing"
}

test_token_is_read_through_in_every_position_it_is_written_in() {
  local dir state out view
  dir=$(make_case token-positions)
  state="$dir/state"
  out="$dir/drain.out"

  # Before the key, after the key, with no key at all, twice on one line (a
  # recovery turn re-embedding), and in the bracketed shape the optional
  # bin/fm-secondmate-report.sh helper writes. Every one is a real observed shape.
  printf 'needs-decision corr=%s [key=before]: token ahead of the key\n' "$CORR" > "$state/t1.status"
  printf 'needs-decision [key=after] corr=%s: token behind the key\n' "$CORR" > "$state/t2.status"
  printf 'blocked corr=%s: token and no key at all\n' "$CORR" > "$state/t3.status"
  printf 'needs-decision corr=%s corr=%s [key=twice]: two tokens on one line\n' "$CORR" "$CORR2" \
    > "$state/t4.status"
  printf 'needs-decision [corr=%s]: the helper bracket shape\n' "$CORR" > "$state/t5.status"

  view=$(drain_open "$state" "$out")
  case "$view" in *'t1'*'[key=before]'*) ;; *) fail "token before the key did not open: $view" ;; esac
  case "$view" in *'t2'*'[key=after]'*) ;; *) fail "token after the key did not open: $view" ;; esac
  # The drain prints the default key as a bare verb, with no [key=...] segment.
  case "$view" in *'t3 blocked:'*) ;; *) fail "token with no key did not open the default key: $view" ;; esac
  case "$view" in *'t4'*'[key=twice]'*) ;; *) fail "two tokens on one line did not open: $view" ;; esac
  case "$view" in *'t5 needs-decision:'*) ;; *) fail "the bracketed helper token did not open: $view" ;; esac

  # ...and each closes from the same position.
  printf 'resolved corr=%s [key=before]: closed\n' "$CORR" >> "$state/t1.status"
  printf 'resolved [key=after] corr=%s: closed\n' "$CORR" >> "$state/t2.status"
  printf 'resolved corr=%s: closed\n' "$CORR" >> "$state/t3.status"
  printf 'resolved corr=%s corr=%s [key=twice]: closed\n' "$CORR" "$CORR2" >> "$state/t4.status"
  printf 'resolved [corr=%s]: closed\n' "$CORR" >> "$state/t5.status"

  view=$(drain_open "$state" "$out")
  [ -z "$view" ] || fail "a correlated closer failed to close from some position: $view"

  pass "the token is read through before the key, after it, doubled, bracketed, and unkeyed"
}

test_untokened_pair_is_unchanged() {
  local dir state out view
  dir=$(make_case untokened-pair)
  state="$dir/state"
  out="$dir/drain.out"

  # The same pair with no token at all, keyed and bare: the historical behavior
  # this change must leave exactly as it was.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/keyed.status"
  printf 'blocked: no key at all\n' > "$state/bare.status"
  view=$(drain_open "$state" "$out")
  case "$view" in *'keyed'*'[key=api-shape]'*) ;; *) fail "an untokened keyed opener regressed: $view" ;; esac
  case "$view" in *'bare blocked:'*) ;; *) fail "an untokened bare opener regressed: $view" ;; esac

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/keyed.status"
  printf 'resolved: cleared on its own\n' >> "$state/bare.status"
  view=$(drain_open "$state" "$out")
  [ -z "$view" ] || fail "an untokened closer regressed: $view"

  pass "the untokened opener/closer pair behaves exactly as before"
}

# --- the strictness the parse exists for ------------------------------------

test_prose_and_malformed_tokens_never_become_transitions() {
  local dir state out view line
  dir=$(make_case no-prose-takeover)
  state="$dir/state"
  out="$dir/drain.out"

  # Every one of these must stay a non-transition. If any became a verb, free
  # text would be able to open decisions nobody raised - or silently close one
  # the captain is owed, which is the takeover this strictness exists to stop.
  #
  # All of these are UNBRACKETED, which is the shape this parser owns. A
  # BRACKETED tag is deliberately NOT listed: verb parsing ends at the first
  # "[", so "resolved [corr=deadbeef] [key=victim]:" reads as the bare verb
  # "resolved" and does close the decision. That is the tag rule's own
  # contract, not a gap in this one, and tightening it here would silently
  # narrow a separately reviewed rule. The strictness below is what keeps an
  # unbracketed token honest, and a bracketed impostor still has to get a
  # well-formed key past _fm_decision_key_transition_allowed.
  local -a impostors=(
    'resolved the corr= issue yesterday [key=victim]'
    'resolved corr= [key=victim]'
    'resolved corr=deadbeef [key=victim]'
    'resolved corr=abcdef0123456789ab [key=victim]'
    'resolved corr=ZZZZbeefdeadbeef [key=victim]'
    'resolved xcorr=c44897ee2db4326b [key=victim]'
    'resolved corr=c44897ee2db4326 [key=victim]'
    'resolved anything=whatever [key=victim]'
    'resolved and then corr=c44897ee2db4326b happened [key=victim]'
  )

  # Each impostor gets its own task log, and every log is only ever appended to,
  # the way a real status file is written. All of them are then folded in ONE
  # drain, so a single pass proves every case at once.
  local i=0
  for line in "${impostors[@]}"; do
    printf 'needs-decision [key=victim]: a real captain decision\n' > "$state/close-$i.status"
    printf '%s: free text that must not close it\n' "$line" >> "$state/close-$i.status"
    # The same shape must not OPEN one either.
    printf '%s: free text that must not open anything\n' "${line/resolved/needs-decision}" \
      > "$state/open-$i.status"
    i=$((i + 1))
  done

  view=$(drain_open "$state" "$out")
  i=0
  for line in "${impostors[@]}"; do
    case "$view" in
      *"close-$i [key=victim] needs-decision: a real captain decision"*) : ;;
      *) fail "an impostor closed a real decision: '$line' -> $view" ;;
    esac
    # The backstop may show the unparsed line itself. Only the open-decisions
    # section, which prints "[key=" before the verb, records a real transition.
    case "$view" in
      *"open-$i [key="*) fail "an impostor opened a decision nobody raised: '$line' -> $view" ;;
    esac
    i=$((i + 1))
  done

  # A note mentioning the token AFTER the colon is ordinary prose and touches
  # nothing, whichever verb carries it.
  printf 'needs-decision [key=noted]: see corr=c44897ee2db4326b in the thread\n' > "$state/noted.status"
  printf 'working: chasing corr=c44897ee2db4326b through the log\n' >> "$state/noted.status"
  printf 'done: resolved corr=c44897ee2db4326b in passing\n' >> "$state/noted.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'noted'*'[key=noted]'*) : ;;
    *) fail "a token quoted inside notes disturbed the fold: $view" ;;
  esac

  pass "prose, malformed, wrong-length and unknown name=value tokens stay non-transitions"
}

test_token_first_word_never_impersonates_a_transition() {
  local dir state out view
  dir=$(make_case token-first)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'corr=%s needs-decision [key=token-first-needs]: prose\n' "$CORR" \
    > "$state/token-first-needs.status"
  printf 'corr=%s blocked [key=token-first-blocked]: prose\n' "$CORR" \
    > "$state/token-first-blocked.status"

  printf 'needs-decision [key=stays-open-resolved]: a real captain decision\n' \
    > "$state/token-first-resolved.status"
  printf 'corr=%s resolved [key=stays-open-resolved]: prose\n' "$CORR" \
    >> "$state/token-first-resolved.status"

  printf 'blocked [key=stays-open-held]: a real captain blocker\n' \
    > "$state/token-first-held.status"
  printf 'corr=%s captain-held [key=stays-open-held]: prose\n' "$CORR" \
    >> "$state/token-first-held.status"

  view=$(drain_open "$state" "$out")
  case "$view" in
    *'token-first-needs [key='*) fail "a token-first needs-decision opened a decision: $view" ;;
  esac
  case "$view" in
    *'token-first-blocked [key='*) fail "a token-first blocked opened a decision: $view" ;;
  esac
  case "$view" in
    *'token-first-resolved'*'[key=stays-open-resolved]'*'a real captain decision'*) : ;;
    *) fail "a token-first resolved closed a real decision: $view" ;;
  esac
  case "$view" in
    *'token-first-held'*'[key=stays-open-held]'*'a real captain blocker'*) : ;;
    *) fail "a token-first captain-held closed a real blocker: $view" ;;
  esac

  pass "a token-first line cannot impersonate any opening or closing verb"
}

# --- every other status_line_verb consumer ----------------------------------

test_captain_relevance_and_pause_are_unchanged_without_a_token() {
  # Pinned verdicts for the untokened shapes. These are the historical answers;
  # the fast path in status_line_verb returns such a prefix byte-for-byte, so
  # this is the regression wall for every consumer at once.
  status_is_captain_relevant 'done: shipped' || fail "done: regressed"
  status_is_captain_relevant 'needs-decision [key=q1]: pick one' || fail "keyed needs-decision regressed"
  status_is_captain_relevant 'blocked: stuck' || fail "blocked: regressed"
  status_is_captain_relevant 'failed: gave up' || fail "failed: regressed"
  status_is_captain_relevant 'working: still going' && fail "working: regressed to captain-relevant"
  status_is_captain_relevant 'working: rebased onto merged #76' \
    && fail "nonterminal free-text guard regressed"
  status_is_captain_relevant 'merged' || fail "legacy bare free-text regressed"
  status_is_captain_relevant 'resolved [key=q1]: answered' && fail "resolved regressed to captain-relevant"

  status_is_paused 'paused: waiting on the upstream release' || fail "paused: regressed"
  status_is_paused '  paused:   waiting on a reset' || fail "spaced paused: regressed"
  status_is_paused 'blocked: the build is paused upstream' && fail "paused-in-prose regressed"
  status_is_paused 'working: paused the animation loop' && fail "paused-in-prose regressed"
  status_is_paused '' && fail "empty line regressed"

  status_is_terminal_verb 'done: shipped' || fail "terminal verb regressed"
  status_is_terminal_verb 'working: rebased onto merged #76' && fail "nonterminal terminal-verb regressed"
  status_is_paused_or_captain_held 'captain-held [key=r]: tracked' || fail "captain-held regressed"
  status_is_paused_or_captain_held 'resolved [key=r]: answered' && fail "resolved regressed"

  pass "untokened captain-relevance, pause, terminal-verb and captain-held verdicts are unchanged"
}

test_consumer_verdicts_read_through_the_token() {
  # A token must not hide a captain-facing event from the supervisors, and must
  # not let a nonterminal line be escalated as one. Both were live: an untreated
  # token made "done corr=...: PR ready" invisible to the terminal-verb test,
  # while "working corr=...: rebased onto merged #76" leaked through the
  # free-text fallback the nonterminal guard was supposed to stop.
  status_is_captain_relevant "done corr=$CORR: shipped" \
    || fail "a correlated done is not captain-relevant"
  status_is_captain_relevant "needs-decision corr=$CORR [key=q]: pick one" \
    || fail "a correlated needs-decision is not captain-relevant"
  status_is_captain_relevant "blocked corr=$CORR: stuck" \
    || fail "a correlated blocked is not captain-relevant"
  status_is_captain_relevant "done [corr=$CORR]: shipped via the helper" \
    || fail "a helper-bracketed done is not captain-relevant"

  status_is_terminal_verb "done corr=$CORR: shipped" \
    || fail "a correlated done is not a terminal verb"
  status_is_terminal_verb "working corr=$CORR: still going" \
    && fail "a correlated working became a terminal verb"

  status_is_captain_relevant "working corr=$CORR: rebased onto merged #76" \
    && fail "a correlated working leaked through the free-text fallback"
  status_is_captain_relevant "resolved corr=$CORR [key=q]: answered" \
    && fail "a correlated resolved leaked through the free-text fallback"

  # The pause and captain-held declarations the watcher reads to leave a
  # deliberately idle endpoint alone instead of aging it as a possible wedge.
  status_is_paused "paused corr=$CORR: waiting on the upstream release" \
    || fail "a correlated pause was not recognised as a declared external wait"
  status_is_paused_or_captain_held "captain-held corr=$CORR [key=r]: tracked as a hold" \
    || fail "a correlated captain-held was not recognised"
  status_is_paused "blocked corr=$CORR: the build is paused upstream" \
    && fail "a correlated blocked mentioning paused false-matched"

  pass "captain-relevance, terminal-verb, pause and captain-held all read through the token"
}

test_daemon_and_crew_state_case_arms_read_through_the_token() {
  # Two consumers switch on the verb STRING rather than on a helper, so they
  # cannot be proven through status_is_*: bin/fm-supervise-daemon.sh matches
  # working|resolved|captain-held to take the transient-stale path instead of
  # the terminal one, and bin/fm-crew-state.sh's map_log_state maps each verb to
  # a run state, falling through to "unknown" on anything else.
  #
  # Before this fix a correlated line matched no arm of either: a correlated
  # working line was escalated as terminally stale, and every correlated line
  # read as run state "unknown". Pin the exact strings those arms compare
  # against, for both the tokened and untokened spellings.
  local verb
  for verb in working resolved captain-held; do
    [ "$(status_line_verb "$verb corr=$CORR [key=k]: note")" = "$verb" ] \
      || fail "the daemon transient-stale arm no longer matches a correlated $verb"
    [ "$(status_line_verb "$verb [key=k]: note")" = "$verb" ] \
      || fail "the daemon transient-stale arm regressed for an untokened $verb"
  done
  for verb in working needs-decision blocked 'done' failed; do
    [ "$(status_line_verb "$verb corr=$CORR: note")" = "$verb" ] \
      || fail "map_log_state would still read a correlated $verb as unknown"
    [ "$(status_line_verb "$verb: note")" = "$verb" ] \
      || fail "map_log_state regressed for an untokened $verb"
  done

  # The same arms must stay closed to prose and to a malformed token, or a
  # stuck worker could dodge a stale escalation by writing one.
  [ "$(status_line_verb "working the corr= thing [key=k]: prose")" = working ] \
    && fail "prose reduced to a bare working verb"
  [ "$(status_line_verb "working corr=deadbeef [key=k]: malformed")" = working ] \
    && fail "a malformed token reduced to a bare working verb"

  pass "the daemon and crew-state verb case arms read through the token"
}

test_pending_reply_escalation_matching_is_unaffected() {
  # bin/fm-pending-reply-lib.sh filters a status file by verb when looking for
  # the escalation IT published, then whole-line matches its own exact payload.
  # Reading through the token widens the verb filter, so this pins that the exact
  # match behind it still refuses everything that is not that library's own line.
  local dir state out view
  dir=$(make_case pending-reply-namespace)
  state="$dir/state"
  out="$dir/drain.out"

  # The reserved namespace may only be opened by a note speaking its vocabulary.
  # A correlated line must not become a way around that. Each claim gets its own
  # append-only log so one drain proves both.
  printf 'blocked corr=%s [key=pending-reply-%s]: unrelated note\n' "$CORR" "$CORR" \
    > "$state/task-takeover.status"
  printf 'blocked corr=%s [key=pending-reply-%s]: pending-reply-missed: task=t pending-reply-id=%s\n' \
    "$CORR" "$CORR" "$CORR" > "$state/task-owner.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-takeover'*) fail "a correlated line took over a reserved key: $view" ;;
  esac
  case "$view" in
    *"task-owner [key=pending-reply-$CORR]"*) : ;;
    *) fail "the reserved namespace owner could not open through a token: $view" ;;
  esac

  # ...and the owner closes it through a token just as completely.
  printf 'resolved corr=%s [key=pending-reply-%s]: pending-reply-missed: answered\n' \
    "$CORR" "$CORR" >> "$state/task-owner.status"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-owner'*) fail "the reserved namespace owner could not close through a token: $view" ;;
  esac

  pass "reading through the token does not weaken the reserved-key namespace rule"
}

# --- the two folds must agree ------------------------------------------------

test_incremental_and_whole_file_folds_agree_over_correlated_lines() {
  local dir state status whole inc round
  dir=$(make_case fold-agreement)
  state="$dir/state"
  status="$state/task-agree.status"

  # Grow the log the way a real one grows - correlated opens, unrelated routine
  # traffic, correlated closes - and after EVERY append assert that the bounded
  # cursor-backed fold and the whole-file fold report the identical open set.
  : > "$status"
  round=0
  while [ "$round" -lt 6 ]; do
    printf 'needs-decision corr=%s [key=k%s]: decision %s\n' "$CORR" "$round" "$round" >> "$status"
    printf 'working corr=%s: routine progress %s\n' "$CORR2" "$round" >> "$status"
    whole=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    inc=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions_incremental "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    [ "$whole" = "$inc" ] \
      || fail "folds disagreed after opening k$round: whole=[$whole] incremental=[$inc]"
    # Agreement alone would be satisfied by both folds being blind in the same
    # way, so pin the answer itself: every key opened so far, and only those.
    [ "$(printf '%s' "$whole" | grep -c .)" -eq "$((round + 1))" ] \
      || fail "after opening k$round the folds agreed on the wrong set: [$whole]"
    case "$whole" in
      *"k$round"*) : ;;
      *) fail "the folds agreed but never saw the correlated opener k$round: [$whole]" ;;
    esac
    round=$((round + 1))
  done

  round=0
  while [ "$round" -lt 6 ]; do
    printf 'resolved corr=%s [key=k%s]: answered %s\n' "$CORR" "$round" "$round" >> "$status"
    whole=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    inc=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; status_open_decisions_incremental "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")
    [ "$whole" = "$inc" ] \
      || fail "folds disagreed after closing k$round: whole=[$whole] incremental=[$inc]"
    [ "$(printf '%s' "$whole" | grep -c .)" -eq "$((5 - round))" ] \
      || fail "after closing k$round the folds agreed on the wrong set: [$whole]"
    case "$whole" in
      *"k$round"*) fail "the correlated closer for k$round left it open in both folds: [$whole]" ;;
    esac
    round=$((round + 1))
  done

  [ -z "$whole" ] || fail "correlated closers left decisions open in both folds: $whole"

  pass "the cursor-backed fold and the whole-file fold agree on every correlated transition"
}

test_a_cursor_written_before_this_change_is_rebuilt() {
  # The persisted cursor carries a folded open set, so every one written under
  # the previous reading holds decisions computed while correlated lines were
  # invisible. Without a fold-version bump those homes would keep serving the old
  # answer forever - the live openers would stay missing after the fix landed.
  local dir state status cursor out view
  dir=$(make_case stale-cursor)
  state="$dir/state"
  status="$state/task-stale.status"

  printf 'needs-decision corr=%s [key=owed]: a decision the captain is owed\n' "$CORR" > "$status"
  # A cursor claiming the whole file is already folded, with an empty open set -
  # byte for byte what the previous reading would have persisted here.
  cursor="$state/.task-stale.open-decisions-cursor"
  {
    printf 'version=4\n'
    printf 'offset=%s\n' "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')"
    printf 'ident=%s\n' "$(bash -c '. "$1"; _fm_open_decisions_file_ident "$2"' _ \
      "$ROOT/bin/fm-classify-lib.sh" "$status")"
  } > "$cursor"

  out="$dir/drain.out"
  view=$(drain_open "$state" "$out")
  case "$view" in
    *'task-stale'*'[key=owed]'*) : ;;
    *) fail "a cursor from the previous reading hid the decision instead of being rebuilt: $view" ;;
  esac

  pass "a cursor persisted under the previous reading is discarded and refolded"
}

# --- the grammar pin ---------------------------------------------------------

test_the_real_writers_produce_tokens_this_library_reads() {
  # This library states the token SHAPE a second time because the library that
  # OWNS the grammar sources this one and cannot be sourced back. That second
  # statement is only safe while it is pinned to the real writers, so this drives
  # both of them for real and asserts the classifier reads their output.
  local dir state token line verb helper_line
  dir=$(make_case writer-pin)
  state="$dir/state"

  # Writer 1: the correlation library's own token builder, over ids it generates.
  local i=0 corr
  while [ "$i" -lt 5 ]; do
    corr=$(bash -c '. "$1"; fm_pending_reply_new_id' _ "$ROOT/bin/fm-pending-reply-lib.sh")
    [ -n "$corr" ] || fail "the correlation library produced an empty id"
    token=$(bash -c '. "$1"; fm_pending_reply_corr_token "$2"' _ \
      "$ROOT/bin/fm-pending-reply-lib.sh" "$corr")
    line="needs-decision $token [key=pinned]: a decision"
    verb=$(status_line_verb "$line")
    [ "$verb" = needs-decision ] \
      || fail "the classifier did not read through a real correlation token '$token' (verb=[$verb])"
    i=$((i + 1))
  done

  # Writer 2: the optional secondmate report helper, whose bracketed shape must
  # be read through just as completely. Drive the real script from a seeded
  # mate home so it resolves the parent channel itself.
  local parent mate
  parent="$dir"
  mate="$dir/mate"
  mkdir -p "$mate/state"
  printf 'pinned\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$parent
EOF
  FM_HOME="$mate" "$REPORT" "done" "$corr" "audit clean" \
    || fail "$REPORT failed writing a correlated report"
  helper_line=$(tail -1 "$state/pinned.status")
  status_line_at_epoch "$helper_line" >/dev/null || fail "report helper emitted no time"
  verb=$(status_line_verb "$helper_line")
  [ "$verb" = "done" ] \
    || fail "the classifier did not read through the helper's own line '$helper_line' (verb=[$verb])"
  status_is_terminal_verb "$helper_line" \
    || fail "the helper's own line is not seen as a terminal captain verb"

  FM_HOME="$mate" "$REPORT" --doc needs-decision "$corr" data/x/report.md "see the report" \
    || fail "$REPORT failed writing a correlated doc-pointer report"
  helper_line=$(tail -1 "$state/pinned.status")
  status_line_at_epoch "$helper_line" >/dev/null || fail "doc report helper emitted no time"
  verb=$(status_line_verb "$helper_line")
  [ "$verb" = needs-decision ] \
    || fail "the classifier did not read through the helper's doc line '$helper_line' (verb=[$verb])"

  pass "both real correlation-token writers produce lines this classifier reads through"
}

test_optional_event_time() {
  local line stamped epoch before after dir
  before=$(date +%s)
  line="needs-decision corr=$CORR [key=timed]: choose: A or B"
  stamped=$(status_stamp_line "$line") || fail "status writer could not stamp an event"
  after=$(date +%s)
  epoch=$(status_line_at_epoch "$stamped") || fail "new event has no emission time"
  [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ] || fail "event time is not append time"
  [ "$(status_line_verb "$stamped")" = needs-decision ] || fail "time changed verb"
  [ "$(_fm_decision_key "$stamped")" = timed ] || fail "time changed key"
  [ "$(status_line_note "$stamped")" = 'choose: A or B' ] || fail "time changed note"
  [ "$(status_stamp_line "$stamped")" = "$stamped" ] || fail "restamping changed emission time"
  line='done [at=1700000000]: old event'
  [ "$(status_stamp_line "$line")" = "$line" ] || fail "writer replaced an old emission time"
  (
    # shellcheck disable=SC2329 # status_stamp_line invokes this clock stub indirectly.
    date() { return 1; }
    [ "$(status_stamp_line 'done: clock unavailable')" = 'done: clock unavailable' ]
  ) || fail "clock failure lost the event"
  for line in 'done: legacy' 'done: [at=1700000000] prose' \
    'done [at=]: empty' "done [at=\$(date +%s)]: literal substitution" \
    'done [at=<epoch>]: unsubstituted placeholder' \
    'done [at=bad]: malformed' 'done [at=17:00]: malformed colon' 'done [at=-1]: negative' \
    'done [at=01700000000]: noncanonical' 'done [at=99999999999999999999]: overflow' \
    'done [at=1] [at=2]: ambiguous'; do
    if status_line_at_epoch "$line" >/dev/null; then fail "invented time for $line"; fi
  done
  # A readable time a worker wrote instead of epoch seconds carries colons that
  # must not move the head/note separator, in either metadata order.
  for line in "needs-decision [key=api-shape] [at=10:30]: choose: A or B" \
    "needs-decision [at=10:30] [key=api-shape]: choose: A or B" \
    "needs-decision [key=api-shape] [at=2026-09-20T14:03:00Z]: choose: A or B"; do
    [ "$(_fm_decision_key "$line")" = api-shape ] \
      || fail "a colon-bearing time hid the decision key: [$(_fm_decision_key "$line")] from $line"
    [ "$(status_line_note "$line")" = 'choose: A or B' ] \
      || fail "a colon-bearing time garbled the note: [$(status_line_note "$line")] from $line"
  done
  for line in "done [at=1700000000] [corr=$CORR]: finished" \
    "done [corr=$CORR] [at=1700000000]: finished" \
    "done[at=1700000000] [corr=$CORR]: finished"; do
    [ "$(status_line_at_epoch "$line")" = 1700000000 ] || fail "metadata order changed time"
  done
  dir=$(make_case event-time)
  # The real parent publisher deduplicates a retry against both timed and
  # legacy records without rewriting the first event's time.
  . "$ROOT/bin/fm-parent-channel-lib.sh"
  line="done [corr=$CORR]: path: C:\\notes"
  printf '%s\n' "$(status_stamp_line "$line")" > "$dir/state/retry.status"
  stamped=$(cat "$dir/state/retry.status")
  fm_parent_channel_append_once "$dir/state/retry.status" "$line" || fail "parent retry failed"
  [ "$(cat "$dir/state/retry.status")" = "$stamped" ] || fail "retry duplicated or restamped event"
  printf '%s\n' "$line" > "$dir/state/legacy.status"
  fm_parent_channel_append_once "$dir/state/legacy.status" "$line" || fail "legacy retry failed"
  [ "$(cat "$dir/state/legacy.status")" = "$line" ] || fail "legacy retry acquired an invented time"
  fm_parent_channel_append_once "$dir/state/retry.status" "done [corr=$CORR2]: path: C:\\notes"
  [ "$(wc -l < "$dir/state/retry.status")" -eq 2 ] || fail "dedup discarded different correlation"
  fm_parent_channel_append_once "$dir/state/retry.status" 'done: prose [at=1]'
  fm_parent_channel_append_once "$dir/state/retry.status" 'done: prose [at=2]'
  [ "$(wc -l < "$dir/state/retry.status")" -eq 4 ] || fail "dedup stripped a time mention from prose"
  # A malformed time tag is ordinary event bytes, so it identifies the event:
  # the unstamped line is a DIFFERENT event, while re-appending the same bytes
  # is still a retry.
  for line in 'done [at=17:00]: shipped' 'done [at=]: shipped' 'done [at=bad]: shipped' \
    'done [at=1] [at=2]: shipped' 'done [at=01700000000]: shipped' \
    'done [at=99999999999999999999]: shipped'; do
    printf '%s\n' "$line" > "$dir/state/malformed.status"
    fm_parent_channel_append_once "$dir/state/malformed.status" 'done: shipped' \
      || fail "append after a malformed time failed"
    [ "$(wc -l < "$dir/state/malformed.status")" -eq 2 ] \
      || fail "dedup stripped a malformed time tag: $line"
    fm_parent_channel_append_once "$dir/state/malformed.status" "$line" \
      || fail "malformed time retry failed"
    [ "$(head -1 "$dir/state/malformed.status")" = "$line" ] \
      && [ "$(wc -l < "$dir/state/malformed.status")" -eq 2 ] \
      || fail "retry duplicated or rewrote malformed time: $line"
  done
  # A well-formed numeric tag still strips, in either metadata order.
  for line in "done [at=1700000000] [corr=$CORR2]: stamped" \
    "done [corr=$CORR2] [at=1700000000]: stamped" \
    "done[at=1700000000] [corr=$CORR2]: stamped"; do
    printf '%s\n' "$line" > "$dir/state/timed.status"
    fm_parent_channel_append_once "$dir/state/timed.status" "done [corr=$CORR2]: stamped" \
      || fail "numeric time retry failed"
    [ "$(cat "$dir/state/timed.status")" = "$line" ] \
      || fail "dedup did not ignore a well-formed numeric time: $line"
  done
  stamped=$(status_stamp_line "needs-decision corr=$CORR [key=timed]: choose: A or B")
  printf '%s\n' "$stamped" 'working [at=1700000000]: unrelated progress' > "$dir/state/task.status"
  [ -n "$(status_open_decisions "$dir/state/task.status")" ] || fail "time cleared an open decision"
  printf '%s\n' 'resolved [at=1700000001] [key=timed]: answered' >> "$dir/state/task.status"
  [ -z "$(status_open_decisions "$dir/state/task.status")" ] || fail "timed resolution did not close decision"
  # The parent publisher uses the same retry check, and a resolve does not
  # make a published line new: a keyed blocker and a note each stay once.
  line='blocked [key=remote-reply-continuity-ios]: remote reply continuity broke for ios (truncated)'
  : > "$dir/state/episode.status"
  fm_parent_channel_append_once "$dir/state/episode.status" "$line" \
    || fail "first continuity append failed"
  fm_parent_channel_append_once "$dir/state/episode.status" "$line" \
    || fail "open continuity retry failed"
  [ "$(wc -l < "$dir/state/episode.status")" -eq 1 ] \
    || fail "an open continuity blocker was duplicated"
  printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator rebased the mirror' \
    >> "$dir/state/episode.status"
  fm_parent_channel_append_once "$dir/state/episode.status" "$line" \
    || fail "continuity retry after the resolve failed"
  [ "$(wc -l < "$dir/state/episode.status")" -eq 2 ] \
    || fail "a resolve made a recorded continuity blocker append again"
  [ -z "$(status_open_decisions "$dir/state/episode.status")" ] \
    || fail "a continuity retry reopened the resolved decision"
  line='note: remote document did not transfer for ios: data/reply/missing.md - absent'
  printf '%s\n' "$line" > "$dir/state/note.status"
  printf '%s\n' 'resolved: closed the default decision' >> "$dir/state/note.status"
  fm_parent_channel_append_once "$dir/state/note.status" "$line" \
    || fail "note retry failed"
  [ "$(wc -l < "$dir/state/note.status")" -eq 2 ] \
    || fail "a resolve duplicated a note"
  pass "optional event time preserves parsing and legacy unknown time"
}

test_captain_override_ignores_event_time() {
  local dir verb line event
  local FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'
  dir=$(make_case captain-override-time)
  for verb in 'done' needs-decision blocked failed; do
    for line in "$verb: audit complete" "$verb [at=1700000000]: audit complete" \
      "${verb}[at=1700000000]: audit complete"; do
      status_is_captain_relevant "$line" || fail "override missed actionable event: $line"
      printf '%s\n' "$line" > "$dir/state/task.status"
      event=$(status_span_first_actionable "$dir/state/task.status" 0) \
        || fail "override hid actionable status span: $line"
      [ "$event" = "$line" ] || fail "classification changed surfaced event bytes: $event"
      [ "$(cat "$dir/state/task.status")" = "$line" ] || fail "classification rewrote stored event"
    done
  done
  FM_CAPTAIN_RE='done:'
  for line in 'blocked: waiting' 'blocked [at=1700000000]: waiting'; do
    status_is_captain_relevant "$line" && fail "override admitted excluded event: $line"
    printf '%s\n' "$line" > "$dir/state/task.status"
    status_span_has_actionable "$dir/state/task.status" 0 \
      && fail "override surfaced excluded event: $line"
  done
  for verb in working paused resolved captain-held; do
    for line in "$verb: done: mentioned" "$verb [at=1700000000]: done: mentioned"; do
      status_is_captain_relevant "$line" && fail "override bypassed nonterminal suppression: $line"
    done
  done
  FM_CAPTAIN_RE='^custom-verb: audit complete$'
  for line in 'custom-verb: audit complete' 'custom-verb [at=1700000000]: audit complete' \
    'custom-verb [at=<epoch>]: audit complete'; do
    status_is_captain_relevant "$line" || fail "timestamp broke custom verb override: $line"
    printf '%s\n' 'working: started' "$line" > "$dir/state/task.status"
    [ "$(last_status_line "$dir/state/task.status")" = "$line" ] \
      || fail "event scan skipped the stamped custom-verb event: $line"
  done
  FM_CAPTAIN_RE="^done \\[corr=$CORR\\]: literal \\[at=1700000000\\]$"
  for line in "done [corr=$CORR]: literal [at=1700000000]" \
    "done [at=1700000000] [corr=$CORR]: literal [at=1700000000]" \
    "done [corr=$CORR] [at=1700000000]: literal [at=1700000000]"; do
    status_is_captain_relevant "$line" || fail "normalization changed correlation metadata or note: $line"
  done
  pass "captain regex overrides preserve timed and legacy relevance and event bytes"
}

# A malformed time tag is never read as a time: relevance, verb, and note all see
# the same ordinary bytes, so a FM_CAPTAIN_RE override matching "<verb>:" does not
# find a separator the line does not have, while the terminal-verb default still
# surfaces the event.
test_malformed_event_time_is_ordinary_bytes() {
  local dir verb line event
  dir=$(make_case malformed-event-time)
  for verb in 'done' needs-decision blocked failed; do
    for line in "$verb [at=]: audit complete" "$verb [at=bad]: audit complete" \
      "$verb [at=17:00]: audit complete" "$verb [at=bad] [at=17:00]: audit complete" \
      "$verb [at=2026-09-20T14:03:00Z]: audit complete" "$verb [at=10:30]: audit complete" \
      "$verb [at=\$(date +%s)]: audit complete" \
      "$verb [at=<epoch>]: audit complete" \
      "$verb [at=1] [at=2]: audit complete" \
      "$verb [at=01700000000]: audit complete" \
      "$verb [at=99999999999999999999]: audit complete"; do
      if status_line_at_epoch "$line" >/dev/null; then fail "invented time for $line"; fi
      [ "$(status_line_verb "$line")" = "$verb" ] || fail "malformed time changed verb: $line"
      [ "$(status_line_note "$line")" = 'audit complete' ] \
        || fail "malformed time garbled the note: [$(status_line_note "$line")] from $line"
      [ "$(_fm_decision_key "$line")" = default ] \
        || fail "malformed time invented a decision key: [$(_fm_decision_key "$line")] from $line"
      status_is_captain_relevant "$line" \
        || fail "default vocabulary lost an actionable event: $line"
      printf '%s\n' "$line" > "$dir/state/task.status"
      event=$(status_span_first_actionable "$dir/state/task.status" 0) \
        || fail "default vocabulary hid actionable status span: $line"
      [ "$event" = "$line" ] || fail "classification changed surfaced event bytes: $event"
      # A tag the worker spelled wrong is still a tag, so it must not decide
      # whether the supervisor sees a terminal event - including a readable
      # timestamp whose colons would otherwise swallow the head/note separator.
      (
        FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'
        status_is_captain_relevant "$line" || exit 1
        exit 0
      ) || fail "override lost a terminal event to a malformed tag: $line"
      printf '%s\n' "$line" > "$dir/state/scan.status"
      (
        FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'
        event=$(last_status_line "$dir/state/scan.status")
        [ "$event" = "$line" ] || exit 1
      ) || fail "event scan lost a terminal event to a malformed tag: $line"
    done
  done
  pass "malformed event times stay ordinary line bytes without hiding the event"
}

# The decision fold reads the head/note separator on the same unstamped copy the
# note and key readers use, so a worker's mis-spelled time tag cannot decide
# whether a captain's decision survives. Without that, a readable "[at=17:00]"
# hands the fold a colon it never wrote: a colonless terminal line closes every
# open decision, and a colonless declaration opens a phantom one no later line
# can close.
test_malformed_event_time_never_moves_the_decision_fold() {
  local dir status tag
  dir=$(make_case fold-malformed-event-time)
  status="$dir/state/task.status"
  printf 'kind=ship\n' > "$dir/state/task.meta"
  for tag in '[at=17:00]' '[at=10:30]' '[at=2026-09-20T14:03:00Z]' '[at=<epoch>]' '[at=bad]'; do
    printf '%s\n%s\n' \
      'needs-decision [key=api-shape] [at=1700000000]: REST or gRPC?' \
      "done $tag finished the audit" > "$status"
    case "$(status_open_decisions "$status")" in
      'api-shape'$'\t''needs-decision'$'\t''REST or gRPC?') : ;;
      *) fail "malformed tag $tag closed an open decision: [$(status_open_decisions "$status")]" ;;
    esac
    printf '%s\n' "needs-decision $tag which base branch" > "$status"
    [ -z "$(status_open_decisions "$status")" ] \
      || fail "malformed tag $tag opened a phantom decision: [$(status_open_decisions "$status")]"
  done
  # The real separator still closes, so the tolerance above did not disarm the
  # terminal rule itself.
  printf '%s\n%s\n' \
    'needs-decision [key=api-shape] [at=1700000000]: REST or gRPC?' \
    'done [at=1700000001]: finished the audit' > "$status"
  [ -z "$(status_open_decisions "$status")" ] \
    || fail "a well-formed terminal event stopped closing the decision"
  pass "malformed event times never open or close a decision"
}

# --- decision keys, bracket tags, and per-key reads -------------------------

# These cases drive the REAL status_line_verb / status_open_decisions /
# status_open_decisions_incremental / status_key_closing_verb /
# status_event_recorded functions directly over crafted status files under
# their own $TMP_ROOT/decision-key/ subtree. They run ahead of the case list at
# the bottom, before test_optional_event_time sources
# bin/fm-parent-channel-lib.sh into this shell, so they see only the library
# sourced at the top.

# Fresh per-case dir so each case's incremental cursor sidecar cannot leak into
# another case.
case_dir() {  # <name>
  local d="$TMP_ROOT/decision-key/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Assert the whole-file fold of <status-file> equals <expected>, and that the
# incremental fold agrees with it on the exact same input - the two consumption
# strategies must never diverge on what is open.
assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_stated_key_is_honored_in_both_positions() {
  local dir before after expected
  dir=$(case_dir positions)
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/before.status"
  printf 'needs-decision: [key=api-shape] pick REST or RPC\n' > "$dir/after.status"
  expected=$(printf 'api-shape\tneeds-decision\tpick REST or RPC\n')

  assert_fold "$dir/before.status" "$expected" "documented before-colon form"
  assert_fold "$dir/after.status" "$expected" "colon-first form"

  # Equivalence is byte-for-byte: both positions yield the same key AND the
  # same note (a consumed note-head token is key metadata, not note text).
  before=$(status_open_decisions "$dir/before.status")
  after=$(status_open_decisions "$dir/after.status")
  [ "$before" = "$after" ] \
    || fail "the two key positions folded to different records: '$before' vs '$after'"
  pass "a stated [key=X] opens X whether it precedes or follows the verb colon"
}

test_bare_keyless_line_still_folds_to_default() {
  local dir
  dir=$(case_dir keyless)
  printf 'needs-decision: which color\n' > "$dir/bare.status"
  assert_fold "$dir/bare.status" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "bare keyless line"

  # And a bare keyless resolution still closes it - the historical
  # one-open-decision-per-task behavior is unchanged.
  printf 'resolved: went with blue\n' >> "$dir/bare.status"
  assert_fold "$dir/bare.status" "" "bare keyless resolution"
  pass "a keyless needs-decision still opens and closes the default key"
}

test_resolution_closes_across_positions() {
  local dir
  dir=$(case_dir cross-close)
  # Opened colon-first, closed in the documented form (what fm-send's
  # --resolve-key writes): the exact failure from issue #2109.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$dir/a.status"
  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$dir/a.status"
  assert_fold "$dir/a.status" "" "documented resolution closing a colon-first open"

  # And the mirror: opened documented, closed colon-first.
  printf 'needs-decision [key=seam-max-bound]: pick the bound\n' > "$dir/b.status"
  printf 'resolved: [key=seam-max-bound] answered: use 4\n' >> "$dir/b.status"
  assert_fold "$dir/b.status" "" "colon-first resolution closing a documented open"
  pass "a resolution closes its decision regardless of either line's key position"
}

test_blocked_is_position_tolerant_like_needs_decision() {
  local dir expected
  dir=$(case_dir blocked)
  expected=$(printf 'creds\tblocked\twaiting on the deploy token\n')
  printf 'blocked [key=creds]: waiting on the deploy token\n' > "$dir/before.status"
  printf 'blocked: [key=creds] waiting on the deploy token\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "$expected" "documented blocked form"
  assert_fold "$dir/after.status" "$expected" "colon-first blocked form"
  pass "blocked [key=X] opens X in both key positions"
}

test_two_colon_form_decisions_stay_distinct() {
  local dir expected
  dir=$(case_dir distinct)
  # The concrete hazard behind the silent collapse: two colon-form decisions on
  # one task used to share the default bucket, so answering one could close the
  # other. They must stay independently open and independently closable.
  printf 'needs-decision: [key=alpha] first question\n' > "$dir/t.status"
  printf 'needs-decision: [key=beta] second question\n' >> "$dir/t.status"
  expected=$(printf 'alpha\tneeds-decision\tfirst question\nbeta\tneeds-decision\tsecond question\n')
  assert_fold "$dir/t.status" "$expected" "two colon-form decisions"

  printf 'resolved [key=alpha]: answered: yes\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" "$(printf 'beta\tneeds-decision\tsecond question\n')" \
    "closing one of two colon-form decisions"
  pass "two colon-form keyed decisions never collapse into one shared bucket"
}

test_mid_note_prose_mention_is_not_a_stated_key() {
  local dir
  dir=$(case_dir prose)
  # Only a token at the head of the note states a key; a summary merely
  # mentioning "[key=x]" deeper in must neither open nor close that key.
  printf 'needs-decision: pick a [key=red] or [key=blue] theme\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\n')" \
    "mid-note prose mention"

  printf 'needs-decision [key=red]: which shade\n' >> "$dir/t.status"
  printf 'working: still thinking about [key=red] here\n' >> "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'default\tneeds-decision\tpick a [key=red] or [key=blue] theme\nred\tneeds-decision\twhich shade\n')" \
    "prose mention leaves the open set untouched"
  pass "a [key=x] mentioned mid-note is prose, never an opened or closed key"
}

test_malformed_stated_key_never_collapses_to_default() {
  local dir
  dir=$(case_dir malformed)
  # A stated-but-invalid slug is rejected in BOTH positions - identically,
  # and never rewritten into the shared default bucket.
  printf 'needs-decision [key=bad key]: before-colon malformed\n' > "$dir/before.status"
  printf 'needs-decision: [key=bad key] colon-first malformed\n' > "$dir/after.status"
  assert_fold "$dir/before.status" "" "malformed before-colon key"
  assert_fold "$dir/after.status" "" "malformed colon-first key"
  pass "a malformed stated key is rejected in both positions, never folded as default"
}

# A remote secondmate reply routinely prepends a "[corr=<hex>]" correlation
# tag ahead of "[key=...]" (issue: a remote reply's "needs-decision
# [corr=d448ea86afa4bf67] [key=x]: ..." folded to no open decision at all,
# because the verb parser only stripped a leading "[key=...]" token and left
# the corr tag glued onto the returned verb word). These cases drive the real
# status_line_verb directly, over every bracket-tag shape that precedes the
# colon, to pin the general fix: strip EVERY "[name=value]" tag there, not
# just "[key=...]", regardless of order or count.
test_status_line_verb_strips_every_bracket_tag_before_colon() {
  local v

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-then-key tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [key=loan-installment-cadence-amount] [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "key-then-corr tag order: got '$v'"

  v=$(status_line_verb 'needs-decision [corr=d448ea86afa4bf67]: fill in the terms')
  [ "$v" = "needs-decision" ] || fail "corr-only tag: got '$v'"

  v=$(status_line_verb 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token')
  [ "$v" = "blocked" ] || fail "blocked with corr+key: got '$v'"

  v=$(status_line_verb 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated')
  [ "$v" = "resolved" ] || fail "resolved with corr+key: got '$v'"

  pass "status_line_verb strips every bracket tag before the colon, in any order, and recovers the bare verb"
}

test_corr_and_key_tags_open_and_close_under_the_stated_key() {
  local dir expected
  dir=$(case_dir corr-and-key)
  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' \
    > "$dir/t.status"
  expected=$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')
  assert_fold "$dir/t.status" "$expected" "corr-then-key opens under the stated key"

  printf 'resolved [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: answered: monthly\n' \
    >> "$dir/t.status"
  assert_fold "$dir/t.status" "" "corr-then-key resolution closes the same stated key"
  pass "a [corr=...] tag ahead of [key=...] no longer swallows the verb: opens and closes under the stated key"
}

test_corr_only_tag_opens_as_default_like_a_bare_line() {
  local dir bare corred
  dir=$(case_dir corr-only)
  printf 'needs-decision: which vendor\n' > "$dir/bare.status"
  printf 'needs-decision [corr=d448ea86afa4bf67]: which vendor\n' > "$dir/corred.status"

  bare=$(status_open_decisions "$dir/bare.status")
  corred=$(status_open_decisions "$dir/corred.status")
  [ "$corred" = "$bare" ] \
    || fail "a corr-only tag folded differently than the bare line: '$corred' vs '$bare'"
  assert_fold "$dir/corred.status" "$(printf 'default\tneeds-decision\twhich vendor\n')" "corr-only tag"
  pass "a [corr=...] tag with no stated key opens under 'default', exactly like a bare needs-decision line"
}

test_key_only_before_colon_still_opens_no_regression() {
  local dir
  dir=$(case_dir key-only-no-corr)
  printf 'needs-decision [key=loan-installment-cadence-amount]: pick the cadence\n' > "$dir/t.status"
  assert_fold "$dir/t.status" \
    "$(printf 'loan-installment-cadence-amount\tneeds-decision\tpick the cadence\n')" \
    "key-only before colon, no corr tag"
  pass "a [key=x] tag alone (no corr tag) still opens x - no regression from the tag-stripping fix"
}

test_blocked_and_resolved_are_tag_order_independent() {
  local dir
  dir=$(case_dir blocked-tag-order)
  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/a.status"
  assert_fold "$dir/a.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked corr-then-key"

  printf 'blocked [key=creds] [corr=aaaa1111bbbb2222]: waiting on the deploy token\n' > "$dir/b.status"
  assert_fold "$dir/b.status" "$(printf 'creds\tblocked\twaiting on the deploy token\n')" \
    "blocked key-then-corr"

  printf 'blocked [corr=aaaa1111bbbb2222] [key=creds]: waiting on the deploy token\n' > "$dir/c.status"
  printf 'resolved [corr=aaaa1111bbbb2222] [key=creds]: answered: rotated\n' >> "$dir/c.status"
  assert_fold "$dir/c.status" "" "blocked/resolved corr+key close together regardless of tag order"
  pass "blocked/resolved parse their bare verb with any bracket-tag order preceding the colon"
}

test_incremental_agrees_with_full_fold_across_appends() {
  local dir f expected
  dir=$(case_dir incremental)
  f="$dir/t.status"
  # assert_fold already pins incremental==full per snapshot; this case pins the
  # agreement ACROSS appends, where the incremental path folds only the new
  # bytes on top of its persisted open set while the full fold re-reads
  # everything from scratch.
  printf 'needs-decision: [key=seam-max-bound] pick the bound\n' > "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\n')
  assert_fold "$f" "$expected" "colon-first open, first read"

  printf 'working: routine progress note\n' >> "$f"
  printf 'needs-decision: [key=other] a second colon-form question\n' >> "$f"
  expected=$(printf 'seam-max-bound\tneeds-decision\tpick the bound\nother\tneeds-decision\ta second colon-form question\n')
  assert_fold "$f" "$expected" "colon-first opens buried under later appends"

  printf 'resolved [key=seam-max-bound]: answered: use 4\n' >> "$f"
  printf 'resolved: [key=other] cleared on its own\n' >> "$f"
  assert_fold "$f" "" "cross-position resolutions close both"
  pass "the incremental fold matches the full fold across appends in both key positions"
}

test_stated_key_is_honored_in_both_positions
test_bare_keyless_line_still_folds_to_default
test_resolution_closes_across_positions
test_blocked_is_position_tolerant_like_needs_decision
test_two_colon_form_decisions_stay_distinct
test_mid_note_prose_mention_is_not_a_stated_key
test_malformed_stated_key_never_collapses_to_default
test_status_line_verb_strips_every_bracket_tag_before_colon
test_corr_and_key_tags_open_and_close_under_the_stated_key
test_corr_only_tag_opens_as_default_like_a_bare_line
test_key_only_before_colon_still_opens_no_regression
test_blocked_and_resolved_are_tag_order_independent
test_incremental_agrees_with_full_fold_across_appends

# status_key_closing_verb reports HOW the status side currently reads one key,
# which is what lets a consumer tell a settled key from a key handed to a
# durable captain-held task. The two closing verbs must stay distinguishable:
# `resolved` claims the question is settled outright, while `captain-held` is
# the verified transfer to that task, so treating them alike would either lose
# the record-divergence signal or invent one on every correct transfer.
test_closing_verb_separates_resolution_from_durable_transfer() {
  local dir f
  dir=$(case_dir closing-verb)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
working: started
needs-decision [key=route]: north or south
resolved [key=route]: answered: north
needs-decision [key=access]: open or restricted
captain-held [key=access]: tracked by sample-access-call
blocked [key=creds]: need the deploy token
done: everything else shipped
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a resolved key did not report the resolve verb: '$(status_key_closing_verb "$f" route)'"
  [ "$(status_key_closing_verb "$f" access)" = captain-held ] \
    || fail "a durable-transfer close reported the wrong verb: '$(status_key_closing_verb "$f" access)'"
  [ "$(status_key_closing_verb "$f" creds)" = blocked ] \
    || fail "a still-open key must report its opening verb: '$(status_key_closing_verb "$f" creds)'"
  [ -z "$(status_key_closing_verb "$f" never-mentioned)" ] \
    || fail "a key with no transition line reported a verb"
  [ -z "$(status_key_closing_verb "$dir/absent.status" route)" ] \
    || fail "an absent status file reported a verb"
  pass "status_key_closing_verb separates resolution, durable transfer, and still-open"
}

# The reported verb is the LAST transition, read through the same fold rule as
# everything else: the colon-first key position counts, a re-opened key reports
# open again, and a prose mention is never a transition.
test_closing_verb_tracks_the_last_transition_in_both_positions() {
  local dir f
  dir=$(case_dir closing-verb-last)
  f="$dir/a.status"
  cat > "$f" <<'EOF'
needs-decision: [key=route] colon-first open
resolved: [key=route] colon-first close
EOF
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a colon-first resolution was not seen: '$(status_key_closing_verb "$f" route)'"

  printf 'needs-decision [key=route]: re-opened after a bad answer\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
    || fail "a re-opened key still reported closed: '$(status_key_closing_verb "$f" route)'"

  printf 'resolved [key=route]: answered: south after all\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "the last of several transitions was not reported: '$(status_key_closing_verb "$f" route)'"

  printf 'working: a later append that only mentions [key=route] as prose\n' >> "$f"
  [ "$(status_key_closing_verb "$f" route)" = resolved ] \
    || fail "a prose mention changed the reported verb: '$(status_key_closing_verb "$f" route)'"
  pass "status_key_closing_verb reports the last real transition, in either key position"
}

test_closing_verb_separates_resolution_from_durable_transfer
test_closing_verb_tracks_the_last_transition_in_both_positions

# The per-key read pre-selects candidate lines by their leading verb before the
# bash fold sees them, and the resolve/durable-transfer verbs are overridable, so
# an overridden verb buried behind unrelated history must still close its key.
test_closing_verb_honors_overridden_transition_verbs() {
  local dir f i
  dir=$(case_dir closing-verb-overrides)
  f="$dir/task.status"
  printf 'kind=ship\n' > "$dir/task.meta"
  printf 'blocked [key=route]: waiting\n' > "$f"
  for ((i = 0; i < 200; i++)); do
    printf 'note: routine reply\nworking: still going\nContinuation prose here.\n' >> "$f"
  done
  printf 'answered [key=route]: settled\n' >> "$f"
  [ "$(FM_CLASSIFY_RESOLVE_VERB=answered status_key_closing_verb "$f" route)" = answered ] \
    || fail "an overridden resolve verb stopped closing its key"
  [ "$(status_key_closing_verb "$f" route)" = blocked ] \
    || fail "without the override the same line must leave the key open"
  printf 'blocked [key=access]: waiting\nawaiting-captain [key=access]: handed off\n' >> "$f"
  [ "$(FM_CLASSIFY_CAPTAIN_HELD_VERB=awaiting-captain status_key_closing_verb "$f" access)" = awaiting-captain ] \
    || fail "an overridden durable-transfer verb stopped closing its key"
  pass "overridden resolve and durable-transfer verbs still close keys behind unrelated history"
}

test_closing_verb_filters_unrelated_history_without_subshell_growth() {
  local dir f want tag size i level small large
  dir=$(case_dir closing-verb-processes)
  f="$dir/task.status"
  printf 'kind=secondmate\n' > "$dir/task.meta"
  for want in route default; do
    tag="[key=$want]"
    [ "$want" != default ] || tag=''
    for size in 1 1000; do
      printf 'blocked corr=0123456789abcdef %s: waiting\n' "$tag" > "$f"
      for ((i = 0; i < size; i++)); do
        printf 'note: routine reply\nworking: mentions [key=%s] in prose\ndone: another task finished\nfailed: unrelated work\nPR ready https://example.com/pull/1\n\n' "$want" >> "$f"
        if [ "$want" != default ]; then
          printf 'blocked [key=other]: another question\nresolved [key=other]: answered\n' >> "$f"
        fi
      done
      printf 'resolved corr=0123456789abcdef: %s answered\nnote: cleanup complete\n' "$tag" >> "$f"
      : > "$dir/children-$size"
      (
        level=$BASH_SUBSHELL
        set -T
        trap 'if [ "$BASH_SUBSHELL" -gt "$level" ]; then printf x >> "$dir/children-$size"; fi' DEBUG
        status_key_closing_verb "$f" "$want" > "$dir/output"
      )
      [ "$(cat "$dir/output")" = resolved ] || fail "$want lost its resolution behind unrelated history"
    done
    small=$(wc -c < "$dir/children-1")
    large=$(wc -c < "$dir/children-1000")
    [ "$large" -le "$((small + 20))" ] || fail "$want launches subprocess work for unrelated history ($small -> $large)"
  done
  pass "per-key reads retain resolutions without subprocess work growing with unrelated history"
}

test_closing_verb_filter_preserves_terminal_chronology() {
  local dir f kind want tag terminal expected
  dir=$(case_dir closing-verb-terminals)
  f="$dir/task.status"
  for kind in ship scout secondmate; do
    printf 'kind=%s\n' "$kind" > "$dir/task.meta"
    for want in access default; do
      tag="[key=$want]"
      [ "$want" != default ] || tag=''
      for terminal in 'done' failed; do
        printf 'blocked %s: waiting\n' "$tag" > "$f"
        case "$terminal" in
          done) printf 'done: report saved\n' >> "$f" ;;
          failed) printf 'failed corr=0123456789abcdef [key=other]: task failed\n' >> "$f" ;;
        esac
        printf 'note: cleanup complete\n' >> "$f"
        expected=$terminal
        [ "$kind" != secondmate ] || expected=blocked
        [ "$(status_key_closing_verb "$f" "$want")" = "$expected" ] || fail "$kind/$want lost $terminal chronology"
        printf 'needs-decision: [key=%s] reopened\nnote: more cleanup\n' "$want" >> "$f"
        [ "$(status_key_closing_verb "$f" "$want")" = needs-decision ] || fail "$kind/$want lost a post-terminal reopening"
      done
    done
  done
  pass "per-key filtering retains ship/scout terminals, reopenings, and secondmate blockers"
}

test_closing_verb_filters_unrelated_history_without_subshell_growth
test_closing_verb_honors_overridden_transition_verbs
test_closing_verb_filter_preserves_terminal_chronology

test_bare_prose_cannot_impersonate_a_terminal_declaration() {
  local dir f kind word open
  dir=$(case_dir prose-terminal)
  open=$(printf 'route\tneeds-decision\tA or B?\n')
  for kind in ship scout; do
    for word in 'done' failed; do
      f="$dir/$kind-$word.status"
      printf 'kind=%s\n' "$kind" > "$dir/$kind-$word.meta"
      printf 'needs-decision [key=route]: A or B?\npaused: waiting on the vendor\nSteps remaining:\n %s\n' \
        "$word" > "$f"
      assert_fold "$f" "$open" "$kind: bare '$word' prose"
      [ "$(status_key_closing_verb "$f" route)" = needs-decision ] \
        || fail "$kind: bare '$word' prose closed a still-open key"
      f="$dir/$kind-$word-real.status"
      printf 'kind=%s\n' "$kind" > "$dir/$kind-$word-real.meta"
      printf 'needs-decision [key=route]: A or B?\n%s: real outcome\n' "$word" > "$f"
      assert_fold "$f" '' "$kind: genuine $word supersedes"
      [ "$(status_key_closing_verb "$f" route)" = "$word" ] \
        || fail "$kind: genuine $word no longer supersedes the open key"
    done
  done
  pass "prose without a colon cannot impersonate a ship or scout terminal declaration"
}

test_bare_prose_cannot_impersonate_a_terminal_declaration

test_bare_prose_cannot_open_or_close_a_decision() {
  local dir f word blocked
  dir=$(case_dir prose-decision)
  blocked=$(printf 'default\tblocked\tneed release access\n')
  for word in blocked needs-decision resolved; do
    f="$dir/open-$word.status"
    printf 'kind=ship\n' > "$dir/open-$word.meta"
    printf 'working: investigating the deploy\nOptions considered:\n %s\n' "$word" > "$f"
    assert_fold "$f" '' "bare '$word' prose opened a decision"

    f="$dir/close-$word.status"
    printf 'kind=ship\n' > "$dir/close-$word.meta"
    printf 'blocked: need release access\nSteps remaining:\n %s\n' "$word" > "$f"
    assert_fold "$f" "$blocked" "bare '$word' prose moved an open decision"
  done

  f="$dir/keyed-colonless.status"
  printf 'kind=ship\n' > "$dir/keyed-colonless.meta"
  printf 'blocked [key=access]\n' > "$f"
  assert_fold "$f" "$(printf 'access\tblocked\tblocked [key=access]\n')" \
    "a keyed colonless line stopped opening its key"
  printf 'resolved [key=access]\n' >> "$f"
  assert_fold "$f" '' "a keyed colonless line stopped closing its key"

  f="$dir/real-resolution.status"
  printf 'kind=ship\n' > "$dir/real-resolution.meta"
  printf 'blocked: need release access\nresolved: access granted\n' > "$f"
  assert_fold "$f" '' "a genuine resolution stopped closing its decision"
  pass "only a colon-bearing or keyed line is a decision transition in the fold"
}

# A stated [key=default] is the shared decision bucket --resolve-key default
# writes. It must keep closing a keyless decision, and it must not cancel a
# keyless live wait that only prints as default. A worker's own keyless
# resolved: still retracts that wait, and neither form closes a differently
# keyed wait.
test_keyless_wait_survives_stated_default_retraction() {
  local dir f
  dir=$(case_dir keyless-wait)
  f="$dir/live.status"
  printf 'needs-decision: which color\n' > "$f"
  printf 'paused: waiting on the vendor release\n' >> "$f"
  assert_fold "$f" "$(printf 'default\tneeds-decision\twhich color\n')" \
    "keyless decision stays open beside the wait"
  [ "$(status_open_activities "$f")" = "$(printf 'default\tpaused\twaiting on the vendor release\n')" ] \
    || fail "keyless pause did not open as its own default phase: '$(status_open_activities "$f")'"

  printf 'resolved [key=default]: answered: blue\n' >> "$f"
  assert_fold "$f" "" "stated default retraction closes the keyless decision"
  [ "$(status_open_activities "$f")" = "$(printf 'default\tpaused\twaiting on the vendor release\n')" ] \
    || fail "stated default retraction cancelled the unrelated keyless wait: '$(status_open_activities "$f")'"

  printf 'paused: waiting on the vendor release\nresolved: [key=default] answered: blue\n' \
    > "$dir/colon-first.status"
  [ "$(status_open_activities "$dir/colon-first.status")" = "$(printf 'default\tpaused\twaiting on the vendor release\n')" ] \
    || fail "a colon-first stated default retraction cancelled the keyless wait: '$(status_open_activities "$dir/colon-first.status")'"

  printf 'paused: waiting on the vendor release\n' > "$dir/self.status"
  printf 'resolved: the vendor shipped\n' >> "$dir/self.status"
  [ -z "$(status_open_activities "$dir/self.status")" ] \
    || fail "a keyless self-retraction left the keyless wait open: '$(status_open_activities "$dir/self.status")'"

  printf 'paused [key=legal]: awaiting counsel\n' > "$dir/keyed.status"
  printf 'resolved [key=default]: answered: blue\n' >> "$dir/keyed.status"
  printf 'resolved: unrelated keyless close\n' >> "$dir/keyed.status"
  [ "$(status_open_activities "$dir/keyed.status")" = "$(printf 'legal\tpaused\tawaiting counsel\n')" ] \
    || fail "a default or keyless retraction closed a keyed wait: '$(status_open_activities "$dir/keyed.status")'"

  printf 'paused [key=default]: named default wait\n' > "$dir/stated.status"
  printf 'resolved [key=default]: that wait cleared\n' >> "$dir/stated.status"
  [ -z "$(status_open_activities "$dir/stated.status")" ] \
    || fail "a stated default retraction did not close the stated default wait"

  printf 'working: legacy start\ndone: legacy completion\n' > "$dir/legacy.status"
  [ -z "$(status_open_activities "$dir/legacy.status")" ] \
    || fail "a keyless terminal stopped superseding the keyless working phase"

  printf 'paused: waiting on the vendor release\nneeds-decision [key=default]: which color\n' \
    > "$dir/stated-open.status"
  [ "$(status_open_activities "$dir/stated-open.status")" = "$(printf 'default\tpaused\twaiting on the vendor release\n')" ] \
    || fail "a stated default decision cancelled the keyless wait: '$(status_open_activities "$dir/stated-open.status")'"
  pass "a stated default retraction closes its decision and leaves an unrelated keyless wait standing"
}

# The supervisors' declared-wait read keeps a pause standing behind answers
# for other keys even when those answers outrun the bounded tail window, and a
# resolved line for the pause's own key still retracts it from there.
test_declared_wait_survives_answers_past_the_event_window() {
  local dir f i
  dir=$(case_dir declared-wait-window)
  f="$dir/answered.status"
  printf 'needs-decision: which color\npaused: waiting on the vendor release\n' > "$f"
  i=0
  while [ "$i" -le "$FM_CLASSIFY_EVENT_WINDOW_LINES" ]; do
    printf 'resolved [key=q%s]: answered\n' "$i" >> "$f"
    i=$((i + 1))
  done
  printf 'resolved [key=default]: answered: blue\n' >> "$f"
  [ "$(status_declared_wait_line "$f")" = 'paused: waiting on the vendor release' ] \
    || fail "answers past the event window cancelled the wait: '$(status_declared_wait_line "$f")'"
  printf 'resolved: the vendor shipped\n' >> "$f"
  [ -z "$(status_declared_wait_line "$f")" ] \
    || fail "the worker's own keyless resolved line did not retract the wait past the window"
  pass "a declared wait outlives answers for other keys beyond the event window, and its own resolved line retracts it"
}

test_keyless_wait_survives_stated_default_retraction
test_declared_wait_survives_answers_past_the_event_window
test_bare_prose_cannot_open_or_close_a_decision

# status_event_recorded is an idempotent retry check: a stamped retry matches,
# and no later resolved line - for another key, outside the reserved-key
# vocabulary, or the real close of that key - makes a recorded line new again.
# The same holds for a note and a done line.
test_recorded_line_stays_recorded_across_a_resolve() {
  local dir f line
  dir=$(case_dir episode)
  f="$dir/task.status"
  line='blocked [key=pending-reply-abc]: pending-reply-delivery-unknown: task=mate pending-reply-id=abc request=wake'
  printf '%s\n' "$line" > "$f"
  status_event_recorded "$f" "$line" \
    || fail "the open blocker was not recorded"
  status_event_recorded "$f" \
    "blocked [key=pending-reply-abc] [at=1700000000]: pending-reply-delivery-unknown: task=mate pending-reply-id=abc request=wake" \
    || fail "a stamp made the recorded blocker look new"
  printf '%s\n' 'resolved [key=other]: answered elsewhere' >> "$f"
  status_event_recorded "$f" "$line" \
    || fail "another key's resolve made the blocker look new"
  printf '%s\n' 'resolved [key=pending-reply-abc]: answered: not this library' >> "$f"
  status_event_recorded "$f" "$line" \
    || fail "a reserved-key resolve outside the vocabulary made the blocker look new"
  printf '%s\n' 'resolved [key=pending-reply-abc] [at=1700000001]: pending-reply-resolved: task=mate pending-reply-id=abc via=operator-resolve-key dismiss' >> "$f"
  [ -z "$(status_open_decisions "$f")" ] \
    || fail "the resolve did not close the decision: $(status_open_decisions "$f")"
  status_event_recorded "$f" "$line" \
    || fail "the resolve of its own key made the blocker look new"
  printf '%s\n' 'note: remote document did not transfer for ios: data/reply/missing.md - absent' \
    > "$dir/note.status"
  printf '%s\n' 'resolved: closed the default decision' >> "$dir/note.status"
  status_event_recorded "$dir/note.status" \
    'note: remote document did not transfer for ios: data/reply/missing.md - absent' \
    || fail "a resolve made a note look new"
  printf '%s\n' 'done [corr=abcd]: shipped' > "$dir/done.status"
  printf '%s\n' 'resolved [key=default]: closed' >> "$dir/done.status"
  status_event_recorded "$dir/done.status" 'done [corr=abcd]: shipped' \
    || fail "a resolve made a done line look new"
  pass "a recorded line stays recorded across a later resolve"
}

test_recorded_line_stays_recorded_across_a_resolve

test_captain_override_ignores_event_time
test_malformed_event_time_is_ordinary_bytes
test_malformed_event_time_never_moves_the_decision_fold
test_optional_event_time
test_tokened_opener_opens_and_tokened_closer_closes
test_token_is_read_through_in_every_position_it_is_written_in
test_untokened_pair_is_unchanged
test_prose_and_malformed_tokens_never_become_transitions
test_token_first_word_never_impersonates_a_transition
test_captain_relevance_and_pause_are_unchanged_without_a_token
test_consumer_verdicts_read_through_the_token
test_daemon_and_crew_state_case_arms_read_through_the_token
test_pending_reply_escalation_matching_is_unaffected
test_incremental_and_whole_file_folds_agree_over_correlated_lines
test_a_cursor_written_before_this_change_is_rebuilt
test_the_real_writers_produce_tokens_this_library_reads
