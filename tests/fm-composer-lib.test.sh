#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), `⟩` (muse), and `→`
#      (cursor) are a genuine empty agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
#
# Ghost-text robustness (incident composer-robust; task afk-herdr-false-pending),
# the tmux-adapter section at the end of this file:
# A harness fills an otherwise-empty composer with de-emphasised ghost text that a
# plain pane capture cannot tell apart from human input, so the composer reader
# saw an idle pane as holding pending input. Two rendering styles are covered by
# the one shared ANSI-aware owner (fm_composer_strip_ghost, bin/fm-composer-lib.sh,
# reached there through the fm_tmux_strip_ghost thin adapter):
#   - DIM/FAINT (SGR 2): claude's rotating prompt suggestion, codex's idle tip.
#   - a dark/muted TRUECOLOR foreground: grok's placeholder/hint text.
# Those tests pin:
#   1. fm_tmux_strip_ghost drops dim/faint AND dark-truecolor runs, keeping
#      normal-intensity, brightly-coloured text.
#   2. fm_pane_input_pending reads a ghost-only composer (either style) as NOT
#      pending, while still treating real (normal/bright) text as pending.
#   3. The tmux reader structurally scans every row of a multi-row composer.
#   4. The human/LLM-facing capture path (fm-peek.sh) stays PLAIN - no escape codes
#      ever reach firstmate's context.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'Type a message...' "$idle" sensitive 'Type a message...' 1 1)
  [ "$out" = pending ] || fail "placeholder-like text surviving a styled box capture should read pending, got '$out'"
  out=$(classify 1 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 1 0)
  [ "$out" = empty ] || fail "a glyph-bearing plain box placeholder should read empty, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 1)
  [ "$out" = pending ] || fail "placeholder text on a styled bare input row must be pending, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 0)
  [ "$out" = unknown ] || fail "placeholder text on a plain bare input row must be unknown, got '$out'"
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: idle matching is limited to proven placeholder positions"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle" sensitive 'type a message...' 1 0)
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive 'type a message...' 1 0)
  [ "$out" = empty ] || fail "an explicitly insensitive plain placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# =============================================================================
# fm_composer_classify_screen: the adapter-facing screen classifier and the
# correctness matrix (audit data/fm-composer-consolidation-audit-s1, task
# fm-composer-thin-adapter-refactor-r1).
#
# Fixtures are the audit's byte-level captures of six REAL idle harnesses:
# claude 2.1.226 (bare `❯` + U+00A0 NO-BREAK SPACE), codex 0.146.0 (bold `›`
# + SGR-2 dim hint), codex 0.154.0 (the same `›` amid a braille starfield over
# a status footer, captured through Herdr on 2026-09-15), muse (truecolor `⟩`, 38;2;90;160;255), pi (blank row
# between solid `─` rules), opencode 1.14.46 (left-bar `┃` rows), and grok
# 1.0.0 (bordered box with a TITLED bottom border), plus claude captured
# inside zellij through `dump-screen --ansi` (`ESC[m` `❯` U+00A0).
#
# Capability profiles mirror the real adapters' descriptors: tmux
# (styled+cursor+identity), herdr/zellij (styled), cmux/orca (plain). Every
# emptiness verdict is asserted under the ambient UTF-8 locale AND LC_ALL=C,
# pinning the locale-safe Unicode-space normalization (issue #1988).
# =============================================================================

ESC=$(printf '\033')
NBSP=$(printf '\302\240')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20' # zellij
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_matrix_claude_bare_nbsp_row() {
  # Real idle claude: `❯` + U+00A0, borderless, between horizontal rules.
  # The audit's headline defect: this row read `pending` under LC_ALL=C
  # (issue #1988), deferring every away-mode escalation in daemon contexts.
  local screen typed
  screen=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  bypass permissions'
  assert_screen "claude idle on tmux" empty "$CAPS_TMUX" "$screen" 2 probe-absent
  assert_screen "claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "claude idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  typed=$'────────────────────────\n❯ fix the login bug\n────────────────────────'
  assert_screen "claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  # Plain capture cannot tell typed text from claude's rotating suggestion:
  # the styled=0 degradation defers instead of fabricating pending.
  assert_screen "claude typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  pass "matrix: claude's ❯+NBSP row reads empty on every profile in both locales (#1988)"
}

test_matrix_claude_arrow_statusline_footer() {
  # Real claude 2.x on herdr (captured live 2026-09-20, herdr 0.8.0): the
  # composer is a bare `❯`+U+00A0 row between two solid rules, and the harness
  # draws a user statusLine plus its permission-mode hint directly BELOW the
  # closing rule. That statusLine opened with `→`, which is Cursor's own agent
  # prompt glyph, so the bottom-most-candidate rule selected the statusLine as
  # a bare composer, swallowed the hint row beneath it as wrapped input, and
  # every steer to a claude worker was refused with a `pending` verdict on a
  # visibly empty composer. A pair that closed over a bare agent-glyph row is
  # a proven composer container, so its contiguous non-blank footer rows are
  # furniture and cannot outrank the composer they sit under.
  local pair footer screen typed residue claude_idle
  claude_idle=$(printf 'claude\tidle')
  pair=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────'
  footer=$'\n  → repo git:(fm/branch)× | Opus 5 | ctx 15%\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  screen="$pair$footer"
  assert_screen "claude idle under an arrow statusline on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "claude idle under an arrow statusline on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle under an arrow statusline on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # The protection this must NOT remove: real unsubmitted text in that same
  # composer, under that same statusline, still refuses.
  typed=$'transcript line\n────────────────────────\n❯ fix the login bug\n────────────────────────'"$footer"
  assert_screen "claude typed under an arrow statusline" pending "$CAPS_STYLED" "$typed" '' "$claude_idle"
  # The live second defect: a stray SGR mouse report left in the composer by
  # a click in the pane is real pending content, not furniture.
  residue=$'transcript line\n────────────────────────\n❯ <65;77;27M\n────────────────────────'"$footer"
  assert_screen "stray mouse report in the composer" pending "$CAPS_STYLED" "$residue" '' "$claude_idle"
  pass "matrix: claude's arrow statusline is footer furniture, not a composer holding text"
}

test_composer_footer_demotion_needs_a_proven_pair() {
  # The demotion is bounded in three directions, and each bound is a case
  # where a lower glyph row IS the live composer.
  local screen out claude_idle pi_idle
  claude_idle=$(printf 'claude\tidle'); pi_idle=$(printf 'pi\tidle')
  # 1. Contiguity: a blank row ends the footer zone, so a composer redrawn
  #    below an old rule pair still wins.
  screen=$'────────────────────────\n❯ old draft\n────────────────────────\n  → repo git:(main)\n\n→'
  assert_screen "blank row reopens lower candidates" empty "$CAPS_STYLED_NOID" "$screen"
  # 2. Proof: a pair that closed over NO agent-glyph row proves no composer,
  #    so nothing below it is demoted. pi's own blank pair is exactly that.
  screen=$'────────────────────────\n\n────────────────────────\n→'
  assert_screen "an unproven pair demotes nothing" empty "$CAPS_STYLED_NOID" "$screen"
  # 3. No pair at all: Cursor draws its `→` composer between half-block rules,
  #    which are not separator rules, so its footer rows change nothing.
  screen=$' ▄▄▄▄▄▄▄▄\n  →\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  assert_screen "cursor keeps its own bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  # A later pair WITHOUT a glyph row must reopen candidates the earlier proven
  # pair had closed, so the zone cannot leak down a screen.
  screen=$'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  → repo git:(main)\n────────────────────────\n────────────────────────\n→'
  assert_screen "a later unproven pair reopens candidates" empty "$CAPS_STYLED_NOID" "$screen"
  # And the strict posture is untouched: a footer row alone proves nothing.
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" $'transcript\n  → repo git:(main) | Opus 5')
  [ "$out" != empty ] \
    || fail "an unanchored statusline row must never prove an empty composer, got '$out'"
  pass "fm_composer_classify_screen: footer demotion needs a contiguous, glyph-proven pair"
}

test_composer_footer_zone_is_shape_independent() {
  # The same captain-facing failure on the BORDERED composer: claude 2.x
  # renders its composer inside a rounded box on a wide pane, and this home's
  # statusLine (opening with `→`, Cursor's prompt glyph) plus the permission
  # hint still land on the two contiguous rows below the closing border. The
  # footer-zone invariant is a property of an envelope proven by a glyph row
  # inside it, not of the pi separator pair, so it must hold here too.
  local box footer screen out claude_idle
  claude_idle=$(printf 'claude\tidle')
  box=$'transcript line\n╭───────────────────────────╮\n│ ❯'"$NBSP"$'                        │\n╰───────────────────────────╯'
  footer=$'\n → repo git:(fm/branch)× | Opus 5 | ctx 15%\n ⏵⏵ bypass permissions on'
  screen="$box$footer"
  assert_screen "boxed claude idle under an arrow statusline on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "boxed claude idle under an arrow statusline on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "boxed claude idle under an arrow statusline on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen")
  case "$out" in
    *'repo git:'*|*'bypass permissions'*)
      fail "the statusline footer must never be extracted as composer content, got '$out'" ;;
  esac
  # The protection this must NOT remove: real unsubmitted text inside that same
  # bordered composer, under that same footer, still refuses.
  screen=$'transcript line\n╭───────────────────────────╮\n│ ❯ half-typed draft        │\n╰───────────────────────────╯'"$footer"
  assert_screen "boxed claude typed under an arrow statusline" pending "$CAPS_STYLED" "$screen" '' "$claude_idle"
  # The deliberate counterexample, pinned as such: codex's startup banner has
  # no glyph row inside it, so it proves no composer, opens no footer zone, and
  # the live bare row contiguously below it keeps winning.
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "unproven banner still yields to the bare row below it" empty "$CAPS_PLAIN" "$screen"
  pass "fm_composer_classify_screen: the footer zone holds for boxes, not only separator pairs"
}

test_composer_footer_zone_refuses_rather_than_allows() {
  # The footer-zone demotion is ASYMMETRIC: `empty` is the only verdict that
  # authorizes fm-send to type into the pane, so the rule may move a verdict
  # toward refusing but never toward `empty`. Every screen below classified
  # `pending` before the footer zone existed and must never read `empty`.
  local screen out
  # 1. Draft loss. A row leading with the SAME glyph the envelope was proven by
  #    is a live composer, not furniture, and must keep winning - otherwise the
  #    doorbell types over a draft the worker can see.
  screen=$'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n❯ my typed draft'
  assert_screen "separated: a live draft below the pair keeps winning" pending "$CAPS_STYLED_NOID" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'my typed draft' ] \
    || fail "the live draft must be the extracted composer content, got '$out'"
  screen=$'╭────────────────────────╮\n│ ❯'"$NBSP"$'                     │\n╰────────────────────────╯\n❯ my typed draft'
  assert_screen "boxed: a live draft below the box keeps winning" pending "$CAPS_STYLED_NOID" "$screen"
  # 2. Working agent. Unclaimed activity below a proven envelope is not
  #    furniture in EITHER row order, even when one of the rows leads with a
  #    foreign agent glyph, so the envelope above it stays stale.
  for screen in \
    $'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...\n→ ran npm test (3 failures)' \
    $'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\n→ ran npm test (3 failures)\nWorking on request...' \
    $'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\nWorking on request...\n→ ran npm test (3 failures)' \
    $'────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n→ ran npm test (3 failures)\nWorking on request...'
  do
    out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$screen")
    [ "$out" != empty ] \
      || fail "a working agent below a proven envelope must never read empty, got '$out'"
    out=$(LC_ALL=C fm_composer_classify_screen "$CAPS_STYLED_NOID" "$screen")
    [ "$out" != empty ] \
      || fail "a working agent below a proven envelope must never read empty under LC_ALL=C, got '$out'"
  done
  # 3. The other direction, which the demotion must not invert either: a pair
  #    holding a QUOTED prompt in the transcript above a live, visibly empty
  #    composer row reads empty, and the quoted text is never composer content.
  screen=$'────────────────────────\ntranscript one\ntranscript two\n❯ some quoted prompt in the transcript\n────────────────────────\n❯'"$NBSP"
  assert_screen "a quoted prompt above a live empty row stays empty" empty "$CAPS_STYLED_NOID" "$screen"
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  case "$out" in
    *'some quoted prompt'*) fail "a quoted transcript prompt must never be composer content, got '$out'" ;;
  esac
  pass "fm_composer_classify_screen: the footer zone only ever refuses, never allows"
}

