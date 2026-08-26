[CmdletBinding()]
param(
    [string]$RepoRoot = "L:\var\www\Brk.Trkr\brk.trkr-db",
    [string]$ConfigPath,
    [string]$PythonExe = "python",
    [int]$SnapshotRetentionDays = 7,
    [int]$LogRetentionDays = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO","PASS","WARN","ERROR")]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "o"), $Level, $Message
    Write-Host $line

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Invoke-PsqlScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $dsn = "postgresql://$($env:BRICKTRACKR_DB_HOST):$($env:BRICKTRACKR_DB_PORT)/$($env:BRICKTRACKR_DATABASE)"

    $output = & psql `
        -X `
        -A `
        -t `
        -q `
        -v ON_ERROR_STOP=1 `
        --username $script:ImportUser `
        --dbname $dsn `
        --command $Sql 2>&1

    $code = $LASTEXITCODE

    if ($code -ne 0) {
        throw "psql failed with exit code $code. Output: $($output -join ' ')"
    }

    return (($output | Out-String).Trim())
}

$startedAt = Get-Date
$script:LogFile = $null
$lockFile = $null
$snapshotDir = $null

try {
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        throw "Repository root does not exist: $RepoRoot"
    }

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $RepoRoot "config\bricktrackr.ini"
    }

    # -------------------------------------------------------------------------
    # Shared non-secret database configuration.
    # -------------------------------------------------------------------------

    $loader = Join-Path $RepoRoot "tools\Load-BrickTrackrConfig.ps1"

    if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) {
        throw "Shared config loader not found: $loader"
    }

    . $loader

    $db = Import-BrickTrackrDatabaseConfig -ConfigPath $ConfigPath

    # Importer identity is intentionally not the admin role.
    $script:ImportUser = if (
        -not [string]::IsNullOrWhiteSpace($env:BRICKTRACKR_IMPORT_USER)
    ) {
        $env:BRICKTRACKR_IMPORT_USER
    }
    else {
        "bricktrackr_import"
    }

    # Secret resolution order:
    #   1. existing PGPASSWORD
    #   2. BRICKTRACKR_IMPORT_PASSWORD
    #   3. no password here; let libpq/.pgpass handle it
    if ([string]::IsNullOrWhiteSpace($env:PGPASSWORD) -and
        -not [string]::IsNullOrWhiteSpace($env:BRICKTRACKR_IMPORT_PASSWORD)) {
        $env:PGPASSWORD = $env:BRICKTRACKR_IMPORT_PASSWORD
    }

    # -------------------------------------------------------------------------
    # Runtime directories and logging.
    # -------------------------------------------------------------------------

    $importRoot = Join-Path $RepoRoot "import"
    $runtimeRoot = Join-Path $importRoot "runtime"
    $snapshotRoot = Join-Path $runtimeRoot "snapshots"
    $lockRoot = Join-Path $runtimeRoot "locks"
    $logRoot = Join-Path $RepoRoot "logs\rebrickable"

    foreach ($dir in @($runtimeRoot, $snapshotRoot, $lockRoot, $logRoot)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path $logRoot "rebrickable_nightly_$stamp.log"
    $lockFile = Join-Path $lockRoot "rebrickable_nightly.lock"
    $snapshotDir = Join-Path $snapshotRoot "nightly_$stamp"

    Write-Log INFO "BrickTrackr nightly Rebrickable refresh starting."
    Write-Log INFO "Database: $($db.HostName):$($db.Port)/$($db.Database)"
    Write-Log INFO "Importer: $script:ImportUser"
    Write-Log INFO "Log: $script:LogFile"

    # -------------------------------------------------------------------------
    # PID-aware single-run lock.
    # -------------------------------------------------------------------------

    if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
        $existingPidText = (Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue |
            Select-Object -First 1)

        $existingPid = 0

        if ([int]::TryParse([string]$existingPidText, [ref]$existingPid)) {
            $existingProcess = Get-Process -Id $existingPid -ErrorAction SilentlyContinue

            if ($null -ne $existingProcess) {
                throw "Nightly refresh is already running under PID $existingPid."
            }
        }

        Write-Log WARN "Removing stale nightly lock: $lockFile"
        Remove-Item -LiteralPath $lockFile -Force
    }

    Set-Content -LiteralPath $lockFile -Value $PID -Encoding ASCII
    Write-Log PASS "Nightly lock acquired (PID $PID)."

    # -------------------------------------------------------------------------
    # Required components.
    # -------------------------------------------------------------------------

    $downloader = Join-Path $importRoot "download_rebrickable_snapshot.py"
    $refresh = Join-Path $importRoot "run_rebrickable_full_refresh.ps1"

    foreach ($required in @($downloader, $refresh)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required nightly component not found: $required"
        }
    }

    # -------------------------------------------------------------------------
    # Verify importer connectivity and role identity.
    # -------------------------------------------------------------------------

    $whoAmI = Invoke-PsqlScalar -Sql "SELECT current_user;"

    if ($whoAmI -ne $script:ImportUser) {
        throw "Importer identity mismatch. Expected '$script:ImportUser', got '$whoAmI'."
    }

    Write-Log PASS "Importer connection verified."

    # -------------------------------------------------------------------------
    # Refuse to start if a previous Rebrickable run is still non-terminal.
    # -------------------------------------------------------------------------

    $openRuns = Invoke-PsqlScalar -Sql @"
