#!/usr/bin/env bash
# fm-helper-consumers.sh - declared consumers of Firstmate helpers that another
# home runs under a pin, and the deploy-after-acceptance gate that keeps a new
# helper version off their path until each of them accepts it, and the landing
# gate that keeps it off the default branch until then.
#
# docs/helper-consumers.md owns the rule, the declaration format, and what each
# consumer must do; this header owns the exact commands.
#
# Usage:
#   fm-helper-consumers.sh list
#   fm-helper-consumers.sh check-advance [--allow-break <consumer>]... [--hold-bound <home>] <checkout> <target-rev>
#   fm-helper-consumers.sh check-land [--repo <dir>] [--fetch] [--if-repo <host>/<path>]
#                                     [--condition] [--allow-break <consumer>]... [<base>] <head>
#   fm-helper-consumers.sh pending [--repo <dir>] [--fetch] [--if-repo <host>/<path>] [<rev> | <from>..<to>]
#   fm-helper-consumers.sh pending [--repo <dir>] [--fetch] [--if-repo <host>/<path>] --candidate <rev>
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
# unless --allow-break names that declaration's file stem, which then takes a
# `break` record naming the stem for each such change.
# --hold-bound <home> applies the hold limit, a whole number of seconds,
# optionally suffixed m or h, in ${FM_CONFIG_OVERRIDE:-<home>/config}/helper-hold-max
# (1h when the file is absent). When every record that would hold is a `hold`
# whose helper version has been held at least the limit, counted from its first
# open held or bypass line in the hold log below (in any home), those records
# print as
#   expired<TAB><helper><TAB><target-sha256><TAB><consumer>[,...]<TAB><first held at>
# and the check advances. A version no pass has held yet never expires. When
# the pass still holds, one more record says when the limit lets it proceed,
# assuming this pass logs its holds now, or why no limit applies:
#   bound<TAB><limit-seconds><TAB><utc time a pass may proceed>
#   unbounded<TAB><reason>
# An `unproven` hold, and every hold while the limit file is present but empty,
# unreadable or malformed or the hold log cannot be read, gets `unbounded`.
# Only bin/fm-update.sh passes --hold-bound, for the primary checkout.
# A missing file hashes as `absent`. Exit 0 to advance, 3 to hold, 2 on a usage
# error or an unreadable checkout or revision. With no declarations it prints
# nothing and exits 0 before reading the checkout, so a home without
# declarations behaves exactly as before. bin/fm-ff-lib.sh's ff_target runs this
# before every byte-changing step and treats any status but 0 as a hold.
#
# check-land is the landing gate. It classes each declared helper whose bytes
# landing <head> on <base> (default: the origin default branch) would change,
# with check-advance's classifier and outcomes: <base>'s bytes are the current
# version and <head>'s the target. A helper counts when its own checkout is
# the same project as --repo (default: this script's own checkout), as for
# pending. When <base> is not an ancestor of <head>, a helper only <base>
# changed since their merge base is left alone, and one both changed holds as
#   diverged<TAB><helper><TAB><head-sha256><TAB><consumer>[,...]
# because the bytes such a landing yields are unknown until <head> is rebased;
# --allow-break does not release it. --allow-break is the operator-run break,
# as for check-advance; when a head it releases may land, each `break` record
# is first written to the hold log as a `break` line for FM_HOME (else the
# checkout), and a line that cannot be written exits 2. A `break` line
# check-land itself wrote (marked `taken-by=check-land`, which `log` never
# writes) releases its consumers for that exact helper basename and sha256 on
# every later run, with or without --condition, and is printed as a `break`
# record but not logged again; bytes with another sha256 need their own
# acceptance or break, a `break` line from `log` releases nothing, and a missing
# or unreadable hold log records no break. --fetch fetches origin first, and
# <head> by its id when it is missing. --if-repo exits 0 quietly unless
# --repo's origin is that forge host and path, and exits 2 when that origin
# URL is absent or unreadable, because the gate cannot then tell whether the
# landing is this project's. --condition exits 1
# rather than 3 while held, as a park cmd: condition needs, and refuses
# --allow-break. A declared helper that cannot be located (no such
# directory, or not in a git checkout) is a stale declaration: it is reported
# as `malformed`, and a head that changes any file with the helper's basename
# holds as `unproven` with that file's bytes at <head>, because a moved helper
# keeps its name; --allow-break naming the consumer releases it, and every
# other head passes. Exit 0 to land, 3 to hold, 2 on a usage error, a failed
# fetch, or an unreadable checkout or revision. With no declarations it prints
# nothing and exits 0 before reading anything else. Every landing path runs it
# and refuses on any status but 0.
#
# pending records each declared helper version at <rev> (default: the origin
# default branch) that some declaring consumer does not accept yet, once per
# version, under FM_HELPER_VERSIONS, default
# ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/helper-versions:
#   <helper basename>/<sha256>/pending.json   the record (schema fm-helper-version/v1)
#   <helper basename>/<sha256>/<basename>     read-only copy of those exact bytes,
#                                             the review artefact; consumers never run it
#   <helper basename>/<sha256>/note-filed     written once the note below is filed
#   <helper basename>/<sha256>/evidence/      optional files listed in the note,
#                                             read when the note is filed
#   <helper basename>/retired/<sha256>[.<epoch>]/  a withdrawn candidate record,
#                                             with withdrawn-note-filed once noted
# and files one fm-inbox.sh note per version to the root home of FM_HOME
# (request id helper-pending-<basename>-<sha12>, with -r<n> after n withdrawals
# of that version, so a retry never duplicates it).
# A declared helper counts when its checkout is the same project as --repo
# (default: this script's own checkout): the same git common directory or the
# same origin URL. With <from>..<to>, only helpers whose bytes differ between
# the two revisions are considered. --if-repo exits quietly unless --repo's
# origin is that forge host and path (fm-pr-merge.sh passes the merged PR's);
# --fetch fetches --repo's origin first and continues on a failed fetch.
#
# --candidate <rev> is the same pass for a landing candidate before it lands
# (fm-ci-push.sh land and fm-pr-merge.sh run it): it considers helpers whose
# bytes differ between <rev> and its merge base with the origin default branch,
# writes a new record with "candidate" set to <rev>'s commit and landed_at
# empty, files the note once, and prints one line per unaccepted version:
#   helper-candidate: <helper>@<sha12> unaccepted by <consumers>; landing holds every home's update until they accept
# With --fetch, a <rev> missing locally is fetched from origin first. A landed
# run (no --candidate) that meets a record with landed_at empty fills in commit
# and landed_at in place, keeping the directory and its note-filed marker.
#
# Every pending run also retires candidate records of --repo's origin still
# unlanded 14 days after recorded_at: after a fresh fetch, one whose version is
# on the default branch is filled in instead; any other moves to retired/ and
# files a "candidate withdrawn" note (request id
# helper-candidate-withdrawn-<basename>-<sha12>[-<epoch>]), retried until filed.
# FM_HELPER_CONSUMERS_NOW (epoch seconds) replaces the clock for that age.
#
# Every failure after the declarations are read is reported and exits 0,
# because the landing that called it is never held by it; a usage error exits 2.
#
# log appends one line to the hold log, FM_HELPER_VERSIONS/holds.log, and is
# its only writer; bin/fm-update.sh and the landing gate call it. This
# interface is stable: outcomes and trailing fields may be added, nothing is
# renamed, removed or reordered, and readers ignore fields they do not know.
# Each line is one tab-separated record, written by a single append:
#   <utc time> <outcome> <home> <target-commit> <helper> <sha256> <consumers> <note> [<taken-by>]
# <outcome> is one of:
#   held     a pass of <home> held at <target-commit> because <consumers> have
#            not accepted <helper> version <sha256>;
#   cleared  a later pass of <home> advanced past that held version;
#   bypass   a held pass on a version that reached the default branch around
#            the landing gate, which no break line names; it opens and clears
#            like held, and also marks the version so alarm raises it at once;
#   break    an operator-run --allow-helper-break moved past <consumers>'
#            acceptance of <helper> version <sha256>; it opens and clears no
#            hold. The landing gate writes its own with the ninth field
#            `taken-by=check-land` and reads only those as releasing that
#            version; `log` takes no ninth field, so a `break` line it
#            writes is a record only.
#   expired  a pass of <home> deployed <helper> version <sha256> unaccepted by
#            <consumers> because its hold passed the hold limit (see
#            check-advance --hold-bound); a record only, it opens and clears
#            nothing, and the alarm below raises it to the consumers' owners.
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
# counted from the commit that brought those bytes to the branch, or at once
# when a bypass line in the hold log marked that version. The file holds
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
# The same pass raises one level helper-unaccepted-deployed-<helper>-<sha12>, at
# once, for each helper version an `expired` line in the hold log records while
# the bytes at that helper path are still that version and a consumer the line
# names still does not accept it; it takes that version's place, so the
# version's branch level above is not raised beside it. It routes like a branch
# level to main and to each such consumer's owner, so every owner gets one level
# per version, and a malformed declaration's consumer counts as not accepting.
# It clears when each named consumer accepts the version, its declaration is
# removed, or the helper's bytes change. The hold log and the helper files are
# re-read only when they changed since the last pass. A hold log that cannot be
# read, or a helper-hold-max file that cannot be read, raises its own level.
# The same pass sends one success notice per helper version with an open hold
# in the hold log (a held or bypass line no cleared line has closed, in any
# home) once every consumer those holds name accepts it, appending
#   note [at=<epoch>]: helper-accepted <helper>@<sha12>: rerun the update
# to the root home's state/helper-unaccepted.status through fm-worker-status.sh,
# where <helper> is the path the hold log names. A consumer whose declaration is
# removed counts as accepting and a malformed one as not, and a hold naming no
# consumer is never judged. The note is per helper version, so a pass held on
# several helpers can hold again on another after one note. A sent version is
# marked under state/helper-unaccepted/accepted/ until it stops being accepted
# or its holds clear, so a rerun sends nothing; a notice that cannot be sent
# prints one line and is retried on the next pass, and a failure to write the
# notices' own state prints one line and leaves the rest of the pass running;
# a version whose sent marker cannot be written is not sent until it can.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DECL_DIR="${FM_HELPER_CONSUMERS:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/firstmate/helper-consumers.d}"
VERSIONS_DIR="${FM_HELPER_VERSIONS:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/firstmate/helper-versions}"
TAB=$(printf '\t')
RETIRE_DAYS=14

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

