# ===============================================================================
# BrickTrackr Rebrickable Import - Phase 1 Launcher
# File: run_rebrickable_phase1_secure.ps1
# ===============================================================================

Clear-Host

$ErrorActionPreference = "Stop"

# ===============================================================================
# LOCAL CONFIGURATION
# ===============================================================================

# Dedicated BrickTrackr importer login.
$DatabaseUser = "bricktrackr_import"

# Target PostgreSQL server/database.
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

# Retain downloaded Rebrickable archives.
$KeepDownloads = $true

# Directories relative to this PowerShell script.
$DownloadDirectoryName = "rebrickable-downloads"
$LogDirectoryName = "logs"


# ===============================================================================
# PATHS
# ===============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "import_rebrickable_phase1.py"
$WorkDir = Join-Path $ScriptDir $DownloadDirectoryName

$LogDir = if ($env:BRICKTRACKR_IMPORT_LOG_DIR) {
    $env:BRICKTRACKR_IMPORT_LOG_DIR
}
else {
    Join-Path $ScriptDir $LogDirectoryName
}


# ===============================================================================
# START
# ===============================================================================

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Import - Phase 1"
Write-Host "==============================================================================="
Write-Host ""


# ===============================================================================
# PROMPT FOR DATABASE PASSWORD
# ===============================================================================

Write-Host "[INFO] PostgreSQL connection"
Write-Host "       Server:   ${DatabaseHost}:${DatabasePort}"
Write-Host "       Database: $DatabaseName"
Write-Host "       User:     $DatabaseUser"
Write-Host ""

$SecurePassword = Read-Host `
    "Enter PostgreSQL password for '$DatabaseUser'" `
    -AsSecureString

if ($SecurePassword.Length -eq 0) {
    Write-Host "[FAIL] Password was not supplied." -ForegroundColor Red
    exit 2
}

# Convert only for the minimum time needed to build the psycopg DSN.
$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)

try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
}

# URL-encode username/password/database components to safely handle characters
# such as @, :, /, #, %, ? and spaces.
$EncodedUser = [System.Uri]::EscapeDataString($DatabaseUser)
$EncodedPassword = [System.Uri]::EscapeDataString($PlainPassword)
$EncodedDatabase = [System.Uri]::EscapeDataString($DatabaseName)

$DatabaseUrl = (
    "postgresql://{0}:{1}@{2}:{3}/{4}" -f
    $EncodedUser,
    $EncodedPassword,
    $DatabaseHost,
    $DatabasePort,
    $EncodedDatabase
)

# Clear the local plaintext variable immediately after constructing the DSN.
$PlainPassword = $null
$EncodedPassword = $null
$SecurePassword = $null

# The Python importer reads this environment variable.
$env:BRICKTRACKR_IMPORT_DATABASE_URL = $DatabaseUrl


# ===============================================================================
# VALIDATE PYTHON
# ===============================================================================

$PythonCommand = Get-Command python -ErrorAction SilentlyContinue

if (-not $PythonCommand) {
    Write-Host "[FAIL] Python was not found on PATH." -ForegroundColor Red
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    exit 3
}

$PythonExe = $PythonCommand.Source


# ===============================================================================
# VALIDATE IMPORTER SCRIPT
# ===============================================================================

if (-not (Test-Path -LiteralPath $PythonScript)) {
    Write-Host "[FAIL] Importer script not found:" -ForegroundColor Red
    Write-Host "       $PythonScript"
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    exit 4
}


# ===============================================================================
# VALIDATE PYTHON DEPENDENCIES
# ===============================================================================

& $PythonExe -c "import psycopg, requests" 2>$null

if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Required Python packages are missing." -ForegroundColor Red
    Write-Host ""
    Write-Host "Install them with:"
    Write-Host ""
    Write-Host "  `"$PythonExe`" -m pip install psycopg requests"
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    exit 5
}


# ===============================================================================
# PREPARE DIRECTORIES
# ===============================================================================

try {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}
catch {
    Write-Host "[FAIL] Unable to create required directories." -ForegroundColor Red
    Write-Host $_.Exception.Message
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    exit 6
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogDir "rebrickable_phase1_$Timestamp.log"


# ===============================================================================
# EXECUTION SUMMARY
# ===============================================================================

Write-Host ""
Write-Host "[INFO] Python:"
Write-Host "       $PythonExe"
Write-Host ""

Write-Host "[INFO] Importer:"
Write-Host "       $PythonScript"
Write-Host ""

Write-Host "[INFO] Download directory:"
Write-Host "       $WorkDir"
Write-Host ""

Write-Host "[INFO] Keep downloads:"
Write-Host "       $KeepDownloads"
Write-Host ""

Write-Host "[INFO] Log:"
Write-Host "       $LogFile"
Write-Host ""

Write-Host "[INFO] Database password accepted securely."
Write-Host "       Password will not be printed or written to the log."
Write-Host ""


# ===============================================================================
# BUILD IMPORTER ARGUMENTS
# ===============================================================================

$ImporterArgs = @(
    $PythonScript,
    "--work-dir",
    $WorkDir
)

if ($KeepDownloads) {
    $ImporterArgs += "--keep-downloads"
}


# ===============================================================================
# RUN IMPORTER
# ===============================================================================

Write-Host "-------------------------------------------------------------------------------"
Write-Host " Starting Rebrickable Phase 1 import"
Write-Host "-------------------------------------------------------------------------------"
Write-Host ""

try {
    & $PythonExe @ImporterArgs 2>&1 |
        Tee-Object -FilePath $LogFile

    $ImportExitCode = $LASTEXITCODE
}
catch {
    $_ |
        Out-String |
        Tee-Object -FilePath $LogFile -Append |
        Write-Host

    $ImportExitCode = 1
}
finally {
    # Remove the credential-bearing environment variable from this PowerShell
    # process as soon as the child importer finishes.
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    $DatabaseUrl = $null
}


# ===============================================================================
# RESULT
# ===============================================================================

Write-Host ""
Write-Host "-------------------------------------------------------------------------------"

if ($ImportExitCode -eq 0) {
    Write-Host "[PASS] Rebrickable Phase 1 completed successfully." -ForegroundColor Green

    Write-Host "[INFO] Downloads retained in:"
    Write-Host "       $WorkDir"

    Write-Host "[INFO] Full log:"
    Write-Host "       $LogFile"

    exit 0
}

if ($ImportExitCode -eq 130) {
    Write-Host "[FAIL] Rebrickable Phase 1 was interrupted by the operator." -ForegroundColor Yellow

    Write-Host "[INFO] Full log:"
    Write-Host "       $LogFile"

    exit 130
}

Write-Host "[FAIL] Rebrickable Phase 1 failed." -ForegroundColor Red

Write-Host "[INFO] Python exit code:"
Write-Host "       $ImportExitCode"

Write-Host "[INFO] Full log:"
Write-Host "       $LogFile"

exit $ImportExitCode
