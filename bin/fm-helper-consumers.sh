#!/usr/bin/env bash
# fm-helper-consumers.sh - declared consumers of Firstmate helpers that another
# home runs under a pin, and the deploy-after-acceptance gate that keeps a new
# helper version off their path until each of them accepts it.
#
# docs/helper-consumers.md owns the rule, the declaration format, and what each
# consumer must do; this header owns the exact commands.
#
# Usage:
#   fm-helper-consumers.sh list
#   fm-helper-consumers.sh check-advance [--allow-break <consumer>]... <checkout> <target-rev>
#   fm-helper-consumers.sh pending [--repo <dir>] [--fetch] [--if-repo <host>/<path>] [<rev> | <from>..<to>]
#   fm-helper-consumers.sh log <outcome> <home> <target-commit> <helper> <sha256> <consumers> [<note>]
#   fm-helper-consumers.sh holds [--home <home>] [--open | --windows]
#   fm-helper-consumers.sh alarm [--repo <dir>] [--arm | --disarm]
#
# Declarations are read from FM_HELPER_CONSUMERS, default
# ${XDG_CONFIG_HOME:-$HOME/.config}/firstmate/helper-consumers.d, one
# <consumer-id>.conf file per consumer, in the format docs/helper-consumers.md
# owns. Firstmate only reads them. A malformed file is reported by name,
# accepts nothing, and holds check-advance as described below.
#
# list prints each declaration's helpers with the live sha256 of the bytes at
# that path and the consumer's state: `accepts`, `waiting` (it accepts some
# version but not the live one), or `missing` (no file at that path). It exits 1
# when any declaration is malformed, else 0, including when none exist.
#
# check-advance compares, for every declared helper inside <checkout>, its bytes
# at the checkout's HEAD (current) with its bytes at <target-rev> (target). A
# helper whose bytes do not change is ignored. For each declaring consumer:
#   - it accepts the target, or is named by --allow-break: advance;
#   - it accepts the current version but not the target: hold;
#   - it accepts neither: it is already waiting, so holding cannot help; advance.
# Output is one tab-separated record per outcome, aggregated per helper:
#   hold<TAB><helper><TAB><target-sha256><TAB><consumer>[,<consumer>...]
#   break<TAB><helper><TAB><target-sha256><TAB><consumer>[,...]
#   waiting<TAB><helper><TAB><target-sha256><TAB><consumer>[,...]
#   malformed<TAB><file><TAB><reason>
#   unproven<TAB><helper><TAB><target-sha256><TAB><file-stem>[,...]
# A malformed or unreadable declaration cannot prove what its consumer accepts,
# so while one exists every change to a helper that any declaration names - its
# own helper= lines included when they can still be read - holds as `unproven`,
# unless --allow-break names that declaration's file stem.
# A missing file hashes as `absent`. Exit 0 to advance, 3 to hold, 2 on a usage
# error or an unreadable checkout or revision. With no declarations it prints
# nothing and exits 0 before reading the checkout, so a home without
# declarations behaves exactly as before. bin/fm-ff-lib.sh's ff_target runs this
# before every byte-changing step and treats any status but 0 as a hold.
#
# pending records each declared helper version at <rev> (default: the origin
# default branch) that some declaring consumer does not accept yet, once per
# version, under FM_HELPER_VERSIONS, default
# ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/helper-versions:
#   <helper basename>/<sha256>/pending.json   the record (schema fm-helper-version/v1)
#   <helper basename>/<sha256>/<basename>     read-only copy of those exact bytes,
#                                             the review artefact; consumers never run it
#   <helper basename>/<sha256>/note-filed     written once the note below is filed
# and files one fm-inbox.sh note per version to the root home of FM_HOME
# (request id helper-pending-<basename>-<sha12>, so a retry never duplicates it).
# A declared helper counts when its checkout is the same project as --repo
# (default: this script's own checkout): the same git common directory or the
# same origin URL. With <from>..<to>, only helpers whose bytes differ between
# the two revisions are considered. --if-repo exits quietly unless --repo's
# origin is that forge host and path (fm-pr-merge.sh passes the merged PR's);
# --fetch fetches --repo's origin first and continues on a failed fetch. Every
# failure after the declarations are read is reported and exits 0, because the
# landing that called it has already happened; a usage error exits 2.
#
# log appends one line to the hold log, FM_HELPER_VERSIONS/holds.log, and is
# its only writer; bin/fm-update.sh and the landing gate call it. This
# interface is stable: outcomes and trailing fields may be added, nothing is
# renamed, removed or reordered, and readers ignore fields they do not know.
# Each line is one tab-separated record, written by a single append:
#   <utc time> <outcome> <home> <target-commit> <helper> <sha256> <consumers> <note>
# <outcome> is one of:
#   held     a pass of <home> held at <target-commit> because <consumers> have
#            not accepted <helper> version <sha256>;
#   cleared  a later pass of <home> advanced past that held version;
#   bypass   a held pass on a version that reached the default branch around
#            a landing check that should have refused it (written once landings
#            are gated); it opens and clears like held;
#   break    an operator-run --allow-helper-break moved past <consumers>'
#            acceptance of <helper> version <sha256>; a record only, it opens
#            and clears nothing.
# <home> is an absolute path (canonicalized when it exists), <target-commit> a
# full commit id, <helper> the helper path as check-advance prints it, <sha256>
# a lowercase sha256 or `absent`, and <consumers> a comma list of consumer ids;
# `-` stands for an unknown value in those last four. <note> is plain language;
# its tabs and newlines become spaces. FM_HELPER_CONSUMERS_NOW (epoch seconds)
# overrides the clock. Exit 0 written, 1 not written (reason on stderr), 2 usage
# error.
#
# holds reads the hold log. With no option it prints its lines, only <home>'s
# with --home. --open prints each hold not yet cleared, per home, helper and
# version:
#   <home> <helper> <sha256> <consumers> <first held at>
# --windows prints one line per hold window of a home, from the first held or
# bypass line while none of its holds was open to the cleared line that closed
# the last one, or `open` (hours then run to now):
#   <home> <start> <end|open> <hours> <held passes> <helper@sha12>[,...] <breaks> <closing note>
# A line it does not understand is named on stderr and skipped. A missing log
# prints nothing; an unreadable one exits 1.
#
# alarm is the unaccepted-version alarm, run as the custom watcher check
# helper-unaccepted. A pass raises one level helper-unaccepted-<helper>-<sha12>
# while a recorded pending version that --repo's origin default branch carries
# (origin/HEAD, else origin/main or origin/master, as last fetched; default
# --repo is this checkout) stays unaccepted by a declaring consumer for longer
# than the limit in ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/helper-unaccepted-max,
# counted from the commit that brought those bytes to the branch. The file holds
# one whole number of seconds, optionally suffixed m or h (2h when the file is
# absent). The level clears when every declaring consumer accepts the version or
# the branch carries other bytes. An unreadable or malformed record, declaration
# or limit file, or an unreadable branch, is a failed reading that raises its
# own level naming it (the limit then counts as 2h). Levels live in alert stores
# under ${FM_STATE_OVERRIDE:-$FM_HOME/state}/helper-unaccepted/stores/, store id
# helper-unaccepted.<home id>, one per target: main (the root home of FM_HOME)
# holds every level, and the local home of each declaration owner listed in the
# root's data/secondmates.md holds its own, both bound to that home's
# state/helper-unaccepted.status; an owner this machine cannot reach is named in
# main's level instead. A pass prints a line only when a level cannot be
# delivered, once per occurrence, and with no declarations prints and writes
# nothing (it still clears levels an earlier pass raised). Per pass it stats each
# pending record and re-reads only those changed since the last pass. --arm
# installs the check through bin/fm-check-register.sh and runs a first pass;
# --disarm unregisters its stores, closing their blockers, and the check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DECL_DIR="${FM_HELPER_CONSUMERS:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/firstmate/helper-consumers.d}"
VERSIONS_DIR="${FM_HELPER_VERSIONS:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/firstmate/helper-versions}"
TAB=$(printf '\t')

