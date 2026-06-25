@echo off
REM Launches a client that auto-joins a server on this machine (127.0.0.1:7000).
REM Run this twice (two windows) to get 2 players so the round starts.

"C:\Godot_v4.6.3-stable_win64.exe" --path "%~dp0." -- --join 127.0.0.1
