<#
.SYNOPSIS
    Rebuilds what went into each box (lot) from PlantWatch's own log files, for days the
    inventory database does not cover, and writes it to a CSV: one row per tube consumed.

.DESCRIPTION
    Reads PlantWatch.*.log files (the logs PlantWatch writes to
    %ProgramData%\HTE\PlantWatch\Logs with logic-chart debug logging on) in date order and
    follows each side's charts:

      * a scanner trigger       "Left-Side-Scanner_Logic|Triggered by ..., deviceValue="ESAT..."
      * a box being opened      "CreateLeftLot ...|FillTemplate: LeftLotLabel = "L000152""
      * a tube going into a box "LeftAddToBatch ...|ConsumeMaterial: consumed PN=... into parent PN=.../SN=L000152"

    The consume line does not name the tube, so the tube is the last serial that side's
    scanner delivered. Each side runs its charts one scan at a time, so that pairing is
    exact even though Left and Right interleave in the log.

    Columns: Side, Box, BoxPart, BoxOpened, Position, Tube, TubePart, ScannedAt, ConsumedAt,
    Notes, LogFile. BoxOpened is when the box serial was issued in these logs, or
    "before these logs" for a box already open when the first log starts. A box serial that
    was issued more than once (the plant's lot counter was reset at least once) appears as
    separate groups with different BoxOpened times. Notes flags the oddities the old charts
    produced: a box whose serial already existed in the database when it was issued, and a
    tube whose own birth failed as a duplicate.

.PARAMETER LogFolder
    Folder holding the PlantWatch.*.log files. Default: the current folder.

.PARAMETER OutFile
    The CSV to write. Default LotContentsFromLogs.csv in the log folder.

.EXAMPLE
    .\Export-LotContentsFromLogs.ps1 -LogFolder C:\Mac\Home\Desktop\LogFiles -OutFile C:\Mac\Home\Desktop\LotContentsFromLogs.csv
#>
[CmdletBinding()]
param(
    [string] $LogFolder = '.',
    [string] $OutFile
)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path $LogFolder 'LotContentsFromLogs.csv' }

$files = Get-ChildItem -Path $LogFolder -Filter 'PlantWatch*.log' | Sort-Object Name
if ($files.Count -eq 0) { throw "No PlantWatch*.log files in $LogFolder" }

$line = [regex]'^(?<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\|(?<level>[A-Z]+)\s*\|(?<logger>[^|]*)\|(?<where>[^|]*)\|(?<text>.*)$'
$trigger = [regex]'^(?<side>Left|Right)-Side-Scanner_Logic$'
$scanValue = [regex]'deviceValue="(?<value>[^"]*)"'
$lotLabel = [regex]'FillTemplate: (?<side>Left|Right)LotLabel = "(?<serial>[^"]*)"'
$consume = [regex]'ConsumeMaterial: consumed PN="(?<pn>[^"]*)" into parent PN="(?<boxPart>[^"]*)"/SN="(?<box>[^"]*)"'
$chartOf = [regex]'^(?<chart>[^ ]+)'

$sides = @{}
foreach ($s in 'Left', 'Right') { $sides[$s] = @{ Scan = $null; ScanTime = ''; ScanBirthFailed = $false; Box = $null; BoxOpened = ''; BoxBirthFailed = $false } }
$rows = New-Object System.Collections.Generic.List[object]
$skipped = 0

foreach ($file in $files) {
    Write-Host "Reading $($file.Name)"
    foreach ($raw in [System.IO.File]::ReadLines($file.FullName)) {
        $m = $line.Match($raw)
        if (-not $m.Success) { continue }      # ZPL and SQL continuation lines carry no pipe-delimited header
        $time = $m.Groups['time'].Value; $logger = $m.Groups['logger'].Value; $where = $m.Groups['where'].Value; $text = $m.Groups['text'].Value
        $chart = $chartOf.Match($where).Groups['chart'].Value

        # A scan arriving on a side's scanner chart
        $t = $trigger.Match($chart)
        if ($t.Success -and $where -eq $chart -and $text.StartsWith('Triggered by')) {
            $side = $sides[$t.Groups['side'].Value]
            $side.Scan = $scanValue.Match($text).Groups['value'].Value
            $side.ScanTime = $time
            $side.ScanBirthFailed = $false
            continue
        }

        # The tube's own birth failing (a duplicate serial)
        if ($t.Success -and $text.StartsWith('Error (ActionBirth)')) {
            $sides[$t.Groups['side'].Value].ScanBirthFailed = $true
            continue
        }

        # A box serial being issued
        $l = $lotLabel.Match($text)
        if ($l.Success) {
            $side = $sides[$l.Groups['side'].Value]
            $side.Box = $l.Groups['serial'].Value
            $side.BoxOpened = $time
            $side.BoxBirthFailed = $false
            continue
        }

        # The box's birth failing: the serial already existed, so the plant counter had been reset
        if ($chart -match '^Create(?<side>Left|Right)Lot$' -and $text.StartsWith('Error (ActionBirth)')) {
            $sides[$Matches['side']].BoxBirthFailed = $true
            continue
        }

        # A tube going into a box
        $c = $consume.Match($text)
        if ($c.Success -and $chart -match '^(?<side>Left|Right)AddToBatch$') {
            $sideName = $Matches['side']; $side = $sides[$sideName]
            $box = $c.Groups['box'].Value
            if (-not $side.Scan) { $skipped++; continue }
            $opened = if ($side.Box -eq $box) { $side.BoxOpened } else { 'before these logs' }
            $notes = @()
            if ($side.Box -eq $box -and $side.BoxBirthFailed) { $notes += 'box serial already existed when issued' }
            if ($side.ScanBirthFailed) { $notes += 'tube birth failed (duplicate serial)' }
            $rows.Add([pscustomobject]@{
                Side       = $sideName
                Box        = $box
                BoxPart    = $c.Groups['boxPart'].Value
                BoxOpened  = $opened
                Position   = 0
                Tube       = $side.Scan
                TubePart   = $c.Groups['pn'].Value
                ScannedAt  = $side.ScanTime
                ConsumedAt = $time
                Notes      = ($notes -join '; ')
                LogFile    = $file.Name
            })
        }
    }
}

# Position within each box instance, in the order the tubes went in
$grouped = $rows | Group-Object Side, Box, BoxOpened
foreach ($g in $grouped) { $i = 0; foreach ($r in ($g.Group | Sort-Object ConsumedAt)) { $i++; $r.Position = $i } }
$ordered = $rows | Sort-Object Side, Box, BoxOpened, ConsumedAt
$ordered | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Wrote $($rows.Count) tube(s) in $($grouped.Count) box instance(s) ($(($rows | Select-Object -ExpandProperty Box -Unique).Count) distinct box serials) to $OutFile"
if ($skipped) { Write-Host "Skipped $skipped consume line(s) with no scan before them in these logs" }
$flagged = @($rows | Where-Object { $_.Notes }).Count
if ($flagged) { Write-Host "$flagged row(s) carry a note; see the Notes column" }
Write-Host ""
Write-Host "Tubes per box instance:"
foreach ($g in $grouped | Sort-Object { $_.Group[0].Side }, { $_.Group[0].Box }, { $_.Group[0].BoxOpened }) {
    $first = $g.Group[0]
    Write-Host ("  {0,-5} {1,-10} opened {2,-19} {3,3} tube(s)" -f $first.Side, $first.Box, $first.BoxOpened.Substring(0, [Math]::Min(19, $first.BoxOpened.Length)), $g.Count)
}
