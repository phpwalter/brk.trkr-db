param(
    [string]$DatabaseHost = "localhost",
    [int]$DatabasePort = 5432,
    [string]$DatabaseName = "bricktrackr",
    [string]$DatabaseUser = "root"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlFile = Join-Path $ScriptDir "apply_phase6b_set_import_context_owner_grant.sql"

$SecurePassword = Read-Host "Enter PostgreSQL password for '$DatabaseUser'" -AsSecureString
$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)

try {
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
}

try {
    & psql `
        -X `
        -v ON_ERROR_STOP=1 `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $DatabaseName `
        -f $SqlFile

    exit $LASTEXITCODE
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
