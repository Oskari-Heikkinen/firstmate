#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-wsl-reclaim.ps1 (docs/disk-room.md) that need no
# elevation and touch no Windows state: the script must parse, and its
# shadow-storage record formatter, run on fake Win32_ShadowStorage objects, and
# its trim result formatter must write the key=value lines bin/fm-disk-room.sh
# reads, and the trim must name the distro to wsl.exe bare (a quoted name is
# WSL_E_DISTRO_NOT_FOUND, which made an elevated -Now skip its trim). Under
# pwsh on Linux a fake wsl.exe on PATH runs Invoke-Trim end to end. Runs under
# pwsh, or
# Windows PowerShell through WSL interop; skips when neither is installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-wsl-reclaim.ps1"
if command -v pwsh >/dev/null 2>&1; then
  PS=pwsh; SCRIPT_ARG=$SCRIPT
elif command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  PS=powershell.exe; SCRIPT_ARG=$(wslpath -w "$SCRIPT")
else
  echo "skip: neither pwsh nor powershell.exe is installed"
  exit 0
fi

# WSL interop can be down (powershell.exe then never starts); that is the
# host's state, not this script's, so it skips rather than fails.
if [ "$PS" = powershell.exe ] && ! timeout 60 powershell.exe -NoProfile -NonInteractive -Command "'fm-probe'" 2>/dev/null | grep -q fm-probe; then
  echo "skip: powershell.exe does not start (WSL interop unavailable)"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-wsl-reclaim)