# ---------------------------------------------------------------- classifier

# The path of declared helper <canon> relative to its checkout, in REL, when
# this run checks it: `inside` takes a helper under <top> (check-advance's
# checkout); `project` takes a helper whose own checkout is the same project
# as <top> (check-land). Returns 1 for a helper it does not check, and 2 in
# `project` mode for one it cannot locate.
locate() {  # <mode> <top> <helper>
  local canon htop
  if ! canon=$(canonical_file "$3"); then
    [ "$1" = project ] || return 1
    return 2
  fi
  case "$1" in
    inside)
      case "$canon" in "$2"/*) REL=${canon#"$2"/}; return 0 ;; esac
      return 1
      ;;
  esac
  htop=$(git -C "$(dirname -- "$canon")" rev-parse --show-toplevel 2>/dev/null) || return 2
  htop=$(CDPATH='' cd -- "$htop" && pwd -P) || die "cannot resolve the checkout of $3"
  same_project "$2" "$htop" || return 1
  REL=${canon#"$htop"/}
}

# The bytes <rel> has before (PAIR_CUR) and after (PAIR_TGT) <head> lands on
# <base>. Returns 1 when the landing leaves them as they are, and 4 when
# <base> and <head> both changed them since <merge-base> (empty to compare
# <base> and <head> alone), so the bytes the landing yields are not known.
pair() {  # <repo> <base> <head> <merge-base> <rel>
  local mid
  PAIR_CUR=$(blob_sha "$1" "$2" "$5") || die "cannot hash $5 at $2"
  PAIR_TGT=$(blob_sha "$1" "$3" "$5") || die "cannot hash $5 at $3"
  [ "$PAIR_CUR" != "$PAIR_TGT" ] || return 1
  [ -n "$4" ] || return 0
  mid=$(blob_sha "$1" "$4" "$5") || die "cannot hash $5 at $4"
  [ "$mid" != "$PAIR_TGT" ] || return 1
  [ "$mid" = "$PAIR_CUR" ] || return 4
}

# Whether <head> changes, since <merge-base>, a file with the basename of
# declared helper <helper>, which a helper that cannot be located may have
# become; that file's bytes at <head> are left in NAME_TGT. The changed paths
# are read once per classify run.
same_name() {  # <top> <head> <merge-base> <helper>
  local name path
  if [ "$CHANGED_READ" = 0 ]; then
    CHANGED=$(git -C "$1" -c core.quotePath=false diff --name-only --no-renames "$3" "$2") \
      || die "cannot list the files $2 changes in $1"
    CHANGED_READ=1
  fi
  name=${4##*/}
  while IFS= read -r path; do
    [ "${path##*/}" = "$name" ] || continue
    NAME_TGT=$(blob_sha "$1" "$2" "$path") || die "cannot hash $path at $2"
    return 0
  done <<< "$CHANGED"
  return 1
}

# Whether LOGGED, the operator breaks check-land read from the hold log, holds
# one of <consumer> for this exact helper version; check-advance reads none.
LOGGED=""
logged() {  # <helper> <sha256> <consumer>
  case "$LOGGED" in *$'\n'"${1##*/}@$2 $3"$'\n'*) return 0 ;; esac
  return 1
}

# Split the comma list <stems> into PRIOR, those with a logged break for this
# helper version, and KEPT, the rest.
split_logged() {  # <helper> <sha256> <stems>
  local s stems
  KEPT="" PRIOR=""
  [ -n "$3" ] || return 0
  IFS=, read -r -a stems <<< "$3"
  for s in "${stems[@]}"; do
    if logged "$1" "$2" "$s"; then PRIOR="$PRIOR${PRIOR:+,}$s"; else KEPT="$KEPT${KEPT:+,}$s"; fi
  done
}

