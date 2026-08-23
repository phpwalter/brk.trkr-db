param(
    [switch]$Restart,
    [int]$BatchSize = 5000,
    [string]$SourceRunId = ""
)

Clear-Host
$ErrorActionPreference = "Stop"

$DatabaseUser = "bricktrackr_import"
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "reconcile_rebrickable_phase5b_checkpointed.py"
$LogDir = Join-Path $ScriptDir "logs"

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8:backslashreplace"
$env:PGCLIENTENCODING = "UTF8"

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Phase 5B - Checkpointed Reconcile v5.1.2"
Write-Host "==============================================================================="
Write-Host "[INFO] Mode:       $(if ($Restart) {'RESTART'} else {'RESUME'})"
Write-Host "[INFO] Batch size: $BatchSize"
if ($SourceRunId) {
    Write-Host "[INFO] Source run: $SourceRunId"
}
else {
    Write-Host "[INFO] Source run: latest validated Phase 5A run"
}
Write-Host ""

$PythonExe = (Get-Command python -ErrorAction Stop).Source

$SecurePassword = Read-Host "Enter PostgreSQL password for '$DatabaseUser'" -AsSecureString
$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
}

$EncodedUser = [System.Uri]::EscapeDataString($DatabaseUser)
$EncodedPassword = [System.Uri]::EscapeDataString($PlainPassword)
$DatabaseUrl = "postgresql://{0}:{1}@{2}:{3}/{4}" -f `
    $EncodedUser,$EncodedPassword,$DatabaseHost,$DatabasePort,$DatabaseName

$PlainPassword = $null
$EncodedPassword = $null
$SecurePassword = $null
$env:BRICKTRACKR_IMPORT_DATABASE_URL = $DatabaseUrl

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogDir "rebrickable_phase5b_$Timestamp.log"

$ArgsList = @(
    "-X","utf8",
    $PythonScript,
    "--batch-size",$BatchSize
)

if ($Restart) {
    $ArgsList += "--restart"
}
if ($SourceRunId) {
    $ArgsList += @("--source-run-id",$SourceRunId)
}

try {
    & $PythonExe @ArgsList 2>&1 |
        Tee-Object -FilePath $LogFile |
        Out-Host
    $ExitCode = $LASTEXITCODE
}
finally {
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
}

Write-Host ""
if ($ExitCode -eq 0) {
    Write-Host "[PASS] Phase 5B completed successfully." -ForegroundColor Green
}
elseif ($ExitCode -eq 130) {
    Write-Host "[STOP] Phase 5B interrupted; resume is available." -ForegroundColor Yellow
}
else {
    Write-Host "[FAIL] Phase 5B failed; resume is available after correction." -ForegroundColor Red
}
Write-Host "[INFO] Log: $LogFile"
exit $ExitCode
