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
              "Firstmate WSL compact at startup" task (SYSTEM, at boot).
              Run it while the distro is running.
  -Now        wsl --shutdown, compact every recorded disk file, print
              before/after, and start the distro again (-NoRestart leaves it
              stopped). Stops every WSL process.
  -Startup    what the task runs at boot: compact every recorded disk file
              that nothing holds open; skips a file in use.
  -Uninstall  remove the task and the ProgramData script, file list and
              shadow storage record. Logs are kept.

Options: -Distro NAME (default: the WSL default distro), -NoDocker (leave
docker_data.vhdx out of -Install's file list), -NoRestart (with -Now).

Output: C:\ProgramData\firstmate\wsl-compact.log (appended) and
wsl-compact-last.txt (key=value: finished, mode, result, reclaimed_bytes,
c_free_bytes, then one file=<path>|<before>|<after>|<status> line per disk).
-Install, -Now and -Startup also rewrite shadow-storage.txt (key=value:
recorded, recorded_epoch, volume, max_bytes, used_bytes, allocated_bytes) with
the restore-point shadow storage held on the system drive, read from
Win32_ShadowStorage, which needs elevation. max_bytes=unbounded means no cap;
0 bytes means no shadow storage. bin/fm-disk-room.sh reserves max minus used.
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
$Shadow = Join-Path $Dir 'shadow-storage.txt'

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
  ((Get-Item $path).Attributes -band [IO.FileAttributes]::SparseFile) -ne 0
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
  $ErrorActionPreference = 'Continue'
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

# Format-ShadowRecord: the shadow-storage.txt lines for the storages whose diff
# area lives on $VolumeId (every match is summed); a MaxSpace of 2^63 or more is
# how Windows reports UNBOUNDED.
function Format-ShadowRecord($Storages, [string]$VolumeId, [string]$Volume, [datetime]$When) {
  $max = [decimal]0; $used = [decimal]0; $alloc = [decimal]0; $unbounded = $false
  foreach ($s in @($Storages | Where-Object { $_ -and $_.DiffVolume.DeviceID -eq $VolumeId })) {
    if ([decimal]$s.MaxSpace -ge [decimal]9223372036854775808) { $unbounded = $true } else { $max += [decimal]$s.MaxSpace }
    $used += [decimal]$s.UsedSpace
    $alloc += [decimal]$s.AllocatedSpace
  }
  $utc = $When.ToUniversalTime()
  @(
    "recorded=$($utc.ToString('s'))Z",
    "recorded_epoch=$([int64]($utc - [datetime]'1970-01-01T00:00:00').TotalSeconds)",
    "volume=$Volume",
    "max_bytes=$(if ($unbounded) { 'unbounded' } else { $max })",
    "used_bytes=$used",
    "allocated_bytes=$alloc"
  )
}

# Save-ShadowRecord: record the system drive's shadow storage for the monitor.
# A failed read is logged and leaves the previous record, which the monitor
# ages out rather than trusting.
function Save-ShadowRecord {
  try {
    $drive = $env:SystemDrive
    $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$drive'"
    $lines = Format-ShadowRecord @(Get-CimInstance -ClassName Win32_ShadowStorage) $vol.DeviceID $drive (Get-Date)
    if (Test-Path $Dir) { Set-Content -Path $Shadow -Encoding ASCII -Value $lines }
    Write-Log "shadow storage: $(($lines | Select-Object -Skip 3) -join ' ')"
  } catch {
    Write-Log "shadow storage: not recorded: $($_.Exception.Message)"
  }
}

function Invoke-Wsl([string[]]$argv) {
  $ErrorActionPreference = 'Continue'
  $out = & wsl.exe @argv 2>&1
  $text = ($out | ForEach-Object { "$_" -replace "`0", '' }) -join "`n"
  "exit $LASTEXITCODE$(if ($text) { ": $text" })"
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
  if (Test-Path $Shadow) { 'shadow storage record:'; Get-Content $Shadow }
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
    Write-Log "installed: task '$TaskName', files: $($files -join ', ')"
    Save-ShadowRecord
  }
  'Now' {
    Require-Admin
    $info = Get-DistroInfo $Distro
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    Write-Log 'wsl --shutdown'
    & wsl.exe --shutdown
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline -and -not (Test-Free $info.Vhdx)) { Start-Sleep -Seconds 2 }
    Invoke-CompactAll 'now'
    Save-ShadowRecord
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $cfg) { Write-Log ".wslconfig now in effect: $((Select-String -Path $cfg -Pattern '^\s*memory\s*=' | Select-Object -First 1).Line)" }
    if (-not $NoRestart) {
      Write-Log "starting $($info.Name): $(Invoke-Wsl @('-d', $info.Name, '--', 'true'))"
    }
  }
  'Startup' { Invoke-CompactAll 'startup'; Save-ShadowRecord }
  'Uninstall' {
    Require-Admin
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $Installed, $Conf, $Shadow -ErrorAction SilentlyContinue
    Write-Log 'uninstalled: task, script, file list, shadow storage record'
  }
}
