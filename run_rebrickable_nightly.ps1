[CmdletBinding()]
param(
    [string]$RepoRoot = "L:\var\www\Brk.Trkr\brk.trkr-db",
    [string]$RefreshScript = "",
    [string[]]$RefreshArgs = @(),
    [string]$HostName = "localhost",
    [int]$Port = 5432,
    [string]$Database = "bricktrackr",
    [string]$DbUser = "bricktrackr_import",
    [string]$PythonExe = "python",
    [string]$PsqlExe = "psql",
    [string]$LogDir = "",
    [int]$RetentionDays = 30,
    [int]$SnapshotRetentionDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Embedded PostgreSQL password, per request.
# Restrict NTFS read permissions on this script.
$PostgresPassword = "root"
$env:PGPASSWORD = $PostgresPassword

if (-not $LogDir) {
    $LogDir = Join-Path $RepoRoot "logs\rebrickable"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$ImportRoot = Join-Path $RepoRoot "import"
$Downloader = Join-Path $ImportRoot "download_rebrickable_snapshot.py"
$SnapshotRoot = Join-Path $ImportRoot "runtime\snapshots"

if (-not (Test-Path $Downloader -PathType Leaf)) {
    throw "Rebrickable snapshot downloader not found: $Downloader"
}

New-Item -ItemType Directory -Force -Path $SnapshotRoot | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $LogDir "rebrickable_refresh_$stamp.log"
$lockPath = Join-Path $LogDir "rebrickable_refresh.lock"
$lockHandle = $null

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    $line = "{0:o} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-PsqlScalar {
    param(
        [Parameter(Mandatory)]
        [string]$Sql
    )

    # IMPORTANT: use a splatted argument array. Do not use comma-separated
    # native-command arguments; PowerShell may bind them incorrectly.
    $psqlArgs = @(
        "-h", $HostName,
        "-p", "$Port",
        "-U", $DbUser,
        "-d", $Database,
        "-v", "ON_ERROR_STOP=1",
        "-A",
        "-t",
        "-q",
        "-c", $Sql
    )

    $result = & $PsqlExe @psqlArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "psql failed: $($result -join [Environment]::NewLine)"
    }

    $value = @(
        $result |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -ne "" }
    )

    if ($value.Count -eq 0) {
        return ""
    }

    return $value[-1]
}

function New-FreshRebrickableSnapshot {
    $snapshotStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $snapshotDir = Join-Path $SnapshotRoot "nightly_$snapshotStamp"

    Write-Log "INFO" "Downloading fresh Rebrickable snapshot: $snapshotDir"

    & $PythonExe $Downloader --output-dir $snapshotDir 2>&1 |
        ForEach-Object {
            Write-Log "DOWNLOAD" $_.ToString()
        }

    $code = $LASTEXITCODE
    Write-Log "INFO" ("Snapshot downloader exit code={0}" -f $code)

    if ($code -ne 0) {
        throw "Fresh Rebrickable snapshot download failed with exit code $code"
    }

    $manifest = Join-Path $snapshotDir "snapshot_manifest.json"
    if (-not (Test-Path $manifest -PathType Leaf)) {
        throw "Snapshot downloader returned success but manifest is missing: $manifest"
    }

    Write-Log "PASS" "Fresh Rebrickable snapshot ready: $snapshotDir"
    return $snapshotDir
}


function Resolve-RefreshScript {
    if ($RefreshScript) {
        $candidate = $RefreshScript

        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $RepoRoot $candidate
        }

        if (-not (Test-Path $candidate -PathType Leaf)) {
            throw "Refresh script not found: $candidate"
        }

        return (Resolve-Path $candidate).Path
    }

    # Canonical production orchestrator.
    $canonical = Join-Path $RepoRoot "import\run_rebrickable_full_refresh.ps1"

    if (Test-Path $canonical -PathType Leaf) {
        return (Resolve-Path $canonical).Path
    }

    throw "Canonical refresh orchestrator not found: $canonical"
}

