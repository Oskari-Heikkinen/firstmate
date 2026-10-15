#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

# The assertions below check what the rendered block names (commands, tools,
# paths, state tokens, headings) rather than the sentences around them, so a
# wording-only edit to a protocol file does not break them.

# assert_mode <text> <harness-word> <msg>: exactly one protocol "Mode:" heading,
# and it names the harness.
assert_mode() {
  local modes
  modes=$(printf '%s\n' "$1" | grep '^Mode: ')
  [ "$(printf '%s\n' "$modes" | grep -c '^Mode: ')" -eq 1 ] || fail "$3 (Mode headings: '$modes')"
  assert_contains "$modes" "$2" "$3"
}

# assert_line_has <text> <msg> <needle>...: one line of <text> holds every
# fixed-string needle, so a rule's parts stay tied together.
assert_line_has() {
  local text=$1 msg=$2 line needle ok
  shift 2
  while IFS= read -r line; do
    ok=1
    for needle in "$@"; do
      case "$line" in *"$needle"*) ;; *) ok=0; break ;; esac
    done
    [ "$ok" -eq 0 ] || return 0
  done <<< "$text"
  fail "$msg (no one line holds: $*)"$'\n'"--- output ---"$'\n'"$text"
}

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_mode "$out" Codex "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "bin/fm-claude-stop-autoarm.sh" "renderer printed the claude snippet too"
  assert_not_contains "$out" "fm_watch_arm_pi" "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

# Every Claude home requires explicit opt-in. No file or an off file renders
# the plain block; an opt-in file adds the host protocol to that block.
test_supervision_host_protocol_on_an_opted_in_claude_home() {
  local home config plain hosted other body
  home="$TMP_ROOT/host-home"
  config="$TMP_ROOT/host-config"
  mkdir -p "$home/state" "$config"
  : > "$config/supervision-host-off"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)
  assert_not_contains "$plain" "Supervision host" "a claude home opted out by config/supervision-host-off rendered the host protocol"
  rm -f "$config/supervision-host-off"
  assert_equals "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)" "$plain" \
    "a Claude home without config/supervision-host must render the plain protocol"
  : > "$config/supervision-host"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)
  assert_contains "$hosted" "- Supervision host: on" "an opted-in claude home did not render the host state line"
  assert_mode "$hosted" Claude "the host protocol replaced the claude protocol instead of adding to it"
  body=$(printf '%s\n' "$hosted" | sed -n '/^Supervision host: on/,$p')
  [ -n "$body" ] || fail "an opted-in claude home rendered no host protocol"
  assert_contains "$body" "\`supervision-host:\`" "the host protocol did not point main at the host's own lines"
  assert_line_has "$body" "the host protocol did not say a handed-back wake is not the captain's return" \
    "captain's return" "\`afk\`"
  [ "$(printf '%s\n' "$hosted" | grep -v '^- Supervision host: on' | head -n "$(printf '%s\n' "$plain" | wc -l)")" = "$plain" ] \
    || fail "the host protocol changed the claude block it should only append to"
  other=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness pi)
  assert_not_contains "$other" "Supervision host" "a pi primary rendered the host protocol"
  rm -f "$config/supervision-host"
  other=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness pi)
  assert_not_contains "$other" "Supervision host" "a pi primary without config/supervision-host rendered the host protocol"
  pass "renderer adds the supervision-host protocol on an opted-in claude home unless config/supervision-host-off opts it out, leaving the claude block intact"
}

