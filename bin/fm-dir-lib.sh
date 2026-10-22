#!/usr/bin/env bash
# fm-dir-lib.sh - fork-free directory resolution with no source-time side
# effects, for short-lived scripts that resolve their own directory on every
# run. It stays out of bin/fm-path-lib.sh because bin/fm-spawn.sh's lint source
# closure expands that file; a library inside that closure calls fm_cd_pwd_to
# only when `command -v` finds it already loaded.

# Assigns what `$(cd <directory> && pwd)` prints when no subshell is needed to
# know it: an absolute path with no empty, `.` or `..` component or newline,
# then any trailing `/..` run. Otherwise returns 1, assigning nothing.
fm_cd_pwd_to() {  # <output-variable> <directory>
  local fm_cpt_dir=$2 fm_cpt_up=0
  [ -n "${BASH_VERSION-}" ] || return 1
  case $- in *[Pr]*) return 1 ;; esac
  while [ "${fm_cpt_dir%/..}" != "$fm_cpt_dir" ]; do
    fm_cpt_dir=${fm_cpt_dir%/..}
    fm_cpt_up=$((fm_cpt_up + 1))
  done
  case $fm_cpt_dir in ''|[!/]*|*//*|*/./*|*/.|*/../*|*/|*$'\n'*) return 1 ;; esac
  # Resolving <dir>/. proves every component a directory cd may search.
  [ -d "$fm_cpt_dir/." ] || return 1
  while [ "$fm_cpt_up" -gt 0 ]; do
    fm_cpt_dir=${fm_cpt_dir%/*}
    fm_cpt_up=$((fm_cpt_up - 1))
  done
  printf -v "$1" '%s' "${fm_cpt_dir:-/}"
}
