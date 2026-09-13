# MEMGUARD

A lightweight, always-on-top Windows widget that shows live system usage
(CPU / GPU / RAM / SSD), lists every process by memory, and frees RAM on demand —
with a game mode that keeps your game smooth by trimming everything else.

Single PowerShell script, packaged into a dependency-free `MEMGUARD.exe`
(uses only Windows built-in .NET / WPF).

## Features
- Live CPU / GPU / RAM / SSD gauges — hover any gauge to see the actual hardware model
- Full process list by memory, each row with a one-click END (kill) button and a hover
  tip explaining what the program is and whether it is safe to trim
- TRIM NOW — frees working-set RAM from background apps (system-critical processes are never touched)
- Game mode (`-Game auto` or a process name) — boosts the game to High priority and trims
  everything else only when RAM gets tight, so the game does not stutter
- Optimization suggestions (memory compression, XMP/EXPO, startup apps) with one-click APPLY
  for the safe, reversible ones
- AI plan panel — your Claude / Codex subscription plan and this month token usage
  (reads local files only; see Privacy)
- Resizable (corner grip), double-click to maximize, wheel to scroll the list,
  Ctrl+wheel to scale, Shift+wheel for opacity
- Auto-start at login, desktop / Start-Menu shortcut, and a clean uninstaller

## Requirements
- Windows 10 / 11
- Run as administrator for full trim reach (non-admin still trims most user apps)

## Install
Download `MEMGUARD.exe` and run it. To auto-start at login and add shortcuts:

    MEMGUARD.exe -Install

## Uninstall
Double-click `MEMGUARD-Uninstall.bat`, or run:

    MEMGUARD.exe -Uninstall

Removes the auto-start task, shortcuts, and settings; then delete the files.

## Controls
- Drag body = move, drag corner grip = resize, double-click = maximize / restore
- X = hide the widget (reopen with the app icon — pin it to the taskbar for one click)
- Wheel = scroll the process list, Ctrl+wheel = scale, Shift+wheel = opacity

## Privacy
Everything stays on your machine. Nothing is ever sent over the network.
The AI plan panel reads local files only, and shows `--` if they are absent:
- `~/.claude/.credentials.json` — your Claude plan tier (not the token)
- `~/.codex/auth.json` — your Codex plan, decoded locally
- `~/.claude/ai-token-monitor-*.json` — token-usage cache (if you use AI Token Monitor)

## Build from source
Requires the `ps2exe` module:

    Install-Module ps2exe -Scope CurrentUser
    Invoke-ps2exe -inputFile memguard.ps1 -outputFile MEMGUARD.exe -iconFile MEMGUARD.ico -noConsole -STA

Run the self-test:

    powershell -NoProfile -ExecutionPolicy Bypass -File memguard.ps1 -SelfTest

## Known limitation
The notification-area (tray) icon does not register reliably when packaged with ps2exe,
so MEMGUARD uses a hidden-window model: X hides the widget and you reopen it via the app icon.

## License
MIT — see LICENSE.