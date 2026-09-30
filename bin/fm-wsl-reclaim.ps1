<#
fm-wsl-reclaim.ps1 - give space Linux has freed back to the Windows drive.

WSL keeps the distro in a non-sparse ext4.vhdx, so space Linux frees stays
allocated on C: until the file is compacted while WSL is not running. This
script is the one-time install and the manual "reclaim now" for that; it never
deletes a file, never changes sparse mode, and never runs wsl --shutdown on its
own. docs/disk-room.md owns the contract; bin/fm-disk-room.sh reads the result.

Modes (run from an elevated Windows PowerShell except -Plan):
  -Plan       (default) read-only: resolved disk files, sizes, sparse flags,
              whether the startup task is installed, and the last result.
  -Install    copy this script to C:\ProgramData\firstmate (Administrators and
              SYSTEM write, Users read), record the disk files, register the
              "Firstmate WSL compact at startup" task (SYSTEM, at boot), and
              enable the weekly fstrim timer inside the distro (wsl -u root).
              Run it while the distro is running.
  -Now        fstrim inside the distro, wsl --shutdown, compact every recorded
              disk file, print before/after, and start the distro again
              (-NoRestart leaves it stopped). Stops every WSL process.
  -Startup    what the task runs at boot: compact every recorded disk file
              that nothing holds open; skips a file in use.
  -Uninstall  remove the task, the ProgramData script and file list, and the
              fstrim drop-ins. Logs are kept.

