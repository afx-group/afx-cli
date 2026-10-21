@echo off
rem afx wrapper for cmd, PowerShell, the Run dialog and shortcuts: runs scripts\afx-guard\afx through Git Bash.
rem Usage: afx | afx list | afx <key> | afx fleet --json | afx where | afx help   (see the header of ..\afx)
set "AFX_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%AFX_BASH%" set "AFX_BASH=bash.exe"
"%AFX_BASH%" "%~dp0..\afx" %*
