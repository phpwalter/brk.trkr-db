[CmdletBinding()]
param(
    [string]$ImportRoot = "L:\var\www\Brk.Trkr\brk.trkr-db\import",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SnapshotDir,
    [string]$PythonExe = "python",
    [string]$PsqlExe = "psql",
    [string]$LogDir = "",
    [int]$RetentionDays = 30,

    [ValidateSet(
        "PHASE1","PHASE2","PHASE3A","PHASE3B",
        "PHASE4A","PHASE4B","PHASE5A","PHASE5B",
        "PHASE6A","PHASE6B"
    )]
    [string]$StartPhase = "PHASE1",

    # Optional explicit resume run. Required when starting directly at a B phase
    # unless the latest open Rebrickable run is the intended run.
    [string]$SourceRunId = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Connection target comes from the shared BrickTrackr config loader.
foreach ($requiredEnv in @(
    "BRICKTRACKR_DB_HOST",
    "BRICKTRACKR_DB_PORT",
    "BRICKTRACKR_DATABASE"
)) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($requiredEnv))) {
        throw "Required environment variable is not set: $requiredEnv"
    }
}

$DbHost = $env:BRICKTRACKR_DB_HOST
$DbPort = [int]$env:BRICKTRACKR_DB_PORT
$DbName = $env:BRICKTRACKR_DATABASE

# Scoped runtime importer identity.
$DbUser = if ($env:BRICKTRACKR_IMPORT_USER) {
    $env:BRICKTRACKR_IMPORT_USER
}
else {
    "bricktrackr_import"
}

# Password remains external to bricktrackr.ini.
# Existing PGPASSWORD is honored; fallback retained for current local dev setup.
if ([string]::IsNullOrWhiteSpace($env:PGPASSWORD)) {
    $env:PGPASSWORD = "root"
}

$env:BRICKTRACKR_IMPORT_DATABASE_URL =
    "postgresql://${DbUser}:$($env:PGPASSWORD)@${DbHost}:${DbPort}/${DbName}"

$SnapshotDir = [System.IO.Path]::GetFullPath($SnapshotDir)

if (-not (Test-Path -LiteralPath $SnapshotDir -PathType Container)) {
    throw "Required Rebrickable snapshot directory does not exist: $SnapshotDir"
}

if (-not $LogDir) {
    $LogDir = Join-Path $ImportRoot "logs"
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = Join-Path $LogDir "rebrickable_full_refresh_$stamp.log"

function Write-Log {
    param([string]$Level,[string]$Message)

    $line = "{0:o} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-PsqlScalar {
    param([Parameter(Mandatory)][string]$Sql)

    $args = @(
        "-h", $DbHost,
        "-p", "$DbPort",
        "-U", $DbUser,
        "-d", $DbName,
        "-v", "ON_ERROR_STOP=1",
        "-A", "-t", "-q",
        "-c", $Sql
    )

    $output = & $PsqlExe @args 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "psql failed: $($output -join [Environment]::NewLine)"
    }

    $lines = @(
        $output |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -ne "" }
    )

    if ($lines.Count -eq 0) {
        return ""
    }

    return $lines[-1]
}

function Get-LatestOpenRebrickableRun {
    $sql = @"
SELECT sr.source_run_id::text
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE es.source_code = 'REBRICKABLE'
  AND sr.status IN ('STARTED','STAGING','VALIDATING','FINALIZING')
ORDER BY sr.started_at DESC
LIMIT 1;
"@

    return Invoke-PsqlScalar -Sql $sql
}

function Assert-SourceRunExists {
    param([Parameter(Mandatory)][string]$RunId)

    $sql = @"
SELECT count(*)::text
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
WHERE sr.source_run_id = '$RunId'::uuid
  AND es.source_code = 'REBRICKABLE'
  AND sr.status IN ('STARTED','STAGING','VALIDATING','FINALIZING');
"@

    $count = Invoke-PsqlScalar -Sql $sql

    if ([int]$count -ne 1) {
        throw "Source run $RunId does not exist or is not a non-terminal REBRICKABLE run."
    }
}


function Complete-RebrickableRun {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string[]]$DatasetNames,
        [Parameter(Mandatory)][string]$SummaryKey
    )

    $datasetList = ($DatasetNames | ForEach-Object {
        "'" + $_.Replace("'", "''") + "'"
    }) -join ","

    $sql = @"
DO `$`$
DECLARE
    v_status import.source_run_status;
    v_bad integer;
