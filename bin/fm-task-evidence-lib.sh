#!/usr/bin/env bash
# Task evidence preservation: the one owner of how a task declares evidence
# that lives inside its disposable copy or its per-task temp folder, how that
# evidence is copied out before cleanup returns or removes those places, and
# when cleanup must refuse because a durable record still points into them.
# bin/fm-teardown.sh calls fm_task_evidence_preserve before any destructive
# step; the declaration contract below is the only place it is stated.
#
# Declaration: data/<id>/evidence.list, one path per line; blank lines and
# lines starting with # are ignored. A relative path names a file or directory
# inside the task's copy. An absolute path must name one inside the task's copy
# or inside its recorded tasktmp folder; anything else is refused. No path may
# contain a `..` component, be a symlink, or contain a symlink or any entry
# that is not a regular file or directory, because the copy must be a faithful
# standalone snapshot.
#
# Copy-out: each declared path is copied to data/<id>/evidence/copy/<rel> (from
# the copy) or data/<id>/evidence/tmp/<rel> (from the tasktmp folder), and every
# copied regular file is listed in data/<id>/evidence/MANIFEST.sha256 in
# sha256sum format, so `cd data/<id>/evidence && sha256sum -c MANIFEST.sha256`
# re-verifies it later. The new evidence tree is built in a staging directory,
# each copied file's hash is compared with its source's, and only a verified
# tree replaces the previous one. A declared path whose source is gone (a
# retried cleanup after the copy was already returned) keeps its earlier copy
# when that copy still verifies against the earlier manifest; otherwise the
# declaration refuses, naming the path.
#
# Dangling references: every text file under data/<id>/ other than the
# evidence tree is scanned for absolute paths strictly inside the copy or the
# tasktmp folder; a :line or :line:column citation suffix is stripped first.
# A referenced path is covered when it equals, or lies under, a declared path
# of the same root. An undeclared regular file in the copy is also recoverable
# when git tracks it and its bytes match the HEAD blob (without clean filters);
# ignored, untracked, modified, and temp-folder paths receive no exemption.
# Any uncovered reference refuses cleanup and is named, so a report can never
# keep citing a scratch file cleanup is about
# to destroy. Declare the path in evidence.list or remove the reference, then
# re-run. --force does not lift either refusal: it authorizes discarding
# unlanded work, never silently orphaning a durable record's evidence.
#
# A copy whose pool slot was already reassigned to another task (teardown's
# slot-owner claim) is no longer this task's: its contents are gone, reading
# it would read another task's work, and refusing could save nothing, so
# declarations and references into it only warn. Its earlier verified copy is
# still carried forward.

fm_task_evidence_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_task_evidence_ere_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'
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

