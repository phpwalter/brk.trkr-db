Clear-Host

$ErrorActionPreference = "Stop"

# ===============================================================================
# BrickTrackr Rebrickable Import - Phase 2 Launcher
# ===============================================================================

$DatabaseUser = "bricktrackr_import"
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "import_rebrickable_phase2.py"
$LogDir = Join-Path $ScriptDir "logs"

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Import - Phase 2"
Write-Host "==============================================================================="
Write-Host ""
Write-Host "[INFO] PostgreSQL connection"
Write-Host "       Server:   ${DatabaseHost}:${DatabasePort}"
Write-Host "       Database: $DatabaseName"
Write-Host "       User:     $DatabaseUser"
Write-Host ""

$SecurePassword = Read-Host "Enter PostgreSQL password for '$DatabaseUser'" -AsSecureString

if ($SecurePassword.Length -eq 0) {
    Write-Host "[FAIL] Password was not supplied." -ForegroundColor Red
    exit 2
}

$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
}

$EncodedUser = [System.Uri]::EscapeDataString($DatabaseUser)
$EncodedPassword = [System.Uri]::EscapeDataString($PlainPassword)
$EncodedDatabase = [System.Uri]::EscapeDataString($DatabaseName)

$DatabaseUrl = "postgresql://{0}:{1}@{2}:{3}/{4}" -f `
    $EncodedUser, $EncodedPassword, $DatabaseHost, $DatabasePort, $EncodedDatabase

$PlainPassword = $null
$EncodedPassword = $null
$SecurePassword = $null

$env:BRICKTRACKR_IMPORT_DATABASE_URL = $DatabaseUrl

$PythonCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $PythonCommand) {
    Write-Host "[FAIL] Python was not found on PATH." -ForegroundColor Red
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    exit 3
}
$PythonExe = $PythonCommand.Source

if (-not (Test-Path -LiteralPath $PythonScript)) {
    Write-Host "[FAIL] Phase 2 importer not found:" -ForegroundColor Red
    Write-Host "       $PythonScript"
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    exit 4
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogDir "rebrickable_phase2_$Timestamp.log"

Write-Host ""
Write-Host "-------------------------------------------------------------------------------"
Write-Host " Starting Rebrickable Phase 2 reconciliation"
Write-Host "-------------------------------------------------------------------------------"
Write-Host ""

try {
    & $PythonExe $PythonScript 2>&1 | Tee-Object -FilePath $LogFile
    $ExitCode = $LASTEXITCODE
}
catch {
    $_ | Out-String | Tee-Object -FilePath $LogFile -Append | Write-Host
    $ExitCode = 1
}
finally {
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    $DatabaseUrl = $null
}

Write-Host ""
Write-Host "-------------------------------------------------------------------------------"

if ($ExitCode -eq 0) {
    Write-Host "[PASS] Rebrickable Phase 2 completed successfully." -ForegroundColor Green
    Write-Host "[INFO] Full log:"
    Write-Host "       $LogFile"
    exit 0
}

Write-Host "[FAIL] Rebrickable Phase 2 failed." -ForegroundColor Red
Write-Host "[INFO] Python exit code: $ExitCode"
Write-Host "[INFO] Full log:"
Write-Host "       $LogFile"
exit $ExitCode
