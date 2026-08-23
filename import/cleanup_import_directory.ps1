param(
    [switch]$WhatIf,
    [int]$KeepLogsPerPhase = 1
)

$ErrorActionPreference = "Stop"

$ImportDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogsDir = Join-Path $ImportDir "logs"

Write-Host "==============================================================================="
Write-Host " BrickTrackr Import Directory Cleanup"
Write-Host "==============================================================================="
Write-Host "[INFO] Import directory: $ImportDir"
Write-Host "[INFO] WhatIf: $WhatIf"
Write-Host "[INFO] Logs retained per phase: $KeepLogsPerPhase"
Write-Host ""

$ObsoleteFiles = @(
    "apply_phase3_importer_audit_hotfix.sql",
    "apply_phase3_source_value_null_hotfix.sql",
    "apply_phase3b_checkpointed_hotfix.sql",
    "apply_phase3b_set_based_hotfix.sql",

    "reconcile_rebrickable_phase3.py",
    "reconcile_rebrickable_phase3_set_based.py",

    "run_rebrickable_phase3b_reconcile_only.ps1",
    "run_rebrickable_phase3b_set_based.ps1",

    "verify_phase3_importer_audit.sql",
    "verify_phase3_source_value_null_fix.sql",
    "verify_phase3b_set_based.sql",
    "verify_phase3b_v3_2_2.sql"
)

$RequiredFiles = @(
    "import_rebrickable_phase1.py",
    "import_rebrickable_phase2.py",
    "import_rebrickable_phase3.py",
    "reconcile_rebrickable_phase3_checkpointed.py",

    "run_rebrickable_phase1_secure.ps1",
    "run_rebrickable_phase2_secure.ps1",
    "run_rebrickable_phase3_secure.ps1",
    "run_rebrickable_phase3b_checkpointed.ps1",
    "show_rebrickable_phase3b_progress.ps1",
)

Write-Host "[CHECK] Required runtime files"
$MissingRequired = @()

foreach ($File in $RequiredFiles) {
    $Path = Join-Path $ImportDir $File

    if (Test-Path -LiteralPath $Path) {
        Write-Host "  [OK]   $File"
    }
    else {
        Write-Host "  [MISS] $File" -ForegroundColor Yellow
        $MissingRequired += $File
    }
}

Write-Host ""
Write-Host "[CLEAN] Obsolete Phase 3 development/hotfix artifacts"

foreach ($File in $ObsoleteFiles) {
    $Path = Join-Path $ImportDir $File

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  [SKIP] $File"
        continue
    }

    if ($WhatIf) {
        Write-Host "  [WOULD REMOVE] $File" -ForegroundColor Yellow
    }
    else {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "  [REMOVED] $File"
    }
}

Write-Host ""
Write-Host "[CLEAN] Logs"

if (Test-Path -LiteralPath $LogsDir) {
    $LogGroups = @(
        @{
            Name = "Phase 1"
            Pattern = "rebrickable_phase1_*.log"
        },
        @{
            Name = "Phase 2"
            Pattern = "rebrickable_phase2_*.log"
        },
        @{
            Name = "Phase 3"
            Pattern = "rebrickable_phase3_*.log"
        },
        @{
            Name = "Phase 3B checkpointed"
            Pattern = "rebrickable_phase3b_checkpointed_*.log"
        },
        @{
            Name = "Phase 3B obsolete set-based"
            Pattern = "rebrickable_phase3b_set_based_*.log"
            RemoveAll = $true
        }
    )

    foreach ($Group in $LogGroups) {
        $Files = @(
            Get-ChildItem `
                -LiteralPath $LogsDir `
                -Filter $Group.Pattern `
                -File `
                -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        )

        if ($Files.Count -eq 0) {
            continue
        }

        Write-Host "  [$($Group.Name)] found $($Files.Count)"

        if ($Group.RemoveAll) {
            $Remove = $Files
            $Keep = @()
        }
        else {
            $Keep = @($Files | Select-Object -First $KeepLogsPerPhase)
            $Remove = @($Files | Select-Object -Skip $KeepLogsPerPhase)
        }

        foreach ($File in $Keep) {
            Write-Host "    [KEEP]   $($File.Name)"
        }

        foreach ($File in $Remove) {
            if ($WhatIf) {
                Write-Host "    [WOULD REMOVE] $($File.Name)" -ForegroundColor Yellow
            }
            else {
                Remove-Item -LiteralPath $File.FullName -Force
                Write-Host "    [REMOVED] $($File.Name)"
            }
        }
    }
}
else {
    Write-Host "  [SKIP] logs directory does not exist"
}

Write-Host ""
Write-Host "[CHECK] Rebrickable downloads"

$DownloadsDir = Join-Path $ImportDir "rebrickable-downloads"

if (Test-Path -LiteralPath $DownloadsDir) {
    $Downloads = @(
        Get-ChildItem -LiteralPath $DownloadsDir -File |
        Sort-Object Name
    )

    foreach ($File in $Downloads) {
        Write-Host "  [KEEP] $($File.Name)"
    }
}
else {
    Write-Host "  [INFO] rebrickable-downloads directory not present"
}

Write-Host ""
Write-Host "==============================================================================="
if ($MissingRequired.Count -gt 0) {
    Write-Host "[WARN] Cleanup complete, but required runtime files are missing:" -ForegroundColor Yellow
    foreach ($File in $MissingRequired) {
        Write-Host "       $File"
    }
}
elseif ($WhatIf) {
    Write-Host "[PASS] Dry run complete. No files were changed." -ForegroundColor Green
}
else {
    Write-Host "[PASS] Import directory cleanup completed." -ForegroundColor Green
}
Write-Host "==============================================================================="
