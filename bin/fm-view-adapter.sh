#!/usr/bin/env bash
# fm-view-adapter.sh - fixed passive observations for the native view engine.
# Internal API: <backend|saved-custody|done-proof|forge> <task-id> [captured-line-or-pr]
# FM_HOME selects the explicit home; callers bound the whole process group and
# stdout/stderr. Output is a NUL-delimited field packet, never executable text.
# No queue/cursor/publication/action authority; no arbitrary command argument.
# Backend observations currently admit tmux only. Other backends require the
# unchanged legacy client until passive no-lifecycle equivalence is proved.
set -u
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
FM_HOME=${FM_HOME:?explicit FM_HOME required}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
operation=${1:-}
ID=${2:-}
case "$ID" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) exit 2 ;; esac
META="$STATE/$ID.meta"
# Out-variable readers assign these at runtime; initialize explicitly so source-
# aware lint does not confuse their uppercase names with library-local fields.
KIND='' WT='' BACKEND='' TARGET='' HARNESS='' MODE='' PROJECT=''
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
fm_meta_get_to KIND "$META" kind
KIND=${KIND:-ship}
fm_meta_get_to WT "$META" worktree
case "$operation" in
  backend)
    fm_backend_of_meta_to BACKEND "$META"
    [ "$BACKEND" = tmux ] || exit 3
    fm_backend_target_of_meta_to TARGET "$META" || TARGET=''
    [ -n "$TARGET" ] || { printf 'no-target\0'; exit 0; }
    AGENT_STATE=alive
    if ! tmux display-message -p -t "$TARGET" '#{pane_id}' >/dev/null 2>&1; then
      AGENT_STATE=$(fm_backend_agent_state "$BACKEND" "$TARGET")
    fi
    BUSY=''
    if [ "$AGENT_STATE" = alive ] && [ "$KIND" != secondmate ]; then
      # shellcheck source=bin/fm-busy-lib.sh
      . "$SCRIPT_DIR/fm-busy-lib.sh"
      fm_meta_get_to HARNESS "$META" harness
      TAIL=$(fm_backend_capture "$BACKEND" "$TARGET" 40 "fm-$ID" 2>/dev/null) || TAIL=''
      fm_busy_classify_to BUSY "$BACKEND" "$TARGET" "$HARNESS" "$ID" "$STATE" "$TAIL"
    fi
    printf '%s\0%s\0%s\0' "$TARGET" "$AGENT_STATE" "$BUSY"
    ;;
  saved-custody)
    # shellcheck source=bin/fm-suspend-lib.sh
    . "$SCRIPT_DIR/fm-suspend-lib.sh"
    if fm_suspend_validate "$META" "$ID" "$FM_HOME" "$DATA"; then
      printf 'valid\0'
    else
      printf 'invalid\0'
    fi
    ;;
  done-proof)
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck source=bin/fm-dod-lib.sh
    . "$SCRIPT_DIR/fm-dod-lib.sh"
    fm_meta_get_to MODE "$META" mode
    fm_meta_get_to PROJECT "$META" project
    LOG_LINE=${3:-}
    if REASON=$(fm_dod_accept_ship_done "$KIND" "$MODE" "$WT" "$PROJECT" "$LOG_LINE" "$STATE" "$ID" "$META"); then
      LANDED=''
      if [ "$KIND" = ship ] && [ "$MODE" = direct-push ]; then
        HEAD=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null || true)
        LANDED=$(fm_dod_head_on_origin_default "$WT" "$HEAD") || LANDED=''
        [ -z "$LANDED" ] || LANDED="landed on $LANDED"
        LANDED=${LANDED:-not landed on origin\'s default branch}
      fi
      printf 'accepted\0%s\0' "$LANDED"
    else
      printf 'blocked\0%s\0' "$REASON"
    fi
    ;;
  forge)
    # shellcheck source=bin/fm-pr-lib.sh
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    if fm_pr_url_parse "${3:-}"; then
      PROVIDER=$FM_PR_PROVIDER URL=$FM_PR_URL HOST=$FM_PR_HOST PROJECT_PATH=$FM_PR_PATH NUMBER=$FM_PR_NUMBER
    elif fm_pr_metadata_identity_parse "$META"; then
      PROVIDER=$FM_PR_META_PROVIDER URL=$FM_PR_META_URL HOST=$FM_PR_META_HOST PROJECT_PATH=$FM_PR_META_PATH NUMBER=$FM_PR_META_NUMBER
    else
      printf 'run passed: PR state unknown (no PR identity)\0'; exit 0
    fi
    if fm_pr_poll_retirement_receipt_valid "$STATE" "$ID" \
      && [ "$FM_PR_RETIRE_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_RETIRE_URL" = "$URL" ] \
      && [ "$FM_PR_RETIRE_HOST" = "$HOST" ] && [ "$FM_PR_RETIRE_PATH" = "$PROJECT_PATH" ] \
      && [ "$FM_PR_RETIRE_NUMBER" = "$NUMBER" ]; then
      printf 'run passed: PR merged\0'; exit 0
    fi
    if [ "${FM_CREW_STATE_NO_FORGE:-0}" = 1 ]; then
      printf 'run passed: PR state unknown (forge read skipped)\0'; exit 0
    fi
    RC=0
    case "$PROVIDER" in
      github) fm_pr_github_read_record "${PROJECT_PATH%%/*}" "${PROJECT_PATH#*/}" "$NUMBER" || RC=$? ;;
      gitlab) fm_pr_gitlab_read_record "$HOST" "$PROJECT_PATH" "$NUMBER" || RC=$? ;;
      forgejo) fm_pr_forgejo_read_record "$HOST" "$PROJECT_PATH" "$NUMBER" || RC=$? ;;
      gerrit) fm_pr_gerrit_read_record "$HOST" "$NUMBER" || RC=$? ;;
      *) printf 'run passed: PR state unknown (unreadable: %s)\0' "$URL"; exit 0 ;;
    esac
    if [ "$RC" -ne 0 ] || [ -z "$FM_PR_RECORD_STATE" ]; then
      printf 'run passed: PR state unknown (unreadable)\0'; exit 0
    fi
    case "$FM_PR_RECORD_MERGED" in true|false) ;; *) printf 'run passed: PR state unknown (unreadable)\0'; exit 0 ;; esac
    if [ "$FM_PR_RECORD_MERGED" = true ]; then
      printf 'run passed: PR merged\0'; exit 0
    fi
    LOWER=$(printf '%s' "$FM_PR_RECORD_STATE" | tr '[:upper:]' '[:lower:]')
    case "$PROVIDER:$LOWER" in gitlab:opened|gerrit:new) LOWER=open ;; gerrit:abandoned) LOWER=closed ;; esac
    case "$LOWER" in
      open|closed) printf 'run passed: PR %s\0' "$LOWER" ;;
      *) printf 'run passed: PR state %s\0' "$LOWER" ;;
    esac
    ;;
  *) exit 2 ;;
esac
