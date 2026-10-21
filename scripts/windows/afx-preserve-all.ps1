<#
.SYNOPSIS
  Windows entrypoint for afx-preserve-all.sh (push every piece of
  machine-local code to archive/<machine>/... without touching anyone's
  working tree).

.DESCRIPTION
  Thin wrapper over ../afx-preserve-all.sh via Git for Windows' bash.exe.
  There is no native-PowerShell fallback for this one (unlike afx-preflight):
  the git-plumbing logic (temp-index snapshots, commit-tree, per-worktree
  walk) is intricate enough that a second implementation would be a real
  maintenance and correctness risk, exactly the "two codebases drift" problem
  called out in afx-run.ps1's header. Preserve-all is not time-critical the
  way a preflight gate is, so "install Git for Windows" (already required for
  this repo) is a reasonable hard dependency here.

.EXAMPLE
  .\afx-preserve-all.ps1 lenovo "C:\Users\you\Projects"
#>
[CmdletBinding()]
param(
  [string]$MachineLabel = "lenovo",
  [string]$Root = "",
  [string]$SkipSubstring = ""
)

# Check Git for Windows' own install locations first -- Get-Command bash.exe
# alone is unreliable on a machine with WSL installed, since its launcher at
# System32\bash.exe is often found before Git's (Git's bin\ directory is
# frequently missing from PATH even when git.exe, in cmd\, is present). WSL's
# bash cannot resolve the Windows-style paths this script passes it.
$candidates = @(
  "$env:ProgramFiles\Git\bin\bash.exe",
  "$env:ProgramFiles(x86)\Git\bin\bash.exe",
  "$env:LocalAppData\Programs\Git\bin\bash.exe"
)
$bashPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bashPath) {
  $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
  if ($onPath -and $onPath.Source -notmatch '\\System32\\bash\.exe$') { $bashPath = $onPath.Source }
}
if (-not $bashPath) { throw "Git for Windows' bash.exe not found (checked common install paths and PATH, excluding the WSL launcher). afx-preserve-all has no native-PowerShell fallback (see script header) - install Git for Windows." }

$scriptDir = Split-Path -Parent $PSScriptRoot
$shScript = Join-Path $scriptDir 'afx-preserve-all.sh'
# bash needs POSIX-ish paths for -C targets it walks into; Git Bash translates
# a plain Windows path like C:\Users\... on the command line automatically,
# so no manual path translation is required here.
$shArgs = @($MachineLabel)
if ($Root) { $shArgs += $Root }
if ($SkipSubstring) { $shArgs += $SkipSubstring }
& $bashPath $shScript @shArgs
exit $LASTEXITCODE
