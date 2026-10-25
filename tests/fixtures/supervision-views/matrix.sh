#!/usr/bin/env bash
# CI-only selection/aggregation for existing drain/snapshot behavior cases.
# Sourced by those suites; never selects native clients without explicit opt-in.

fm_view_matrix_enable() {
  VIEW_MATRIX_PYTHON=$(command -v python3) || fail 'native view matrix requires Python 3.9+'
  export FM_VIEW_COMPAT_MATRIX_ROOT="$TMP_ROOT"
  export FM_VIEW_COMPAT_MATRIX_HELPER="$ROOT/tests/fixtures/supervision-views/view_matrix.py"
  mkdir -p "$TMP_ROOT/.view-matrix-metrics"
}

fm_view_matrix_wrapper() {  # <snapshot|view|drain> -> executable path
  local selector=$1 wrapper="$TMP_ROOT/.native-$1"
  case "$selector" in snapshot|view|drain) ;; *) fail 'invalid native matrix selector' ;; esac
  {
    printf '#!%s\n' "$VIEW_MATRIX_PYTHON"
    printf '%s\n' 'import os, runpy, sys'
    printf 'sys.argv.insert(1, "%s")\n' "$selector"
    printf '%s\n' 'runpy.run_path(os.environ["FM_VIEW_COMPAT_MATRIX_HELPER"], run_name="__main__")'
  } > "$wrapper"
  chmod +x "$wrapper"
  printf '%s\n' "$wrapper"
}

# A native matrix collects every independent case after failures. The default
# legacy suite retains its original caller/exit semantics and assertions.
fm_view_matrix_case() {
  if [ "${FM_VIEW_COMPAT_MATRIX:-0}" = 1 ]; then
    ( "$@" ) || view_matrix_rc=1
  else
    "$@"
  fi
}

fm_view_matrix_finish() {
  if [ "${FM_VIEW_COMPAT_MATRIX:-0}" = 1 ]; then
    "$VIEW_MATRIX_PYTHON" "$FM_VIEW_COMPAT_MATRIX_HELPER" --summary || view_matrix_rc=1
  fi
  return "$view_matrix_rc"
}