test_matrix_codex_dim_hint_row() {
  # Real idle codex: bold `›`, reset, then an SGR-2 dim hint. Styled captures
  # strip the ghost and prove empty; plain captures must defer as unknown -
  # NEVER the old false `pending` that read the hint as unsent text.
  local styled plain
  styled=$'banner\n'"${ESC}[1m›${ESC}[0m ${ESC}[2mUse /skills to list available skills${ESC}[0m"
  plain=$'banner\n› Use /skills to list available skills'
  assert_screen "codex idle on tmux" empty "$CAPS_TMUX" "$styled" 1
  assert_screen "codex idle on herdr" empty "$CAPS_STYLED" "$styled"
  assert_screen "codex idle on zellij" empty "$CAPS_STYLED_NOID" "$styled"
  assert_screen "codex idle on plain backends" unknown "$CAPS_PLAIN" "$plain"
  pass "matrix: codex's dim hint is empty when styling proves it, unknown (never pending) when it cannot"
}

test_matrix_muse_truecolor_glyph_survives_signal_loss() {
  # Real idle muse: truecolor `⟩` (38;2;90;160;255, luminance ~149.9) under a
  # TITLED rule. Two independent signals prove emptiness: the glyph surviving
  # the ghost strip, and the UNSTRIPPED plain row carrying an agent glyph.
  # Drive them apart: with the luma threshold raised past the glyph's
  # luminance, the ghost strip erases it, and the verdict must survive on the
  # plain-row signal alone.
  local screen plain out
  screen=$'── Voice input (⌥ + v to start) ─────\n'"${ESC}[0m${ESC}[38;2;90;160;255m⟩${ESC}[0m"
  plain=$'── Voice input (⌥ + v to start) ─────\n⟩'
  assert_screen "muse idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "muse idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "muse idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "muse idle on cmux/orca" empty "$CAPS_PLAIN" "$plain"
  out=$(FM_COMPOSER_GHOST_LUMA_MAX=200 fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] || fail "muse must stay empty when the ghost strip eats its glyph (plain-row signal), got '$out'"
  pass "matrix: muse's ⟩ reads empty everywhere and survives losing the styled-glyph signal"
}

test_matrix_cursor_reverse_video_placeholder_remnant() {
  # Real idle cursor-agent (2026.08.11-e8db854), captured byte-for-byte from a
  # live pane: the `→ ` glyph and the placeholder tail are dim (SGR 2), but the
  # cell under the terminal cursor is REVERSE VIDEO (SGR 0;7). Reverse video is
  # neither dim nor a dark foreground, so the ghost stripper keeps that one
  # character and an idle composer reduces to a lone `P`.
  local row screen plain out stripped
  row="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0;7m${ESC}[48;2;21;21;21mP"
  row="${row}${ESC}[0;2m${ESC}[48;2;21;21;21mlan, search, build anything${ESC}[0m"
  screen=$'transcript\n\n'"$row"
  plain=$'transcript\n\n  → Plan, search, build anything'

  # NON-VACUOUSNESS: prove the remnant really survives stripping. If the ghost
  # stripper ever learned SGR 7, `stripped` would be empty and the verdict below
  # would come from the empty-content path instead, silently retiring the
  # plain-row branch this case exists to cover.
  stripped=$(printf '%s' "$row" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = P ] \
    || fail "cursor's reverse-video remnant must survive ghost stripping as 'P', got '$stripped'"

  assert_screen "cursor idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "cursor idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  # An UNSTYLED capture carries no ghost-strip proof, so a bare row matching a
  # placeholder is indistinguishable from typed text and must stay unknown -
  # the same degradation every other bare-row placeholder already takes.
  assert_screen "cursor idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"

  # The dangerous direction: text a user actually TYPED is uniformly bright, so
  # stripping leaves it EQUAL to the plain row. Even when that text is exactly
  # the placeholder, it must stay pending - never a false empty.
  local typed typed_plain
  typed="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0m${ESC}[38;2;224;222;244mAdd a follow-up${ESC}[0m"
  typed_plain=$'transcript\n\n  → Add a follow-up'
  assert_screen "cursor typed placeholder text stays pending" pending \
    "$CAPS_STYLED" $'transcript\n\n'"$typed"
  # Without styling there is no proof either way, so it must not read empty.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$typed_plain")
  [ "$out" != empty ] \
    || fail "an unstyled cursor row matching the placeholder must not read empty, got '$out'"
  pass "matrix: cursor's reverse-video placeholder remnant reads empty; real typed text stays pending"
}

test_matrix_herdr_halfblock_rule_bounds_bare_wrap() {
  # Herdr draws a composer's rules with half-block glyphs (▄ above, ▀ below)
  # rather than the box-drawing family. Without treating those as edges, a bare
  # composer's WRAP region walks through its own closing rule and swallows the
  # footer, whose real content turns an idle pane into a false `pending`.
  # Captured live from a herdr cursor pane.
  local screen plain out
  plain=$'transcript\n ▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  # The closing rule must bound the region, so the footer below is not input.
  fm_composer_row_has_edge ' ▀▀▀' \
    || fail "a half-block rule row must count as a structural edge"
  fm_composer_row_has_edge ' ▄▄▄' \
    || fail "the upper half-block rule must count as a structural edge"
  # Non-vacuousness: the footer rows really are non-blank content that would be
  # swallowed if the rule did not bound the region.
  case "$plain" in *"Run Everything"*) : ;; *) fail "fixture lost its footer content" ;; esac
  ESC_LOCAL=$(printf '\033')
  screen=$'transcript\n ▄▄▄▄▄▄▄▄\n'"  ${ESC_LOCAL}[2m→ ${ESC_LOCAL}[0;7mA${ESC_LOCAL}[0;2mdd a follow-up${ESC_LOCAL}[0m"$'\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] \
    || fail "an idle cursor composer inside herdr half-block rules must read empty, got '$out'"
  pass "matrix: herdr half-block rules bound a bare composer's wrap region"
}

test_matrix_omp_status_row_bounds_bare_composer() {
  # omp (Oh My Pi) draws its status line directly BELOW the borderless `❯`
  # composer. Captured live through Herdr on omp 18.1.11 under the captain's
  # unicode preset (idle), plus the nerd-preset idle row and the busy spinner
  # row from the 18.1.2 investigation. Without the status-row rule the bare
  # wrap region swallows that row and an idle omp pane reads `pending`, which
  # skipped the doorbell on the first live omp worker.
  local idle_unicode idle_nerd busy typed wrapped
  idle_unicode=$'transcript line

❯
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  idle_nerd=$'transcript line

❯
 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K'
  busy=$'transcript line

  ⎋ Working…

❯
 ⠧ 11s  · ◔ GPT-6-Astra · ◫ 15.4%/272K'
  typed=$'transcript line

❯ fix the flaky test
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  # Non-vacuousness: each status row is real non-blank content that the wrap
  # region would otherwise take as typed input.
  _fm_composer_row_is_omp_status ' π  · ◔ GPT-6-Astra · 🌳 …-workspace' \
    || fail "the unicode-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K' \
    || fail "the nerd-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' ⠧ 11s  · ◔ GPT-6-Astra' \
    || fail "the busy omp spinner row must be recognized as furniture"
  _fm_composer_row_is_omp_status 'fix the flaky test' \
    && fail "ordinary typed text must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status 'please rerun the suite and report' \
    && fail "ordinary prose must not be mistaken for omp status furniture"
  # Only omp's identity cell opens the row: a wrapped typed row that happens
  # to begin with a short word and a spaced middle dot is composer input.
  _fm_composer_row_is_omp_status 'fix · tests before pushing' \
    && fail "wrapped typed text with a middle dot must not be mistaken for omp status furniture"
  # The ascii preset's identity cell is `pi`, but that preset separates its
  # cells with ` - `, so a row opening `pi ·` is never omp furniture.
  _fm_composer_row_is_omp_status 'pi · e · phi as the three constants' \
    && fail "typed text opening 'pi ·' must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status ' ⣾ 3s  · ◔ GPT-6-Astra' \
    || fail "the status-set omp spinner row must be recognized as furniture"
  assert_screen "idle omp (unicode preset)" empty "$CAPS_STYLED" "$idle_unicode"
  assert_screen "idle omp (nerd preset)" empty "$CAPS_STYLED" "$idle_nerd"
  assert_screen "busy omp keeps an empty composer" empty "$CAPS_STYLED" "$busy"
  assert_screen "typed omp text is pending" pending "$CAPS_STYLED" "$typed"
  assert_screen "idle omp on a plain capture" empty "$CAPS_PLAIN" "$idle_unicode"
  # The boundary must not cut a bare composer's own wrapped input: with the
  # cursor on a continuation row that opens `fix · tests`, the composer is a
  # proven wrap region and reads pending, exactly as it did before the rule.
  wrapped=$'transcript line\n\n❯ please run the suite and then\nfix · tests before pushing'
  assert_screen "wrapped typed text with a middle dot stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  wrapped=$'transcript line\n\n❯ document the constants in the order\npi · e · phi with one example each'
  assert_screen "wrapped typed text opening 'pi ·' stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  pass "matrix: omp's status row bounds the bare composer's wrap region"
}

# codex_cell <grey> <glyph>: one codex 0.154 starfield cell exactly as the
# harness draws it - a truecolor grey foreground, the composer's grey
# background, the braille glyph, then a reset.
codex_cell() {
  printf '%s[38;2;%s;%s;%sm%s[48;2;57;57;57m%s%s[0m' "$ESC" "$1" "$1" "$1" "$ESC" "$2" "$ESC"
}

