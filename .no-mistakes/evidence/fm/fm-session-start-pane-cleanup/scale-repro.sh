#!/usr/bin/env bash
# Reproduce the session-start stale-projection cleanup cost at the reported
# scale (85 leftover journals) by running the real cleanup script entrypoint
# against a fake `herdr` CLI. Usage: scale-repro.sh <repo-root> <cleanup-script> [leftovers] [workspaces]
set -u
ROOT=$1 SCRIPT=$2 LEFTOVERS=${3:-85} WORKSPACES=${4:-40}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-scale.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/bin" "$T/home/state" "$T/home/config" "$T/fakebin"
cp -R "$ROOT/bin/." "$T/root/bin/"; cp "$SCRIPT" "$T/root/bin/fm-herdr-session-cleanup.sh"
printf herdr > "$T/home/config/backend"; touch "$T/home/config/herdr-presentation-spaces"
HOME_REAL=$(cd "$T/home" && pwd -P)
for i in $(seq 1 "$LEFTOVERS"); do
  tok=$(printf 'Lx%020d' "$i")
  printf 'version=2\ntask_id=gone-%s\nprojection_id=%s\nhome=%s\nsession=fm-scale\nworkspace_id=wg%s\ntab_id=wg%s:t1\npane_id=wg%s:p1\nparent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ gone-%s · p:%s\ntask_label=fm-gone-%s\n' \
    "$i" "$tok" "$HOME_REAL" "$i" "$i" "$i" "$i" "$tok" "$i" > "$T/home/state/gone-$i.herdr-presentation"
done
# One live leftover whose pane still exists must be preserved.
printf 'version=2\ntask_id=alive\nprojection_id=Ax00000000000000000001\nhome=%s\nsession=fm-scale\nworkspace_id=wlive\ntab_id=wlive:t1\npane_id=wlive:p1\nparent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ alive · p:Ax00000000000000000001\ntask_label=fm-alive\n' "$HOME_REAL" > "$T/home/state/alive.herdr-presentation"
: > "$T/home/state/alive.meta"
ws='{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"wlive","label":"└ alive · p:Ax00000000000000000001"}'
for i in $(seq 1 "$WORKSPACES"); do ws+=$(printf ',{"workspace_id":"x%s","label":"└ other-%s · p:Ox%020d"}' "$i" "$i" "$i"); done
printf '{"result":{"workspaces":[%s]}}' "$ws" > "$T/workspaces.json"
printf '{"result":{"snapshot":{"workspaces":[%s],"panes":[{"pane_id":"w1:p1"},{"pane_id":"wlive:p1"}]}}}' "$ws" > "$T/snapshot.json"
cat > "$T/fakebin/herdr" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$T/herdr-calls.log"
case "\$1 \$2" in
  "workspace list") cat "$T/workspaces.json" ;;
  "api snapshot") cat "$T/snapshot.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/herdr"
start=$(date +%s.%N)
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$T/home" HERDR_SESSION=fm-scale PATH="$T/fakebin:$PATH" \
  bash "$T/root/bin/fm-herdr-session-cleanup.sh"
rc=$?
end=$(date +%s.%N)
printf 'script=%s leftovers=%s candidate-workspaces=%s exit=%s elapsed=%.1fs\n' "$(basename "$SCRIPT")" "$LEFTOVERS" "$WORKSPACES" "$rc" "$(echo "$end - $start" | bc)"
printf 'dead leftover journals remaining: %s / %s\n' "$(ls "$T/home/state" | grep -c '^gone-.*herdr-presentation$')" "$LEFTOVERS"
printf 'live (meta-bearing) journal preserved: %s\n' "$([ -f "$T/home/state/alive.herdr-presentation" ] && echo yes || echo NO)"
printf 'leftover task locks left behind: %s\n' "$(ls -a "$T/home/state" | grep -c '^\.spawn-' )"
printf 'herdr calls: %s (%s)\n' "$(wc -l < "$T/herdr-calls.log")" "$(cut -d' ' -f1-2 "$T/herdr-calls.log" | sort | uniq -c | tr -s ' ' | paste -sd, -)"
