[CmdletBinding()]
param(
    [string]$RepoRoot = "L:\var\www\Brk.Trkr\brk.trkr-db",
    [string]$TaskName = "BrickTrackr Rebrickable Nightly",
    [string]$StartTime = "02:00",
    [switch]$RunNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    $nightlyScript = Join-Path $RepoRoot "run_rebrickable_nightly.ps1"
    $configFile = Join-Path $RepoRoot "config\bricktrackr.ini"
    $loader = Join-Path $RepoRoot "tools\Load-BrickTrackrConfig.ps1"

    foreach ($required in @($nightlyScript, $configFile, $loader)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required file not found: $required"
        }
    }

    $parsedTime = [datetime]::MinValue

    if (-not [datetime]::TryParseExact(
        $StartTime,
        "HH:mm",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedTime
    )) {
        throw "Invalid -StartTime '$StartTime'. Use 24-hour HH:mm, e.g. 02:00."
    }

    $powerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        "-File `"$nightlyScript`"",
        "-RepoRoot `"$RepoRoot`""
    ) -join " "

    $action = New-ScheduledTaskAction `
        -Execute $powerShellExe `
        -Argument $arguments `
        -WorkingDirectory $RepoRoot

    $trigger = New-ScheduledTaskTrigger `
        -Daily `
        -At $parsedTime

    # S4U permits unattended execution without storing the Windows password
    # in this repository/script. Internet access required for Rebrickable
    # downloads does not require Windows network credentials.
    $principal = New-ScheduledTaskPrincipal `
        -UserId $userId `
        -LogonType S4U `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
        -RestartCount 2 `
        -RestartInterval (New-TimeSpan -Minutes 15)

    $task = New-ScheduledTask `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Downloads a fresh Rebrickable snapshot and runs the BrickTrackr Phase 1-6 nightly reconciliation."

    Register-ScheduledTask `
        -TaskName $TaskName `
        -InputObject $task `
        -Force | Out-Null

    Write-Host "[PASS] Scheduled task registered."
    Write-Host "[INFO] Task:      $TaskName"
    Write-Host "[INFO] User:      $userId"
    Write-Host "[INFO] Schedule:  Daily at $StartTime"
    Write-Host "[INFO] Script:    $nightlyScript"
    Write-Host "[INFO] Config:    $configFile"
    Write-Host ""
    Write-Host "NOTE:"
    Write-Host "  Database passwords are not stored in bricktrackr.ini or this task."
    Write-Host "  Configure the importer secret through an appropriate user/machine secret"
    Write-Host "  environment variable or PostgreSQL .pgpass before unattended execution."

    if ($RunNow) {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "[INFO] Task started."
    }

    exit 0
}
catch {
    Write-Host "[FAIL] Failed to register BrickTrackr nightly scheduled task."
    Write-Host ("Error: " + $_.Exception.Message)

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Stack:"
        Write-Host $_.ScriptStackTrace
    }

    exit 1
}
