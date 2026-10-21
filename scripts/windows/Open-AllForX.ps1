<#
  Open-AllForX.ps1 - DEPRECATED NAME. Renamed 2026-10-14 to afx-terminal-agent-launcher.ps1.
  This shim only forwards, so existing shortcuts, .cmd files and notes keep working. Use the new name.
#>
param(
  [Parameter(Position = 0)][string]$Project,
  [switch]$List, [switch]$Here, [switch]$NoFetch, [switch]$NoClaude, [switch]$IncludePaused,
  [int]$StaggerSeconds = 20, [string]$Model, [string]$Prompt, [switch]$AtProject
)
Write-Host 'Open-AllForX.ps1 is now afx-terminal-agent-launcher.ps1 (forwarding).' -ForegroundColor DarkYellow
& (Join-Path $PSScriptRoot 'afx-terminal-agent-launcher.ps1') @PSBoundParameters