BEGIN
    SELECT status
      INTO v_status
      FROM import.source_runs
     WHERE source_run_id = '$RunId'::uuid
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source run $RunId does not exist';
    END IF;

    IF v_status = 'COMPLETED'::import.source_run_status THEN
        RETURN;
    END IF;

    IF v_status = 'FAILED'::import.source_run_status THEN
        RAISE EXCEPTION 'Source run $RunId is FAILED';
    END IF;

    SELECT count(*)
      INTO v_bad
      FROM import.source_run_datasets
     WHERE source_run_id = '$RunId'::uuid
       AND dataset_name IN ($datasetList)
       AND status NOT IN (
           'VALIDATED'::import.dataset_status,
           'COMPLETED'::import.dataset_status
       );

    IF v_bad <> 0 THEN
        RAISE EXCEPTION
            'Source run $RunId has % dataset(s) not ready for completion',
            v_bad;
    END IF;

    UPDATE import.source_run_datasets
       SET status = 'COMPLETED'::import.dataset_status,
           completed_at = COALESCE(completed_at, clock_timestamp())
     WHERE source_run_id = '$RunId'::uuid
       AND dataset_name IN ($datasetList)
       AND status = 'VALIDATED'::import.dataset_status;

    PERFORM import.complete_source_run(
        '$RunId'::uuid,
        jsonb_build_object(
            '$SummaryKey',
            jsonb_build_object(
                'strategy', 'orchestrator-finalization',
                'completed_at', clock_timestamp()
            )
        )
    );
END
`$`$;

SELECT status::text
FROM import.source_runs
WHERE source_run_id = '$RunId'::uuid;
"@

    $status = Invoke-PsqlScalar -Sql $sql

    if ($status -ne "COMPLETED") {
        throw "Source run $RunId did not finalize; status=$status"
    }

    Write-Log "PASS" ("Lifecycle finalized source_run_id={0}" -f $RunId)
}

function Assert-RebrickableSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $required = @(
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

    if (-not (Test-Path $Path -PathType Container)) {
        throw "Rebrickable snapshot directory not found: $Path"
    }

    $missing = @(
        foreach ($dataset in $required) {
            $archive = Join-Path $Path "$dataset.csv.gz"
            if (-not (Test-Path $archive -PathType Leaf)) {
                $archive
            }
        }
    )

    if ($missing.Count -gt 0) {
        throw "Rebrickable snapshot incomplete. Missing: $($missing -join ', ')"
    }

    $manifest = Join-Path $Path "snapshot_manifest.json"
    if (-not (Test-Path $manifest -PathType Leaf)) {
        throw "Rebrickable snapshot manifest not found: $manifest"
    }
}


function Invoke-PythonPhase {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$Arguments = @()
    )

    $scriptPath = Join-Path $ImportRoot $ScriptName

    if (-not (Test-Path $scriptPath -PathType Leaf)) {
        throw "Required phase runner not found: $scriptPath"
    }

    Write-Log "INFO" ("START {0}: {1} {2}" -f $Phase, $ScriptName, ($Arguments -join " "))

    Push-Location $ImportRoot
    try {
        & $PythonExe $scriptPath @Arguments 2>&1 |
            ForEach-Object {
                Write-Log $Phase $_.ToString()
            }

        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    Write-Log "INFO" ("{0} process exit code={1}" -f $Phase, $code)

    if ($code -ne 0) {
        throw "$Phase failed with exit code $code"
    }

    Write-Log "PASS" "$Phase completed"
}

$phaseOrder = @(
    "PHASE1","PHASE2","PHASE3A","PHASE3B",
    "PHASE4A","PHASE4B","PHASE5A","PHASE5B",
    "PHASE6A","PHASE6B"
)

$startIndex = [Array]::IndexOf($phaseOrder, $StartPhase)
if ($startIndex -lt 0) {
    throw "Invalid StartPhase: $StartPhase"
}

$currentRunId = $SourceRunId
$exitCode = 1
$started = Get-Date

