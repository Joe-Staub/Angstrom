<#
.SYNOPSIS
    Backs up the PlantWatch inventory database on the local SQL Server Express instance
    to C:\PWInventoryBackups\YYYYMMDD.BAK. Made to run nightly from Windows Task Scheduler.

.DESCRIPTION
    Runs BACKUP DATABASE through the .NET SQL client, so nothing but Windows PowerShell and
    the SQL Server instance is needed. The backup file is named after today's date
    (20261107.BAK); a second run on the same day overwrites that day's file. Backups older
    than -KeepDays are deleted after a successful backup, and every run is appended to
    Backup.log in the backup folder.

    SQL Server itself writes the file, so its service account (NT Service\MSSQL$SQLEXPRESS)
    needs Modify rights on the backup folder. The script grants them when it creates the
    folder, which needs an elevated prompt the first time; after that it runs unelevated.

    -Register creates (or replaces) the scheduled task "PlantWatch inventory backup" to
    run this script every day at -At (default 23:45) under the current account, whether or
    not that account is logged on. The account must be allowed to back up the database:
    a member of the server's sysadmin role, or of db_backupoperator in the database.

.PARAMETER Instance
    SQL Server instance. Default localhost\SQLEXPRESS, as in pwDBBDatabase.yaml.

.PARAMETER Database
    Database to back up. Default PWInventory.

.PARAMETER BackupFolder
    Where the .BAK files go. Default C:\PWInventoryBackups.

.PARAMETER KeepDays
    Delete .BAK files in the backup folder older than this many days after a successful
    backup. Default 30. 0 keeps everything.

.PARAMETER Register
    Create or replace the nightly scheduled task instead of running a backup now.

.PARAMETER At
    Time of day for the scheduled task, 24-hour HH:mm. Default 23:45.

.PARAMETER TaskName
    Name of the scheduled task. Default "PlantWatch inventory backup".

.EXAMPLE
    .\Backup-PWInventory.ps1
    Backs up PWInventory to C:\PWInventoryBackups\<today>.BAK now.

.EXAMPLE
    .\Backup-PWInventory.ps1 -Register
    Schedules the nightly 23:45 backup under the current account.

.EXAMPLE
    .\Backup-PWInventory.ps1 -Database PWInventory2 -KeepDays 14
#>
[CmdletBinding()]
param(
    [string] $Instance = 'localhost\SQLEXPRESS',
    [string] $Database = 'PWInventory',
    [string] $BackupFolder = 'C:\PWInventoryBackups',
    [int]    $KeepDays = 30,
    [switch] $Register,
    [string] $At = '23:45',
    [string] $TaskName = 'PlantWatch inventory backup'
)

$ErrorActionPreference = 'Stop'
$logFile = Join-Path $BackupFolder 'Backup.log'

function Write-Log([string] $message, [switch] $IsError) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $message
    if ($IsError) { Write-Host $line -ForegroundColor Red } else { Write-Host $line }
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Service account of the instance, so the folder can be opened to it. SQL Server writes the
# backup, not this script, so the script's own rights on the folder are not what matters.
function Get-SqlServiceAccount([string] $instanceName) {
    $name = ($instanceName -split '\\')[-1]
    $service = if ($name -and $name -ne 'localhost' -and $name -ne '.' -and $name -ne $env:COMPUTERNAME) { "MSSQL`$$name" } else { 'MSSQLSERVER' }
    try {
        $wmi = Get-CimInstance Win32_Service -Filter "Name='$service'" -ErrorAction Stop
        if ($wmi) { return $wmi.StartName }
    } catch { }
    return "NT Service\$service"
}

function Ensure-BackupFolder {
    if (Test-Path -LiteralPath $BackupFolder) { return }
    New-Item -ItemType Directory -Path $BackupFolder | Out-Null
    Write-Log "Created $BackupFolder"
    $account = Get-SqlServiceAccount $Instance
    if (Test-IsAdmin) {
        & icacls $BackupFolder /grant "${account}:(OI)(CI)M" | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Granted Modify on $BackupFolder to $account" }
        else { Write-Log "Could not grant $account rights on $BackupFolder (icacls exit $LASTEXITCODE); grant Modify by hand if the backup fails to write" -IsError }
    } else {
        Write-Log "Not elevated: if the backup fails to write, run once from an elevated prompt or grant Modify on $BackupFolder to $account by hand"
    }
}

function Invoke-Backup {
    Ensure-BackupFolder
    $file = Join-Path $BackupFolder ('{0:yyyyMMdd}.BAK' -f (Get-Date))
    $sql = @"
BACKUP DATABASE [$Database]
TO DISK = N'$($file.Replace("'", "''"))'
WITH INIT, CHECKSUM, NAME = N'$Database nightly backup', DESCRIPTION = N'PlantWatch inventory, $(Get-Date -Format 'yyyy-MM-dd HH:mm')';
"@
    Write-Log "Backing up [$Database] on $Instance to $file"
    $connection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Instance;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=30"
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        $command.CommandTimeout = 0        # a large database takes as long as it takes
        [void] $command.ExecuteNonQuery()
    } finally {
        $connection.Dispose()
    }
    $size = (Get-Item -LiteralPath $file).Length
    Write-Log ('Backup complete: {0} ({1:N1} MB)' -f $file, ($size / 1MB))

    if ($KeepDays -gt 0) {
        $cutoff = (Get-Date).Date.AddDays(-$KeepDays)
        Get-ChildItem -LiteralPath $BackupFolder -Filter '*.BAK' -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force
                Write-Log "Deleted old backup $($_.Name)"
            }
    }
}

function Register-NightlyTask {
    if ($At -notmatch '^\s*(\d{1,2}):(\d{2})\s*$') { throw "-At must be HH:mm, got '$At'" }
    $scriptPath = $MyInvocation.PSCommandPath
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" +
                 " -Instance `"$Instance`" -Database `"$Database`" -BackupFolder `"$BackupFolder`" -KeepDays $KeepDays"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -Daily -At $At
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    # S4U runs the task whether or not the account is logged on, without storing a password.
    # It cannot reach network shares, which a local SQL instance and a local folder never need.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
                     -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description "Backs up the $Database database to $BackupFolder every night" -Force | Out-Null
    Write-Host "Scheduled task '$TaskName' will run daily at $At as ${user}:"
    Write-Host "  powershell.exe $arguments"
    Write-Host "Check it in Task Scheduler, or run it now with:  Start-ScheduledTask -TaskName '$TaskName'"
}

try {
    if ($Register) { Register-NightlyTask } else { Invoke-Backup }
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)" -IsError
    exit 1
}