test_matrix_codex_idle_starfield_furniture() {
  # Real idle codex-cli 0.154.0 (gpt-6-astra, fast mode) captured byte-for-byte
  # through Herdr (`pane read --format ansi`) from the first codex second mate:
  # an animated braille "starfield" on the row above the bold `›`, on the `›`
  # row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on
  # the row below, then a bright model/path/title status footer. The cells are
  # truecolor greys on BOTH sides of the 128 ghost-luma ceiling, so the
  # brighter ones survive the ghost strip, and the rows below the glyph carry
  # no structural edge. The bare shape therefore extended its wrap region over
  # the two rows beneath the glyph and read the survivors as wrapped typed
  # input: `pending`, which deferred every steering doorbell for that pane.
  local bg="${ESC}[48;2;57;57;57m" above glyph glyph2 below footer
  local screen screen2 plain plain2 ascii_screen stripped out
  above="${ESC}[0m${bg}                         ${ESC}[0m$(codex_cell 82 ⢀)${bg}      ${ESC}[0m$(codex_cell 136 ⠂)${bg} ${ESC}[0m$(codex_cell 163 ⠄)${bg}     ${ESC}[0m$(codex_cell 118 ⠈)"
  glyph="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m${bg} ${ESC}[0m${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 117 ⡀)${bg}  ${ESC}[0m$(codex_cell 88 ⠈)${bg}       ${ESC}[0m$(codex_cell 156 ⠂)${bg}        ${ESC}[0m$(codex_cell 71 ⠁)$(codex_cell 161 ⠐)${bg} ${ESC}[0m$(codex_cell 165 ⠁)"
  # A second live sample of the same pane, minutes later: the animation had
  # placed a bright cell BETWEEN the glyph and the placeholder.
  glyph2="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m$(codex_cell 138 ⠁)${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 163 ⡀)${bg}  ${ESC}[0m$(codex_cell 132 ⠈)"
  below="${ESC}[0m${bg}        ${ESC}[0m$(codex_cell 101 ⠐)${bg}    ${ESC}[0m$(codex_cell 111 ⠄)${bg}   ${ESC}[0m$(codex_cell 165 ⠠)${bg}  ${ESC}[0m$(codex_cell 121 ⢀)$(codex_cell 122 ⠠)$(codex_cell 81 ⡀)$(codex_cell 150 ⠄⠂)"
  footer="  ${ESC}[0m${ESC}[38;2;246;226;183mgpt-6-astra high fast${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;171;223;167m~/Projects/purser${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;156;222;211mLaunch Purser desk brief${ESC}[0m"
  screen=$'transcript line\n\n'"$above"$'\n'"$glyph"$'\n'"$below"$'\n'"$footer"
  screen2=$'transcript line\n\n'"$above"$'\n'"$glyph2"$'\n'"$below"$'\n'"$footer"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  plain2=$(printf '%s\n' "$screen2" | fm_composer_strip_ansi)

  # NON-VACUOUSNESS: the ghost strip really leaves braille survivors behind the
  # placeholder and on the row below (cells above the luma ceiling), and the
  # footer really is non-blank, edge-free content the wrap region would take.
  stripped=$(printf '%s\n' "$glyph" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" != '›' ] \
    || fail "the glyph row's starfield cells must survive ghost stripping, or the furniture case is vacuous"
  stripped=$(printf '%s\n' "$stripped" | fm_composer_strip_braille)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = '›' ] \
    || fail "everything surviving ghost stripping behind the glyph must be braille, got '$stripped'"
  stripped=$(printf '%s\n' "$below" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ -n "$stripped" ] \
    || fail "the row below the glyph must keep starfield cells after ghost stripping"
  _fm_composer_row_is_braille_furniture "$stripped" \
    || fail "the row below the glyph must be recognized as braille furniture"
  fm_composer_row_has_edge '  gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief' \
    && fail "fixture drift: the footer must carry no structural edge, or the boundary rule is untested"

  # The verdicts: empty wherever styling can prove the placeholder ghost, on
  # both live samples, in both locales; unknown (never pending) on a plain
  # capture, exactly as the codex dim-hint row above.
  assert_screen "codex 0.154 idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "codex 0.154 idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "codex 0.154 idle on tmux (cursor on the glyph row)" empty "$CAPS_TMUX" "$screen" 3
  assert_screen "codex 0.154 idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"
  assert_screen "codex 0.154 idle (second sample) on herdr" empty "$CAPS_STYLED" "$screen2"
  assert_screen "codex 0.154 idle (second sample) on tmux" empty "$CAPS_TMUX" "$screen2" 3
  assert_screen "codex 0.154 idle (second sample) on cmux/orca" unknown "$CAPS_PLAIN" "$plain2"
  # A cursor parked on the starfield row below the glyph is not inside a wrap
  # region, so the strict blank-row posture keeps it unknown.
  assert_screen "codex 0.154 cursor on the starfield row" unknown "$CAPS_TMUX" "$screen" 4

  # DIVERGENCE: the same screen with every starfield cell replaced by a letter
  # is wrapped typed input and must stay pending, so the furniture verdict
  # above cannot come from anything but the braille rule.
  ascii_screen=$(printf '%s\n' "$screen" | LC_ALL=C sed 's/⢀/x/g; s/⠂/x/g; s/⠄/x/g; s/⠈/x/g; s/⡀/x/g; s/⠁/x/g; s/⠐/x/g; s/⠠/x/g')
  case "$ascii_screen" in *'⠂'*|*'⠁'*) fail "fixture drift: the divergence screen still carries braille" ;; esac
  assert_screen "starfield replaced by letters on herdr" pending "$CAPS_STYLED" "$ascii_screen"
  assert_screen "starfield replaced by letters on tmux" pending "$CAPS_TMUX" "$ascii_screen" 3

  # NEGATIVES that keep the rule from over-stripping:
  # (i) a real message wrapped below the `›` row, footer beneath, stays pending.
  out=$'transcript line\n\n› please run the suite and then\ncontinue with the docs\n'"$footer"
  assert_screen "wrapped typed input above the codex footer on herdr" pending "$CAPS_STYLED" "$out"
  assert_screen "wrapped typed input above the codex footer on tmux" pending "$CAPS_TMUX" "$out" 3
  # (ii) braille mixed with typed text is typed text, on the glyph row and on
  # a wrapped row alike.
  assert_screen "braille mixed into the glyph row" pending "$CAPS_STYLED" $'transcript line\n\n› fix ⠂ the tests'
  assert_screen "braille mixed into a wrapped row" pending "$CAPS_STYLED" $'transcript line\n\n› please\nfix ⠂ the tests'
  # (iii) a typed row carrying a spaced middle dot is composer input.
  assert_screen "wrapped typed row with a middle dot on herdr" pending "$CAPS_STYLED" $'transcript line\n\n› deploy\nfix · tests before pushing'
  assert_screen "wrapped typed row with a middle dot on tmux" pending "$CAPS_TMUX" $'transcript line\n\n› deploy\nfix · tests before pushing' 3
  # (iv) the footer or a starfield row alone, with no bare glyph above, gains
  # no new verdict: still no container proof.
  assert_screen "codex footer alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$footer"
  assert_screen "codex footer alone on tmux" unknown "$CAPS_TMUX" $'transcript line\n\n'"$footer" 2
  assert_screen "starfield row alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$below"
  pass "matrix: codex 0.154's starfield rows are furniture; typed, mixed, and unanchored rows keep their verdicts"
}

test_matrix_pi_separated_needs_identity() {
  # Real idle pi: a blank row between two solid rules. The blank row alone is
  # exactly what the strict rule refuses; only structure PLUS a live
  # idle/done pi identity proves the composer (herdr's rule, now
  # fleet-wide; tmux supplies identity from its foreground-process probe).
  local screen typed pi_idle pi_working pi_blocked none
  screen=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  pi_blocked=$(printf 'pi\tblocked')
  assert_screen "pi idle with identity" empty "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "pi idle on tmux with identity" empty "$CAPS_TMUX" "$screen" 2 "$pi_idle"
  assert_screen "pi idle on zellij" unknown "$CAPS_STYLED_NOID" "$screen"
  # Identity-capable but unfetched: the adapter is asked to probe lazily.
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" = need-identity ] \
    || fail "an identity-capable profile should request the lazy identity probe"
  # No identity capability (cmux/orca/zellij): the shape is unprovable.
  assert_screen "pi pair without identity capability" unknown "$CAPS_PLAIN" "$screen"
  # A working pi cannot authorize injection into the blank region.
  assert_screen "working pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_working"
  # A pi parked on an interactive prompt reports `blocked`: it is waiting on a
  # human keystroke, so the blank region is a menu's, not a free composer's.
  # Typing there answers the prompt and the text is discarded (issue #2797).
  assert_screen "blocked pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_blocked"
  # The audit's live counterexample: a plain shell running sleep, cursor
  # parked on a blank line between two rules, NO pi process. The permissive
  # rule read this `empty`; identity+structure refuses it.
  assert_screen "sleep-pane counterexample" unknown "$CAPS_TMUX" "$screen" 2 "$none"
  assert_screen "absent identity cannot prove blank pi pair" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  typed=$'────────────────────────\nfix the flaky test\n────────────────────────'
  assert_screen "pi typed" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  typed=$'────────────────────────\n❯\n────────────────────────'
  assert_screen "pi lone-glyph draft with identity" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  assert_screen "pi lone-glyph draft on tmux" pending "$CAPS_TMUX" "$typed" 1 "$pi_idle"
  assert_screen "lone glyph without identity capability" empty "$CAPS_STYLED_NOID" "$typed"
  assert_screen "lone glyph on plain backend" empty "$CAPS_PLAIN" "$typed"
  assert_screen "lone glyph with non-pi identity" empty "$CAPS_STYLED" "$typed" '' "$none"
  pass "matrix: pi's separated composer needs identity + structure; the blank row alone never proves it"
}

test_matrix_pi_dollar_status_footer_is_empty() {
  # Pi's status row `$0.000 (sub) 5.4%/272k (auto)` at column 0 used to read
  # as a dead-shell prompt, so an idle separated composer classified unknown.
  # A counters-first footer never took that path. A real `$` or `$ ls` prompt,
  # and the same cost string typed between the separators, still refuse.
  local dollar typed dead_shell dead_cmd spaced footer_only inside wrap dollar_status
  local pi_idle pi_working none out
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  dollar_status=$'$0.000 (sub) 5.4%/272k (auto)'
  dollar=$'transcript\n────────────────────────\n\n────────────────────────\n'"$dollar_status"

  assert_screen "pi dollar-first status on herdr" empty "$CAPS_STYLED" "$dollar" '' "$pi_idle"
  assert_screen "pi dollar-first status on tmux" empty "$CAPS_TMUX" "$dollar" 2 "$pi_idle"

  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$dollar")" = need-identity ] \
    || fail "a dollar-first Pi footer must still request the lazy identity probe"
  assert_screen "dollar-first status without identity capability" unknown "$CAPS_PLAIN" "$dollar"
  assert_screen "working pi with dollar-first status defers" unknown \
    "$CAPS_STYLED" "$dollar" '' "$pi_working"
  assert_screen "non-pi identity with dollar-first status defers" unknown \
    "$CAPS_STYLED" "$dollar" '' "$none"

  typed=$'────────────────────────\nfix the flaky test\n────────────────────────\n'"$dollar_status"
  assert_screen "pi typed text above dollar-first status" pending \
    "$CAPS_STYLED" "$typed" '' "$pi_idle"
  inside=$'────────────────────────\n'"$dollar_status"$'\n────────────────────────'
  assert_screen "dollar-first string typed into the pi composer" pending \
    "$CAPS_STYLED" "$inside" '' "$pi_idle"

  dead_shell=$'transcript\n────────────────────────\n\n────────────────────────\n$'
  dead_cmd=$'transcript\n────────────────────────\n\n────────────────────────\n$ ls -la'
  spaced=$'transcript\n────────────────────────\n\n────────────────────────\n$ 0.000 (sub)'
  assert_screen "real dead shell below a pi pair" unknown "$CAPS_STYLED" "$dead_shell" '' "$pi_idle"
  assert_screen "dead-shell command below a pi pair" unknown "$CAPS_STYLED" "$dead_cmd" '' "$pi_idle"
  assert_screen "spaced dollar below a pi pair" unknown "$CAPS_STYLED" "$spaced" '' "$pi_idle"

  footer_only=$'transcript\n'"$dollar_status"
  assert_screen "dollar-first status with no pi pair" unknown \
    "$CAPS_STYLED" "$footer_only" '' "$pi_idle"

  wrap=$'❯\n$ ls -la'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$wrap")
  [ "$out" = unknown ] \
    || fail "a real dead shell below a bare glyph must still invalidate cursorless selection, got '$out'"
  wrap=$'❯\n$ '
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$wrap")
  [ "$out" = unknown ] \
    || fail "a bare dollar prompt below a glyph must still invalidate cursorless selection, got '$out'"
  pass "matrix: a dollar-first pi status footer reads empty; dead shells still refuse"
}