try {
    Write-Log "INFO" "============================================================"
    Write-Log "INFO" "BrickTrackr Rebrickable full refresh starting"
    Write-Log "INFO" ("StartPhase={0}" -f $StartPhase)
    Write-Log "INFO" ("ImportRoot={0}" -f $ImportRoot)
    Write-Log "INFO" ("SnapshotDir={0}" -f $SnapshotDir)
    Write-Log "INFO" "============================================================"

    Assert-RebrickableSnapshot -Path $SnapshotDir
    Write-Log "PASS" "Complete Rebrickable snapshot verified."

    foreach ($phase in $phaseOrder[$startIndex..($phaseOrder.Count - 1)]) {
        switch ($phase) {
            "PHASE1" {
                Invoke-PythonPhase -Phase $phase -ScriptName "import_rebrickable_phase1.py" -Arguments @("--work-dir", $SnapshotDir)
            }

            "PHASE2" {
                Invoke-PythonPhase -Phase $phase -ScriptName "import_rebrickable_phase2.py"
            }

            "PHASE3A" {
                Invoke-PythonPhase -Phase $phase -ScriptName "import_rebrickable_phase3.py" -Arguments @("--work-dir", $SnapshotDir)

                $currentRunId = Get-LatestOpenRebrickableRun
                if (-not $currentRunId) {
                    throw "PHASE3A completed but no non-terminal REBRICKABLE source run was found."
                }

                Write-Log "INFO" ("PHASE3A source_run_id={0}" -f $currentRunId)
            }

            "PHASE3B" {
                if (-not $currentRunId) {
                    $currentRunId = Get-LatestOpenRebrickableRun
                }

                if (-not $currentRunId) {
                    throw "PHASE3B requires a source run ID."
                }

                Assert-SourceRunExists -RunId $currentRunId

                Invoke-PythonPhase `
                    -Phase $phase `
                    -ScriptName "reconcile_rebrickable_phase3_checkpointed.py" `
                    -Arguments @("--source-run-id", $currentRunId)

                Complete-RebrickableRun `
                    -RunId $currentRunId `
                    -DatasetNames @("parts","sets","minifigs") `
                    -SummaryKey "phase3b_catalog"

                $currentRunId = ""
            }

            "PHASE4A" {
                Invoke-PythonPhase -Phase $phase -ScriptName "import_rebrickable_phase4a_elements.py" -Arguments @("--file", (Join-Path $SnapshotDir "elements.csv.gz"))

                $currentRunId = Get-LatestOpenRebrickableRun
                if (-not $currentRunId) {
                    throw "PHASE4A completed but no non-terminal REBRICKABLE source run was found."
                }

                Write-Log "INFO" ("PHASE4A source_run_id={0}" -f $currentRunId)
            }

            "PHASE4B" {
                if (-not $currentRunId) {
                    $currentRunId = Get-LatestOpenRebrickableRun
                }

                if (-not $currentRunId) {
                    throw "PHASE4B requires a source run ID."
                }

                Assert-SourceRunExists -RunId $currentRunId

                Invoke-PythonPhase `
                    -Phase $phase `
                    -ScriptName "reconcile_rebrickable_phase4b_checkpointed.py" `
                    -Arguments @("--source-run-id", $currentRunId)

                Complete-RebrickableRun `
                    -RunId $currentRunId `
                    -DatasetNames @("elements") `
                    -SummaryKey "phase4b_elements"

                $currentRunId = ""
            }

            "PHASE5A" {
                Invoke-PythonPhase -Phase $phase -ScriptName "import_rebrickable_phase5a_inventory.py" -Arguments @("--downloads-dir", $SnapshotDir)

                $currentRunId = Get-LatestOpenRebrickableRun
                if (-not $currentRunId) {
                    throw "PHASE5A completed but no non-terminal REBRICKABLE source run was found."
                }

                Write-Log "INFO" ("PHASE5A source_run_id={0}" -f $currentRunId)
            }

            "PHASE5B" {
                if (-not $currentRunId) {
                    $currentRunId = Get-LatestOpenRebrickableRun
                }

                if (-not $currentRunId) {
                    throw "PHASE5B requires a source run ID."
                }

                Assert-SourceRunExists -RunId $currentRunId

                Invoke-PythonPhase `
                    -Phase $phase `
                    -ScriptName "reconcile_rebrickable_phase5b_checkpointed.py" `
                    -Arguments @("--source-run-id", $currentRunId)

                Complete-RebrickableRun `
                    -RunId $currentRunId `
                    -DatasetNames @("inventories","inventory_parts","inventory_sets","inventory_minifigs") `
                    -SummaryKey "phase5b_inventory"

                $currentRunId = ""
            }

            "PHASE6A" {
                Invoke-PythonPhase -Phase $phase -ScriptName "import_rebrickable_phase6a_relationships.py" -Arguments @("--archive", (Join-Path $SnapshotDir "part_relationships.csv.gz"))

                $currentRunId = Get-LatestOpenRebrickableRun
                if (-not $currentRunId) {
                    throw "PHASE6A completed but no non-terminal REBRICKABLE source run was found."
                }

                Write-Log "INFO" ("PHASE6A source_run_id={0}" -f $currentRunId)
            }

            "PHASE6B" {
                if (-not $currentRunId) {
                    $currentRunId = Get-LatestOpenRebrickableRun
                }

                if (-not $currentRunId) {
                    throw "PHASE6B requires a source run ID."
                }

                Assert-SourceRunExists -RunId $currentRunId

                Invoke-PythonPhase `
                    -Phase $phase `
                    -ScriptName "reconcile_rebrickable_phase6b_relationships.py" `
                    -Arguments @("--source-run-id", $currentRunId)

                Complete-RebrickableRun `
                    -RunId $currentRunId `
                    -DatasetNames @("part_relationships") `
                    -SummaryKey "phase6b_part_relationships"

                $currentRunId = ""
            }
        }
    }

    $elapsed = (Get-Date) - $started
    Write-Log "PASS" ("Rebrickable full refresh completed in {0:hh\:mm\:ss}" -f $elapsed)
    $exitCode = 0
}
catch {
    $elapsed = (Get-Date) - $started

    Write-Log "ERROR" $_.Exception.Message

    if ($_.ScriptStackTrace) {
        Write-Log "ERROR" $_.ScriptStackTrace
    }

    Write-Log "ERROR" ("Full refresh failed after {0:hh\:mm\:ss}" -f $elapsed)
    $exitCode = 1
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:BRICKTRACKR_IMPORT_DATABASE_URL -ErrorAction SilentlyContinue

    Get-ChildItem $LogDir -File -Filter "rebrickable_full_refresh_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

exit $exitCode
