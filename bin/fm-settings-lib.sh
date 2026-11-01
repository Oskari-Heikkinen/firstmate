#!/usr/bin/env bash
# fm-settings-lib.sh - the one reader of Firstmate settings.
#
# Source it and call
#   fm_setting_to <output-variable> <key>
# which assigns the key's effective value and returns
#   0 the value is good; FM_SETTING_SOURCE names where it came from
#     (env <NAME>, <file>:<line>, or default),
#   1 failed reading of a refuse key: the variable is empty,
#   2 the key is not in the table, or the table itself does not parse,
#   3 failed reading of a last-good key: the variable holds the last good
#     value this process read, or the default when there is none, so a
#     supervision loop keeps running.
# On 1 and 3, FM_SETTING_ERROR names the env variable or file:line and what is
# wrong, one stderr line says so once per distinct error, and a file error
# raises the settings-invalid alarm through `bin/fm-settings.sh check`; when
# the reading recovers the same check clears it.
#
# Precedence: the env variable the table names for the key (a per-invocation
# override), then the key's scope file, then the table default. Each key
# reads from exactly one scope file. bin/fm-settings.sh --help owns the table
# and file formats, the types and the validation rules; this library is their
# only parser, and bin/fm-settings.sh sources it.
#
# A parsed scope file is kept per process, keyed by its path, inode, size and
# mtime, so a long-running loop pays one stat per read and reparses only after
# a change. The parse is fork-free apart from that stat.

FM_SETTINGS_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_SETTINGS_TABLE_FILE=${FM_SETTINGS_TABLE_OVERRIDE:-$FM_SETTINGS_LIB_DIR/fm-settings.table}
# Input-safety bound on a settings file; a larger file is a failed reading.
FM_SETTINGS_FILE_MAX=65536
{ _FMS_UNAME=$(uname); } 2>/dev/null || _FMS_UNAME=unknown

_FMS_TABLE_STATE=''   # '' not loaded, ok, bad
_FMS_TABLE_ERR=''
_FMS_N=0
_FMS_KEY=() _FMS_TYPE=() _FMS_MIN=() _FMS_MAX=() _FMS_DEF=() _FMS_DEFN=() _FMS_DEFRAW=()
_FMS_SCOPE=() _FMS_REREAD=() _FMS_ONBAD=() _FMS_ENV=() _FMS_OWNER=() _FMS_APPLY=()
_FMS_MINRAW=() _FMS_MAXRAW=()
_FMS_RN=0
_FMS_RA=() _FMS_ROP=() _FMS_RB=() _FMS_RLINE=()
# Per key: the value its scope file holds (print form, compare form, line).
_FMS_FV=() _FMS_FN=() _FMS_FL=()
# Per key: the last good value this process read.
_FMS_GOOD=()
# Per scope (machine, home): cache signature, state (absent, ok, bad), error.
_FMS_SIG_machine='' _FMS_STATE_machine='' _FMS_ERR_machine='' _FMS_PATH_machine=''
_FMS_SIG_home='' _FMS_STATE_home='' _FMS_ERR_home='' _FMS_PATH_home=''
# The last error this process reported and alarmed on.
_FMS_REPORTED=''