# The shared classifier of check-advance and check-land: one record per
# outcome for every declared helper whose bytes <head> changes on <base>, in
# RECORDS, with HELD=1 when any record holds. The header owns the outcomes; a
# release by a logged break is the internal kind `logged`, printed as `break`.
classify() {  # <mode> <top> <base> <head> <merge-base> <allow>
  local mode=$1 top=$2 base=$3 head=$4 mb=$5 allow=$6 file helper stem rc
  local bad="" freed="" watched="" seen
  RECORDS="" HELD=0 CHANGED_READ=0
  while IFS= read -r file; do
    if ! parse_decl "$file"; then
      RECORDS="${RECORDS}malformed$TAB$file$TAB$DECL_ERROR$TAB-"$'\n'
      stem=$(basename -- "$file" .conf)
      case " $allow " in
        *" $stem "*) freed="$freed${freed:+,}$stem" ;;
        *) bad="$bad${bad:+,}$stem" ;;
      esac
      watched="$watched$(salvage_helpers "$file")"$'\n'
      continue
    fi
    watched="$watched$DECL_HELPERS"
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      rc=0
      locate "$mode" "$top" "$helper" || rc=$?
      case "$rc" in
        0) ;;
        2) RECORDS="${RECORDS}malformed$TAB$file${TAB}declared helper $helper cannot be located$TAB-"$'\n'
           same_name "$top" "$head" "$mb" "$helper" || continue
           case " $allow " in
             *" $DECL_CONSUMER "*) RECORDS="${RECORDS}break$TAB$helper$TAB$NAME_TGT$TAB$DECL_CONSUMER"$'\n' ;;
             *) if logged "$helper" "$NAME_TGT" "$DECL_CONSUMER"; then
                  RECORDS="${RECORDS}logged$TAB$helper$TAB$NAME_TGT$TAB$DECL_CONSUMER"$'\n'
                else
                  RECORDS="${RECORDS}unproven$TAB$helper$TAB$NAME_TGT$TAB$DECL_CONSUMER"$'\n'
                  HELD=1
                fi ;;
           esac
           continue ;;
        *) continue ;;
      esac
      rc=0
      pair "$top" "$base" "$head" "$mb" "$REL" || rc=$?
      case "$rc" in
        0) ;;
        1) continue ;;
        *) RECORDS="${RECORDS}diverged$TAB$helper$TAB$PAIR_TGT$TAB$DECL_CONSUMER"$'\n'
           HELD=1
           continue ;;
      esac
      if accepts "$PAIR_TGT"; then
        continue
      fi
      case " $allow " in
        *" $DECL_CONSUMER "*)
          RECORDS="${RECORDS}break$TAB$helper$TAB$PAIR_TGT$TAB$DECL_CONSUMER"$'\n'
          continue
          ;;
      esac
      if ! accepts "$PAIR_CUR"; then
        RECORDS="${RECORDS}waiting$TAB$helper$TAB$PAIR_TGT$TAB$DECL_CONSUMER"$'\n'
      elif logged "$helper" "$PAIR_TGT" "$DECL_CONSUMER"; then
        RECORDS="${RECORDS}logged$TAB$helper$TAB$PAIR_TGT$TAB$DECL_CONSUMER"$'\n'
      else
        RECORDS="${RECORDS}hold$TAB$helper$TAB$PAIR_TGT$TAB$DECL_CONSUMER"$'\n'
        HELD=1
      fi
    done <<< "$DECL_HELPERS"
  done < <(declarations)

  # A declaration that cannot be parsed cannot prove what its consumer accepts,
  # so while one is malformed or unreadable, every change to a helper any
  # declaration names holds, unless --allow-break or a logged break names that
  # file's stem; at the landing gate a stem it names gets a break record for
  # each such change, so it is logged, and a diverged head still holds. The
  # update gate drops a named stem without a record, as it always has.
  [ "$mode" = project ] || freed=""
  [ -n "$bad$freed" ] || return 0
  seen=$'\n'
  while IFS= read -r helper; do
    [ -n "$helper" ] || continue
    case "$seen" in *$'\n'"$helper"$'\n'*) continue ;; esac
    seen="$seen$helper"$'\n'
    rc=0
    locate "$mode" "$top" "$helper" || rc=$?
    case "$rc" in
      0) ;;
      2) same_name "$top" "$head" "$mb" "$helper" || continue
         [ -z "$freed" ] || RECORDS="${RECORDS}break$TAB$helper$TAB$NAME_TGT$TAB$freed"$'\n'
         split_logged "$helper" "$NAME_TGT" "$bad"
         [ -z "$PRIOR" ] || RECORDS="${RECORDS}logged$TAB$helper$TAB$NAME_TGT$TAB$PRIOR"$'\n'
         [ -n "$KEPT" ] || continue
         RECORDS="${RECORDS}unproven$TAB$helper$TAB$NAME_TGT$TAB$KEPT"$'\n'
         HELD=1
         continue ;;
      *) continue ;;
    esac
    case "$seen" in *$'\n'"@$top/$REL"$'\n'*) continue ;; esac
    seen="$seen@$top/$REL"$'\n'
    rc=0
    pair "$top" "$base" "$head" "$mb" "$REL" || rc=$?
    case "$rc" in
      0) [ -z "$freed" ] || RECORDS="${RECORDS}break$TAB$helper$TAB$PAIR_TGT$TAB$freed"$'\n'
         split_logged "$helper" "$PAIR_TGT" "$bad"
         [ -z "$PRIOR" ] || RECORDS="${RECORDS}logged$TAB$helper$TAB$PAIR_TGT$TAB$PRIOR"$'\n'
         [ -n "$KEPT" ] || continue
         RECORDS="${RECORDS}unproven$TAB$helper$TAB$PAIR_TGT$TAB$KEPT"$'\n' ;;
      1) continue ;;
      *) RECORDS="${RECORDS}diverged$TAB$helper$TAB$PAIR_TGT$TAB$bad${bad:+${freed:+,}}$freed"$'\n' ;;
    esac
    HELD=1
  done <<< "$watched"
}

# Print RECORDS aggregated per kind, helper and sha.
emit_records() {
  local out kind a b c
  out=$(printf '%s' "$RECORDS" | sed "s/^logged$TAB/break$TAB/" | aggregate)
  [ -n "$out" ] || return 0
  while IFS="$TAB" read -r kind a b c; do
    if [ "$kind" = malformed ]; then
      printf 'malformed%s%s%s%s\n' "$TAB" "$a" "$TAB" "$b"
    else
      printf '%s%s%s%s%s%s%s\n' "$kind" "$TAB" "$a" "$TAB" "$b" "$TAB" "$c"
    fi
  done <<< "$out"
}

# ---------------------------------------------------------------- check-advance

cmd_check_advance() {
  local allow="" checkout target top out bound_home=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-break)
        [ -n "${2:-}" ] || die "--allow-break needs a consumer id"
        allow="$allow $2"
        shift 2
        ;;
      --hold-bound)
        [ -n "${2:-}" ] || die "--hold-bound needs a home"
        bound_home=$2
        shift 2
        ;;
      --) shift; break ;;
      -*) die "unknown option $1" ;;
      *) break ;;
    esac
  done
  [ $# -eq 2 ] || die "usage: check-advance [--allow-break <consumer>]... [--hold-bound <home>] <checkout> <target-rev>"
  checkout=$1 target=$2
  [ -n "$(declarations)" ] || return 0

  top=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) || die "not a git checkout: $checkout"
  top=$(CDPATH='' cd -- "$top" && pwd -P) || die "cannot resolve $checkout"
  git -C "$top" rev-parse --verify --quiet "$target^{commit}" >/dev/null || die "unknown revision $target in $checkout"

  classify inside "$top" HEAD "$target" "" "$allow"
  out=$(emit_records)
  if [ "$HELD" = 1 ] && [ -n "$bound_home" ]; then
    hold_bound "$bound_home" "$out"
    out=$BOUND_OUT HELD=$BOUND_HELD
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$HELD" = 0 ] || return 3
  return 0
}

# The hold limit for check-advance --hold-bound: when every record that holds
# is a `hold` whose version has been held at least the limit, counted from its
# first open held or bypass line in the hold log in any home, those records
# become `expired` and the pass advances (BOUND_HELD=0). Otherwise the records
# stay and one `bound` record says when the limit lets the pass proceed, or one
# `unbounded` record says why no limit applies. A version with no open hold yet
# counts from now and never expires before one pass has held it; when the log
# cannot be read, every version counts from now.
hold_bound() {  # <home> <records>
  local limit_file opens now proceed stems
  BOUND_OUT=$2 BOUND_HELD=1
  stems=$(printf '%s\n' "$2" | awk -F '\t' '$1 == "unproven" { print $4; exit }')
  if [ -n "$stems" ]; then
    BOUND_OUT="$BOUND_OUT"$'\n'"unbounded${TAB}malformed or unreadable declaration $stems holds without a limit"
    return 0
  fi
  limit_file="${FM_CONFIG_OVERRIDE:-$1/config}/$HOLD_MAX_FILE"
  if ! read_limit "$limit_file" "$HOLD_DEFAULT_MAX"; then
    BOUND_OUT="$BOUND_OUT"$'\n'"unbounded${TAB}limit file $limit_file $LIMIT_ERROR, so the hold has no limit until it is fixed"
    return 0
  fi
  if ! opens=$(cmd_holds --open 2>/dev/null); then
    BOUND_OUT="$BOUND_OUT"$'\n'"unbounded${TAB}hold log $VERSIONS_DIR/holds.log cannot be read, so every hold counts from now"
    return 0
  fi
  now_to now
  # The open holds, a `.` line, then the records. The first output line is
  # `advance` or `hold <epoch the limit lets the pass proceed>`.
  BOUND_OUT=$(printf '%s\n.\n%s\n' "$opens" "$2" | awk -F '\t' -v now="$now" -v limit="$LIMIT" "$AWK_EPOCH"'
    !sep { if ($0 == ".") sep = 1; else if ($2 != "" && (!(($2 SUBSEP $3) in since) || $5 < since[$2 SUBSEP $3])) since[$2 SUBSEP $3] = $5; next }
    $0 == "" { next }
    { line[++n] = $0; kind[n] = $1
      if ($1 == "hold") {
        k = $2 SUBSEP $3; first[n] = (k in since) ? since[k] : ""
        start = (first[n] == "") ? now : epoch(first[n])
        if (start + limit > proceed) proceed = start + limit
        if (first[n] == "" || start + limit > now) waiting = 1
      } }
    END {
      if (waiting) { print "hold\t" proceed; for (i = 1; i <= n; i++) print line[i]; exit }
      print "advance"
      for (i = 1; i <= n; i++) {
        if (kind[i] == "hold") { sub(/^hold/, "expired", line[i]); print line[i] "\t" first[i] } else print line[i]
      }
    }') || { BOUND_OUT="$2"$'\n'"unbounded${TAB}cannot apply the hold limit"; return 0; }
  case "$BOUND_OUT" in
    advance*) BOUND_OUT=${BOUND_OUT#advance}; BOUND_OUT=${BOUND_OUT#$'\n'}; BOUND_HELD=0 ;;
    hold"$TAB"*)
      proceed=${BOUND_OUT%%$'\n'*}; proceed=${proceed#hold"$TAB"}
      BOUND_OUT=${BOUND_OUT#*$'\n'}
      BOUND_OUT="$BOUND_OUT"$'\n'"bound$TAB$LIMIT$TAB$(epoch_iso "$proceed")"
      ;;
    *) BOUND_OUT="$2"$'\n'"unbounded${TAB}cannot apply the hold limit" ;;
  esac
}

# ---------------------------------------------------------------- check-land

# Record each break the landing of <head> on <base> takes in the hold log,
# before it lands; a break that cannot be recorded refuses the landing.
log_breaks() {  # <top> <head> <base>
  local out helper sha who home=${FM_HOME:-}
  out=$(printf '%s' "$RECORDS" | awk -F '\t' '$1 == "break"' | aggregate)
  [ -n "$out" ] || return 0
  case "$home" in /*) ;; *) home=$1 ;; esac
  while IFS="$TAB" read -r _ helper sha who; do
    ( TAKEN_BY=$TAKEN_BY_LAND; cmd_log break "$home" "$2" "$helper" "$sha" "$who" \
        "--allow-helper-break for $who allows ${helper##*/}@$sha to land (taken on $2 over $3)" ) \
      || die "cannot record the break of $who for $helper in $VERSIONS_DIR/holds.log, so $2 may not land"
  done <<< "$out"
}

