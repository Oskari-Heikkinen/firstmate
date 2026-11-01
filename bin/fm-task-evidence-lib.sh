#!/usr/bin/env bash
# Task evidence preservation: the one owner of how a task declares evidence
# that lives inside its disposable copy or its per-task temp folder, how that
# evidence is copied out before cleanup returns or removes those places, and
# when cleanup must refuse because a durable record still points into them.
# bin/fm-teardown.sh stages the copy with fm_task_evidence_stage before it
# takes the project lock and installs it with fm_task_evidence_finish before
# any destructive step; other callers use fm_task_evidence_preserve, which runs
# both. The declaration contract below is the only place it is stated.
#
# Runtime: Perl/grep for durable-record scanning; Python 3 with stdlib sqlite3
# for fixed-size hash batches and disk-backed copy inventories. Per-tree lists
# stay in the caller-owned scan directory, never in shell heaps. Each private
# spool is sealed and read through fm-spool-lib.sh: only a checked completion
# frame is EOF, never a failed open/read or truncated list. Manifest sidecars
# are staging-only and removed before installation. Interrupted
# .evidence.new.<pid> directories are not verified prior evidence and are never
# adopted: only evidence/ can satisfy a missing source declaration.
#
# Declaration: data/<id>/evidence.list, one path per line; blank lines and
# lines starting with # are ignored. A relative path names a file or directory
# inside the task's copy. An absolute path must name one inside the task's copy
# or inside its recorded tasktmp folder; anything else is refused. No path may
# contain a `..` component or contain devices, fifos, sockets or other members
# that are not regular files, directories or symlinks. Newlines in names or
# link text are unsupported and refuse. Symlinks are copied as
# links, never followed, with a warning naming each link. An existing resolved
# target inside either disposable root must itself be declared or recoverable
# from git as described below; otherwise cleanup refuses to destroy it.
#
# Copy-out: each declared path is copied to data/<id>/evidence/copy/<rel> (from
# the copy) or data/<id>/evidence/tmp/<rel> (from the tasktmp folder), and every
# copied regular file is listed in data/<id>/evidence/MANIFEST.sha256 in
# sha256sum format, so `cd data/<id>/evidence && sha256sum -c MANIFEST.sha256`
# re-verifies it later. The new evidence tree is built in a staging directory,
# each copied file's hash is compared with its source's, and only a verified
# tree replaces the previous one. Every manifest write, regular or link,
# including its sorted rewrite, fails closed before installation or
# empty-snapshot success, retaining sources and any prior tree.
# MANIFEST.sha256.links separately records hashes
# of `readlink` output for symlinks; these are checked without following links. A declared path whose source is gone (a
# retried cleanup after the copy was already returned) keeps its earlier copy
# when that copy still verifies against the earlier manifest; otherwise the
# declaration refuses, naming the path.
# Staging runs without a lock, so before each source (or carried earlier copy)
# is read its metadata inventory is snapshotted; staging's last step repeats
# every walk, rehashes each file modified within a few seconds of its snapshot
# or whose only metadata change is its mtime and ctime, and refuses with nothing
# changed when any member was added, removed, replaced, retargeted or edited
# since, unless the copy still holds the member's current bytes: the guarantee
# is that the copy equals the source as rechecked at staging's end, before any
# lock, so a same-size edit made before a file was copied is captured and
# passes, and a carried earlier copy, whose staged hashes are its stored
# manifest's, refuses any edit (bin/fm-task-evidence-stream.py owns the
# disk-backed comparison). No walk of a declared tree runs at finishing, so a caller's lock
# hold does not grow with the tree; finishing, under that lock, consumes the
# recheck's outcome and refuses when its inputs differ from staging's. Every other check and refusal below runs at finishing, in the
# original order.
#
# Dangling references: every text file under data/<id>/ other than the
# evidence tree is scanned for absolute paths strictly inside the copy or the
# tasktmp folder. The bulk text prefilter runs once over the records, in bounded
# grep argv batches for both roots together. Teardown prepares it before taking
# the project lock; metadata inventories refuse changed record identities,
# membership or timestamps before finishing and after it. The parser's
# existence-aware checks and installation run under the project lock.
# Unquoted citations end at whitespace or markup; single,
# double or backtick quoted citations must close on the same line. Word-internal
# apostrophes are prose, not quote openers. At every citation boundary,
# including quotes and markup, every longer same-line prefix is checked for an
# existing entry, so a delimiter in an existing name cannot turn its citation
# into a missing prefix. Every such entry must satisfy the same coverage rules.
# Escaped tokens or paths within larger quoted strings are ambiguous and refuse.
# Exact entries, including punctuation, are checked before each single
# component removed from markup punctuation or :line[:column] suffixes.
# Trailing slashes never hide a final dangling link entry.
# References and link targets share one survival rule: an existing object
# inside a disposable root is covered only when its resolved location is
# copied as content by a declaration, or is a clean tracked source as below.
# Resolve ancestor links, but preserve a final link as its own object; its
# target is checked separately. Lexical ancestry through a declared link never
# covers its target. Physical leading-slash aliases are normalized only after
# directory identity agrees; unresolved identity refuses. Objects resolved
# outside both roots survive cleanup.
# An undeclared regular file in the copy is also recoverable
# when git tracks it and its bytes match the HEAD blob (without clean filters);
# ignored, untracked, modified, and temp-folder paths receive no exemption.
# A reference that no longer exists (and is not a dangling symlink) warns,
# naming its record and path: there is nothing left to save. An existing
# uncovered reference refuses cleanup and is named, so a report cannot cite a
# scratch file cleanup is about to destroy. Declare it or remove the reference, then
# re-run. --force does not lift either refusal: it authorizes discarding
# unlanded work, never silently orphaning a durable record's evidence.
#
# A copy whose pool slot was already reassigned to another task (teardown's
# slot-owner claim) is no longer this task's: its contents are gone, reading
# it would read another task's work, and refusing could save nothing, so
# declarations and references into it only warn. Reference warnings retain the
# matching record line verbatim, without existence-aware parsing of foreign
# paths. Its earlier verified copy is still carried forward; a staging failure
# refuses rather than being treated as proof that the old source is lost.

