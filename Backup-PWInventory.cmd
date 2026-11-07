@echo off
rem Double-click wrapper: backs up the PWInventory database to C:\PWInventoryBackups\YYYYMMDD.BAK.
rem Any arguments are passed straight through, e.g.  Backup-PWInventory.cmd -Register
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup-PWInventory.ps1" %*
if errorlevel 1 (
    echo.
    echo Backup finished with errors. See messages above and C:\PWInventoryBackups\Backup.log.
    pause
)