test_matrix_opencode_leftbar_signals() {
  # Real idle opencode: `┃`-prefixed rows holding an "Ask anything" hint,
  # blanks, and a Build-mode footer. Two independent idle signals: the shared
  # idle-placeholder pattern (works on plain captures) and the ghost strip
  # (works on styled captures even if the pattern is overridden away).
  local screen typed dim_screen captured_idle captured_pending out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux (cursor on hint)" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # This sanitized live OpenCode 1.18.30 capture preserves its U+2026 hint and
  # RGB 128 styling. RGB 128 is deliberately outside the ghost threshold, so
  # the placeholder spelling is the independent empty signal. The completed-
  # turn row above the active composer also pins the incident's idle layout.
  captured_idle=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;128;128;128mAsk anything… \"Fix a TODO in the codebase\"${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn idle hint on tmux" empty "$CAPS_TMUX" "$captured_idle" 3
  captured_pending=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;255;255;255mReply with OK.${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn typed composer on tmux" pending "$CAPS_TMUX" "$captured_pending" 3
  # Signal separation: with the idle pattern overridden to something that
  # cannot match, a DIM-styled hint still proves empty through the ghost strip.
  out=$(FM_COMPOSER_IDLE_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_TMUX" "$dim_screen" 1)
  [ "$out" = empty ] || fail "a dim opencode hint must stay empty via the ghost strip alone, got '$out'"
  typed=$'┃\n┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "opencode typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  Ask anything... please investigate\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode placeholder-like input on tmux" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "opencode placeholder-like input on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high'
  assert_screen "opencode multiline draft above blank cursor row" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: opencode's left-bar composer reads empty everywhere and scans the full active run"
}

test_matrix_grok_titled_bottom_border() {
  # Grok 1.0.5 widened its titled BOTTOM border three columns past the top and
  # content rows. This is the idle capture from issue #3436; Herdr has no
  # cursor anchor, so the geometry mismatch used to make the proven box
  # ambiguous and the verdict unknown, stranding away-mode injection.
  local titled plain_border typed malformed placeholder_draft
  titled=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯\n\n  Shift+Tab:mode  │  Ctrl+x:shortcuts'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "issue #3436 idle grok 1.0.5 on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ Type a message...                                                      │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  # The tolerance is additive: an untitled border still proves the same box.
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ deploy the fix                                                         │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "grok typed on herdr" pending "$CAPS_STYLED" "$typed"
  malformed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── unknown surface ─╯'
  assert_screen "oversized unknown title on herdr" unknown "$CAPS_STYLED" "$malformed"
  pass "matrix: grok's real oversized titled bottom is empty while typed and unproved panes stay safe"
}

test_matrix_claude_titled_top_rule() {
  # A named Claude Code session draws its title into the composer's TOP rule
  # (issues #5601 and #5558; observed on herdr as
  # `─── Firstmate operational input 1790546042 ─`). The strict separator
  # predicate rejects that row, so the pair never opened, the closing rule
  # read as a lower unmatched separator, and a visibly empty composer read
  # `unknown` on every cursorless backend, refusing steers, exit, and relaunch.
  local rule title top bottom footer screen ansi typed claude_idle
  local scrollback short nonascii flush blank
  claude_idle=$(printf 'claude\tidle')
  rule='────────────────────────────────────────────────────────────'
  title=' Firstmate operational input 1790546042 '
  top="${rule}───${title}─"
  bottom="${rule}────────────────────────────────────────────"
  footer='  ⏵⏵ bypass permissions on (shift+tab to cycle)'
  screen="recap: earlier work"$'\n'"$top"$'\n❯'"$NBSP"$'\n'"$bottom"$'\n'"$footer"
  ansi="${ESC}[38;2;128;130;131mrecap: earlier work${ESC}[0m"$'\n'
  ansi+="${ESC}[0m${ESC}[38;2;121;129;134m${rule}─── ${ESC}[38;2;177;185;249m${title# }${ESC}[38;2;121;129;134m─${ESC}[0m"$'\n'
  ansi+="${ESC}[0m${ESC}[38;2;128;130;131m❯${NBSP}${ESC}[0m"$'\n'
  ansi+="${ESC}[0m${ESC}[38;2;121;129;134m${bottom}${ESC}[0m"$'\n'"$footer"
  assert_screen "titled claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' "$claude_idle"
  assert_screen "titled claude idle on herdr (ansi)" empty "$CAPS_STYLED" "$ansi" '' "$claude_idle"
  assert_screen "titled claude idle on zellij (ansi)" empty "$CAPS_STYLED_NOID" "$ansi"
  assert_screen "titled claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "titled claude idle on tmux" empty "$CAPS_TMUX" "$ansi" 2 probe-absent
  typed="$top"$'\n❯ fix the login bug\n'"$bottom"$'\n'"$footer"
  assert_screen "titled claude typed on herdr" pending "$CAPS_STYLED" "$typed" '' "$claude_idle"
  assert_screen "titled claude typed on zellij" pending "$CAPS_STYLED_NOID" "$typed"
  assert_screen "titled claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  assert_screen "titled claude typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  # The staleness rule still holds: a titled sandwich stranded in scrollback,
  # with transcript rows between it and a lower unmatched rule, stays unknown.
  scrollback="$top"$'\n❯'"$NBSP"$'\n'"$bottom"$'\nlater transcript output\n'"$bottom"$'\nmore output'
  assert_screen "titled sandwich in scrollback" unknown "$CAPS_STYLED_NOID" "$scrollback"
  # Width is proven, not assumed: a titled rule narrower than its closing rule
  # is not that composer's top edge.
  short="${rule}${title}─"$'\n❯'"$NBSP"$'\n'"$bottom"
  assert_screen "mismatched titled rule width" unknown "$CAPS_STYLED_NOID" "$short"
  # A non-ASCII title leaves residue and refuses rather than guessing width.
  nonascii="${rule}─── ✳ Firstmate operational input 179054604 ─"$'\n❯'"$NBSP"$'\n'"$bottom"
  assert_screen "non-ASCII titled rule" unknown "$CAPS_STYLED_NOID" "$nonascii"
  # The rule must open with the strict separator's dash run.
  flush=" Firstmate operational input 1790546042 ${rule}────"$'\n❯'"$NBSP"$'\n'"$bottom"
  assert_screen "title flush at the rule's start" unknown "$CAPS_STYLED_NOID" "$flush"
  # The strict blank-row posture is untouched: no glyph row, no proof.
  blank="$top"$'\n\n'"$bottom"
  assert_screen "titled rule over a blank row" unknown "$CAPS_STYLED_NOID" "$blank"
  # The untitled pair keeps its verdict alongside the new shape.
  assert_screen "untitled claude idle on herdr" empty "$CAPS_STYLED" \
    "$bottom"$'\n❯'"$NBSP"$'\n'"$bottom"$'\n'"$footer" '' "$claude_idle"
  pass "matrix: claude's titled top rule proves an idle composer empty and a draft pending (#5601, #5558)"
}

test_matrix_kimi_bordered_shell_glyph_box() {
  # Kimi's bordered `│ > │` composer - the shape fm-spawn.sh's retired
  # spawn-local regex used to own. Now the shared owner proves it everywhere,
  # which is what kimi launch-readiness and delivery route through.
  local screen
  screen=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  assert_screen "kimi idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "kimi idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "kimi idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "kimi idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  pass "matrix: kimi's bordered shell-glyph box reads empty through the shared owner (spawn's fourth copy retired)"
}

test_matrix_claude_inside_zellij_ansi_dump() {
  # Real claude captured through `zellij action dump-screen --ansi`
  # (capability established by the audit): `ESC[m` `❯` U+00A0.
  local screen plain
  screen=$'zellij pane transcript\n'"${ESC}[m❯${NBSP}"
  plain=$'zellij pane transcript\n❯'"$NBSP"
  assert_screen "claude-in-zellij on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "claude-in-zellij on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "claude-in-zellij on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude-in-zellij on plain backends" empty "$CAPS_PLAIN" "$plain"
  pass "matrix: the real claude-in-zellij --ansi dump reads empty in both locales"
}

test_strict_blank_row_divergence() {
  # THE STRICT POSTURE PIN (captain decision blank-row-injection-posture,
  # 2026-08-09): a blank or otherwise unidentified input row with no positive
  # container proof is `unknown`. Each case below read `empty` (or `pending`)
  # under the replaced permissive rule; if any of them drifts back, the
  # permissive posture has silently returned and away-mode injection would
  # again type escalations into unproven panes.
  local out
  # Permissive read this blank cursor row as empty = safe to inject.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'some output\nmore output\n' 2)
  [ "$out" = unknown ] || fail "a blank unidentified cursor row must be unknown (was permissive empty), got '$out'"
  # A dead shell's prompt row.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\n$ ' 1)
  [ "$out" = unknown ] || fail "a dead-shell prompt row must be unknown, got '$out'"
  # A bare busy-footer row is not a composer container.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'Working...' 0)
  [ "$out" = unknown ] || fail "a bare busy-footer row must be unknown (was permissive empty), got '$out'"
  # An unidentified free-text cursor row carries no container proof either.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\nhuman draft text' 1)
  [ "$out" = unknown ] || fail "an unidentified text row must be unknown under strict, got '$out'"
  # A blank screen with no cursor capability.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'\n\n')
  [ "$out" = unknown ] || fail "a blank screen must be unknown, got '$out'"
  pass "strict posture: blank and unidentified rows are unknown, never injectable empty"
}

test_bare_wrap_region_classifies() {
  # Long typed input wraps below the glyph row; the cursor rides the wrapped
  # continuation. The region is IDENTIFIED (glyph row + contiguous non-blank,
  # non-structural rows), so a swallowed Enter still reads pending and earns
  # its retry; a wrapped GHOST suggestion still proves empty.
  local wrapped ghost_wrapped out
  wrapped=$'❯ a very long steer message that\nwraps onto the following line'
  assert_screen "wrapped typed input" pending "$CAPS_TMUX" "$wrapped" 1
  wrapped=$'❯ wrapped typed input\ncontinues without a terminal-inserted glyph'
  assert_screen "ordinary wrapped input" pending "$CAPS_TMUX" "$wrapped" 1
  ghost_wrapped=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$ghost_wrapped" 1)
  [ "$out" = empty ] || fail "a wrapped ghost suggestion should still prove empty, got '$out'"
  # A structural row between the glyph and the cursor breaks the wrap claim.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n────────────────\nbelow the rule' 2)
  [ "$out" = unknown ] || fail "a rule between glyph and cursor must break the wrap region, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n$ live shell' 1)
  [ "$out" = unknown ] || fail "a shell prompt below a glyph row must not become wrapped input, got '$out'"
  pass "fm_composer_classify_screen: the bare composer's wrap region stays identified; structure breaks it"
}

test_contiguous_transcript_reanchors_on_live_prompt() {
  local screen
  screen=$'❯ hi\nHello!\n❯'
  assert_screen "contiguous transcript live prompt on cursorless styled backend" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "contiguous transcript live prompt on cursorless plain backend" empty "$CAPS_PLAIN" "$screen"
  assert_screen "contiguous transcript live prompt with cursor" empty "$CAPS_TMUX" "$screen" 2
  pass "fm_composer_classify_screen: a row-leading agent glyph reanchors the live composer"
}

test_lower_dead_shell_invalidates_cursorless_candidate() {
  local stale live out
  stale=$'old transcript\n❯\nprocess exited\n$'
  assert_screen "stale composer above dead shell on herdr" unknown "$CAPS_STYLED" "$stale"
  assert_screen "stale composer above dead shell on zellij" unknown "$CAPS_STYLED_NOID" "$stale"
  assert_screen "stale composer above dead shell on cmux/orca" unknown "$CAPS_PLAIN" "$stale"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$stale" 1)
  [ "$out" = empty ] \
    || fail "cursor mode must keep the cursor-anchored composer verdict, got '$out'"

  live=$'transcript shell snippet\n$ echo old output\nmore transcript\n❯'
  assert_screen "shell transcript above live composer on herdr" empty "$CAPS_STYLED" "$live"
  assert_screen "shell transcript above live composer on zellij" empty "$CAPS_STYLED_NOID" "$live"
  assert_screen "shell transcript above live composer on cmux/orca" empty "$CAPS_PLAIN" "$live"
  pass "fm_composer_classify_screen: a lower dead shell invalidates only cursorless stale composers"
}

test_cursorless_bare_wrap_region_classifies() {
  local activity status bounded ghost out
  activity=$'❯\nWorking on request...'
  assert_screen "cursorless activity below bare row on herdr" pending "$CAPS_STYLED" "$activity"
  assert_screen "cursorless activity below bare row on zellij" pending "$CAPS_STYLED_NOID" "$activity"
  assert_screen "cursorless activity below bare row on cmux/orca" unknown "$CAPS_PLAIN" "$activity"

  status=$'›\n\ncodex status line'
  assert_screen "blank-separated codex status on herdr" empty "$CAPS_STYLED" "$status"
  assert_screen "blank-separated codex status on zellij" empty "$CAPS_STYLED_NOID" "$status"
  assert_screen "blank-separated codex status on cmux/orca" empty "$CAPS_PLAIN" "$status"

  bounded=$'────────────────────────\n❯\n────────────────────────\nClaude 4.1'
  assert_screen "rule-bounded claude footer on herdr" empty "$CAPS_STYLED" "$bounded" '' probe-absent
  assert_screen "rule-bounded claude footer on zellij" empty "$CAPS_STYLED_NOID" "$bounded"
  assert_screen "rule-bounded claude footer on cmux/orca" empty "$CAPS_PLAIN" "$bounded"

  ghost=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on herdr should be empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on zellij should be empty, got '$out'"
  pass "fm_composer_classify_screen: cursorless bare wrap regions participate in verdicts"
}

test_cursorless_container_rejects_contiguous_lower_activity() {
  local box leftbar grok kimi opencode
  box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...'
  assert_screen "stale box above activity on herdr" unknown "$CAPS_STYLED" "$box"
  assert_screen "stale box above activity on zellij" unknown "$CAPS_STYLED_NOID" "$box"
  assert_screen "stale box above activity on cmux/orca" unknown "$CAPS_PLAIN" "$box"

  leftbar=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\nWorking on request...'
  assert_screen "stale left-bar above activity on herdr" unknown "$CAPS_STYLED" "$leftbar"
  assert_screen "stale left-bar above activity on zellij" unknown "$CAPS_STYLED_NOID" "$leftbar"
  assert_screen "stale left-bar above activity on cmux/orca" unknown "$CAPS_PLAIN" "$leftbar"

  grok=$'╭────────────────────────╮\n│ ❯                      │\n╰──────── Grok 4.5 ──────╯\n\nGrok status'
  kimi=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯\n\nKimi status'
  opencode=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\n\nOpenCode status'
  assert_screen "blank-separated grok footer" empty "$CAPS_STYLED_NOID" "$grok"
  assert_screen "blank-separated kimi footer" empty "$CAPS_PLAIN" "$kimi"
  assert_screen "left-bar floor and blank-separated footer" empty "$CAPS_STYLED_NOID" "$opencode"
  pass "fm_composer_classify_screen: cursorless containers reject only contiguous unclaimed activity"
}

test_bottom_most_candidate_wins() {
  # The one ranking rule: the live composer is bottom-anchored, so a stale
  # decorative box (codex's startup banner) can never outrank the real row
  # below it - the confidently-wrong orca case from the audit.
  local screen out
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "banner above live claude row" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n› Use /skills to list available skills')
  [ "$out" != pending ] || fail "a stale banner must never classify as pending composer text"
  screen=$'❯ old draft\n\n❯'
  assert_screen "blank-separated newer bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  pass "fm_composer_classify_screen: the bottom-most candidate wins; stale banners cannot"
}

test_incomplete_lower_box_invalidates_stale_candidate() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nstartup complete\n╭────────────────────────╮\n│ ❯ clipped live draft  '
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] \
    || fail "an incomplete lower box must invalidate an earlier empty box, got '$out'"
  pass "fm_composer_classify_screen: incomplete lower structure invalidates stale boxes"
}

