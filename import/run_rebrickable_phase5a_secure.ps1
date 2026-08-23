param(
    [int]$BatchSize = 50000
)

Clear-Host
$ErrorActionPreference = "Stop"

$DatabaseUser = "bricktrackr_import"
$DatabaseHost = "localhost"
$DatabasePort = 5432
$DatabaseName = "bricktrackr"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "import_rebrickable_phase5a_inventory.py"
$DownloadsDir = Join-Path $ScriptDir "rebrickable-downloads"
$LogDir = Join-Path $ScriptDir "logs"

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8:backslashreplace"
$env:PGCLIENTENCODING = "UTF8"

Write-Host "==============================================================================="
Write-Host " BrickTrackr Rebrickable Phase 5A - Inventory Composition Staging v5.0.1"
Write-Host "==============================================================================="
Write-Host "[INFO] Downloads:  $DownloadsDir"
Write-Host "[INFO] COPY batch: $BatchSize"
Write-Host ""

$Required = @(
    "inventories.csv.gz",
    "inventory_parts.csv.gz",
    "inventory_sets.csv.gz",
    "inventory_minifigs.csv.gz"
)

foreach ($Name in $Required) {
    $Path = Join-Path $DownloadsDir $Name
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "[FAIL] Missing: $Path" -ForegroundColor Red
        exit 2
    }
}

$PythonExe = (Get-Command python -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $PythonScript)) {
    Write-Host "[FAIL] Python importer missing: $PythonScript" -ForegroundColor Red
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
$LogFile = Join-Path $LogDir "rebrickable_phase5a_$Timestamp.log"

try {
    & $PythonExe -X utf8 $PythonScript `
        --downloads-dir $DownloadsDir `
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
    Write-Host "[PASS] Phase 5A completed successfully." -ForegroundColor Green
}
else {
    Write-Host "[FAIL] Phase 5A failed." -ForegroundColor Red
}

Write-Host "[INFO] Log:"
Write-Host "       $LogFile"

exit $ExitCode