# shellcheck source=bin/fm-spool-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-spool-lib.sh"

# The one hash tool choice: sets FM_TE_HASH_TOOL to shasum or sha256sum.
fm_task_evidence_hash_tool() {
  if command -v shasum >/dev/null 2>&1; then
    FM_TE_HASH_TOOL=shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    FM_TE_HASH_TOOL=sha256sum
  else
    return 1
  fi
}

fm_task_evidence_hash() {
  fm_task_evidence_hash_tool || return 1
  if [ "$FM_TE_HASH_TOOL" = shasum ]; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# Stream relative suffixes from a file; no per-tree paths or hashes survive in
# the shell. The helper bounds each hash-tool invocation and keeps fallback
# verification and manifest writes in source order.
fm_task_evidence_verify_copies() {  # <manifest> <key> <source> <copy> <rels-file>
  local rows="$5.rows" line hash rel rc=0 rows_end=0
  fm_spool seal "$5" lines || return 1
  : > "$rows" || return 1
  fm_task_evidence_stream copies "$3" "$4" "$2" "$rows" "$5" || rc=$?
  fm_spool seal "$rows" lines || return 1
  while fm_spool_next line rows_end; do
    hash=${line%%  *}; rel=${line#*  }; rel=${rel#"$2"}
    printf '%s  %s%s\n' "$hash" "$2" "$rel" >> "$1" || return 1
  done < <(fm_spool read "$rows")
  fm_spool_end "$rows_end" "$rows" || return 1
  return "$rc"
}

# Lexical classification of one declared or referenced path.
# Sets FM_TE_LABEL (copy|tmp) and FM_TE_REL; returns 1 when outside both roots.
fm_task_evidence_classify() {
  local path=$1 copy_root=$2 tmp_root=$3
  FM_TE_LABEL=
  FM_TE_REL=
  if [ -n "$copy_root" ]; then
    case "$path" in
      "$copy_root"/*) FM_TE_LABEL=copy; FM_TE_REL=${path#"$copy_root"/} ;;
    esac
  fi
  if [ -z "$FM_TE_LABEL" ] && [ -n "$tmp_root" ]; then
    case "$path" in
      "$tmp_root"/*) FM_TE_LABEL=tmp; FM_TE_REL=${path#"$tmp_root"/} ;;
    esac
  fi
  [ -n "$FM_TE_LABEL" ] || return 1
  while :; do
    case "$FM_TE_REL" in
      */) FM_TE_REL=${FM_TE_REL%/} ;;
      ./*) FM_TE_REL=${FM_TE_REL#./} ;;
      *) break ;;
    esac
  done
  [ -n "$FM_TE_REL" ] && [ "$FM_TE_REL" != . ]
}

fm_task_evidence_has_dotdot() {
  case "/$1/" in
    */../*) return 0 ;;
  esac
  return 1
}

# A clean tracked source citation is recoverable from git, unlike scratch.
# Compare actual bytes with HEAD rather than trusting diff/status, which can
# hide local edits under assume-unchanged/skip-worktree flags. Never run filters.
fm_task_evidence_recoverable_source() {
  local root=$1 rel=$2 head actual
  fm_task_evidence_has_dotdot "$rel" && return 1
  [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] || return 1
  git -C "$root" ls-files --error-unmatch -- ":(literal)$rel" >/dev/null 2>&1 || return 1
  head=$(git -C "$root" rev-parse --verify "HEAD:$rel" 2>/dev/null) || return 1
  actual=$(git -C "$root" hash-object --no-filters -- "$root/$rel" 2>/dev/null) || return 1
  [ -n "$head" ] && [ "$actual" = "$head" ]
}

# Keep readlink's significant trailing bytes until unsupported text is rejected.
# The sentinel also propagates readlink errors instead of hashing empty output.
fm_task_evidence_read_link() {
  local text
  text=$(readlink "$1" && printf '.') || return 2
  text=${text%.}
  FM_TE_LINK_TEXT=${text%$'\n'}
  case "$FM_TE_LINK_TEXT" in
    *$'\n'*) echo "REFUSED: evidence symlink $1 contains unsupported newline text" >&2; return 2 ;;
  esac
}

# Hash the link text, not the target bytes (including readlink's final newline).
fm_task_evidence_link_hash() {
  [ -L "$1" ] || return 1
  fm_task_evidence_read_link "$1" || return 1
  printf '%s\n' "$FM_TE_LINK_TEXT" | fm_task_evidence_hash /dev/stdin
}

# Capture physical directories without command substitution dropping name bytes.
fm_task_evidence_physical_dir() {
  local text
  text=$(cd -P -- "$1" 2>/dev/null && pwd -P && printf '.') || return 2
  text=${text%.}
  FM_TE_PHYSICAL=${text%$'\n'}
  case "$FM_TE_PHYSICAL" in *$'\n'*) return 2 ;; esac
  # Bash can retain // after traversing a link to /. Compare one spelling
  # only when the filesystem confirms identity, never assume // is local /.
  while [[ "$FM_TE_PHYSICAL" == //* ]]; do
    [ "$FM_TE_PHYSICAL" -ef "${FM_TE_PHYSICAL#/}" ] || return 2
    FM_TE_PHYSICAL=${FM_TE_PHYSICAL#/}
  done
}

# Resolve an existing link target without depending on GNU realpath.
# Sets FM_TE_TARGET; dangling links and cycles have no existing target.
fm_task_evidence_link_target() {
  local path=$1 stored=${2:-$1} parent target n=0
  FM_TE_TARGET=
  fm_task_evidence_read_link "$stored" || return 2
  target=$FM_TE_LINK_TEXT
  case "$target" in /*) path=$target ;; *) path="${path%/*}/$target" ;; esac
  [ -e "$path" ] || return 1
  while [ "$n" -lt 40 ]; do
    parent=${path%/*}
    fm_task_evidence_physical_dir "${parent:-/}" || return 2
    parent=$FM_TE_PHYSICAL
    path="${parent%/}/${path##*/}"
    if [ ! -L "$path" ]; then
      if [ -d "$path" ]; then
        fm_task_evidence_physical_dir "$path" || return 2
        path=$FM_TE_PHYSICAL
      fi
      FM_TE_TARGET=$path
      return 0
    fi
    fm_task_evidence_read_link "$path" || return 2
    target=$FM_TE_LINK_TEXT
    case "$target" in /*) path=$target ;; *) path="${parent%/}/$target" ;; esac
    n=$((n + 1))
  done
  echo "REFUSED: cannot resolve existing evidence link $1" >&2
  return 2
}

# Resolve ancestor directories, not a final symlink object. Unlike a lexical
# prefix, this identifies what a citation actually names through directory links.
fm_task_evidence_object() {
  local path=$1 parent=${1%/*}
  fm_task_evidence_physical_dir "${parent:-/}" || return 2
  parent=$FM_TE_PHYSICAL
  FM_TE_OBJECT="${parent%/}/${path##*/}"
  if [ -d "$FM_TE_OBJECT" ] && [ ! -L "$FM_TE_OBJECT" ]; then
    fm_task_evidence_physical_dir "$FM_TE_OBJECT" || return 2
    FM_TE_OBJECT=$FM_TE_PHYSICAL
  fi
}

