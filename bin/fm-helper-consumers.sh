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
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DECL_DIR="${FM_HELPER_CONSUMERS:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/firstmate/helper-consumers.d}"
VERSIONS_DIR="${FM_HELPER_VERSIONS:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/firstmate/helper-versions}"
TAB=$(printf '\t')

usage() {
  sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'
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
  root=$(
    unset FM_STATE_OVERRIDE STATE
    FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$home"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh" >/dev/null 2>&1 || exit 1
    fm_firstmate_root_home "$home"
  ) || { printf 'helper-pending: note not filed: cannot resolve the root home of %s\n' "$home"; return 1; }
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
  local file helper canon htop rel tgt from_sha lines="" line key seen=""
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
    default=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || default=""
    if [ -z "$default" ]; then
      for default in origin/main origin/master ''; do
        [ -n "$default" ] || break
        git -C "$repo" rev-parse --verify --quiet "$default^{commit}" >/dev/null && break
      done
    fi
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

  # One line per helper version some consumer does not accept:
  # rel \t sha \t consumer \t owner \t declared path \t accepted shas
  while IFS= read -r file; do
    parse_decl "$file" || continue
    while IFS= read -r helper; do
      [ -n "$helper" ] || continue
      canon=$(canonical_file "$helper") || continue
      htop=$(git -C "$(dirname -- "$canon")" rev-parse --show-toplevel 2>/dev/null) || continue
      htop=$(CDPATH='' cd -- "$htop" && pwd -P) || continue
      case "$canon" in "$htop"/*) rel=${canon#"$htop"/} ;; *) continue ;; esac
      same_project "$repo" "$htop" || continue
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

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  list) shift; cmd_list "$@" ;;
  check-advance) shift; cmd_check_advance "$@" ;;
  pending) shift; cmd_pending "$@" ;;
  *) usage >&2; exit 2 ;;
esac
