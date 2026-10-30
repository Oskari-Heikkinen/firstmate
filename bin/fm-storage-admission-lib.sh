#!/usr/bin/env bash
# fm-storage-admission-lib.sh - shared admission owner pieces for
# bin/fm-disk-room.sh: the site policy, token admission records, tokens and
# the strict C: terms port. Sourced by fm-disk-room.sh only when the site
# policy file exists or a token verb runs, so a copy without a policy never
# loads it and keeps its interface v1/v2 results byte for byte.
# fm-disk-room.sh's header owns the commands, records and exit codes.
#
# Site policy (one file, read on every run):
#   fm-storage-admission-policy/v1     line 1, exactly
#   admission=on|off                   token admissions (reserve-token)
#   c-terms=strict|off                 strict C: terms for every admission
#   c-terms-command=/ABS/PATH          the measurer, required with strict
#   c-terms-arg=VALUE                  zero or more measurer arguments, in order
#   c-terms-bounded=refuse|accept      bounded readings (default refuse)
# Lines starting with # are comments. An unknown, repeated or malformed line,
# a carriage return, or a missing admission= or c-terms= line makes the whole
# file a failed reading; it never falls back to the default.

# shellcheck disable=SC2034 # Every POL_*, ADM_*, R_* and CT_* result is read by fm-disk-room.sh.
ADM_POLICY_FORMAT=fm-storage-admission-policy/v1
ADM_RECORD_FORMAT=fm-storage-admission/v1
# Byte ceiling: 18 digits, so sums of two records never wrap bash arithmetic.
ADM_MAX=999999999999999999
ADM_JSON_MAX=9007199254740991
ADM_CTERMS_TIMEOUT=60