# Copy one source into staging and append its verified manifest lines.
fm_task_evidence_copy_source() {
  local src=$1 root=$2 dest=$3 key=$4 manifest=$5 src_parent root_phys odd f rel h1 h2
  root_phys=$(cd -P -- "$root" 2>/dev/null && pwd -P) || return 1
  src_parent=$(cd -P -- "$(dirname -- "$src")" 2>/dev/null && pwd -P) || return 1
  case "$src_parent" in
    "$root_phys"|"$root_phys"/*) ;;
    *) echo "REFUSED: declared evidence $src resolves outside its root $root" >&2; return 1 ;;
  esac
  odd=$(find "$src" \( -type l -o \( ! -type f ! -type d \) -o -name '*
*' \) -print 2>/dev/null | head -1)
  if [ -n "$odd" ]; then
    echo "REFUSED: declared evidence $src contains $odd, which is not a regular file or directory" >&2
    return 1
  fi
  mkdir -p -- "$(dirname -- "$dest")" || return 1
  cp -Rp -- "$src" "$dest" || return 1
  if [ -d "$src" ]; then
    while IFS= read -r f; do
      rel=${f#"$src"}
      h1=$(fm_task_evidence_hash "$f") && [ -n "$h1" ] || return 1
      h2=$(fm_task_evidence_hash "$dest$rel") && [ -n "$h2" ] || return 1
      [ "$h1" = "$h2" ] || { echo "REFUSED: copied evidence $dest$rel does not match its source" >&2; return 1; }
      printf '%s  %s%s\n' "$h2" "$key" "$rel" >> "$manifest"
    done < <(find "$src" -type f -print)
  else
    h1=$(fm_task_evidence_hash "$src") && [ -n "$h1" ] || return 1
    h2=$(fm_task_evidence_hash "$dest") && [ -n "$h2" ] || return 1
    [ "$h1" = "$h2" ] || { echo "REFUSED: copied evidence $dest does not match its source" >&2; return 1; }
    printf '%s  %s\n' "$h2" "$key" >> "$manifest"
  fi
}

# Carry an earlier verified copy of <key> forward into staging.
fm_task_evidence_carry_prior() {
  local prior=$1 key=$2 staging=$3 manifest=$4 lines hash path
  [ -f "$prior/MANIFEST.sha256" ] && [ -e "$prior/$key" ] || return 1
  lines=$(awk -v k="$key" '{ p = substr($0, 67) } p == k || index(p, k "/") == 1' "$prior/MANIFEST.sha256")
  [ -n "$lines" ] || return 1
  while IFS= read -r line; do
    hash=${line%%  *}
    path=${line#*  }
    [ "$(fm_task_evidence_hash "$prior/$path")" = "$hash" ] || return 1
  done <<< "$lines"
  mkdir -p -- "$(dirname -- "$staging/$key")" || return 1
  cp -Rp -- "$prior/$key" "$staging/$key" || return 1
  printf '%s\n' "$lines" >> "$manifest"
}

# fm_task_evidence_preserve <id> <data-dir> <copy-root> <copy-owned 0|1> <tmp-root>
# Returns 0 when every declared path is copied and verified and no durable
# record references an uncovered path; prints each refusal and returns 1
# otherwise. Either root may be empty.
fm_task_evidence_preserve() {
  local id=$1 data=$2 copy_root=$3 copy_owned=$4 tmp_root=$5
  local dir="$data/$id" list evidence staging manifest line path src root key
  local declared='' refused=0 refs ref covered d escaped pattern overlap
  [ -d "$dir" ] || return 0
  copy_root=${copy_root%/}
  tmp_root=${tmp_root%/}
  list="$dir/evidence.list"
  evidence="$dir/evidence"
  if [ -f "$list" ]; then
    staging="$dir/.evidence.new.$$"
    manifest="$staging/MANIFEST.sha256"
    rm -rf -- "$staging"
    if ! { mkdir -p -- "$staging" && : > "$manifest"; }; then
      echo "REFUSED: cannot stage evidence for $id under $dir" >&2
      return 1
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
        fm_task_evidence_carry_prior "$evidence" "$key" "$staging" "$manifest" \
          || echo "warning: declared evidence $src for $id was not copied out before its pool slot was reassigned; it is lost" >&2
        continue
      fi
      if [ -L "$src" ]; then
        echo "REFUSED: declared evidence $src for $id is a symlink" >&2
        refused=1; continue
      fi
      if [ -e "$src" ]; then
        fm_task_evidence_copy_source "$src" "$root" "$staging/$key" "$key" "$manifest" || {
          echo "REFUSED: could not copy and verify declared evidence $src for $id" >&2
          refused=1
        }
      elif ! fm_task_evidence_carry_prior "$evidence" "$key" "$staging" "$manifest"; then
        echo "REFUSED: declared evidence $src for $id does not exist and no verified earlier copy is preserved" >&2
        refused=1
      fi
    done < "$list"
    if [ "$refused" = 0 ]; then
      sort -k2 -o "$manifest" "$manifest"
      while IFS= read -r line; do
        [ "$(fm_task_evidence_hash "$staging/${line#*  }")" = "${line%%  *}" ] || {
          echo "REFUSED: staged evidence ${line#*  } for $id failed verification" >&2
          refused=1
        }
      done < "$manifest"
    fi
  fi

  # Reference scan over every durable text record except the evidence tree.
  for root in "$copy_root" "$tmp_root"; do
    [ -n "$root" ] || continue
    escaped=$(fm_task_evidence_ere_escape "$root")
    # Include a terminating semicolon only to recognise a complete HTML entity.
    pattern="$escaped/[^][[:space:]'\"\`<>(){}|;,*]+;?"
    refs=$(find "$dir" \( -path "$dir/evidence" -o -path "$dir/.evidence.*" \) -prune \
        -o -type f -print0 2>/dev/null \
      | xargs -0 grep -IhoE -- "$pattern" /dev/null 2>/dev/null \
      | sed -E 's/&([[:alpha:]][[:alnum:]]*|#[0-9]+|#[xX][[:xdigit:]]+);$//; s/;$//; s/[.:!?]*$//; s/:[0-9]+(:[0-9]+)?$//' | sort -u || true)
    [ -n "$refs" ] || continue
    while IFS= read -r ref; do
      fm_task_evidence_classify "$ref" "$copy_root" "$tmp_root" || continue
      if [ "$FM_TE_LABEL" = copy ] && [ "$copy_owned" != 1 ]; then
        echo "warning: a record under $dir references $ref inside a copy already reassigned to another task" >&2
        continue
      fi
      if [ "$FM_TE_LABEL" = copy ] \
         && fm_task_evidence_recoverable_source "$copy_root" "$FM_TE_REL"; then
        continue
      fi
      covered=0
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$FM_TE_LABEL/$FM_TE_REL" in
          "$d"|"$d"/*) covered=1; break ;;
        esac
      done <<< "$declared"
      if [ "$covered" = 0 ]; then
        echo "REFUSED: a record under $dir references $ref, which cleanup would destroy and which evidence.list does not declare" >&2
        refused=1
      fi
    done <<< "$refs"
  done

  if [ "$refused" != 0 ]; then
    [ -z "${staging:-}" ] || rm -rf -- "$staging"
    echo "Declare each path in $list so cleanup copies it out, or remove the reference, then re-run." >&2
    return 1
  fi
  [ -n "${staging:-}" ] || return 0
  if [ ! -s "$manifest" ] && [ ! -e "$evidence" ]; then
    rm -rf -- "$staging"
    return 0
  fi
  if [ -e "$evidence" ] || [ -L "$evidence" ]; then
    rm -rf -- "$dir/.evidence.old.$$"
    mv -- "$evidence" "$dir/.evidence.old.$$" || { rm -rf -- "$staging"; return 1; }
  fi
  if ! mv -- "$staging" "$evidence"; then
    [ ! -e "$dir/.evidence.old.$$" ] || mv -- "$dir/.evidence.old.$$" "$evidence"
    echo "REFUSED: could not install the verified evidence copy for $id" >&2
    return 1
  fi
  rm -rf -- "$dir/.evidence.old.$$"
  return 0
}