_fms_trim_to() {  # <output-variable> <text>
  local _fmst_s=$2
  _fmst_s=${_fmst_s#"${_fmst_s%%[![:space:]]*}"}
  _fmst_s=${_fmst_s%"${_fmst_s##*[![:space:]]}"}
  printf -v "$1" '%s' "$_fmst_s"
}

# _fms_norm <type> <raw>: validate <raw> as <type>. Sets _FMS_V (print form)
# and _FMS_NUM (compare form; empty for enum and calendar) and returns 0, or
# sets _FMS_WHY and returns 1.
_fms_norm() {
  local type=$1 raw=$2 digits mult=1 int frac
  _FMS_V='' _FMS_NUM='' _FMS_WHY=''
  case "$type" in
    seconds)
      case "$raw" in *[smhd]) digits=${raw%?} ;; *) digits=$raw ;; esac
      case "$digits" in ''|*[!0-9]*) _FMS_WHY="'$raw' is not a whole number of seconds (an optional s, m, h or d suffix)"; return 1 ;; esac
      [ "${#digits}" -le 12 ] || { _FMS_WHY="'$raw' is too large"; return 1; }
      case "$raw" in *m) mult=60 ;; *h) mult=3600 ;; *d) mult=86400 ;; esac
      _FMS_NUM=$((10#$digits * mult)) ;;
    count)
      case "$raw" in ''|*[!0-9]*) _FMS_WHY="'$raw' is not a whole number"; return 1 ;; esac
      [ "${#raw}" -le 15 ] || { _FMS_WHY="'$raw' is too large"; return 1; }
      _FMS_NUM=$((10#$raw)) ;;
    bytes)
      case "$raw" in *[KMGT]) digits=${raw%?} ;; *) digits=$raw ;; esac
      case "$digits" in ''|*[!0-9]*) _FMS_WHY="'$raw' is not a byte size (a whole number with an optional K, M, G or T suffix)"; return 1 ;; esac
      case "$raw" in
        *[KMGT]) [ "${#digits}" -le 6 ] || { _FMS_WHY="'$raw' is too large"; return 1; } ;;
        *) [ "${#digits}" -le 15 ] || { _FMS_WHY="'$raw' is too large"; return 1; } ;;
      esac
      case "$raw" in *K) mult=1024 ;; *M) mult=1048576 ;; *G) mult=1073741824 ;; *T) mult=1099511627776 ;; esac
      _FMS_NUM=$((10#$digits * mult)) ;;
    ratio)
      int=${raw%%.*}
      case "$raw" in *.*) frac=${raw#*.} ;; *) frac='' ;; esac
      case "$int" in ''|*[!0-9]*) _FMS_WHY="'$raw' is not a decimal number"; return 1 ;; esac
      case "$raw" in *.) _FMS_WHY="'$raw' is not a decimal number"; return 1 ;; esac
      case "$frac" in *[!0-9]*) _FMS_WHY="'$raw' is not a decimal number"; return 1 ;; esac
      [ "${#int}" -le 6 ] && [ "${#frac}" -le 6 ] || { _FMS_WHY="'$raw' has more than six digits on one side of the point"; return 1; }
      frac="${frac}000000"
      frac=${frac:0:6}
      _FMS_NUM=$((10#$int * 1000000 + 10#$frac))
      _FMS_V=$raw
      return 0 ;;
    enum:*)
      case "$raw" in *,*) _FMS_WHY="'$raw' is not one of ${type#enum:}"; return 1 ;; esac
      case ",${type#enum:}," in
        *",$raw,"*) [ -n "$raw" ] || { _FMS_WHY="the value is empty"; return 1; } ;;
        *) _FMS_WHY="'$raw' is not one of ${type#enum:}"; return 1 ;;
      esac
      _FMS_V=$raw
      return 0 ;;
    calendar)
      case "$raw" in ''|*[!0-9A-Za-z*,./:~\ -]*) _FMS_WHY="'$raw' is not a calendar expression"; return 1 ;; esac
      [ "${#raw}" -le 64 ] || { _FMS_WHY="'$raw' is longer than 64 characters"; return 1; }
      _FMS_V=$raw
      return 0 ;;
    *) _FMS_WHY="unknown type '$type'"; return 1 ;;
  esac
  _FMS_V=$_FMS_NUM
}

_fms_numeric_type() {  # <type>
  case "$1" in seconds|count|bytes|ratio) return 0 ;; *) return 1 ;; esac
}

# _fms_index_to <output-variable> <key>: the key's table index, or -1.
_fms_index_to() {
  local _fmsi_i=0
  while [ "$_fmsi_i" -lt "$_FMS_N" ]; do
    [ "${_FMS_KEY[_fmsi_i]}" != "$2" ] || { printf -v "$1" '%s' "$_fmsi_i"; return 0; }
    _fmsi_i=$((_fmsi_i + 1))
  done
  printf -v "$1" '%s' -1
  return 1
}

# _fms_range_check <index> <num>: 0 inside the key's range, else sets _FMS_WHY.
_fms_range_check() {
  local i=$1
  _fms_numeric_type "${_FMS_TYPE[i]}" || return 0
  if [ "$2" -lt "${_FMS_MIN[i]}" ] || [ "$2" -gt "${_FMS_MAX[i]}" ]; then
    _FMS_WHY="it is outside the reviewed range ${_FMS_MINRAW[i]}..${_FMS_MAXRAW[i]}"
    return 1
  fi
}

