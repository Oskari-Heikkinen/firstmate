#!/usr/bin/env bash
# Shared home-summary failure pacing for the publisher and watcher.
# Call after loading fm-wake-lib.sh (mtime and epoch readers).
# The refresh executable owns the durable marker and owed-request contract.

# fm_home_summary_retry_due <state> <interval-seconds>
# Missing marker means the preceding attempt succeeded (or none has run).
# A backward clock holds retries until a full interval after the saved start.
fm_home_summary_retry_due() {
  local started now
  [ -e "$1/.home-summary-refresh.attempt" ] || return 0
  fm_path_mtime_to started "$1/.home-summary-refresh.attempt" || return 1
  fm_epoch_seconds_to now
  [ "$(( now - started ))" -ge "$2" ]
}