# Each non-Pi arm owner gets the host protocol in its own terms, and only its
# own terms; Grok's model-owned arm command becomes the host; a home with
# config/supervision-host-off, or a non-Claude home without the file, renders exactly what
# it did before, with no tag or placeholder.
test_supervision_host_protocol_on_every_arm_owner() {
  local home config harness plain hosted body
  home="$TMP_ROOT/host-owners-home"
  config="$TMP_ROOT/host-owners-config"
  mkdir -p "$home/state" "$config"
  for harness in claude cursor opencode omp grok codex; do
    : > "$config/supervision-host-off"
    plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness "$harness")
    assert_not_contains "$plain" "Supervision host" "$harness: a home opted out by config/supervision-host-off rendered the host protocol"
    assert_not_contains "$plain" "__FM_" "$harness: a placeholder leaked into the rendered block"
    if [ "$harness" != claude ]; then
      rm -f "$config/supervision-host" "$config/supervision-host-off"
      assert_equals "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness "$harness")" "$plain" \
        "$harness: a home without config/supervision-host must render the plain block"
    fi
    rm -f "$config/supervision-host-off"
    : > "$config/supervision-host"
    hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness "$harness")
    assert_contains "$hosted" "- Supervision host: on" \
      "$harness: an opted-in home did not render the host state line"
    body=$(printf '%s\n' "$hosted" | sed -n '/^Supervision host: on/,$p')
    [ -n "$body" ] || fail "$harness: the host protocol is missing"
    printf '%s\n' "$body" | grep -E '^\{[a-z,]+\} ' >/dev/null && fail "$harness: a harness tag leaked into the rendered protocol: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^Attended')" -eq 1 ] \
      || fail "$harness: the protocol must say exactly once what happens attended: $body"
    [ "$(printf '%s\n' "$body" | grep -F "captain's return" | grep -cF "\`afk\`")" -eq 1 ] \
      || fail "$harness: the protocol must say once that a handed-back away wake is not the return and that afk owns it: $body"
    case "$harness" in
      claude|cursor)
        assert_line_has "$body" "$harness: the attended line did not say the branch takes eligible wakes" \
          'Attended' 'supervision branch'
        assert_line_has "$body" "$harness: the branch-outcome line lost its current-state processing rule" \
          "\`supervision-host: branch-outcome: ...\`" "\`bin/fm-wake-drain.sh\`" "\`BRANCH OUTCOMES\`" 'current state'
        assert_line_has "$body" "$harness: the branch-outcome line lost its still-open-only rule" \
          "\`supervision-host: branch-outcome: ...\`" 'still open'
        assert_line_has "$body" "$harness: the branch-outcome line lost its acknowledgement" \
          "\`supervision-host: branch-outcome: ...\`" "\`mark-processed\`"
        ;;
      *)
        assert_line_has "$body" "$harness: the attended line did not say every wake reaches main" 'Attended' 'every wake'
        assert_not_contains "$body" "BRANCH OUTCOMES" "$harness: a harness with no attended branch rendered the branch-outcome rule"
        ;;
    esac
  done
  rm -f "$config/supervision-host"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$plain" 'exec bin/fm-watch-arm.sh`' "grok without the file must arm the plain watcher"
  : > "$config/supervision-host-off"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$plain" 'exec bin/fm-watch-arm.sh`' "grok with an off file must arm the plain watcher"
  rm -f "$config/supervision-host-off"
  : > "$config/supervision-host"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok)
  assert_contains "$hosted" 'exec bin/fm-supervision-host.sh park`' "grok with the file must arm the supervision host"
  assert_not_contains "$hosted" 'bin/fm-watch-arm.sh' "grok with the file must re-arm the supervision host, not the plain arm"
  assert_line_has "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --repair-line)" \
    "grok's repair line must name the host" 'bin/fm-supervision-host.sh park' 'Grok' 'background'
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex)
  assert_contains "$hosted" 'FM_CODEX_WATCH_CHECKPOINT_AWAY' "codex must learn that an away checkpoint holds longer"
  assert_contains "$hosted" 'checkpoint: no actionable wake within' "codex must learn how the park boundary arrives"
  pass "renderer gives each non-Pi arm owner the host protocol in its own terms, and grok arms the host"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_mode "$out" Unknown "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_mode "$out" Codex "codex snippet missing"
  assert_not_contains "$out" "\`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_quiet_mode_stanzas() {
  local home config out
  home="$TMP_ROOT/quiet-home"
  config="$TMP_ROOT/quiet-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --afk 1 --afk-mode quiet)
  assert_contains "$out" "- Quiet mode: active" "quiet stanza missing"
  assert_line_has "$out" "quiet stanza did not name the /quiet skill" '- Quiet mode: active' '/quiet'
  assert_line_has "$out" "quiet stanza lost the explicit-only exit rule" '- Quiet mode: active' '/quiet off'
  assert_not_contains "$out" "- Away mode: active" "quiet mode incorrectly rendered as away mode"
  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --afk-mode quiet --repair-line)
  assert_contains "$out" "/quiet" "quiet repair line did not name /quiet"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1)
  assert_contains "$out" "- Away mode: active" "omitting --afk-mode did not default to away (regression)"
  assert_not_contains "$out" "Quiet mode" "omitting --afk-mode leaked quiet-mode text"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --afk-mode not-a-real-mode)
  assert_contains "$out" "- Away mode: active" "unrecognized --afk-mode value did not fall back to away"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 0)
  assert_not_contains "$out" "Away mode" "an inactive away posture still rendered an away line"
  assert_not_contains "$out" "Quiet mode" "an inactive quiet posture still rendered a quiet line"
  assert_not_contains "$out" "X mode" "an inactive X mode still rendered an X-mode line"
  pass "renderer's away/quiet stanzas are mode-aware, default to away, and fall back safely on garbage input"
}