# A staged member proves preservation only without following an ancestor link.
# A final link is content in its own right; its target has a separate guard.
fm_task_evidence_staged_member() {
  local path=$1 rel=$2 part
  fm_task_evidence_has_dotdot "$rel" && return 1
  while [[ "$rel" == */* ]]; do
    part=${rel%%/*}; rel=${rel#*/}
    path="$path/$part"
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
  done
  [ -e "$path/$rel" ] || [ -L "$path/$rel" ]
}

# Shared object-survival check for citations and resolved link targets.
# 0 survives, 1 uncovered, 2 resolution failure (never evidence of absence).
# Declarations are mapped by their physical object, then checked in verified
# staging without traversing links; a declared alias cannot cover its target.
fm_task_evidence_survives() {
  local path=$1 copy_root=$2 tmp_root=$3 copy_owned=$4 physical_copy=$5 physical_tmp=$6
  local declared=$7 staging=$8 object d source declaration suffix declared_end=0 covered=0
  fm_task_evidence_object "$path" || return 2
  object=$FM_TE_OBJECT
  case "$object" in
    "$physical_copy"|"$physical_tmp") ;; # A root itself is disposable too.
    *) fm_task_evidence_classify "$object" "$physical_copy" "$physical_tmp" || return 0 ;;
  esac
  if [ -n "$physical_copy" ]; then
    case "$object" in
      "$physical_copy"|"$physical_copy"/*)
        [ "$copy_owned" = 1 ] || return 0
        fm_task_evidence_recoverable_source "$physical_copy" "${object#"$physical_copy"/}" && return 0 ;;
    esac
  fi
  while fm_spool_next d declared_end; do
    [ "$covered" = 0 ] || continue
    [ -n "$d" ] || continue
    case "$d" in
      copy/*) [ "$copy_owned" = 1 ] || continue; source="$copy_root/${d#*/}" ;;
      tmp/*) source="$tmp_root/${d#*/}" ;;
      *) continue ;;
    esac
    [ -e "$source" ] || [ -L "$source" ] || continue
    fm_task_evidence_object "$source" || return 2
    declaration=$FM_TE_OBJECT
    suffix=
    if [ "$object" != "$declaration" ]; then
      [ -d "$source" ] && [ ! -L "$source" ] || continue
      case "$object" in
        "$declaration"/*) suffix=/${object#"$declaration"/} ;;
        *) continue ;;
      esac
    fi
    if fm_task_evidence_staged_member "$staging" "$d$suffix"; then covered=1; fi
  done < <(fm_spool read "$declared")
  fm_spool_end "$declared_end" "$declared" || return 2
  [ "$covered" = 1 ]
}

# Extract complete quoted citations, not a lossy prefix of a quoted filename.
# Every boundary checks longer existing prefixes, including delimiter name bytes.
# Ambiguous quotes without a longer existing entry and escapes fail closed.
fm_task_evidence_references() {
  local record=$1 root=$2 text prefix rest quote token char context previous before bad=0
  local continuation candidate extended boundary_quote
  while IFS= read -r text; do
    while [[ "$text" == *"$root/"* ]]; do
      prefix=${text%%"$root/"*}
      rest=${text#*"$root/"}
      # A path inside a larger quoted string is ambiguous (it may include
      # whitespace beyond the first token). Do not downgrade that prefix.
      quote=; context=$prefix; previous=; before=
      while [ -n "$context" ]; do
        char=${context:0:1}; context=${context:1}
        if [ "$previous" = "\\" ]; then previous=; before=$char; continue; fi
        if [ "$char" = "\\" ]; then previous=$char; before=$char; continue; fi
        case "$char" in
          "'"|'"'|'`')
            # Possessives and contractions do not begin quoted strings.
            if [ -z "$quote" ] && [ "$char" = "'" ] \
               && [[ "$before" == [[:alnum:]_] ]] && [[ "${context:0:1}" == [[:alnum:]_] ]]; then
              :
            elif [ -z "$quote" ]; then quote=$char
            elif [ "$quote" = "$char" ]; then quote=; fi ;;
        esac
        before=$char
      done
      token="$root/"; boundary_quote=0
      if [ -n "$quote" ] && [ "${prefix: -1}" != "$quote" ]; then
        echo "REFUSED: ambiguous quoted context in $record: $token$rest" >&2
        bad=1; break
      fi
      case "$quote" in
        "'"|'"'|'`')
          if [[ "$rest" != *"$quote"* ]]; then
            echo "REFUSED: ambiguous quoted evidence citation in $record: $token$rest" >&2
            bad=1; break
          fi
          token="$token${rest%%"$quote"*}"
          text=${rest#*"$quote"}
          continuation="$quote$text"
          case "$token" in
            *\\*) echo "REFUSED: ambiguous escaped evidence citation in $record: $token" >&2; bad=1; continue ;;
          esac
          ;;
        *)
          while [ -n "$rest" ]; do
            char=${rest:0:1}
            case "$char" in
              [[:space:]]|'<') break ;;
              "'"|'"'|'`') boundary_quote=1; break ;;
            esac
            token="$token$char"
            rest=${rest:1}
          done
          text=${rest:1}
          [ -n "$token" ] || continue
          case "$token" in
            *\\*) echo "REFUSED: ambiguous escaped evidence citation in $record: $token" >&2; bad=1; continue ;;
          esac
          continuation=$rest
          ;;
      esac
      # Any boundary may be a filename byte, not just whitespace. Check all
      # longer same-line prefixes without directory traversal. Emit every
      # existing interpretation for ordinary coverage checks, even when a
      # shorter one is covered. Only suppress a nonexistent short token when
      # at least one longer existing interpretation was found.
      extended=0; candidate=$token
      while [ -n "$continuation" ]; do
        candidate="$candidate${continuation:0:1}"
        continuation=${continuation:1}
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
          printf 'u\t%s\n' "$candidate"
          extended=1
        fi
      done
      if [ "$boundary_quote" = 1 ] && [ "$extended" = 0 ]; then
        echo "REFUSED: ambiguous evidence citation in $record: $token$rest" >&2
        bad=1; continue
      fi
      if [ "$extended" = 1 ]; then
        # A presentation suffix may hide an existing short interpretation too.
        # Suppress only a genuinely missing token, not that existing entry or
        # an ambiguity which must still fail closed in the ordinary scan.
        if [ -n "$quote" ]; then context=q; else context=u; fi
        if fm_task_evidence_reference_path "$token" "$context" \
           && [ ! -e "$FM_TE_REF" ] && [ ! -L "$FM_TE_REF" ]; then continue; fi
      fi
      if [ -n "$quote" ]; then printf 'q\t%s\n' "$token"; else printf 'u\t%s\n' "$token"; fi
    done
  done
  return "$bad"
}

# Prefer every exact entry before peeling presentation suffixes. Checking the
# slash-free entry also recognises dangling symlinks cited with trailing '/'.
fm_task_evidence_reference_path() {
  local path=$1 quoted=$2 next entry
  while :; do
    entry=$path
    while [[ "$entry" == */ ]]; do entry=${entry%/}; done
    if [ -e "$entry" ] || [ -L "$entry" ]; then FM_TE_REF=$entry; return; fi
    next=$(printf '%s' "$path" | sed -E \
      -e 's/&([[:alpha:]][[:alnum:]]*|#[0-9]+|#[xX][[:xdigit:]]+);$//' -e t -e 's/:[0-9]+$//')
    if [ "$next" = "$path" ]; then
      case "$path" in
        *'.'|*':'|*'!'|*'?'|*';'|*','|*')'|*']'|*'}'|*'|'|*'*'|*'>') next=${path%?} ;;
        *)
          # Interior markup could join several citations or delimit a shorter
          # existing filename. Only a quoted token proves these are name bytes.
          if [ "$quoted" != q ]; then
            case "$entry" in
              *'('*|*')'*|*'['*|*']'*|*'{'*|*'}'*|*','*|*';'*|*'|'*|*'*'*|*':'*|*'&'*|*'>'*) return 1 ;;
            esac
          fi
          FM_TE_REF=$entry; return ;;
      esac
    fi
    path=$next
  done
}

