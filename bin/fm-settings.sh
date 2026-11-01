#!/usr/bin/env bash
# fm-settings.sh - read, check, change and explain Firstmate settings.
#
# Usage:
#   fm-settings.sh get <key>
#   fm-settings.sh set <key> <value> --reason <why>
#   fm-settings.sh set <key> --default --reason <why>
#   fm-settings.sh check
#   fm-settings.sh log [<key>]
#   fm-settings.sh explain <key>
#   fm-settings.sh doc [--check <markdown-file> | --write <markdown-file>]
#   fm-settings.sh --help
#
# A setting is an operational value someone may retune (a deadline, timeout,
# cadence, budget, cap, threshold, margin or retry count) whose range and floor
# are reviewed code and whose value inside that range is a knob. This header
# owns the mechanics; AGENTS.md owns the rule for which values are settings.
#
# Key table. bin/fm-settings.table declares every key, one per line:
#   key | type | min | max | default | scope | reread | on-bad | env | owner | apply
#   type     seconds (whole seconds, optional s/m/h/d suffix), count (whole
#            number), bytes (whole bytes, optional K/M/G/T suffix, 1024-based),
#            ratio (decimal, up to six digits each side of the point),
#            enum:<a>,<b>,... (one listed word) or calendar (a systemd calendar
#            expression; no range). Numeric keys print in base units.
#   min, max the reviewed range, inclusive; "-" for enum and calendar keys.
#   scope    machine (~/.config/firstmate/settings, shared by every home on
#            this machine: resource floors, machine shapes, unit cadences) or
#            home (<home>/config/settings: policy that may differ per home).
#            A key reads from its one scope file only.
#   reread   every-run (read at each run), per-tick (a loop rereads it when the
#            file changes) or install (baked into an installed unit; set runs
#            the key's apply command, the installer's idempotent install path).
#   on-bad   refuse (a failed reading refuses, as a gate must) or last-good (a
#            supervision loop keeps its last good value, or the default, and
#            keeps running).
#   env      an FM_* variable that overrides the key for one invocation, or "-".
#   owner    the script that reads the key; apply, for install keys only, is a
#            command path relative to the repository root plus plain words.
# A rule line "rule | <key> | <op> | <key>" (op >, >=, < or <=) is an
# invariant between two keys of one numeric type; a reading that breaks it
# fails for both keys. The defaults must satisfy every rule and range.
#
# Settings files. Plain "<key> = <value>" lines; blank lines and lines starting
# with # are ignored. A missing file means every key takes its default. A file
# that is present but empty or blank, a symlink, not a regular file,
# unreadable, larger than 64 KiB, holding NUL bytes, or with a line that does
# not parse, an unknown key, a key of the other scope, a duplicate key, a value
# of the wrong type or outside its range, or a broken rule, is a failed
# reading naming <file>:<line>. Precedence: the key's env variable, then its
# scope file, then the default.
#
# Failed readings raise the level alarm settings-invalid-<scope> in this
# home's alert store state/settings-alerts.json (store id "settings",
# projected into state/settings.status); check raises and clears it, and
# bin/fm-settings-lib.sh runs check when a reader first meets a failed file
# reading and again when it recovers.
#
# get prints the key's effective value. Exit 0 good; 1 failed reading of a
# refuse key (nothing printed); 2 unknown key or usage error; 3 failed reading
# of a last-good key (the default is printed). The failure is named on stderr.
#
# set validates the value and the whole resulting file, including every rule,
# under <file>.lock, writes the file atomically and appends one line to
# <file>.log: UTC time, key, old -> new, actor (the task id, or the
# supervision actor, and the harness), why, the reread mode and, for an
# install key, the apply result. --default removes the key's line so it takes
# its default again. set never writes a file that would be a failed reading.
# After each write it keeps a copy at <file>.snapshot.
#
# check reads both scope files and every rule, prints one line per file, and
# raises or clears the alarm. A file that differs from its snapshot was edited
# by hand: check (and set, before writing) logs each changed key as
# "changed outside set: <key>: <old> -> <new>, actor unknown" and refreshes the
# snapshot. Exit 0 when every file reads, 1 otherwise.
#
# log prints both change logs, oldest first, optionally only one key's lines.
# explain prints a key's value and source, its table entry and its last change.
# doc prints the generated "Settings" table for docs/configuration.md;
# --check exits 1 when the section between the fm-settings.sh doc markers in
# the file differs, and --write rewrites that section.
#
# Environment: FM_HOME, FM_CONFIG_OVERRIDE (the home file is
# $FM_CONFIG_OVERRIDE/settings), FM_STATE_OVERRIDE, HOME (the machine file),
# FM_TASK_ID and FM_SUPERVISION_ACTOR (the actor). FM_SETTINGS_TABLE_OVERRIDE
# is a test seam that replaces the key table.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STORE="$STATE/settings-alerts.json"
STORE_ID=settings
STATUS_NAME=settings.status
LOCK_SECONDS=10
DOC_BEGIN='<!-- fm-settings.sh doc: begin -->'
DOC_END='<!-- fm-settings.sh doc: end -->'

