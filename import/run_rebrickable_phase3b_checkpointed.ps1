param(
    [switch]$Restart,
    [int]$BatchSize = 5000,
    [string]$SourceRunId = "01a0283d-4c30-744e-b3f7-4e96561db0af"
)

Clear-Host
$ErrorActionPreference = "Stop"

$DatabaseUser = "bricktrackr_import"
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "reconcile_rebrickable_phase3_checkpointed.py"
$LogDir = Join-Path $ScriptDir "logs"

$PreviousPythonUtf8 = $env:PYTHONUTF8
$PreviousPythonIoEncoding = $env:PYTHONIOENCODING
$PreviousPgClientEncoding = $env:PGCLIENTENCODING

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8:backslashreplace"
$env:PGCLIENTENCODING = "UTF8"

$Mode = if ($Restart) { "RESTART" } else { "RESUME" }

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Phase 3B - Checkpointed Reconcile v3.2.2"
Write-Host "==============================================================================="
Write-Host ""
Write-Host "[INFO] Mode:       $Mode"
Write-Host "[INFO] Source run: $SourceRunId"
Write-Host "[INFO] Batch size: $BatchSize"
Write-Host "[INFO] Database:   $DatabaseName"
Write-Host "[INFO] User:       $DatabaseUser"
Write-Host ""

if ($Restart) {
    Write-Host "[WARNING] Restart resets Phase 3B checkpoint progress." -ForegroundColor Yellow
    Write-Host "[WARNING] It does NOT delete canonical catalog UUIDs." -ForegroundColor Yellow
    Write-Host ""
}

$PythonExe = (Get-Command python -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $PythonScript)) {
    Write-Host "[FAIL] Checkpointed reconciliation client not found:" -ForegroundColor Red
    Write-Host "       $PythonScript"
    exit 4
}

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
    $EncodedUser,
    $EncodedPassword,
    $DatabaseHost,
    $DatabasePort,
    $EncodedDatabase

$PlainPassword = $null
$EncodedPassword = $null
$SecurePassword = $null
$env:BRICKTRACKR_IMPORT_DATABASE_URL = $DatabaseUrl

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogDir "rebrickable_phase3b_checkpointed_$Timestamp.log"

$ArgsList = @(
    "-X", "utf8",
    $PythonScript,
    "--source-run-id", $SourceRunId,
    "--batch-size", $BatchSize
)

if ($Restart) {
    $ArgsList += "--restart"
}

try {
    & $PythonExe @ArgsList 2>&1 |
        Tee-Object -FilePath $LogFile |
        Out-Host

    $ExitCode = $LASTEXITCODE
}
finally {
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    $DatabaseUrl = $null

    $env:PYTHONUTF8 = $PreviousPythonUtf8
    $env:PYTHONIOENCODING = $PreviousPythonIoEncoding
    $env:PGCLIENTENCODING = $PreviousPgClientEncoding
}

Write-Host ""
if ($ExitCode -eq 0) {
    Write-Host "[PASS] Phase 3B completed successfully." -ForegroundColor Green
}
elseif ($ExitCode -eq 130) {
    Write-Host "[STOP] Phase 3B interrupted. Resume is available." -ForegroundColor Yellow
}
else {
    Write-Host "[FAIL] Phase 3B failed. Resume is available after correction." -ForegroundColor Red
}

Write-Host "[INFO] Full log:"
Write-Host "       $LogFile"

exit $ExitCode
