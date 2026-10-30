#!/usr/bin/env bash
# Shared wait-condition evaluator: the one reader of the condition kinds a park
# (bin/fm-park.sh check) and a declared wait (the `[wait=...]` tag of a
# `paused:` status line, whose vocabulary bin/fm-classify-lib.sh owns) have in
# common, so a park and a declared wait read a file, an inbox pickup and a
# process the same way.
# Sourced by bin/fm-park.sh, including its per-interval `poll`, and by
# bin/fm-classify-lib.sh, so it sources nothing, defines functions only, and
# starts no process where /proc is readable.
#
# fm_wait_cond_eval <condition> <state-dir>: 0 when the condition is met, 1 when
# it is not met yet, and 2 when it cannot be evaluated (a malformed argument or
# a source that cannot be read), never a guess. Kinds:
#   file:<abs-path>, receipt:<abs-path>
#                      met once the path exists.
#   inbox:<task-id>    met once the task record <state-dir>/<task-id>.meta
#                      names an explicit pickup: its last park_pickup= value
#                      equals its last, non-empty park_token= value. A record
#                      that is missing, not a regular file or unreadable cannot
#                      be evaluated.
#   process:<pid>:<start>
#                      met once that process has ended: no process has the
#                      pid, it is a zombie, or its start token
#                      (fm_wait_pid_start_to) is not <start> because the pid
#                      now names a later process.
# Any other kind cannot be evaluated here.
#
# fm_wait_pid_start_to <out-var> <pid>: assigns the start token of a live,
# non-zombie process, which holds only letters and digits: field 22 of
# /proc/<pid>/stat (its start in clock ticks since boot), read in the shell,
# else `ps -o lstart=` with everything but letters and digits removed. Returns
# 1, with an empty value, for no such process or a zombie. Pid plus start token
# names one process for the machine's uptime, so a reused pid never matches.

fm_wait_pid_start_to() {  # <out-var> <pid>
  local __fm_ws_raw='' __fm_ws_tok
  local -a __fm_ws_f
  printf -v "$1" '%s' ''
  case "$2" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#2}" -le 10 ] || return 1
  if [ -r /proc/self/stat ]; then
    # The command name in field 2 may hold spaces, `)` or a newline, so the
    # whole record is read and the fields counted after its last `)`.
    { IFS= read -r -d '' __fm_ws_raw < "/proc/$2/stat"; } 2>/dev/null || :
    case "$__fm_ws_raw" in *')'*) ;; *) return 1 ;; esac
    read -r -d '' -a __fm_ws_f <<< "${__fm_ws_raw##*)}" || :
    case "${__fm_ws_f[0]-}" in ''|Z|X|x) return 1 ;; esac
    __fm_ws_tok=${__fm_ws_f[19]-}
  else
    __fm_ws_raw=$(LC_ALL=C ps -p "$2" -o stat= -o lstart= 2>/dev/null) || return 1
    __fm_ws_raw=${__fm_ws_raw#"${__fm_ws_raw%%[![:space:]]*}"}
    case "$__fm_ws_raw" in ''|Z*) return 1 ;; esac
    __fm_ws_tok=${__fm_ws_raw#*[[:space:]]}
    [ "$__fm_ws_tok" != "$__fm_ws_raw" ] || return 1
    __fm_ws_tok=${__fm_ws_tok//[!A-Za-z0-9]/}
  fi
  case "$__fm_ws_tok" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  printf -v "$1" '%s' "$__fm_ws_tok"
}

fm_wait_cond_eval() {  # <condition> <state-dir>
  local cond=${1-} state=${2-} arg meta line token='' pickup='' pid start now_start
  arg=${cond#*:}
  case "$cond" in
    file:*|receipt:*)
      case "$arg" in /*) ;; *) return 2 ;; esac
      [ -e "$arg" ] && return 0
      return 1
      ;;
    inbox:*)
      case "$arg" in ''|.*|*/*) return 2 ;; esac
      [ -n "$state" ] || return 2
      meta="$state/$arg.meta"
      [ -f "$meta" ] && [ -r "$meta" ] || return 2
      {
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            park_token=*) token=${line#park_token=} ;;
            park_pickup=*) pickup=${line#park_pickup=} ;;
          esac
        done < "$meta"
      } 2>/dev/null || return 2
      [ -n "$token" ] && [ "$pickup" = "$token" ] && return 0
      return 1
      ;;
    process:*)
      pid=${arg%%:*}
      start=${arg#*:}
      [ "$start" != "$arg" ] || return 2
      case "$pid" in ''|0*|*[!0-9]*) return 2 ;; esac
      case "$start" in ''|*[!A-Za-z0-9]*) return 2 ;; esac
      fm_wait_pid_start_to now_start "$pid" || return 0
      [ "$now_start" = "$start" ] && return 1
      return 0
      ;;
  esac
  return 2
}