# shellcheck source=bin/fm-settings-lib.sh
. "$SCRIPT_DIR/fm-settings-lib.sh"

usage() {
  sed -n '2,/^set -u$/{ /^set -u$/d; s/^# \{0,1\}//; p; }' "$0"
}

die_usage() {
  printf 'fm-settings.sh: %s\n' "$1" >&2
  exit 2
}

HELD_LOCK=

fail() {
  printf 'fm-settings.sh: %s\n' "$1" >&2
  [ -z "$HELD_LOCK" ] || fm_lock_release "$HELD_LOCK"
  exit 1
}

need_table() {
  fm_settings_table_load || fail "$_FMS_TABLE_ERR"
}

need_key() {  # <output-variable> <key>
  _fms_index_to "$1" "$2" || die_usage "unknown settings key '$2' (bin/fm-settings.table lists them)"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

actor() {
  local who harness
  if [ -n "${FM_TASK_ID:-}" ]; then
    who="task $FM_TASK_ID"
  else
    who="${FM_SUPERVISION_ACTOR:-main} session"
  fi
  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null) || harness=''
  printf '%s on %s\n' "$who" "${harness:-an unknown harness}"
}

# The wake-library lock primitives, loaded only by commands that write.
need_locks() {
  command -v fm_lock_acquire_wait_max >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

# loose_pairs <file>: "<key>=<value>" for each line that looks like a setting,
# the last one winning, without validation; used to describe hand edits.
loose_pairs() {
  local line key value
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    _fms_trim_to line "$line"
    case "$line" in ''|'#'*|[!a-z0-9]*) continue ;; *=*) ;; *) continue ;; esac
    _fms_trim_to key "${line%%=*}"
    _fms_trim_to value "${line#*=}"
    printf '%s=%s\n' "$key" "$value"
  done < "$1" 2>/dev/null | awk -F= '{ k = $1; sub(/^[^=]*=/, ""); v[k] = $0; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
    END { for (i = 1; i <= n; i++) print order[i] "=" v[order[i]] }'
}

# pair_value <pairs> <key>: the value <pairs> holds for <key>, or nothing.
pair_value() {
  local pair
  while IFS= read -r pair; do
    [ "${pair%%=*}" != "$2" ] || { printf '%s' "${pair#*=}"; return 0; }
  done <<EOF
$1
EOF
  return 1
}

default_label() {  # <key>
  local i
  _fms_index_to i "$1" && printf 'default (%s)' "${_FMS_DEF[i]}" || printf 'default'
}

# record_outside_changes <path>: log every key whose value differs between the
# file and its snapshot, then refresh the snapshot. The caller holds the lock.
record_outside_changes() {
  local path=$1 snap="$1.snapshot" now old new key found pairs_old pairs_new o n who keys what
  if [ -f "$path" ] && [ ! -L "$path" ] && [ -f "$snap" ] && cmp -s "$path" "$snap"; then
    return 0
  fi
  [ -e "$path" ] || [ -e "$snap" ] || return 0
  if [ -e "$path" ] && { [ -L "$path" ] || [ ! -f "$path" ] || [ ! -r "$path" ]; }; then
    return 0
  fi
  pairs_old=$(loose_pairs "$snap")
  pairs_new=$(loose_pairs "$path")
  now=$(utc_now)
  who=$(actor)
  found=0
  keys=$(printf '%s\n%s\n' "$pairs_old" "$pairs_new" | sed -n 's/=.*//p' | awk '!seen[$0]++')
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if o=$(pair_value "$pairs_old" "$key"); then old=$o; else old=$(default_label "$key"); fi
    if n=$(pair_value "$pairs_new" "$key"); then new=$n; else new=$(default_label "$key"); fi
    [ "$old" != "$new" ] || continue
    found=1
    printf '%s changed outside set: %s: %s -> %s, actor unknown; found by %s\n' \
      "$now" "$key" "$old" "$new" "$who" >> "$path.log" \
      || fail "cannot append to $path.log"
  done <<EOF
$keys
EOF
  if [ "$found" = 0 ]; then
    if [ -e "$path" ]; then what='changed by hand with no setting value changed'; else what='removed by hand'; fi
    printf '%s changed outside set: the file was %s; found by %s\n' \
      "$now" "$what" "$who" >> "$path.log" || fail "cannot append to $path.log"
  fi
  if [ -e "$path" ]; then
    if ! cp -p -- "$path" "$snap.tmp.$$" || ! mv -f -- "$snap.tmp.$$" "$snap"; then
      rm -f -- "$snap.tmp.$$"
      fail "cannot refresh $snap"
    fi
  else
    rm -f -- "$snap" || fail "cannot remove $snap"
  fi
}

