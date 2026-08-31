<#
.SYNOPSIS
    Creates or reconciles BrickTrackr PostgreSQL service login accounts.

.DESCRIPTION
    File:    tools\create_db_service_accounts.ps1
    Version: 1.1.0

    Ensures these LOGIN roles exist and have exactly the required membership:

      brktrkr_owner_login      -> brktrkr_owner
      brktrkr_admin_login      -> brktrkr_admin
      brktrkr_migrator_login   -> brktrkr_migrator
      brktrkr_api_login        -> brktrkr_api
      brktrkr_import_login     -> brktrkr_import
      brktrkr_reporting_login  -> brktrkr_reporting

    Existing LOGIN roles are reconciled in place. Their temporary local
    password is reset to "root".

    Membership grants are idempotent:
      * If membership already exists, GRANT is not executed.
      * If membership is absent, GRANT is executed.
      * PostgreSQL NOTICE output is not used as control flow.

    psql exit code is authoritative. PostgreSQL NOTICE/WARNING output is
    captured without being promoted to a PowerShell terminating error.

.NOTES
    Temporary local-development password: root
    Replace it before any non-local or production use.
#>

[CmdletBinding()]
param(
    [string]$DbHost = "localhost",
    [int]$DbPort = 5432,
    [string]$Database = "bricktrackr",
    [string]$AdminUser = "root",
    [string]$AdminPassword = "root",
    [string]$DefaultLoginPassword = "root"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$FileVersion = "1.1.0"

$Accounts = @(
    @{
        LoginRole     = "brktrkr_owner_login"
        PrivilegeRole = "brktrkr_owner"
        Purpose       = "Schema owner / controlled maintenance"
    },
    @{
        LoginRole     = "brktrkr_admin_login"
        PrivilegeRole = "brktrkr_admin"
        Purpose       = "Administrative stored procedures"
    },
    @{
        LoginRole     = "brktrkr_migrator_login"
        PrivilegeRole = "brktrkr_migrator"
        Purpose       = "Schema installation and migrations"
    },
    @{
        LoginRole     = "brktrkr_api_login"
        PrivilegeRole = "brktrkr_api"
        Purpose       = "Application API runtime"
    },
    @{
        LoginRole     = "brktrkr_import_login"
        PrivilegeRole = "brktrkr_import"
        Purpose       = "Catalog/import workloads"
    },
    @{
        LoginRole     = "brktrkr_reporting_login"
        PrivilegeRole = "brktrkr_reporting"
        Purpose       = "Read-only reporting"
    }
)

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[FAIL] $Message"
}

function Find-Psql {
    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue

    if (-not $cmd) {
        $cmd = Get-Command psql -ErrorAction SilentlyContinue
    }

    if (-not $cmd) {
        throw "psql was not found in PATH."
    }

    return $cmd.Source
}

function Escape-SqlLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    return "'" + $Value.Replace("'", "''") + "'"
}

