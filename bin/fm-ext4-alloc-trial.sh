#!/usr/bin/env bash
# fm-ext4-alloc-trial.sh - measure how ext4 allocator settings change the
# growth of fragmented free space, on a scratch loop image and never on a live
# filesystem. docs/disk-room.md "Allocator settings" owns what the result means
# and what may follow from it; this header owns the mechanics.
#
# For each setting it makes a fresh ext4 image in DIR, attaches it to a loop
# device, mounts it there (discard,relatime, like the WSL root), writes the
# setting's values into that loop device's own /sys/fs/ext4/<loop>/ files, and
# replays a seeded workload for ROUNDS rounds: long-lived small files (.json,
# .jsonl, .gz and .py sizes) interleaved with short-lived files CHURN times
# their volume that are deleted, appending logs, and atomic-rename rewrites of
# a few hundred state-like files. After each round it syncs and reads
# /proc/fs/ext4/<loop>/mb_groups through `fm-disk-room.sh mb-groups`, the one
# mb_groups parser. Then it unmounts, detaches and deletes the image.
#
# Usage:
#   fm-ext4-alloc-trial.sh run --dir DIR [--size SIZE] [--rounds N]
#                              [--volume SIZE] [--churn N] [--jobs N]
#                              [--seed N] [--settings LIST] [--results FILE]
#       Root only, run by the operator. DIR must be an existing, empty, real
#       directory given as a plain absolute path (no //, . or ..); it is
#       refused when it is or resolves to /, to anything on /mnt, to a
#       system directory (/proc /sys /dev /run /boot /etc /usr /bin /sbin
#       /lib /lib64 /root /home) or to a network, 9p or FUSE filesystem;
#       these refusals happen before the root check. Then, as root, DIR and
#       the directory that will hold FILE must belong to root and be writable
#       by no one else, and every directory above them, as given and as
#       resolved, must belong to root and be writable by no one else or be
#       sticky, so no other user can swap either path while root uses it.
#       The trial creates only DIR/trial.img and DIR/mnt and removes both on
#       every exit path (EXIT, INT, TERM and HUP): it stops the workload,
#       unmounts (retrying, then lazily), detaches every loop device backing
#       that image, deletes it, and removes the mount point. A SIGKILL leaves
#       them behind, and the next run refuses the non-empty DIR until the
#       operator removes them.
#       LIST is space-separated settings; each is `default` (the kernel's
#       values) or KEY=VALUE[,KEY=VALUE...] with KEY an mb_* file in the
#       loop device's /sys/fs/ext4/<loop>/ directory and VALUE a whole number
#       (default: "default mb_group_prealloc=64 mb_group_prealloc=16
#       mb_group_prealloc=0 mb_stream_req=64"). A value the kernel refuses or
#       does not read back marks that setting failed, and the others still run.
#       SIZE (default 8G) is the image's length; the image is sparse and
#       mounted with discard, so DIR's filesystem needs that much free only at
#       worst: it waits (exit 75) when it has less. On the WSL Linux disk,
#       admit it as docs/disk-room.md "Allocator settings" shows.
#       VOLUME (default 128M) is the long-lived bytes each round writes,
#       CHURN (default 15) the short-lived bytes per long-lived byte, JOBS
#       (default 4) the parallel writers, SEED (default 1) the random seed.
#       The workload runs at nice 19 and best-effort I/O priority 7, not the
#       idle class, because idle I/O can starve and the time column must stay
#       comparable between settings.
#       Prints one progress line per round on stderr and the table on stdout.
#       --results also keeps the raw readings in FILE, an absolute path
#       outside DIR that must not exist; it is created without clobbering.
#       Exit 0 when every setting ran, 1 when a setting or reading failed (the
#       table still prints), 2 on misuse or refusal, 75 when DIR lacks room.
#   fm-ext4-alloc-trial.sh table [FILE|-]
#       Print the table for a results file: per setting, fragmented GiB after
#       each round (round 0 is the fresh filesystem), its growth and the ratio
#       to the default's growth, used GiB, allocation seconds (write and sync)
#       and the ratio to the default's, and the largest free extent left; then
#       one "answer:" line naming each setting that keeps fragmented growth
#       under 10% of the default's without more than twice its allocation
#       time, "none" when no setting does, or "unknown" with the reason.
#       Exit 0, 2 when FILE is unreadable or not a results file.
#
# Results file (fm-ext4-alloc-trial-results/v1), tab-separated:
#   # fm-ext4-alloc-trial-results/v1 size=B rounds=N volume=B churn=N jobs=N seed=N
#   SETTING ROUND FRAGMENTED_BYTES FREE_BYTES LARGEST_FREE_BYTES USED_BYTES SECONDS
#   SETTING failed REASON
# ROUND 0 is the fresh filesystem, with SECONDS 0.
#
# Environment:
#   FM_EXT4_TRIAL_DISK_ROOM  fm-disk-room.sh used for mb-groups (default: the
#                            one beside this script)
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_ROOM=${FM_EXT4_TRIAL_DISK_ROOM:-$SCRIPT_DIR/fm-disk-room.sh}
FORMAT=fm-ext4-alloc-trial-results/v1
DEFAULT_SETTINGS='default mb_group_prealloc=64 mb_group_prealloc=16 mb_group_prealloc=0 mb_stream_req=64'