test_titled_bottom_requires_matching_width() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰─ Grok ─╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1)
  [ "$out" = unknown ] \
    || fail "a short titled bottom must not prove an empty box, got '$out'"
  pass "fm_composer_classify_screen: titled bottoms retain full box geometry"
}

test_cursor_on_proven_box_bottom_classifies_content() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2)
  [ "$out" = empty ] \
    || fail "a cursor on a proven box bottom must classify its content, got '$out'"
  pass "fm_composer_classify_screen: a proven box tolerates a bottom-border cursor"
}

test_selected_content_is_composer_scoped_and_wrap_normalized() {
  local screen out
  screen=$'hello captain in transcript\n╭────────────────────╮\n│ unrelated          │\n│ draft               │\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'unrelated draft' ] \
    || fail "box extraction should contain only normalized selected composer rows, got '$out'"
  screen=$'hello captain in transcript\n┃ hello\n┃ captain\n┃ Build · GPT-5.5 Fast OpenAI · high'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'hello captain' ] \
    || fail "left-bar extraction should join user rows without footer furniture, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost agent-prompt placeholders should be excluded from extracted user content, got '$out'"
  screen=$'╭────────────────────╮\n│ > '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost shell-prompt placeholders should be excluded from boxed user content, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ Type a message...│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'Type a message...' ] \
    || fail "surviving placeholder-like input should remain extracted user content, got '$out'"
  screen=$'❯ a legitimately long steer that\nwraps across the next bare row\n\ntranscript below the break'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'a legitimately long steer that wraps across the next bare row' ] \
    || fail "bare extraction should include only its contiguous wrap region, got '$out'"
  screen=$'❯ wrapped user content\ncontinuation preserves a mid-row ❯ glyph'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content continuation preserves a mid-row ❯ glyph' ] \
    || fail "bare extraction should preserve mid-row agent glyph bytes, got '$out'"
  screen=$'❯ stale composer\n$ live shell'
  if out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen"); then
    fail "a lower live shell must invalidate composer extraction, got '$out'"
  fi
  screen=$'╭──────────────────────────────╮\n│ > wrapped user content       │\n│ ❯ preserves its leading glyph│\n╰──────────────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content ❯ preserves its leading glyph' ] \
    || fail "box extraction should strip only its actual prompt-row glyph, got '$out'"
  pass "fm_composer_extract_selected_content: scopes user content and excludes furniture"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_matrix_claude_bare_nbsp_row
test_matrix_claude_arrow_statusline_footer
test_composer_footer_demotion_needs_a_proven_pair
test_composer_footer_zone_is_shape_independent
test_composer_footer_zone_refuses_rather_than_allows
test_matrix_codex_dim_hint_row
test_matrix_muse_truecolor_glyph_survives_signal_loss
test_matrix_cursor_reverse_video_placeholder_remnant
test_matrix_herdr_halfblock_rule_bounds_bare_wrap
test_matrix_omp_status_row_bounds_bare_composer
test_matrix_codex_idle_starfield_furniture
test_matrix_pi_separated_needs_identity
test_matrix_pi_dollar_status_footer_is_empty
test_matrix_opencode_leftbar_signals
test_matrix_grok_titled_bottom_border
test_matrix_claude_titled_top_rule
test_matrix_kimi_bordered_shell_glyph_box
test_matrix_claude_inside_zellij_ansi_dump
test_strict_blank_row_divergence
test_bare_wrap_region_classifies
test_contiguous_transcript_reanchors_on_live_prompt
test_lower_dead_shell_invalidates_cursorless_candidate
test_cursorless_bare_wrap_region_classifies
test_cursorless_container_rejects_contiguous_lower_activity
test_bottom_most_candidate_wins
test_incomplete_lower_box_invalidates_stale_candidate
test_titled_bottom_requires_matching_width
test_cursor_on_proven_box_bottom_classifies_content
test_selected_content_is_composer_scoped_and_wrap_normalized

test_queued_enter_verdict_busy_pending_is_empty() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "busy + proven pending must be queued delivery (empty), got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)"
}

test_queued_enter_verdict_idle_pending_stays_pending() {
  local out
  out=$(fm_composer_queued_enter_verdict pending idle)
  [ "$out" = pending ] || fail "idle + proven pending must stay a genuine swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown)
  [ "$out" = pending ] || fail "unknown busy is not proof of a queue, got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + idle/unknown stays pending"
}

test_queued_enter_verdict_does_not_convert_other_states() {
  local state out
  for state in empty pending-unproven unknown send-failed future-state; do
    out=$(fm_composer_queued_enter_verdict "$state" busy)
    [ "$out" = "$state" ] || fail "busy must not convert '$state', got '$out'"
    out=$(fm_composer_queued_enter_verdict "$state" idle)
    [ "$out" = "$state" ] || fail "idle must not convert '$state', got '$out'"
  done
  pass "fm_composer_queued_enter_verdict: only proven pending is converted"
}

test_queued_enter_verdict_busy_pending_is_empty
test_queued_enter_verdict_idle_pending_stays_pending
test_queued_enter_verdict_does_not_convert_other_states

# The selected row sits on cursor row 1 so a tmux read whose cursor is that
# row, and a cursorless read, both still see unsubmitted text.
exit_picker_screen() {
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel'
}

fm_test_picker_send() {
  printf 'Enter\n' >> "$FM_TEST_PICKER_ENTERS"
}

fm_test_picker_state() {
  fm_composer_classify_screen 'styled=1' "$FM_TEST_PICKER_SCREEN" 1
}

test_background_exit_picker_stays_pending_and_blocks_retry() {
  local screen out rc sink enters
  screen=$(exit_picker_screen)
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 0 ] || fail "the recorded picker should match"
  [ "$out" = 'Claude background-task exit picker' ] || fail "dialog name was '$out'"
  out=$(fm_composer_blocking_dialog 'Background work is running'); rc=$?
  [ "$rc" -eq 1 ] || fail "a heading alone must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' 'Background work is running' 'Exit and stop tasks')"); rc=$?
  [ "$rc" -eq 1 ] || fail "two of the three strings must not match"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' "$screen" '' '')"); rc=$?
  [ "$rc" -eq 0 ] || fail "blank rows below the footer should still match"
  sink=$(mktemp)
  FM_COMPOSER_DIALOG_SINK=$sink
  out=$(fm_composer_classify_screen 'styled=1' "$screen" 1)
  [ "$out" = pending ] || fail "cursor on the selected row should stay pending, got '$out'"
  [ "$(cat "$sink")" = 'Claude background-task exit picker' ] || fail "classify should note the dialog, got '$(cat "$sink")'"
  out=$(fm_composer_classify_screen 'styled=1' "$screen")
  [ "$out" = pending ] || fail "a styled cursorless picker should stay pending, got '$out'"
  unset FM_COMPOSER_DIALOG_SINK
  rm -f "$sink"
  FM_TEST_PICKER_SCREEN=$screen
  FM_TEST_PICKER_ENTERS=$(mktemp)
  : > "$FM_TEST_PICKER_ENTERS"
  fm_composer_dialog_sink_prepare || fail "the dialog sink could not be prepared"
  sink=$FM_COMPOSER_DIALOG_SINK
  out=$(fm_composer_submit_retry_core fm_test_picker_send fm_test_picker_state win 3 0)
  fm_composer_dialog_sink_release
  [ ! -e "$sink" ] || fail "the release should remove a sink that prepare created"
  [ -z "${FM_COMPOSER_DIALOG_SINK:-}" ] || fail "the release should unset a sink that prepare created"
  enters=$(grep -c '^Enter$' "$FM_TEST_PICKER_ENTERS" || true)
  [ "$out" = unknown ] || fail "a picker must stop the retry as unknown, got '$out'"
  [ "$enters" -eq 1 ] || fail "a picker must receive one Enter, got $enters"
  rm -f "$FM_TEST_PICKER_ENTERS"
  unset FM_TEST_PICKER_SCREEN FM_TEST_PICKER_ENTERS
  pass "the Claude background-task exit picker stays pending and receives no confirming Enter"
}