usage() {
  awk 'NR > 1 && /^set -u$/ { exit } NR > 1' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-helper-consumers: %s\n' "$*" >&2; exit 2; }

sha256_stdin() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

# sha256 of <rel> at <rev> in <repo>, or `absent` when the revision has no such file.
blob_sha() {  # <repo> <rev> <rel>
  if ! git -C "$1" cat-file -e "$2:$3" 2>/dev/null; then
    printf 'absent\n'
    return 0
  fi
  git -C "$1" cat-file blob "$2:$3" | sha256_stdin
}

file_sha() {  # <path>
  [ -f "$1" ] || { printf 'absent\n'; return 0; }
  sha256_stdin < "$1"
}

# Canonical absolute path of an existing file's directory joined with its name.
canonical_file() {  # <path>
  local dir
  dir=$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename -- "$1")"
}

declarations() {
  local f
  [ -d "$DECL_DIR" ] || return 0
  for f in "$DECL_DIR"/*.conf; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Parse one declaration into DECL_CONSUMER, DECL_OWNER, DECL_HELPERS (newline
# list), and DECL_ACCEPTS (space list). Returns 1 with DECL_ERROR when malformed.
parse_decl() {  # <file>
  local file=$1 stem line key value seen_schema=0 n=0
  DECL_CONSUMER="" DECL_OWNER="" DECL_HELPERS="" DECL_ACCEPTS="" DECL_ERROR=""
  stem=$(basename -- "$file" .conf)
  case "$stem" in
    ''|.*|*[!A-Za-z0-9._-]*) DECL_ERROR="file name is not a consumer id"; return 1 ;;
  esac
  [ -r "$file" ] || { DECL_ERROR="unreadable"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) DECL_ERROR="line $n is not key=value"; return 1 ;;
    esac
    if [ "$seen_schema" = 0 ] && [ "$key" != schema ]; then
      DECL_ERROR="schema= must come first"
      return 1
    fi
    case "$key" in
      schema)
        [ "$seen_schema" = 0 ] || { DECL_ERROR="schema= repeated"; return 1; }
        [ "$value" = fm-helper-consumer/v1 ] || { DECL_ERROR="unsupported schema '$value'"; return 1; }
        seen_schema=1
        ;;
      consumer)
        [ -z "$DECL_CONSUMER" ] || { DECL_ERROR="consumer= repeated"; return 1; }
        [ "$value" = "$stem" ] || { DECL_ERROR="consumer= '$value' does not match the file name"; return 1; }
        DECL_CONSUMER=$value
        ;;
      owner)
        [ -z "$DECL_OWNER" ] || { DECL_ERROR="owner= repeated"; return 1; }
        case "$value" in ''|*[[:space:]]*) DECL_ERROR="owner= must be one word"; return 1 ;; esac
        DECL_OWNER=$value
        ;;
      helper)
        case "$value" in
          /*) ;;
          *) DECL_ERROR="helper= must be an absolute path"; return 1 ;;
        esac
        case "$value" in *"$TAB"*) DECL_ERROR="helper= contains a tab"; return 1 ;; esac
        DECL_HELPERS="$DECL_HELPERS$value"$'\n'
        ;;
      accept)
        case "$value" in
          *[!0-9a-f]*|'') DECL_ERROR="accept= must be a lowercase sha256"; return 1 ;;
        esac
        [ "${#value}" -eq 64 ] || { DECL_ERROR="accept= must be a lowercase sha256"; return 1; }
        DECL_ACCEPTS="$DECL_ACCEPTS $value"
        ;;
      *) DECL_ERROR="unknown key '$key'"; return 1 ;;
    esac
  done < "$file"
  [ "$seen_schema" = 1 ] || { DECL_ERROR="no schema="; return 1; }
  [ -n "$DECL_CONSUMER" ] || { DECL_ERROR="no consumer="; return 1; }
  [ -n "$DECL_OWNER" ] || { DECL_ERROR="no owner="; return 1; }
  [ -n "$DECL_HELPERS" ] || { DECL_ERROR="no helper="; return 1; }
  return 0
}

# The absolute helper= paths a malformed declaration still names, best effort,
# so a hold for it can cover them; nothing when the file cannot be read.
salvage_helpers() {  # <file>
  [ -r "$1" ] || return 0
  sed -n 's/\r$//; s/^helper=\(\/.*\)$/\1/p' "$1" 2>/dev/null | grep -v "$TAB" || true
}

accepts() {  # <sha>  (reads DECL_ACCEPTS)
  case " $DECL_ACCEPTS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Merge records `<kind>\t<helper>\t<sha>\t<consumer>` into one line per
# kind, helper, and sha with a comma-separated consumer list, first-seen order.
aggregate() {
  awk -F '\t' 'BEGIN { OFS = "\t" }
    { k = $1 FS $2 FS $3
      if (!(k in who)) { order[++n] = k; who[k] = $4 } else { who[k] = who[k] "," $4 } }
    END { for (i = 1; i <= n; i++) print order[i], who[order[i]] }'
}

# ---------------------------------------------------------------- list

cmd_list() {
  local file helper live state rc=0 any=0
  [ $# -eq 0 ] || die "list takes no arguments"
  while IFS= read -r file; do
    any=1
    if ! parse_decl "$file"; then
      printf 'malformed: %s: %s (accepts nothing)\n' "$file" "$DECL_ERROR"
      rc=1
      continue
    fi
    printf 'consumer %s owner %s (%s)\n' "$DECL_CONSUMER" "$DECL_OWNER" "$file"
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      live=$(file_sha "$helper") || live=unreadable
      if [ "$live" = absent ]; then
        state=missing
      elif accepts "$live"; then
        state=accepts
      else
        state=waiting
      fi
      printf '  %s live %s %s\n' "$helper" "$(printf '%s' "$live" | cut -c1-12)" "$state"
    done <<< "$DECL_HELPERS"
  done < <(declarations)
  [ "$any" = 1 ] || printf 'no helper consumer declarations in %s\n' "$DECL_DIR"
  return "$rc"
}

# ---------------------------------------------------------------- check-advance

cmd_check_advance() {
  local allow="" checkout target top file helper canon rel cur tgt records="" held=0 out
  local bad="" stem watched="" seen
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-break)
        [ -n "${2:-}" ] || die "--allow-break needs a consumer id"
        allow="$allow $2"
        shift 2
        ;;
      --) shift; break ;;
      -*) die "unknown option $1" ;;
      *) break ;;
    esac
  done
  [ $# -eq 2 ] || die "usage: check-advance [--allow-break <consumer>]... <checkout> <target-rev>"
  checkout=$1 target=$2
  [ -n "$(declarations)" ] || return 0

  top=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) || die "not a git checkout: $checkout"
  top=$(CDPATH='' cd -- "$top" && pwd -P) || die "cannot resolve $checkout"
  git -C "$top" rev-parse --verify --quiet "$target^{commit}" >/dev/null || die "unknown revision $target in $checkout"

  while IFS= read -r file; do
    if ! parse_decl "$file"; then
      records="${records}malformed$TAB$file$TAB$DECL_ERROR$TAB-"$'\n'
      stem=$(basename -- "$file" .conf)
      case " $allow " in
        *" $stem "*) ;;
        *) bad="$bad${bad:+,}$stem" ;;
      esac
      watched="$watched$(salvage_helpers "$file")"$'\n'
      continue
    fi
    watched="$watched$DECL_HELPERS"
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      canon=$(canonical_file "$helper") || continue
      case "$canon" in
        "$top"/*) rel=${canon#"$top"/} ;;
        *) continue ;;
      esac
      cur=$(blob_sha "$top" HEAD "$rel") || die "cannot hash $rel at HEAD"
      tgt=$(blob_sha "$top" "$target" "$rel") || die "cannot hash $rel at $target"
      [ "$cur" != "$tgt" ] || continue
      if accepts "$tgt"; then
        continue
      fi
      case " $allow " in
        *" $DECL_CONSUMER "*)
          records="${records}break$TAB$helper$TAB$tgt$TAB$DECL_CONSUMER"$'\n'
          continue
          ;;
      esac
      if accepts "$cur"; then
        records="${records}hold$TAB$helper$TAB$tgt$TAB$DECL_CONSUMER"$'\n'
        held=1
      else
        records="${records}waiting$TAB$helper$TAB$tgt$TAB$DECL_CONSUMER"$'\n'
      fi
    done <<< "$DECL_HELPERS"
  done < <(declarations)

  # A declaration that cannot be parsed cannot prove what its consumer accepts,
  # so while one is malformed or unreadable, every change to a helper any
  # declaration names holds, unless --allow-break names that file's stem.
  if [ -n "$bad" ]; then
    seen=$'\n'
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      canon=$(canonical_file "$helper") || continue
      case "$seen" in *$'\n'"$canon"$'\n'*) continue ;; esac
      seen="$seen$canon"$'\n'
      case "$canon" in
        "$top"/*) rel=${canon#"$top"/} ;;
        *) continue ;;
      esac
      cur=$(blob_sha "$top" HEAD "$rel") || die "cannot hash $rel at HEAD"
      tgt=$(blob_sha "$top" "$target" "$rel") || die "cannot hash $rel at $target"
      [ "$cur" != "$tgt" ] || continue
      records="${records}unproven$TAB$helper$TAB$tgt$TAB$bad"$'\n'
      held=1
    done <<< "$watched"
  fi

  out=$(printf '%s' "$records" | aggregate)
  [ -z "$out" ] || printf '%s\n' "$out" | while IFS="$TAB" read -r kind a b c; do
    if [ "$kind" = malformed ]; then
      printf 'malformed%s%s%s%s\n' "$TAB" "$a" "$TAB" "$b"
    else
      printf '%s%s%s%s%s%s%s\n' "$kind" "$TAB" "$a" "$TAB" "$b" "$TAB" "$c"
    fi
  done
  [ "$held" = 0 ] || return 3
  return 0
}

# ---------------------------------------------------------------- pending

# Lowercased host/path of a remote URL: scheme, user, port separator, and a
# trailing .git dropped, so https and scp-style spellings of one repo compare equal.
normalize_remote() {  # <url>
  local u=$1
  u=${u#*://}
  u=${u#*@}
  u=${u%/}
  u=${u%.git}
  case "$u" in
    *:*) case "${u%%/*}" in *:*) u="${u%%:*}/${u#*:}" ;; esac ;;
  esac
  printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]'
}

origin_url() {  # <repo>
  git -C "$1" config --get remote.origin.url 2>/dev/null
}

same_project() {  # <repo> <other-checkout>
  local a b
  a=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  b=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  a=$(CDPATH='' cd -- "$a" && pwd -P) || return 1
  b=$(CDPATH='' cd -- "$b" && pwd -P) || return 1
  [ "$a" = "$b" ] && return 0
  a=$(origin_url "$1") || return 1
  b=$(origin_url "$2") || return 1
  [ -n "$a" ] && [ "$(normalize_remote "$a")" = "$(normalize_remote "$b")" ]
}

# The origin default branch of <repo>: origin/HEAD, else origin/main or
# origin/master; fails when none resolves.
origin_default() {  # <repo>
  local ref
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  [ -z "$ref" ] || { printf '%s\n' "$ref"; return 0; }
  for ref in origin/main origin/master; do
    git -C "$1" rev-parse --verify --quiet "$ref^{commit}" >/dev/null && { printf '%s\n' "$ref"; return 0; }
  done
  return 1
}

# The repo-relative path of a declared <helper> when its checkout is the same
# project as <repo>; fails otherwise or when its directory cannot be read.
helper_rel() {  # <repo> <helper>
  local canon htop
  canon=$(canonical_file "$2") || return 1
  htop=$(git -C "$(dirname -- "$canon")" rev-parse --show-toplevel 2>/dev/null) || return 1
  htop=$(CDPATH='' cd -- "$htop" && pwd -P) || return 1
  case "$canon" in "$htop"/*) ;; *) return 1 ;; esac
  same_project "$1" "$htop" || return 1
  printf '%s\n' "${canon#"$htop"/}"
}

json_str() {  # <text>
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

# The newest commit at or before <rev> whose <rel> hashes to <sha>, searched
# through the file's last 100 revisions; empty when none is found.
commit_for_sha() {  # <repo> <rev> <rel> <sha>
  local c
  while IFS= read -r c; do
    [ "$(blob_sha "$1" "$c" "$3")" = "$4" ] && { printf '%s\n' "$c"; return 0; }
  done < <(git -C "$1" log --format=%H -n 100 "$2" -- "$3" 2>/dev/null)
  return 0
}

# File the one note per pending version to the root home of FM_HOME.
file_note() {  # <record-dir> <request-id> <text>
  local dir=$1 request=$2 text=$3 home root
  home=${FM_HOME:-}
  [ -n "$home" ] || { printf 'helper-pending: note not filed: FM_HOME is not set\n'; return 1; }
  # A separate shell keeps the wake library's globals out of this script.
  # shellcheck disable=SC2016 # The inner shell expands its own arguments.
  root=$(env -u FM_STATE_OVERRIDE -u STATE FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$home" \
    bash -c '. "$1/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1; fm_firstmate_root_home "$2"' \
    fm-helper-consumers "$SCRIPT_DIR" "$home") || { printf 'helper-pending: note not filed: cannot resolve the root home of %s\n' "$home"; return 1; }
  if env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$root" \
      "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$request" -- "$text" >/dev/null 2>&1; then
    : > "$dir/note-filed"
    printf 'helper-pending: note filed to %s\n' "$root"
    return 0
  fi
  printf 'helper-pending: note not filed to %s; the next pending run retries it\n' "$root"
  return 1
}

cmd_pending() {
  local repo=$FM_ROOT fetch=0 if_repo="" spec="" from="" to default url
  local file helper rel tgt from_sha lines="" line key seen=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ -n "${2:-}" ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --fetch) fetch=1; shift ;;
      --if-repo) [ -n "${2:-}" ] || die "--if-repo needs <host>/<path>"; if_repo=$2; shift 2 ;;
      --) shift; break ;;
      -*) die "unknown option $1" ;;
      *) break ;;
    esac
  done
  [ $# -le 1 ] || die "usage: pending [--repo <dir>] [--fetch] [--if-repo <host>/<path>] [<rev> | <from>..<to>]"
  spec=${1:-}
  [ -n "$(declarations)" ] || return 0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $repo"

  if [ -n "$if_repo" ]; then
    url=$(origin_url "$repo") || return 0
    [ "$(normalize_remote "$url")" = "$(normalize_remote "$if_repo")" ] || return 0
  fi
  if [ "$fetch" = 1 ] && ! git -C "$repo" fetch origin --quiet 2>/dev/null; then
    printf 'helper-pending: fetch from origin failed; checking the last fetched state\n'
  fi
  if [ -z "$spec" ]; then
    default=$(origin_default "$repo") || { printf 'helper-pending: skipped: no origin default branch in %s\n' "$repo"; return 0; }
    spec=$default
  fi
  case "$spec" in
    *..*) from=${spec%%..*}; to=${spec#*..} ;;
    *) to=$spec ;;
  esac
  to=$(git -C "$repo" rev-parse --verify --quiet "$to^{commit}") \
    || { printf 'helper-pending: skipped: unknown revision %s\n' "$spec"; return 0; }
  if [ -n "$from" ]; then
    from=$(git -C "$repo" rev-parse --verify --quiet "$from^{commit}") \
      || { printf 'helper-pending: skipped: unknown revision %s\n' "$spec"; return 0; }
  fi

  # One line per helper version some consumer does not accept:
  # rel \t sha \t consumer \t owner \t declared path \t accepted shas
  while IFS= read -r file; do
    parse_decl "$file" || continue
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      rel=$(helper_rel "$repo" "$helper") || continue
      tgt=$(blob_sha "$repo" "$to" "$rel") || continue
      [ "$tgt" != absent ] || continue
      if [ -n "$from" ]; then
        from_sha=$(blob_sha "$repo" "$from" "$rel") || continue
        [ "$from_sha" != "$tgt" ] || continue
      fi
      accepts "$tgt" && continue
      lines="$lines$rel$TAB$tgt$TAB$DECL_CONSUMER$TAB$DECL_OWNER$TAB$helper$TAB${DECL_ACCEPTS# }"$'\n'
    done <<< "$DECL_HELPERS"
  done < <(declarations)

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=$(printf '%s' "$line" | cut -f1-2)
    case "$seen" in *"|$key|"*) continue ;; esac
    seen="$seen|$key|"
    record_version "$repo" "$to" "$(printf '%s' "$key" | cut -f1)" "$(printf '%s' "$key" | cut -f2)" \
      "$(printf '%s' "$lines" | awk -F '\t' -v k="$key" '($1 FS $2) == k')"
  done <<< "$lines"
  return 0
}

# Write one version's record and artefact if absent, then file its note if not
# yet filed. <consumer-lines> are this version's rows from cmd_pending.
record_version() {  # <repo> <commit> <rel> <sha> <consumer-lines>
  local repo=$1 commit=$2 rel=$3 sha=$4 rows=$5 base dir parent tmp landed origin
  local consumers="" owners="" c o path acc acc_json a since stat first=1 text
  base=$(basename -- "$rel")
  parent="$VERSIONS_DIR/$base"
  dir="$parent/$sha"
  while IFS="$TAB" read -r _ _ c o path acc; do
    consumers="$consumers${consumers:+,}$c"
    case ",$owners," in *",$o,"*) ;; *) owners="$owners${owners:+,}$o" ;; esac
  done <<< "$rows"

  if [ ! -f "$dir/pending.json" ]; then
    mkdir -p "$parent" || { printf 'helper-pending: cannot create %s\n' "$parent"; return 0; }
    tmp=$(mktemp -d "$parent/.pending.XXXXXX") || { printf 'helper-pending: cannot stage a record in %s\n' "$parent"; return 0; }
    landed=$(git -C "$repo" log -1 --format=%cI "$commit" -- "$rel" 2>/dev/null)
    origin=$(origin_url "$repo") || origin=$repo
    if ! {
      printf '{\n'
      printf '  "schema": "fm-helper-version/v1",\n'
      printf '  "helper": %s,\n' "$(json_str "$rel")"
      printf '  "sha256": "%s",\n' "$sha"
      printf '  "commit": "%s",\n' "$commit"
      printf '  "repo": %s,\n' "$(json_str "$origin")"
      printf '  "landed_at": %s,\n' "$(json_str "$landed")"
      printf '  "recorded_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '  "artefact": %s,\n' "$(json_str "$dir/$base")"
      printf '  "consumers": ['
      while IFS="$TAB" read -r _ _ c o path acc; do
        acc_json="" stat=""
        for a in $acc; do
          acc_json="$acc_json${acc_json:+, }\"$a\""
          if [ -z "$stat" ]; then
            since=$(commit_for_sha "$repo" "$commit" "$rel" "$a")
            [ -z "$since" ] || stat="$(git -C "$repo" diff --shortstat "$since" "$commit" -- "$rel" 2>/dev/null | sed 's/^ *//') since $since"
          fi
        done
        [ "$first" = 1 ] || printf ','
        first=0
        printf '\n    {"consumer": %s, "owner": %s, "helper_path": %s, "accepts": [%s], "diff_since_accepted": %s}' \
          "$(json_str "$c")" "$(json_str "$o")" "$(json_str "$path")" "$acc_json" "$(json_str "$stat")"
      done <<< "$rows"
      printf '\n  ]\n}\n'
    } > "$tmp/pending.json" \
      || ! git -C "$repo" cat-file blob "$commit:$rel" > "$tmp/$base" \
      || ! chmod 444 "$tmp/$base" "$tmp/pending.json"; then
      rm -rf -- "$tmp"
      printf 'helper-pending: cannot write the record for %s %s\n' "$rel" "$sha"
      return 0
    fi
    if [ ! -e "$dir" ] && mv -- "$tmp" "$dir"; then
      printf 'helper-pending: %s version %s recorded at %s, awaiting %s\n' "$rel" "$(printf '%s' "$sha" | cut -c1-12)" "$dir" "$consumers"
    else
      rm -rf -- "$tmp"
    fi
  fi
  [ -f "$dir/pending.json" ] || return 0
  [ ! -e "$dir/note-filed" ] || return 0
  text="Firstmate helper $rel has a new version $(printf '%s' "$sha" | cut -c1-12) at commit $(printf '%s' "$commit" | cut -c1-12) that $consumers (owner $owners) has not accepted yet; /updatefirstmate holds it until they accept it. Review artefact: $dir/$base. Route this to $owners for review."
  file_note "$dir" "helper-pending-$base-$(printf '%s' "$sha" | cut -c1-12)" "$text" || true
  return 0
}

