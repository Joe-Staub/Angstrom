<#
.SYNOPSIS
    Exports the contents of the axle-tube boxes (lots) from the PlantWatch inventory
    database to a CSV file: one row per tube, with the box it went into.

.DESCRIPTION
    Reads the box items (parts LOT85545338 and LOT85545339) and the tubes consumed into
    them (Item_Gene) through the .NET SQL client, so nothing but Windows PowerShell and the
    SQL Server instance is needed. Columns:

        Box, BoxPart, Side, BoxCreated, BoxCount, Position, Tube, TubePart, TubeBorn, Added, Station

    BoxCount is the count PlantWatch keeps on the box (its lot quantity); Position numbers
    the tubes in the order they were added. A box with no tubes yet appears once with the
    tube columns empty. Rows are ordered by box creation, then by the order the tubes were
    added. Added is when the tube went into the box and Station the machine that did it;
    for boxes migrated from the old PWInventory database Added is the migration time, so
    TubeBorn, the moment the tube was scanned, is the time to use for those.

    Without -Lot, -Side, -Since or -Until every box in the database is exported.

.PARAMETER Lot
    One or more box serials to export, wildcards allowed: L00012, 'R*', 'L0001?'. Default
    all boxes.

.PARAMETER Side
    Left or Right: only that side's boxes.

.PARAMETER Since
    Only boxes created on or after this date/time, e.g. 2026-11-01 or '2026-11-10 06:00'.

.PARAMETER Until
    Only boxes created before this date/time.

.PARAMETER OutFile
    The CSV to write. Default C:\AxleReports\LotContents_<yyyyMMdd_HHmmss>.csv, or
    LotContents_<serial>.csv when exactly one -Lot without wildcards is given. An existing
    file is overwritten.

.PARAMETER Instance
    SQL Server instance. Default localhost\SQLEXPRESS, as in pwDBBDatabase.yaml.

.PARAMETER Database
    Database to read. Default PWInventory2 (schema v2).

.EXAMPLE
    .\Export-LotContents.ps1
    Every box, to C:\AxleReports\LotContents_20261111_093000.csv

.EXAMPLE
    .\Export-LotContents.ps1 -Lot L00012
    One box, to C:\AxleReports\LotContents_L00012.csv

.EXAMPLE
    .\Export-LotContents.ps1 -Side Right -Since 2026-11-10 -OutFile C:\Temp\right.csv
#>
[CmdletBinding()]
param(
    [string[]] $Lot,
    [ValidateSet('Left', 'Right')] [string] $Side,
    [datetime] $Since,
    [datetime] $Until,
    [string] $OutFile,
    [string] $Instance = 'localhost\SQLEXPRESS',
    [string] $Database = 'PWInventory2'
)

$ErrorActionPreference = 'Stop'

# Which box part belongs to which side; the box serial's first letter is the fallback for
# boxes made before the L/R scheme.
$sideParts = @{ Left = 'LOT85545338'; Right = 'LOT85545339' }

$where = New-Object System.Collections.Generic.List[string]
$parameters = New-Object System.Collections.Generic.List[System.Data.SqlClient.SqlParameter]
$where.Add("b.Part_Number LIKE 'LOT%'")

if ($Lot) {
    $clauses = @()
    $i = 0
    foreach ($serial in $Lot) {
        $name = "@lot$i"; $i++
        $clauses += "b.Serial_Nbr LIKE $name"
        $parameters.Add((New-Object System.Data.SqlClient.SqlParameter($name, ($serial -replace '\*', '%' -replace '\?', '_'))))
    }
    $where.Add('(' + ($clauses -join ' OR ') + ')')
}
if ($Side) {
    $where.Add('b.Part_Number = @part')
    $parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@part', $sideParts[$Side])))
}
if ($PSBoundParameters.ContainsKey('Since')) {
    $where.Add('b.Birth_DateTime >= @since')
    $parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@since', $Since)))
}
if ($PSBoundParameters.ContainsKey('Until')) {
    $where.Add('b.Birth_DateTime < @until')
    $parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@until', $Until)))
}

