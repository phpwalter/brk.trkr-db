[CmdletBinding()]
param(
    [string]$ReadRunner = "",
    [string]$WriteRunner = ""
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

function Resolve-RunnerPath {
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
        throw "$Label runner not found: $path"
    }

    return (Resolve-Path -LiteralPath $path).Path
}

function Invoke-ChildRunner {
    param(
        [string]$Path,
        [string]$Label
    )

    Write-Run $Label

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        & $Path
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

    $defaultRead = Join-Path $script:RepoRoot "tools\test_admin_user_reads.ps1"
    $defaultWrite = Join-Path $script:RepoRoot "tools\test_admin_user_writes.ps1"

    $readPath = Resolve-RunnerPath `
        -Candidate $ReadRunner `
        -DefaultPath $defaultRead `
        -Label "Read"

    $writePath = Resolve-RunnerPath `
        -Candidate $WriteRunner `
        -DefaultPath $defaultWrite `
        -Label "Write/lifecycle"

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Admin User Contract Test"
    Write-Host "==============================================================================="
    Write-Host "Read runner:  $readPath"
    Write-Host "Write runner: $writePath"
    Write-Host ""

    Invoke-ChildRunner `
        -Path $readPath `
        -Label "Admin user read contract"

    Write-Host ""

    Invoke-ChildRunner `
        -Path $writePath `
        -Label "Admin user write/lifecycle contract"

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Pass "BrickTrackr admin user contract verification passed."
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
