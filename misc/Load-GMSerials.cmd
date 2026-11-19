@echo off
rem Empties PWInventory2 of every item and box and loads the checked GM serials
rem (C:\AxleReports\GM-Serials\GM-Serials-Checked.csv from Prepare-GMSerials.ps1).
rem Back the database up first: Backup-PWInventory.cmd
rem
rem   Load-GMSerials.cmd                 preview: does everything, then rolls back
rem   Load-GMSerials.cmd commit          wipe and load
rem   Load-GMSerials.cmd commit Axletube\SQLEXPRESS    ...on another instance (default localhost\SQLEXPRESS)
setlocal
set ARGS=
if /i "%~1"=="commit" set ARGS=-Commit
if not "%~2"=="" set ARGS=%ARGS% -Instance "%~2"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Load-GMSerials.ps1" %ARGS%
echo.
pause
