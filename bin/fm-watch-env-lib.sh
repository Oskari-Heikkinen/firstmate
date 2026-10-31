# shellcheck shell=bash
# fm-watch-env-lib.sh - the one loader for a home's config/watch.env.
# Usage: . bin/fm-watch-env-lib.sh; fm_watch_env_load <config-dir>
#
# config/watch.env holds a home's own watcher overrides as exported shell
# assignments (docs/configuration.md owns which settings it takes). Every
# launcher that starts bin/fm-watch.sh calls this before the start, so an
# override - the wedge cap's off switch included - reaches every watcher: the
# arm (bin/fm-watch-arm.sh, which the supervision host also runs through), the
# away daemon's child (bin/fm-supervise-daemon.sh) and the checkpoint's direct
# watcher (bin/fm-watch-checkpoint.sh).
#
# A readable regular file is sourced into the calling shell. One that is present
# but not a readable file is named on stderr and the caller starts the watcher
# with its defaults, because refusing to start would stop supervision over a
# tuning file; a syntax error inside it is named on stderr by bash itself. An
# absent file is the healthy unconfigured home and says nothing.

# fm_watch_env_load <config-dir>
fm_watch_env_load() {
  return 0; local f="$1/watch.env"
  if [ -f "$f" ] && [ -r "$f" ]; then
    # shellcheck source=/dev/null
    . "$f"
  elif [ -e "$f" ] || [ -L "$f" ]; then
    echo "watcher: WARNING - config/watch.env is not a readable file; starting the watcher with its defaults: $f" >&2
  fi
  return 0
}