test_repair_lines() {
  local home out plain
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  plain=$(FM_HOME="$home" "$RENDER" --harness claude --repair-line)
  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  case "$out" in
    ?*"$plain") assert_contains "${out%"$plain"}" "queued wakes" "queue-pending prefix missing" ;;
    *) fail "queue-pending prefix missing (expected a prefix before '$plain', got '$out')" ;;
  esac
  assert_line_has "$out" "claude pre-verification repair line is not neutral" 'Stop' 'hook'
  assert_not_contains "$out" "is broken" "claude pre-verification repair line claimed a verified mechanism failure"
  assert_not_contains "$out" "FAILED" "claude pre-verification repair line emitted a verified failure notice"
  assert_not_contains "$out" "manual background" "claude pre-verification repair line directed a manual background arm"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude pre-verification repair line directed an arm command"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_line_has "$out" "x-mode repair line did not source the effective cadence config" 'source' "'$home/config/x-mode.env'"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "x-mode codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_line_has "$out" "read-only repair line missing" 'fleet lock' 'read-only'

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "/fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  out=$(FM_HOME="$home" "$RENDER" --harness omp --repair-line)
  assert_contains "$out" "fm_watch_arm_omp" "omp repair line does not direct the model to the extension-owned tool"
  assert_contains "$out" ".omp/extensions/fm-primary-turnend-guard.ts" "omp repair line does not name its own turn-end extension"
  assert_not_contains "$out" "fm_watch_arm_pi" "omp repair line must not borrow the Pi tool"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_cross_harness_ordinary_continuation_and_repair_matrix() {
  local ordinary out

  out=$("$RENDER" --harness pi)
  assert_not_contains "$out" "- Ordinary wake:" "pi rendered a separate ordinary-wake line its protocol already states"
  assert_line_has "$out" "pi protocol does not leave ordinary-wake continuity to the extension" \
    "\`fm_watch_arm_pi\`" 'again' 'ordinary wakes'
  out=$("$RENDER" --harness pi --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness omp)
  assert_contains "$out" "primary harness: omp" "omp heading missing"
  assert_mode "$out" omp "omp snippet missing"
  assert_line_has "$out" "omp ordinary-wake line does not leave continuity to the extension" '- Ordinary wake:' 'extension'
  assert_contains "$out" ".omp/extensions/fm-primary-omp-watch.ts" "omp snippet did not substitute its watch extension path"
  assert_not_contains "$out" "__FM_OMP_EXT__" "omp snippet left a placeholder unsubstituted"
  assert_not_contains "$out" "__FM_OMP_TURNEND_EXT__" "omp snippet left the turn-end placeholder unsubstituted"
  assert_not_contains "$out" "project trust" "omp snippet must not carry Pi's trust prerequisite"
  out=$("$RENDER" --harness omp --repair-line)
  assert_contains "$out" "fm_watch_arm_omp" "omp recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness opencode)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "plugin" "opencode ordinary-wake line does not leave continuity to the plugin"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "opencode ordinary-wake line incorrectly calls the recovery probe"
  out=$("$RENDER" --harness opencode --repair-line)
  assert_line_has "$out" "opencode recovery line lost its manual probe" 'bin/fm-watch-arm.sh' 'manual'

  out=$("$RENDER" --harness claude)
  assert_not_contains "$out" "- Ordinary wake:" "claude rendered a separate ordinary-wake line its protocol already states"
  assert_contains "$out" "\`bin/fm-claude-stop-autoarm.sh\`" "claude protocol does not leave continuity to the Stop hook"
  assert_line_has "$out" "claude protocol does not forbid a model arm after an ordinary wake" \
    'never' "\`bin/fm-watch-arm.sh\`" 'ordinary wake'
  out=$("$RENDER" --harness claude --repair-line)
  assert_line_has "$out" "claude recovery line lost its neutral automatic-recovery guidance" 'Stop' 'hook'
  assert_not_contains "$out" "is broken" "claude recovery line claimed failure before verification"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude recovery line must not create a repeatable manual arm loop"

  out=$("$RENDER" --harness grok)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "grok ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "background" "grok ordinary-wake line lost tracked background ownership"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "grok ordinary-wake line lost the background arm command"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "background" "grok recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok recovery line lost the arm command"

  out=$("$RENDER" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "foreground" "codex ordinary-wake line lost its foreground checkpoint"
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "codex ordinary-wake line lost the checkpoint command"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codex ordinary-wake line incorrectly uses a background arm"
  out=$("$RENDER" --harness codex --repair-line)
  assert_contains "$out" "foreground" "codex recovery line lost its checkpoint repair"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex recovery line lost the checkpoint command"

  pass "renderer preserves every harness ordinary-continuation and missing-cycle repair path"
}

test_pi_signed_preserves_identity_with_pi_supervision_protocol() {
  local out
  out=$("$RENDER" --harness pi-signed)
  assert_contains "$out" "primary harness: pi-signed" \
    "pi-signed supervision normalized the visible runtime identity to pi"
  assert_mode "$out" Pi "pi-signed did not reuse Pi's authoritative supervision protocol"
  [ "$out" = "$("$RENDER" --harness pi | sed 's/primary harness: pi$/primary harness: pi-signed/')" ] \
    || fail "pi-signed supervision semantics diverged from Pi"
  out=$("$RENDER" --harness pi-signed --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi-signed repair semantics diverged from Pi"
  pass "pi-signed keeps its identity while sharing Pi's supervision protocol"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_mode "$out" Grok "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "bin/fm-watch-checkpoint.sh" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "background" "grok repair line is not background-notify shaped"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_grok_command_sources_effective_config() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; exec bin/fm-watch-arm.sh" "grok arm command did not use the effective x-mode config path"
  pass "grok rendered command sources the effective x-mode config"
}

test_pi_repair_line_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "-e $turnend -e $watch" "pi repair line did not render both effective extension launch paths"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  pass "pi repair line renders the effective extension paths"
}

# The kept per-harness lines are each the fix for an observed mistake: a model
# re-arming the Claude watcher, a Pi foreground arm that wedged the agent, and a
# finished worker answered with a bare no-op reply. Each rule must survive, checked
# by the commands, tools, and tokens it ties together on its line; the Pi
# regression example is the one line its protocol itself says to keep verbatim.
test_claude_protocol_keeps_its_mistake_lines() {
  local out
  out=$("$RENDER" --harness claude)
  assert_contains "$out" "\`Stop hook feedback\`" "claude protocol lost how a wake arrives"
  assert_line_has "$out" "claude protocol lost drain-first on a wake" \
    "\`Stop hook feedback\`" "\`bin/fm-wake-drain.sh\`" 'first'
  assert_line_has "$out" "claude protocol lost the no-invented-wake rule" 'attach-status' "\`OPEN DECISIONS\`"
  assert_line_has "$out" "claude protocol lost the auto-arm failure pointer" \
    "\`firstmate watcher auto-arm FAILED ...\`" "\`INTERRUPTED ...\`"
  assert_line_has "$out" "claude protocol lost the no-manual-arm-loop rule" 'auto-arm FAILED' 'manual-arm'
  pass "claude protocol keeps its arm-ownership, wake, and failure-notice lines"
}

test_pi_protocol_keeps_its_mistake_lines() {
  local out
  out=$("$RENDER" --harness pi)
  assert_line_has "$out" "pi protocol lost the one initial arm call" 'Initial' "\`fm_watch_arm_pi\`"
  assert_line_has "$out" "pi protocol lost the human-only slash fallback" "\`/fm-watch-arm-pi\`" 'human'
  assert_line_has "$out" "pi protocol lost the no-foreground-arm rule" 'never' "\`bin/fm-watch-arm.sh\`" 'bash tool'
  assert_contains "$out" "Regression example - keep verbatim and never condense away: \`[seq 41] claude-mod: implementation complete, ready for review\` requires relaying a captain-facing outcome response, not just \`Captain, shipshape.\`." \
    "pi protocol lost its verbatim regression example"
  assert_line_has "$out" "pi protocol lost the single processed acknowledgement" \
    "\`fm_branch_processed\`" 'highest' 'once'
  assert_contains "$out" "still-open" "pi protocol lost the still-open-only rule"
  assert_line_has "$out" "pi protocol lost the merge-ask URL rule" 'merge' 'URL' "\`AGENTS.md\` section 9"
  assert_line_has "$out" "pi protocol lost the lease claim" "\`bin/fm-lease.sh claim <task>\`" 'release'
  pass "pi protocol keeps its one-arm, processing-request, and lease lines"
}

test_supervision_host_protocol_on_an_opted_in_claude_home
test_supervision_host_protocol_on_every_arm_owner
test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_quiet_mode_stanzas
test_repair_lines
test_cross_harness_ordinary_continuation_and_repair_matrix
test_pi_signed_preserves_identity_with_pi_supervision_protocol
test_grok_is_background_notify
test_grok_command_sources_effective_config
test_pi_repair_line_uses_effective_extension_path
test_claude_protocol_keeps_its_mistake_lines
test_pi_protocol_keeps_its_mistake_lines
