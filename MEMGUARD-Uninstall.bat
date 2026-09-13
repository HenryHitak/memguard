@echo off
REM MEMGUARD uninstaller - double-click to remove the widget, auto-start task, and shortcuts.
REM Self-elevates (UAC) because removing the scheduled task needs admin.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memguard.ps1" -Uninstall