function Quote-SqlIdentifier {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [switch]$TuplesOnly
    )

    $arguments = @(
        "-X",
        "-v", "ON_ERROR_STOP=1",
        "-h", $DbHost,
        "-p", "$DbPort",
        "-U", $AdminUser,
        "-d", $Database
    )

    if ($TuplesOnly) {
        $arguments += @("-t", "-A")
    }

    # Native stderr can contain PostgreSQL NOTICE/WARNING messages. Those are
    # not failures. Temporarily relax PowerShell's native-command handling and
    # use psql's exit code as the authoritative result.
    $previousErrorActionPreference = $ErrorActionPreference
    $hadNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference

    if ($hadNativePreference) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    }

    try {
        $ErrorActionPreference = "Continue"

        if ($hadNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $false
        }

        $output = $Sql | & $script:PsqlPath @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if ($hadNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($exitCode -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }

    return $output
}

function Test-RoleMembership {
    param(
        [Parameter(Mandatory = $true)][string]$LoginRole,
        [Parameter(Mandatory = $true)][string]$PrivilegeRole
    )

    $loginLiteral = Escape-SqlLiteral $LoginRole
    $privilegeLiteral = Escape-SqlLiteral $PrivilegeRole

    $sql = @"
SELECT CASE
    WHEN pg_catalog.pg_has_role(
        $loginLiteral,
        $privilegeLiteral,
        'MEMBER'
    )
    THEN '1'
    ELSE '0'
END;
"@

    $result = Invoke-Psql -Sql $sql -TuplesOnly

    return (($result | ForEach-Object { $_.ToString().Trim() }) -contains "1")
}

$hadPgPassword = Test-Path Env:PGPASSWORD
$previousPgPassword = $env:PGPASSWORD

try {
    Write-Host "==============================================================================="
    Write-Host " BrickTrackr PostgreSQL Service Account Setup"
    Write-Host "==============================================================================="
    Write-Host "[INFO] File version:   $FileVersion"
    Write-Host "[INFO] PostgreSQL:     ${DbHost}:${DbPort}/${Database}"
    Write-Host "[INFO] Installer role: $AdminUser"
    Write-Host "[INFO] Accounts:       $($Accounts.Count)"
    Write-Host "[WARN] LOGIN passwords will be set to the temporary value 'root'."
    Write-Host ""

    $script:PsqlPath = Find-Psql
    Write-Host "[INFO] psql: $script:PsqlPath"

    $env:PGPASSWORD = $AdminPassword

    Write-Host "[RUN ] Verify PostgreSQL connection"
    $null = Invoke-Psql -Sql "SELECT 1;"
    Write-Host "[PASS] PostgreSQL connection successful"
    Write-Host ""

    Write-Host "[RUN ] Verify required NOLOGIN privilege roles"

    foreach ($account in $Accounts) {
        $privilegeRole = $account.PrivilegeRole
        $privilegeLiteral = Escape-SqlLiteral $privilegeRole

        $sql = @"
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = $privilegeLiteral
          AND NOT rolcanlogin
          AND NOT rolsuper
          AND NOT rolbypassrls
    )
    THEN '1'
    ELSE '0'
END;
"@

        $result = Invoke-Psql -Sql $sql -TuplesOnly
        $valid = (($result | ForEach-Object { $_.ToString().Trim() }) -contains "1")

        if (-not $valid) {
            throw "Required NOLOGIN/NOSUPERUSER/NOBYPASSRLS privilege role '$privilegeRole' is missing or invalid."
        }

        Write-Host "[PASS] $privilegeRole valid"
    }

    Write-Host ""

    foreach ($account in $Accounts) {
        $loginRole = $account.LoginRole
        $privilegeRole = $account.PrivilegeRole
        $purpose = $account.Purpose

        $loginLiteral = Escape-SqlLiteral $loginRole
        $loginIdent = Quote-SqlIdentifier $loginRole
        $privilegeIdent = Quote-SqlIdentifier $privilegeRole
        $passwordLiteral = Escape-SqlLiteral $DefaultLoginPassword

        Write-Host "-------------------------------------------------------------------------------"
        Write-Host "[INFO] $loginRole"
        Write-Host "[INFO] Purpose:    $purpose"
        Write-Host "[INFO] Membership: $privilegeRole"

        $existsSql = @"
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = $loginLiteral
    )
    THEN '1'
    ELSE '0'
END;
"@

        $result = Invoke-Psql -Sql $existsSql -TuplesOnly
        $exists = (($result | ForEach-Object { $_.ToString().Trim() }) -contains "1")

        if ($exists) {
            Write-Host "[FOUND] LOGIN role already exists"
            Write-Host "[RUN ] Reconcile LOGIN attributes and temporary password"

            $alterSql = @"
ALTER ROLE $loginIdent
    WITH LOGIN
    PASSWORD $passwordLiteral
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;
"@

            $null = Invoke-Psql -Sql $alterSql
            Write-Host "[PASS] LOGIN role reconciled"
        }
        else {
            Write-Host "[CREATE] Creating LOGIN role"

            $createSql = @"
CREATE ROLE $loginIdent
    WITH LOGIN
    PASSWORD $passwordLiteral
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;
"@

            $null = Invoke-Psql -Sql $createSql
            Write-Host "[PASS] LOGIN role created"
        }

        Write-Host "[RUN ] Reconcile $privilegeRole membership"

        $hasMembership = Test-RoleMembership `
            -LoginRole $loginRole `
            -PrivilegeRole $privilegeRole

        if ($hasMembership) {
            Write-Host "[PASS] Membership already present; GRANT skipped"
        }
        else {
            $grantSql = @"
GRANT $privilegeIdent TO $loginIdent;
"@

            $null = Invoke-Psql -Sql $grantSql
            Write-Host "[PASS] Membership granted"
        }

        Write-Host "[RUN ] Verify LOGIN role and required membership"

        $membershipSql = @"
SELECT
    r.rolname,
    r.rolcanlogin,
    r.rolsuper,
    r.rolcreatedb,
    r.rolcreaterole,
    r.rolreplication,
    r.rolbypassrls,
    pg_catalog.pg_has_role(
        $loginLiteral,
        $(Escape-SqlLiteral $privilegeRole),
        'MEMBER'
    ) AS has_required_membership
FROM pg_catalog.pg_roles AS r
WHERE r.rolname = $loginLiteral;
"@

        $verification = Invoke-Psql -Sql $membershipSql -TuplesOnly
        $verification | ForEach-Object { Write-Host "[VERIFY] $_" }

        $finalMembership = Test-RoleMembership `
            -LoginRole $loginRole `
            -PrivilegeRole $privilegeRole

        if (-not $finalMembership) {
            throw "Required membership verification failed: $loginRole -> $privilegeRole"
        }

        $secureLoginSql = @"
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = $loginLiteral
          AND rolcanlogin
          AND NOT rolsuper
          AND NOT rolcreatedb
          AND NOT rolcreaterole
          AND NOT rolreplication
          AND NOT rolbypassrls
    )
    THEN '1'
    ELSE '0'
END;
"@

        $secureResult = Invoke-Psql -Sql $secureLoginSql -TuplesOnly
        $secureLogin = (($secureResult | ForEach-Object { $_.ToString().Trim() }) -contains "1")

        if (-not $secureLogin) {
            throw "LOGIN role security attributes are invalid: $loginRole"
        }

        Write-Host "[PASS] $loginRole ready"
        Write-Host ""
    }

    Write-Host "==============================================================================="
    Write-Host "[PASS] All BrickTrackr PostgreSQL service login accounts are ready."
    Write-Host "==============================================================================="
    Write-Host "[INFO] File version: $FileVersion"
    Write-Host "[WARN] Replace the temporary password 'root' before non-local use."

    exit 0
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
finally {
    if ($hadPgPassword) {
        $env:PGPASSWORD = $previousPgPassword
    }
    else {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}
