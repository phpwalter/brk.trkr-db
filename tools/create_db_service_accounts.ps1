<#
.SYNOPSIS
    Creates the BrickTrackr PostgreSQL service login accounts and grants each
    login membership in its corresponding NOLOGIN privilege role.

.DESCRIPTION
    Connects to PostgreSQL as root/root and ensures these LOGIN roles exist:

      brktrkr_owner_login      -> brktrkr_owner
      brktrkr_admin_login      -> brktrkr_admin
      brktrkr_migrator_login   -> brktrkr_migrator
      brktrkr_api_login        -> brktrkr_api
      brktrkr_import_login     -> brktrkr_import
      brktrkr_reporting_login  -> brktrkr_reporting

    Temporary/default password for every LOGIN role:
      root

    Existing LOGIN roles are not recreated. Their password is reset to "root",
    LOGIN is enabled, and the required membership is granted.

    Existing privilege roles must already exist.

.USAGE
    .\create_db_service_accounts.ps1

.NOTES
    PostgreSQL connection:
      Host:     localhost
      Port:     5432
      Database: bricktrackr
      Admin:    root
      Password: root

    IMPORTANT:
      The password "root" is intentionally temporary and must be replaced before
      any non-local or production use.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DbHost = "localhost"
$DbPort = "5432"
$Database = "bricktrackr"
$AdminUser = "root"
$AdminPassword = "root"
$DefaultLoginPassword = "root"

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

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[FAIL] $Message"
    exit 1
}

function Find-Psql {
    $cmd = Get-Command psql.exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $cmd = Get-Command psql -ErrorAction SilentlyContinue
    }

    if (-not $cmd) {
        Fail "psql was not found in PATH."
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
        "-p", $DbPort,
        "-U", $AdminUser,
        "-d", $Database
    )

    if ($TuplesOnly) {
        $arguments += @("-t", "-A")
    }

    # Send SQL through stdin so passwords embedded in SQL are not exposed in
    # the psql command-line argument list.
    $output = $Sql | & $script:PsqlPath @arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }

    return $output
}

try {
    Write-Host "=============================================================================="
    Write-Host " BrickTrackr PostgreSQL Service Account Setup"
    Write-Host "=============================================================================="
    Write-Host "[INFO] PostgreSQL: ${DbHost}:${DbPort}/${Database}"
    Write-Host "[INFO] Installer role: $AdminUser"
    Write-Host "[INFO] Accounts: $($Accounts.Count)"
    Write-Host "[WARN] All LOGIN passwords will be set to the temporary value 'root'."
    Write-Host ""

    $script:PsqlPath = Find-Psql
    Write-Host "[INFO] psql: $script:PsqlPath"

    $hadPgPassword = Test-Path Env:PGPASSWORD
    $previousPgPassword = $env:PGPASSWORD
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
    )
    THEN '1'
    ELSE '0'
END;
"@

        $result = Invoke-Psql -Sql $sql -TuplesOnly
        $exists = (($result | ForEach-Object { $_.ToString().Trim() }) -contains "1")

        if (-not $exists) {
            Fail "Required privilege role '$privilegeRole' does not exist."
        }

        Write-Host "[PASS] $privilegeRole exists"
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

        Write-Host "------------------------------------------------------------------------------"
        Write-Host "[INFO] $loginRole"
        Write-Host "[INFO] Purpose: $purpose"
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
            Write-Host "[RUN ] Enable LOGIN and reset temporary password"

            $alterSql = @"
ALTER ROLE $loginIdent
    WITH LOGIN
    PASSWORD $passwordLiteral
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION;
"@

            $null = Invoke-Psql -Sql $alterSql
            Write-Host "[PASS] LOGIN role updated"
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
    NOREPLICATION;
"@

            $null = Invoke-Psql -Sql $createSql
            Write-Host "[PASS] LOGIN role created"
        }

        Write-Host "[RUN ] Grant $privilegeRole membership"

        $grantSql = @"
GRANT $privilegeIdent TO $loginIdent;
"@

        $null = Invoke-Psql -Sql $grantSql
        Write-Host "[PASS] Membership granted"

        Write-Host "[RUN ] Verify LOGIN and membership"

        $membershipSql = @"
SELECT
    r.rolname,
    r.rolcanlogin,
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

        Write-Host "[PASS] $loginRole ready"
        Write-Host ""
    }

    Write-Host "=============================================================================="
    Write-Host "[PASS] All BrickTrackr PostgreSQL service login accounts are ready."
    Write-Host "=============================================================================="
    Write-Host ""
    Write-Host "[NEXT] Test admin procedures with:"
    Write-Host "       psql -h localhost -p 5432 -U brktrkr_admin_login -d bricktrackr"
    Write-Host ""
    Write-Host "[WARN] Replace the temporary password 'root' before non-local use."
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