SELECT count(*)
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
  AND sr.status IN ('STARTED','STAGING','VALIDATING','FINALIZING');
"@

    if ([int]$openRuns -ne 0) {
        throw "Refusing nightly refresh: $openRuns non-terminal Rebrickable source run(s) already exist."
    }

    Write-Log PASS "No non-terminal Rebrickable source runs found."

    # -------------------------------------------------------------------------
    # Fresh immutable snapshot for this nightly execution.
    # -------------------------------------------------------------------------

    Write-Log INFO "Downloading a fresh 12-file Rebrickable snapshot."
    Write-Log INFO "Snapshot: $snapshotDir"

    & $PythonExe $downloader --output-dir $snapshotDir 2>&1 |
        ForEach-Object {
            $line = [string]$_
            Write-Host $line
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        }

    $downloadCode = $LASTEXITCODE

    if ($downloadCode -ne 0) {
        throw "Rebrickable snapshot download failed with exit code $downloadCode."
    }

    $requiredDatasets = @(
        "themes",
        "colors",
        "part_categories",
        "parts",
        "sets",
        "minifigs",
        "elements",
        "inventories",
        "inventory_parts",
        "inventory_sets",
        "inventory_minifigs",
        "part_relationships"
    )

    $missing = @(
        foreach ($dataset in $requiredDatasets) {
            $path = Join-Path $snapshotDir "$dataset.csv.gz"

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $path
            }
        }
    )

    if ($missing.Count -gt 0) {
        throw "Fresh nightly snapshot is incomplete. Missing: $($missing -join ', ')"
    }

    Write-Log PASS "Fresh Rebrickable snapshot verified: 12 archives."

    # -------------------------------------------------------------------------
    # Shared Phase 1-6 import engine.
    # Full-refresh does not download anything itself.
    # -------------------------------------------------------------------------

    Write-Log INFO "Starting canonical Phase 1-6 refresh engine."

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $refresh `
        -StartPhase PHASE1 `
        -SnapshotDir $snapshotDir 2>&1 |
        ForEach-Object {
            $line = [string]$_
            Write-Host $line
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        }

    $refreshCode = $LASTEXITCODE

    if ($refreshCode -ne 0) {
        throw "Rebrickable full refresh failed with exit code $refreshCode."
    }

    # -------------------------------------------------------------------------
    # Post-run lifecycle verification.
    # -------------------------------------------------------------------------

    $remainingOpenRuns = Invoke-PsqlScalar -Sql @"
SELECT count(*)
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
  AND sr.status IN ('STARTED','STAGING','VALIDATING','FINALIZING');
"@

    if ([int]$remainingOpenRuns -ne 0) {
        throw "Nightly refresh returned success but left $remainingOpenRuns non-terminal Rebrickable run(s)."
    }

    $latestStatus = Invoke-PsqlScalar -Sql @"
SELECT sr.status
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
ORDER BY sr.started_at DESC
LIMIT 1;
"@

    if ($latestStatus -ne "COMPLETED") {
        throw "Latest Rebrickable source run is '$latestStatus', expected 'COMPLETED'."
    }

    Write-Log PASS "Latest Rebrickable source run is COMPLETED."
    Write-Log PASS "No non-terminal Rebrickable runs remain."

    # -------------------------------------------------------------------------
    # Retention cleanup. Never deletes this run's snapshot/log.
    # -------------------------------------------------------------------------

    $snapshotCutoff = (Get-Date).AddDays(-$SnapshotRetentionDays)

    Get-ChildItem -LiteralPath $snapshotRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -ne $snapshotDir -and
            $_.LastWriteTime -lt $snapshotCutoff
        } |
        ForEach-Object {
            Write-Log INFO "Removing expired snapshot: $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }

    $logCutoff = (Get-Date).AddDays(-$LogRetentionDays)

    Get-ChildItem -LiteralPath $logRoot -File -Filter "rebrickable_nightly_*.log" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -ne $script:LogFile -and
            $_.LastWriteTime -lt $logCutoff
        } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $elapsed = (Get-Date) - $startedAt

    Write-Log PASS ("Nightly Rebrickable refresh completed in {0:hh\:mm\:ss}." -f $elapsed)
    exit 0
}
catch {
    $elapsed = (Get-Date) - $startedAt

    try {
        Write-Log ERROR $_.Exception.Message

        if ($_.ScriptStackTrace) {
            Write-Log ERROR $_.ScriptStackTrace
        }

        Write-Log ERROR ("Nightly Rebrickable refresh failed after {0:hh\:mm\:ss}." -f $elapsed)
    }
    catch {
        Write-Host "[ERROR] Nightly Rebrickable refresh failed."
        Write-Host $_.Exception.Message
    }

    exit 1
}
finally {
    if ($lockFile -and (Test-Path -LiteralPath $lockFile -PathType Leaf)) {
        try {
            $ownerPidText = Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue |
                Select-Object -First 1

            $ownerPid = 0

            if ([int]::TryParse([string]$ownerPidText, [ref]$ownerPid) -and
                $ownerPid -eq $PID) {
                Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            # Do not mask the actual import result because lock cleanup failed.
        }
    }
}
