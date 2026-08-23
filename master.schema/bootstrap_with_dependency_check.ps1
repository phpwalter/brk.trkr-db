Clear-Host
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Preflight = Join-Path $ScriptDir "0000_bootstrap\0000_dependency_preflight.sql"
$Bootstrap = Join-Path $ScriptDir "bootstrap_fixed.ps1"

Write-Host "==============================================================================="
Write-Host " BrickTrackr dependency-manifest precheck"
Write-Host "==============================================================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $Preflight)) {
    Write-Host "[FAIL] Active dependency preflight file not found:" -ForegroundColor Red
    Write-Host "       $Preflight"
    exit 10
}

$Required = @(
    "1000_function/1015_rebrickable_reference_reconcile.sql",
    "1000_function/1016_rebrickable_catalog_reconcile.sql"
)

$Content = Get-Content -LiteralPath $Preflight -Raw

foreach ($File in $Required) {
    if ($Content -notmatch [regex]::Escape($File)) {
        Write-Host "[FAIL] Active dependency preflight is stale." -ForegroundColor Red
        Write-Host "       Missing managed file:"
        Write-Host "       $File"
        Write-Host ""
        Write-Host "       Active file:"
        Write-Host "       $Preflight"
        exit 11
    }

    Write-Host "[PASS] Manifest contains $File" -ForegroundColor Green
}

Write-Host ""
Write-Host "[PASS] Active SQL dependency manifest contains Phase 2 and Phase 3." -ForegroundColor Green
Write-Host ""

if (-not (Test-Path -LiteralPath $Bootstrap)) {
    Write-Host "[INFO] bootstrap_fixed.ps1 was not found at:" -ForegroundColor Yellow
    Write-Host "       $Bootstrap"
    Write-Host ""
    Write-Host "Run your normal bootstrap script now."
    exit 0
}

Write-Host "Launching bootstrap_fixed.ps1..."
Write-Host ""
& $Bootstrap
exit $LASTEXITCODE