Options: -Distro NAME (default: the WSL default distro), -NoDocker (leave
docker_data.vhdx out of -Install's file list), -NoRestart (with -Now).

Output: C:\ProgramData\firstmate\wsl-compact.log (appended) and
wsl-compact-last.txt (key=value: finished, mode, result, reclaimed_bytes,
c_free_bytes, then one file=<path>|<before>|<after>|<status> line per disk).
#>
[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
  [Parameter(ParameterSetName = 'Plan')][switch]$Plan,
  [Parameter(ParameterSetName = 'Install')][switch]$Install,
  [Parameter(ParameterSetName = 'Now')][switch]$Now,
  [Parameter(ParameterSetName = 'Startup')][switch]$Startup,
  [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
  [string]$Distro = '',
  [switch]$NoDocker,
  [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Firstmate WSL compact at startup'
$Dir = Join-Path $env:ProgramData 'firstmate'
$Installed = Join-Path $Dir 'fm-wsl-reclaim.ps1'
$Conf = Join-Path $Dir 'wsl-compact.conf'
$Log = Join-Path $Dir 'wsl-compact.log'
$Last = Join-Path $Dir 'wsl-compact-last.txt'
$DropinUnits = @('fstrim.timer', 'fstrim.service')

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
  if (-not (Test-Admin)) { throw 'This mode needs an elevated PowerShell (Run as administrator).' }
}

function Write-Log([string]$msg) {
  $line = '{0} {1}' -f (Get-Date -Format 's'), $msg
  Write-Host $line
  if (Test-Path $Dir) { Add-Content -Path $Log -Value $line -ErrorAction SilentlyContinue }
}

function Get-DistroInfo([string]$name) {
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (-not (Test-Path $lxss)) { throw 'No WSL distributions are registered for this user.' }
  $entries = Get-ChildItem $lxss | ForEach-Object { Get-ItemProperty $_.PSPath }
  # Default: the distro this script was started from (\\wsl.localhost\<name>\...),
  # else the WSL default distro unless that is Docker Desktop's own.
  # The installed copy runs from ProgramData, so -Install records the distro.
  if (-not $name -and (Test-Path $Conf)) {
    $name = (Get-Content $Conf | Where-Object { $_ -like '# distro=*' } | Select-Object -First 1) -replace '^# distro=', ''
  }
  if (-not $name -and $PSCommandPath -match '^\\\\wsl(\.localhost|\$)\\([^\\]+)\\') { $name = $Matches[2] }
  if ($name) {
    $d = $entries | Where-Object { $_.DistributionName -eq $name } | Select-Object -First 1
  } else {
    $def = (Get-ItemProperty $lxss).DefaultDistribution
    $d = $entries | Where-Object { $_.PSChildName -eq $def -and $_.DistributionName -notlike 'docker-desktop*' } | Select-Object -First 1
  }
  if (-not $d) { throw "WSL distribution '$name' not found; pass -Distro NAME." }
  $base = $d.BasePath -replace '^\\\\\?\\', ''
  $vhd = if ($d.VhdFileName) { $d.VhdFileName } else { 'ext4.vhdx' }
  [pscustomobject]@{ Name = $d.DistributionName; Vhdx = (Join-Path $base $vhd) }
}

function Get-DiskFiles {
  if (Test-Path $Conf) {
    return @(Get-Content $Conf | Where-Object { $_ -and -not $_.StartsWith('#') })
  }
  $files = @((Get-DistroInfo $Distro).Vhdx)
  $docker = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
  if (-not $NoDocker -and (Test-Path $docker)) { $files += $docker }
  return $files
}

function Test-Sparse([string]$path) {
  ((& fsutil sparse queryflag "$path") -join ' ') -notmatch 'NOT set'
}

function Test-Free([string]$path) {
  try {
    $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
    $fs.Close()
    return $true
  } catch { return $false }
}

function Get-CFree { (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free }

function Invoke-Compact([string]$path) {
  if (-not (Test-Path $path)) { return 'missing' }
  if (Test-Sparse $path) { return 'sparse-skipped' }
  if (-not (Test-Free $path)) { return 'in-use-skipped' }
  $script = [IO.Path]::GetTempFileName()
  Set-Content -Path $script -Encoding ASCII -Value @(
    "select vdisk file=`"$path`"",
    'attach vdisk readonly',
    'compact vdisk',
    'detach vdisk'
  )
  try {
    $out = & diskpart /s $script 2>&1
    $ok = $LASTEXITCODE -eq 0
    Write-Log (($out | Where-Object { $_ -match '\S' } | Select-Object -Last 4) -join ' | ')
  } finally {
    Remove-Item $script -ErrorAction SilentlyContinue
  }
  if (-not $ok) {
    $undo = [IO.Path]::GetTempFileName()
    Set-Content -Path $undo -Encoding ASCII -Value @("select vdisk file=`"$path`"", 'detach vdisk')
    & diskpart /s $undo *> $null
    Remove-Item $undo -ErrorAction SilentlyContinue
    return 'failed'
  }
  return 'ok'
}

function Invoke-CompactAll([string]$mode) {
  $rows = @(); $total = 0; $result = 'ok'
  foreach ($f in Get-DiskFiles) {
    $before = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
    Write-Log "compact start: $f ($([math]::Round($before / 1GB, 1)) GiB)"
    $status = Invoke-Compact $f
    $after = if (Test-Path $f) { (Get-Item $f).Length } else { 0 }
    if ($status -eq 'ok') { $total += ($before - $after) }
    elseif ($status -eq 'failed') { $result = 'failed' }
    elseif ($result -eq 'ok') { $result = 'partial' }
    Write-Log "compact $status`: $f $([math]::Round($before / 1GB, 1)) -> $([math]::Round($after / 1GB, 1)) GiB"
    $rows += "file=$f|$before|$after|$status"
  }
  $lines = @(
    "finished=$(Get-Date -Format 's')",
    "mode=$mode",
    "result=$result",
    "reclaimed_bytes=$total",
    "c_free_bytes=$(Get-CFree)"
  ) + $rows
  if (Test-Path $Dir) { Set-Content -Path $Last -Encoding ASCII -Value $lines }
  Write-Log ("reclaimed {0:N1} GiB; C: free {1:N1} GiB" -f ($total / 1GB), ((Get-CFree) / 1GB))
}

function Invoke-Wsl([string[]]$argv) {
  $out = & wsl.exe @argv 2>&1
  ($out | ForEach-Object { "$_" -replace "`0", '' }) -join "`n"
}

function Set-Dropins([bool]$enable, [string]$name) {
  foreach ($u in $DropinUnits) {
    $d = "/etc/systemd/system/$u.d"
    if ($enable) {
      Invoke-Wsl @('-d', $name, '-u', 'root', '--', 'sh', '-c', "mkdir -p $d && printf '[Unit]\nConditionVirtualization=\n' > $d/firstmate-wsl.conf") | Out-Null
    } else {
      Invoke-Wsl @('-d', $name, '-u', 'root', '--', 'rm', '-f', "$d/firstmate-wsl.conf") | Out-Null
    }
  }
  Invoke-Wsl @('-d', $name, '-u', 'root', '--', 'systemctl', 'daemon-reload') | Out-Null
  if ($enable) {
    Invoke-Wsl @('-d', $name, '-u', 'root', '--', 'systemctl', 'enable', '--now', 'fstrim.timer') | Out-Null
  } else {
    Invoke-Wsl @('-d', $name, '-u', 'root', '--', 'systemctl', 'stop', 'fstrim.timer') | Out-Null
  }
}

function Show-Plan {
  "task installed: $([bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))"
  "file list: $(if (Test-Path $Conf) { $Conf } else { '(not installed; resolved now)' })"
  foreach ($f in Get-DiskFiles) {
    if (Test-Path $f) {
      "{0}  {1:N1} GiB  sparse={2}  in-use={3}" -f $f, ((Get-Item $f).Length / 1GB), (Test-Sparse $f), (-not (Test-Free $f))
    } else { "$f  missing" }
  }
  "C: free: {0:N1} GiB" -f ((Get-CFree) / 1GB)
  if (Test-Path $Last) { 'last result:'; Get-Content $Last }
}

switch ($PSCmdlet.ParameterSetName) {
  'Plan' { Show-Plan }
  'Install' {
    Require-Admin
    $info = Get-DistroInfo $Distro
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    # SYSTEM runs this copy at boot, so only Administrators and SYSTEM may change it.
    & icacls $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    Copy-Item -Path $PSCommandPath -Destination $Installed -Force
    $files = @($info.Vhdx)
    $docker = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
    if (-not $NoDocker -and (Test-Path $docker)) { $files += $docker }
    Set-Content -Path $Conf -Encoding ASCII -Value (@("# distro=$($info.Name)") + $files)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Installed`" -Startup"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Set-Dropins $true $info.Name
    Write-Log "installed: task '$TaskName', files: $($files -join ', '), weekly fstrim in $($info.Name)"
  }
  'Now' {
    Require-Admin
    $info = Get-DistroInfo $Distro
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Write-Log "fstrim in $($info.Name): $(Invoke-Wsl @('-d', $info.Name, '-u', 'root', '--', 'fstrim', '-v', '/'))"
    Write-Log 'wsl --shutdown'
    & wsl.exe --shutdown
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline -and -not (Test-Free $info.Vhdx)) { Start-Sleep -Seconds 2 }
    Invoke-CompactAll 'now'
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $cfg) { Write-Log ".wslconfig now in effect: $((Select-String -Path $cfg -Pattern '^\s*memory\s*=' | Select-Object -First 1).Line)" }
    if (-not $NoRestart) {
      Write-Log "starting $($info.Name)"
      Invoke-Wsl @('-d', $info.Name, '--', 'true') | Out-Null
    }
  }
  'Startup' { Invoke-CompactAll 'startup' }
  'Uninstall' {
    Require-Admin
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $name = (Get-DistroInfo $Distro).Name
    Set-Dropins $false $name
    Remove-Item -Path $Installed, $Conf -ErrorAction SilentlyContinue
    Write-Log "uninstalled: task, script, file list, fstrim drop-ins in $name"
  }
}