DRIVER="$TMP_ROOT/driver.ps1"
cat >"$DRIVER" <<'PS1'
param([string]$Path, [string]$FakeDir)
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { "parse-error: $($_.Message)" }; exit 1 }
foreach ($name in 'Format-ShadowRecord', 'Format-TrimResult', 'Get-TrimArgv', 'Invoke-Trim') {
  $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
  if (-not $fn) { "missing: $name"; exit 1 }
  . ([scriptblock]::Create($fn.Extent.Text))
}
function Storage($id, $max, $used, $alloc) {
  [pscustomobject]@{ DiffVolume = [pscustomobject]@{ DeviceID = $id }; MaxSpace = [uint64]$max; UsedSpace = [uint64]$used; AllocatedSpace = [uint64]$alloc }
}
$c = '\\?\Volume{c}\'
$when = [datetime]::SpecifyKind([datetime]'2026-10-01T12:00:00', 'Utc')
'case=capped'
Format-ShadowRecord @((Storage $c 10737418240 3221225472 3489660928), (Storage '\\?\Volume{d}\' 5 1 1)) $c 'C:' $when
'case=unbounded'
Format-ShadowRecord @(Storage $c ([uint64]::MaxValue) 1048576 2097152) $c 'C:' $when
'case=none'
Format-ShadowRecord @() $c 'C:' $when
'case=trim-ok'
Format-TrimResult "exit 0: /: 30 GiB (32212254720 bytes) trimmed`non /dev/sdf"
'case=trim-failed'
Format-TrimResult 'exit 1: fstrim: /: the discard operation is not supported'
'case=trim-none'
Format-TrimResult ''
'case=trim-no-distro'
Format-TrimResult "exit -1: There is no distribution with the supplied name.`n`nError code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND`n"
'case=trim-argv'
Get-TrimArgv 'Ubuntu-24.04'
'case=trim-fake-wsl'
if ($FakeDir) {
  $env:PATH = "$FakeDir$([IO.Path]::PathSeparator)$env:PATH"
  Invoke-Trim 'Ubuntu-24.04'
  Get-Content (Join-Path $FakeDir 'argv')
} else { 'skipped' }
PS1
[ "$PS" = pwsh ] && [ "$(uname -s)" = Linux ] && FAKE_DIR=$TMP_ROOT/fake || FAKE_DIR=
if [ -n "$FAKE_DIR" ]; then
  mkdir -p "$FAKE_DIR"
  # Like wsl.exe: an unknown distro name is an error, the known one runs fstrim.
  cat >"$FAKE_DIR/wsl.exe" <<'SH'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >"$(dirname "$0")/argv"
[ "$2" = Ubuntu-24.04 ] || { echo "There is no distribution with the supplied name."; exit 1; }
echo "/: 2 GiB (2147483648 bytes) trimmed on /dev/sdf"
SH
  chmod +x "$FAKE_DIR/wsl.exe"
fi
[ "$PS" = powershell.exe ] && DRIVER_ARG=$(wslpath -w "$DRIVER") || DRIVER_ARG=$DRIVER

"$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$DRIVER_ARG" "$SCRIPT_ARG" "$FAKE_DIR" >"$TMP_ROOT/out" 2>&1
RC=$?
OUT=$(tr -d '\r' <"$TMP_ROOT/out")

# section NAME -> the lines printed after case=NAME, up to the next case.
section() { printf '%s\n' "$OUT" | awk -v c="case=$1" '/^case=/ { on = ($0 == c); next } on'; }

test_parses() {
  expect_code 0 "$RC" "the driver ran ($OUT)"
  assert_not_contains "$OUT" "parse-error" "the script parses"
  pass "fm-wsl-reclaim.ps1 parses under $PS"
}

test_capped_record() {
  local s
  s=$(section capped)
  assert_equals "recorded=2026-10-01T12:00:00Z
recorded_epoch=1790856000
volume=C:
max_bytes=10737418240
used_bytes=3221225472
allocated_bytes=3489660928" "$s" "only the system drive's diff area is recorded"
  pass "a capped shadow storage records its max and used bytes"
}

test_unbounded_and_none() {
  assert_contains "$(section unbounded)" "max_bytes=unbounded" "UNBOUNDED is named, not written as 2^64"
  assert_contains "$(section unbounded)" "used_bytes=1048576" "used is still recorded"
  assert_contains "$(section none)" "max_bytes=0" "no shadow storage records a zero cap"
  assert_contains "$(section none)" "used_bytes=0" "and zero used"
  pass "an unbounded or absent shadow storage is recorded explicitly"
}

test_trim_result() {
  assert_equals "trim=ok
trim_detail=exit 0: /: 30 GiB (32212254720 bytes) trimmed on /dev/sdf" "$(section trim-ok)" "a trim's output is one detail line"
  assert_equals "trim=failed
trim_detail=exit 1: fstrim: /: the discard operation is not supported" "$(section trim-failed)" "a failed trim is recorded, not thrown"
  assert_equals "trim=not-run
trim_detail=no trim in this mode" "$(section trim-none)" "a mode without a trim says so"
  pass "the trim result is recorded as trim and trim_detail lines"
}

test_trim_unreachable_says_what_to_do() {
  assert_equals "trim=failed
trim_detail=exit -1: There is no distribution with the supplied name. Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND - trim by hand: run sudo fstrim -v / in the distro from a normal shell, then -Now" "$(section trim-no-distro)" "a trim wsl.exe never ran names the manual step"
  pass "a trim that never reached the distro says how to trim by hand"
}

test_trim_names_distro_bare() {
  assert_equals "-d
Ubuntu-24.04
-u
root
--
timeout
600
fstrim
-v
/" "$(section trim-argv)" "the distro name carries no literal quotes"
  if [ -z "$FAKE_DIR" ]; then
    pass "the trim names the distro bare (fake wsl.exe needs pwsh on Linux)"
    return
  fi
  assert_equals "exit 0: /: 2 GiB (2147483648 bytes) trimmed on /dev/sdf
argv=-d Ubuntu-24.04 -u root -- timeout 600 fstrim -v /" "$(section trim-fake-wsl)" "Invoke-Trim reaches the distro and returns fstrim's output"
  pass "the trim names the distro bare and reaches it through wsl.exe"
}

test_parses
test_capped_record
test_unbounded_and_none
test_trim_result
test_trim_unreachable_says_what_to_do
test_trim_names_distro_bare