# The picker's own text, shown the way a worker pane shows it when it prints
# this repository's diff, verification note, or a test fixture: quoted above a
# normal composer. No picker is open, so the next Enter confirms nothing.
quoted_exit_picker_screen() {
  printf '%s\n' \
    '● Here is the fixture the test uses:' \
    "+    'Background work is running' \\" \
    "+    '❯ 1. Exit and stop tasks' \\" \
    "+    'Enter to confirm · Esc to cancel'" \
    '  The selected row is "❯ 1. Exit and stop tasks" and the footer is "Enter to confirm · Esc to cancel".' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel' \
    '' \
    '╭──────────────╮' \
    '│ > next steer │' \
    '╰──────────────╯'
}

test_dialog_heading_and_footer_must_be_the_recorded_lines() {
  local screen out rc
  screen=$(printf '%s\n' \
    'The fixture mentions Background work is running in a sentence' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm · Esc to cancel')
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "a heading buried in a sentence must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  screen=$(printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'Enter to confirm the deployment')
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "a last line that only starts with the confirm words must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  pass "a buried heading or a different last line is not the exit picker"
}

test_dialog_note_skips_the_match_when_no_sink_is_set() {
  local screen out rc before after
  screen=$(exit_picker_screen)
  unset FM_COMPOSER_DIALOG_SINK
  out=$(fm_composer_note_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "a note without a sink should return 1, got $rc"
  [ -z "$out" ] || fail "a note without a sink should print nothing, got '$out'"
  [ -z "${FM_COMPOSER_DIALOG_SINK:-}" ] || fail "a note without a sink must not create one"
  out=$(fm_composer_classify_screen 'styled=1' "$screen" 1)
  [ "$out" = pending ] || fail "classify without a sink should stay pending, got '$out'"
  trap 'true' RETURN
  before=$(trap -p RETURN)
  fm_composer_dialog_sink_prepare || fail "the dialog sink could not be prepared"
  fm_composer_dialog_sink_release
  after=$(trap -p RETURN)
  trap - RETURN
  [ "$before" = "$after" ] || fail "release replaced the caller RETURN trap: $after"
  pass "a dialog note without a sink skips the match, and release leaves a caller RETURN trap"
}

test_quoted_exit_picker_text_is_not_a_dialog() {
  local screen out rc sink enters
  screen=$(quoted_exit_picker_screen)
  out=$(fm_composer_blocking_dialog "$screen"); rc=$?
  [ "$rc" -eq 1 ] || fail "picker text quoted above a normal composer must not match"
  [ -z "$out" ] || fail "a miss must print nothing, got '$out'"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' \
    'Background work is running' \
    "+    '❯ 1. Exit and stop tasks' \\" \
    'Enter to confirm · Esc to cancel')"); rc=$?
  [ "$rc" -eq 1 ] || fail "a selected row that is not alone on its row must not match"
  out=$(fm_composer_blocking_dialog "$(printf '%s\n' \
    '❯ 1. Exit and stop tasks' \
    'Background work is running' \
    'Enter to confirm · Esc to cancel')"); rc=$?
  [ "$rc" -eq 1 ] || fail "a selected row above the heading must not match"
  FM_TEST_PICKER_SCREEN=$screen
  FM_TEST_PICKER_ENTERS=$(mktemp)
  : > "$FM_TEST_PICKER_ENTERS"
  fm_composer_dialog_sink_prepare || fail "the dialog sink could not be prepared"
  sink=$FM_COMPOSER_DIALOG_SINK
  out=$(fm_composer_submit_retry_core fm_test_picker_send fm_test_picker_state win 3 0)
  [ ! -s "$sink" ] || fail "quoted picker text must not be noted as a dialog, got '$(cat "$sink")'"
  fm_composer_dialog_sink_release
  enters=$(grep -c '^Enter$' "$FM_TEST_PICKER_ENTERS" || true)
  [ "$out" = pending ] || fail "quoted picker text must keep the ordinary pending verdict, got '$out'"
  [ "$enters" -eq 3 ] || fail "quoted picker text must keep the ordinary Enter retries, got $enters"
  rm -f "$FM_TEST_PICKER_ENTERS"
  unset FM_TEST_PICKER_SCREEN FM_TEST_PICKER_ENTERS
  pass "picker text quoted above a normal composer is not read as a live picker"
}

# Real Pi 0.87.1 worker viewport, including its closing separator.
# runtime-backends.md owns the live guard and viewport evidence.
pi_trust_dialog_screen() {
  printf '%s\n' \
    '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────' \
    '' \
    ' Trust project folder?' \
    ' /tmp/task-copy' \
    '' \
    ' This allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.' \
    '' \
    ' → Trust' \
    '   Trust parent folder (/tmp)' \
    '   Trust (this session only)' \
    '   Do not trust' \
    '   Do not trust (this session only)' \
    '' \
    ' ↑↓ navigate  enter select  escape/ctrl+c cancel' \
    '' \
    '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────'
}

test_pi_project_trust_dialog_is_named_not_idle() {
  local screen out caps sink candidate
  screen=$(pi_trust_dialog_screen)
  fm_composer_dialog_sink_prepare || fail "could not prepare dialog sink"
  sink=$FM_COMPOSER_DIALOG_SINK
  # Keep both the bordered live viewport and the older footer-last shape.
  for candidate in "$screen" "${screen%$'\n\n────────────────'*}"; do
    out=$(fm_composer_blocking_dialog "$candidate")
    [ "$out" = 'Pi project-trust dialog' ] || fail "Pi trust dialog was not named: $out"
    for caps in 'styled=1' 'styled=0' $'styled=1\ncursor=1'; do
      out=$(fm_composer_classify_screen "$caps" "$candidate" 8)
      [ "$out" != empty ] || fail "a Pi trust dialog must never authorize injection"
      [ "$(cat "$sink")" = 'Pi project-trust dialog' ] || fail "Pi dialog did not cross the classifier sink"
    done
  done
  # A normal Pi composer, including one below an exact transcript of the
  # dialog, is not a live dialog. A near-matching footer is not one either.
  for candidate in \
    $'────────────────────\n\n────────────────────' \
    "$screen"$'\n────────────────────\n\n────────────────────' \
    "${screen%$'\n\n────────────────'*}"$'\n────────────────────\n\n────────────────────' \
    "$screen"$'\nnot a border' \
    "$screen"$'\n────x────' \
    "$screen"$'\n> queued input\n────────────────────' \
    "${screen%↑↓*}"'↑↓ navigate  enter select  another action'; do
    out=$(fm_composer_blocking_dialog "$candidate")
    [ -z "$out" ] || fail "ordinary composer or different footer was named as a dialog: $out"
    out=$(fm_composer_classify_screen $'styled=1\nidentity=1' "$candidate" '' $'pi\tidle')
    [ ! -s "$sink" ] || fail "an ordinary composer retained the old dialog note"
  done
  out=$(fm_composer_classify_screen $'styled=1\nidentity=1' \
    $'────────────────────\n\n────────────────────' '' $'pi\tidle')
  [ "$out" = empty ] || fail "ordinary idle Pi composer must remain empty: $out"
  fm_composer_dialog_sink_release
  pass "Pi project trust is named across composer capabilities, never on an ordinary idle composer"
}

test_pi_project_trust_dialog_is_named_not_idle
test_background_exit_picker_stays_pending_and_blocks_retry
test_dialog_heading_and_footer_must_be_the_recorded_lines
test_dialog_note_skips_the_match_when_no_sink_is_set
test_quoted_exit_picker_text_is_not_a_dialog

# =============================================================================
# Ghost-text robustness through the tmux adapter (bin/fm-tmux-lib.sh).
#
# fm-tmux-lib.sh is sourced only here, after every case above has run, so the
# shared-owner cases above see exactly the definitions they always did. It
# re-sources bin/fm-composer-lib.sh, which redefines the same functions, and
# adds the tmux capture primitives and fm-cursor-lib.sh; none of its functions
# shadows a fm-composer-lib.sh one. ESC (defined above) is the escape byte the
# styled fixtures and the escape-free assertion use.
# =============================================================================

PEEK="$ROOT/bin/fm-peek.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-composer-lib-tests)

# A fake tmux that serves a styled composer line for the dim-aware reader and an
# escape-free line for the plain (peek) path. capture-pane returns the styled
# fixture verbatim WITH -e (mirrors `tmux capture-pane -e`), and the same content
# with SGR sequences stripped WITHOUT -e (mirrors a plain capture). cursor_y comes
# from FM_FAKE_CY. The fake deliberately returns the complete fixture for every
# capture, which exercises the structural scan while preserving the historical
# single-row fallback fixtures.
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0
    start= end= prev=
    for a in "$@"; do
      [ "$a" = "-e" ] && has_e=1
      case "$prev" in
        -S) start=$a ;;
        -E) end=$a ;;
      esac
      prev=$a
    done
    f="${FM_FAKE_STYLED:-/dev/null}"
    if [ -n "${FM_FAKE_ROW:-}" ] \
       && [ "$start" = "${FM_FAKE_CY:-0}" ] \
       && [ "$end" = "${FM_FAKE_CY:-0}" ]; then
      f=$FM_FAKE_ROW
    fi
    if [ "$has_e" = 1 ]; then
      cat "$f" 2>/dev/null
    else
      # Plain capture: drop SGR sequences, as real `tmux capture-pane -p` does.
      LC_ALL=C awk '{gsub(/\033\[[0-9;]*m/, ""); print}' "$f" 2>/dev/null
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# --- fm_tmux_strip_ghost (pure) ---------------------------------------------