# adm_policy_load FILE: sets POL_ADMISSION, POL_CTERMS, POL_CMD, POL_ARGS and
# POL_BOUNDED; returns 1 with POL_ERR when FILE is not a valid policy.
adm_policy_load() {
  local f=$1 line key val n=0 seen=' '
  POL_ADMISSION='' POL_CTERMS='' POL_CMD='' POL_BOUNDED=refuse POL_ERR=''
  POL_ARGS=()
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then POL_ERR="policy $f is not a readable file"; return 1; fi
  { while IFS= read -r line; do
      n=$((n + 1))
      case "$line" in *$'\r'*) POL_ERR="policy $f line $n has a carriage return"; return 1 ;; esac
      if [ "$n" -eq 1 ]; then
        [ "$line" = "$ADM_POLICY_FORMAT" ] || { POL_ERR="policy $f line 1 is not $ADM_POLICY_FORMAT"; return 1; }
        continue
      fi
      case "$line" in
        '#'*) continue ;;
        ?*=*) ;;
        *) POL_ERR="policy $f line $n is not KEY=VALUE"; return 1 ;;
      esac
      key=${line%%=*} val=${line#*=}
      if [ "$key" = c-terms-arg ]; then POL_ARGS+=("$val"); continue; fi
      case "$seen" in *" $key "*) POL_ERR="policy $f repeats $key"; return 1 ;; esac
      seen="$seen$key "
      case "$key=$val" in
        admission=on|admission=off) POL_ADMISSION=$val ;;
        c-terms=strict|c-terms=off) POL_CTERMS=$val ;;
        c-terms-bounded=refuse|c-terms-bounded=accept) POL_BOUNDED=$val ;;
        c-terms-command=/*) POL_CMD=$val ;;
        admission=*|c-terms=*|c-terms-bounded=*|c-terms-command=*) POL_ERR="policy $f has a bad $key value"; return 1 ;;
        *) POL_ERR="policy $f has unknown key $key"; return 1 ;;
      esac
    done
    [ -z "$line" ] || { POL_ERR="policy $f does not end with a newline"; return 1; }
  } <"$f" 2>/dev/null
  [ "$n" -ge 1 ] || { POL_ERR="policy $f is empty"; return 1; }
  [ -n "$POL_ADMISSION" ] && [ -n "$POL_CTERMS" ] || { POL_ERR="policy $f needs admission= and c-terms="; return 1; }
  if [ "$POL_CTERMS" = strict ] && [ -z "$POL_CMD" ]; then POL_ERR="policy $f needs c-terms-command= with c-terms=strict"; return 1; fi
  return 0
}

# Validators -------------------------------------------------------------------

# adm_id VALUE: a task or reservation name, [A-Za-z0-9][A-Za-z0-9._-]{0,127}.
adm_id() {
  case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

# adm_class VALUE: [a-z0-9-]{1,40}.
adm_class() {
  case "$1" in ''|*[!a-z0-9-]*) return 1 ;; esac
  [ "${#1}" -le 40 ]
}

# adm_token VALUE: exactly 64 lowercase hex characters.
adm_token() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

# adm_uint VALUE: a canonical nonnegative integer of at most 18 digits.
adm_uint() {
  case "$1" in ''|*[!0-9]*|0?*) return 1 ;; esac
  [ "${#1}" -le 18 ]
}

# adm_bytes VALUE -> ADM_N: a nonnegative base-10 integer, leading zeros
# allowed, at most ADM_MAX; no sign, fraction, exponent or unit.
adm_bytes() {
  local v=$1
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v=${v#0}; done
  [ "${#v}" -le 18 ] || return 1
  ADM_N=$v
}

# adm_add A B -> ADM_SUM_OUT: A + B saturated at ADM_MAX (both <= ADM_MAX).
adm_add() {
  ADM_SUM_OUT=$(( $1 + $2 ))
  [ "$ADM_SUM_OUT" -le "$ADM_MAX" ] || ADM_SUM_OUT=$ADM_MAX
}

# adm_start_of PID -> ADM_START, the process start time in clock ticks read
# in the shell (the same field proc_start reads); 1 when PID is not running.
adm_start_of() {
  local stat rest fld
  ADM_START=''
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  { IFS= read -r stat <"/proc/$1/stat"; } 2>/dev/null || return 1
  rest=${stat##*) }
  read -r -a fld <<<"$rest"
  ADM_START=${fld[19]:-}
  case "$ADM_START" in ''|*[!0-9]*) ADM_START=''; return 1 ;; esac
}

# adm_boot -> ADM_BOOT from FM_DISK_ROOM_BOOT_ID; 1 when unreadable.
adm_boot() {
  local f=${FM_DISK_ROOM_BOOT_ID:-/proc/sys/kernel/random/boot_id} b=''
  ADM_BOOT=''
  { IFS= read -r b <"$f"; } 2>/dev/null || [ -n "$b" ] || return 1
  case "$b" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
  [ "${#b}" -le 64 ] || return 1
  ADM_BOOT=$b
}

# adm_new_token -> ADM_TOKEN, 32 random bytes as 64 lowercase hex.
adm_new_token() {
  ADM_TOKEN=$(od -v -An -N32 -tx1 "${FM_DISK_ROOM_RANDOM:-/dev/urandom}" 2>/dev/null) || return 1
  ADM_TOKEN=${ADM_TOKEN//[$' \t\n']/}
  adm_token "$ADM_TOKEN"
}

# Records ----------------------------------------------------------------------

# adm_record_read FILE: strict parse of one reservation record. Sets R_KIND
# (v2, pid or ttl) and R_BYTES, R_PID, R_START, R_EXPIRES, R_TOKEN, R_TASK,
# R_CLASS, R_VOLUME (legacy records: legacy), R_NAME, R_BOOT, R_ADMITTED.
# Returns 1 for an unreadable or malformed record.
adm_record_read() {
  local f=$1 line n=0 l=()
  R_KIND='' R_BYTES='' R_PID='' R_START='' R_EXPIRES='' R_TOKEN='' R_TASK=''
  R_CLASS='' R_VOLUME=legacy R_NAME='' R_BOOT='' R_ADMITTED=''
  { while IFS= read -r line; do
      n=$((n + 1)); [ "$n" -le 11 ] || return 1
      l+=("$line")
    done
    [ -z "$line" ] || return 1
  } <"$f" 2>/dev/null || return 1
  [ "$n" -ge 2 ] || return 1
  [ "${l[0]#bytes=}" != "${l[0]}" ] || return 1
  R_BYTES=${l[0]#bytes=}
  adm_uint "$R_BYTES" || return 1
  if [ "$n" -eq 2 ]; then
    [ "${l[1]#expires=}" != "${l[1]}" ] || return 1
    R_EXPIRES=${l[1]#expires=}; R_KIND=ttl
    adm_uint "$R_EXPIRES"
    return
  fi
  [ "${l[1]#pid=}" != "${l[1]}" ] && [ "${l[2]#start=}" != "${l[2]}" ] || return 1
  R_PID=${l[1]#pid=} R_START=${l[2]#start=}
  adm_uint "$R_PID" || return 1
  if [ "$n" -eq 3 ]; then
    R_KIND=pid
    [ -z "$R_START" ] || adm_uint "$R_START"
    return
  fi
  [ "$n" -eq 11 ] && adm_uint "$R_START" || return 1
  [ "${l[3]}" = "format=$ADM_RECORD_FORMAT" ] || return 1
  [ "${l[4]#token=}" != "${l[4]}" ] && [ "${l[5]#task=}" != "${l[5]}" ] && [ "${l[6]#class=}" != "${l[6]}" ] &&
    [ "${l[7]#volume=}" != "${l[7]}" ] && [ "${l[8]#name=}" != "${l[8]}" ] && [ "${l[9]#boot=}" != "${l[9]}" ] &&
    [ "${l[10]#admitted=}" != "${l[10]}" ] || return 1
  R_TOKEN=${l[4]#token=} R_TASK=${l[5]#task=} R_CLASS=${l[6]#class=} R_VOLUME=${l[7]#volume=}
  R_NAME=${l[8]#name=} R_BOOT=${l[9]#boot=} R_ADMITTED=${l[10]#admitted=}
  adm_token "$R_TOKEN" && adm_id "$R_TASK" && adm_class "$R_CLASS" && adm_id "$R_NAME" && adm_uint "$R_ADMITTED" || return 1
  case "$R_VOLUME" in linux|host-c|d) ;; *) return 1 ;; esac
  case "$R_BOOT" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
  R_KIND=v2
}

# adm_collect DIR EXCLUDE POOL [keep]: strict read of every record in DIR
# (POOL c: the Linux and C: pool, which holds linux, host-c and legacy records;
# POOL d: a D: pool, which holds d and legacy D records). Prunes lapsed records
# (with keep, a read-only caller, it skips them and deletes nothing) and sets
# ADM_SUM (charged to Linux and C:, or to the D: pool), ADM_HOSTC (C:
# only), ADM_LIST (for people) and ADM_KEYS (" volume:task:name " of live
# token records). Returns 1 with ADM_ERR when a record cannot be trusted.
adm_collect() {
  local dir=$1 exclude=$2 pool=$3 keep=${4:-} f name t=''
  ADM_SUM=0 ADM_HOSTC=0 ADM_LIST='' ADM_KEYS=' ' ADM_ERR=''
  if [ ! -d "$dir" ]; then
    if [ -e "$dir" ] || [ -L "$dir" ]; then ADM_ERR="reservation pool $dir is not a directory"; return 1; fi
    return 0
  fi
  [ -r "$dir" ] && [ -x "$dir" ] || { ADM_ERR="cannot read reservation pool $dir"; return 1; }
  for f in "$dir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}
    if [ -L "$f" ] || [ ! -f "$f" ]; then ADM_ERR="reservation $f is not a regular file"; return 1; fi
    adm_record_read "$f" || { ADM_ERR="unreadable or malformed reservation $f"; return 1; }
    case "$R_KIND:$pool:$R_VOLUME" in
      v2:c:linux|v2:c:host-c|v2:d:d)
        [ "$name" = "token@$R_TOKEN" ] || { ADM_ERR="reservation $f does not match its token"; return 1; }
        [ -n "${ADM_BOOT:-}" ] || adm_boot || { ADM_ERR="cannot read the boot id"; return 1; }
        if [ "$R_BOOT" != "$ADM_BOOT" ] || ! adm_start_of "$R_PID" || [ "$ADM_START" != "$R_START" ]; then
          [ -n "$keep" ] || rm -f -- "$f"; continue
        fi
        ADM_KEYS="$ADM_KEYS$R_VOLUME:$R_TASK:$R_NAME " ;;
      v2:*) ADM_ERR="reservation $f is in the wrong pool"; return 1 ;;
      pid:*:*) pid_alive "$R_PID" "$R_START" || { [ -n "$keep" ] || rm -f -- "$f"; continue; } ;;
      ttl:*:*)
        [ -n "$t" ] || t=$(now)
        [ "$t" -lt "$R_EXPIRES" ] || { [ -n "$keep" ] || rm -f -- "$f"; continue; } ;;
    esac
    [ "$name" = "$exclude" ] && continue
    if [ "$R_VOLUME" = host-c ]; then
      adm_add "$ADM_HOSTC" "$R_BYTES"; ADM_HOSTC=$ADM_SUM_OUT
    else
      adm_add "$ADM_SUM" "$R_BYTES"; ADM_SUM=$ADM_SUM_OUT
    fi
    if [ "$R_KIND" = v2 ]; then name="$R_TASK/$R_NAME"; [ "$R_VOLUME" != host-c ] || name="$name C: only"; fi
    ADM_LIST="$ADM_LIST${ADM_LIST:+, }$name $(gib "$R_BYTES") GiB"
  done
  return 0
}

# adm_write_record DIR -> 0, or 1 with ADM_ERR. Writes token@ADM_TOKEN from
# the R_* values, never replacing an existing record.
adm_write_record() {
  local dir=$1 tmp
  mkdir -p -- "$dir" 2>/dev/null && [ -d "$dir" ] || { ADM_ERR="cannot create reservation pool $dir"; return 1; }
  tmp=$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null) || { ADM_ERR="cannot write in reservation pool $dir"; return 1; }
  if ! { printf 'bytes=%s\npid=%s\nstart=%s\nformat=%s\ntoken=%s\ntask=%s\nclass=%s\nvolume=%s\nname=%s\nboot=%s\nadmitted=%s\n' \
      "$R_BYTES" "$R_PID" "$R_START" "$ADM_RECORD_FORMAT" "$ADM_TOKEN" "$R_TASK" "$R_CLASS" "$R_VOLUME" "$R_NAME" "$R_BOOT" "$R_ADMITTED" \
      >"$tmp"; } 2>/dev/null; then
    rm -f -- "$tmp"; ADM_ERR="cannot write reservation in $dir"; return 1
  fi
  if ! ln -- "$tmp" "$dir/token@$ADM_TOKEN" 2>/dev/null; then
    rm -f -- "$tmp"; ADM_ERR="cannot publish reservation token@$ADM_TOKEN in $dir"; return 1
  fi
  rm -f -- "$tmp"
}

# C: terms port --------------------------------------------------------------

# The measurer prints one fm-storage-c-terms/v1 object on stdout
# (bin/fm-storage-c-terms.py's header owns it): exactly schema, sampled_at,
# free, c_terms and reasons. c_terms is plan section 3's object, exactly
# ext4_vhdx, swap_vhdx, vss and pagefile, each with the common keys state,
# source, sampled_at, reason, reserved_bytes and its own fields. The output is
# "ok", one line per term, the first reason as "VOLUME:TERM<tab>DETAIL", and
# the c_terms object, or "bad".
# shellcheck disable=SC2016
ADM_CTERMS_JQ='
def n: type == "number" and . == floor and . >= 0 and . <= '"$ADM_JSON_MAX"';
def nn: . == null or n;
def sn: . == null or type == "string";
def fields: {ext4_vhdx: ["path", "file_bytes", "linux_free_bytes", "linux_pending_bytes", "growth_reserved_bytes"],
  swap_vhdx: ["path", "configured_bytes", "file_bytes", "hosting_volume"],
  vss: ["cap_bytes", "allocated_bytes", "used_bytes", "cap_proven"],
  pagefile: ["mode", "allocation_bytes", "maximum_bytes", "operator_growth_reservation_bytes", "policy_id", "hosting_volumes"]};
def common: ["state", "source", "sampled_at", "reason", "reserved_bytes"];
def value_ok($k): if ($k | endswith("_bytes")) then nn
  elif $k == "cap_proven" then (. == null or type == "boolean")
  elif $k == "hosting_volumes" then (. == null or (type == "array" and all(.[]; type == "string")))
  elif $k == "sampled_at" then (. == null or n or type == "string")
  else sn end;
def term_ok($t): type == "object" and (keys == ((common + fields[$t]) | sort))
  and all(to_entries[]; .key as $k | .value | value_ok($k))
  and (.state | IN("measured", "bounded", "not-applicable", "unknown"))
  and (if .state == "unknown" then .reserved_bytes == null
       elif .state == "not-applicable" then (.reserved_bytes == null or .reserved_bytes == 0)
       else (.reserved_bytes | n) end);
def reason_ok: type == "object" and (keys == ["code", "detail", "term", "volume"])
  and (.code | type == "string") and (.volume | type == "string") and (.term | sn) and (.detail | sn);
. as $o
| if type == "object" and (keys == ["c_terms", "free", "reasons", "sampled_at", "schema"])
     and .schema == "fm-storage-c-terms/v1" and (.sampled_at | n) and (.free | type == "object")
     and (.reasons | type == "array" and all(.[]; reason_ok))
     and (.c_terms as $c | $c | type == "object" and (keys == (fields | keys))
          and all(fields | keys[]; . as $t | $c[$t] | term_ok($t)))
  then .c_terms as $c
  | "ok", (["ext4_vhdx", "swap_vhdx", "vss", "pagefile"][] as $t
       | [$t, $c[$t].state, ($c[$t].reserved_bytes // 0 | tostring), ($c[$t].cap_proven // false | tostring),
          ($c[$t].reason // "" | tostring | .[0:200])] | @tsv),
    ($o.reasons[0] // null | if . == null then "\t"
       else [.volume + ":" + (.term // (.volume + "-free")), (.detail // "" | .[0:200])] | @tsv end),
    ($c | tojson)
  else "bad" end
'

# adm_cterms: measures the strict C: terms once per process. Sets CT_STATE
# (ok or failed), CT_TERM and CT_WHY (the first unusable VOLUME:TERM and why),
# CT_SWAP, CT_VSS, CT_PAGEFILE (reserved bytes), CT_EXT4 (its state), CT_VSS_*
# and CT_JSON (the measurer's object). Returns 1 when any mandatory term is
# unusable.
adm_cterms() {
  local out rc t state res proven why
  if [ -n "${CT_STATE:-}" ]; then [ "$CT_STATE" = ok ]; return; fi
  CT_STATE=failed CT_TERM=host-c:c-terms CT_WHY='' CT_SWAP=0 CT_VSS=0 CT_PAGEFILE=0 CT_EXT4='' CT_JSON=null
  command -v jq >/dev/null 2>&1 || { CT_WHY="jq is not installed"; return 1; }
  out=$(timeout "$ADM_CTERMS_TIMEOUT" "$POL_CMD" ${POL_ARGS[@]+"${POL_ARGS[@]}"} </dev/null 2>/dev/null); rc=$?
  case "$rc" in
    0|75) ;;
    124) CT_WHY="measurer timed out after ${ADM_CTERMS_TIMEOUT}s"; return 1 ;;
    *) CT_WHY="measurer exited $rc"; return 1 ;;
  esac
  out=$(printf '%s\n' "$out" | jq -r "$ADM_CTERMS_JQ" 2>/dev/null) || out=bad
  case "$out" in
    ok$'\n'*) ;;
    *) CT_WHY="measurer output is not the strict c_terms object"
      [ "$rc" = 0 ] || CT_WHY="measurer exited $rc"
      return 1 ;;
  esac
  CT_JSON=${out##*$'\n'}
  # Exit 75 is the measurer's wait, and any reason is an unknown reading: the
  # first reason names it.
  IFS=$'\t' read -r t why <<<"$(printf '%s\n' "$out" | sed -n '6p')"
  if [ -n "$t" ]; then
    CT_TERM=${t//[^[:print:]]/?} CT_WHY=${why//[^[:print:]]/?}
    CT_WHY=${CT_WHY:-unknown}
    return 1
  fi
  [ "$rc" = 0 ] || { CT_WHY="measurer exited $rc without a reason"; return 1; }
  while IFS=$'\t' read -r t state res proven why; do
    why=${why//[^[:print:]]/?}
    case "$state" in
      measured|not-applicable) ;;
      bounded)
        if [ "$POL_BOUNDED" != accept ]; then CT_TERM=host-c:$t CT_WHY="bounded reading not accepted by site policy"; return 1; fi
        if [ "$t" = vss ] && [ "$proven" != true ]; then CT_TERM=host-c:$t CT_WHY="bounded cap not proven"; return 1; fi ;;
      *) CT_TERM=host-c:$t CT_WHY=${why:-unknown}; return 1 ;;
    esac
    case "$t" in
      ext4_vhdx) CT_EXT4=$state ;;
      swap_vhdx) CT_SWAP=$res ;;
      vss) CT_VSS=$res ;;
      pagefile) CT_PAGEFILE=$res ;;
    esac
  done <<<"$(printf '%s\n' "$out" | sed -n '2,5p')"
  CT_STATE=ok CT_TERM='' CT_WHY=''
}

ADM_LIB_LOADED=1
