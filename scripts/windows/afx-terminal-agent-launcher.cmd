@echo off
rem afx-terminal-agent-launcher wrapper: runs from anywhere (cmd, Run dialog, a shortcut) without changing the PowerShell execution policy.
rem Usage:  afx-terminal-agent-launcher list | afx-terminal-agent-launcher <key> | ... hub -Model sonnet | ... root | ... all
rem Sessions start in the home folder; add -AtProject to start inside the clone.
if /I "%~1"=="list" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0afx-terminal-agent-launcher.ps1" -List
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0afx-terminal-agent-launcher.ps1" %*
)