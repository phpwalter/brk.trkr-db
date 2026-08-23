param(
    [string]$DatabaseHost = "localhost",
    [int]$DatabasePort = 5432,
    [string]$DatabaseName = "bricktrackr",
    [string]$DatabaseUser = "bricktrackr_import"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "import_rebrickable_phase6a_relationships.py"
$Archive = Join-Path $ScriptDir "rebrickable-downloads\part_relationships.csv.gz"
$LogDir = Join-Path $ScriptDir "logs"

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogDir "rebrickable_phase6a_$Timestamp.log"

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
$EncodedDatabase = [System.Uri]::EscapeDataString($DatabaseName)

$env:BRICKTRACKR_IMPORT_DATABASE_URL = "postgresql://{0}:{1}@{2}:{3}/{4}" -f `
    $EncodedUser,$EncodedPassword,$DatabaseHost,$DatabasePort,$EncodedDatabase

$PlainPassword = $null
$EncodedPassword = $null
$SecurePassword = $null

try {
    & python -X utf8 $PythonScript --archive $Archive 2>&1 |
        Tee-Object -FilePath $LogFile
    $ExitCode = $LASTEXITCODE
}
finally {
    Remove-Item Env:BRICKTRACKR_IMPORT_DATABASE_URL -ErrorAction SilentlyContinue
}

exit $ExitCode