with_lock() {  # <path> <command...>
  local lock="$1.lock" rc
  need_locks
  fm_lock_acquire_wait_max "$lock" "$LOCK_SECONDS" \
    || fail "cannot take $lock within ${LOCK_SECONDS}s; another set or check holds it"
  HELD_LOCK=$lock
  shift
  "$@"
  rc=$?
  HELD_LOCK=
  fm_lock_release "$lock"
  return "$rc"
}

alarm_raise() {  # <scope> <path> <error>
  local alert="$SCRIPT_DIR/fm-alert-store.sh"
  if [ ! -f "$STATE/alert-stores/$STORE_ID.reg" ]; then
    "$alert" register "$STORE" "$STORE_ID" "$STATUS_NAME" fm-settings >/dev/null || return 1
  fi
  [ -e "$STATE/$STATUS_NAME" ] || : >> "$STATE/$STATUS_NAME" || return 1
  "$alert" assert "$STORE" "$STORE_ID" "settings-invalid-$1" \
    "$3; fix that line by hand or with bin/fm-settings.sh set, and bin/fm-settings.sh check clears this" \
    settings-invalid "$2" >/dev/null
}

alarm_clear() {  # <scope> <path>
  [ -f "$STORE" ] || return 0
  grep -qF "\"settings-invalid-$1\"" "$STORE" 2>/dev/null || return 0
  "$SCRIPT_DIR/fm-alert-store.sh" clear "$STORE" "$STORE_ID" "settings-invalid-$1" \
    "bin/fm-settings.sh check reads $2 without a problem" >/dev/null
}

cmd_get() {
  local value rc
  [ "$#" -eq 1 ] || die_usage "get needs <key>"
  fm_setting_to value "$1"
  rc=$?
  case "$rc" in
    0|3) printf '%s\n' "$value" ;;
    2) die_usage "$FM_SETTING_ERROR" ;;
  esac
  return "$rc"
}

# check_scope <scope>: record hand edits, read the file; prints its line and
# sets SCOPE_ERROR.
check_scope() {
  local scope=$1 path
  SCOPE_ERROR=''
  if ! fm_settings_scope_path_to path "$scope"; then
    SCOPE_ERROR="the machine settings file cannot be named: HOME is unset"
    printf '%s settings: INVALID: %s\n' "$scope" "$SCOPE_ERROR"
    return 0
  fi
  if [ -e "$path" ] || [ -e "$path.snapshot" ]; then
    if ! { [ -f "$path" ] && [ -f "$path.snapshot" ] && cmp -s "$path" "$path.snapshot"; }; then
      with_lock "$path" record_outside_changes "$path"
    fi
  fi
  _fms_scope_error_to SCOPE_ERROR "$scope"
  if [ -n "$SCOPE_ERROR" ]; then
    printf '%s settings: INVALID: %s\n' "$scope" "$SCOPE_ERROR"
  elif [ ! -e "$path" ]; then
    printf '%s settings: %s is absent; every %s key takes its default\n' "$scope" "$path" "$scope"
  else
    printf '%s settings: %s reads without a problem\n' "$scope" "$path"
  fi
}

