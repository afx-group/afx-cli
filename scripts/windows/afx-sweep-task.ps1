<#
.SYNOPSIS
  afx-sweep-task: schedule the 2-hourly AFX sweep (afx-sweep.sh) on Windows, the Task Scheduler twin of the Mac's
  launchd afx-sweep.plist. Until 2026-10-20 the Lenovo had no sweep at all, so the guard self-update, fragment
  audit, 8h preserve and daily branch census never ran there ("Sweep status unknown" in every briefing).

.DESCRIPTION
  -Register    (default) create or replace the task "\AFX\AFX Sweep": every 2 hours from now and at logon, hidden.
  -Run         what the task runs: export scripts/afx-guard from the hub's origin/main (git objects only, the hub
               working tree is never touched) to a temp folder and run afx-sweep.sh from there with Git Bash. Running
               the newest sweep each time means a fix merged to main applies on the next run, and the sweep's own
               guard self-update then refreshes ~/.claude/hooks/afx-guard.
  -RunNow      start the registered task now.     -Status   show it.     -Unregister   remove it.
  Hub folder: machine.conf hub=, else the "hub" project in afx-projects.json next to the launcher.
  Log: %USERPROFILE%\.afx\logs\afx-sweep-task.log

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File afx-sweep-task.ps1            # register
  powershell -NoProfile -ExecutionPolicy Bypass -File afx-sweep-task.ps1 -RunNow
#>
[CmdletBinding()]
param([switch]$Register, [switch]$Run, [switch]$RunNow, [switch]$Status, [switch]$Unregister)

$ErrorActionPreference = 'Stop'
$TaskPath = '\AFX\'; $TaskName = 'AFX Sweep'
$bash = 'C:\Program Files\Git\bin\bash.exe'
$logDir = Join-Path $env:USERPROFILE '.afx\logs'; New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'afx-sweep-task.log'
function Log([string]$m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding utf8 }

function Find-Hub {
  $conf = Join-Path $env:USERPROFILE '.claude\hooks\afx-guard\machine.conf'
  if (Test-Path $conf) {
    $line = Get-Content $conf | Where-Object { $_ -like 'hub=*' } | Select-Object -First 1
    if ($line) { $p = $line.Substring(4).Trim(); if (Test-Path (Join-Path $p '.git')) { return $p } }
  }
  $reg = Join-Path $env:USERPROFILE 'Projects\afx-projects.json'
  if (-not (Test-Path $reg)) { $reg = Join-Path $env:USERPROFILE 'Projects\allforx-projects.json' }  # pre-0.1.3 name
  if (Test-Path $reg) {
    $hub = (Get-Content $reg -Raw | ConvertFrom-Json).projects | Where-Object { $_.key -eq 'hub' } | Select-Object -First 1
    if ($hub -and (Test-Path (Join-Path $hub.path '.git'))) { return $hub.path }
  }
  return $null
}

if ($Run) {
  if (-not (Test-Path $bash)) { Log 'FAIL: Git Bash not found (the WSL bash on PATH must not be used)'; exit 1 }
  $hub = Find-Hub
  if (-not $hub) { Log 'FAIL: hub clone not found (machine.conf hub= or afx-projects.json)'; exit 1 }
  $tmp = Join-Path $env:TEMP ("afx-sweep-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    & git -C $hub fetch -q origin main
    $tar = Join-Path $tmp 'guard.tar'
    & git -C $hub archive --format=tar -o $tar origin/main scripts/afx-guard
    & tar -xf $tar -C $tmp
    $sweep = Join-Path $tmp 'scripts\afx-guard\afx-sweep.sh'
    if (-not (Test-Path $sweep)) { Log 'FAIL: export has no afx-sweep.sh'; exit 1 }
    $sha = (& git -C $hub rev-parse --short origin/main).Trim()
    $env:AFX_HUB = $hub
    # Without machine.conf root= the sweep fell back to ~/Projects, so its reports landed in ~/_readiness (the home
    # folder) on 2026-10-20. Use the registry root (the projects root) so they go to Projects\_readiness.
    $conf = Join-Path $env:USERPROFILE '.claude\hooks\afx-guard\machine.conf'
    $hasRoot = (Test-Path $conf) -and (Get-Content $conf | Where-Object { $_ -like 'root=*' })
    $reg = Join-Path $env:USERPROFILE 'Projects\afx-projects.json'
  if (-not (Test-Path $reg)) { $reg = Join-Path $env:USERPROFILE 'Projects\allforx-projects.json' }  # pre-0.1.3 name
    if (-not $hasRoot -and -not $env:AFX_CLONES_ROOT -and (Test-Path $reg)) {
      $root = (Get-Content $reg -Raw | ConvertFrom-Json).root
      if ($root -and (Test-Path $root)) { $env:AFX_CLONES_ROOT = $root.Replace('\', '/') }
    }
    $out = & $bash $sweep.Replace('\', '/') 2>&1
    $code = $LASTEXITCODE
    Log ("sweep exit={0} hub={1} :: {2}" -f $code, $sha, (($out | Select-Object -Last 2) -join ' | '))
    exit $code
  } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

if ($Status) { Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo | Format-List TaskName, LastRunTime, LastTaskResult, NextRunTime; exit 0 }
if ($RunNow) { Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName; "started $TaskPath$TaskName"; exit 0 }
if ($Unregister) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false; "removed $TaskPath$TaskName"; exit 0 }

# Register (default). The task runs a stable copy in ~/.afx/bin, never a worktree or a clone's working folder; each
# run still exports the newest afx-sweep.sh from origin/main, so this small runner rarely needs re-registering.
$binDir = Join-Path $env:USERPROFILE '.afx\bin'; New-Item -ItemType Directory -Force $binDir | Out-Null
$self = Join-Path $binDir 'afx-sweep-task.ps1'
if ($PSCommandPath -ne $self) { Copy-Item -Force $PSCommandPath $self }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`" -Run" -f $self)
# Two triggers: a repeating one from now (a logon trigger's repetition only starts at the NEXT logon, which left
# "Next run" blank on 2026-10-20), plus logon so a reboot runs it straight away.
$every2h = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 2)
$trigger = @($every2h, (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'AFX 2-hourly sweep: guard self-update from hub origin/main, fragment audit, 8h preserve, daily branch census (scripts/afx-guard/windows/afx-sweep-task.ps1)' -Force | Out-Null
"registered $TaskPath$TaskName -> $self -Run (at logon, then every 2h)"
