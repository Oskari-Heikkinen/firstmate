#!/usr/bin/env bash
# fm-unit-file-lib.sh - write values into a systemd user unit that install-timer
# commands generate, with no source-time side effects.
#
# A unit started by the user manager gets the manager's environment, not the
# installing shell's, so a tool the scan needs from a per-user directory such
# as ~/.local/npm/bin is not found unless the unit carries PATH itself.

# fm_unit_safe_path PATH: true when PATH is absolute and holds only characters
# a unit line can carry verbatim (ExecStart= arguments, unquoted values).
fm_unit_safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/@+-]+$ ]]; }

# fm_unit_env NAME VALUE: print one quoted Environment= line, escaped for a unit
# file (backslash, double quote, and % as a specifier). A value with a newline
# cannot be carried: it prints nothing and returns 1, so the caller refuses with
# its own prefixed diagnostic.
fm_unit_env() {
  local value=$2
  case "$value" in *$'\n'*) return 1 ;; esac
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  printf 'Environment="%s=%s"\n' "$1" "$value"
}
