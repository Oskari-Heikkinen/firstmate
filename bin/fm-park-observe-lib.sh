#!/usr/bin/env bash
# Cheap change observations for the when runner's exact fm-park.sh poll argv.
# Usage: fm_park_observation_to <out> <park-script> <verb> <task> <token>
# Requires fm-wake-lib.sh and fm-pr-lib.sh (already loaded by the when runner).
# A successful observation is only a hint to skip an unchanged FALSE poll;
# it is never a true verdict or resume authority. The runner still evaluates
# on change and at least every 300 s, and after every true/error result.
# Local file/receipt existence and inbox metadata are read without forks.
# Merge queues backed by queue.log use one stat; opaque result.sh providers,
# missing/unreadable records and unknown kinds force the full bounded poll.
# No persistent cache, new process, source, trust format or custody authority.

fm_park_observation_to() {
  [ "$#" = 5 ] || return 1
  [ "$2" = "$SCRIPT_DIR/fm-park.sh" ] && [ "$3" = poll ] || return 1
  fm_task_id_path_safe "$4" || return 1
  local _po_meta _po_line _po_cond='' _po_copy='' _po_config='' _po_dir=${FM_MERGE_QUEUE_DIR:-}
  local _po_sig _po_exists=0 _po_parent
  [ -f "$STATE/$4.meta" ] && [ ! -L "$STATE/$4.meta" ] || return 1
  fm_file_text_to _po_meta "$STATE/$4.meta" || return 1
  while IFS= read -r _po_line || [ -n "$_po_line" ]; do
    case "$_po_line" in
      park_when=*) _po_cond=${_po_line#*=} ;;
      copy_state=*) _po_copy=${_po_line#*=} ;;
    esac
  done <<< "$_po_meta"
  # Interrupted custody has its own reconciliation/notification work per poll.
  case "$_po_copy" in ''|retained|released) ;; *) return 1 ;; esac
  case "$_po_cond" in
    file:*|receipt:*)
      case "${_po_cond#*:}" in /*) ;; *) return 1 ;; esac
      _po_parent=${_po_cond#*:}; _po_parent=${_po_parent%/*}
      [ -n "$_po_parent" ] || _po_parent=/
      [ -x "$_po_parent" ] || return 1
      [ ! -e "${_po_cond#*:}" ] || _po_exists=1
      _po_sig=$_po_exists
      ;;
    inbox:*) _po_sig=inbox ;;
    merge-result:*)
      if [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/merge-queue" ]; then
        [ ! -L "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/merge-queue" ] || return 1
        fm_file_text_to _po_config "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/merge-queue" || return 1
      fi
      if [ -z "$_po_dir" ]; then
        while IFS= read -r _po_line || [ -n "$_po_line" ]; do
          case "$_po_line" in dir=*) _po_dir=${_po_line#*=} ;; esac
        done <<< "$_po_config"
      fi
      case "$_po_dir" in '~/'*) _po_dir=$HOME/${_po_dir#'~/'} ;; esac
      [ -n "$_po_dir" ] || return 1
      # A provider can depend on anything, not just these files. Never cache it.
      [ ! -x "$_po_dir/result.sh" ] || return 1
      [ -f "$_po_dir/queue.log" ] && [ -r "$_po_dir/queue.log" ] || return 1
      if [ "$_FM_UNAME" = Darwin ]; then
        _po_sig=$(exec /usr/bin/stat -L -f '%d:%i:%p:%z:%Fm:%Fc' "$_po_dir/queue.log") || return 1
      else
        _po_sig=$(exec stat -L -c '%d:%i:%f:%s:%y:%z' -- "$_po_dir/queue.log") || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  # Include the whole task record: cancellation, supersession, incarnation and
  # custody changes must reach the real poll even if its condition is unchanged.
  printf -v "$1" '%s\n%s\n%s\n%s' "$_po_meta" "$_po_config" "$_po_dir" "$_po_sig"
}
