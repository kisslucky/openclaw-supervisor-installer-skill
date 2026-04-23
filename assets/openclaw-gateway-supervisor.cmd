@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0openclaw-gateway-supervisor.ps1" -ConfigPath "%~dp0config.json" %*
