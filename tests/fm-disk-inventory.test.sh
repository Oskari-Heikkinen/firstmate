#!/usr/bin/env bash
# Read-only disk inventory: every REMOVE safety check keeps an item in KEEP when
# it fails, clean landed unreferenced copies and idle uncited temp folders are
# REMOVE, other homes are listed, and nothing but the output file is written.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-disk-inventory)
fm_git_identity

# Origin, and the main checkout that is a firstmate home owning the pool.
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/main" 2>/dev/null
echo one > "$T/main/file"
git -C "$T/main" add file
git -C "$T/main" commit -q -m one
git -C "$T/main" push -q origin main
git -C "$T/main" remote set-head origin main
# housekeeping/ exists up front so only the output file and its folder change.
mkdir -p "$T/main/state" "$T/main/data/task-a" "$T/main/data/housekeeping"

POOL=$T/pool/repo-abc
for n in 1 2 3 4 5 6 7 8; do
  mkdir -p "$POOL/$n"
  git -C "$T/main" worktree add -q --detach "$POOL/$n/repo" main
done
# 2: referenced by a task record; 3: tracked edit; 4: untracked file;
# 5: unlanded commit; 6: leased; 7: live process; 8: stale owner claim.
printf 'worktree=%s\ntasktmp=%s\n' "$POOL/2/repo" "$T/tmp/fm-a" > "$T/main/state/task-a.meta"
echo changed > "$POOL/3/repo/file"
echo scratch > "$POOL/4/repo/new"
echo two > "$POOL/5/repo/file"
git -C "$POOL/5/repo" commit -q -am two
printf '{"worktrees":[{"name":"6","path":"%s","leased":true,"lease_holder":"mate-x"}]}\n' \
  "$POOL/6/repo" > "$POOL/treehouse-state.json"
printf 'task=gone-task\nhome=%s\n' "$T/main" > "$POOL/8/.fm-slot-owner"
(cd "$POOL/7/repo" && exec sleep 300) &
LIVE=$!

# Another home, found through its pool slot, whose data is listed for its owner.
mkdir -p "$T/pool/fm-xyz/1/firstmate/state" "$T/pool/fm-xyz/1/firstmate/data/big"
head -c 20000 /dev/zero > "$T/pool/fm-xyz/1/firstmate/data/big/blob"
printf 'worktree=%s\n' "$T/elsewhere" > "$T/pool/fm-xyz/1/firstmate/state/other.meta"

# Temp folders: a referenced, b idle, c recent, d idle but cited by a report.
mkdir -p "$T/tmp/fm-a" "$T/tmp/fm-b" "$T/tmp/fm-c" "$T/tmp/fm-d" "$T/nm/repo/RUN1"
for d in a b d; do
  echo x > "$T/tmp/fm-$d/f"
  touch -d '3 days ago' "$T/tmp/fm-$d/f" "$T/tmp/fm-$d"
done
echo x > "$T/tmp/fm-c/f"
echo "see $T/tmp/fm-d for evidence" > "$T/main/data/task-a/report.md"

snapshot() {
  (cd "$T" && find . -path ./main/data/housekeeping -prune -o -print0 | LC_ALL=C sort -z |
    xargs -0 stat -c '%n %s %Y %a' && find . -type f ! -path './main/data/housekeeping/*' -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum)
}
before=$(snapshot)

run() {
  "$ROOT/bin/fm-disk-inventory.sh" --home "$T/main" --pool-root "$T/pool" \
    --nm-root "$T/nm" --tmp-root "$T/tmp" --date 2026-01-02 "$@"
}
out=$(run)
kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
[ "$out" = "$T/main/data/housekeeping/inventory-2026-01-02.md" ] || { echo "FAIL: output path $out"; exit 1; }
after=$(snapshot); [ "$after" = "$before" ] || { diff <(echo "$before") <(echo "$after") | head; echo 'FAIL: inventory changed something besides its output'; exit 1; }

python3 - "$out" "$T" <<'PY'
import re, sys
text, T = open(sys.argv[1]).read(), sys.argv[2]
keep = text.split('## KEEP')[1].split('## REMOVE')[0]
remove = text.split('## REMOVE')[1].split('## Other homes')[0]
other = text.split('## Other homes')[1].split('## Scan limits')[0]
def row(section, path):
    m = [ln for ln in section.splitlines() if ln.startswith('| `%s`' % path)]
    assert len(m) == 1, (path, section)
    return m[0]
pool = T + '/pool/repo-abc/'
assert 'on origin/main' in row(remove, pool + '1')
for n, why in [('2', 'task-a.meta (worktree=)'), ('3', 'uncommitted tracked'),
               ('4', 'untracked files: new'), ('5', 'is not on origin/main'),
               ('6', 'leased to mate-x'), ('7', 'live process'),
               ('8', 'gone-task')]:
    assert why in row(keep, pool + n), (n, row(keep, pool + n))
assert 'idle' in row(remove, T + '/tmp/fm-b')
assert 'tasktmp=' in row(keep, T + '/tmp/fm-a')
assert 'changed within' in row(keep, T + '/tmp/fm-c')
assert 'cited by' in row(keep, T + '/tmp/fm-d')
assert 'no-mistakes' in row(keep, T + '/nm/repo/RUN1')
assert 'firstmate home' in row(keep, T + '/pool/fm-xyz/1')
row(other, T + '/pool/fm-xyz/1/firstmate/data')
assert 'Nothing was deleted' in text
print('PASS: KEEP/REMOVE verdicts per safety check, other homes listed')
PY

# A second default run never overwrites; an explicit existing --out is refused.
out2=$(run)
[ "$out2" != "$out" ] && [ -f "$out2" ] || { echo "FAIL: second run reused $out2"; exit 1; }
if run --out "$out" 2>/dev/null; then echo 'FAIL: overwrote an existing --out'; exit 1; fi
echo 'PASS: read-only scan, no overwrite'
