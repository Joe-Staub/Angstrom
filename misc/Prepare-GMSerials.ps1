<#
.SYNOPSIS
    Checks the tube serial numbers sent by GM Grand Rapids and writes two CSV files: the
    serials to load, and the duplicates that were left out.
.DESCRIPTION
    Reads every .xlsx or .csv given (first worksheet; every cell that starts with ESAT in any
    case), upper-cases the ESAT prefix, and keeps the first 22 characters as the key that goes
    into the database and is tested for duplicates:

        ESAT + yy + ddd + line + sequence(4) + GM part(8)          (22 characters)

    A longer value (the full 31-character scan with the supplier serial) is kept beside the key
    for reference. The first occurrence of a key is loaded; every later one is a duplicate. The
    part number is read from characters 15-22 of the serial, not from the column the serial sat
    in, and the line digit is kept exactly as it is in the serial.

    Writes <OutFolder>\GM-Serials-Checked.csv and <OutFolder>\GM-Serials-Duplicates.csv, and
    prints the counts. Load-GMSerials.ps1 takes the checked file.
.PARAMETER Path       One or more .xlsx or .csv files, in the order they should be trusted
                      (an earlier file wins when a key appears in two).
.PARAMETER OutFolder  Where the two CSV files go (default C:\AxleReports\GM-Serials).
.EXAMPLE
    .\Prepare-GMSerials.ps1 -Path 'C:\in\Tube Serial No.xlsx', 'C:\in\Rear Tube Scanning 11-18.xlsx'
#>
param(
    [Parameter(Mandatory = $true)] [string[]] $Path,
    [string] $OutFolder = 'C:\AxleReports\GM-Serials'
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-XlsxFirstSheet([string] $file) {
    # Cells of the first worksheet as [column letter, text]; shared strings resolved.
    $zip = [IO.Compression.ZipFile]::OpenRead($file)
    try {
        $text = { param($name) $e = $zip.GetEntry($name); if (-not $e) { return $null }; $r = New-Object IO.StreamReader($e.Open()); try { $r.ReadToEnd() } finally { $r.Close() } }
        $ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
        $shared = @()
        $ssx = & $text 'xl/sharedStrings.xml'
        if ($ssx) {
            $doc = [xml]$ssx; $m = New-Object Xml.XmlNamespaceManager($doc.NameTable); $m.AddNamespace('m', $ns)
            $shared = @($doc.SelectNodes('//m:si', $m) | ForEach-Object { ($_.SelectNodes('.//m:t', $m) | ForEach-Object { $_.InnerText }) -join '' })
        }
        $sheet = [xml](& $text 'xl/worksheets/sheet1.xml'); $m2 = New-Object Xml.XmlNamespaceManager($sheet.NameTable); $m2.AddNamespace('m', $ns)
        foreach ($c in $sheet.SelectNodes('//m:sheetData/m:row/m:c', $m2)) {
            $v = $c.SelectSingleNode('m:v', $m2)
            $val = if ($v) { $v.InnerText } else { $is = $c.SelectSingleNode('m:is', $m2); if ($is) { $is.InnerText } else { '' } }
            if ($c.GetAttribute('t') -eq 's' -and $v) { $val = $shared[[int]$val] }
            $ref = $c.GetAttribute('r')
            [pscustomobject]@{ Column = ($ref -replace '\d', ''); Row = [int]($ref -replace '\D', ''); Text = [string]$val }
        }
    } finally { $zip.Dispose() }
}

function Read-CsvCells([string] $file) {
    $row = 0
    foreach ($line in Get-Content $file) {
        $row++; $col = 0
        foreach ($field in ($line -split ',')) {
            $col++
            [pscustomobject]@{ Column = [string][char](64 + $col); Row = $row; Text = $field.Trim().Trim('"') }
        }
    }
}

$seen = @{}            # key -> the row that was kept
$checked = New-Object System.Collections.Generic.List[object]
$duplicates = New-Object System.Collections.Generic.List[object]
$read = 0

foreach ($file in $Path) {
    if (-not (Test-Path $file)) { throw "Not found: $file" }
    $name = [IO.Path]::GetFileName($file)
    $cells = if ($file -match '\.xlsx$') { Read-XlsxFirstSheet $file } else { Read-CsvCells $file }
    foreach ($cell in $cells) {
        $raw = ([string]$cell.Text).Trim()
        if ($raw -notmatch '^(?i)esat') { continue }
        $read++
        $normalised = 'ESAT' + $raw.Substring(4)
        $problem = $null
        if ($normalised -notmatch '^ESAT\d{18,}$') { $problem = 'Not ESAT followed by digits' }
        elseif ($normalised.Length -lt 22) { $problem = "Only $($normalised.Length) characters" }
        if ($problem) {
            $duplicates.Add([pscustomobject]@{ Key22 = $normalised; Raw = $raw; File = $name; Column = $cell.Column; Row = $cell.Row; Reason = $problem })
            continue
        }
        $key = $normalised.Substring(0, 22)
        $line = $key.Substring(9, 1)
        $entry = [pscustomobject]@{
            Serial     = $key
            Part       = $key.Substring(14, 8)
            Line       = $line
            Year       = $key.Substring(4, 2)
            DayOfYear  = $key.Substring(6, 3)
            Sequence   = $key.Substring(10, 4)
            FullScan   = if ($normalised.Length -gt 22) { $normalised } else { '' }
            File       = $name
            Column     = $cell.Column
            Row        = $cell.Row
            Note       = if ($line -notin '1', '2') { "Line digit $line" } else { '' }
        }
        if ($seen.ContainsKey($key)) {
            $first = $seen[$key]
            $reason = if ($first.File -ne $name) { "Already in $($first.File)" }
                      elseif ($entry.FullScan -and $first.FullScan -and $entry.FullScan -ne $first.FullScan) { "Same 22 characters as row $($first.Row), different supplier serial" }
                      else { "Same as row $($first.Row)" }
            $duplicates.Add([pscustomobject]@{ Key22 = $key; Raw = $raw; File = $name; Column = $cell.Column; Row = $cell.Row; Reason = $reason })
            continue
        }
        $seen[$key] = $entry
        $checked.Add($entry)
    }
}

New-Item -ItemType Directory -Force -Path $OutFolder | Out-Null
$checkedPath = Join-Path $OutFolder 'GM-Serials-Checked.csv'
$dupPath = Join-Path $OutFolder 'GM-Serials-Duplicates.csv'
$checked | Export-Csv $checkedPath -NoTypeInformation -Encoding UTF8
$duplicates | Export-Csv $dupPath -NoTypeInformation -Encoding UTF8

Write-Host ("Read {0} serial cells from {1} file(s)" -f $read, $Path.Count)
Write-Host ("Checked (to load): {0}  -> {1}" -f $checked.Count, $checkedPath)
Write-Host ("Duplicates / rejected: {0}  -> {1}" -f $duplicates.Count, $dupPath)
$checked | Group-Object Part | ForEach-Object { Write-Host ("  part {0}: {1}" -f $_.Name, $_.Count) }
$checked | Where-Object Note | Group-Object Note | ForEach-Object { Write-Host ("  note '{0}': {1} (loaded)" -f $_.Name, $_.Count) }
$duplicates | Group-Object Reason | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) }
