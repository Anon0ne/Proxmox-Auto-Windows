@echo off
rem Drag a Proxmox VE ISO onto this file to run the answer-file wizard.
rem Extra arguments are passed through, e.g.:  Build-AutoIso.cmd proxmox-ve.iso -Config pve01.json
if "%~1"=="" (
  echo Usage: drag a Proxmox ISO onto this file, or run: Build-AutoIso.cmd ^<iso^> [options]
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-ProxmoxAutoIso.ps1" %*
pause
