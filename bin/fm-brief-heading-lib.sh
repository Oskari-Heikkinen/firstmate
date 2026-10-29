# shellcheck shell=bash
# Brief heading reader.
# Usage: . bin/fm-brief-heading-lib.sh
#
# This file is the single owner of how a brief's sections are read: the
# `# Task` subsections bin/fm-brief.sh scaffolds feed the no-mistakes
# `--intent` contract in bin/fm-dod-lib.sh, spawn and promotion validation,
# and the task text bin/fm-dispatch-resolve.sh sends to the router, so every
# consumer sees the same section bodies. It also owns replacing a section,
# which bin/fm-dod-lib.sh's launch-brief render uses on the Definition of done.

# The line scanner every reader below shares, so a fence or a heading means the
# same thing to each of them. fm_scan(line) sets fm_was_fenced (the line sits
# inside a fenced block, its own opening or closing fence aside), fm_is_fence
# (the line opens or closes one) and fm_level (the ATX level of an unfenced
# heading line, 0 for any other line), carrying the fence state across lines.
_FM_BRIEF_HEADING_SCAN_AWK='
  function fm_heading_level(text,    level) {
    level = 0
    while (substr(text, level + 1, 1) == "#") level++
    return level
  }
  function fm_scan(line,    scan, spaces, marker, marker_len, rest) {
    scan = line
    spaces = 0
    while (spaces < 3 && substr(scan, 1, 1) == " ") {
      scan = substr(scan, 2)
      spaces++
    }
    marker = substr(scan, 1, 1)
    marker_len = 0
    if (marker == "`" || marker == "~") {
      while (substr(scan, marker_len + 1, 1) == marker) marker_len++
    }
    fm_is_fence = marker_len >= 3
    fm_was_fenced = fenced

    if (fm_is_fence) {
      rest = substr(scan, marker_len + 1)
      if (!fenced) {
        fenced = 1
        fence_marker = marker
        fence_len = marker_len
      } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
        fenced = 0
      }
    }

    fm_level = 0
    if (!fm_is_fence && !fm_was_fenced) {
      fm_level = fm_heading_level(scan)
      if (fm_level > 0 && substr(scan, fm_level + 1, 1) !~ /^[[:space:]]?$/) fm_level = 0
    }
  }
'

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" "$_FM_BRIEF_HEADING_SCAN_AWK"'
    BEGIN { target_level = fm_heading_level(heading) }
    {
      line = $0
      fm_scan(line)

      if (!found && !fm_was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (fm_is_fence || fm_was_fenced) {
        print line
        next
      }

      if (fm_level > 0 && fm_level <= target_level) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

# Print <file> with every section under the exact unfenced <heading> whose text
# equals <old-text> replaced by <new-text>. A section is its heading line
# through the line before the next unfenced heading at the same or a higher
# level; both sides are compared without trailing blank lines, and the
# section's own trailing blank lines are kept. The texts reach awk through its
# environment, which applies no escape processing. Exits 0 when the printed
# result holds a section equal to <new-text> (replaced here or already present),
# 2 when it holds none, and 1 when <file> is not a readable regular file.
fm_brief_heading_replace() {  # <file> <heading> <old-text> <new-text>
  local file=$1 heading=$2
  [ -f "$file" ] && [ -r "$file" ] || {
    echo "error: fm_brief_heading_replace: not a readable regular file: $file" >&2
    return 1
  }
  FM_HEADING_OLD=$3 FM_HEADING_NEW=$4 awk -v heading="$heading" "$_FM_BRIEF_HEADING_SCAN_AWK"'
    function trim(text,    lines, n, m, i, out) {
      n = split(text, lines, "\n")
      m = n
      while (m > 0 && lines[m] ~ /^[[:space:]]*$/) m--
      out = ""
      for (i = 1; i <= m; i++) out = out (i > 1 ? "\n" : "") lines[i]
      return out
    }
    function flush(    m, i, text, tail) {
      if (!n) return
      m = n
      while (m > 0 && sec[m] ~ /^[[:space:]]*$/) m--
      text = ""
      for (i = 1; i <= m; i++) text = text (i > 1 ? "\n" : "") sec[i]
      tail = ""
      for (i = m + 1; i <= n; i++) tail = tail sec[i] "\n"
      if (text == old_text) {
        printf "%s\n%s", new_text, tail
        matched = 1
      } else {
        if (text == new_text) matched = 1
        printf "%s\n%s", text, tail
      }
      n = 0
    }
    BEGIN {
      target_level = fm_heading_level(heading)
      old_text = trim(ENVIRON["FM_HEADING_OLD"])
      new_text = trim(ENVIRON["FM_HEADING_NEW"])
    }
    {
      line = $0
      fm_scan(line)
      if (n && fm_level > 0 && fm_level <= target_level) flush()
      if (!n && !fm_was_fenced && line == heading) {
        sec[++n] = line
        next
      }
      if (n) {
        sec[++n] = line
        next
      }
      print line
    }
    END {
      flush()
      exit matched ? 0 : 2
    }
  ' "$file"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" body <<<"$task"
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  fm_brief_heading_parse - "$2" present >/dev/null <<<"$task"
}

