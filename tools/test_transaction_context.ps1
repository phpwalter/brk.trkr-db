[CmdletBinding()]
param(
    [string]$DbHost = "localhost",
    [int]$DbPort = 5432,
    [string]$Database = "bricktrackr",
    [string]$PsqlPath = "",
    [string]$FixtureUser = "",

    [string]$ApiUser = "brktrkr_api_login",
    [string]$AdminUser = "brktrkr_admin_login",
    [string]$ImportUser = "brktrkr_import_login",
    [string]$MigratorUser = "brktrkr_migrator_login",
    [string]$OwnerUser = "brktrkr_owner_login",

    [string]$ApiPassword = "root",
    [string]$AdminPassword = "root",
    [string]$ImportPassword = "root",
    [string]$MigratorPassword = "root",
    [string]$OwnerPassword = "root"
)

$ErrorActionPreference = "Stop"

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " $Title"
    Write-Host "==============================================================================="
}

function Resolve-Psql {
    if (-not [string]::IsNullOrWhiteSpace($PsqlPath)) {
        if (-not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) {
            throw "psql not found: $PsqlPath"
        }
        return (Resolve-Path -LiteralPath $PsqlPath).Path
    }

    $candidates = @(
        "L:\etc\postgresql\bin\psql.exe",
        "psql.exe",
        "psql"
    )

    foreach ($candidate in $candidates) {
        if ([System.IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
        else {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd) {
                return $cmd.Source
            }
        }
    }

    throw "psql executable was not found."
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory=$true)][string]$Role,
        [Parameter(Mandatory=$true)][string]$Password,
        [string]$Sql = "",
        [string]$File = "",
        [string[]]$Variables = @(),
        [switch]$ExpectFailure,
        [switch]$Capture
    )

    $args = @(
        "-X",
        "-v", "ON_ERROR_STOP=1",
        "-h", $DbHost,
        "-p", "$DbPort",
        "-U", $Role,
        "-d", $Database
    )

    foreach ($v in $Variables) {
        $args += @("-v", $v)
    }

    if (-not [string]::IsNullOrWhiteSpace($File)) {
        $args += @("-f", $File)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Sql)) {
        $args += @("-c", $Sql)
    }
    else {
        throw "Invoke-Psql requires -Sql or -File."
    }

    $oldPassword = $env:PGPASSWORD
    $hadPassword = Test-Path Env:PGPASSWORD

    try {
        $env:PGPASSWORD = $Password
        if ($Capture) {
            $output = & $script:Psql @args 2>&1
        }
        else {
            & $script:Psql @args
            $output = $null
        }
        $code = $LASTEXITCODE
    }
    finally {
        if ($hadPassword) {
            $env:PGPASSWORD = $oldPassword
        }
        else {
            Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        }
    }

    if ($ExpectFailure) {
        if ($code -eq 0) {
            throw "Expected SQL failure for role $Role, but command succeeded."
        }
        return $output
    }

    if ($code -ne 0) {
        if ($Capture -and $output) {
            Write-Host ($output -join [Environment]::NewLine)
        }
        throw "psql failed for role $Role with exit code $code."
    }

    return $output
}

function Expect-Allowed {
    param(
        [string]$Role,
        [string]$Password,
        [string]$ActorClass
    )
    $request = [guid]::NewGuid().ToString()
    $sql = "SELECT app.set_request_context(NULL, '$request'::uuid, 'matrix-$ActorClass', '$ActorClass');"
    Invoke-Psql -Role $Role -Password $Password -Sql $sql | Out-Null
    Write-Host "[PASS] $Role -> $ActorClass allowed"
}

function Expect-Denied {
    param(
        [string]$Role,
        [string]$Password,
        [string]$ActorClass,
        [string]$UserId = ""
    )
    $request = [guid]::NewGuid().ToString()
    $userSql = if ([string]::IsNullOrWhiteSpace($UserId)) { "NULL" } else { "'$UserId'::uuid" }
    $sql = "SELECT app.set_request_context($userSql, '$request'::uuid, 'matrix-denied', '$ActorClass');"
    Invoke-Psql -Role $Role -Password $Password -Sql $sql -ExpectFailure | Out-Null
    Write-Host "[PASS] $Role -> $ActorClass denied"
}

