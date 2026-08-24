[CmdletBinding()]
param(
    [string]$RepoRoot = "L:\var\www\Brk.Trkr\brk.trkr-db",
    [string]$ConfigPath,
    [switch]$ForceRecreate = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host ("[INFO]  " + $Message) }
function Write-Pass { param([string]$Message) Write-Host ("[PASS]  " + $Message) }
function Write-Fail { param([string]$Message) Write-Host ("[FAIL]  " + $Message) }

$startedAt = Get-Date

try {
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
        throw "Repository root does not exist: $RepoRoot"
    }

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $RepoRoot "config\bricktrackr.ini"
    }

    $loader = Join-Path $RepoRoot "tools\Load-BrickTrackrConfig.ps1"
    if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) {
        throw "Shared config loader not found: $loader"
    }

    . $loader

    $db = Import-BrickTrackrDatabaseConfig -ConfigPath $ConfigPath

    $installer = Join-Path $RepoRoot "master.schema\install_bricktrackr_greenfield.ps1"
    $bootstrap = Join-Path $RepoRoot "master.schema\bootstrap.sql"
    $manifest = Join-Path $RepoRoot "master.schema\DEPENDENCY_MANIFEST.json"

    foreach ($required in @($installer, $bootstrap, $manifest)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required greenfield file not found: $required"
        }
    }

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Greenfield Database Build"
    Write-Host "==============================================================================="
    Write-Host ""

    Write-BrickTrackrDatabaseConfig -Config $db
    Write-Host ""

    if ($ForceRecreate) {
        Write-Host "[WARN] Target database may be dropped and recreated."
        Write-Host ""
    }

    Write-Pass "Required greenfield files are present."

    Push-Location $RepoRoot
    try {
        $childArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $installer,
            "-HostName", $db.HostName,
            "-Port", [string]$db.Port,
            "-AdminUser", $db.AdminUser,
            "-Database", $db.Database
        )

        if ($ForceRecreate) {
            $childArgs += "-ForceRecreate"
        }

        Write-Info "Starting canonical greenfield installer..."
        & powershell.exe @childArgs

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Greenfield installer failed with exit code $exitCode."
        }
    }
    finally {
        Pop-Location
    }

    $elapsed = (Get-Date) - $startedAt

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Pass "BrickTrackr greenfield database build completed."
    Write-Host ("Elapsed: {0:hh\:mm\:ss}" -f $elapsed)
    Write-Host "==============================================================================="
    Write-Host ""
    Write-Host "Next:"
    Write-Host "  .\run_rebrickable_initial_load.ps1"
    Write-Host ""

    exit 0
}
catch {
    $elapsed = (Get-Date) - $startedAt

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Fail "BrickTrackr greenfield database build failed."
    Write-Host "==============================================================================="
    Write-Host ""
    Write-Host ("Error:   " + $_.Exception.Message)
    Write-Host ("Elapsed: {0:hh\:mm\:ss}" -f $elapsed)

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Stack:"
        Write-Host $_.ScriptStackTrace
    }

    exit 1
}