# ---------------------------------------------------------------- hold log

HOLD_OUTCOMES="held cleared bypass break"

# The current time in epoch seconds into <var>; FM_HELPER_CONSUMERS_NOW wins.
now_to() {  # <var>
  local v=${FM_HELPER_CONSUMERS_NOW:-}
  if [ -n "$v" ]; then
    case "$v" in *[!0-9]*) die "FM_HELPER_CONSUMERS_NOW must be epoch seconds" ;; esac
  else
    v=$(date +%s)
  fi
  printf -v "$1" '%s' "$v"
}

epoch_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

cmd_log() {
  local outcome=${1:-} home=${2:-} commit=${3:-} helper=${4:-} sha=${5:-} consumers=${6:-} note=${7:-} now at log
  [ $# -ge 6 ] && [ $# -le 7 ] || die "usage: log <outcome> <home> <target-commit> <helper> <sha256> <consumers> [<note>]"
  case " $HOLD_OUTCOMES " in *" $outcome "*) ;; *) die "unknown outcome '$outcome' (one of: $HOLD_OUTCOMES)" ;; esac
  case "$home" in
    /*) ;;
    *) die "home must be an absolute path" ;;
  esac
  case "$home$helper" in *"$TAB"*|*$'\n'*) die "home and helper must not hold a tab or newline" ;; esac
  [ ! -d "$home" ] || home=$(CDPATH='' cd -- "$home" && pwd -P) || die "cannot resolve $home"
  case "$commit" in
    -) ;;
    *[!0-9a-f]*|'') die "target commit must be a full lowercase commit id or -" ;;
    *) [ "${#commit}" -eq 40 ] || [ "${#commit}" -eq 64 ] || die "target commit must be a full lowercase commit id or -" ;;
  esac
  [ -n "$helper" ] || die "helper must not be empty"
  case "$sha" in
    -|absent) ;;
    *[!0-9a-f]*|'') die "sha256 must be a lowercase sha256, absent or -" ;;
    *) [ "${#sha}" -eq 64 ] || die "sha256 must be a lowercase sha256, absent or -" ;;
  esac
  case "$consumers" in
    ''|*[!A-Za-z0-9._,-]*) die "consumers must be a comma list of consumer ids or -" ;;
  esac
  note=${note//$TAB/ }
  note=${note//$'\n'/ }
  note=${note//$'\r'/ }
  [ "${#note}" -le 600 ] || note="${note:0:597}..."
  now_to now
  at=$(epoch_iso "$now") || { printf 'fm-helper-consumers: cannot format the time %s\n' "$now" >&2; exit 1; }
  log="$VERSIONS_DIR/holds.log"
  mkdir -p "$VERSIONS_DIR" 2>/dev/null || { printf 'fm-helper-consumers: cannot create %s\n' "$VERSIONS_DIR" >&2; exit 1; }
  # One short line in one append, so concurrent writers never interleave.
  { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$at" "$outcome" "$home" "$commit" "$helper" "$sha" "$consumers" "$note" >> "$log"; } 2>/dev/null \
    || { printf 'fm-helper-consumers: cannot append to %s\n' "$log" >&2; exit 1; }
}

cmd_holds() {
  local home="" mode=lines log="$VERSIONS_DIR/holds.log" now
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) [ -n "${2:-}" ] || die "--home needs a directory"; home=$2; shift 2 ;;
      --open) [ "$mode" = lines ] || die "--open and --windows exclude each other"; mode=open; shift ;;
      --windows) [ "$mode" = lines ] || die "--open and --windows exclude each other"; mode=windows; shift ;;
      *) die "usage: holds [--home <home>] [--open | --windows]" ;;
    esac
  done
  [ -z "$home" ] || [ ! -d "$home" ] || home=$(CDPATH='' cd -- "$home" && pwd -P) || die "cannot resolve $home"
  [ -e "$log" ] || [ -L "$log" ] || return 0
  [ -f "$log" ] && [ -r "$log" ] || { printf 'fm-helper-consumers: cannot read %s\n' "$log" >&2; return 1; }
  now_to now
  awk -F '\t' -v home="$home" -v mode="$mode" -v now="$now" -v logf="$log" '
    function epoch(t,   y, m, d, era, yoe, doy, doe) {
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return (era * 146097 + doe - 719468) * 86400 + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2)
    }
    function base(p) { sub(/.*\//, "", p); return p }
    function emit(w, end, hours) {
      printf "%s\t%s\t%s\t%.1f\t%d\t%s\t%d\t%s\n", whome[w], wstart[w], end, hours, wpass[w], wvers[w], wbreak[w], wnote[w]
    }
    NF < 8 || $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ ||
    ($2 != "held" && $2 != "cleared" && $2 != "bypass" && $2 != "break") {
      if (mode != "lines") { printf "fm-helper-consumers: %s line %d is not a hold record; skipped\n", logf, NR > "/dev/stderr"; next }
    }
    home != "" && $3 != home { next }
    mode == "lines" { print; next }
    {
      k = $3 SUBSEP $5 SUBSEP $6
      if ($2 == "held" || $2 == "bypass") {
        if (!(k in open)) {
          if (!(k in seen)) { seen[k] = 1; order[++n] = k }
          if (cnt[$3] + 0 == 0) {
            w = ++nw; win[$3] = w; whome[w] = $3; wstart[w] = $1; wpass[w] = 0; wvers[w] = ""; wbreak[w] = 0; wnote[w] = "-"; wend[w] = ""
          }
          open[k] = 1; since[k] = $1; cnt[$3]++
          w = win[$3]; v = base($5) "@" substr($6, 1, 12)
          if (index("," wvers[w] ",", "," v ",") == 0) wvers[w] = wvers[w] (wvers[w] == "" ? "" : ",") v
        }
        who[k] = $7
        w = win[$3]
        if (lastpass[$3] != $1) { wpass[w]++; lastpass[$3] = $1 }
      } else if ($2 == "cleared") {
        if (k in open) {
          delete open[k]; cnt[$3]--
          if (cnt[$3] == 0) { w = win[$3]; wend[w] = $1; wnote[w] = ($8 == "" ? "-" : $8) }
        }
      } else if ($2 == "break") {
        if (cnt[$3] + 0 > 0) wbreak[win[$3]]++
      }
    }
    END {
      if (mode == "open") {
        for (i = 1; i <= n; i++) if (order[i] in open) {
          split(order[i], p, SUBSEP); print p[1] "\t" p[2] "\t" p[3] "\t" who[order[i]] "\t" since[order[i]]
        }
      } else if (mode == "windows") {
        for (w = 1; w <= nw; w++) {
          if (wend[w] != "") emit(w, wend[w], (epoch(wend[w]) - epoch(wstart[w])) / 3600)
          else emit(w, "open", (now - epoch(wstart[w])) / 3600)
        }
      }
    }' "$log"
}

# ---------------------------------------------------------------- alarm

ALARM_ID="helper-unaccepted"
ALARM_DEFAULT_MAX=7200
ALARM_STATUS="helper-unaccepted.status"

# Seconds in a limit such as 7200, 90m or 2h into LIMIT; fails on anything else.
parse_limit() {  # <text>
  local n=${1%[smh]}
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#n}" -le 9 ] || return 1
  n=$((10#$n))
  case "${1#"$n"}" in
    ''|s) LIMIT=$n ;;
    m) LIMIT=$((n * 60)) ;;
    h) LIMIT=$((n * 3600)) ;;
    *) return 1 ;;
  esac
}

# The limit file into LIMIT (default when absent); LIMIT_ERROR on a failed reading.
read_limit() {  # <file>
  local f=$1 line value="" n=0
  LIMIT=$ALARM_DEFAULT_MAX LIMIT_ERROR=""
  [ -e "$f" ] || [ -L "$f" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || { LIMIT_ERROR="is not a readable file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//[[:space:]]/}
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    value=$line
  done < "$f"
  [ "$n" -gt 0 ] || { LIMIT_ERROR="holds no value"; LIMIT=$ALARM_DEFAULT_MAX; return 1; }
  [ "$n" -eq 1 ] || { LIMIT_ERROR="holds more than one value"; LIMIT=$ALARM_DEFAULT_MAX; return 1; }
  if ! parse_limit "$value"; then
    LIMIT=$ALARM_DEFAULT_MAX
    LIMIT_ERROR="'$value' is not a whole number of seconds, minutes (m) or hours (h)"
    return 1
  fi
}

slug() {  # <text>
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# A project identity comparable with a record's repo: the normalized origin
# URL, else the path itself, as record_version writes it.
project_of() {  # <repo>
  local url
  url=$(origin_url "$1") && [ -n "$url" ] || url=$1
  normalize_remote "$url"
}

# Rebuild <out> from the declarations: `ok<TAB>consumer<TAB>owner<TAB>rel<TAB>accepts`
# per helper in <repo>'s project, `bad<TAB>file<TAB>reason` per malformed file.
alarm_declarations() {  # <repo> <out>
  local file helper rel
  while IFS= read -r file; do
    if ! parse_decl "$file"; then
      printf 'bad\t%s\t%s\n' "$file" "$DECL_ERROR"
      continue
    fi
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      rel=$(helper_rel "$1" "$helper") || continue
      printf 'ok\t%s\t%s\t%s\t%s\n' "$DECL_CONSUMER" "$DECL_OWNER" "$rel" "${DECL_ACCEPTS# }"
    done <<< "$DECL_HELPERS"
  done < <(declarations) > "$2"
}

# One records.tsv row for a pending record:
# `<path><TAB>ok<TAB>rel<TAB>sha<TAB>project` or `<path><TAB>bad<TAB>reason`.
alarm_record_row() {  # <pending.json>
  local f=$1 out rel sha repo dirsha
  dirsha=$(basename -- "$(dirname -- "$f")")
  if [ ! -r "$f" ] || ! out=$(jq -r 'select(.schema == "fm-helper-version/v1")
      | [.helper, .sha256, .repo] | map(if type == "string" then . else error("field") end) | @tsv' "$f" 2>/dev/null); then
    printf '%s\tbad\tcannot be read as a fm-helper-version/v1 record\n' "$f"
    return 0
  fi
  IFS="$TAB" read -r rel sha repo <<< "$out"
  if [ -z "$rel" ] || [ -z "$repo" ]; then
    printf '%s\tbad\tis not a fm-helper-version/v1 record with helper, sha256 and repo\n' "$f"
  elif [ "$sha" != "$dirsha" ] || [ "${#sha}" -ne 64 ] || case "$sha" in *[!0-9a-f]*) true ;; *) false ;; esac; then
    printf '%s\tbad\tits sha256 does not name its directory\n' "$f"
  else
    printf '%s\tok\t%s\t%s\t%s\n' "$f" "$rel" "$sha" "$(normalize_remote "$repo")"
  fi
}

# Print each line of <lines> not printed by the previous pass; keep the set.
alarm_report() {  # <dir> <lines>
  local path="$1/undeliverable" old="" line
  [ ! -f "$path" ] || old=$(cat "$path" 2>/dev/null)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $'\n'"$old"$'\n' in *$'\n'"$line"$'\n'*) ;; *) printf '%s\n' "$line" ;; esac
  done <<< "$2"
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$path"; else rm -f -- "$path"; fi
}

# This home's id for the store id: its .fm-secondmate-home marker, else main.
alarm_home_id() {  # <home>
  local id=""
  [ ! -f "$1/.fm-secondmate-home" ] || IFS= read -r id < "$1/.fm-secondmate-home" || true
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) id=main ;; esac
  printf '%s\n' "$id"
}

root_home() {  # <home>
  # A separate shell keeps the wake library's globals out of this script.
  # shellcheck disable=SC2016 # The inner shell expands its own arguments.
  env -u FM_STATE_OVERRIDE -u STATE FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$1" \
    bash -c '. "$1/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1; fm_firstmate_root_home "$2"' \
    fm-helper-consumers "$SCRIPT_DIR" "$1"
}

# The local home of secondmate <owner> listed in <root>/data/secondmates.md
# with a state/ folder; fails when this machine cannot reach it.
owner_home() {  # <root> <owner>
  (
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh" || exit 1
    secondmate_registry_line_for_id "$1/data/secondmates.md" "$2" || exit 1
    [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || exit 1
    [ -d "$SECONDMATE_REGISTRY_HOME/state" ] || exit 1
    CDPATH='' cd -- "$SECONDMATE_REGISTRY_HOME" && pwd -P
  )
}

# Bind <store> to <target-home>'s state/helper-unaccepted.status; prints a
# problem line on failure.
alarm_register() {  # <target-home> <store-id> <store> <home-id>
  local state="$1/state" reg text cur="" tmp
  reg="$state/alert-stores/$2.reg"
  text="schema=fm-alert-registration/v1
store=$2
path=$3
status=$ALARM_STATUS
owner=$4 fm-helper-consumers"
  [ -d "$state" ] || { printf 'helper-unaccepted: alarms for %s cannot be delivered: %s does not exist\n' "$1" "$state"; return 1; }
  [ -e "$state/$ALARM_STATUS" ] || : > "$state/$ALARM_STATUS" \
    || { printf 'helper-unaccepted: alarms for %s cannot be delivered: cannot create %s\n' "$1" "$state/$ALARM_STATUS"; return 1; }
  [ ! -f "$reg" ] || cur=$(cat "$reg" 2>/dev/null)
  [ "$cur" != "$text" ] || return 0
  if ! mkdir -p "$state/alert-stores" 2>/dev/null || ! tmp=$(mktemp "$state/alert-stores/.$2.reg.XXXXXX" 2>/dev/null) \
      || ! printf '%s\n' "$text" > "$tmp" || ! mv -f -- "$tmp" "$reg"; then
    [ -z "${tmp:-}" ] || rm -f -- "$tmp"
    printf 'helper-unaccepted: alarms for %s cannot be delivered: cannot write %s\n' "$1" "$reg"
    return 1
  fi
}

cmd_alarm() {
  local repo=$FM_ROOT action=pass home state
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ -n "${2:-}" ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --arm) action=arm; shift ;;
      --disarm) action=disarm; shift ;;
      *) die "usage: alarm [--repo <dir>] [--arm | --disarm]" ;;
    esac
  done
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || die "cannot resolve the home $home"
  state=${FM_STATE_OVERRIDE:-$home/state}
  case "$action" in
    arm) alarm_arm "$home" "$state" "$repo" ;;
    disarm) alarm_disarm "$home" "$state" ;;
    *) alarm_pass "$home" "$state" "$repo" ;;
  esac
}

alarm_arm() {  # <home> <state> <repo>
  local tmp
  repo=$(CDPATH='' cd -- "$3" 2>/dev/null && pwd -P) || die "cannot resolve the repo $3"
  [ -d "$2" ] || die "no state directory $2"
  tmp=$(mktemp "$2/.$ALARM_ID.XXXXXX") || die "cannot stage the check in $2"
  if ! {
    printf '#!/usr/bin/env bash\n'
    printf '# %s: the unaccepted helper version alarm, armed by fm-helper-consumers.sh alarm --arm.\n' "$ALARM_ID"
    printf 'exec env FM_HOME=%q' "$1"
    [ -z "${FM_HELPER_CONSUMERS:-}" ] || printf ' FM_HELPER_CONSUMERS=%q' "$FM_HELPER_CONSUMERS"
    [ -z "${FM_HELPER_VERSIONS:-}" ] || printf ' FM_HELPER_VERSIONS=%q' "$FM_HELPER_VERSIONS"
    printf ' %q alarm --repo %q\n' "$SCRIPT_DIR/fm-helper-consumers.sh" "$repo"
  } > "$tmp" || ! chmod 700 "$tmp"; then
    rm -f -- "$tmp"
    die "cannot write the check to $tmp"
  fi
  if ! FM_HOME="$1" "$SCRIPT_DIR/fm-check-register.sh" "$ALARM_ID" --from "$tmp" \
      --no-handoff "reads helper-version records and helper-consumer declarations on this machine and writes only its own alert stores"; then
    rm -f -- "$tmp"
    printf 'helper-unaccepted: not armed: check registration refused\n'
    return 1
  fi
  printf 'helper-unaccepted: armed in %s\n' "$1"
  alarm_pass "$1" "$2" "$repo"
}

alarm_disarm() {  # <home> <state>
  local dir="$2/$ALARM_ID" id f target_home rc=0
  id="$ALARM_ID.$(alarm_home_id "$1")"
  for f in "$dir"/stores/*.home; do
    [ -f "$f" ] || continue
    IFS= read -r target_home < "$f" || continue
    if FM_HOME="$target_home" FM_STATE_OVERRIDE="$target_home/state" "$SCRIPT_DIR/fm-alert-store.sh" unregister "$id" >/dev/null; then
      rm -f -- "$f" "${f%.home}.wanted"
    else
      printf 'helper-unaccepted: cannot unregister %s in %s\n' "$id" "$target_home"
      rc=1
    fi
  done
  if [ -e "$2/$ALARM_ID.check.sh" ]; then
    FM_HOME="$1" FM_STATE_OVERRIDE="$2" "$SCRIPT_DIR/fm-check-unregister.sh" "$ALARM_ID" || rc=1
  fi
  [ "$rc" = 0 ] && printf 'helper-unaccepted: disarmed in %s\n' "$1"
  return "$rc"
}

alarm_pass() {  # <home> <state> <repo>
  local home=$1 dir="$2/$ALARM_ID" repo=$3 now limit_file main_ref main="" project stamp
  local f old="" scan="" rows="" routes="" problems="" root="" line key reason
  local b s12 rel t who owners rdir ref o oh unreached id store wanted prev tmp decl_new=0
  local -a targets=()
  now_to now
  if [ -z "$(declarations)" ]; then
    # Nothing is declared: clear whatever an earlier pass raised, write nothing new.
    [ -d "$dir/stores" ] || return 0
  else
    mkdir -p "$dir/stores" 2>/dev/null || { printf 'helper-unaccepted: cannot create %s\n' "$dir/stores"; return 0; }
    command -v jq >/dev/null 2>&1 || { alarm_report "$dir" "helper-unaccepted: jq is missing, so no unaccepted helper version can be checked"; return 0; }
    stamp="$dir/.stamp"
    : > "$dir/.stamp.next" || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/.stamp.next"; return 0; }
    limit_file="${FM_CONFIG_OVERRIDE:-$home/config}/helper-unaccepted-max"
    read_limit "$limit_file" \
      || rows="$rows$ALARM_ID-max-unreadable${TAB}limit file $limit_file $LIMIT_ERROR; the alarm counts 2h until it is fixed"$'\n'
    main_ref=$(origin_default "$repo") && main=$(git -C "$repo" rev-parse --verify --quiet "$main_ref^{commit}" 2>/dev/null) || main=""

    # Declarations: re-resolved only when a file, the file set or the branch
    # changed, or a file stopped being readable.
    f=$(declarations; printf 'repo %s %s %s\n' "$repo" "$main" "$main_ref")
    if [ ! -f "$dir/decls.tsv" ] || [ ! -f "$stamp" ] || [ "$f" != "$(cat "$dir/decls.list" 2>/dev/null)" ]; then
      decl_new=1
    else
      while IFS= read -r line; do
        case "$line" in "repo "*) continue ;; esac
        [ "$stamp" -nt "$line" ] && [ -r "$line" ] || decl_new=1
      done <<< "$f"
    fi
    if [ "$decl_new" = 1 ]; then
      { alarm_declarations "$repo" "$dir/decls.tsv.new" && mv -f -- "$dir/decls.tsv.new" "$dir/decls.tsv" \
        && printf '%s\n' "$f" > "$dir/decls.list"; } || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/decls.tsv"; return 0; }
    fi

    # Records: one stat each; only a record new, changed or no longer readable
    # since the last pass is read.
    [ ! -f "$stamp" ] || [ ! -f "$dir/records.tsv" ] || old=$'\n'$(cat "$dir/records.tsv")$'\n'
    for f in "$VERSIONS_DIR"/*/*/pending.json; do
      [ -e "$f" ] || continue
      case "$old" in
        *$'\n'"$f$TAB"*) if [ "$stamp" -nt "$f" ] && [ -r "$f" ]; then scan="$scan$f${TAB}keep"$'\n'; continue; fi ;;
      esac
      scan="$scan$(alarm_record_row "$f")"$'\n'
    done
    # The old rows, a `.` line, then this pass's rows; a kept row is copied.
    { printf '%s\n.\n%s' "$old" "$scan" | awk -F '\t' '
        !sep { if ($0 == ".") sep = 1; else if ($1 != "") row[$1] = $0; next }
        $1 == "" { next }
        $2 == "keep" { print row[$1]; next }
        { print }' > "$dir/records.tsv.new" \
      && mv -f -- "$dir/records.tsv.new" "$dir/records.tsv"; } \
      || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/records.tsv"; return 0; }

    # The branch: per helper path, its bytes there and when it took them;
    # recomputed only when the branch moved or a new path appeared.
    if [ -z "$main" ]; then
      rows="$rows$ALARM_ID-branch-unreadable${TAB}cannot read the origin default branch of $repo, so helper versions cannot be judged; the last judged alarms stay"$'\n'
      [ -f "$dir/due.tsv" ] || : > "$dir/due.tsv"
    else
      project=$(project_of "$repo")
      f=$(awk -F '\t' -v p="$project" '$2 == "ok" && $5 == p && !s[$3]++ { print $3 }' "$dir/records.tsv")
      if [ "$(head -n 1 "$dir/main.tsv" 2>/dev/null)" != "$main $main_ref" ] \
          || [ -n "$(printf '%s\n' "$f" | awk -F '\t' 'NR == FNR { if (FNR > 1) have[$1] = 1; next } $0 != "" && !($0 in have)' "$dir/main.tsv" - 2>/dev/null)" ]; then
        {
          {
            printf '%s %s\n' "$main" "$main_ref"
            while IFS= read -r line; do
              [ -n "$line" ] || continue
              printf '%s\t%s\t%s\n' "$line" "$(blob_sha "$repo" "$main" "$line")" "$(git -C "$repo" log -1 --format=%ct "$main" -- "$line" 2>/dev/null)"
            done <<< "$f"
          } > "$dir/main.tsv.new" && mv -f -- "$dir/main.tsv.new" "$dir/main.tsv"
        } || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/main.tsv"; return 0; }
      fi
      # Each version on the branch some declaring consumer has not accepted
      # within the limit: helper name, sha12, path, since, consumers, owners,
      # record directory, branch.
      { awk -F '\t' -v p="$project" -v now="$now" -v limit="$LIMIT" -v ref="$main_ref" '
        FILENAME == ARGV[1] { if ($1 == "ok") { n++; dc[n] = $2; dw[n] = $3; dr[n] = $4; da[n] = " " $5 " " }; next }
        FILENAME == ARGV[2] { if (FNR > 1) { msha[$1] = $2; msince[$1] = $3 }; next }
        $2 != "ok" || $5 != p || msha[$3] != $4 || msince[$3] == "" { next }
        {
          who = ""; own = ""
          for (i = 1; i <= n; i++) if (dr[i] == $3 && index(da[i], " " $4 " ") == 0) {
            who = who (who == "" ? "" : ",") dc[i]
            if (index("," own ",", "," dw[i] ",") == 0) own = own (own == "" ? "" : ",") dw[i]
          }
          if (who == "" || now - msince[$3] < limit) next
          b = $3; sub(/.*\//, "", b); d = $1; sub(/\/pending\.json$/, "", d)
          print b "\t" substr($4, 1, 12) "\t" $3 "\t" msince[$3] "\t" who "\t" own "\t" d "\t" ref
        }' "$dir/decls.tsv" "$dir/main.tsv" "$dir/records.tsv" > "$dir/due.tsv.new" \
        && mv -f -- "$dir/due.tsv.new" "$dir/due.tsv"; } \
        || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/due.tsv"; return 0; }
    fi
    # Failed readings of declarations and records.
    rows="$rows$(awk -F '\t' -v id="$ALARM_ID" '$1 == "bad" {
        s = $2; sub(/.*\//, "", s); sub(/\.conf$/, "", s); gsub(/[^A-Za-z0-9._-]/, "-", s)
        print id "-decl-" s "\tdeclaration " $2 " " $3 "; it accepts nothing and cannot be checked until it is fixed" }' "$dir/decls.tsv")"$'\n'
    rows="$rows$(awk -F '\t' -v id="$ALARM_ID" '$2 == "bad" {
        d = $1; sub(/\/pending\.json$/, "", d); s = d; sub(/.*\//, "", s); h = d; sub(/\/[^\/]*$/, "", h); sub(/.*\//, "", h)
        k = h "-" substr(s, 1, 12); gsub(/[^A-Za-z0-9._-]/, "-", k)
        print id "-record-" k "\tpending record " $1 " " $3 "; its version cannot be checked until it is fixed" }' "$dir/records.tsv")"$'\n'
  fi

  # Route: `target<TAB>key<TAB>kind<TAB>subject<TAB>reason<TAB>since-epoch`.
  # Every level goes to main; a version level also to each owner this
  # machine reaches.
  while IFS="$TAB" read -r key reason; do
    [ -n "$key" ] || continue
    routes="${routes}main$TAB$key${TAB}failed-reading${TAB}$ALARM_ID$TAB$reason$TAB$now"$'\n'
  done <<< "$rows"
  if [ -n "$(declarations)" ] && [ -s "$dir/due.tsv" ]; then
    root=$(root_home "$home") || { alarm_report "$dir" "helper-unaccepted: cannot resolve the root home of $home, so no alarm can be delivered"; return 0; }
    while IFS="$TAB" read -r b s12 rel t who owners rdir ref; do
      [ -n "$b" ] || continue
      key=$(slug "$ALARM_ID-$b-$s12")
      reason="$rel version $s12 on $ref since $(epoch_iso "$t") is not accepted by $who (owner $owners) within the limit; review artefact in $rdir"
      unreached=""
      for o in ${owners//,/ }; do
        case "$o" in main|.*|*[!A-Za-z0-9._-]*) oh="" ;; *) oh=$(owner_home "$root" "$o") || oh="" ;; esac
        if [ -n "$oh" ] && [ "$oh" != "$root" ]; then
          routes="$routes$o$TAB$key${TAB}unaccepted$TAB$rel$TAB$reason$TAB$t"$'\n'
          [ "$(cat "$dir/stores/$o.home" 2>/dev/null)" = "$oh" ] || printf '%s\n' "$oh" > "$dir/stores/$o.home"
        elif [ -z "$oh" ] && [ "$o" != main ]; then
          unreached="$unreached${unreached:+, }$o"
        fi
      done
      [ -z "$unreached" ] || reason="$reason (for $unreached, whose home this machine does not see)"
      routes="${routes}main$TAB$key${TAB}unaccepted$TAB$rel$TAB$reason$TAB$t"$'\n'
    done < "$dir/due.tsv"
  fi
  [ -n "$routes" ] || [ -d "$dir/stores" ] || return 0

  # Sync each target's store when its wanted set changed; a target that wants
  # nothing any more is cleared.
  id="$ALARM_ID.$(alarm_home_id "$home")"
  for f in "$dir"/stores/*.json; do
    [ -f "$f" ] || continue
    t=$(basename -- "$f" .json)
    case " ${targets[*]-} " in *" $t "*) ;; *) targets+=("$t") ;; esac
  done
  while IFS="$TAB" read -r t _; do
    [ -n "$t" ] || continue
    case " ${targets[*]-} " in *" $t "*) ;; *) targets+=("$t") ;; esac
  done <<< "$routes"
  for t in ${targets[@]+"${targets[@]}"}; do
    store="$dir/stores/$t.json"
    prev="$dir/stores/$t.wanted"
    [ -f "$prev" ] || prev=/dev/null
    # A level keeps the since of its first pass, so an unchanged set compares equal.
    wanted=$(printf '%s' "$routes" | awk -F '\t' -v t="$t" '$1 == t' \
      | jq -R -n --slurpfile prev "$prev" '($prev[0] // {}) as $p
          | [inputs | split("\t") | {key: .[1], value: {kind: .[2], subject: .[3], reason: .[4],
              since: ($p[.[1]].since // (.[5] | tonumber | todate)), evidence: {}}}] | from_entries') \
      || { problems="$problems"$'\n'"helper-unaccepted: cannot build the alarms for $t"; continue; }
    if [ -f "$store" ] && [ "$wanted" = "$(cat "$dir/stores/$t.wanted" 2>/dev/null)" ]; then
      continue
    fi
    if [ "$wanted" != "{}" ]; then
      if [ "$t" = main ]; then
        [ -n "$root" ] || root=$(root_home "$home") \
          || { problems="$problems"$'\n'"helper-unaccepted: cannot resolve the root home of $home, so no alarm can be delivered"; continue; }
        printf '%s\n' "$root" > "$dir/stores/main.home"
      fi
      oh=$(cat "$dir/stores/$t.home" 2>/dev/null) || oh=""
      [ -n "$oh" ] || { problems="$problems"$'\n'"helper-unaccepted: alarms for $t cannot be delivered: its home is unknown"; continue; }
      line=$(alarm_register "$oh" "$id" "$store" "$(alarm_home_id "$home")") || { problems="$problems"$'\n'"$line"; continue; }
    fi
    tmp="$dir/stores/.$t.wanted.$$"
    if printf '%s\n' "$wanted" > "$tmp" \
        && "$SCRIPT_DIR/fm-alert-store.sh" sync "$store" "$id" "$tmp" "accepted by every declaring consumer, no longer on the branch, or read again" >/dev/null; then
      mv -f -- "$tmp" "$dir/stores/$t.wanted"
    else
      rm -f -- "$tmp"
      problems="$problems"$'\n'"helper-unaccepted: cannot write the alert store $store"
    fi
  done
  [ ! -f "$dir/.stamp.next" ] || mv -f -- "$dir/.stamp.next" "$dir/.stamp"
  alarm_report "$dir" "${problems#$'\n'}"
  return 0
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  list) shift; cmd_list "$@" ;;
  check-advance) shift; cmd_check_advance "$@" ;;
  pending) shift; cmd_pending "$@" ;;
  log) shift; cmd_log "$@" ;;
  holds) shift; cmd_holds "$@" ;;
  alarm) shift; cmd_alarm "$@" ;;
  *) usage >&2; exit 2 ;;
esac
