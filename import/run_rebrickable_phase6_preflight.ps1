param(
    [string]$ImportRoot = $PSScriptRoot,
    [string]$DatabaseHost = "localhost",
    [int]$DatabasePort = 5432,
    [string]$DatabaseName = "bricktrackr",
    [string]$DatabaseUser = "root",
    [switch]$Refresh
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "rebrickable_phase6_preflight.py"

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

$env:BRICKTRACKR_ADMIN_DATABASE_URL = "postgresql://{0}:{1}@{2}:{3}/{4}" -f `
    $EncodedUser,$EncodedPassword,$DatabaseHost,$DatabasePort,$EncodedDatabase

$PlainPassword = $null
$EncodedPassword = $null
$SecurePassword = $null

$ArgsList = @(
    "-X","utf8",
    $PythonScript,
    "--import-root",$ImportRoot
)

if ($Refresh) {
    $ArgsList += "--refresh"
}

try {
    & python @ArgsList
    $ExitCode = $LASTEXITCODE
}
finally {
    $env:BRICKTRACKR_ADMIN_DATABASE_URL = $null
}

exit $ExitCode
