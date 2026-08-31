[CmdletBinding()]
param(
    [string]$PythonPath = "",
    [string]$SchemaVerifier = "",
    [string]$TransactionContextRunner = "",
    [string]$AdminUserRunner = ""
)

$ErrorActionPreference = "Stop"

function Write-Run {
    param([string]$Message)
    Write-Host "[RUN ] $Message"
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message"
}

function Resolve-Python {
    param([string]$Candidate)

    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
            throw "Python executable not found: $Candidate"
        }
        return (Resolve-Path -LiteralPath $Candidate).Path
    }

    $candidates = @(
        (Join-Path $script:RepoRoot ".venv\Scripts\python.exe"),
        "L:\etc\Python\Python313\python.exe"
    )

    foreach ($candidatePath in $candidates) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    $command = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command "python" -ErrorAction SilentlyContinue
    }

    if ($command) {
        return $command.Source
    }

    throw "Python executable was not found."
}

function Resolve-RequiredFile {
    param(
        [string]$Candidate,
        [string]$DefaultPath,
        [string]$Label
    )

    $path = $Candidate
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $DefaultPath
    }
    elseif (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $script:RepoRoot $path
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$Label not found: $path"
    }

    return (Resolve-Path -LiteralPath $path).Path
}

function Invoke-NativeStep {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$Label
    )

    Write-Run $Label
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        & $Executable @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode."
    }

    Write-Pass $Label
}

function Invoke-PowerShellStep {
    param(
        [string]$ScriptPath,
        [string]$Label
    )

    Write-Run $Label
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        & $ScriptPath
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode."
    }

    Write-Pass $Label
}

try {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $script:RepoRoot = Split-Path -Parent $scriptRoot

    $python = Resolve-Python -Candidate $PythonPath

    $schemaVerifierPath = Resolve-RequiredFile `
        -Candidate $SchemaVerifier `
        -DefaultPath (Join-Path $script:RepoRoot "master.schema\tools\verify_schema_contract.py") `
        -Label "Schema contract verifier"

    $transactionContextRunnerPath = Resolve-RequiredFile `
        -Candidate $TransactionContextRunner `
        -DefaultPath (Join-Path $script:RepoRoot "tools\test_transaction_context.ps1") `
        -Label "Transaction context runner"

    $adminUserRunnerPath = Resolve-RequiredFile `
        -Candidate $AdminUserRunner `
        -DefaultPath (Join-Path $script:RepoRoot "tools\test_admin_users.ps1") `
        -Label "Admin user contract runner"

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Database Verification"
    Write-Host "==============================================================================="
    Write-Host "Repository:          $script:RepoRoot"
    Write-Host "Python:              $python"
    Write-Host "Schema verifier:     $schemaVerifierPath"
    Write-Host "Transaction context: $transactionContextRunnerPath"
    Write-Host "Admin user test:     $adminUserRunnerPath"
    Write-Host ""

    Invoke-NativeStep `
        -Executable $python `
        -Arguments @($schemaVerifierPath) `
        -Label "Schema Contract Verification"

    Write-Host ""

    Invoke-PowerShellStep `
        -ScriptPath $transactionContextRunnerPath `
        -Label "Transaction Context Contract Verification"

    Write-Host ""

    Invoke-PowerShellStep `
        -ScriptPath $adminUserRunnerPath `
        -Label "Admin User Contract Verification"

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Pass "BrickTrackr database verification completed successfully."
    Write-Host "==============================================================================="
    exit 0
}
catch {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Fail $_.Exception.Message
    Write-Host "==============================================================================="
    exit 1
}
