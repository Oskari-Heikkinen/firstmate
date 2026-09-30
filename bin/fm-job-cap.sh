#!/usr/bin/env bash
# Run one heavy background job under disk-speed and memory caps.
# Usage: fm-job-cap.sh [--read RATE] [--write RATE] [--dev DEV]... [--mem-high SIZE]
#                      [--mem-max SIZE] [--swap-max SIZE] [--no-nice] [--admit] [--strict]
#                      -- <command> [args...]
#   The command runs in a transient systemd --user scope with IOReadBandwidthMax
#   and IOWriteBandwidthMax on each DEV (default: the block device backing /),
#   MemoryHigh (the kernel throttles and reclaims the job above it), MemoryMax
#   (the job is OOM-killed inside its own scope above it, never the laptop), and
#   MemorySwapMax (how much of the job may go to swap), plus nice 19 and the idle
#   IO class unless --no-nice (for test runners that refuse an outer nice).
#   RATE and SIZE are systemd values such as 40M or 6G; `infinity` lifts one cap.
#   --admit first asks bin/fm-mem-guard.sh admit with the job's MemoryMax as its
#   cost and exits 75 printing the refusal when the memory guard refuses.
#   A cap the user manager cannot apply (its io or memory controller is not
#   delegated) prints a warning naming it and the job still runs, or with
#   --strict (FM_JOB_CAP_STRICT=1) exits 3 before the command starts.
#   Without a reachable user systemd manager the job runs uncapped with a
#   warning, or with --strict exits 3.
#
# Defaults: the optional `job_cap` object of the machine admission rules file
# ${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json}, then
# FM_JOB_CAP_READ/WRITE/MEM_HIGH/MEM_MAX/SWAP_MAX, then flags; docs/configuration.md
# "Memory guard" owns the keys and built-in defaults.
# Test seams: FM_JOB_CAP_SYSTEMD_RUN (default systemd-run), FM_JOB_CAP_SYSTEMCTL
# (default systemctl).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE=${FM_ADMISSION_RULES:-$HOME/.config/fm-admission/rules.json}

read_bw=40M write_bw=40M mem_high=6G mem_max=8G swap_max=2G
if [ -f "$RULES_FILE" ] && command -v jq >/dev/null 2>&1; then
  for key in read_bw write_bw mem_high mem_max swap_max; do
    val=$(jq -r --arg k "$key" '.job_cap[$k]? // empty | select(type == "string") | select(test("^([0-9]+[KMGT]?|infinity)$"))' "$RULES_FILE" 2>/dev/null) || val=
    [ -z "$val" ] || printf -v "$key" '%s' "$val"
  done
fi
read_bw=${FM_JOB_CAP_READ:-$read_bw}
write_bw=${FM_JOB_CAP_WRITE:-$write_bw}
mem_high=${FM_JOB_CAP_MEM_HIGH:-$mem_high}
mem_max=${FM_JOB_CAP_MEM_MAX:-$mem_max}
swap_max=${FM_JOB_CAP_SWAP_MAX:-$swap_max}
strict=${FM_JOB_CAP_STRICT:-0}
nice=1 admit=0 devs=()

need() { [ $# -ge 2 ] || { echo "fm-job-cap: $1 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case $1 in
  --read) need "$@"; read_bw=$2; shift 2 ;;
  --write) need "$@"; write_bw=$2; shift 2 ;;
  --dev) need "$@"; devs+=("$2"); shift 2 ;;
  --mem-high) need "$@"; mem_high=$2; shift 2 ;;
  --mem-max) need "$@"; mem_max=$2; shift 2 ;;
  --swap-max) need "$@"; swap_max=$2; shift 2 ;;
  --no-nice) nice=0; shift ;;
  --admit) admit=1; shift ;;
  --strict) strict=1; shift ;;
  --) shift; break ;;
  -h | --help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "fm-job-cap: unknown option '$1' (see --help)" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "fm-job-cap: no command given (see --help)" >&2; exit 2; }

# size_mib <systemd size>: whole MiB, or empty for infinity.
size_mib() {
  case $1 in
  infinity) ;;
  *T) echo $((${1%T} * 1048576)) ;;
  *G) echo $((${1%G} * 1024)) ;;
  *M) echo "${1%M}" ;;
  *K) echo $((${1%K} / 1024)) ;;
  *[!0-9]*) echo "fm-job-cap: not a size: $1" >&2; exit 2 ;;
  *) echo $(($1 / 1048576)) ;;
  esac
}
cost=$(size_mib "$mem_max")
size_mib "$mem_high" >/dev/null
size_mib "$swap_max" >/dev/null

if [ "$admit" = 1 ]; then
  if ! verdict=$("$SCRIPT_DIR/fm-mem-guard.sh" admit --cost-mib "${cost:-0}"); then
    echo "fm-job-cap: $verdict" >&2
    exit 75
  fi
fi

systemd_run=${FM_JOB_CAP_SYSTEMD_RUN:-systemd-run}
if ! command -v "$systemd_run" >/dev/null 2>&1 || ! "${FM_JOB_CAP_SYSTEMCTL:-systemctl}" --user show-environment >/dev/null 2>&1; then
  echo "fm-job-cap: WARNING no user systemd manager, so no disk or memory cap is applied" >&2
  [ "$strict" = 1 ] && { echo "fm-job-cap: refusing (--strict)" >&2; exit 3; }
  if [ "$nice" = 1 ]; then exec nice -n 19 ionice -c3 "$@"; fi
  exec "$@"
fi

[ ${#devs[@]} -gt 0 ] || devs=("$(findmnt -no SOURCE /)")
props=(-p "MemoryHigh=$mem_high" -p "MemoryMax=$mem_max" -p "MemorySwapMax=$swap_max")
for d in "${devs[@]}"; do
  [ -b "$d" ] || { echo "fm-job-cap: not a block device: $d" >&2; exit 2; }
  props+=(-p "IOReadBandwidthMax=$d $read_bw" -p "IOWriteBandwidthMax=$d $write_bw")
done
# shellcheck disable=SC2016 # the inner script runs in the scope's own bash
exec "$systemd_run" --user --scope --quiet --collect "${props[@]}" -- \
  bash -c '
    cg=$(cut -d: -f3 /proc/self/cgroup)
    missing=
    [ -e "/sys/fs/cgroup$cg/io.max" ] || missing="disk-speed"
    [ -e "/sys/fs/cgroup$cg/memory.max" ] || missing="${missing:+$missing and }memory"
    if [ -n "$missing" ]; then
      echo "fm-job-cap: WARNING $missing cap NOT applied (controller not delegated to the user manager)" >&2
      [ "$1" = 1 ] && { echo "fm-job-cap: refusing (--strict)" >&2; exit 3; }
    fi
    nice=$2
    shift 2
    if [ "$nice" = 1 ]; then exec nice -n 19 ionice -c3 "$@"; fi
    exec "$@"' fm-job-cap "$strict" "$nice" "$@"
