<#
.SYNOPSIS
    Creates or updates a PostgreSQL login role.

.DESCRIPTION
    Connects to PostgreSQL as root/root on localhost:5432 using the postgres database.

    - If the target role does not exist, it is created with LOGIN and the supplied password.
    - If the target role already exists, LOGIN is enabled and the password is reset.
    - The supplied target password is never printed.

.USAGE
    .\create_db_user.ps1 -Username "brktrkr_api" -Password "StrongPasswordHere"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Password
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DbHost = "localhost"
$DbPort = "5432"
$Database = "postgres"

$AdminUser = "root"
$AdminPassword = "root"

function Fail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[FAIL] $Message" -ForegroundColor Red
    exit 1
}

function Find-Psql {

    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue

    if (-not $cmd) {
        $cmd = Get-Command psql -ErrorAction SilentlyContinue
    }

    if (-not $cmd) {
        Fail "psql was not found in PATH. Install PostgreSQL client tools or add the PostgreSQL bin directory to PATH."
    }

    return $cmd.Source
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [switch]$TuplesOnly
    )

    $psqlArgs = @(
        "-X",
        "-v", "ON_ERROR_STOP=1",
        "-h", $DbHost,
        "-p", $DbPort,
        "-U", $AdminUser,
        "-d", $Database,
        "-v", "target_user=$Username",
        "-v", "target_password=$Password"
    )

    if ($TuplesOnly) {
        $psqlArgs += @(
            "-t",
            "-A"
        )
    }

    #
    # IMPORTANT:
    #
    # Send SQL through stdin instead of -c.
    #
    # This allows psql to process:
    #
    #   :'target_user'
    #   :'target_password'
    #   \gexec
    #
    # before sending SQL to PostgreSQL.
    #
    $output = $Sql | & $script:PsqlPath @psqlArgs 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }

    return $output
}

try {

    Write-Host "=============================================================================="
    Write-Host " BrickTrackr PostgreSQL User Setup"
    Write-Host "=============================================================================="

    Write-Host "[INFO] PostgreSQL: ${DbHost}:${DbPort}/${Database}"
    Write-Host "[INFO] Admin role: $AdminUser"
    Write-Host "[INFO] Target role: $Username"

    $script:PsqlPath = Find-Psql

    Write-Host "[INFO] psql: $script:PsqlPath"

    #
    # Preserve any existing PGPASSWORD.
    #

    $hadPgPassword = Test-Path Env:PGPASSWORD

    if ($hadPgPassword) {
        $previousPgPassword = $env:PGPASSWORD
    }
    else {
        $previousPgPassword = $null
    }

    $env:PGPASSWORD = $AdminPassword

    #
    # Verify PostgreSQL.
    #

    Write-Host "[RUN ] Verify PostgreSQL connection"

    $null = Invoke-Psql -Sql @"
SELECT 1;
"@

    Write-Host "[PASS] PostgreSQL connection successful" -ForegroundColor Green

    #
    # Check target role.
    #

    Write-Host "[RUN ] Check whether role exists"

    $existsOutput = Invoke-Psql `
        -Sql @"
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = :'target_user'
    )
    THEN '1'
    ELSE '0'
END;
"@ `
        -TuplesOnly

    $exists = (
        ($existsOutput | ForEach-Object {
            $_.ToString().Trim()
        }) -contains "1"
    )

    #
    # Update existing role.
    #

    if ($exists) {

        Write-Host "[FOUND] Role '$Username' exists"
        Write-Host "[RUN ] Enable LOGIN and reset password"

        $sql = @"
SELECT format(
    'ALTER ROLE %I WITH LOGIN PASSWORD %L',
    :'target_user',
    :'target_password'
)
\gexec
"@

        $null = Invoke-Psql -Sql $sql

        Write-Host "[PASS] Password reset and LOGIN enabled" -ForegroundColor Green
    }

    #
    # Create new role.
    #

    else {

        Write-Host "[CREATE] Role '$Username' does not exist"
        Write-Host "[RUN ] Create role with LOGIN"

        $sql = @"
SELECT format(
    'CREATE ROLE %I WITH LOGIN PASSWORD %L',
    :'target_user',
    :'target_password'
)
\gexec
"@

        $null = Invoke-Psql -Sql $sql

        Write-Host "[PASS] Role created with LOGIN" -ForegroundColor Green
    }

    #
    # Verify final state.
    #

    Write-Host "[RUN ] Verify final role state"

    $verifySql = @"
SELECT
    rolname,
    rolcanlogin
FROM pg_catalog.pg_roles
WHERE rolname = :'target_user';
"@

    $verifyOutput = Invoke-Psql -Sql $verifySql

    $verifyOutput | ForEach-Object {
        Write-Host $_
    }

    #
    # Explicit final verification.
    #

    $finalCheck = Invoke-Psql `
        -Sql @"
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = :'target_user'
          AND rolcanlogin = true
    )
    THEN '1'
    ELSE '0'
END;
"@ `
        -TuplesOnly

    $valid = (
        ($finalCheck | ForEach-Object {
            $_.ToString().Trim()
        }) -contains "1"
    )

    if (-not $valid) {
        Fail "Role '$Username' was not successfully configured as a LOGIN role."
    }

    Write-Host ""
    Write-Host "[PASS] PostgreSQL user setup completed successfully" -ForegroundColor Green
}
catch {

    Fail $_.Exception.Message
}
finally {

    if ($hadPgPassword) {
        $env:PGPASSWORD = $previousPgPassword
    }
    else {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}