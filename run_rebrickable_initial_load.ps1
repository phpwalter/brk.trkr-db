[CmdletBinding()]
param(
    [string]$RepoRoot = "L:\var\www\Brk.Trkr\brk.trkr-db",
    [string]$ConfigPath,
    [string]$PythonExe = "python",
    [string[]]$RefreshArgs = @(),
    [int]$SnapshotRetentionDays = 7
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$startedAt = Get-Date

try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $RepoRoot "config\bricktrackr.ini"
    }

    $loader = Join-Path $RepoRoot "tools\Load-BrickTrackrConfig.ps1"
    if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) {
        throw "Shared config loader not found: $loader"
    }

    . $loader
    $db = Import-BrickTrackrDatabaseConfig -ConfigPath $ConfigPath

    $importDir = Join-Path $RepoRoot "import"
    $downloader = Join-Path $importDir "download_rebrickable_snapshot.py"
    $refresh = Join-Path $importDir "run_rebrickable_full_refresh.ps1"
    $snapshotRoot = Join-Path $importDir "runtime\snapshots"

    foreach ($required in @($downloader, $refresh)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required initial-load component not found: $required"
        }
    }

    New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $snapshotDir = Join-Path $snapshotRoot "initial_$stamp"

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Initial Rebrickable Load"
    Write-Host "==============================================================================="
    Write-Host ""
    Write-BrickTrackrDatabaseConfig -Config $db
    Write-Host ""
    Write-Host "[INFO] Fresh snapshot directory:"
    Write-Host "       $snapshotDir"
    Write-Host ""

    Write-Host "[INFO] Downloading all 12 Rebrickable source archives fresh..."

    & $PythonExe $downloader --output-dir $snapshotDir

    $downloadCode = $LASTEXITCODE
    if ($downloadCode -ne 0) {
        throw "Fresh Rebrickable snapshot download failed with exit code $downloadCode"
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
        throw "Fresh snapshot is incomplete. Missing: $($missing -join ', ')"
    }

    Write-Host "[PASS] Fresh snapshot downloaded and validated."
    Write-Host "[INFO] Starting canonical Phase 1-6 import engine..."

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $refresh `
        -StartPhase PHASE1 `
        -SnapshotDir $snapshotDir `
        @RefreshArgs

    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw "Initial Rebrickable load failed with exit code $code"
    }

    $elapsed = (Get-Date) - $startedAt

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host "[PASS] Initial Rebrickable load completed."
    Write-Host ("Elapsed: {0:hh\:mm\:ss}" -f $elapsed)
    Write-Host "==============================================================================="
    exit 0
}
catch {
    $elapsed = (Get-Date) - $startedAt

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host "[FAIL] Initial Rebrickable load failed."
    Write-Host "==============================================================================="
    Write-Host ("Error:   " + $_.Exception.Message)
    Write-Host ("Elapsed: {0:hh\:mm\:ss}" -f $elapsed)

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Stack:"
        Write-Host $_.ScriptStackTrace
    }

    exit 1
}
finally {
    if (Test-Path -LiteralPath $snapshotRoot -PathType Container) {
        $cutoff = (Get-Date).AddDays(-$SnapshotRetentionDays)

        Get-ChildItem $snapshotRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
