param(
    [string]$ImportRoot = $PSScriptRoot,
    [switch]$Apply,
    [int]$KeepNewestLogsPerPhase = 2
)

$ErrorActionPreference = "Stop"

$ImportRoot = (Resolve-Path $ImportRoot).Path
$LogsDir = Join-Path $ImportRoot "logs"

Write-Host "==============================================================================="
Write-Host " BrickTrackr import/ cleanup"
Write-Host "==============================================================================="
Write-Host "[INFO] Root: $ImportRoot"
Write-Host "[INFO] Mode: $(if ($Apply) { 'APPLY' } else { 'DRY RUN' })"
Write-Host "[INFO] Keep newest logs per phase/group: $KeepNewestLogsPerPhase"
Write-Host ""

$RemoveFiles = @(
    "README_PHASE4A.txt",
    "README_PHASE4B.txt",
    "README_PHASE5A.txt",
    "README_PHASE5B.txt",
    "README_PHASE5_CANONICALIZE.txt",
    "README_PHASE5_POST_VERIFY.txt",

    "apply_live_import_context_hotfix.sql",
    "apply_phase4b_checkpointed_hotfix.sql",
    "apply_phase5b_checkpointed_hotfix.sql",

    "canonicalize_import_checkpoint_tables.py",
    "canonicalize_rebrickable_phase5.py",
    "diagnose_1016_dependency_contract.py",
    "fix_0402_requirement_groups_syntax.py",
    "rebuild_1016_from_live_db.py",
    "repair_1016_import_context.py",
    "repair_requirement_groups_requirement_key.py",

    "inspect_phase5b_definition_contract.sql",
    "inspect_phase5b_final_contract.sql",
    "inspect_phase5b_parent_classes.sql",

    "phase4_preflight_report.txt",
    "phase5_post_verify_report.txt",
    "phase5_preflight_report.txt",
    "phase5b_definition_contract.txt",
    "phase5b_final_contract.txt",
    "phase5b_parent_classes.txt",

    "run_canonicalize_import_checkpoint_tables.ps1",
    "run_canonicalize_rebrickable_phase5.ps1",
    "run_diagnose_1016_dependency_contract.ps1",
    "run_fix_0402_requirement_groups_syntax.ps1",
    "run_phase5b_definition_contract.ps1",
    "run_phase5b_final_contract.ps1",
    "run_phase5b_parent_classification.ps1",
    "run_rebrickable_phase4_preflight.ps1",
    "run_rebrickable_phase5_post_verify.ps1",
    "run_rebrickable_phase5_preflight.ps1",
    "run_rebuild_1016_from_live_db.ps1",
    "run_repair_1016_import_context.ps1",
    "run_repair_requirement_groups_requirement_key.ps1",

    "verify_rebrickable_phase4a.sql",
    "verify_rebrickable_phase5_post.sql",
    "verify_rebrickable_phase5a.sql"
)

function Remove-PlannedFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $Rel = [System.IO.Path]::GetRelativePath($ImportRoot, $Path)

    if ($Apply) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "[DELETE] $Rel"
    }
    else {
        Write-Host "[DRY]    $Rel"
    }
}

foreach ($Name in $RemoveFiles) {
    Remove-PlannedFile -Path (Join-Path $ImportRoot $Name)
}

if (Test-Path -LiteralPath $LogsDir) {
    $Logs = Get-ChildItem -LiteralPath $LogsDir -File -Filter "*.log"

    $Grouped = $Logs | Group-Object {
        if ($_.BaseName -match '^(.*)_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$') {
            $Matches[1]
        }
        else {
            $_.BaseName
        }
    }

    foreach ($Group in $Grouped) {
        $Ordered = $Group.Group | Sort-Object LastWriteTime -Descending
        $ToDelete = $Ordered | Select-Object -Skip $KeepNewestLogsPerPhase

        foreach ($Log in $ToDelete) {
            Remove-PlannedFile -Path $Log.FullName
        }
    }
}

Write-Host ""
Write-Host "==============================================================================="
if ($Apply) {
    Write-Host " [PASS] import/ cleanup completed"
}
else {
    Write-Host " [PASS] dry run completed; no files deleted"
    Write-Host " [NEXT] rerun with -Apply after reviewing the list"
}
Write-Host "==============================================================================="