$sql = @"
SELECT  b.Serial_Nbr                 AS Box,
        b.Part_Number                AS BoxPart,
        b.Birth_DateTime             AS BoxCreated,
        ISNULL(b.LotQuantity, 0)     AS BoxCount,
        CASE WHEN g.Child_Serial_Nbr IS NULL THEN NULL
             ELSE ROW_NUMBER() OVER (PARTITION BY b.Entity, b.Serial_Nbr ORDER BY g.Consumed_At) END AS Position,
        g.Child_Serial_Nbr           AS Tube,
        t.Part_Number                AS TubePart,
        t.Birth_DateTime             AS TubeBorn,
        g.Consumed_At                AS Added,
        g.Station                    AS Station
FROM    dbo.Item b
        LEFT  JOIN dbo.Item_Gene g  ON g.Parent_Entity = b.Entity AND g.Parent_Serial_Nbr = b.Serial_Nbr
        LEFT  JOIN dbo.Item t       ON t.Entity = g.Child_Entity AND t.Serial_Nbr = g.Child_Serial_Nbr
WHERE   $($where -join "`r`n  AND   ")
ORDER BY b.Birth_DateTime, b.Serial_Nbr, g.Consumed_At
"@

if (-not $OutFile) {
    $folder = 'C:\AxleReports'
    $stamp = if ($Lot -and $Lot.Count -eq 1 -and $Lot[0] -notmatch '[*?]') { $Lot[0] } else { Get-Date -Format 'yyyyMMdd_HHmmss' }
    $OutFile = Join-Path $folder "LotContents_$stamp.csv"
}
$outFolder = Split-Path -Parent $OutFile
if ($outFolder -and -not (Test-Path $outFolder)) { New-Item -ItemType Directory -Path $outFolder | Out-Null }

function Stamp($value) { if ($value -is [DBNull] -or $null -eq $value) { '' } else { ([datetime]$value).ToString('yyyy-MM-dd HH:mm:ss') } }
function Text($value) { if ($value -is [DBNull] -or $null -eq $value) { '' } else { "$value" } }
function SideOf($part, $serial) {
    foreach ($k in $sideParts.Keys) { if ($sideParts[$k] -eq $part) { return $k } }
    switch ($serial.Substring(0, 1).ToUpper()) { 'L' { 'Left' } 'R' { 'Right' } default { '' } }
}

$rows = New-Object System.Collections.Generic.List[object]
$boxes = @{}
$connection = New-Object System.Data.SqlClient.SqlConnection("Data Source=$Instance;Initial Catalog=$Database;Integrated Security=SSPI")
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = $sql
    $command.CommandTimeout = 120
    foreach ($p in $parameters) { [void]$command.Parameters.Add($p) }
    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $box = $reader['Box']; $part = $reader['BoxPart']
            $boxes[$box] = $true
            $rows.Add([pscustomobject]@{
                Box        = $box
                BoxPart    = $part
                Side       = SideOf $part $box
                BoxCreated = Stamp $reader['BoxCreated']
                BoxCount   = Text $reader['BoxCount']
                Position   = Text $reader['Position']
                Tube       = Text $reader['Tube']
                TubePart   = Text $reader['TubePart']
                TubeBorn   = Stamp $reader['TubeBorn']
                Added      = Stamp $reader['Added']
                Station    = Text $reader['Station']
            })
        }
    }
    finally { $reader.Close() }
}
finally { $connection.Close() }

$rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
$tubes = @($rows | Where-Object { $_.Tube -ne '' }).Count
Write-Host "Exported $($boxes.Count) box(es), $tubes tube(s) to $OutFile"
if ($boxes.Count -eq 0) { Write-Host 'No boxes matched.' }