test_strip_ghost_drops_dim_keeps_normal() {
  local out
  # Dim run between ESC[2m and ESC[0m is dropped; the prompt glyph survives.
  out=$(printf '\xe2\x9d\xaf \033[2mWhat is the largest country by area?\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dim run not dropped: '$out'"
  # Normal-intensity text is kept verbatim (no styling at all).
  out=$(printf '\xe2\x9d\xaf real human text\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf real human text')" ] || fail "normal text changed: '$out'"
  # Bold (SGR 1) is normal-intensity, NOT dim - must be kept.
  out=$(printf '\033[1mbold typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "bold typed" ] || fail "bold text wrongly dropped: '$out'"
  pass "fm_tmux_strip_ghost drops dim/faint runs, keeps normal and bold text"
}

test_strip_ghost_handles_combined_and_boundary_codes() {
  local out
  # Dim combined with a color in one sequence (ESC[2;37m) is still a dim run.
  out=$(printf '\xe2\x9d\xaf \033[2;37mpredicted\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "combined dim+color not dropped: '$out'"
  # ESC[22m (normal intensity) ends a dim run mid-line; the tail is kept.
  out=$(printf '\033[2mghost\033[22mREALTAIL\n' | fm_tmux_strip_ghost)
  [ "$out" = "REALTAIL" ] || fail "ESC[22m did not end the dim run: '$out'"
  # ESC[0;2m (reset then dim) reads as dim (left-to-right within the sequence).
  out=$(printf 'keep\033[0;2mdrop\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "keep" ] || fail "reset-then-dim not treated as dim: '$out'"
  pass "fm_tmux_strip_ghost handles combined SGR, ESC[22m, and reset-then-dim"
}

test_strip_ghost_keeps_colored_text_with_2_payloads() {
  local out
  # These pin that the awk's truecolor/256-color `2` payload SELECTOR is not
  # mistaken for the SGR-2 dim attribute. The truecolor foregrounds use a BRIGHT
  # colour (grok's real-input RGB 224,222,244, luminance ~225), because a DARK
  # truecolor foreground is now itself a ghost signal (grok's placeholder) and is
  # covered by test_strip_ghost_drops_dark_truecolor_ghost below.
  out=$(printf '\033[38;5;2mgreen typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "green typed" ] || fail "8-bit color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38;2;224;222;244mtruecolor typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "truecolor typed" ] || fail "bright truecolor payload 2 was treated as dim/ghost: '$out'"
  out=$(printf '\033[48;2;4;5;6mbackground typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "background typed" ] || fail "background truecolor payload was treated as dim: '$out'"
  out=$(printf '\033[58;5;2munderline-color typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "underline-color typed" ] || fail "underline color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38:2::224:222:244mcolon truecolor typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "colon truecolor typed" ] || fail "bright colon truecolor payload 2 was treated as dim/ghost: '$out'"
  out=$(printf '\033[58::5::2mcolon underline typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "colon underline typed" ] || fail "colon underline SGR leaked or dimmed text: '$out'"
  out=$(printf '\033[4:2mnot dim underline\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "not dim underline" ] || fail "colon subparameter 2 was treated as dim: '$out'"
  pass "fm_tmux_strip_ghost keeps bright colored text with 2 payloads"
}

# --- Dark truecolor foreground is ghost (grok placeholder), dropped ----------

test_strip_ghost_drops_dark_truecolor_ghost() {
  local out
  # grok renders its placeholder/hint text with a dark, muted truecolor
  # foreground (empirically 38;2;50;47;70 .. 38;2;110;106;134, luminance ~51..110,
  # verified live against grok 0.2.93; the pristine "Type a message..." placeholder
  # was this shape in grok 0.2.82). The shared owner drops it while keeping the
  # bright prompt glyph, so an idle grok composer never reads as pending.
  out=$(printf '\xe2\x9d\xaf \033[38;2;50;47;70mType a message...\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dark truecolor ghost not dropped: '$out'"
  out=$(printf '\033[38;2;110;106;134mplaceholder hint text\033[39m\n' | fm_tmux_strip_ghost)
  [ -z "$out" ] || fail "dark truecolor hint not dropped: '$out'"
  # The colon form drops too.
  out=$(printf '\xe2\x9d\xaf \033[38:2::86:82:110mmuted\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dark colon-truecolor ghost not dropped: '$out'"
  pass "fm_tmux_strip_ghost drops a dark/muted truecolor foreground (grok placeholder)"
}

# --- muse's composer sits closest to the ghost threshold ---------------------

# These are muse 0.1.0-R708.1's real captured composer rows. Its prompt glyph
# `⟩` is truecolor 38;2;90;160;255 (luminance ~149.9) and its typed text is
# 38;2;204;211;219 (~209.8), so the glyph clears the 128 default by the
# narrowest margin in the fleet - roughly a fifth of grok's real-input margin.
# Both must survive stripping: dropping the glyph would empty an idle composer's
# plain row, and dropping the typed text would read a pending pane as empty and
# make it an injection target.
test_strip_ghost_keeps_muse_composer_colors() {
  local out glyph
  glyph=$(printf '\xe2\x9f\xa9')
  out=$(printf '\033[0m\033[38;2;90;160;255m\xe2\x9f\xa9 \033[39m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '%s ' "$glyph")" ] \
    || fail "muse's idle composer glyph was stripped as ghost text: '$out'"
  # The submitted-prompt row carries a background colour too; an SGR 48 payload
  # must not be luminance-tested as if it were the foreground.
  out=$(printf '\033[38;2;90;160;255m\033[48;2;38;56;84m\xe2\x9f\xa9 \033[38;2;204;211;219mhello from firstmate\033[39m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '%s hello from firstmate' "$glyph")" ] \
    || fail "muse's typed text or background-coloured glyph row was stripped: '$out'"
  # The restored prompt muse puts back into the composer after an Escape
  # interrupt is real bright text and must stay visible as pending input.
  out=$(printf '\033[0m\033[38;2;90;160;255m\xe2\x9f\xa9 \033[38;2;204;211;219msecond turn to interrupt\033[39m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '%s second turn to interrupt' "$glyph")" ] \
    || fail "muse's restored post-interrupt prompt was stripped as ghost text: '$out'"
  pass "fm_tmux_strip_ghost keeps muse's near-threshold glyph and its typed text"
}

# --- fm_pane_input_pending: dim ghost is not pending ------------------------

test_dim_ghost_only_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/ghost-only"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # The exact rendering claude emits: a normal prompt glyph + a DIM predicted prompt.
  printf '\xe2\x9d\xaf \033[2mWhat is the largest country by area?\033[0m\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fm_pane_input_pending "fakepane"; then
    fail "dim ghost-only composer falsely read as pending"
  fi
  pass "fm_pane_input_pending: a dim ghost-only composer is NOT pending"
}

test_dim_ghost_inside_bordered_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/ghost-bordered"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # Bordered composer (claude box) holding only dim ghost text.
  printf '╭─────────────────────────────────────╮\n│ \033[2mtry the other approach instead\033[0m      │\n╰─────────────────────────────────────╯\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
     fm_pane_input_pending "fakepane"; then
    fail "dim ghost in a bordered composer falsely read as pending"
  fi
  pass "fm_pane_input_pending: dim ghost inside a bordered composer is NOT pending"
}

test_normal_text_still_pending() {
  local dir fb capture
  dir="$TMP_ROOT/real-text"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # Real human text, normal intensity - must still read as pending.
  printf '\xe2\x9d\xaf fix findings 1 and 3, skip 2\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "real typed text was not detected as pending"
  pass "fm_pane_input_pending: normal-intensity typed text is still pending"
}

test_colored_text_with_2_payload_still_pending() {
  local dir fb capture
  dir="$TMP_ROOT/colored-text"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '\xe2\x9d\xaf \033[38;5;2mgreen typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "8-bit colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[38;2;224;222;244mtruecolor typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "bright truecolor typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58;5;2munderline-color typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "underline-colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58::5::2mcolon underline typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "colon underline typed text was not detected as pending"
  pass "fm_pane_input_pending: bright colored text with 2 payloads is still pending"
}

test_dark_truecolor_ghost_only_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/grok-ghost"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A grok-style pristine composer: bright prompt glyph + a dark/muted truecolor
  # placeholder. It must read NOT pending (the grok TRUECOLOR gap, now covered by
  # the same ANSI-aware owner as claude's dim ghost).
  printf '\xe2\x9d\xaf \033[38;2;50;47;70mType a message...\033[0m\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fm_pane_input_pending "fakepane"; then
    fail "dark truecolor ghost-only composer falsely read as pending"
  fi
  pass "fm_pane_input_pending: a dark truecolor ghost-only composer (grok placeholder) is NOT pending"
}

test_dark_truecolor_bare_shell_prompt_is_unknown() {
  local dir fb capture out prompt
  dir="$TMP_ROOT/dark-shell-prompt"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for prompt in '$' 'user@host $'; do
    printf '\033[38;2;50;47;70m%s\033[0m\n' "$prompt" > "$capture"
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "dark truecolor bare shell prompt '$prompt' must read unknown, got '$out'"
  done
  pass "fm_tmux_composer_state: dark truecolor shell prompts read unknown"
}

test_real_text_with_trailing_ghost_is_pending() {
  local dir fb capture
  dir="$TMP_ROOT/mixed"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A human typed "deploy" and claude appended a dim ghost completion. The real
  # text must win - the composer is pending.
  printf '\xe2\x9d\xaf deploy\033[2m the staging environment now\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "real text with a trailing ghost completion was not detected as pending"
  pass "fm_pane_input_pending: real text plus a trailing ghost run is still pending"
}

# --- fm_tmux_composer_state: structural multi-row box scan ------------------

test_two_row_composer_reads_text_above_empty_cursor_row() {
  local dir fb capture out
  dir="$TMP_ROOT/two-row"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  cat > "$capture" <<'EOF'
╭────────────────────────────────────────────────────╮
│ > Read the brief at /tmp/brief.md and follow it.   │
│                                                    │
╰────────────────────────────────────────────────────╯
EOF
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "two-row composer text above the empty cursor row should be pending, got '$out'"
  pass "fm_tmux_composer_state: text above an empty cursor row is pending"
}

test_wrapped_composer_reads_all_content_rows() {
  local dir fb capture out
  dir="$TMP_ROOT/wrapped"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  cat > "$capture" <<'EOF'
╭────────────────────────────────────────────╮
│ > This deliberately long instruction wraps │
│ across a second composer content row and   │
│ across a third composer content row too.   │
│                                            │
╰────────────────────────────────────────────╯
EOF
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=4 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "a three-row wrapped composer should be pending, got '$out'"
  pass "fm_tmux_composer_state: a message wrapped across three rows is pending"
}

test_proven_box_bottom_border_cursor_classifies_content() {
  local dir fb capture out
  dir="$TMP_ROOT/bottom-border-ghost"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭────────────────────────╮\n│ ❯ \033[38;2;50;47;70mType a message...\033[0m    │\n╰──────── Grok 4.5 ──────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] \
    || fail "a cursor on a proven titled box bottom must classify its content, got '$out'"
  pass "fm_tmux_composer_state: a proven titled box tolerates a bottom-border cursor"
}

test_pi_identity_requires_readable_busy_state() (
  local out
  # Keep the mocks in this subshell so they cannot affect later tests. Defining
  # functions directly inside a command substitution does not parse in Bash 3.2.
  # shellcheck disable=SC2329 # Mock invoked indirectly by the sourced adapter.
  tmux() {
    local arg
    for arg in "$@"; do
      case "$arg" in
        *pane_tty*) printf '\n'; return 0 ;;
        *pane_current_command*) printf 'pi\n'; return 0 ;;
      esac
    done
    return 1
  }
  # shellcheck disable=SC2329 # Mock invoked indirectly by the sourced adapter.
  fm_pane_busy_state() { printf 'unknown'; }
  if out=$(fm_tmux_composer_identity fakepane); then
    fail "a live Pi process with unreadable busy state must not produce identity, got '$out'"
  fi
  pass "fm_tmux_composer_identity: unknown busy state cannot become idle identity"
)

test_bordered_busy_signatures_are_pending() {
  local dir fb capture out signature
  dir="$TMP_ROOT/bordered-busy-signatures"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for signature in 'Working...' 'Ctrl+c:cancel'; do
    printf '╭────────────────────╮\n│ %-18s │\n╰────────────────────╯\n' "$signature" > "$capture"
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "typed bordered busy signature '$signature' should be pending, got '$out'"
  done
  pass "fm_tmux_composer_state: typed Pi and Grok busy signatures inside a box are pending"
}

test_non_bordered_busy_footer_is_unknown_strict() {
  # STRICT divergence (captain decision blank-row-injection-posture): a bare
  # busy-footer row under the cursor is not a composer container, so it no
  # longer reads `empty` the way the old allow-busy compatibility fallback
  # did. Its one load-bearing consumer - submit confirmation on a harness
  # whose mid-turn screen hides the composer (pi) - moved to the submit
  # core's baseline-idle turn-started conversion (fm_tmux_submit_core), which
  # requires an idle-to-busy transition across our own Enter instead of
  # trusting any busy-looking row.
  local dir fb capture out
  dir="$TMP_ROOT/non-bordered-busy"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf 'Working...\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a non-bordered busy footer must read unknown under the strict rule, got '$out'"
  pass "fm_tmux_composer_state: a bare busy-footer row reads unknown (strict container-proof rule)"
}

test_clipped_bordered_box_is_unknown() {
  local dir fb capture out
  dir="$TMP_ROOT/clipped-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭────────────────────╮\n│ >                  │\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a bordered box with no readable bottom border should be unknown, got '$out'"
  pass "fm_tmux_composer_state: an unbounded bordered box fails closed as unknown"
}

test_asymmetric_composer_edges_are_unknown() {
  local dir fb capture out row
  dir="$TMP_ROOT/asymmetric-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for row in '│ > text' 'text │' '│ > text ┃' '──────' '+----' 'text +'; do
    printf '%s\n' "$row" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "unbounded composer-edge row '$row' should be unknown, got '$out'"
  done
  pass "fm_tmux_composer_state: clipped and asymmetric composer edges fail closed"
}

test_mismatched_box_families_are_unknown() {
  local dir fb capture out
  dir="$TMP_ROOT/mismatched-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭────────╮\n┃ >      ┃\n╰────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a box with mismatched border families should be unknown, got '$out'"
  pass "fm_tmux_composer_state: inconsistent box geometry fails closed"
}

test_misaligned_box_is_unknown() {
  local dir fb capture out fixture
  dir="$TMP_ROOT/misaligned-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for fixture in offset width; do
    case "$fixture" in
      offset) printf ' ╭────╮\n │    │\n╰────╯\n' > "$capture" ;;
      width) printf '╭────╮\n│     │\n╰────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "a box with inconsistent $fixture geometry should be unknown, got '$out'"
  done
  pass "fm_tmux_composer_state: misaligned box bounds fail closed"
}

test_unproved_empty_geometry_fails_closed() {
  local dir fb capture out fixture expected
  dir="$TMP_ROOT/unproved-empty-geometry"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for fixture in ghost idle malformed-top; do
    case "$fixture" in
      ghost)
        expected=unknown
        printf '╭────────────╮\n│ \033[2mghost\033[0m │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          fm_tmux_composer_state "fakepane")
        ;;
      idle)
        expected=pending-unproven
        printf '╭────────────╮\n│ idle hint │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          FM_COMPOSER_IDLE_RE='^idle hint$' fm_tmux_composer_state "fakepane")
        ;;
      malformed-top)
        expected=unknown
        printf '╭────x───────╮\n│            │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          fm_tmux_composer_state "fakepane")
        ;;
    esac
    [ "$out" = "$expected" ] \
      || fail "unproved geometry '$fixture' should be $expected, got '$out'"
  done
  pass "fm_tmux_composer_state: unproved ghost and malformed geometry stay unknown while styled placeholder-like text stays pending-unproven"
}

test_differing_widths_use_asymmetric_verdicts() {
  local dir fb capture out
  dir="$TMP_ROOT/differing-widths"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭──────────╮\n│ > text │\n╰──────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending-unproven ] \
    || fail "text in a differing-width box should be pending-unproven, got '$out'"
  printf '╭──────────╮\n│        │\n╰──────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "an empty differing-width box should be unknown, never empty, got '$out'"
  pass "fm_tmux_composer_state: differing widths prefer pending or unknown, never empty"
}

test_wide_composer_text_is_pending() {
  local dir fb capture out text
  dir="$TMP_ROOT/wide-text"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for text in '修复登录问题' 'fix the bug 🔧'; do
    printf '╭────────────────────╮\n│ > %s │\n╰────────────────────╯\n' "$text" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending-unproven ] \
      || fail "wide composer text '$text' should be pending-unproven, got '$out'"
  done
  pass "fm_tmux_composer_state: emoji and CJK text remain pending under the C locale"
}

test_all_tmux_harness_composers_share_classification() {
  local dir fb capture out harness
  dir="$TMP_ROOT/all-harness-composers"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for harness in claude codex opencode pi pi-signed grok; do
    case "$harness" in
      claude) printf '╭────────────╮\n│ ❯ \033[2mtry\033[0m      │\n╰────────────╯\n' > "$capture" ;;
      codex) printf '╭────────────╮\n│ › \033[2mtip\033[0m      │\n╰────────────╯\n' > "$capture" ;;
      opencode) printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$capture" ;;
      pi|pi-signed) printf '╭────────────╮\n│            │\n╰────────────╯\n' > "$capture" ;;
      grok) printf '╭────────────╮\n│ ❯ \033[38;2;50;47;70mType\033[0m     │\n╰────────────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = empty ] \
      || fail "$harness aligned idle composer should be empty, got '$out'"
    case "$harness" in
      claude|grok) printf '╭────────────╮\n│ ❯ fix      │\n╰────────────╯\n' > "$capture" ;;
      codex) printf '╭────────────╮\n│ › fix      │\n╰────────────╯\n' > "$capture" ;;
      opencode|pi|pi-signed) printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "$harness composer with text should be pending, got '$out'"
  done
  pass "fm_tmux_composer_state: all tmux harnesses share empty and pending classification"
}

