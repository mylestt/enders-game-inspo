@echo off
REM Launches a dedicated, headless authoritative server for this project.
REM No local player; it just runs the simulation + RoundManager and waits for clients.
REM Stop it with Ctrl+C or by closing this window.

"C:\Godot_v4.6.3-stable_win64.exe" --headless --path "%~dp0." -- --server --port 7000

echo.
echo Server stopped.
pause
