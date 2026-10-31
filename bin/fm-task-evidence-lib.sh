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
# every walk, rehashes each file modified within a few seconds of its snapshot,
# and refuses with nothing changed when any member was added, removed,
# replaced, retargeted or edited since (bin/fm-task-evidence-scan.pl owns the
# comparison). No walk of a declared tree runs at finishing, so a caller's lock
# hold does not grow with the tree; finishing refuses when its inputs differ
# from staging's. Every other check and refusal below runs at finishing, in the
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

# Hash every path in FM_TE_PATHS with one NUL-delimited batch of that tool and
# set FM_TE_HASHES to each line's first field, in order, as
# fm_task_evidence_hash prints it. Unless the batch exits 0 with one non-empty
# hash per path, leave FM_TE_HASHES empty and return 1, so
# fm_task_evidence_hash_at hashes each path alone and every refusal keeps its
# per-file order, message and early stop.
fm_task_evidence_hash_paths() {
  local line hash batch want=${#FM_TE_PATHS[@]}
  local out=()
  FM_TE_HASHES=()
  [ "$want" -gt 0 ] && fm_task_evidence_hash_tool || return 1
  if [ "$FM_TE_HASH_TOOL" = shasum ]; then set -- shasum -a 256; else set -- sha256sum; fi
  # The batch's exit status follows its output as one final line. Capture it
  # whole: read from a pipe costs one system call per byte.
  { batch=$(printf '%s\0' "${FM_TE_PATHS[@]}" | xargs -0 "$@" 2>/dev/null; printf '%s\n' "$?"); } 2>/dev/null
  while IFS= read -r line; do
    out+=("$line")
  done <<< "$batch"
  [ "${#out[@]}" = $((want + 1)) ] && [ "${out[want]}" = 0 ] || return 1
  for line in "${out[@]:0:want}"; do
    line=${line#"${line%%[![:blank:]]*}"}
    hash=${line%%[[:blank:]]*}
    [ -n "$hash" ] || { FM_TE_HASHES=(); return 1; }
    FM_TE_HASHES+=("$hash")
  done
}

# Set FM_TE_HASH to the hash of FM_TE_PATHS[<index>]: the batch's when
# fm_task_evidence_hash_paths succeeded, otherwise fm_task_evidence_hash's,
# whose status it returns.
fm_task_evidence_hash_at() {
  if [ "${#FM_TE_HASHES[@]}" -gt 0 ]; then
    FM_TE_HASH=${FM_TE_HASHES[$1]}
  else
    FM_TE_HASH=$(fm_task_evidence_hash "${FM_TE_PATHS[$1]}")
  fi
}

# Read sha256sum-format manifest lines on stdin into FM_TE_EXPECT (hash),
# FM_TE_RELS (name) and FM_TE_PATHS (<dir>/<name>), then batch their hashes.
fm_task_evidence_load_hashes() {
  local line
  FM_TE_PATHS=(); FM_TE_RELS=(); FM_TE_EXPECT=()
  while IFS= read -r line; do
    FM_TE_EXPECT+=("${line%%  *}")
    FM_TE_RELS+=("${line#*  }")
    FM_TE_PATHS+=("$1/${line#*  }")
  done
  fm_task_evidence_hash_paths || :
}

# Compare the sources in FM_TE_PATHS' first half with their copies in its
# second half and append each copy's manifest line, <hash>  <key><rel>, with
# <rel> from FM_TE_RELS.
fm_task_evidence_verify_copies() {
  local manifest=$1 key=$2 n=${#FM_TE_RELS[@]} i h1
  fm_task_evidence_hash_paths || :
  for ((i = 0; i < n; i++)); do
    # A name that gained a newline after the scan refuses at its place.
    case "${FM_TE_RELS[i]}" in *$'\n'*) return 1 ;; esac
    fm_task_evidence_hash_at "$i" && h1=$FM_TE_HASH && [ -n "$h1" ] || return 1
    fm_task_evidence_hash_at $((n + i)) && [ -n "$FM_TE_HASH" ] || return 1
    [ "$h1" = "$FM_TE_HASH" ] || {
      echo "REFUSED: copied evidence ${FM_TE_PATHS[n + i]} does not match its source" >&2
      return 1
    }
    printf '%s  %s%s\n' "$FM_TE_HASH" "$key" "${FM_TE_RELS[i]}" >> "$manifest" || return 1
  done
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
  local declared=$7 staging=$8 object d source declaration suffix
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
  while IFS= read -r d; do
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
    fm_task_evidence_staged_member "$staging" "$d$suffix" && return 0
  done <<< "$declared"
  return 1
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
  local src=$1 root=$2 dest=$3 key=$4 manifest=$5 src_parent root_phys odd f rel h1 h2 i n
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
  while IFS= read -r f; do
    rel=${f#"$src"}
    echo "warning: preserving evidence symlink $f as a link, not following it" >&2
    h1=$(fm_task_evidence_link_hash "$f") && [ -n "$h1" ] || return 1
    h2=$(fm_task_evidence_link_hash "$dest$rel") && [ -n "$h2" ] || return 1
    [ "$h1" = "$h2" ] || { echo "REFUSED: copied evidence link $dest$rel does not match its source" >&2; return 1; }
    printf '%s  %s%s\n' "$h2" "$key" "$rel" >> "$manifest.links" || return 1
  done < <(find "$src" -type l -print)
  if [ -L "$src" ]; then
    return 0
  elif [ -d "$src" ]; then
    FM_TE_PATHS=(); FM_TE_RELS=()
    while IFS= read -r -d '' f; do
      FM_TE_PATHS+=("$f")
      FM_TE_RELS+=("${f#"$src"}")
    done < <(find "$src" -type f -print0)
    n=${#FM_TE_RELS[@]}
    for ((i = 0; i < n; i++)); do
      FM_TE_PATHS+=("$dest${FM_TE_RELS[i]}")
    done
    fm_task_evidence_verify_copies "$manifest" "$key"
  else
    FM_TE_PATHS=("$src" "$dest"); FM_TE_RELS=('')
    fm_task_evidence_verify_copies "$manifest" "$key"
  fi
}

# Carry an earlier verified copy of <key> forward into staging.
# Return 1 for unavailable/unverifiable prior evidence, 2 for staging failure.
# A foreign copy may excuse old source loss, never a failure saving valid proof.
fm_task_evidence_carry_prior() {
  local prior=$1 key=$2 staging=$3 manifest=$4 lines hash path line suffix i found=0
  local regular_lines='' link_lines=''
  [ -f "$prior/MANIFEST.sha256" ] || return 1
  [ -e "$prior/$key" ] || [ -L "$prior/$key" ] || return 1
  for suffix in '' .links; do
    [ -f "$prior/MANIFEST.sha256$suffix" ] || continue
    lines=$(awk -v k="$key" '{ p = substr($0, 67) } p == k || index(p, k "/") == 1' "$prior/MANIFEST.sha256$suffix")
    [ -n "$lines" ] || continue
    found=1
    if [ "$suffix" = .links ]; then
      while IFS= read -r line; do
        hash=${line%%  *}
        path=${line#*  }
        [ "$(fm_task_evidence_link_hash "$prior/$path")" = "$hash" ] || return 1
        echo "warning: preserving earlier evidence symlink $prior/$path as a link, not following it" >&2
      done <<< "$lines"
      link_lines=$lines
    else
      fm_task_evidence_load_hashes "$prior" <<< "$lines"
      for ((i = 0; i < ${#FM_TE_RELS[@]}; i++)); do
        fm_task_evidence_hash_at "$i" || :
        [ "$FM_TE_HASH" = "${FM_TE_EXPECT[i]}" ] || return 1
      done
      regular_lines=$lines
    fi
  done
  [ "$found" = 1 ] || return 1
  mkdir -p -- "$(dirname -- "$staging/$key")" || return 2
  cp -RPp -- "$prior/$key" "$staging/$key" || return 2
  [ -z "$regular_lines" ] || printf '%s\n' "$regular_lines" >> "$manifest" || return 2
  [ -z "$link_lines" ] || printf '%s\n' "$link_lines" >> "$manifest.links" || return 2
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

fm_task_evidence_scan() {
  perl "${BASH_SOURCE[0]%/*}/fm-task-evidence-scan.pl" "$@"
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
  FM_TE_STAGE_DONE=0 FM_TE_STAGE_STAGING='' FM_TE_STAGE_DECLARED='' FM_TE_STAGE_REFUSED=0
  FM_TE_STAGE_ABSENT=0 FM_TE_STAGE_EARLY=0 FM_TE_STAGE_SNAPSHOTS=0 FM_TE_STAGE_CHANGED=0
  if ! { fm_task_evidence_stage_copy "$@"; } 2> "$6/stage.err"; then
    echo "REFUSED: cannot record staged task evidence for $1; nothing was changed" >&2
    return 1
  fi
  # A copy that verified when staged is still the source's only while nothing
  # it read has changed since its snapshot.
  if [ -n "$FM_TE_STAGE_STAGING" ] && [ "$FM_TE_STAGE_EARLY" = 0 ] \
     && [ "$FM_TE_STAGE_REFUSED" = 0 ] \
     && ! fm_task_evidence_scan recheck "$FM_TE_STAGE_STAGING" "$6" \
       "$FM_TE_STAGE_SNAPSHOTS" 2>> "$6/stage.err"; then
    FM_TE_STAGE_CHANGED=1
  fi
  FM_TE_STAGE_ID=$1 FM_TE_STAGE_DATA=$2 FM_TE_STAGE_COPY=$3 FM_TE_STAGE_OWNED=$4
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
  local declared='' refused=0 d overlap hash rc i suffix
  if [ ! -d "$dir" ]; then FM_TE_STAGE_ABSENT=1; return 0; fi
  if [ ! -r "$scan/matches" ]; then
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
    while IFS= read -r line || [ -n "$line" ]; do
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
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$key" in "$d"|"$d"/*) overlap=$d; break ;; esac
        case "$d" in "$key"/*) overlap=$d; break ;; esac
      done <<< "$declared"
      if [ -n "$overlap" ]; then
        echo "REFUSED: evidence.list entry '$path' for $id overlaps another entry ($overlap); declare each path once" >&2
        refused=1; continue
      fi
      declared="$declared$key
"
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
    done < "$list"
    if [ "$refused" = 0 ]; then
      for suffix in '' .links; do
        if ! sort -k2 -o "$manifest$suffix" "$manifest$suffix"; then
          echo "REFUSED: could not sort staged evidence manifest $manifest$suffix for $id" >&2
          refused=1
          break
        fi
        if [ "$suffix" = .links ]; then
          while IFS= read -r line; do
            hash=$(fm_task_evidence_link_hash "$staging/${line#*  }")
            [ "$hash" = "${line%%  *}" ] || {
              echo "REFUSED: staged evidence ${line#*  } for $id failed verification" >&2
              refused=1
            }
          done < "$manifest$suffix"
          continue
        fi
        fm_task_evidence_load_hashes "$staging" < "$manifest"
        for ((i = 0; i < ${#FM_TE_RELS[@]}; i++)); do
          fm_task_evidence_hash_at "$i" || :
          [ "$FM_TE_HASH" = "${FM_TE_EXPECT[i]}" ] || {
            echo "REFUSED: staged evidence ${FM_TE_RELS[i]} for $id failed verification" >&2
            refused=1
          }
        done
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
  if [ ! -f "$scan/stage.err" ] || ! cat -- "$scan/stage.err" >&2; then
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
    while IFS= read -r line; do
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
    done < "$manifest.links"
  fi

  # The text scan is already complete. Interpret only matching record lines;
  # existence-aware parsing and preservation still share the destructive lock.
  for root in "$copy_root" "$tmp_root"; do
    [ -n "$root" ] || continue
    record=; record_lines=; scan_eof=0
    while :; do
    next_record=; next_line=
    if IFS= read -r -d '' next_record; then
      if [ -z "$next_record" ] || ! IFS= read -r next_line; then
        echo "REFUSED: evidence record scan: malformed matches framing; retry teardown" >&2
        refused=1; break
      fi
      if [ -z "$record" ] || [ "$record" = "$next_record" ]; then
        record=$next_record
        record_lines+="$next_line"$'\n'
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
    # One parser call per consecutive record group, as in the old per-record
    # scan. Keep foreign-slot warnings per matching line without statting it.
    refs=
    if [ "$root" = "$copy_root" ] && [ "$copy_owned" != 1 ]; then
      while IFS= read -r line; do
        [[ "$line" == *"$root/"* ]] || continue
        echo "warning: record $record cites $line inside a copy already reassigned to another task" >&2
      done <<< "$record_lines"
    else
      refs=$(fm_task_evidence_references "$record" "$root" <<< "$record_lines") || refused=1
    fi
    if [ -n "$refs" ]; then
    while IFS= read -r ref; do
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
    done <<< "$refs"
    fi
    [ "$scan_eof" = 0 ] || break
    record=$next_record
    record_lines="$next_line"$'\n'
    done < "$scan/matches"
  done

  fm_task_evidence_scan verify "$dir" "$scan" || refused=1
  if [ "$refused" != 0 ]; then
    echo "Declare each path in $list so cleanup copies it out, or remove the reference, then re-run." >&2
    return 1
  fi
  [ -n "${staging:-}" ] || return 0
  if [ ! -s "$manifest" ] && [ ! -s "$manifest.links" ] && [ ! -e "$evidence" ]; then
    return 0
  fi
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
