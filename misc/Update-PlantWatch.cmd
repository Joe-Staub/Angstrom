@echo off
rem Double-click wrapper: stops PlantWatch, pulls the Angstrom config, restarts PlantWatch.
rem Any arguments are passed straight through, e.g.  Update-PlantWatch.cmd -Branch main
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-PlantWatch.ps1" %*
if errorlevel 1 (
    echo.
    echo Update finished with errors. See messages above.
    pause
)
