param(
    [int]$BatchSize = 5000
)

Clear-Host
$ErrorActionPreference = "Stop"

$DatabaseUser = "bricktrackr_import"
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "import_rebrickable_phase4a_elements.py"
$ElementsFile = Join-Path $ScriptDir "rebrickable-downloads\elements.csv.gz"
$LogDir = Join-Path $ScriptDir "logs"

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8:backslashreplace"
$env:PGCLIENTENCODING = "UTF8"

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Phase 4A - Elements Staging v4.0.2"
Write-Host "==============================================================================="
Write-Host ""
Write-Host "[INFO] Elements:   $ElementsFile"
Write-Host "[INFO] Batch size: $BatchSize"
Write-Host ""

if (-not (Test-Path -LiteralPath $ElementsFile)) {
    Write-Host "[FAIL] elements.csv.gz is missing." -ForegroundColor Red
    Write-Host "       Run Phase 4 preflight first."
    exit 2
}

$PythonExe = (Get-Command python -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $PythonScript)) {
    Write-Host "[FAIL] Python importer missing:" -ForegroundColor Red
    Write-Host "       $PythonScript"
    exit 3
}

$SecurePassword = Read-Host "Enter PostgreSQL password for '$DatabaseUser'" -AsSecureString
if ($SecurePassword.Length -eq 0) {
    Write-Host "[FAIL] Password was not supplied." -ForegroundColor Red
    exit 4
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
$LogFile = Join-Path $LogDir "rebrickable_phase4a_$Timestamp.log"

try {
    & $PythonExe -X utf8 $PythonScript `
        --file $ElementsFile `
        --batch-size $BatchSize 2>&1 |
        Tee-Object -FilePath $LogFile |
        Out-Host

    $ExitCode = $LASTEXITCODE
}
finally {
    $env:BRICKTRACKR_IMPORT_DATABASE_URL = $null
    $DatabaseUrl = $null
}

Write-Host ""
if ($ExitCode -eq 0) {
    Write-Host "[PASS] Phase 4A completed successfully." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] Phase 4A failed." -ForegroundColor Red
}

Write-Host "[INFO] Log:"
Write-Host "       $LogFile"

exit $ExitCode