# fm_settings_table_load: parse the key table once per process. 0 ok; 1 with
# _FMS_TABLE_ERR naming table:line.
fm_settings_table_load() {
  [ "$_FMS_TABLE_STATE" != ok ] || return 0
  [ "$_FMS_TABLE_STATE" != bad ] || return 1
  local line lineno=0 rest f n i j why nf
  local -a fields
  if ! [ -f "$FM_SETTINGS_TABLE_FILE" ] || ! [ -r "$FM_SETTINGS_TABLE_FILE" ]; then
    _FMS_TABLE_ERR="$FM_SETTINGS_TABLE_FILE: the settings key table is missing or unreadable"
    _FMS_TABLE_STATE=bad
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    _fms_trim_to line "$line"
    case "$line" in ''|'#'*) continue ;; esac
    fields=() nf=0
    rest="$line|"
    while [ -n "$rest" ]; do
      _fms_trim_to f "${rest%%|*}"
      [ "$f" != - ] || f=''
      fields[nf]=$f
      nf=$((nf + 1))
      rest=${rest#*|}
    done
    if [ "${fields[0]}" = rule ]; then
      [ "$nf" -eq 4 ] || { _fms_table_bad "a rule line needs: rule | <key> | <op> | <key>"; return 1; }
      _fms_index_to i "${fields[1]}" || { _fms_table_bad "rule names unknown key '${fields[1]}'"; return 1; }
      _fms_index_to j "${fields[3]}" || { _fms_table_bad "rule names unknown key '${fields[3]}'"; return 1; }
      case "${fields[2]}" in '>'|'>='|'<'|'<=') ;; *) _fms_table_bad "unknown rule operator '${fields[2]}'"; return 1 ;; esac
      { _fms_numeric_type "${_FMS_TYPE[i]}" && [ "${_FMS_TYPE[i]}" = "${_FMS_TYPE[j]}" ]; } \
        || { _fms_table_bad "a rule compares two keys of one numeric type"; return 1; }
      n=$_FMS_RN
      _FMS_RA[n]=$i _FMS_ROP[n]=${fields[2]} _FMS_RB[n]=$j _FMS_RLINE[n]=$lineno
      _FMS_RN=$((n + 1))
      _fms_rule_holds "${_FMS_DEFN[i]}" "${fields[2]}" "${_FMS_DEFN[j]}" \
        || { _fms_table_bad "the defaults break this rule"; return 1; }
      continue
    fi
    [ "$nf" -eq 11 ] || { _fms_table_bad "a key line has 11 fields, this one has $nf"; return 1; }
    case "${fields[0]}" in
      [a-z0-9]*) case "${fields[0]}" in *[!a-z0-9.-]*) _fms_table_bad "bad key name '${fields[0]}'"; return 1 ;; esac ;;
      *) _fms_table_bad "bad key name '${fields[0]}'"; return 1 ;;
    esac
    ! _fms_index_to i "${fields[0]}" || { _fms_table_bad "duplicate key '${fields[0]}'"; return 1; }
    n=$_FMS_N
    _FMS_KEY[n]=${fields[0]} _FMS_TYPE[n]=${fields[1]}
    if _fms_numeric_type "${fields[1]}"; then
      _fms_norm "${fields[1]}" "${fields[2]}" || { _fms_table_bad "min: $_FMS_WHY"; return 1; }
      _FMS_MIN[n]=$_FMS_NUM _FMS_MINRAW[n]=${fields[2]}
      _fms_norm "${fields[1]}" "${fields[3]}" || { _fms_table_bad "max: $_FMS_WHY"; return 1; }
      _FMS_MAX[n]=$_FMS_NUM _FMS_MAXRAW[n]=${fields[3]}
      [ "${_FMS_MIN[n]}" -le "${_FMS_MAX[n]}" ] || { _fms_table_bad "min is above max"; return 1; }
    else
      [ -z "${fields[2]}${fields[3]}" ] || { _fms_table_bad "an ${fields[1]} key takes no min or max"; return 1; }
      _FMS_MIN[n]='' _FMS_MAX[n]='' _FMS_MINRAW[n]='' _FMS_MAXRAW[n]=''
    fi
    _fms_norm "${fields[1]}" "${fields[4]}" || { _fms_table_bad "default: $_FMS_WHY"; return 1; }
    _FMS_DEF[n]=$_FMS_V _FMS_DEFN[n]=$_FMS_NUM _FMS_DEFRAW[n]=${fields[4]}
    _FMS_N=$((n + 1))
    _fms_range_check "$n" "${_FMS_DEFN[n]}" || { _FMS_N=$n; _fms_table_bad "default: $_FMS_WHY"; return 1; }
    case "${fields[5]}" in machine|home) ;; *) _FMS_N=$n; _fms_table_bad "scope must be machine or home"; return 1 ;; esac
    case "${fields[6]}" in every-run|per-tick) why='' ;; install) why=install ;; *) _FMS_N=$n; _fms_table_bad "reread must be every-run, per-tick or install"; return 1 ;; esac
    case "${fields[7]}" in refuse|last-good) ;; *) _FMS_N=$n; _fms_table_bad "on-bad must be refuse or last-good"; return 1 ;; esac
    case "${fields[8]}" in ''|FM_*) case "${fields[8]}" in *[!A-Z0-9_]*) _FMS_N=$n; _fms_table_bad "bad env name '${fields[8]}'"; return 1 ;; esac ;;
      *) _FMS_N=$n; _fms_table_bad "an env override is named FM_*"; return 1 ;; esac
    [ -n "${fields[9]}" ] || { _FMS_N=$n; _fms_table_bad "every key names its owning script"; return 1; }
    if [ -n "$why" ] && [ -z "${fields[10]}" ]; then _FMS_N=$n; _fms_table_bad "an install key names its apply command"; return 1; fi
    if [ -z "$why" ] && [ -n "${fields[10]}" ]; then _FMS_N=$n; _fms_table_bad "only an install key has an apply command"; return 1; fi
    _FMS_SCOPE[n]=${fields[5]} _FMS_REREAD[n]=${fields[6]} _FMS_ONBAD[n]=${fields[7]}
    _FMS_ENV[n]=${fields[8]} _FMS_OWNER[n]=${fields[9]} _FMS_APPLY[n]=${fields[10]}
    _FMS_FV[n]='' _FMS_FN[n]='' _FMS_FL[n]='' _FMS_GOOD[n]=''
  done < "$FM_SETTINGS_TABLE_FILE"
  _FMS_TABLE_STATE=ok
}