cmd_check() {
  local scope path r err err_machine err_home rc=0 i
  [ "$#" -eq 0 ] || die_usage "check takes no arguments"
  need_table
  check_scope machine
  err_machine=$SCOPE_ERROR
  check_scope home
  err_home=$SCOPE_ERROR
  r=0
  while [ "$r" -lt "$_FMS_RN" ]; do
    if fm_settings_rule_check "$r" 0; then
      :
    elif [ $? = 1 ]; then
      printf 'rule: INVALID: %s\n' "$_FMS_WHY"
      # A broken rule belongs to every file that sets one of its keys.
      for i in "${_FMS_RA[r]}" "${_FMS_RB[r]}"; do
        [ -n "${_FMS_FL[i]}" ] || continue
        fm_settings_scope_path_to path "${_FMS_SCOPE[i]}"
        if [ "${_FMS_SCOPE[i]}" = machine ]; then
          [ -n "$err_machine" ] || err_machine="$path:${_FMS_FL[i]}: $_FMS_WHY"
        else
          [ -n "$err_home" ] || err_home="$path:${_FMS_FL[i]}: $_FMS_WHY"
        fi
      done
    fi
    r=$((r + 1))
  done
  for scope in machine home; do
    fm_settings_scope_path_to path "$scope" || path="the machine settings file"
    if [ "$scope" = machine ]; then err=$err_machine; else err=$err_home; fi
    if [ -n "$err" ]; then
      rc=1
      alarm_raise "$scope" "$path" "$err" \
        || printf 'fm-settings.sh: could not raise settings-invalid-%s in %s\n' "$scope" "$STORE" >&2
    else
      alarm_clear "$scope" "$path" \
        || { rc=1; printf 'fm-settings.sh: could not clear settings-invalid-%s in %s\n' "$scope" "$STORE" >&2; }
    fi
  done
  return "$rc"
}

# write_setting <path> <scope> <index> <value-or-empty> <reason>: the locked
# part of set.
write_setting() {
  local path=$1 scope=$2 i=$3 value=$4 reason=$5 key=${_FMS_KEY[$3]}
  local tmp line k old new done=0 err apply_note='' rc=0 cmd
  record_outside_changes "$path"
  if [ -e "$path" ] && { [ -L "$path" ] || [ ! -f "$path" ]; }; then
    fail "$path is not a regular file; remove it before set"
  fi
  old=$(pair_value "$(loose_pairs "$path")" "$key") || old=$(default_label "$key")
  tmp=$(mktemp "$path.tmp.XXXXXX") || fail "cannot write beside $path"
  {
    if [ -f "$path" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        _fms_trim_to k "${line%%=*}"
        case "$line" in
          *=*) if [ "$k" = "$key" ]; then
                 [ "$done" = 1 ] || [ -z "$value" ] || printf '%s = %s\n' "$key" "$value"
                 done=1
                 continue
               fi ;;
        esac
        printf '%s\n' "$line"
      done < "$path"
    else
      printf '# Firstmate %s settings. Change them with bin/fm-settings.sh set; see its --help.\n' "$scope"
    fi
    [ "$done" = 1 ] || [ -z "$value" ] || printf '%s = %s\n' "$key" "$value"
  } > "$tmp" || { rm -f -- "$tmp"; fail "cannot write $tmp"; }
  # Validate the candidate as the scope file, with every rule, before the rename.
  err=$(
    if [ "$scope" = machine ]; then _FMS_FORCE_machine=$tmp; else _FMS_FORCE_home=$tmp; fi
    _fms_scope_error_to e "$scope"
    if [ -z "$e" ]; then
      r=0
      while [ "$r" -lt "$_FMS_RN" ]; do
        if [ "${_FMS_SCOPE[${_FMS_RA[r]}]}" = "$scope" ] || [ "${_FMS_SCOPE[${_FMS_RB[r]}]}" = "$scope" ]; then
          fm_settings_rule_check "$r" 0 || { e=$_FMS_WHY; break; }
        fi
        r=$((r + 1))
      done
    fi
    e=${e//"$tmp"/$path}
    printf '%s' "$e"
  )
  if [ -n "$err" ]; then
    rm -f -- "$tmp"
    fail "refused, nothing written: $err"
  fi
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; fail "cannot replace $path"; }
  if ! cp -p -- "$path" "$path.snapshot.tmp.$$" || ! mv -f -- "$path.snapshot.tmp.$$" "$path.snapshot"; then
    rm -f -- "$path.snapshot.tmp.$$"
    fail "wrote $path but cannot refresh $path.snapshot"
  fi
  if [ -n "$value" ]; then new=$value; else new=$(default_label "$key"); fi
  if [ "${_FMS_REREAD[i]}" = install ]; then
    set -f
    # shellcheck disable=SC2086 # The apply field is plain words, split on purpose.
    set -- ${_FMS_APPLY[i]}
    set +f
    cmd="${SCRIPT_DIR%/*}/$1"
    shift
    if "$cmd" "$@" >&2; then
      apply_note='; apply: ok'
    else
      rc=$?
      apply_note="; apply: failed (exit $rc), rerun ${_FMS_APPLY[i]}"
      rc=1
    fi
  fi
  printf '%s set %s: %s -> %s by %s; why: %s; reread: %s%s\n' \
    "$(utc_now)" "$key" "$old" "$new" "$(actor)" "$reason" "${_FMS_REREAD[i]}" "$apply_note" >> "$path.log" \
    || fail "wrote $path but cannot append to $path.log"
  printf '%s: %s -> %s in %s%s\n' "$key" "$old" "$new" "$path" "$apply_note"
  return "$rc"
}

