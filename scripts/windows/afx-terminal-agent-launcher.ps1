<#
.SYNOPSIS
  afx-terminal-agent-launcher (the older launcher name remains as a forwarding shim):
  the one way to start a Claude Code session for an AFX project. Starts in the machine's home folder.

.DESCRIPTION
  Opens a dedicated PowerShell window in the machine's home folder (override: AFX_LAUNCH_DIR;
  -AtProject uses the clone instead), reads the project's canonical clone from
  afx-projects.json next to this script, checks that the folder really is
  that project's repo, fetches (never pulls), prints what is unpushed or
  uncommitted, and starts claude there.

.EXAMPLE
  .\afx-terminal-agent-launcher.ps1 -List
  .\afx-terminal-agent-launcher.ps1 my-app
  .\afx-terminal-agent-launcher.ps1 hub -Model sonnet
  .\afx-terminal-agent-launcher.ps1 other-app -NoClaude          # status only
  .\afx-terminal-agent-launcher.ps1 all                    # one window per active project, staggered
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Project,
  [switch]$List,
  [switch]$Here,           # run in this window instead of opening a new one
  [switch]$NoFetch,
  [switch]$NoClaude,       # print status and stop
  [switch]$IncludePaused,  # with "all": also open paused projects
  [int]$StaggerSeconds = 20,
  [string]$Model,
  [string]$Prompt,
  [switch]$AtProject       # start IN the project's clone instead of the Projects root (owner decision 2026-10-14: root is the default)
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $PSScriptRoot 'afx-projects.json'
if (-not (Test-Path $configPath)) { $configPath = Join-Path $PSScriptRoot 'allforx-projects.json' }  # pre-0.1.3 name
if (-not (Test-Path $configPath)) { throw "Missing $configPath - it is the source of truth for project paths." }
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$projects = $config.projects
# Owner decision 2026-10-14: sessions start in the machine's home folder (override: AFX_LAUNCH_DIR), not in a clone.
$homeDir = $(if ($env:AFX_LAUNCH_DIR) { $env:AFX_LAUNCH_DIR } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME })

function Show-List {
  $projects | ForEach-Object {
    [pscustomobject]@{
      Key     = $_.key
      Project = $_.name
      Target  = $(if ($_.stagingBranch) { $_.stagingBranch } else { $_.defaultBranch })
      State   = $(if (-not (Test-Path (Join-Path $_.path '.git'))) { 'MISSING' } elseif ($_.paused) { 'paused' } elseif ($_.notes) { 'see notes' } else { 'ok' })
      Path    = $_.path
    }
  } | Format-Table -AutoSize -Wrap
  $projects | Where-Object { $_.notes } | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.key, $_.notes) -ForegroundColor DarkYellow }
}

function Resolve-Project([string]$name) {
  $n = $name.ToLower()
  $hit = $projects | Where-Object { $_.key -eq $n -or ($_.aliases -contains $n) -or $_.name.ToLower() -eq $n }
  if (-not $hit) { Show-List; throw "Unknown project '$name'. Use one of the keys above. Do not start sessions from any other folder." }
  return $hit
}

function Get-RepoSlug([string]$url) {
  return ($url -replace '\.git$', '' -replace '^.*github\.com[:/]', '').ToLower()
}

if ($List -or -not $Project) { Show-List; return }

if ($Project -eq 'all') {
  # "all" means the 13 projects plus afx-standards; hub-support repos ("support": true) open only by key.
  $targets = $projects | Where-Object { -not $_.support -and ($IncludePaused -or -not $_.paused) }
  Write-Host ("Opening {0} windows, {1}s apart. Each window asks for its own permission approvals, and this PC ran out of memory on 2026-09-19 - close windows you are not using." -f $targets.Count, $StaggerSeconds) -ForegroundColor Yellow
  foreach ($t in $targets) {
    & $PSCommandPath -Project $t.key -Model $Model -NoFetch:$NoFetch -NoClaude:$NoClaude
    Start-Sleep -Seconds $StaggerSeconds
  }
  return
}