_fms_table_bad() {  # <why>: uses the caller's lineno
  _FMS_TABLE_ERR="$FM_SETTINGS_TABLE_FILE:$lineno: $1"
  _FMS_TABLE_STATE=bad
}

_fms_rule_holds() {  # <a> <op> <b>
  case "$2" in
    '>') [ "$1" -gt "$3" ] ;;
    '>=') [ "$1" -ge "$3" ] ;;
    '<') [ "$1" -lt "$3" ] ;;
    '<=') [ "$1" -le "$3" ] ;;
    *) return 1 ;;
  esac
}

# fm_settings_scope_path_to <output-variable> <scope>: the scope's file path;
# 1 when it cannot be named (HOME unset for the machine file).
# bin/fm-settings.sh set points _FMS_FORCE_<scope> at a candidate file to
# validate it before the rename.
fm_settings_scope_path_to() {
  case "$2" in
    machine) [ -z "${_FMS_FORCE_machine:-}" ] || { printf -v "$1" '%s' "$_FMS_FORCE_machine"; return 0; } ;;
    home) [ -z "${_FMS_FORCE_home:-}" ] || { printf -v "$1" '%s' "$_FMS_FORCE_home"; return 0; } ;;
  esac
  case "$2" in
    machine)
      [ -n "${HOME:-}" ] || { printf -v "$1" '%s' ''; return 1; }
      printf -v "$1" '%s' "$HOME/.config/firstmate/settings" ;;
    home)
      printf -v "$1" '%s' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_SETTINGS_LIB_DIR%/*}}}/config}/settings" ;;
    *) return 1 ;;
  esac
}

# _fms_stat_sig_to <output-variable> <path>: inode, size and mtime, one fork.
_fms_stat_sig_to() {
  local _fmss_out
  if [ "$_FMS_UNAME" = Darwin ]; then
    { _fmss_out=$(/usr/bin/stat -f '%i %z %m' "$2"); } 2>/dev/null || return 1
  else
    { _fmss_out=$(stat -c '%i %s %Y' "$2"); } 2>/dev/null || return 1
  fi
  printf -v "$1" '%s' "$_fmss_out"
}

# fm_settings_file_load <scope>: (re)read the scope file when it changed.
# Sets _FMS_STATE_<scope> to absent, ok or bad, and _FMS_ERR_<scope> to
# "<file>:<line>: <why>" (or "<file>: <why>") when bad. Returns 0 unless bad.
fm_settings_file_load() {
  local scope=$1 path sig size prev_sig prev_state
  fm_settings_table_load || return 1
  if ! fm_settings_scope_path_to path "$scope"; then
    _fms_scope_set "$scope" '' bad "the machine settings file cannot be named: HOME is unset" ''
    return 1
  fi
  if ! [ -e "$path" ] && ! [ -L "$path" ]; then
    _fms_scope_set "$scope" "$path" absent '' absent
    return 0
  fi
  if [ -L "$path" ]; then
    _fms_scope_set "$scope" "$path" bad "$path: is a symlink; settings files are regular files" "symlink"
    return 1
  fi
  if ! [ -f "$path" ]; then
    _fms_scope_set "$scope" "$path" bad "$path: is not a regular file" "nonregular"
    return 1
  fi
  if ! [ -r "$path" ] || ! _fms_stat_sig_to sig "$path"; then
    _fms_scope_set "$scope" "$path" bad "$path: cannot be read" "unreadable"
    return 1
  fi
  sig="$path $sig"
  if [ "$scope" = machine ]; then
    prev_sig=$_FMS_SIG_machine prev_state=$_FMS_STATE_machine
  else
    prev_sig=$_FMS_SIG_home prev_state=$_FMS_STATE_home
  fi
  if [ "$sig" = "$prev_sig" ] && [ -n "$prev_state" ]; then
    [ "$prev_state" != bad ]
    return
  fi
  size=${sig% *}
  size=${size##* }
  if [ "$size" -gt "$FM_SETTINGS_FILE_MAX" ]; then
    _fms_scope_set "$scope" "$path" bad "$path: is larger than $FM_SETTINGS_FILE_MAX bytes" "$sig"
    return 1
  fi
  _fms_parse "$scope" "$path" "$size"
  if [ -n "$_FMS_WHY" ]; then
    _fms_scope_set "$scope" "$path" bad "$_FMS_WHY" "$sig"
    return 1
  fi
  _fms_scope_set "$scope" "$path" ok '' "$sig"
}

_fms_scope_set() {  # <scope> <path> <state> <error> <sig>
  if [ "$1" = machine ]; then
    _FMS_PATH_machine=$2 _FMS_STATE_machine=$3 _FMS_ERR_machine=$4 _FMS_SIG_machine=$5
  else
    _FMS_PATH_home=$2 _FMS_STATE_home=$3 _FMS_ERR_home=$4 _FMS_SIG_home=$5
  fi
  [ "$3" = ok ] || _fms_clear_scope_values "$1"
}

_fms_clear_scope_values() {  # <scope>
  local i=0
  while [ "$i" -lt "$_FMS_N" ]; do
    [ "${_FMS_SCOPE[i]}" != "$1" ] || { _FMS_FV[i]='' _FMS_FN[i]='' _FMS_FL[i]=''; }
    i=$((i + 1))
  done
}

# _fms_parse <scope> <path> <size>: parse one scope file into _FMS_FV/FN/FL.
# Leaves _FMS_WHY empty on success, else "<path>:<line>: <why>".
_fms_parse() {
  local scope=$1 path=$2 size=$3 LC_ALL=C
  local line raw key value lineno=0 bytes=0 content=0 i other nl
  _fms_clear_scope_values "$scope"
  _FMS_WHY=''
  {
    while :; do
      if IFS= read -r line; then nl=1; else [ -n "$line" ] || break; nl=0; fi
      lineno=$((lineno + 1))
      bytes=$((bytes + ${#line} + nl))
      _fms_trim_to raw "$line"
      case "$raw" in
        '') continue ;;
        '#'*) content=1; continue ;;
      esac
      content=1
      case "$raw" in
        *=*) ;;
        *) _FMS_WHY="$path:$lineno: does not parse; a setting line is <key> = <value>"; return 0 ;;
      esac
      _fms_trim_to key "${raw%%=*}"
      _fms_trim_to value "${raw#*=}"
      if ! _fms_index_to i "$key"; then
        _FMS_WHY="$path:$lineno: unknown key '$key'"
        return 0
      fi
      if [ "${_FMS_SCOPE[i]}" != "$scope" ]; then
        fm_settings_scope_path_to other "${_FMS_SCOPE[i]}" || other="the ${_FMS_SCOPE[i]} settings file"
        _FMS_WHY="$path:$lineno: $key is a ${_FMS_SCOPE[i]} key; set it in $other"
        return 0
      fi
      if [ -n "${_FMS_FL[i]}" ]; then
        _FMS_WHY="$path:$lineno: duplicate $key (first set on line ${_FMS_FL[i]})"
        return 0
      fi
      if ! _fms_norm "${_FMS_TYPE[i]}" "$value" || ! _fms_range_check "$i" "$_FMS_NUM"; then
        _FMS_WHY="$path:$lineno: $key = $value: $_FMS_WHY"
        return 0
      fi
      _FMS_FV[i]=$_FMS_V _FMS_FN[i]=$_FMS_NUM _FMS_FL[i]=$lineno
    done
  } < "$path" 2>/dev/null || { _FMS_WHY="$path: cannot be read"; return 0; }
  if [ "$bytes" -ne "$size" ]; then
    _FMS_WHY="$path: read $bytes of $size bytes; the file holds NUL bytes or changed while it was read"
  elif [ "$content" = 0 ]; then
    _FMS_WHY="$path: is empty; delete it or set a key with bin/fm-settings.sh set"
  fi
}

# _fms_effective <index> <use-env>: the key's value from env (when <use-env>
# is 1), its loaded scope file, or the default. Sets _FMS_EV, _FMS_EN and
# _FMS_ESRC, or _FMS_WHY and returns 1. The scope file must be loaded.
_fms_effective() {
  local i=$1 name=${_FMS_ENV[$1]} raw path
  if [ "$2" = 1 ] && [ -n "$name" ] && [ -n "${!name:-}" ]; then
    raw=${!name}
    if ! _fms_norm "${_FMS_TYPE[i]}" "$raw" || ! _fms_range_check "$i" "$_FMS_NUM"; then
      _FMS_WHY="env $name = $raw: $_FMS_WHY"
      return 1
    fi
    _FMS_EV=$_FMS_V _FMS_EN=$_FMS_NUM _FMS_ESRC="env $name"
    return 0
  fi
  if [ -n "${_FMS_FL[i]}" ]; then
    fm_settings_scope_path_to path "${_FMS_SCOPE[i]}"
    _FMS_EV=${_FMS_FV[i]} _FMS_EN=${_FMS_FN[i]} _FMS_ESRC="$path:${_FMS_FL[i]}"
    return 0
  fi
  _FMS_EV=${_FMS_DEF[i]} _FMS_EN=${_FMS_DEFN[i]} _FMS_ESRC=default
}

_fms_scope_error_to() {  # <output-variable> <scope>: load it; its error, or ''
  if fm_settings_file_load "$2"; then
    printf -v "$1" '%s' ''
  elif [ "$_FMS_TABLE_STATE" = bad ]; then
    printf -v "$1" '%s' "$_FMS_TABLE_ERR"
  elif [ "$2" = machine ]; then
    printf -v "$1" '%s' "$_FMS_ERR_machine"
  else
    printf -v "$1" '%s' "$_FMS_ERR_home"
  fi
}

# fm_settings_rule_check <rule> <use-env>: rule number <rule> holds. Sets
# _FMS_WHY and returns 1 when it is broken, 2 when a scope file it needs is
# unreadable or a value is bad.
fm_settings_rule_check() {
  local r=$1 a=${_FMS_RA[$1]} b=${_FMS_RB[$1]} av an as err
  _fms_scope_error_to err "${_FMS_SCOPE[a]}"
  [ -n "$err" ] || _fms_scope_error_to err "${_FMS_SCOPE[b]}"
  [ -z "$err" ] || { _FMS_WHY="rule ${_FMS_KEY[a]} ${_FMS_ROP[r]} ${_FMS_KEY[b]} cannot be checked: $err"; return 2; }
  _fms_effective "$a" "$2" || return 2
  av=$_FMS_EV an=$_FMS_EN as=$_FMS_ESRC
  _fms_effective "$b" "$2" || return 2
  _fms_rule_holds "$an" "${_FMS_ROP[r]}" "$_FMS_EN" && return 0
  _FMS_WHY="rule ${_FMS_KEY[a]} ${_FMS_ROP[r]} ${_FMS_KEY[b]} is broken: ${_FMS_KEY[a]} = $av ($as), ${_FMS_KEY[b]} = $_FMS_EV ($_FMS_ESRC)"
  return 1
}

# fm_settings_rules_check <index> <use-env>: every rule naming the key holds.
# Sets _FMS_WHY and returns 1 on the first broken or unreadable rule.
fm_settings_rules_check() {
  local r=0
  while [ "$r" -lt "$_FMS_RN" ]; do
    if [ "${_FMS_RA[r]}" = "$1" ] || [ "${_FMS_RB[r]}" = "$1" ]; then
      fm_settings_rule_check "$r" "$2" || return 1
    fi
    r=$((r + 1))
  done
}

# fm_setting_to <output-variable> <key>: see the header.
# shellcheck disable=SC2034 # FM_SETTING_SOURCE and FM_SETTING_ERROR are for callers.
fm_setting_to() {
  local _fmsto_i _fmsto_err=''
  FM_SETTING_SOURCE='' FM_SETTING_ERROR=''
  if ! fm_settings_table_load; then
    FM_SETTING_ERROR=$_FMS_TABLE_ERR
    printf -v "$1" '%s' ''
    return 2
  fi
  if ! _fms_index_to _fmsto_i "$2"; then
    FM_SETTING_ERROR="unknown settings key '$2'"
    printf -v "$1" '%s' ''
    return 2
  fi
  _fms_scope_error_to _fmsto_err "${_FMS_SCOPE[_fmsto_i]}"
  if [ -z "$_fmsto_err" ]; then
    if ! _fms_effective "$_fmsto_i" 1; then
      _fmsto_err=$_FMS_WHY
    elif ! fm_settings_rules_check "$_fmsto_i" 1; then
      _fmsto_err=$_FMS_WHY
    else
      _fms_effective "$_fmsto_i" 1
    fi
  fi
  if [ -z "$_fmsto_err" ]; then
    printf -v "$1" '%s' "$_FMS_EV"
    FM_SETTING_SOURCE=$_FMS_ESRC
    _FMS_GOOD[_fmsto_i]=$_FMS_EV
    _fms_report ''
    return 0
  fi
  FM_SETTING_ERROR=$_fmsto_err
  _fms_report "$2: $_fmsto_err"
  if [ "${_FMS_ONBAD[_fmsto_i]}" = last-good ]; then
    if [ -n "${_FMS_GOOD[_fmsto_i]}" ]; then
      printf -v "$1" '%s' "${_FMS_GOOD[_fmsto_i]}"
      FM_SETTING_SOURCE=last-good
    else
      printf -v "$1" '%s' "${_FMS_DEF[_fmsto_i]}"
      FM_SETTING_SOURCE=default
    fi
    return 3
  fi
  printf -v "$1" '%s' ''
  return 1
}

# _fms_report <error-or-empty>: print a new error once and hand the alarm to
# bin/fm-settings.sh check; on recovery from a reported error, run check once
# so it clears the alarm. FM_SETTINGS_NO_ALARM=1 (set by bin/fm-settings.sh
# itself) skips the check, which owns the alarm there.
_fms_report() {
  [ "$1" != "$_FMS_REPORTED" ] || return 0
  [ -z "$1" ] || printf 'fm-settings: failed reading of %s; bin/fm-settings.sh check names the fix\n' "$1" >&2
  _FMS_REPORTED=$1
  [ "${FM_SETTINGS_NO_ALARM:-0}" != 1 ] || return 0
  FM_SETTINGS_NO_ALARM=1 "$FM_SETTINGS_LIB_DIR/fm-settings.sh" check >/dev/null 2>&1 || true
}
