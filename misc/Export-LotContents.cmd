@echo off
rem Double-click wrapper: exports every box and its tubes to C:\AxleReports\LotContents_<date>.csv.
rem Any arguments are passed straight through, e.g.  Export-LotContents.cmd -Lot L00012
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-LotContents.ps1" %*
if errorlevel 1 (
    echo.
    echo Export finished with errors. See messages above.
    pause
)