cmd_set() {
  local key='' value='' reason='' to_default=0 have_value=0 i path scope rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die_usage "--reason needs a value"; reason=$2; shift 2 ;;
      --default) to_default=1; shift ;;
      --*) die_usage "unknown option '$1'" ;;
      *)
        if [ -z "$key" ]; then key=$1
        elif [ "$have_value" = 0 ]; then value=$1; have_value=1
        else die_usage "set takes one <key> and one <value>"
        fi
        shift ;;
    esac
  done
  [ -n "$key" ] || die_usage "set needs <key>"
  [ "$to_default" = 1 ] && [ "$have_value" = 1 ] && die_usage "give a <value> or --default, not both"
  [ "$to_default" = 1 ] || [ "$have_value" = 1 ] || die_usage "set needs <value> or --default"
  _fms_trim_to reason "$reason"
  [ -n "$reason" ] || die_usage "set needs --reason <why>"
  case "$reason" in *$'\n'*) die_usage "the reason must be one line" ;; esac
  need_table
  need_key i "$key"
  if [ "$have_value" = 1 ]; then
    _fms_trim_to value "$value"
    { _fms_norm "${_FMS_TYPE[i]}" "$value" && _fms_range_check "$i" "$_FMS_NUM"; } \
      || fail "refused, nothing written: $key = $value: $_FMS_WHY"
  fi
  scope=${_FMS_SCOPE[i]}
  fm_settings_scope_path_to path "$scope" || fail "the machine settings file cannot be named: HOME is unset"
  mkdir -p "${path%/*}" || fail "cannot create ${path%/*}"
  with_lock "$path" write_setting "$path" "$scope" "$i" "$value" "$reason"
  rc=$?
  cmd_check >/dev/null || true
  return "$rc"
}

cmd_log() {
  local key=${1:-} scope path line out='' i
  [ "$#" -le 1 ] || die_usage "log takes at most one <key>"
  if [ -n "$key" ]; then need_table; need_key i "$key"; fi
  for scope in machine home; do
    fm_settings_scope_path_to path "$scope" || continue
    [ -e "$path.log" ] || continue
    [ -f "$path.log" ] && [ -r "$path.log" ] || fail "$path.log cannot be read"
    while IFS= read -r line || [ -n "$line" ]; do
      if [ -n "$key" ]; then
        case "$line" in *" $key: "*) ;; *) continue ;; esac
      fi
      out="$out${line%% *} [$scope] ${line#* }"$'\n'
    done < "$path.log"
  done
  [ -z "$out" ] || printf '%s' "$out" | sort -s -k1,1
}

cmd_explain() {
  local i value rc path last range
  [ "$#" -eq 1 ] || die_usage "explain needs <key>"
  need_table
  need_key i "$1"
  fm_setting_to value "$1"
  rc=$?
  fm_settings_scope_path_to path "${_FMS_SCOPE[i]}" || path="(HOME is unset)"
  if [ -n "${_FMS_MINRAW[i]}" ]; then range="${_FMS_MINRAW[i]}..${_FMS_MAXRAW[i]}"; else range=none; fi
  printf 'key: %s\n' "$1"
  case "$rc" in
    0) printf 'value: %s (from %s)\n' "$value" "$FM_SETTING_SOURCE" ;;
    3) printf 'value: %s (%s, after a failed reading: %s)\n' "$value" "$FM_SETTING_SOURCE" "$FM_SETTING_ERROR" ;;
    *) printf 'value: none, failed reading: %s\n' "$FM_SETTING_ERROR" ;;
  esac
  printf 'type: %s; range: %s; default: %s\n' "${_FMS_TYPE[i]}" "$range" "${_FMS_DEF[i]}"
  printf 'scope: %s (%s); reread: %s; on a bad reading: %s\n' "${_FMS_SCOPE[i]}" "$path" "${_FMS_REREAD[i]}" "${_FMS_ONBAD[i]}"
  printf 'env override: %s; owner: %s\n' "${_FMS_ENV[i]:-none}" "${_FMS_OWNER[i]}"
  [ -z "${_FMS_APPLY[i]}" ] || printf 'apply: %s\n' "${_FMS_APPLY[i]}"
  last=$(cmd_log "$1" | tail -n 1)
  printf 'last change: %s\n' "${last:-none recorded}"
  [ "$rc" != 2 ] || rc=1
  return "$rc"
}

