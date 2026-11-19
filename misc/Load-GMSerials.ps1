<#
.SYNOPSIS
    Empties PWInventory2 of every item and loads the checked GM serial numbers in their place.
.DESCRIPTION
    One transaction: every genealogy link, item attribute, route step and item goes (boxes
    included: with no tubes left they would be empty, and box numbering starts again at 1),
    then one Item per row of GM-Serials-Checked.csv (from Prepare-GMSerials.ps1): the
    22-character serial, its part from characters 15-22, the default status, quantity 1, and a
    Birth_DateTime decoded from the serial's year and day of year, so day reports show the
    serials on the days they were made rather than on the day they were loaded.

    Without -Commit the script does all of it and rolls back, printing what would happen.
    Back the database up first (Backup-PWInventory.cmd).
.PARAMETER CsvPath   The checked file (default C:\AxleReports\GM-Serials\GM-Serials-Checked.csv).
.PARAMETER Instance  SQL Server instance (default localhost\SQLEXPRESS).
.PARAMETER Database  Default PWInventory2.
.PARAMETER Entity    The company the items belong to (default Angstrom).
.PARAMETER Commit    Actually write. Without it: preview and roll back.
.EXAMPLE
    .\Load-GMSerials.ps1                       preview
    .\Load-GMSerials.ps1 -Commit               wipe and load
#>
param(
    [string] $CsvPath = 'C:\AxleReports\GM-Serials\GM-Serials-Checked.csv',
    [string] $Instance = 'localhost\SQLEXPRESS',
    [string] $Database = 'PWInventory2',
    [string] $Entity = 'Angstrom',
    [switch] $Commit
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$rows = @(Import-Csv $CsvPath)
if ($rows.Count -eq 0) { throw "No rows in $CsvPath" }

# Decode the birth date from the serial: ESAT yy ddd ...
$table = New-Object Data.DataTable
foreach ($c in 'Serial', 'Part') { [void]$table.Columns.Add($c, [string]) }
[void]$table.Columns.Add('Birth', [datetime])
$bad = @()
foreach ($r in $rows) {
    $serial = $r.Serial.Trim().ToUpperInvariant()
    if ($serial.Length -ne 22) { $bad += "$serial is $($serial.Length) characters"; continue }
    $yy = [int]$serial.Substring(4, 2); $ddd = [int]$serial.Substring(6, 3)
    if ($ddd -lt 1 -or $ddd -gt 366) { $bad += "$serial has day of year $ddd"; continue }
    $birth = (Get-Date -Year (2000 + $yy) -Month 1 -Day 1 -Hour 12 -Minute 0 -Second 0 -Millisecond 0).AddDays($ddd - 1)
    if ($birth.Year -ne 2000 + $yy) { $bad += "$serial has day of year $ddd in a year of fewer days"; continue }
    [void]$table.Rows.Add($serial, $serial.Substring(14, 8), $birth)
}
if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Host "REJECTED: $_" -ForegroundColor Red }; throw "$($bad.Count) serial(s) could not be decoded; fix the file first." }

Write-Host ("{0} serials to load into {1} on {2}; birth dates {3:yyyy-MM-dd} to {4:yyyy-MM-dd}" -f $table.Rows.Count, $Database, $Instance,
    ($table.Rows | ForEach-Object { $_.Birth } | Measure-Object -Minimum).Minimum, ($table.Rows | ForEach-Object { $_.Birth } | Measure-Object -Maximum).Maximum)

$conn = New-Object Data.SqlClient.SqlConnection "Data Source=$Instance;Initial Catalog=$Database;Integrated Security=SSPI;Application Name=Load-GMSerials"
$conn.Open()
$tx = $conn.BeginTransaction()
function Scalar($sql) { $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandText = $sql; $cmd.ExecuteScalar() }
function Exec($sql) { $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandText = $sql; $cmd.CommandTimeout = 300; $cmd.ExecuteNonQuery() }
try {
    Exec "SET QUOTED_IDENTIFIER ON" | Out-Null
    $before = Scalar "SELECT CAST((SELECT COUNT(*) FROM dbo.Item) AS varchar(10)) + ' items, ' + CAST((SELECT COUNT(*) FROM dbo.Item_Gene) AS varchar(10)) + ' links, ' + CAST((SELECT COUNT(*) FROM dbo.Item WHERE Part_Number LIKE 'LOT%') AS varchar(10)) + ' boxes'"
    Write-Host "Before: $before"

    $missingParts = Scalar "SELECT COUNT(*) FROM (SELECT DISTINCT p FROM (VALUES ('85545338'), ('85545339')) v(p)) parts WHERE NOT EXISTS (SELECT 1 FROM dbo.Part WHERE Entity = '$Entity' AND Part_Number = parts.p)"
    if ($missingParts -gt 0) { throw "A part is missing from dbo.Part for $Entity; nothing changed." }
    $status = Scalar "SELECT Status_Name FROM dbo.Item_Status WHERE Default_Status = 1"
    if (-not $status) { throw "No default Item_Status; nothing changed." }

    Write-Host ("Removed: {0} links, {1} attributes, {2} route steps, {3} items" -f (Exec "DELETE FROM dbo.Item_Gene"), (Exec "DELETE FROM dbo.Item_Attribute"), (Exec "DELETE FROM dbo.Item_RouteOp"), (Exec "DELETE FROM dbo.Item"))

    Exec "CREATE TABLE #GM (Serial varchar(100) NOT NULL PRIMARY KEY, Part varchar(100) NOT NULL, Birth datetime NOT NULL)" | Out-Null
    $bulk = New-Object Data.SqlClient.SqlBulkCopy($conn, [Data.SqlClient.SqlBulkCopyOptions]::Default, $tx)
    $bulk.DestinationTableName = '#GM'
    $bulk.WriteToServer($table)
    $inserted = Exec "INSERT INTO dbo.Item (Entity, Serial_Nbr, Part_Number, Status, Birth_DateTime, LotQuantity) SELECT '$Entity', Serial, Part, '$status', Birth, 1 FROM #GM ORDER BY Birth, Serial"
    Write-Host "Loaded: $inserted items with status '$status'"

    $after = Scalar "SELECT CAST((SELECT COUNT(*) FROM dbo.Item) AS varchar(10)) + ' items, ' + CAST((SELECT COUNT(*) FROM dbo.Item_Gene) AS varchar(10)) + ' links; per part: ' + (SELECT STUFF((SELECT ', ' + Part_Number + '=' + CAST(COUNT(*) AS varchar(10)) FROM dbo.Item GROUP BY Part_Number ORDER BY Part_Number FOR XML PATH('')), 1, 2, ''))"
    Write-Host "After:  $after"
    if ($inserted -ne $table.Rows.Count) { throw "Inserted $inserted but the file has $($table.Rows.Count); rolled back." }

    if ($Commit) { $tx.Commit(); Write-Host "COMMITTED." -ForegroundColor Green }
    else { $tx.Rollback(); Write-Host "PREVIEW ONLY - rolled back, nothing changed. Run with -Commit to load." -ForegroundColor Yellow }
}
catch {
    try { $tx.Rollback() } catch { }
    Write-Host "FAILED, rolled back: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally { $conn.Close() }