test_unrecognized_state_defers_input_guard() {
  (
    # shellcheck disable=SC2329
    fm_tmux_composer_state() { printf 'future-state'; }
    fm_pane_input_pending "fakepane"
  ) || fail "an unrecognized composer state should defer the input guard"
  pass "fm_pane_input_pending: unrecognized states defer by default"
}

test_single_capture_leaves_no_fallback_race() {
  # The old reader captured twice (a full-pane scan, then a separate
  # cursor-row band capture), so a pane redraw between the two could hand the
  # verdict a row the scan never saw. The consolidated reader classifies ONE
  # capture (bin/fm-composer-lib.sh, fm_composer_classify_screen), so the
  # race is structurally gone: a divergent band-capture row (served via
  # FM_FAKE_ROW, which only a band capture would read) must have no effect on
  # the verdict.
  local dir fb capture row_capture out
  dir="$TMP_ROOT/fallback-race"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  row_capture="$dir/row.txt"
  printf '› deploy staging\n' > "$capture"
  printf '│ > │\n' > "$row_capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_ROW="$row_capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "the verdict must come from the one full capture (agent glyph + typed text = pending), got '$out'"
  pass "fm_tmux_composer_state: one capture feeds the classifier; no band-capture race remains"
}

test_absent_tmux_identity_keeps_enclosed_bare_verdict() {
  local dir fb capture out nbsp
  dir="$TMP_ROOT/absent-identity"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  nbsp=$(printf '\302\240')
  printf '────────────────────────\n❯%s\n────────────────────────\n' "$nbsp" > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] \
    || fail "an enclosed Claude glyph must keep its bare empty verdict when the Pi-only probe is absent, got '$out'"
  pass "fm_tmux_composer_state: absent Pi identity preserves Claude's enclosed bare verdict"
}

test_legitimate_empty_routes_remain_empty() {
  local dir fb capture out fixture cursor
  dir="$TMP_ROOT/legitimate-empty"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A blank pane is deliberately absent here: under the strict container-proof
  # rule (captain decision blank-row-injection-posture) a blank cursor row is
  # unknown, pinned by tests/fm-daemon.test.sh and test_strict_blank_row_divergence above.
  for fixture in bordered double-bordered agent-prompt; do
    case "$fixture" in
      bordered) printf '╭────╮\n│    │\n╰────╯\n' > "$capture"; cursor=1 ;;
      double-bordered) printf '╔════╗\n║    ║\n╚════╝\n' > "$capture"; cursor=1 ;;
      agent-prompt) printf '›\n' > "$capture"; cursor=0 ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY="$cursor" \
      fm_tmux_composer_state "fakepane")
    [ "$out" = empty ] \
      || fail "legitimate empty route '$fixture' should remain empty, got '$out'"
  done
  pass "fm_tmux_composer_state: only proven structural and non-bordered empty routes stay empty"
}

test_non_bordered_composer_uses_compatibility_fallback() {
  local dir fb capture out
  dir="$TMP_ROOT/non-bordered-fallback"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '› deploy staging\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "a non-bordered composer should retain cursor-row classification, got '$out'"
  pass "fm_tmux_composer_state: panes without bordered structure retain compatibility fallback"
}

test_non_bordered_interior_edges_are_pending() {
  local dir fb capture out row
  dir="$TMP_ROOT/non-bordered-interior-edges"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for row in '› cat file | grep x' '› explain │ this glyph'; do
    printf '%s\n' "$row" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "non-bordered interior edge row '$row' should be pending, got '$out'"
  done
  pass "fm_tmux_composer_state: interior edge glyphs retain non-bordered fallback"
}

# --- fm-peek.sh stays escape-free (LLM-facing path) -------------------------

test_peek_output_is_escape_free() {
  local dir fb capture home out
  dir="$TMP_ROOT/peek"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A pane full of styling, including dim ghost text. The plain peek path must
  # surface NONE of these escape codes into firstmate's context.
  printf 'normal output line\n\xe2\x9d\xaf \033[2mpredicted next prompt\033[0m\n' > "$capture"
  # Empty FM_HOME so fm-guard.sh finds no in-flight task and stays silent.
  home="$dir/home"; mkdir -p "$home/state"
  # Pass an explicit session:window so resolution needs no metadata.
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_STYLED="$capture" \
        "$PEEK" "sess:win" 2>/dev/null)
  case "$out" in
    *"$ESC"*) fail "fm-peek surfaced ANSI escape codes into LLM-facing output" ;;
  esac
  # And it should still carry the real content.
  case "$out" in
    *"predicted next prompt"*) : ;;
    *) fail "fm-peek dropped pane content (expected the ghost text body as plain text)" ;;
  esac
  pass "fm-peek output is escape-free (no raw -e bytes reach firstmate context)"
}

test_strip_ghost_drops_dim_keeps_normal
test_strip_ghost_handles_combined_and_boundary_codes
test_strip_ghost_keeps_colored_text_with_2_payloads
test_strip_ghost_drops_dark_truecolor_ghost
test_strip_ghost_keeps_muse_composer_colors
test_dim_ghost_only_composer_is_not_pending
test_dim_ghost_inside_bordered_composer_is_not_pending
test_normal_text_still_pending
test_colored_text_with_2_payload_still_pending
test_dark_truecolor_ghost_only_composer_is_not_pending
test_dark_truecolor_bare_shell_prompt_is_unknown
test_real_text_with_trailing_ghost_is_pending
test_two_row_composer_reads_text_above_empty_cursor_row
test_wrapped_composer_reads_all_content_rows
test_proven_box_bottom_border_cursor_classifies_content
test_pi_identity_requires_readable_busy_state
test_bordered_busy_signatures_are_pending
test_non_bordered_busy_footer_is_unknown_strict
test_clipped_bordered_box_is_unknown
test_asymmetric_composer_edges_are_unknown
test_mismatched_box_families_are_unknown
test_misaligned_box_is_unknown
test_unproved_empty_geometry_fails_closed
test_differing_widths_use_asymmetric_verdicts
test_wide_composer_text_is_pending
test_all_tmux_harness_composers_share_classification
test_unrecognized_state_defers_input_guard
test_single_capture_leaves_no_fallback_race
test_absent_tmux_identity_keeps_enclosed_bare_verdict
test_legitimate_empty_routes_remain_empty
test_non_bordered_composer_uses_compatibility_fallback
test_non_bordered_interior_edges_are_pending
test_peek_output_is_escape_free