try {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:Psql = Resolve-Psql
    $behaviorFile = Join-Path $repoRoot "tests\transaction_context.sql"

    if (-not (Test-Path -LiteralPath $behaviorFile -PathType Leaf)) {
        throw "Behavioral SQL suite not found: $behaviorFile"
    }

    Write-Section "BrickTrackr Transaction Context Verification"
    Write-Host "Database: ${DbHost}:${DbPort}/${Database}"
    Write-Host "psql:    $script:Psql"

    if ([string]::IsNullOrWhiteSpace($FixtureUser)) {
        Write-Host "[RUN ] Resolve an existing BrickTrackr identity using owner login"
        $sql = "SELECT user_id::text FROM identity.users ORDER BY created_at, user_id LIMIT 1;"
        $raw = Invoke-Psql `
            -Role $OwnerUser `
            -Password $OwnerPassword `
            -Sql $sql `
            -Capture

        $FixtureUser = (
            $raw |
            Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' } |
            Select-Object -First 1
        )

        if ([string]::IsNullOrWhiteSpace($FixtureUser)) {
            throw "No visible identity.users row found. Supply -FixtureUser <uuid>."
        }
    }

    Write-Host "[INFO] Fixture user: $FixtureUser"

    Write-Section "1. Persistent Backend / Pool-Leakage Simulation"
    Invoke-Psql `
        -Role $ApiUser `
        -Password $ApiPassword `
        -File $behaviorFile `
        -Variables @("user_id=$FixtureUser") | Out-Null
    Write-Host "[PASS] Transaction Context Behavioral Verification"
    Write-Host "[PASS] Same-backend COMMIT/ROLLBACK/SAVEPOINT/autocommit isolation"

    Write-Section "2. Actor-Class Capability Matrix"

    # Positive privileged actor cases.
    Expect-Allowed -Role $AdminUser -Password $AdminPassword -ActorClass "ADMIN"
    Expect-Allowed -Role $ImportUser -Password $ImportPassword -ActorClass "IMPORTER"
    Expect-Allowed -Role $MigratorUser -Password $MigratorPassword -ActorClass "SYSTEM"
    Expect-Allowed -Role $OwnerUser -Password $OwnerPassword -ActorClass "SYSTEM"

    # API cannot self-elevate.
    Expect-Denied -Role $ApiUser -Password $ApiPassword -ActorClass "ADMIN"
    Expect-Denied -Role $ApiUser -Password $ApiPassword -ActorClass "IMPORTER"
    Expect-Denied -Role $ApiUser -Password $ApiPassword -ActorClass "SYSTEM"

    # Privileged service roles cannot impersonate USER context.
    Expect-Denied -Role $AdminUser -Password $AdminPassword -ActorClass "USER" -UserId $FixtureUser
    Expect-Denied -Role $ImportUser -Password $ImportPassword -ActorClass "USER" -UserId $FixtureUser
    Expect-Denied -Role $MigratorUser -Password $MigratorPassword -ActorClass "USER" -UserId $FixtureUser

    # Migrator's transitive owner membership must not grant other actor classes.
    Expect-Denied -Role $MigratorUser -Password $MigratorPassword -ActorClass "ADMIN"
    Expect-Denied -Role $MigratorUser -Password $MigratorPassword -ActorClass "IMPORTER"

    Write-Host "[PASS] Actor-Class Capability Matrix"

    Write-Section "3. Forced-RLS Identity Lookup"
    $request = [guid]::NewGuid().ToString()
    $sql = "BEGIN; SELECT app.set_request_context('$FixtureUser'::uuid, '$request'::uuid, 'forced-rls-lookup', 'USER'); ROLLBACK;"
    Invoke-Psql -Role $ApiUser -Password $ApiPassword -Sql $sql | Out-Null
    Write-Host "[PASS] SECURITY DEFINER identity.users existence lookup succeeds under installed RLS contract"

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host "[PASS] BrickTrackr transaction-context verification passed."
    Write-Host "==============================================================================="
    exit 0
}
catch {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host "[FAIL] $($_.Exception.Message)"
    Write-Host "==============================================================================="
    exit 1
}