die() { printf 'fm-ext4-alloc-trial: %s\n' "$*" >&2; exit 2; }
note() { printf '%s fm-ext4-alloc-trial: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }

# to_bytes SIZE -> bytes for a whole number with an optional K, M, G or T.
to_bytes() {
  local n=${1%[KMGTkmgt]} u
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  u=${1#"$n"}
  case "$u" in
    '') printf '%s\n' "$n" ;;
    [Kk]) printf '%s\n' $(( n << 10 )) ;;
    [Mm]) printf '%s\n' $(( n << 20 )) ;;
    [Gg]) printf '%s\n' $(( n << 30 )) ;;
    [Tt]) printf '%s\n' $(( n << 40 )) ;;
    *) return 1 ;;
  esac
}

whole() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

# check_settings LIST: every word is default or KEY=VALUE[,KEY=VALUE...].
check_settings() {
  local s pair
  [ -n "${1// /}" ] || die "--settings is empty"
  for s in $1; do
    [ "$s" = default ] && continue
    for pair in ${s//,/ }; do
      case "$pair" in
        mb_*=*) ;;
        *) die "bad setting $s: each part is mb_KEY=VALUE" ;;
      esac
      case "${pair%%=*}" in *[!a-z0-9_]*) die "bad setting key in $s" ;; esac
      whole "${pair#*=}" || die "bad setting value in $s"
    done
  done
}

# physical DIR: prints DIR's resolved path with one leading slash; pwd -P
# keeps a leading // (POSIX leaves it implementation-defined), which would
# slip past the place patterns.
physical() {
  local p
  p=$(cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  while [ "${p#//}" != "$p" ]; do p=${p#/}; done
  printf '%s\n' "$p"
}

# refuse_place GIVEN PATH: refuses a scratch directory at PATH.
refuse_place() {
  case "$2" in
    /) die "refusing --dir $1: it is /" ;;
    /mnt|/mnt/*) die "refusing --dir $1: it is on /mnt ($2)" ;;
    /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/boot|/boot/*|/etc|/etc/*|/usr|/usr/*|\
    /bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/root|/home)
      die "refusing --dir $1: $2 is a system directory" ;;
  esac
}

# check_dir DIR: sets DIR to the physical path of a safe, empty scratch
# directory, or refuses. The place is judged as written first, so a refusal
# never depends on whether the path exists, and again once resolved.
check_dir() {
  local d=$1 real fstype listing
  case "$d" in /*) ;; *) die "refusing --dir $d: not an absolute path" ;; esac
  case "$d" in *//*|*/./*|*/../*|*/.|*/..) die "refusing --dir $d: not a plain path (no //, . or ..)" ;; esac
  real=${d%/}
  refuse_place "$d" "${real:-/}"
  [ ! -L "${d%/}" ] || die "refusing --dir $d: it is a symbolic link"
  [ -d "$d" ] || die "refusing --dir $d: not an existing directory"
  real=$(physical "$d") || die "refusing --dir $d: cannot resolve it"
  refuse_place "$d" "$real"
  fstype=$(stat -f -c %T -- "$real" 2>/dev/null) || die "refusing --dir $d: cannot read its filesystem type"
  case "$fstype" in
    v9fs|9p|fuse|fuse.*|fuseblk|nfs|nfs4|cifs|smb|smb2|smb3|drvfs)
      die "refusing --dir $d: it is on a $fstype filesystem" ;;
  esac
  listing=$(ls -A -- "$real" 2>&1) || die "refusing --dir $d: cannot list it"
  [ -z "$listing" ] || die "refusing --dir $d: it is not empty"
  DIR=$real
}