# Read the operator breaks check-land logged itself into LOGGED, one
# `<helper basename>@<sha256> <consumer>` per line; a break line `log` wrote
# lacks the taken-by field and counts for nothing, and a missing or unreadable
# log records none, so its holds stand.
read_logged() {
  local lines
  lines=$( (cmd_holds) 2>/dev/null) || lines=""
  LOGGED=$'\n'$(printf '%s\n' "$lines" | awk -F '\t' -v by="$TAKEN_BY_LAND" '
    $2 == "break" && $9 == by && length($6) == 64 && $6 !~ /[^0-9a-f]/ {
      b = $5; sub(/.*\//, "", b); n = split($7, c, ",")
      for (i = 1; i <= n; i++) if (c[i] != "" && c[i] != "-") print b "@" $6 " " c[i] }')$'\n'
}

cmd_check_land() {
  local repo=$FM_ROOT fetch=0 if_repo="" allow="" condition=0 base="" head top url
  local base_c head_c mb
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ -n "${2:-}" ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --fetch) fetch=1; shift ;;
      --if-repo) [ -n "${2:-}" ] || die "--if-repo needs <host>/<path>"; if_repo=$2; shift 2 ;;
      --condition) condition=1; shift ;;
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
  case $# in
    1) head=$1 ;;
    2) base=$1 head=$2 ;;
    *) die "usage: check-land [--repo <dir>] [--fetch] [--if-repo <host>/<path>] [--condition] [--allow-break <consumer>]... [<base>] <head>" ;;
  esac
  [ "$condition" = 0 ] || [ -z "$allow" ] || die "--condition and --allow-break exclude each other: a parked wait never carries the operator's break"
  [ -n "$(declarations)" ] || return 0

  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "not a git checkout: $repo"
  top=$(CDPATH='' cd -- "$top" && pwd -P) || die "cannot resolve $repo"
  if [ -n "$if_repo" ]; then
    url=$(origin_url "$top") && [ -n "$url" ] \
      || die "cannot read the origin URL of $top, so --if-repo cannot tell whether this landing is this project's"
    [ "$(normalize_remote "$url")" = "$(normalize_remote "$if_repo")" ] || return 0
  fi
  if [ "$fetch" = 1 ]; then
    git -C "$top" fetch --quiet origin 2>/dev/null || die "cannot fetch origin in $top"
    git -C "$top" rev-parse --verify --quiet "$head^{commit}" >/dev/null \
      || git -C "$top" fetch --quiet origin "$head" 2>/dev/null \
      || die "cannot fetch $head from origin in $top"
  fi
  if [ -z "$base" ]; then
    base=$(origin_default "$top") || die "no origin default branch in $top"
  fi
  base_c=$(git -C "$top" rev-parse --verify --quiet "$base^{commit}") || die "unknown revision $base in $top"
  head_c=$(git -C "$top" rev-parse --verify --quiet "$head^{commit}") || die "unknown revision $head in $top"
  mb=$(git -C "$top" merge-base "$base_c" "$head_c" 2>/dev/null) || die "$base and $head share no history in $top"

  read_logged
  classify project "$top" "$base_c" "$head_c" "$mb" "$allow"
  emit_records
  [ "$HELD" = 1 ] || { log_breaks "$top" "$head_c" "$base"; return 0; }
  printf 'fm-helper-consumers: %s may not land on %s yet: the records above name each held helper (docs/helper-consumers.md "The landing gate")\n' "$head_c" "$base" >&2
  [ "$condition" = 0 ] || return 1
  return 3
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

# File one note to the root home of FM_HOME and write <marker> once it is
# filed; <quiet> 1 prints only a failure.
file_note() {  # <label> <marker> <request-id> <text> <quiet>
  local label=$1 marker=$2 request=$3 text=$4 quiet=$5 home root
  home=${FM_HOME:-}
  [ -n "$home" ] || { printf '%s: note not filed: FM_HOME is not set\n' "$label"; return 1; }
  # A separate shell keeps the wake library's globals out of this script.
  # shellcheck disable=SC2016 # The inner shell expands its own arguments.
  root=$(env -u FM_STATE_OVERRIDE -u STATE FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$home" \
    bash -c '. "$1/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1; fm_firstmate_root_home "$2"' \
    fm-helper-consumers "$SCRIPT_DIR" "$home") || { printf '%s: note not filed: cannot resolve the root home of %s\n' "$label" "$home"; return 1; }
  if env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$root" \
      "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$request" -- "$text" >/dev/null 2>&1; then
    : > "$marker"
    [ "$quiet" = 1 ] || printf '%s: note filed to %s\n' "$label" "$root"
    return 0
  fi
  printf '%s: note not filed to %s; the next pending run retries it\n' "$label" "$root"
  return 1
}

cmd_pending() {
  local repo=$FM_ROOT fetch=0 if_repo="" spec="" from="" to default="" url candidate="" mode=landed
  local file helper rel tgt from_sha lines="" line key seen=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ -n "${2:-}" ] || die "--repo needs a directory"; repo=$2; shift 2 ;;
      --fetch) fetch=1; shift ;;
      --if-repo) [ -n "${2:-}" ] || die "--if-repo needs <host>/<path>"; if_repo=$2; shift 2 ;;
      --candidate) [ -n "${2:-}" ] || die "--candidate needs a revision"; candidate=$2; mode=candidate; shift 2 ;;
      --) shift; break ;;
      -*) die "unknown option $1" ;;
      *) break ;;
    esac
  done
  [ $# -le 1 ] || die "usage: pending [--repo <dir>] [--fetch] [--if-repo <host>/<path>] [--candidate <rev> | <rev> | <from>..<to>]"
  spec=${1:-}
  [ -z "$candidate" ] || [ -z "$spec" ] || die "--candidate takes no <rev> or range"
  [ -n "$(declarations)" ] || return 0
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $repo"

  if [ -n "$if_repo" ]; then
    url=$(origin_url "$repo") || return 0
    [ "$(normalize_remote "$url")" = "$(normalize_remote "$if_repo")" ] || return 0
  fi
  if [ "$fetch" = 1 ] && ! git -C "$repo" fetch origin --quiet 2>/dev/null; then
    printf 'helper-%s: fetch from origin failed; checking the last fetched state\n' "$mode"
  fi
  default=$(origin_default "$repo") || default=""
  if [ -n "$candidate" ]; then
    [ -n "$default" ] || { printf 'helper-candidate: skipped: no origin default branch in %s\n' "$repo"; return 0; }
    if [ "$fetch" = 1 ] && ! git -C "$repo" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
      git -C "$repo" fetch origin --quiet "$candidate" 2>/dev/null || true
    fi
    to=$(git -C "$repo" rev-parse --verify --quiet "$candidate^{commit}") \
      || { printf 'helper-candidate: skipped: unknown revision %s\n' "$candidate"; return 0; }
    # Against the merge base, so a candidate behind the default branch is not
    # taken to change a helper the default branch changed after it.
    from=$(git -C "$repo" merge-base "$default" "$to" 2>/dev/null) \
      || { printf 'helper-candidate: skipped: %s shares no history with %s\n' "$candidate" "$default"; return 0; }
  else
    if [ -z "$spec" ]; then
      [ -n "$default" ] || { printf 'helper-pending: skipped: no origin default branch in %s\n' "$repo"; return 0; }
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
      "$(printf '%s' "$lines" | awk -F '\t' -v k="$key" '($1 FS $2) == k')" "$mode"
  done <<< "$lines"
  sweep_candidates "$repo" "$default" "$seen"
  return 0
}