# Copy one source into staging and append its verified manifest lines.
fm_task_evidence_copy_source() {
  local src=$1 root=$2 dest=$3 key=$4 manifest=$5 src_parent root_phys odd f rel h1 h2
  local paths="$FM_TE_WORK/paths" rels="$FM_TE_WORK/rels" links="$FM_TE_WORK/source-links"
  local paths_end=0 links_end=0
  root_phys=$(cd -P -- "$root" 2>/dev/null && pwd -P) || return 1
  src_parent=$(cd -P -- "$(dirname -- "$src")" 2>/dev/null && pwd -P) || return 1
  case "$src_parent" in
    "$root_phys"|"$root_phys"/*) ;;
    *) echo "REFUSED: declared evidence $src resolves outside its root $root" >&2; return 1 ;;
  esac
  odd=$(find "$src" \( \( ! -type l ! -type f ! -type d \) -o -name '*
*' \) -print 2>/dev/null | head -1)
  if [ -n "$odd" ]; then
    echo "REFUSED: declared evidence $src contains $odd, which is not a regular file or directory" >&2
    return 1
  fi
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  cp -RPp -- "$src" "$dest" || return 1
  find "$src" -type l -print > "$links" || return 1
  fm_spool seal "$links" lines || return 1
  while fm_spool_next f links_end; do
    rel=${f#"$src"}
    echo "warning: preserving evidence symlink $f as a link, not following it" >&2
    h1=$(fm_task_evidence_link_hash "$f") && [ -n "$h1" ] || return 1
    h2=$(fm_task_evidence_link_hash "$dest$rel") && [ -n "$h2" ] || return 1
    [ "$h1" = "$h2" ] || { echo "REFUSED: copied evidence link $dest$rel does not match its source" >&2; return 1; }
    printf '%s  %s%s\n' "$h2" "$key" "$rel" >> "$manifest.links" || return 1
  done < <(fm_spool read "$links")
  fm_spool_end "$links_end" "$links" || return 1
  if [ -L "$src" ]; then
    return 0
  elif [ -d "$src" ]; then
    find "$src" -type f -print0 > "$paths" || return 1
    fm_spool seal "$paths" nul || return 1
    : > "$rels" || return 1
    while fm_spool_next f paths_end; do
      rel=${f#"$src"}
      case "$rel" in *$'\n'*) return 1 ;; esac
      printf '%s\n' "$rel" >> "$rels" || return 1
    done < <(fm_spool read "$paths")
    fm_spool_end "$paths_end" "$paths" || return 1
    fm_task_evidence_verify_copies "$manifest" "$key" "$src" "$dest" "$rels"
  else
    printf '\n' > "$rels" || return 1
    fm_task_evidence_verify_copies "$manifest" "$key" "$src" "$dest" "$rels"
  fi
}

# Carry an earlier verified copy of <key> forward into staging.
# Return 1 for unavailable/unverifiable prior evidence, 2 for staging failure.
# A foreign copy may excuse old source loss, never a failure saving valid proof.
fm_task_evidence_carry_prior() {
  local prior=$1 key=$2 staging=$3 manifest=$4 lines hash path line suffix found=0
  local regular_lines="$FM_TE_WORK/prior-regular" link_lines="$FM_TE_WORK/prior-links"
  local prior_end=0 verify_rc
  : > "$regular_lines" && : > "$link_lines" || return 2
  fm_spool seal "$regular_lines" lines && fm_spool seal "$link_lines" lines || return 2
  [ -f "$prior/MANIFEST.sha256" ] || return 1
  [ -e "$prior/$key" ] || [ -L "$prior/$key" ] || return 1
  for suffix in '' .links; do
    [ -f "$prior/MANIFEST.sha256$suffix" ] || continue
    if [ "$suffix" = .links ]; then lines=$link_lines; else lines=$regular_lines; fi
    awk -v k="$key" '{ p = substr($0, 67) } p == k || index(p, k "/") == 1' \
      "$prior/MANIFEST.sha256$suffix" > "$lines" || return 2
    fm_spool seal "$lines" lines && fm_spool_inspect "$lines" || return 2
    [ "$FM_SPOOL_NONEMPTY" = 1 ] || continue
    found=1
    if [ "$suffix" = .links ]; then
      prior_end=0
      while fm_spool_next line prior_end; do
        hash=${line%%  *}
        path=${line#*  }
        [ "$(fm_task_evidence_link_hash "$prior/$path")" = "$hash" ] || return 1
        echo "warning: preserving earlier evidence symlink $prior/$path as a link, not following it" >&2
      done < <(fm_spool read "$lines")
      fm_spool_end "$prior_end" "$lines" || return 2
    else
      verify_rc=0
      fm_task_evidence_stream verify "$prior" "$lines" || verify_rc=$?
      case "$verify_rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
    fi
  done
  [ "$found" = 1 ] || return 1
  mkdir -p -- "$(dirname -- "$staging/$key")" || return 2
  cp -RPp -- "$prior/$key" "$staging/$key" || return 2
  prior_end=0
  while fm_spool_next line prior_end; do
    printf '%s\n' "$line" >> "$manifest" || return 2
  done < <(fm_spool read "$regular_lines")
  fm_spool_end "$prior_end" "$regular_lines" || return 2
  prior_end=0
  while fm_spool_next line prior_end; do
    printf '%s\n' "$line" >> "$manifest.links" || return 2
  done < <(fm_spool read "$link_lines")
  fm_spool_end "$prior_end" "$link_lines" || return 2
  return 0
}

# fm_task_evidence_preserve <id> <data-dir> <copy-root> <copy-owned 0|1> <tmp-root> [<prepared-scan-dir>]
# The optional scan must be prepared for these same roots; its caller cleans it
# up. Without it, this wrapper prepares and cleans up its own temporary scan.
# Returns 0 when every declared path is copied and verified and no durable
# record references an existing uncovered path; prints each refusal and returns 1
# otherwise. Either root may be empty. A caller that must not hold its lock
# through the copy runs fm_task_evidence_stage and fm_task_evidence_finish itself.
fm_task_evidence_preserve() (
  # Standalone callers get the same bulk prefilter. Teardown supplies its
  # already-prepared unlocked scan; only this wrapper owns temporary storage.
  local scan=${6:-}
  trap 'fm_task_evidence_discard' EXIT
  if [ -z "$scan" ]; then
    scan=$(mktemp -d "${TMPDIR:-/tmp}/fm-evidence-scan.XXXXXX") || return 1
    trap 'fm_task_evidence_discard; rm -rf -- "$scan"' EXIT
    fm_task_evidence_scan prepare "$2/$1" "$scan" "$3" "$5" || return 1
  fi
  fm_task_evidence_scan verify "$2/$1" "$scan" || return 1
  fm_task_evidence_stage "$1" "$2" "$3" "$4" "$5" "$scan" || return 1
  fm_task_evidence_finish "$1" "$2" "$3" "$4" "$5" "$scan"
)

fm_task_evidence_stream() {
  python3 "${BASH_SOURCE[0]%/*}/fm-task-evidence-stream.py" "$@"
}

fm_task_evidence_scan() {
  perl "${BASH_SOURCE[0]%/*}/fm-task-evidence-scan.pl" "$@" || return 1
  if [ "$1" = prepare ]; then fm_spool seal "$3/matches" matches || return 1; fi
}

# fm_task_evidence_stage <id> <data-dir> <copy-root> <copy-owned 0|1> <tmp-root> <scan-dir>
# The first half of preservation, which needs no lock: snapshot each declared
# source (or carried earlier copy) into the scan, copy and verify it into
# staging, then recheck every snapshot, so the caller takes its lock right
# after the last walk. Every message it would print is held in the scan for
# fm_task_evidence_finish to print at its original place, so a caller's earlier
# refusals keep their order. Returns 1 only when it cannot record that outcome;
# the staging tree then stays for fm_task_evidence_discard.
FM_TE_STAGE_DONE=0
FM_TE_STAGE_STAGING=
fm_task_evidence_stage() {
  FM_TE_WORK=$6
  FM_TE_STAGE_DONE=0 FM_TE_STAGE_STAGING='' FM_TE_STAGE_DECLARED='' FM_TE_STAGE_REFUSED=0
  FM_TE_STAGE_ABSENT=0 FM_TE_STAGE_EARLY=0 FM_TE_STAGE_SNAPSHOTS=0 FM_TE_STAGE_CHANGED=0
  if ! { fm_task_evidence_stage_copy "$@"; } 2> "$6/stage.err"; then
    echo "REFUSED: cannot record staged task evidence for $1; nothing was changed" >&2
    return 1
  fi
  # A copy that verified when staged is kept only while every source it read
  # still equals the staged manifest baseline, rechecked here at staging's end.
  if [ -n "$FM_TE_STAGE_STAGING" ] && [ "$FM_TE_STAGE_EARLY" = 0 ] \
     && [ "$FM_TE_STAGE_REFUSED" = 0 ] \
     && ! fm_task_evidence_scan recheck "$FM_TE_STAGE_STAGING" "$6" \
       "$FM_TE_STAGE_SNAPSHOTS" 2>> "$6/stage.err"; then
    FM_TE_STAGE_CHANGED=1
  fi
  FM_TE_STAGE_ID=$1 FM_TE_STAGE_DATA=$2 FM_TE_STAGE_COPY=$3 FM_TE_STAGE_OWNED=$4
  fm_spool seal "$6/stage.err" text || return 1
  FM_TE_STAGE_TMP=$5 FM_TE_STAGE_SCAN=$6 FM_TE_STAGE_DONE=1
}

# Remove a staged tree that no finish installed and the earlier tree a finish
# replaced. Both can be as large as the copy, so a caller that holds a lock
# runs this after releasing it. Safe in an EXIT trap.
FM_TE_STAGE_REPLACED=
fm_task_evidence_discard() {
  [ -z "${FM_TE_STAGE_STAGING:-}" ] || rm -rf -- "$FM_TE_STAGE_STAGING"
  [ -z "${FM_TE_STAGE_REPLACED:-}" ] || rm -rf -- "$FM_TE_STAGE_REPLACED"
  FM_TE_STAGE_STAGING='' FM_TE_STAGE_REPLACED=''
}

# Snapshot <path> as staged key <key> before anything reads it for the copy.
fm_task_evidence_snapshot() {  # <path> <key> <scan-dir>
  fm_task_evidence_scan snapshot "$1" "$3" "$FM_TE_STAGE_SNAPSHOTS" "$2" || return 1
  FM_TE_STAGE_SNAPSHOTS=$((FM_TE_STAGE_SNAPSHOTS + 1))
}

fm_task_evidence_stage_copy() {
  local id=$1 data=$2 copy_root=$3 copy_owned=$4 tmp_root=$5 scan=$6
  local dir="$data/$id" list evidence staging manifest line path src root key
  local declared="$scan/declared" refused=0 d overlap hash rc suffix
  local list_spool="$scan/declarations" list_end=0 declared_end=0 manifest_end=0
  : > "$declared" || return 1
  fm_spool seal "$declared" lines || return 1
  if [ ! -d "$dir" ]; then FM_TE_STAGE_ABSENT=1; return 0; fi
  if ! fm_spool_inspect "$scan/matches"; then
    echo "REFUSED: evidence record scan: cannot read prepared matches; retry teardown" >&2
    FM_TE_STAGE_EARLY=1
    return 0
  fi
  copy_root=${copy_root%/}
  tmp_root=${tmp_root%/}
  list="$dir/evidence.list"
  evidence="$dir/evidence"
  if [ -f "$list" ]; then
    staging="$dir/.evidence.new.$$"
    manifest="$staging/MANIFEST.sha256"
    rm -rf -- "$staging"
    FM_TE_STAGE_STAGING=$staging
    if ! { mkdir -p -- "$staging" && : > "$manifest" && : > "$manifest.links"; }; then
      echo "REFUSED: cannot stage evidence for $id under $dir" >&2
      FM_TE_STAGE_EARLY=1
      return 0
    fi
    cat -- "$list" > "$list_spool" || return 1
    fm_spool seal "$list_spool" text || return 1
    while fm_spool_next line list_end; do
      path=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      case "$path" in ''|'#'*) continue ;; esac
      if fm_task_evidence_has_dotdot "$path"; then
        echo "REFUSED: evidence.list entry '$path' for $id contains a .. component" >&2
        refused=1; continue
      fi
      case "$path" in
        /*) ;;
        *)
          if [ -z "$copy_root" ]; then
            echo "REFUSED: evidence.list entry '$path' for $id is relative but the task records no copy" >&2
            refused=1; continue
          fi
          path="$copy_root/$path"
          ;;
      esac
      if ! fm_task_evidence_classify "$path" "$copy_root" "$tmp_root"; then
        echo "REFUSED: evidence.list entry '$path' for $id is not inside the task's copy or its own temp folder" >&2
        refused=1; continue
      fi
      key="$FM_TE_LABEL/$FM_TE_REL"
      overlap=
      declared_end=0
      while fm_spool_next d declared_end; do
        [ -z "$overlap" ] && [ -n "$d" ] || continue
        case "$key" in "$d"|"$d"/*) overlap=$d ;; esac
        case "$d" in "$key"/*) overlap=$d ;; esac
      done < <(fm_spool read "$declared")
      fm_spool_end "$declared_end" "$declared" || return 1
      if [ -n "$overlap" ]; then
        echo "REFUSED: evidence.list entry '$path' for $id overlaps another entry ($overlap); declare each path once" >&2
        refused=1; continue
      fi
      printf '%s\n' "$key" >> "$declared" || return 1
      fm_spool seal "$declared" lines || return 1
      if [ "$FM_TE_LABEL" = copy ]; then root=$copy_root; else root=$tmp_root; fi
      src="$root/$FM_TE_REL"
      if [ "$FM_TE_LABEL" = copy ] && [ "$copy_owned" != 1 ]; then
        fm_task_evidence_snapshot "$evidence/$key" "$key" "$scan" || { refused=1; continue; }
        rc=0
        fm_task_evidence_carry_prior "$evidence" "$key" "$staging" "$manifest" || rc=$?
        case "$rc" in
          0) ;;
          1) echo "warning: declared evidence $src for $id was not copied out before its pool slot was reassigned; it is lost" >&2 ;;
          *)
            echo "REFUSED: could not stage verified earlier evidence $src for $id" >&2
            refused=1 ;;
        esac
        continue
      fi
      fm_task_evidence_snapshot "$src" "$key" "$scan" || { refused=1; continue; }
      if [ -e "$src" ] || [ -L "$src" ]; then
        fm_task_evidence_copy_source "$src" "$root" "$staging/$key" "$key" "$manifest" || {
          echo "REFUSED: could not copy and verify declared evidence $src for $id" >&2
          refused=1
        }
      elif ! fm_task_evidence_snapshot "$evidence/$key" "$key" "$scan"; then
        refused=1
      elif ! fm_task_evidence_carry_prior "$evidence" "$key" "$staging" "$manifest"; then
        echo "REFUSED: declared evidence $src for $id does not exist and no verified earlier copy is preserved" >&2
        refused=1
      fi
    done < <(fm_spool read "$list_spool")
    fm_spool_end "$list_end" "$list_spool" || return 1
    if [ "$refused" = 0 ]; then
      for suffix in '' .links; do
        if ! sort -k2 -o "$manifest$suffix" "$manifest$suffix"; then
          echo "REFUSED: could not sort staged evidence manifest $manifest$suffix for $id" >&2
          refused=1
          break
        fi
        fm_spool seal "$manifest$suffix" lines || return 1
        if [ "$suffix" = .links ]; then
          manifest_end=0
          while fm_spool_next line manifest_end; do
            hash=$(fm_task_evidence_link_hash "$staging/${line#*  }")
            [ "$hash" = "${line%%  *}" ] || {
              echo "REFUSED: staged evidence ${line#*  } for $id failed verification" >&2
              refused=1
            }
          done < <(fm_spool read "$manifest$suffix")
          fm_spool_end "$manifest_end" "$manifest$suffix" || return 1
          continue
        fi
        fm_task_evidence_stream verify "$staging" "$manifest" "$id" || refused=1
      done
    fi
  fi
  FM_TE_STAGE_DECLARED=$declared
  FM_TE_STAGE_REFUSED=$refused
}

# fm_task_evidence_finish <id> <data-dir> <copy-root> <copy-owned 0|1> <tmp-root> <scan-dir>
# The second half, run under the caller's destructive lock with the arguments
# fm_task_evidence_stage was given: refuse with nothing changed when they differ,
# print the staged messages, refuse when staging's recheck found a change, and
# run the existence-aware checks and installation. It walks and removes no
# declared tree: a staged tree it did not install and the earlier tree it
# replaced stay for fm_task_evidence_discard, which a caller runs after
# releasing its lock. Returns as fm_task_evidence_preserve.
fm_task_evidence_finish() {
  local id=$1 data=$2 copy_root=$3 copy_owned=$4 tmp_root=$5 scan=$6
  local dir="$data/$id" list evidence staging manifest line root key
  local declared refused refs ref ref_mode record
  local next_record next_line record_lines scan_eof
  local matches_end=0 lines_end=0 refs_end=0 links_end=0 regular_present link_present
  local link target label rel physical_copy physical_tmp rc
  if [ "$FM_TE_STAGE_DONE" != 1 ] || [ "$FM_TE_STAGE_ID" != "$id" ] \
     || [ "$FM_TE_STAGE_DATA" != "$data" ] || [ "$FM_TE_STAGE_COPY" != "$copy_root" ] \
     || [ "$FM_TE_STAGE_OWNED" != "$copy_owned" ] || [ "$FM_TE_STAGE_TMP" != "$tmp_root" ] \
     || [ "$FM_TE_STAGE_SCAN" != "$scan" ]; then
    echo "REFUSED: task evidence inputs changed since the unlocked copy for $id; nothing was changed; retry teardown" >&2
    return 1
  fi
  FM_TE_STAGE_DONE=0
  staging=$FM_TE_STAGE_STAGING
  declared=$FM_TE_STAGE_DECLARED
  refused=$FM_TE_STAGE_REFUSED
  if ! fm_spool cat "$scan/stage.err" >&2; then
    echo "REFUSED: cannot read staged task evidence messages for $id; retry teardown" >&2
    return 1
  fi
  [ "$FM_TE_STAGE_CHANGED" = 0 ] || return 1
  [ "$FM_TE_STAGE_ABSENT" = 0 ] || return 0
  [ "$FM_TE_STAGE_EARLY" = 0 ] || return 1
  copy_root=${copy_root%/}
  tmp_root=${tmp_root%/}
  list="$dir/evidence.list"
  evidence="$dir/evidence"
  [ -z "$staging" ] || manifest="$staging/MANIFEST.sha256"

  physical_copy=$copy_root
  physical_tmp=$tmp_root
  if [ -n "$copy_root" ] && [ "$copy_owned" = 1 ]; then
    fm_task_evidence_physical_dir "$copy_root" && physical_copy=$FM_TE_PHYSICAL
  fi
  if [ -n "$tmp_root" ]; then
    fm_task_evidence_physical_dir "$tmp_root" && physical_tmp=$FM_TE_PHYSICAL
  fi

  # Check link targets only after every declaration has been staged, so list
  # order cannot hide an undeclared target or reject a later declared target.
  if [ -n "${staging:-}" ] && [ "$refused" = 0 ]; then
    while fm_spool_next line links_end; do
      key=${line#*  }
      label=${key%%/*}; rel=${key#*/}
      if [ "$label" = copy ]; then
        [ "$copy_owned" = 1 ] || continue
        link="$copy_root/$rel"
      else
        link="$tmp_root/$rel"
      fi
      rc=0
      fm_task_evidence_link_target "$link" "$staging/$key" || rc=$?
      if [ "$rc" = 2 ]; then
        echo "REFUSED: cannot resolve evidence symlink $link for $id" >&2
        refused=1; continue
      fi
      [ "$rc" = 0 ] || continue
      target=$FM_TE_TARGET
      if ! fm_task_evidence_survives "$target" "$copy_root" "$tmp_root" "$copy_owned" \
           "$physical_copy" "$physical_tmp" "$declared" "$staging"; then
        echo "REFUSED: evidence symlink $link resolves to $target, which cleanup would destroy and which evidence.list does not declare" >&2
        refused=1
      fi
    done < <(fm_spool read "$manifest.links")
    fm_spool_end "$links_end" "$manifest.links" || return 1
  fi

  # The text scan is already complete. Interpret only matching record lines;
  # existence-aware parsing and preservation still share the destructive lock.
  for root in "$copy_root" "$tmp_root"; do
    [ -n "$root" ] || continue
    record=; scan_eof=0; matches_end=0
    record_lines="$scan/record-lines"; refs="$scan/refs"
    : > "$record_lines" || return 1
    while :; do
    next_record=; next_line=
    if fm_spool_next next_record matches_end; then
      if [ -z "$next_record" ] || ! fm_spool_next next_line matches_end; then
        echo "REFUSED: evidence record scan: malformed matches framing; retry teardown" >&2
        refused=1; break
      fi
      if [ -z "$record" ] || [ "$record" = "$next_record" ]; then
        record=$next_record
        printf '%s\n' "$next_line" >> "$record_lines" || return 1
        continue
      fi
    else
      if [ -n "$next_record" ]; then
        echo "REFUSED: evidence record scan: malformed matches framing; retry teardown" >&2
        refused=1; break
      fi
      scan_eof=1
    fi
    [ -n "$record" ] || break
    # Preserve per-record parser calls, but spool both its input and output.
    # The final LF matches the former here-string's framing.
    printf '\n' >> "$record_lines" || return 1
    fm_spool seal "$record_lines" lines || return 1
    : > "$refs" || return 1
    if [ "$root" = "$copy_root" ] && [ "$copy_owned" != 1 ]; then
      lines_end=0
      while fm_spool_next line lines_end; do
        [[ "$line" == *"$root/"* ]] || continue
        echo "warning: record $record cites $line inside a copy already reassigned to another task" >&2
      done < <(fm_spool read "$record_lines")
      fm_spool_end "$lines_end" "$record_lines" || return 1
    else
      ( set -o pipefail; fm_spool cat "$record_lines" | fm_task_evidence_references "$record" "$root" ) > "$refs" || refused=1
    fi
    fm_spool seal "$refs" lines || return 1
    refs_end=0
    while fm_spool_next ref refs_end; do
      ref_mode=${ref%%$'\t'*}; ref=${ref#*$'\t'}
      fm_task_evidence_classify "$ref" "$copy_root" "$tmp_root" || continue
      if [ "$FM_TE_LABEL" = copy ] && [ "$copy_owned" != 1 ]; then
        echo "warning: a record under $dir references $ref inside a copy already reassigned to another task" >&2
        continue
      fi
      if ! fm_task_evidence_reference_path "$ref" "$ref_mode"; then
        echo "REFUSED: ambiguous unquoted evidence citation in $record: $ref" >&2
        refused=1; continue
      fi
      ref=$FM_TE_REF
      fm_task_evidence_classify "$ref" "$copy_root" "$tmp_root" || continue
      if [ ! -e "$ref" ] && [ ! -L "$ref" ]; then
        echo "warning: record $record references missing path $ref; there is nothing left to save" >&2
        continue
      fi
      if ! fm_task_evidence_survives "$ref" "$copy_root" "$tmp_root" "$copy_owned" \
           "$physical_copy" "$physical_tmp" "$declared" "${staging:-}"; then
        echo "REFUSED: a record under $dir references $ref, which cleanup would destroy and which evidence.list does not declare" >&2
        refused=1
      fi
    done < <(fm_spool read "$refs")
    fm_spool_end "$refs_end" "$refs" || return 1
    [ "$scan_eof" = 0 ] || break
    record=$next_record
    printf '%s\n' "$next_line" > "$record_lines" || return 1
    done < <(fm_spool read "$scan/matches")
    fm_spool_end "$matches_end" "$scan/matches" || return 1
  done

  fm_task_evidence_scan verify "$dir" "$scan" || refused=1
  if [ "$refused" != 0 ]; then
    echo "Declare each path in $list so cleanup copies it out, or remove the reference, then re-run." >&2
    return 1
  fi
  [ -n "${staging:-}" ] || return 0
  fm_spool_inspect "$manifest" || return 1
  regular_present=$FM_SPOOL_NONEMPTY
  fm_spool_inspect "$manifest.links" || return 1
  link_present=$FM_SPOOL_NONEMPTY
  if [ "$regular_present" = 0 ] && [ "$link_present" = 0 ] && [ ! -e "$evidence" ]; then
    return 0
  fi
  rm -f -- "$manifest.seal" "$manifest.links.seal" || return 1
  if [ -e "$evidence" ] || [ -L "$evidence" ]; then
    rm -rf -- "$dir/.evidence.old.$$"
    mv -- "$evidence" "$dir/.evidence.old.$$" || return 1
  fi
  if ! mv -- "$staging" "$evidence"; then
    [ ! -e "$dir/.evidence.old.$$" ] || mv -- "$dir/.evidence.old.$$" "$evidence"
    echo "REFUSED: could not install the verified evidence copy for $id" >&2
    return 1
  fi
  FM_TE_STAGE_STAGING=
  [ ! -e "$dir/.evidence.old.$$" ] || FM_TE_STAGE_REPLACED=$dir/.evidence.old.$$
  return 0
}