# root_chain WHAT PATH: refuses unless PATH and every directory above it
# belong to root, PATH is writable by no one else, and each directory above
# it is writable by no one else or sticky (where only root may rename a
# root-owned entry). A symbolic link along the way only has to belong to root.
root_chain() {
  local p=$2 st uid mode type leaf=1
  while :; do
    st=$(stat -c '%u %a %F' -- "${p:-/}" 2>/dev/null) || die "refusing $1: cannot read ${p:-/}"
    uid=${st%% *} st=${st#* }
    mode=${st%% *} type=${st#* }
    [ "$uid" = 0 ] || die "refusing $1: ${p:-/} does not belong to root"
    if [ "$type" != "symbolic link" ] && [ $(( 8#$mode & 8#022 )) -ne 0 ]; then
      [ "$leaf" = 0 ] && [ $(( 8#$mode & 8#1000 )) -ne 0 ] ||
        die "refusing $1: ${p:-/} is writable by users other than root"
    fi
    [ -n "$p" ] || break
    p=${p%/*} leaf=0
  done
}

# check_owned GIVEN REAL WHAT: root_chain on a path as given and as resolved.
check_owned() {
  root_chain "$3" "${1%/}"
  root_chain "$3" "$2"
}

# The seeded workload, run as `python3 -I -c TEXT MNT ROUND VOLUME CHURN JOBS SEED STATES`.
# It prints the round's seconds (writes plus a final sync) and exits 1 when a
# writer failed; TERM, INT and HUP kill its writers before it exits.
WORKLOAD='
import math, os, random, signal, sys, time
mnt = sys.argv[1]
rnd, volume, churn, jobs, seed, states = (int(a) for a in sys.argv[2:8])
TYPES = (("json", 0.40, 2048, 200, 65536), ("jsonl", 0.25, 24576, 1024, 1048576),
         ("gz", 0.20, 8192, 512, 262144), ("py", 0.15, 6144, 200, 65536))
BUF = os.urandom(1 << 20)
def pick(r):
    x = r.random()
    for t in TYPES:
        x -= t[1]
        if x < 0:
            return t
    return TYPES[-1]
def size(r, t):
    return max(t[3], min(t[4], int(r.lognormvariate(math.log(t[2]), 1.0))))
def put(path, n):
    with open(path, "wb") as f:
        f.write(BUF[:n])
def job(j):
    r = random.Random(seed * 1000003 + rnd * 1009 + j)
    base = os.path.join(mnt, "j%d" % j)
    live = os.path.join(base, "live", "r%d" % rnd)
    tmp, logs, state = (os.path.join(base, x) for x in ("tmp", "logs", "state"))
    for d in (live, tmp, logs, state):
        os.makedirs(d, exist_ok=True)
    target, done, short, n, s, ring = volume // jobs, 0, 0, 0, 0, []
    while done < target:
        t = pick(r)
        k = size(r, t)
        put(os.path.join(live, "f%06d.%s" % (n, t[0])), k)
        done += k
        n += 1
        while short < churn * done:
            t2 = pick(r)
            k2 = size(r, t2)
            p = os.path.join(tmp, "t%07d.%s" % (s, t2[0]))
            put(p, k2)
            ring.append(p)
            short += k2
            s += 1
            if len(ring) > 64:
                os.unlink(ring.pop(0))
        if n % 8 == 0:
            with open(os.path.join(logs, "log%d.jsonl" % (n // 8 % 4)), "ab") as f:
                f.write(BUF[:r.randint(512, 4096)])
        if n % 4 == 0:
            p = os.path.join(state, "s%03d.json" % r.randrange(max(1, states // jobs)))
            put(p + ".tmp", r.randint(1024, 8192))
            os.replace(p + ".tmp", p)
    for p in ring:
        os.unlink(p)
kids = []
def stop(sig, frame):
    for p in kids:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass
    for p in kids:
        try:
            os.waitpid(p, 0)
        except OSError:
            pass
    os._exit(128 + sig)
for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sg, stop)
t0 = time.monotonic()
for j in range(jobs):
    pid = os.fork()
    if pid == 0:
        for sg in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sg, signal.SIG_DFL)
        code = 0
        try:
            job(j)
        except Exception as e:
            sys.stderr.write("writer %d: %s\n" % (j, e))
            code = 1
        os._exit(code)
    kids.append(pid)
bad = 0
for p in kids:
    if os.waitpid(p, 0)[1] != 0:
        bad = 1
os.sync()
print("%.3f" % (time.monotonic() - t0))
sys.exit(bad)
'

IMG='' MNT='' LOOP='' WORKER='' RUN_TMP=''

# teardown: undo whatever exists of this run's image, in reverse order; safe
# to call repeatedly and after any partial setup.
teardown() {
  local try dev
  if [ -n "$WORKER" ]; then
    kill -TERM "$WORKER" 2>/dev/null
    wait "$WORKER" 2>/dev/null
    WORKER=''
  fi
  if [ -n "$MNT" ] && mountpoint -q -- "$MNT" 2>/dev/null; then
    for try in 1 2 3 4 5; do
      umount -- "$MNT" 2>/dev/null && break
      [ "$try" = 5 ] || sleep 1
    done
    if mountpoint -q -- "$MNT" 2>/dev/null; then
      note "unmount of $MNT stays busy; detaching it lazily"
      umount -l -- "$MNT" 2>/dev/null || note "cannot unmount $MNT; run: umount -l $MNT"
    fi
  fi
  if [ -n "$IMG" ]; then
    # Every loop device backing this image, including one attached by a run
    # stopped before LOOP was recorded.
    for dev in $LOOP $(losetup -l -j "$IMG" -O NAME -n 2>/dev/null); do
      losetup -d "$dev" 2>/dev/null
    done
    LOOP=''
    rm -f -- "$IMG" || note "cannot remove $IMG"
    IMG=''
  fi
  if [ -n "$MNT" ]; then
    rmdir -- "$MNT" 2>/dev/null || [ ! -e "$MNT" ] || note "cannot remove $MNT"
    MNT=''
  fi
}

on_exit() {
  local rc=$?
  trap '' INT TERM HUP
  teardown
  [ -n "$RUN_TMP" ] && rm -rf -- "$RUN_TMP"
  exit "$rc"
}

# read_round SETTING ROUND SECONDS: appends one reading to RESULTS.
read_round() {
  local out frag free big st used total avail bs
  out=$("$DISK_ROOM" mb-groups "/proc/fs/ext4/${LOOP##*/}/mb_groups" "$BS" 2>&1) || {
    printf '%s\tfailed\tmb_groups unreadable after round %s: %s\n' "$1" "$2" "$out" >>"$RESULTS"; return 1; }
  read -r frag free big <<<"$out"
  frag=${frag#fragmented=} free=${free#free=} big=${big#largest=}
  st=$(stat -f -c '%b %f %S' -- "$MNT") || { printf '%s\tfailed\tcannot read used space after round %s\n' "$1" "$2" >>"$RESULTS"; return 1; }
  read -r total avail bs <<<"$st"
  used=$(( (total - avail) * bs ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$frag" "$free" "$big" "$used" "$3" >>"$RESULTS"
  note "$1 round $2: fragmented $frag bytes, free $free, largest free $big, used $used, ${3}s"
}

# apply_setting SETTING: writes each KEY=VALUE into the loop device's sysfs
# directory and reads it back.
apply_setting() {
  local pair key val f got
  [ "$1" = default ] && return 0
  for pair in ${1//,/ }; do
    key=${pair%%=*} val=${pair#*=}
    f="/sys/fs/ext4/${LOOP##*/}/$key"
    [ -f "$f" ] || { FAIL="no $key in /sys/fs/ext4/${LOOP##*/}"; return 1; }
    { printf '%s\n' "$val" >"$f"; } 2>/dev/null || { FAIL="the kernel refused $key=$val"; return 1; }
    got=$(cat -- "$f" 2>/dev/null)
    [ "$got" = "$val" ] || { FAIL="$key reads back ${got:-nothing}, not $val"; return 1; }
  done
}

# trial SETTING: one fresh image through all rounds; returns 1 on failure.
trial() {
  local r secs
  FAIL=''
  # Each path is recorded for teardown only once this run has created it.
  ( set -C; : >"$DIR/trial.img" ) 2>/dev/null || { FAIL="cannot create $DIR/trial.img"; return 1; }
  IMG="$DIR/trial.img"
  mkdir -- "$DIR/mnt" 2>/dev/null || { FAIL="cannot create $DIR/mnt"; return 1; }
  MNT="$DIR/mnt"
  truncate -s "$SIZE" -- "$IMG" || { FAIL="cannot size the image"; return 1; }
  mkfs.ext4 -q -F -b 4096 -E lazy_itable_init=0,lazy_journal_init=0,nodiscard -- "$IMG" >/dev/null 2>&1 ||
    { FAIL="mkfs.ext4 failed"; return 1; }
  LOOP=$(losetup --find --show -- "$IMG" 2>/dev/null) && [ -n "$LOOP" ] || { LOOP=''; FAIL="losetup failed"; return 1; }
  mount -t ext4 -o discard,relatime -- "$LOOP" "$MNT" || { FAIL="mount failed"; return 1; }
  BS=$(stat -f -c %S -- "$MNT") || { FAIL="cannot read the block size"; return 1; }
  apply_setting "$1" || return 1
  read_round "$1" 0 0 || { FAIL=''; return 1; }
  for ((r = 1; r <= ROUNDS; r++)); do
    nice -n 19 ionice -c2 -n7 python3 -I -c "$WORKLOAD" "$MNT" "$r" "$VOLUME" "$CHURN" "$JOBS" "$SEED" 300 \
      >"$RUN_TMP/secs" 2>"$RUN_TMP/err" &
    WORKER=$!
    wait "$WORKER" || { WORKER=''; FAIL="workload failed in round $r: $(head -c 300 "$RUN_TMP/err")"; return 1; }
    WORKER=''
    secs=$(cat -- "$RUN_TMP/secs")
    read_round "$1" "$r" "$secs" || { FAIL=''; return 1; }
  done
}

cmd_run() {
  local dir='' s avail need rc=0 settings=$DEFAULT_SETTINGS results=''
  SIZE=$((8 << 30)) ROUNDS=6 VOLUME=$((128 << 20)) CHURN=15 JOBS=4 SEED=1
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --dir) dir=$2 ;;
      --size) SIZE=$(to_bytes "$2") || die "bad --size $2" ;;
      --rounds) whole "$2" && [ "$2" -ge 1 ] || die "bad --rounds $2"; ROUNDS=$2 ;;
      --volume) VOLUME=$(to_bytes "$2") && [ "$VOLUME" -ge $((1 << 20)) ] || die "bad --volume $2 (at least 1M)" ;;
      --churn) whole "$2" || die "bad --churn $2"; CHURN=$2 ;;
      --jobs) whole "$2" && [ "$2" -ge 1 ] && [ "$2" -le 64 ] || die "bad --jobs $2 (1 to 64)"; JOBS=$2 ;;
      --seed) whole "$2" || die "bad --seed $2"; SEED=$2 ;;
      --settings) settings=$2 ;;
      --results) results=$2 ;;
      *) die "unknown run argument: $1" ;;
    esac
    shift 2
  done
  [ -n "$dir" ] || die "run needs --dir DIR"
  [ "$SIZE" -ge $((1 << 30)) ] || die "--size must be at least 1G"
  # Long-lived files, logs and state must fit in half the image, so the
  # allocator is measured with room to choose, never near full.
  need=$(( ROUNDS * VOLUME + 64 * (1 << 20) ))
  [ $(( need * 2 )) -le "$SIZE" ] || die "--rounds x --volume needs at least $(( need * 2 >> 20 )) MiB of image; raise --size"
  check_settings "$settings"
  if [ -n "$results" ]; then
    case "$results" in /*) ;; *) die "--results must be an absolute path" ;; esac
    [ ! -e "$results" ] && [ ! -L "$results" ] || die "refusing --results $results: it exists"
  fi
  check_dir "$dir"
  if [ -n "$results" ]; then
    case "$results" in "$DIR"/*) die "--results must be outside --dir" ;; esac
  fi
  [ "$(uname -s)" = Linux ] || die "run needs Linux"
  [ "$(id -u)" = 0 ] || die "run needs root: run it as the operator with sudo"
  check_owned "$dir" "$DIR" "--dir $dir"
  if [ -n "$results" ]; then
    s=${results%/*}
    s=$(physical "${s:-/}") || die "refusing --results $results: cannot resolve its directory"
    check_owned "${results%/*}" "${s%/}" "--results $results"
  fi
  for s in mkfs.ext4 losetup mount umount mountpoint truncate python3 ionice; do
    command -v "$s" >/dev/null 2>&1 || die "run needs $s"
  done
  [ -x "$DISK_ROOM" ] || die "cannot run $DISK_ROOM"
  avail=$(stat -f -c '%a %S' -- "$DIR") || die "cannot read free space on $DIR"
  avail=$(( ${avail% *} * ${avail#* } ))
  if [ "$avail" -lt "$SIZE" ]; then
    printf 'fm-ext4-alloc-trial: wait: %s has %s MiB free, under the %s MiB image\n' "$DIR" $(( avail >> 20 )) $(( SIZE >> 20 )) >&2
    exit 75
  fi
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ext4-alloc-trial.XXXXXX") || die "cannot make a temp directory"
  RESULTS=${results:-$RUN_TMP/results}
  ( set -C; printf '# %s size=%s rounds=%s volume=%s churn=%s jobs=%s seed=%s\n' \
    "$FORMAT" "$SIZE" "$ROUNDS" "$VOLUME" "$CHURN" "$JOBS" "$SEED" >"$RESULTS" ) || die "cannot create $RESULTS"
  for s in $settings; do
    note "setting $s: fresh $(( SIZE >> 20 )) MiB image in $DIR"
    if ! trial "$s"; then
      rc=1
      [ -z "$FAIL" ] || printf '%s\tfailed\t%s\n' "$s" "$FAIL" >>"$RESULTS"
      note "setting $s failed${FAIL:+: $FAIL}"
    fi
    teardown
  done
  cmd_table "$RESULTS" || rc=1
  exit "$rc"
}

cmd_table() {
  local f=${1:--} text
  [ "$#" -le 1 ] || die "table takes at most one FILE"
  if [ "$f" = - ]; then text=$(cat) || die "cannot read stdin"
  else text=$(cat -- "$f" 2>/dev/null) || die "cannot read $f"; fi
  case "$text" in "# $FORMAT "*) ;; *) die "not a $FORMAT file: $f" ;; esac
  awk -F '\t' -v gib=1073741824 '
    NR == 1 {
      m = split($0, h, " ")
      for (i = 3; i <= m; i++) { split(h[i], kv, "="); P[kv[1]] = kv[2] }
      next
    }
    !($1 in seen) { seen[$1] = 1; order[++n] = $1 }
    $2 == "failed" { failed[$1] = $3; next }
    {
      s = $1; r = $2 + 0
      frag[s, r] = $3; if (!(s in last) || r > last[s]) last[s] = r
      used[s] = $6; big[s] = $5; secs[s] += $7
    }
    function fmt(x) { return sprintf("%.3f", x / gib) }
    function ratio(a, b) { return b > 0 ? sprintf("%.2f", a / b) : "-" }
    END {
      printf "fm-ext4-alloc-trial: fresh %.1f GiB image per setting, %d rounds of %d MiB long-lived files with %dx short-lived churn, %d writers, seed %d\n\n",
        P["size"] / gib, P["rounds"], P["volume"] / 1048576, P["churn"], P["jobs"], P["seed"]
      print "| setting | fragmented GiB after round 0.." P["rounds"] " | growth GiB | growth vs default | used GiB | alloc s | alloc vs default | largest free MiB |"
      print "|---|---|---|---|---|---|---|---|"
      dok = ("default" in last) && !("default" in failed) && last["default"] == P["rounds"]
      if (dok) { dg = frag["default", last["default"]] - frag["default", 0]; dt = secs["default"] }
      for (k = 1; k <= n; k++) {
        s = order[k]
        if ((s in failed) || !(s in last) || last[s] != P["rounds"]) {
          printf "| %s | failed: %s | - | - | - | - | - | - |\n", s, (s in failed) ? failed[s] : "incomplete"
          continue
        }
        row = ""
        for (r = 0; r <= last[s]; r++) row = row (r ? " " : "") fmt(frag[s, r])
        g = frag[s, last[s]] - frag[s, 0]
        printf "| %s | %s | %s | %s | %s | %.1f | %s | %.0f |\n", s, row, fmt(g), dok ? ratio(g, dg) : "-",
          fmt(used[s]), secs[s], dok ? ratio(secs[s], dt) : "-", big[s] / 1048576
        if (s != "default") { G[s] = g; T[s] = secs[s] }
      }
      printf "\n"
      if (!dok) { print "answer: unknown (the default setting did not complete)"; exit }
      if (dg <= 0) { print "answer: unknown (the default setting shows no fragmented growth in this workload)"; exit }
      pass = ""
      for (k = 1; k <= n; k++) {
        s = order[k]
        if ((s in G) && G[s] < 0.1 * dg && T[s] <= 2 * dt) pass = pass (pass ? ", " : "") s
      }
      if (pass) print "answer: " pass " (fragmented growth under 10% of the default'\''s, within twice its allocation time)"
      else print "answer: none: no setting keeps fragmented growth under 10% of the default'\''s within twice its allocation time"
    }' <<<"$text"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  table) shift; cmd_table "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
