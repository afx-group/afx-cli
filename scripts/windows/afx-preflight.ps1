<#
.SYNOPSIS
  Windows entrypoint for afx-preflight.sh (disk/load/memory/worktree health
  check before heavy work).

.DESCRIPTION
  Thin wrapper over ../afx-preflight.sh via Git for Windows' bash.exe — see
  afx-run.ps1's header comment for why this repo prefers one bash
  implementation over a parallel PowerShell one. If bash.exe genuinely cannot
  be found, falls back to a native PowerShell equivalent so a preflight check
  is never simply skipped; the native path is a heuristic approximation
  (documented in AFX_PLATFORM_PARITY.md), not bit-for-bit identical output.

.EXAMPLE
  .\afx-preflight.ps1 -MinFreeGB 20 -MaxLoad 12
#>
[CmdletBinding()]
param(
  [int]$MinFreeGB = 20,
  [int]$MaxLoad = 12,
  [string]$ClonesRoot = ""
)

function Find-GitBash {
  # Check Git for Windows' own install locations first -- Get-Command bash.exe
  # alone is unreliable on a machine with WSL installed, since its launcher at
  # System32\bash.exe is often found before Git's (Git's bin\ directory is
  # frequently missing from PATH even when git.exe, in cmd\, is present).
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles(x86)\Git\bin\bash.exe",
    "$env:LocalAppData\Programs\Git\bin\bash.exe"
  )
  $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($found) { return $found }
  $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
  if ($onPath -and $onPath.Source -notmatch '\\System32\\bash\.exe$') { return $onPath.Source }
  return $null
}

$bashPath = Find-GitBash
if ($bashPath) {
  $scriptDir = Split-Path -Parent $PSScriptRoot
  $shScript = Join-Path $scriptDir 'afx-preflight.sh'
  $shArgs = @('--min-free-gb', $MinFreeGB, '--max-load', $MaxLoad)
  if ($ClonesRoot) { $shArgs += @('--clones-root', $ClonesRoot) }
  & $bashPath $shScript @shArgs
  exit $LASTEXITCODE
}

Write-Warning "Git Bash not found; running the native PowerShell preflight fallback (heuristic, see AFX_PLATFORM_PARITY.md)."
$fail = $false

$drive = (Get-Item $PSScriptRoot).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB)
Write-Host "platform: windows"
Write-Host "disk free: ${freeGB}GB (min ${MinFreeGB})"
if ($freeGB -lt $MinFreeGB) { Write-Host "  FAIL: free disk." -ForegroundColor Red; $fail = $true }

# No true loadavg on Windows; approximate as (CPU% busy / 100 * ncpu).
$pct = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
$ncpu = $env:NUMBER_OF_PROCESSORS
$load = [math]::Round(($pct / 100.0) * $ncpu, 2)
Write-Host "load (1m, approx): $load (max $MaxLoad)"
if ($load -gt $MaxLoad) { Write-Host "  FAIL: load." -ForegroundColor Red; $fail = $true }

$os = Get-CimInstance Win32_OperatingSystem
$freeMemMB = [math]::Round($os.FreePhysicalMemory / 1024)
$totalMemMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
Write-Host "memory: freeMB=$freeMemMB totalMB=$totalMemMB"

# Git config hygiene: stale safe.directory entries pointing at forbidden or
# missing paths (Windows/Lenovo finding, 2026-09-27: dozens of stale
# C:\afx\... entries from before that path was declared forbidden).
$safeDirs = & git config --global --get-all safe.directory 2>$null
foreach ($p in $safeDirs) {
  if ($p -match '^[Cc]:[\\/]afx') { Write-Host "STALE-CONFIG safe.directory=$p (forbidden legacy path)" }
  elseif (-not (Test-Path $p)) { Write-Host "STALE-CONFIG safe.directory=$p (path does not exist)" }
}

if ($ClonesRoot -and (Test-Path $ClonesRoot)) {
  Get-ChildItem -Directory $ClonesRoot | ForEach-Object {
    Push-Location $_.FullName
    try {
      $n = (git worktree list 2>$null | Measure-Object).Count - 1
      if ($n -gt 6) { Write-Host "worktrees: $($_.Name) has $n; remove merged ones" }
    } finally { Pop-Location }
  }
} else {
  Write-Host "worktrees: skipped (pass -ClonesRoot)"
}

if ($fail) { exit 1 } else { exit 0 }