# How many retired records <parent>/retired/ holds for <sha>; a version that
# comes back after a withdrawal files its note under a new request id.
retired_count() {  # <parent> <sha>
  local n=0 d
  for d in "$1/retired/$2" "$1/retired/$2".*; do
    [ -d "$d" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# The note's optional evidence field, set in EVIDENCE: every regular file
# directly in <record-dir>/evidence/ when the note is filed, as
# " Evidence: <path>[; <path>]..."; docs/helper-consumers.md owns the format.
evidence_field() {  # <record-dir>
  local f name LC_ALL=C  # name order is byte order whatever the caller's locale
  EVIDENCE=""
  if [ -e "$1/evidence" ] && [ ! -d "$1/evidence" ]; then
    printf 'helper-pending: %s is not a directory; the note carries no evidence\n' "$1/evidence"
    return 0
  fi
  for f in "$1"/evidence/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name=${f##*/}
    case "$name" in
      *[!A-Za-z0-9._-]*) printf 'helper-pending: evidence %s left out of the note: its name is not [A-Za-z0-9._-]\n' "$f"; continue ;;
    esac
    if [ -L "$f" ] || [ ! -f "$f" ]; then
      printf 'helper-pending: evidence %s left out of the note: not a regular file\n' "$f"
      continue
    fi
    EVIDENCE="$EVIDENCE${EVIDENCE:+; }$f"
  done
  [ -z "$EVIDENCE" ] || EVIDENCE=" Evidence: $EVIDENCE"
}

# Write one version's record and artefact if absent, then file its note if not
# yet filed. <consumer-lines> are this version's rows from cmd_pending. A
# candidate record has landed_at empty until a landed run fills it in place.
record_version() {  # <repo> <commit> <rel> <sha> <consumer-lines> <landed|candidate>
  local repo=$1 commit=$2 rel=$3 sha=$4 rows=$5 mode=$6 base dir parent tmp landed="" cand="" origin
  local consumers="" owners="" c o path acc acc_json a since stat first=1 text sha12 n request quiet=0
  base=$(basename -- "$rel")
  parent="$VERSIONS_DIR/$base"
  dir="$parent/$sha"
  sha12=$(printf '%s' "$sha" | cut -c1-12)
  while IFS="$TAB" read -r _ _ c o path acc; do
    consumers="$consumers${consumers:+,}$c"
    case ",$owners," in *",$o,"*) ;; *) owners="$owners${owners:+,}$o" ;; esac
  done <<< "$rows"

  if [ ! -f "$dir/pending.json" ]; then
    mkdir -p "$parent" || { printf 'helper-pending: cannot create %s\n' "$parent"; return 0; }
    tmp=$(mktemp -d "$parent/.pending.XXXXXX") || { printf 'helper-pending: cannot stage a record in %s\n' "$parent"; return 0; }
    if [ "$mode" = candidate ]; then
      cand=$commit
    else
      landed=$(git -C "$repo" log -1 --format=%cI "$commit" -- "$rel" 2>/dev/null)
    fi
    origin=$(origin_url "$repo") || origin=$repo
    if ! {
      printf '{\n'
      printf '  "schema": "fm-helper-version/v1",\n'
      printf '  "helper": %s,\n' "$(json_str "$rel")"
      printf '  "sha256": "%s",\n' "$sha"
      printf '  "commit": "%s",\n' "$commit"
      printf '  "candidate": "%s",\n' "$cand"
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
    elif { [ ! -e "$dir" ] && mv -- "$tmp" "$dir"; } \
      || { [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! -e "$dir/pending.json" ] \
        && mv -f -- "$tmp/$base" "$dir/$base" && mv -- "$tmp/pending.json" "$dir/pending.json" && rmdir -- "$tmp"; }; then
      # The second form fills a directory a producer made early for evidence/.
      [ "$mode" = candidate ] \
        || printf 'helper-pending: %s version %s recorded at %s, awaiting %s\n' "$rel" "$sha12" "$dir" "$consumers"
    else
      rm -rf -- "$tmp"
    fi
  elif [ "$mode" = landed ]; then
    fill_landed "$repo" "$dir" "$commit" "$rel"
  fi
  if [ -f "$dir/pending.json" ] && [ ! -e "$dir/note-filed" ]; then
    n=$(retired_count "$parent" "$sha")
    request="helper-pending-$base-$sha12"
    [ "$n" = 0 ] || request="$request-r$n"
    evidence_field "$dir"
    if [ "$mode" = candidate ]; then
      text="Firstmate helper $rel has a landing candidate $sha12 at commit $(printf '%s' "$commit" | cut -c1-12) that $consumers (owner $owners) has not accepted yet; once it lands, /updatefirstmate holds every home's update until they accept it. Review artefact: $dir/$base. Route this to $owners for review.$EVIDENCE"
    else
      text="Firstmate helper $rel has a new version $sha12 at commit $(printf '%s' "$commit" | cut -c1-12) that $consumers (owner $owners) has not accepted yet; /updatefirstmate holds it until they accept it. Review artefact: $dir/$base. Route this to $owners for review.$EVIDENCE"
    fi
    [ "$mode" = landed ] || quiet=1
    file_note helper-pending "$dir/note-filed" "$request" "$text" "$quiet" || true
  fi
  if [ "$mode" = candidate ]; then
    printf "helper-candidate: %s@%s unaccepted by %s; landing holds every home's update until they accept\n" "$rel" "$sha12" "$consumers"
  fi
  return 0
}

# ---------------------------------------------------------------- hold log

HOLD_OUTCOMES="held cleared bypass break expired"
# The ninth field of a break line check-land took itself, the only kind it
# reads as releasing; set by log_breaks alone, never from the command line.
TAKEN_BY_LAND="taken-by=check-land"
TAKEN_BY=""
# Under VERSIONS_DIR, one empty <helper basename>@<sha256> file per version a
# bypass line names; the dot keeps it out of the record glob.
BYPASS_DIR=".bypass"
HOLD_MAX_FILE="helper-hold-max"
HOLD_DEFAULT_MAX=3600

# Epoch seconds of a <utc time> field, for the awk programs that read the log.
AWK_EPOCH='function epoch(t,   y, m, d, era, yoe, doy, doe) {
      y = substr(t, 1, 4) + 0; m = substr(t, 6, 2) + 0; d = substr(t, 9, 2) + 0
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      return (era * 146097 + doe - 719468) * 86400 + substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2)
    }'

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
  if [ "$outcome" = bypass ] && [ "${#sha}" -eq 64 ]; then
    # The mark alarm reads, written first so a version is never logged
    # bypassed without being raised at once.
    { mkdir -p "$VERSIONS_DIR/$BYPASS_DIR" && : > "$VERSIONS_DIR/$BYPASS_DIR/${helper##*/}@$sha"; } 2>/dev/null \
      || { printf 'fm-helper-consumers: cannot mark %s version %s bypassed in %s\n' "$helper" "$sha" "$VERSIONS_DIR/$BYPASS_DIR" >&2; exit 1; }
  fi
  # One short line in one append, so concurrent writers never interleave.
  { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\n' "$at" "$outcome" "$home" "$commit" "$helper" "$sha" "$consumers" "$note" \
      "${TAKEN_BY:+$TAB$TAKEN_BY}" >> "$log"; } 2>/dev/null \
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
  awk -F '\t' -v home="$home" -v mode="$mode" -v now="$now" -v logf="$log" -v outcomes=" $HOLD_OUTCOMES " "$AWK_EPOCH"'
    function base(p) { sub(/.*\//, "", p); return p }
    function emit(w, end, hours) {
      printf "%s\t%s\t%s\t%.1f\t%d\t%s\t%d\t%s\n", whome[w], wstart[w], end, hours, wpass[w], wvers[w], wbreak[w], wnote[w]
    }
    NF < 8 || $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ ||
    index(outcomes, " " $2 " ") == 0 {
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

# The limit file into LIMIT (<default>, else the alarm's, when absent);
# LIMIT_ERROR on a failed reading.
read_limit() {  # <file> [<default>]
  local f=$1 dflt=${2:-$ALARM_DEFAULT_MAX} line value="" n=0
  LIMIT=$dflt LIMIT_ERROR=""
  [ -e "$f" ] || [ -L "$f" ] || return 0
  [ -f "$f" ] && [ -r "$f" ] || { LIMIT_ERROR="is not a readable file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//[[:space:]]/}
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    value=$line
  done < "$f"
  [ "$n" -gt 0 ] || { LIMIT_ERROR="holds no value"; LIMIT=$dflt; return 1; }
  [ "$n" -eq 1 ] || { LIMIT_ERROR="holds more than one value"; LIMIT=$dflt; return 1; }
  if ! parse_limit "$value"; then
    LIMIT=$dflt
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

# Rebuild <out> from the declarations: `who<TAB>consumer<TAB>owner<TAB>accepts`
# per valid file, `ok<TAB>consumer<TAB>owner<TAB>rel<TAB>accepts` per helper in
# <repo>'s project, `bad<TAB>file<TAB>reason` per malformed file.
alarm_declarations() {  # <repo> <out>
  local file helper rel
  while IFS= read -r file; do
    if ! parse_decl "$file"; then
      printf 'bad\t%s\t%s\n' "$file" "$DECL_ERROR"
      continue
    fi
    printf 'who\t%s\t%s\t%s\n' "$DECL_CONSUMER" "$DECL_OWNER" "${DECL_ACCEPTS# }"
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
      --no-handoff "reads helper-version records, the hold log and helper-consumer declarations on this machine and writes only its own alert stores and its own status file"; then
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

# Rebuild <dir>/deployed.tsv, one row
# `<helper name><TAB><sha256><TAB><helper><TAB><since epoch><TAB><consumers><TAB><owners>`
# per version an `expired` line in <log> records while the helper still holds
# those bytes (or cannot be read) and a consumer the lines name still does not
# accept it; <dir>/deployed.helpers keeps each helper read, with its version.
alarm_deployed() {  # <dir> <log>
  local cands h sha t who owners live seen=$'\n'
  cands=$(awk -F '\t' "$AWK_EPOCH"'
    FILENAME == ARGV[1] {
      if ($1 == "who") { own[$2] = $3; acc[$2] = " " $4 " " }
      else if ($1 == "bad") { s = $2; sub(/.*\//, "", s); sub(/\.conf$/, "", s); bad[s] = 1 }
      next }
    $2 != "expired" || NF < 7 || $5 == "-" || length($6) != 64 || $6 ~ /[^0-9a-f]/ { next }
    { k = $5 SUBSEP $6
      if (!(k in first)) { first[k] = $1; order[++n] = k; list[k] = "" }
      m = split($7, cs, ",")
      for (i = 1; i <= m; i++) if (cs[i] != "-" && index("," list[k] ",", "," cs[i] ",") == 0) list[k] = list[k] (list[k] == "" ? "" : ",") cs[i] }
    END {
      for (j = 1; j <= n; j++) {
        k = order[j]; split(k, p, SUBSEP); who = ""; ow = ""
        m = split(list[k], cs, ",")
        for (i = 1; i <= m; i++) {
          c = cs[i]
          if (c in acc) { if (index(acc[c], " " p[2] " ") > 0) continue; o = own[c] }
          else if (c in bad) o = ""
          else continue
          who = who (who == "" ? "" : ",") c
          if (o != "" && index("," ow ",", "," o ",") == 0) ow = ow (ow == "" ? "" : ",") o
        }
        if (who != "") print p[1] "\t" p[2] "\t" epoch(first[k]) "\t" who "\t" ow
      }
    }' "$1/decls.tsv" "$2") || return 1
  {
    while IFS="$TAB" read -r h sha t who owners; do
      [ -n "$h" ] || continue
      case "$seen" in
        *$'\n'"$h$TAB"*) live=${seen#*$'\n'"$h$TAB"}; live=${live%%$'\n'*} ;;
        *) live=$(file_sha "$h") || live=unreadable; seen="$seen$h$TAB$live"$'\n' ;;
      esac
      [ "$live" = "$sha" ] || [ "$live" = unreadable ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${h##*/}" "$sha" "$h" "$t" "$who" "$owners"
    done <<< "$cands"
  } > "$1/deployed.tsv.new" && mv -f -- "$1/deployed.tsv.new" "$1/deployed.tsv" \
    && printf '%s' "${seen#$'\n'}" > "$1/deployed.helpers"
}

# Rebuild <dir>/accepted.tsv, one row `<helper><TAB><sha256>` per helper
# version with an open hold in <log> (a held or bypass line no cleared line has
# closed, in any home) that every consumer its open holds name now accepts; a
# consumer whose declaration is removed counts as accepting and a malformed one
# as not, and a hold naming no consumer is never judged. A sent marker in
# <dir>/accepted/ (<helper name>@<sha256>, as the levels key a version) whose
# version left the set is removed, so a later hold on it is a new occurrence; a
# marker that cannot be removed adds one line to alarm_pass's `problems`. Fails,
# removing <dir>/accepted.tsv so the next pass judges again, when the set cannot
# be read or written.
alarm_accepted() {  # <dir> <log>
  local rows f k h sha
  rows=$(awk -F '\t' '
    FILENAME == ARGV[1] {
      if ($1 == "who") acc[$2] = " " $4 " "
      else if ($1 == "bad") { s = $2; sub(/.*\//, "", s); sub(/\.conf$/, "", s); bad[s] = 1 }
      next }
    NF < 8 || $5 == "-" || length($6) != 64 || $6 ~ /[^0-9a-f]/ { next }
    $2 == "held" || $2 == "bypass" {
      k = $3 SUBSEP $5 SUBSEP $6
      if (!(k in seen)) { seen[k] = 1; order[++n] = k }
      open[k] = 1; who[k] = $7; next }
    $2 == "cleared" { delete open[$3 SUBSEP $5 SUBSEP $6] }
    END {
      for (j = 1; j <= n; j++) {
        if (!(order[j] in open)) continue
        split(order[j], p, SUBSEP); v = p[2] "\t" p[3]
        if (!(v in vseen)) { vseen[v] = 1; vorder[++m] = v; ok[v] = 1; any[v] = 0 }
        c = split(who[order[j]], cs, ",")
        for (i = 1; i <= c; i++) {
          if (cs[i] == "" || cs[i] == "-") continue
          any[v] = 1
          if (cs[i] in acc) { if (index(acc[cs[i]], " " p[3] " ") == 0) ok[v] = 0 }
          else if (cs[i] in bad) ok[v] = 0
        }
      }
      for (j = 1; j <= m; j++) if (any[vorder[j]] && ok[vorder[j]]) print vorder[j]
    }' "$1/decls.tsv" "$2") || { rm -f -- "$1/accepted.tsv"; return 1; }
  { mkdir -p "$1/accepted" && if [ -n "$rows" ]; then printf '%s\n' "$rows"; fi > "$1/accepted.tsv.new" \
    && mv -f -- "$1/accepted.tsv.new" "$1/accepted.tsv"; } 2>/dev/null \
    || { rm -f -- "$1/accepted.tsv.new" "$1/accepted.tsv" 2>/dev/null; return 1; }
  k=$'\n'
  while IFS="$TAB" read -r h sha; do
    [ -z "$h" ] || k="$k${h##*/}@$sha"$'\n'
  done <<< "$rows"
  for f in "$1"/accepted/*@*; do
    [ -e "$f" ] || continue
    case "$k" in
      *$'\n'"${f##*/}"$'\n'*) ;;
      *) rm -f -- "$f" 2>/dev/null \
        || problems="$problems"$'\n'"helper-unaccepted: cannot remove the sent marker $f, so a later hold on that version sends no accepted notice" ;;
    esac
  done
  return 0
}

# Whether <dir>/accepted/ holds a sent marker.
accepted_markers() {  # <dir>
  local f
  for f in "$1"/accepted/*@*; do [ -e "$f" ] && return 0; done
  return 1
}

# Append one level's routes to alarm_pass's `routes`: to each owner in <owners>
# whose home this machine reaches from <root> (recorded in <dir>/stores/<owner>.home),
# and to main, whose reason names the owners it cannot reach.
alarm_route() {  # <root> <dir> <key> <kind> <subject> <reason> <since-epoch> <owners>
  local o oh unreached="" reason=$6
  for o in ${8//,/ }; do
    case "$o" in main|.*|*[!A-Za-z0-9._-]*) oh="" ;; *) oh=$(owner_home "$1" "$o") || oh="" ;; esac
    if [ -n "$oh" ] && [ "$oh" != "$1" ]; then
      routes="$routes$o$TAB$3$TAB$4$TAB$5$TAB$6$TAB$7"$'\n'
      [ "$(cat "$2/stores/$o.home" 2>/dev/null)" = "$oh" ] || printf '%s\n' "$oh" > "$2/stores/$o.home"
    elif [ -z "$oh" ] && [ "$o" != main ]; then
      unreached="$unreached${unreached:+, }$o"
    fi
  done
  [ -z "$unreached" ] || reason="$reason (for $unreached, whose home this machine does not see)"
  routes="${routes}main$TAB$3$TAB$4$TAB$5$TAB$reason$TAB$7"$'\n'
}

alarm_pass() {  # <home> <state> <repo>
  local home=$1 dir="$2/$ALARM_ID" repo=$3 now limit_file main_ref main="" project stamp
  local f old="" scan="" rows="" routes="" problems="" root="" line key reason
  local b s12 rel t who owners rdir ref by bypassed oh id store wanted prev tmp decl_new=0
  local log h live sha new deployed=" " cfg declared=0 accepted_ok=1
  local -a targets=()
  now_to now
  if [ -z "$(declarations)" ]; then
    # Nothing is declared: clear whatever an earlier pass raised, write nothing new.
    [ -d "$dir/stores" ] || return 0
  else
    declared=1
    mkdir -p "$dir/stores" 2>/dev/null || { printf 'helper-unaccepted: cannot create %s\n' "$dir/stores"; return 0; }
    command -v jq >/dev/null 2>&1 || { alarm_report "$dir" "helper-unaccepted: jq is missing, so no unaccepted helper version can be checked"; return 0; }
    stamp="$dir/.stamp"
    : > "$dir/.stamp.next" || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/.stamp.next"; return 0; }
    cfg=${FM_CONFIG_OVERRIDE:-$home/config}
    read_limit "$cfg/$HOLD_MAX_FILE" "$HOLD_DEFAULT_MAX" \
      || rows="$rows$ALARM_ID-hold-max-unreadable${TAB}limit file $cfg/$HOLD_MAX_FILE $LIMIT_ERROR; /updatefirstmate holds without a limit until it is fixed"$'\n'
    limit_file="$cfg/helper-unaccepted-max"
    read_limit "$limit_file" \
      || rows="$rows$ALARM_ID-max-unreadable${TAB}limit file $limit_file $LIMIT_ERROR; the alarm counts 2h until it is fixed"$'\n'
    main_ref=$(origin_default "$repo") && main=$(git -C "$repo" rev-parse --verify --quiet "$main_ref^{commit}" 2>/dev/null) || main=""

    # Declarations: re-resolved only when a file, the file set or the branch
    # changed, or a file stopped being readable.
    f=$(declarations; printf 'format 2\nrepo %s %s %s\n' "$repo" "$main" "$main_ref")
    if [ ! -f "$dir/decls.tsv" ] || [ ! -f "$stamp" ] || [ "$f" != "$(cat "$dir/decls.list" 2>/dev/null)" ]; then
      decl_new=1
    else
      while IFS= read -r line; do
        case "$line" in "repo "*|"format "*) continue ;; esac
        [ "$stamp" -nt "$line" ] && [ -r "$line" ] || decl_new=1
      done <<< "$f"
    fi
    if [ "$decl_new" = 1 ]; then
      { alarm_declarations "$repo" "$dir/decls.tsv.new" && mv -f -- "$dir/decls.tsv.new" "$dir/decls.tsv" \
        && printf '%s\n' "$f" > "$dir/decls.list"; } || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/decls.tsv"; return 0; }
    fi

    # Versions deployed past the hold limit: re-judged only when the hold log,
    # a declaration, or a helper they name changed since the last pass.
    log="$VERSIONS_DIR/holds.log"
    if [ ! -e "$log" ] && [ ! -L "$log" ]; then
      [ ! -s "$dir/deployed.tsv" ] || : > "$dir/deployed.tsv"
      { [ ! -s "$dir/accepted.tsv" ] && ! accepted_markers "$dir"; } || alarm_accepted "$dir" /dev/null || accepted_ok=0
    elif [ ! -f "$log" ] || [ ! -r "$log" ]; then
      rows="$rows$ALARM_ID-hold-log-unreadable${TAB}hold log $log cannot be read, so versions deployed past the hold limit cannot be judged; the last judged alarms stay"$'\n'
    else
      new=$decl_new
      { [ -f "$stamp" ] && [ "$stamp" -nt "$log" ] && [ -f "$dir/deployed.tsv" ] && [ -f "$dir/deployed.helpers" ]; } || new=1
      [ "$new" = 1 ] || while IFS="$TAB" read -r h live; do
        [ -n "$h" ] || continue
        if [ -e "$h" ]; then [ "$stamp" -nt "$h" ] || new=1; else [ "$live" = absent ] || new=1; fi
      done < "$dir/deployed.helpers"
      [ "$new" = 0 ] || alarm_deployed "$dir" "$log" \
        || { alarm_report "$dir" "helper-unaccepted: cannot write $dir/deployed.tsv"; return 0; }
      [ "$new" = 0 ] && [ -f "$dir/accepted.tsv" ] || alarm_accepted "$dir" "$log" || accepted_ok=0
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
      # within the limit, or at all when a bypass line marked it: helper name,
      # sha12, path, since, consumers, owners, record directory, branch, and
      # `bypass` or `-`.
      bypassed=" "
      for f in "$VERSIONS_DIR/$BYPASS_DIR"/*@*; do
        [ -e "$f" ] && bypassed="$bypassed${f##*/} "
      done
      { awk -F '\t' -v p="$project" -v now="$now" -v limit="$LIMIT" -v ref="$main_ref" -v bypassed="$bypassed" '
        FILENAME == ARGV[1] { if ($1 == "ok") { n++; dc[n] = $2; dw[n] = $3; dr[n] = $4; da[n] = " " $5 " " }; next }
        FILENAME == ARGV[2] { if (FNR > 1) { msha[$1] = $2; msince[$1] = $3 }; next }
        $2 != "ok" || $5 != p || msha[$3] != $4 || msince[$3] == "" { next }
        {
          who = ""; own = ""
          for (i = 1; i <= n; i++) if (dr[i] == $3 && index(da[i], " " $4 " ") == 0) {
            who = who (who == "" ? "" : ",") dc[i]
            if (index("," own ",", "," dw[i] ",") == 0) own = own (own == "" ? "" : ",") dw[i]
          }
          b = $3; sub(/.*\//, "", b)
          by = index(bypassed, " " b "@" $4 " ") ? "bypass" : "-"
          if (who == "" || (by == "-" && now - msince[$3] < limit)) next
          d = $1; sub(/\/pending\.json$/, "", d)
          print b "\t" substr($4, 1, 12) "\t" $3 "\t" msince[$3] "\t" who "\t" own "\t" d "\t" ref "\t" by
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
  if [ -n "$(declarations)" ] && { [ -s "$dir/due.tsv" ] || [ -s "$dir/deployed.tsv" ]; }; then
    root=$(root_home "$home") || { alarm_report "$dir" "helper-unaccepted: cannot resolve the root home of $home, so no alarm can be delivered"; return 0; }
    # A deployed version's level takes the place of its branch level.
    [ -f "$dir/deployed.tsv" ] || : > "$dir/deployed.tsv"
    while IFS="$TAB" read -r b sha rel t who owners; do
      [ -n "$b" ] || continue
      s12=${sha:0:12}
      deployed="$deployed$b-$s12 "
      alarm_route "$root" "$dir" "$(slug "$ALARM_ID-deployed-$b-$s12")" deployed-unaccepted "$rel" \
        "$rel version $s12 was deployed by an update at $(epoch_iso "$t") after its hold passed the hold limit, and $who (owner ${owners:-unknown, its declaration is malformed}) has not accepted it, so it waits until its own review accepts that version; review artefact in $VERSIONS_DIR/$b/$sha" \
        "$t" "$owners"
    done < "$dir/deployed.tsv"
    while IFS="$TAB" read -r b s12 rel t who owners rdir ref by; do
      [ -n "$b" ] || continue
      case "$deployed" in *" $b-$s12 "*) continue ;; esac
      if [ "$by" = bypass ]; then
        reason="$rel version $s12 on $ref since $(epoch_iso "$t") is not accepted by $who (owner $owners) and reached $ref around the landing gate; review artefact in $rdir"
      else
        reason="$rel version $s12 on $ref since $(epoch_iso "$t") is not accepted by $who (owner $owners) within the limit; review artefact in $rdir"
      fi
      alarm_route "$root" "$dir" "$(slug "$ALARM_ID-$b-$s12")" unaccepted "$rel" "$reason" "$t" "$owners"
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
  # Each held version every consumer its hold names now accepts: one note to
  # main, once; a note not sent is retried on the next pass. A set that could
  # not be written sends nothing this pass and is judged again on the next.
  [ "$accepted_ok" = 1 ] || problems="$problems"$'\n'"helper-unaccepted: cannot write $dir/accepted.tsv, so no accepted notice is sent until it can"
  if [ "$declared" = 1 ] && [ "$accepted_ok" = 1 ] && [ -s "$dir/accepted.tsv" ]; then
    while IFS="$TAB" read -r h sha; do
      [ -n "$h" ] || continue
      f="$dir/accepted/${h##*/}@$sha"
      [ ! -e "$f" ] || continue
      [ -n "$root" ] || root=$(root_home "$home") \
        || { problems="$problems"$'\n'"helper-unaccepted: cannot resolve the root home of $home, so no accepted notice can be sent"; break; }
      # The marker is written as <marker>.new before the send, so a marker that
      # cannot be written sends nothing instead of a note on every pass.
      if false; then
        problems="$problems"$'\n'"helper-unaccepted: cannot write $f.new, so the accepted notice for $h@${sha:0:12} is not sent until it can"
      elif "$SCRIPT_DIR/fm-worker-status.sh" "$root/state/$ALARM_STATUS" "$root/config" \
          "note [at=<epoch>]: helper-accepted $h@${sha:0:12}: rerun the update" >/dev/null 2>&1; then
        mv -f -- "$f.new" "$f" 2>/dev/null \
          || problems="$problems"$'\n'"helper-unaccepted: accepted notice for $h@${sha:0:12} sent, but cannot write $f, so the next pass sends it again"
      else
        rm -f -- "$f.new"
        problems="$problems"$'\n'"helper-unaccepted: accepted notice for $h@${sha:0:12} not sent to $root/state/$ALARM_STATUS; the next pass retries it"
      fi
    done < "$dir/accepted.tsv"
  fi
  [ ! -f "$dir/.stamp.next" ] || mv -f -- "$dir/.stamp.next" "$dir/.stamp"
  alarm_report "$dir" "${problems#$'\n'}"
  return 0
}

# Fill a record's empty landed_at once its version is on the default branch,
# in place: the same directory, candidate field and note-filed marker.
fill_landed() {  # <repo> <record-dir> <commit> <rel>
  local repo=$1 dir=$2 commit=$3 rel=$4 was landed tmp
  was=$(jq -r 'if (.landed_at | type) == "string" then .landed_at else error("no landed_at") end' \
    "$dir/pending.json" 2>/dev/null) \
    || { printf 'helper-pending: cannot read %s; left as it is\n' "$dir/pending.json"; return 0; }
  [ -z "$was" ] || return 0
  landed=$(git -C "$repo" log -1 --format=%cI "$commit" -- "$rel" 2>/dev/null)
  [ -n "$landed" ] || { printf 'helper-pending: cannot date %s at %s; %s left as it is\n' "$rel" "$commit" "$dir/pending.json"; return 0; }
  tmp=$(mktemp "$dir/.pending.json.XXXXXX") || { printf 'helper-pending: cannot stage a fill-in in %s\n' "$dir"; return 0; }
  if jq --arg c "$commit" --arg l "$landed" '.commit = $c | .landed_at = $l' "$dir/pending.json" > "$tmp" 2>/dev/null \
      && chmod 444 "$tmp" && mv -f -- "$tmp" "$dir/pending.json"; then
    printf 'helper-pending: %s landed at %s; record %s filled in\n' "$rel" "$(printf '%s' "$commit" | cut -c1-12)" "$dir"
  else
    rm -f -- "$tmp"
    printf 'helper-pending: cannot fill in %s; left as it is\n' "$dir/pending.json"
  fi
}

# Retire every candidate record of this repository still unlanded
# RETIRE_DAYS after it was recorded, unless its version is on the default
# branch after a fresh fetch (then fill it in instead), and file or retry the
# withdrawn note of every retired record. <skip> holds this run's |rel\tsha| keys.
sweep_candidates() {  # <repo> <default> <skip>
  local repo=$1 default=$2 skip=$3 here now f dir parent rec cand landed epoch rrepo rel sha fetched=0 found dest
  here=$(origin_url "$repo") || here=""
  [ -n "$here" ] || here=$repo
  here=$(normalize_remote "$here")
  now=${FM_HELPER_CONSUMERS_NOW:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) printf 'helper-candidate: retirement skipped: FM_HELPER_CONSUMERS_NOW is not epoch seconds\n'; return 0 ;;
  esac
  for f in "$VERSIONS_DIR"/*/*/pending.json; do
    [ -f "$f" ] || continue
    rec=$(jq -r '[(.candidate // ""), .landed_at, (.recorded_at | try fromdateiso8601 catch ""), .repo, .helper, .sha256]
      | map(tostring) | join("\u001f")' "$f" 2>/dev/null) \
      || { printf 'helper-candidate: cannot read %s\n' "$f"; continue; }
    IFS=$'\037' read -r cand landed epoch rrepo rel sha <<< "$rec"
    [ -n "$cand" ] && [ -z "$landed" ] || continue
    [ "$(normalize_remote "$rrepo")" = "$here" ] || continue
    case "$skip" in *"|$rel$TAB$sha|"*) continue ;; esac
    case "$epoch" in
      ''|*[!0-9]*) printf 'helper-candidate: cannot read recorded_at in %s\n' "$f"; continue ;;
    esac
    [ $((now - epoch)) -ge $((RETIRE_DAYS * 86400)) ] || continue
    if [ -z "$default" ]; then
      printf 'helper-candidate: retirement of %s@%s skipped: no origin default branch in %s\n' "$rel" "${sha:0:12}" "$repo"
      continue
    fi
    if [ "$fetched" = 0 ]; then
      fetched=2
      git -C "$repo" fetch origin --quiet 2>/dev/null && fetched=1
    fi
    if [ "$fetched" != 1 ]; then
      printf 'helper-candidate: retirement of %s@%s skipped: fetch from origin failed\n' "$rel" "${sha:0:12}"
      continue
    fi
    dir=${f%/pending.json}
    found=$(commit_for_sha "$repo" "$default" "$rel" "$sha")
    if [ -n "$found" ]; then
      fill_landed "$repo" "$dir" "$found" "$rel"
      continue
    fi
    parent=${dir%/*}
    dest="$parent/retired/$sha"
    [ ! -e "$dest" ] || dest="$dest.$now"
    if mkdir -p "$parent/retired" && [ ! -e "$dest" ] && mv -- "$dir" "$dest"; then
      printf 'helper-candidate: %s@%s withdrawn: not on %s %s days after its notice; record moved to %s\n' \
        "$rel" "${sha:0:12}" "$default" "$RETIRE_DAYS" "$dest"
    else
      printf 'helper-candidate: cannot move %s to %s; the next pending run retries it\n' "$dir" "$dest"
    fi
  done
  for dir in "$VERSIONS_DIR"/*/retired/*/; do
    dir=${dir%/}
    [ -f "$dir/pending.json" ] && [ ! -e "$dir/withdrawn-note-filed" ] || continue
    withdrawn_note "$dir"
  done
}

# File the "candidate withdrawn" note of one retired record.
withdrawn_note() {  # <retired-dir>
  local dir=$1 rec rel sha cand owners base name suffix=""
  rec=$(jq -r '[.helper, .sha256, (.candidate // ""), ([.consumers[]?.owner] | unique | join(","))]
    | map(tostring) | join("\u001f")' "$dir/pending.json" 2>/dev/null) \
    || { printf 'helper-candidate: cannot read %s; its withdrawn note is not filed\n' "$dir/pending.json"; return 0; }
  IFS=$'\037' read -r rel sha cand owners <<< "$rec"
  base=$(basename -- "$rel")
  name=${dir##*/}
  case "$name" in *.*) suffix="-${name#*.}" ;; esac
  file_note helper-candidate "$dir/withdrawn-note-filed" "helper-candidate-withdrawn-$base-${sha:0:12}$suffix" \
    "Firstmate helper $rel landing candidate ${sha:0:12} (commit ${cand:0:12}) did not reach the default branch within $RETIRE_DAYS days of its notice, so it is withdrawn and needs no review now; a later candidate with these bytes files a new note. Record: $dir. Tell $owners." 0 || true
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  list) shift; cmd_list "$@" ;;
  check-advance) shift; cmd_check_advance "$@" ;;
  check-land) shift; cmd_check_land "$@" ;;
  pending) shift; cmd_pending "$@" ;;
  log) shift; cmd_log "$@" ;;
  holds) shift; cmd_holds "$@" ;;
  alarm) shift; cmd_alarm "$@" ;;
  *) usage >&2; exit 2 ;;
esac
