<#
.SYNOPSIS
    Stops PlantWatch, pulls the latest Angstrom configuration from git, and restarts PlantWatch.

.DESCRIPTION
    PlantWatch is a desktop application (PlantWatch.exe, normally started with /runtime).
    It runs its shutdown charts and saves persisted variables only when its window closes
    normally, so this script asks the window to close first and only force-kills the
    process if it has not exited within -CloseTimeoutSec.

    The pull is fast-forward only. If the pull fails (local edits, diverged history,
    no network) the script still restarts PlantWatch on the old configuration so the
    line is not left down, and exits with a non-zero code.

    Run this from the logged-in operator session (double-click Update-PlantWatch.cmd,
    or a scheduled task set to "Run only when user is logged on"), otherwise the
    PlantWatch window will start in a session nobody can see.

.PARAMETER RepoPath
    Folder holding the Angstrom configuration repository. Default C:\PlantWatch\Angstrom.

.PARAMETER PlantWatchExe
    Full path to PlantWatch.exe. If omitted, the script uses the path of the running
    PlantWatch process, then C:\PlantWatch\PlantWatch.exe, then the usual Program Files folders.

.PARAMETER Arguments
    Command line to start PlantWatch with. If omitted, the script reuses the arguments of
    the PlantWatch process it stopped, or falls back to "/runtime /config:<RepoPath>".

.PARAMETER Branch
    Optional. Check out this branch before pulling. By default the current branch is pulled.

.PARAMETER CloseTimeoutSec
    How long to wait for PlantWatch to close gracefully before force-killing it. Default 60.

.PARAMETER SkipRestart
    Stop and pull, but do not start PlantWatch again.

.EXAMPLE
    .\Update-PlantWatch.ps1
    .\Update-PlantWatch.ps1 -Branch main
    .\Update-PlantWatch.ps1 -PlantWatchExe 'C:\Program Files\HTE\PlantWatch\PlantWatch.exe'
