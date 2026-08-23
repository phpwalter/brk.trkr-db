Clear-Host

$ErrorActionPreference = "Stop"

# ===============================================================================
# BrickTrackr Rebrickable Phase 3 - Diagnostic UTF-8 Launcher
# Version: 3.0.3
#
# Prompts once for DB password.
# Verifies the exact importer file being executed.
# Forces UTF-8 at PowerShell, Python and PostgreSQL/libpq layers.
# ===============================================================================

$DatabaseUser = "bricktrackr_import"
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

$KeepDownloads = $true
$DownloadDirectoryName = "rebrickable-downloads"
$LogDirectoryName = "logs"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StageScript = Join-Path $ScriptDir "import_rebrickable_phase3.py"
$ReconcileScript = Join-Path $ScriptDir "reconcile_rebrickable_phase3.py"
$WorkDir = Join-Path $ScriptDir $DownloadDirectoryName
$LogDir = Join-Path $ScriptDir $LogDirectoryName

# ------------------------------------------------------------------------------
# Force UTF-8 for this launcher and child Python processes.
# ------------------------------------------------------------------------------

$PreviousOutputEncoding = [Console]::OutputEncoding
$PreviousInputEncoding = [Console]::InputEncoding
$PreviousPythonUtf8 = $env:PYTHONUTF8
$PreviousPythonIoEncoding = $env:PYTHONIOENCODING
$PreviousPgClientEncoding = $env:PGCLIENTENCODING
$PreviousPythonLegacyWindowsStdio = $env:PYTHONLEGACYWINDOWSSTDIO

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8:backslashreplace"
$env:PYTHONLEGACYWINDOWSSTDIO = "0"
$env:PGCLIENTENCODING = "UTF8"

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Phase 3 - Catalog Import"
Write-Host " Launcher version: 3.0.3"
Write-Host "==============================================================================="
Write-Host ""
Write-Host "[INFO] PostgreSQL connection"
Write-Host "       Server:   ${DatabaseHost}:${DatabasePort}"
Write-Host "       Database: $DatabaseName"
Write-Host "       User:     $DatabaseUser"
Write-Host ""
Write-Host "[INFO] Expected stage importer:"
Write-Host "       $StageScript"
Write-Host "[INFO] Expected reconciliation importer:"
Write-Host "       $ReconcileScript"
Write-Host ""

# ------------------------------------------------------------------------------
# Locate Python and prove its runtime encoding before any importer code executes.
# ------------------------------------------------------------------------------

$PythonCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $PythonCommand) {
    Write-Host "[FAIL] Python was not found on PATH." -ForegroundColor Red
    exit 3
}

$PythonExe = $PythonCommand.Source
Write-Host "[INFO] Python executable:"
Write-Host "       $PythonExe"

if (-not (Test-Path -LiteralPath $StageScript)) {
    Write-Host "[FAIL] Phase 3 staging importer not found:" -ForegroundColor Red
    Write-Host "       $StageScript"
    exit 4
}

if (-not (Test-Path -LiteralPath $ReconcileScript)) {
    Write-Host "[FAIL] Phase 3 reconciliation importer not found:" -ForegroundColor Red
    Write-Host "       $ReconcileScript"
    exit 5
}

Write-Host ""
Write-Host "[PRECHECK] Python UTF-8 runtime:"
& $PythonExe -X utf8 -c "import sys,locale; print('  utf8_mode=', sys.flags.utf8_mode); print('  stdout=', sys.stdout.encoding); print('  stderr=', sys.stderr.encoding); print('  preferred=', locale.getpreferredencoding(False))" | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Python UTF-8 precheck failed." -ForegroundColor Red
    exit $LASTEXITCODE
}

# ------------------------------------------------------------------------------
# Verify the actual importer file contains the expected fixed version.
# ------------------------------------------------------------------------------

$StageContent = Get-Content -LiteralPath $StageScript -Raw -Encoding UTF8

if ($StageContent -notmatch 'IMPORTER_VERSION\s*=\s*"3\.0\.3"') {
    Write-Host ""
    Write-Host "[FAIL] The active Phase 3 importer is NOT the UTF-8 fixed v3.0.3 file." -ForegroundColor Red
    Write-Host "[INFO] Active file:"
    Write-Host "       $StageScript"
    Write-Host ""
    Write-Host "Replace that exact file before retrying."
    exit 6
}

Write-Host "[PASS] Active Phase 3 importer is v3.0.3." -ForegroundColor Green

$StageHash = (Get-FileHash -LiteralPath $StageScript -Algorithm SHA256).Hash
Write-Host "[INFO] Stage importer SHA256:"
Write-Host "       $StageHash"
Write-Host ""

# ------------------------------------------------------------------------------
# Password prompt - exactly once.
# ------------------------------------------------------------------------------

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

try {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $LogFile = Join-Path $LogDir "rebrickable_phase3_$Timestamp.log"

    Write-Host ""
    Write-Host "-------------------------------------------------------------------------------"
    Write-Host " Phase 3A - Download, validate and stage"
    Write-Host "-------------------------------------------------------------------------------"
    Write-Host ""

    $StageArgs = @(
        "-X", "utf8",
        $StageScript,
        "--work-dir", $WorkDir
    )

    if ($KeepDownloads) {
        $StageArgs += "--keep-downloads"
    }

    & $PythonExe @StageArgs 2>&1 |
        Tee-Object -FilePath $LogFile |
        Out-Host

    $StageExit = $LASTEXITCODE

    if ($StageExit -ne 0) {
        Write-Host ""
        Write-Host "[FAIL] Phase 3 staging failed." -ForegroundColor Red
        Write-Host "[INFO] Python exit code: $StageExit"
        Write-Host "[INFO] Full log:"
        Write-Host "       $LogFile"
        exit $StageExit
    }

    Write-Host ""
    Write-Host "-------------------------------------------------------------------------------"
    Write-Host " Phase 3B - Reconcile canonical catalog"
    Write-Host "-------------------------------------------------------------------------------"
    Write-Host ""

    & $PythonExe -X utf8 $ReconcileScript 2>&1 |
        Tee-Object -FilePath $LogFile -Append |
        Out-Host

    $ReconcileExit = $LASTEXITCODE

    if ($ReconcileExit -ne 0) {
        Write-Host ""
        Write-Host "[FAIL] Phase 3 reconciliation failed." -ForegroundColor Red
        Write-Host "[INFO] Python exit code: $ReconcileExit"
        Write-Host "[INFO] Full log:"
        Write-Host "       $LogFile"
        exit $ReconcileExit
    }

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host "[PASS] Rebrickable Phase 3 completed successfully." -ForegroundColor Green
    Write-Host "[INFO] Full log:"
    Write-Host "       $LogFile"
    if ($KeepDownloads) {
        Write-Host "[INFO] Downloads retained in:"
        Write-Host "       $WorkDir"
    }
    Write-Host "==============================================================================="
    exit 0
}
finally {
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    $DatabaseUrl = $null

    $env:PYTHONUTF8 = $PreviousPythonUtf8
    $env:PYTHONIOENCODING = $PreviousPythonIoEncoding
    $env:PGCLIENTENCODING = $PreviousPgClientEncoding
    $env:PYTHONLEGACYWINDOWSSTDIO = $PreviousPythonLegacyWindowsStdio

    if ($null -ne $PreviousOutputEncoding) {
        [Console]::OutputEncoding = $PreviousOutputEncoding
    }
    if ($null -ne $PreviousInputEncoding) {
        [Console]::InputEncoding = $PreviousInputEncoding
    }
}