function Invoke-RefreshOrchestrator {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$SnapshotDir
    )

    $extension = [System.IO.Path]::GetExtension($ScriptPath).ToLowerInvariant()

    switch ($extension) {
        ".ps1" {
            & powershell.exe `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File $ScriptPath `
                -SnapshotDir $SnapshotDir `
                @RefreshArgs 2>&1 |
                ForEach-Object {
                    Write-Log "IMPORT" $_.ToString()
                }

            $code = $LASTEXITCODE
        }

        ".py" {
            & $PythonExe $ScriptPath @RefreshArgs 2>&1 |
                ForEach-Object {
                    Write-Log "IMPORT" $_.ToString()
                }

            $code = $LASTEXITCODE
        }

        default {
            throw "Unsupported refresh orchestrator type: $extension"
        }
    }

    Write-Log "INFO" ("Refresh orchestrator exit code={0}" -f $code)

    if ($code -ne 0) {
        throw "Refresh orchestrator exited with code $code"
    }
}

$exitCode = 1

try {
    # Prevent overlapping refreshes.
    try {
        $lockHandle = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    catch {
        throw "Another refresh appears active. Lock exists: $lockPath"
    }

    $pidText = "$PID`r`n"
    $pidBytes = [System.Text.Encoding]::UTF8.GetBytes($pidText)
    $lockHandle.Write($pidBytes, 0, $pidBytes.Length)
    $lockHandle.Flush()

    Write-Log "INFO" "Nightly Rebrickable refresh starting."
    Write-Log "INFO" "PostgreSQL user=$DbUser database=$Database host=$HostName port=$Port"

    $connected = Invoke-PsqlScalar -Sql "SELECT current_database() || '|' || current_user;"

    if ($connected -ne "$Database|$DbUser") {
        throw "Unexpected PostgreSQL connection identity: $connected"
    }

    Write-Log "INFO" "Database connection verified: $connected"

    # Refuse to overlap an active or stranded Rebrickable run.
    $openRuns = Invoke-PsqlScalar -Sql @"
SELECT count(*)
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
  AND sr.status IN ('STARTED','STAGING','VALIDATING','FINALIZING');
"@

    if ([int]$openRuns -ne 0) {
        throw "Refusing refresh because $openRuns non-terminal REBRICKABLE source run(s) already exist."
    }

    $snapshotDir = New-FreshRebrickableSnapshot

    $resolvedRefresh = Resolve-RefreshScript
    Write-Log "INFO" "Refresh orchestrator: $resolvedRefresh"

    Push-Location (Split-Path $resolvedRefresh -Parent)
    try {
        Invoke-RefreshOrchestrator -ScriptPath $resolvedRefresh -SnapshotDir $snapshotDir
    }
    finally {
        Pop-Location
    }

    # Post-run lifecycle verification.
    $remainingOpen = Invoke-PsqlScalar -Sql @"
SELECT count(*)
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
  AND sr.status IN ('STARTED','STAGING','VALIDATING','FINALIZING');
"@

    if ([int]$remainingOpen -ne 0) {
        throw "Refresh returned success but $remainingOpen non-terminal REBRICKABLE run(s) remain."
    }

    $latest = Invoke-PsqlScalar -Sql @"
SELECT
    sr.source_run_id::text || '|' ||
    sr.status::text || '|' ||
    COALESCE(sr.completed_at::text, '')
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
ORDER BY sr.started_at DESC
LIMIT 1;
"@

    $parts = $latest -split '\|', 3

    if ($parts.Count -lt 2 -or $parts[1] -ne "COMPLETED") {
        throw "Latest REBRICKABLE source run is not COMPLETED: $latest"
    }

    Write-Log "PASS" "Nightly refresh completed. source_run_id=$($parts[0])"
    $exitCode = 0
}
catch {
    Write-Log "ERROR" $_.Exception.Message

    if ($_.ScriptStackTrace) {
        Write-Log "ERROR" $_.ScriptStackTrace
    }

    $exitCode = 1
}
finally {
    if ($lockHandle) {
        $lockHandle.Dispose()
    }

    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue

    Get-ChildItem $LogDir -File -Filter "rebrickable_refresh_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Get-ChildItem $SnapshotRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$SnapshotRetentionDays) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