#>
[CmdletBinding()]
param(
    [string]$RepoPath = 'C:\PlantWatch\Angstrom',
    [string]$PlantWatchExe = '',
    [string]$Arguments = '',
    [string]$Branch = '',
    [int]$CloseTimeoutSec = 60,
    [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'
$processName = 'PlantWatch'
$exitCode = 0

function Write-Step([string]$Message) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Find-PlantWatchExe([string]$Hint) {
    if ($Hint -and (Test-Path $Hint)) { return $Hint }
    $candidates = @(
        'C:\PlantWatch\PlantWatch.exe',
        (Join-Path $env:ProgramFiles 'HTE\PlantWatch\PlantWatch.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'HTE\PlantWatch\PlantWatch.exe'),
        (Join-Path $env:ProgramFiles 'PlantWatch\PlantWatch.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'PlantWatch\PlantWatch.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

# Strip the executable token from a Win32_Process command line, leaving only the arguments.
function Get-ArgumentsFromCommandLine([string]$CommandLine) {
    if (-not $CommandLine) { return '' }
    $trimmed = $CommandLine.TrimStart()
    if ($trimmed.StartsWith('"')) {
        $end = $trimmed.IndexOf('"', 1)
        if ($end -gt 0) { return $trimmed.Substring($end + 1).Trim() }
    }
    $space = $trimmed.IndexOf(' ')
    if ($space -gt 0) { return $trimmed.Substring($space + 1).Trim() }
    return ''
}

# ---------------------------------------------------------------------------
# 1. Stop PlantWatch
# ---------------------------------------------------------------------------
$runningExe  = $null
$runningArgs = $null

$procs = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    Write-Step "PlantWatch is not running."
} else {
    foreach ($p in $procs) {
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)"
            if ($cim) {
                if (-not $runningExe)  { $runningExe  = $cim.ExecutablePath }
                if (-not $runningArgs) { $runningArgs = Get-ArgumentsFromCommandLine $cim.CommandLine }
            }
        } catch { }
        if (-not $runningExe) { try { $runningExe = $p.Path } catch { } }

        Write-Step "Asking PlantWatch (PID $($p.Id)) to close so shutdown charts can run..."
        $closed = $false
        try { $closed = $p.CloseMainWindow() } catch { }
        if (-not $closed) {
            Write-Step "PlantWatch has no main window to close; it may already be shutting down."
        }
    }

    Write-Step "Waiting up to $CloseTimeoutSec s for PlantWatch to exit..."
    $deadline = (Get-Date).AddSeconds($CloseTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }

    $stillRunning = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    if ($stillRunning.Count -gt 0) {
        Write-Warning "PlantWatch did not close within $CloseTimeoutSec s. Forcing it to stop (shutdown charts and variable persistence are skipped)."
        $stillRunning | Stop-Process -Force -Confirm:$false
        Start-Sleep -Seconds 2
    } else {
        Write-Step "PlantWatch closed."
    }
}

# ---------------------------------------------------------------------------
# 2. Pull the configuration
# ---------------------------------------------------------------------------
$pullOk = $false
try {
    if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
        throw "'$RepoPath' is not a git repository."
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is not on the PATH."
    }

    $dirty = & git -C $RepoPath status --porcelain --untracked-files=no
    if ($dirty) {
        Write-Warning "Local changes in '$RepoPath' will block a clean pull:"
        $dirty | ForEach-Object { Write-Warning "  $_" }
        throw "Commit, stash or discard the local changes, then run this script again."
    }

    if ($Branch) {
        Write-Step "Fetching and switching to branch '$Branch'..."
        & git -C $RepoPath fetch --prune origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed." }
        & git -C $RepoPath checkout $Branch
        if ($LASTEXITCODE -ne 0) { throw "git checkout '$Branch' failed." }
    }

    $currentBranch = (& git -C $RepoPath rev-parse --abbrev-ref HEAD).Trim()
    $before        = (& git -C $RepoPath rev-parse --short HEAD).Trim()
    Write-Step "Pulling '$currentBranch' in $RepoPath (currently at $before)..."

    & git -C $RepoPath pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed (see output above)." }

    $after = (& git -C $RepoPath rev-parse --short HEAD).Trim()
    if ($before -eq $after) {
        Write-Step "Already up to date at $after."
    } else {
        Write-Step "Updated $before -> $after. Changed files:"
        & git -C $RepoPath diff --stat "$before..$after" | ForEach-Object { Write-Host "    $_" }
    }
    $pullOk = $true
} catch {
    Write-Warning "Pull failed: $($_.Exception.Message)"
    Write-Warning "PlantWatch will be restarted on the configuration already on disk."
    $exitCode = 1
}

# ---------------------------------------------------------------------------
# 3. Restart PlantWatch
# ---------------------------------------------------------------------------
if ($SkipRestart) {
    Write-Step "SkipRestart given; PlantWatch left stopped."
} else {
    $exe = Find-PlantWatchExe $PlantWatchExe
    if (-not $exe -and $runningExe) { $exe = $runningExe }

    if (-not $exe) {
        Write-Error "Cannot find PlantWatch.exe. Pass -PlantWatchExe with its full path."
        exit 2
    }

    $startArgs = $Arguments
    if (-not $startArgs) { $startArgs = $runningArgs }
    if (-not $startArgs) { $startArgs = "/runtime /config:`"$RepoPath`"" }

    Write-Step "Starting: `"$exe`" $startArgs"
    $started = Start-Process -FilePath $exe -ArgumentList $startArgs -WorkingDirectory (Split-Path $exe) -PassThru
    Start-Sleep -Seconds 5
    if ($started.HasExited) {
        Write-Error "PlantWatch exited immediately (exit code $($started.ExitCode)). Check its log."
        exit 3
    }
    Write-Step "PlantWatch is running (PID $($started.Id))."
}

if ($pullOk) { Write-Step "Done." } else { Write-Step "Done, but the pull failed. See warnings above." }
exit $exitCode
