# Loads bin/fm-wsl-reclaim.ps1's function definitions (not its mode switch) via the
# PowerShell parser and calls them on the real Windows host, non-elevated.
param([string]$Script, [string]$Distro, [string]$Work)
$ErrorActionPreference = 'Stop'
$ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
  . ([scriptblock]::Create($f.Extent.Text))
}
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$Dir = $Work; $Log = Join-Path $Work 'wsl-compact.log'; $Last = Join-Path $Work 'wsl-compact-last.txt'
$Conf = Join-Path $Work 'wsl-compact.conf'; $NoDocker = $true

'--- Invoke-Wsl with a Linux command that writes stderr and exits 3 ($ErrorActionPreference=Stop, PS ' + $PSVersionTable.PSVersion + ')'
try { 'returned: ' + (Invoke-Wsl @('-d', $Distro, '--', 'sh', '-c', 'echo warning-on-stderr >&2; echo out; exit 3')) } catch { 'THREW: ' + $_ }
'--- Invoke-Wsl with a clean command'
try { 'returned: ' + (Invoke-Wsl @('-d', $Distro, '--', 'true')) } catch { 'THREW: ' + $_ }

'--- Test-Sparse on a normal and a sparse file'
$plain = Join-Path $Work 'plain.bin'; $sparse = Join-Path $Work 'sparse.bin'
[IO.File]::WriteAllBytes($plain, [byte[]](1..16)); [IO.File]::WriteAllBytes($sparse, [byte[]](1..16))
& fsutil sparse setflag $sparse | Out-Null
"plain  sparse=$(Test-Sparse $plain)"
"sparse sparse=$(Test-Sparse $sparse)"
'--- Invoke-Compact skips a sparse file and a missing file without running diskpart'
"sparse  -> $(Invoke-Compact $sparse)"
"missing -> $(Invoke-Compact (Join-Path $Work 'nope.vhdx'))"

'--- Invoke-CompactAll writes the last-result file (file list = one missing + one sparse disk)'
Set-Content -Path $Conf -Encoding ASCII -Value @('# distro=test', (Join-Path $Work 'nope.vhdx'), $sparse)
Invoke-CompactAll 'startup'
'--- wsl-compact-last.txt'
Get-Content $Last