# "root": a general session at the Projects root with no focus project (portfolio-wide / orchestration work).
if ($Project -eq 'root') {
  if (-not $Here) {
    $argList = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Project', 'root', '-Here')
    if ($Model) { $argList += @('-Model', $Model) }
    if ($Prompt) { $argList += @('-Prompt', "`"$($Prompt -replace '"', "'")`"") }
    Start-Process powershell.exe -WorkingDirectory $homeDir -ArgumentList $argList | Out-Null
    Write-Host "Opened a root window in $homeDir"
    return
  }
  Set-Location -LiteralPath $homeDir
  $host.UI.RawUI.WindowTitle = 'AFX - root'
  if ($NoClaude) { Write-Host "Root session folder: $homeDir"; return }
  $claudeArgs = @()
  if ($Model) { $claudeArgs += @('--model', $Model) }
  if ($Prompt) { $claudeArgs += $Prompt }
  & claude @claudeArgs
  return
}

$p = Resolve-Project $Project

# --- validate before anything opens -----------------------------------------
if (-not (Test-Path (Join-Path $p.path '.git'))) {
  throw "Canonical clone for $($p.name) is missing or is not a git repo: $($p.path)`nDo NOT clone it somewhere else. Fix the path in $configPath or ask the owner."
}
# `git config --get` prints nothing (and nothing on stderr) when there is no origin; in Windows PowerShell 5.1 any
# stderr output from a native command becomes a terminating error under $ErrorActionPreference = 'Stop'.
$originUrl = (& git -C $p.path config --get remote.origin.url)
if (-not $originUrl) { throw "$($p.path) has no 'origin' remote. A repo with no remote is a bug - stop and tell the owner." }
if ((Get-RepoSlug $originUrl) -ne $p.repo.ToLower()) {
  throw "Wrong repo in the canonical folder for $($p.name): origin is '$originUrl' but expected github.com/$($p.repo)."
}

if (-not $Here) {
  $argList = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Project', $p.key, '-Here')
  if ($NoFetch) { $argList += '-NoFetch' }
  if ($NoClaude) { $argList += '-NoClaude' }
  if ($Model) { $argList += @('-Model', $Model) }
  if ($Prompt) { $argList += @('-Prompt', "`"$($Prompt -replace '"', "'")`"") }
  if ($AtProject) { $argList += '-AtProject' }
  $startDir = $(if ($AtProject) { $p.path } else { $homeDir })
  Start-Process powershell.exe -WorkingDirectory $startDir -ArgumentList $argList | Out-Null
  Write-Host "Opened a window for $($p.name) in $startDir"
  return
}

# --- inside the project window ----------------------------------------------
# Default: the session lives at the home folder so it can do broader work; the project's clone is
# inspected with `git -C` and named in the session's context. -AtProject starts inside the clone instead.
$startDir = $(if ($AtProject) { $p.path } else { $homeDir })
Set-Location -LiteralPath $startDir
$host.UI.RawUI.WindowTitle = "AFX - $($p.name)"
$target = $(if ($p.stagingBranch) { $p.stagingBranch } else { $p.defaultBranch })

Write-Host ""
Write-Host "=== $($p.name) ===" -ForegroundColor Cyan
Write-Host "Session: $startDir$(if (-not $AtProject) { '   (home folder; project work happens in the clone below via a worktree)' })"
Write-Host "Folder : $($p.path)"
Write-Host "GitHub : $($p.repo)   work targets: $target   (main changes only via afx-land.sh from a wip/ worktree)"
if ($p.paused) { Write-Host "PAUSED : the owner has paused this project. Do not start new work without their say-so." -ForegroundColor Red }
if ($p.notes) { Write-Host "NOTE   : $($p.notes)" -ForegroundColor Yellow }

if (-not $NoFetch) {
  Write-Host "Fetching (remote refs only - nothing is pulled or merged)..."
  $ErrorActionPreference = 'Continue'   # git writes progress and warnings to stderr; that must not abort the launcher
  & git -C $p.path fetch origin --quiet
  if ($LASTEXITCODE -ne 0) { Write-Host "  fetch failed - status below may be stale" -ForegroundColor Yellow }
  $ErrorActionPreference = 'Stop'
}

$branch = (& git -C $p.path rev-parse --abbrev-ref HEAD)
$statusLines = @(& git -C $p.path status --porcelain)
$modified = @($statusLines | Where-Object { $_ -notmatch '^\?\?' }).Count
$untracked = @($statusLines | Where-Object { $_ -match '^\?\?' }).Count
$unpushed = @(& git -C $p.path log --branches --not --remotes --oneline).Count
$stashes = @(& git -C $p.path stash list).Count
$worktrees = @(& git -C $p.path worktree list).Count - 1
$behindTarget = 0; $aheadTarget = 0
& git -C $p.path rev-parse --verify --quiet "refs/remotes/origin/$target" | Out-Null
$haveTargetRef = ($LASTEXITCODE -eq 0)
if ($haveTargetRef) {
  $behindTarget = (& git -C $p.path rev-list --count "HEAD..origin/$target")
  $aheadTarget = (& git -C $p.path rev-list --count "origin/$target..HEAD")
}

Write-Host ""
if ($haveTargetRef) {
  Write-Host ("Branch : {0}   vs origin/{1}: {2} ahead, {3} behind" -f $branch, $target, $aheadTarget, $behindTarget)
} else {
  Write-Host ("Branch : {0}   (origin/{1} is not known locally yet - run without -NoFetch)" -f $branch, $target) -ForegroundColor Yellow
}
Write-Host ("Local  : {0} modified, {1} untracked, {2} stash(es), {3} extra worktree(s)" -f $modified, $untracked, $stashes, $worktrees)
if ($unpushed -gt 0) { Write-Host "UNPUSHED: $unpushed commit(s) exist on no remote. Push them to a branch before doing anything else." -ForegroundColor Red }
if ($modified -gt 0) { Write-Host "UNCOMMITTED: $modified modified file(s). If they are not yours, leave them alone and tell the owner. Never restore, reset, clean or stash them away." -ForegroundColor Red }
if ([int]$behindTarget -gt 0) { Write-Host "BEHIND: do not pull blindly. Look at 'git log HEAD..origin/$target --stat' first; with local changes present, ask the owner." -ForegroundColor Yellow }
Write-Host ""

if ($NoClaude) { return }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw "claude is not on PATH in this window." }

$claudeArgs = @()
if ($Model) { $claudeArgs += @('--model', $Model) }
if (-not $AtProject) {
  $ctx = "Session started at the home folder $homeDir by owner decision (2026-10-14), not inside a clone; projects live under $($config.root). Focus project: $($p.name) ($($p.key)), canonical clone $($p.path), repo $($p.repo), work branches target origin/$($p.defaultBranch). Do project work in a worktree under $($p.path)\.claude\worktrees\<name>; never git init or clone; never touch uncommitted changes you did not make. Land with afx-land.sh (AFX_GUARD_DIR) from a wip/ worktree."
  $claudeArgs += @('--append-system-prompt', $ctx)
}
if ($Prompt) { $claudeArgs += $Prompt }
& claude @claudeArgs
