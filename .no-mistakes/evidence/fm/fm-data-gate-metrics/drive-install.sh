#!/usr/bin/env bash
# Live driver: runs the real installer against a throwaway HOME with a recording systemctl stub
# (so the real user systemd manager is never touched), verifies the installed units with
# systemd-analyze, runs the installed service's ExecStart as systemd would, then uninstalls.
set -u
REPO=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M3SJFHJB9C8T2AXATYWSMJDA
T=$(mktemp -d /tmp/fm-dg-inst.XXXX); H=$T/home; mkdir -p "$H/.claude" "$H/Tools/firstmate/data" "$T/stub"
: >"$H/Tools/firstmate/AGENTS.md"
cat >"$T/stub/systemctl" <<'S'
#!/bin/sh
echo "systemctl $*" >>"$STUBLOG"
S
chmod +x "$T/stub/systemctl"; export STUBLOG=$T/systemctl.log
I() { HOME="$H" PATH="$T/stub:$PATH" env -u FM_HOME "$REPO/bin/fm-data-gate-install.sh" "$@"; }
echo '$ fm-data-gate-install.sh install --dry-run'; I install --dry-run | grep -iE 'report|timer|dry'
echo; echo '$ fm-data-gate-install.sh install'; I install | sed "s#$H#~#g"; echo "exit=$?"
echo; echo "--- systemctl calls:"; cat "$STUBLOG"
U=$H/.config/systemd/user
echo; echo "--- installed service:"; sed "s#$H#~#g" "$U/lattice-data-gate-report.service"
echo "--- installed timer:"; cat "$U/lattice-data-gate-report.timer"
echo; echo '$ systemd-analyze verify (service + timer)'; (cd "$U" && systemd-analyze verify --user lattice-data-gate-report.timer lattice-data-gate-report.service 2>&1 | grep -v 'Failed to .*bus\|tmpfiles' ); echo "exit=${PIPESTATUS[0]}"
echo '$ systemd-analyze calendar "*-*-* 00:40:00"'; systemd-analyze calendar '*-*-* 00:40:00' | sed -n '1,4p'
echo; echo "--- run the installed ExecStart with the unit's Environment, nice/ionice as the unit sets:"
envline=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$U/lattice-data-gate-report.service")
exe=$(sed -n 's/^ExecStart=//p' "$U/lattice-data-gate-report.service")
echo "ExecStart=$exe" | sed "s#$REPO#<worktree>#"
HOME="$H" env -i HOME="$H" PATH="$envline" nice -n 19 ionice -c3 sh -c "$exe"; echo "exit=$?"; ls "$H/.local/state/lattice-data-gate/reports"
echo; echo '$ fm-data-gate-install.sh install (re-run, idempotent)'; : >"$STUBLOG"; I install | grep -iE 'report|timer|unchanged|current' | sed "s#$H#~#g"
echo; echo '$ fm-data-gate-install.sh uninstall'; : >"$STUBLOG"; I uninstall | sed "s#$H#~#g"; echo "--- systemctl calls:"; cat "$STUBLOG"
ls "$U" 2>&1; echo "reports kept:"; ls "$H/.local/state/lattice-data-gate/reports"
rm -rf "$T"
