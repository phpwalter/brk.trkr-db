[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}

$RepoRoot = [System.IO.Path]::GetFullPath(
    (Resolve-Path -LiteralPath $RepoRoot).Path
)

$PackageRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
)

$files = @(
    "master.schema\5000_function\5700_system\5709_system_request_context.sql",
    "master.schema\5000_function\5900_tests\5979_test_system_request_context.sql",
    "master.schema\1200_validation\1217_pgbouncer_transaction_context_validation.sql",
    "master.schema\tools\verify_transaction_context.py",
    "master.schema\tools\verify_pgbouncer_transaction_context.psql",
    "master.schema\tools\verify_schema_contract.py",
    "master.schema\tools\sync_transaction_context_dependencies.py",
    "tests\transaction_context.sql",
    "tools\test_transaction_context.ps1",
    "tools\verify_bricktrackr.ps1"
)

function Resolve-Python {
    param([string]$Root)

    $candidates = @(
        (Join-Path $Root ".venv\Scripts\python.exe"),
        "L:\etc\Python\Python313\python.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $cmd = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $cmd = Get-Command "python" -ErrorAction SilentlyContinue
    }

    if ($cmd) {
        return $cmd.Source
    }

    throw "Python executable not found."
}

function Test-SamePath {
    param(
        [Parameter(Mandatory=$true)][string]$Left,
        [Parameter(Mandatory=$true)][string]$Right
    )

    $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\')
    $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\')

    return [string]::Equals(
        $leftFull,
        $rightFull,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

Write-Host "==============================================================================="
Write-Host " BrickTrackr Transaction Context Package Installer"
Write-Host "==============================================================================="
Write-Host "Package: $PackageRoot"
Write-Host "Repo:    $RepoRoot"
Write-Host ""

$selfInstall = Test-SamePath -Left $PackageRoot -Right $RepoRoot

if ($selfInstall) {
    Write-Host "[INFO] Package is already located inside the target repository."
    Write-Host "[INFO] File-copy phase will be skipped; verification will continue."
    Write-Host ""
}
else {
    foreach ($rel in $files) {
        $source = Join-Path $PackageRoot $rel
        $target = Join-Path $RepoRoot $rel

        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Package file missing: $source"
        }

        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($target, "Replace from transaction-context package")) {
            Copy-Item -LiteralPath $source -Destination $target -Force
            Write-Host "[COPY] $rel"
        }
    }
}

$python = Resolve-Python -Root $RepoRoot

$schemaRoot = Join-Path $RepoRoot "master.schema"
$sync = Join-Path $schemaRoot "tools\sync_transaction_context_dependencies.py"
$deps = Join-Path $schemaRoot "tools\verify_dependencies.py"
$static = Join-Path $schemaRoot "tools\verify_transaction_context.py"

foreach ($required in @($sync, $deps, $static)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required verification file missing: $required"
    }
}

Push-Location $schemaRoot
try {
    Write-Host ""
    Write-Host "[RUN ] Synchronize transaction-context dependency metadata"
    & $python $sync
    if ($LASTEXITCODE -ne 0) {
        throw "Dependency synchronization failed with exit code $LASTEXITCODE."
    }
    Write-Host "[PASS] Synchronize transaction-context dependency metadata"

    Write-Host ""
    Write-Host "[RUN ] Verify dependency manifest"
    & $python $deps
    if ($LASTEXITCODE -ne 0) {
        throw "Dependency verification failed with exit code $LASTEXITCODE."
    }
    Write-Host "[PASS] Verify dependency manifest"

    Write-Host ""
    Write-Host "[RUN ] Verify transaction-context static contract"
    & $python $static
    if ($LASTEXITCODE -ne 0) {
        throw "Transaction-context static verification failed with exit code $LASTEXITCODE."
    }
    Write-Host "[PASS] Verify transaction-context static contract"
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "==============================================================================="
Write-Host "[PASS] Transaction-context package installed and statically verified."
Write-Host "==============================================================================="
Write-Host ""
Write-Host "Next:"
Write-Host "  .\tools\verify_bricktrackr.ps1"
