param(
    [string]$DatabaseHost = "localhost",
    [int]$DatabasePort = 5432,
    [string]$DatabaseName = "bricktrackr",
    [string]$DatabaseUser = "root"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SqlFile = Join-Path $ScriptDir "inspect_phase6_relationship_contract.sql"
$ReportFile = Join-Path $ScriptDir "phase6_relationship_contract.txt"

$env:PGPASSWORD = Read-Host "Enter PostgreSQL password for '$DatabaseUser'" -AsSecureString | ForEach-Object {
    $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
    }
}

try {
    & psql `
        -X `
        -v ON_ERROR_STOP=1 `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $DatabaseName `
        -f $SqlFile 2>&1 |
        Tee-Object -FilePath $ReportFile

    if ($LASTEXITCODE -ne 0) {
        throw "psql contract inspection failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "[PASS] Report written to $ReportFile"
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