# shellcheck disable=SC2016 # The backticks are Markdown code spans.
doc_body() {
  local i=0 r=0 range
  printf '| Key | Type | Range | Default | Scope | Reread | On a bad reading | Env override | Owner |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
  while [ "$i" -lt "$_FMS_N" ]; do
    if [ -n "${_FMS_MINRAW[i]}" ]; then range="${_FMS_MINRAW[i]}..${_FMS_MAXRAW[i]}"; else range=-; fi
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | `%s` |\n' "${_FMS_KEY[i]}" "${_FMS_TYPE[i]}" "$range" \
      "${_FMS_DEFRAW[i]}" "${_FMS_SCOPE[i]}" "${_FMS_REREAD[i]}" "${_FMS_ONBAD[i]}" "${_FMS_ENV[i]:--}" "${_FMS_OWNER[i]}"
    i=$((i + 1))
  done
  [ "$_FMS_RN" -gt 0 ] || return 0
  printf '\nInvariants between keys:\n\n'
  while [ "$r" -lt "$_FMS_RN" ]; do
    printf -- '- `%s` %s `%s`\n' "${_FMS_KEY[${_FMS_RA[r]}]}" "${_FMS_ROP[r]}" "${_FMS_KEY[${_FMS_RB[r]}]}"
    r=$((r + 1))
  done
}

doc_section() {
  printf '%s\n' "$DOC_BEGIN"
  doc_body
  printf '%s\n' "$DOC_END"
}

# doc_current <file>: the section between the markers, markers included.
doc_current() {
  awk -v b="$DOC_BEGIN" -v e="$DOC_END" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$1"
}

cmd_doc() {
  local mode=${1:-} file=${2:-} want have tmp
  need_table
  case "$mode" in
    '') [ "$#" -eq 0 ] || die_usage "doc takes --check or --write <file>"; doc_body; return 0 ;;
    --check|--write) [ "$#" -eq 2 ] || die_usage "doc $mode needs <markdown-file>" ;;
    *) die_usage "doc takes --check or --write <file>" ;;
  esac
  [ -f "$file" ] && [ -r "$file" ] || fail "$file cannot be read"
  [ "$(grep -cxF "$DOC_BEGIN" "$file")" = 1 ] && [ "$(grep -cxF "$DOC_END" "$file")" = 1 ] \
    || fail "$file needs exactly one '$DOC_BEGIN' line and one '$DOC_END' line"
  want=$(doc_section)
  have=$(doc_current "$file")
  if [ "$mode" = --check ]; then
    [ "$want" = "$have" ] && return 0
    printf 'fm-settings.sh: the settings section in %s is stale; run bin/fm-settings.sh doc --write %s\n' "$file" "$file" >&2
    return 1
  fi
  [ "$want" != "$have" ] || return 0
  tmp=$(mktemp "$file.XXXXXX") || fail "cannot write beside $file"
  if ! FM_SETTINGS_DOC_BODY=$want awk -v b="$DOC_BEGIN" -v e="$DOC_END" \
      '$0 == b { print ENVIRON["FM_SETTINGS_DOC_BODY"]; skip = 1; next } $0 == e { skip = 0; next } !skip { print }' "$file" > "$tmp" \
      || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    fail "cannot rewrite $file"
  fi
}

sub=${1:-}
[ "$#" -eq 0 ] || shift
case "$sub" in
  -h|--help|help) usage ;;
  get) cmd_get "$@" ;;
  set) cmd_set "$@" ;;
  check) cmd_check "$@" ;;
  log) cmd_log "$@" ;;
  explain) cmd_explain "$@" ;;
  doc) cmd_doc "$@" ;;
  '') usage >&2; exit 2 ;;
  *) die_usage "unknown command '$sub' (see --help)" ;;
esac
