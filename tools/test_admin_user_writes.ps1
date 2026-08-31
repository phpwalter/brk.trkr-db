[CmdletBinding()]
param(
    [string]$HostName = "localhost",
    [int]$Port = 5432,
    [string]$Database = "bricktrackr",
    [string]$Username = "brktrkr_admin_login",
    [string]$Password = "root",
    [string]$SqlFile = ""
)

$ErrorActionPreference = "Stop"

function Write-Run {
    param([string]$Message)
    Write-Host "[RUN ] $Message"
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message"
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message"
}

function Find-Psql {
    $command = Get-Command "psql.exe" -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command "psql" -ErrorAction SilentlyContinue
    }

    if ($command) {
        return $command.Source
    }

    $candidates = @(
        "L:\etc\postgresql\bin\psql.exe",
        "C:\Program Files\PostgreSQL\18\bin\psql.exe",
        "C:\Program Files\PostgreSQL\17\bin\psql.exe",
        "C:\Program Files\PostgreSQL\16\bin\psql.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "psql.exe was not found in PATH or known PostgreSQL installation locations."
}

try {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptRoot

    if ([string]::IsNullOrWhiteSpace($SqlFile)) {
        $SqlFile = Join-Path $repoRoot "tests\admin_user_writes.sql"
    }
    elseif (-not [System.IO.Path]::IsPathRooted($SqlFile)) {
        $SqlFile = Join-Path $repoRoot $SqlFile
    }

    if (-not (Test-Path -LiteralPath $SqlFile -PathType Leaf)) {
        throw "SQL test file does not exist: $SqlFile"
    }

    $psqlPath = Find-Psql

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Admin User Write / Lifecycle Test"
    Write-Host "==============================================================================="
    Write-Host "Database: $HostName`:$Port/$Database"
    Write-Host "User:     $Username"
    Write-Host "psql:     $psqlPath"
    Write-Host "SQL:      $SqlFile"
    Write-Host ""

    $env:PGPASSWORD = $Password

    $baseArgs = @(
        "-X",
        "-h", $HostName,
        "-p", $Port.ToString(),
        "-U", $Username,
        "-d", $Database,
        "-v", "ON_ERROR_STOP=1"
    )

    $signatureSql = @"
WITH required(label, resolved_oid) AS (
    VALUES
        (
            'admin.create_user(text,text,text,jsonb)',
            pg_catalog.to_regprocedure('admin.create_user(text,text,text,jsonb)')
        ),
        (
            'admin.update_user(uuid,jsonb,jsonb)',
            pg_catalog.to_regprocedure('admin.update_user(uuid,jsonb,jsonb)')
        ),
        (
            'admin.set_user_status(uuid,identity.account_status,jsonb)',
            pg_catalog.to_regprocedure(
                'admin.set_user_status(uuid,identity.account_status,jsonb)'
            )
        ),
        (
            'admin.set_user_management_type(uuid,identity.account_management_type,jsonb)',
            pg_catalog.to_regprocedure(
                'admin.set_user_management_type(uuid,identity.account_management_type,jsonb)'
            )
        ),
        (
            'admin.delete_user(uuid,jsonb)',
            pg_catalog.to_regprocedure('admin.delete_user(uuid,jsonb)')
        ),
        (
            'admin.restore_user(uuid,jsonb)',
            pg_catalog.to_regprocedure('admin.restore_user(uuid,jsonb)')
        ),
        (
            'admin.list_audit_events(text,uuid,text,text,text,uuid,timestamp with time zone,timestamp with time zone,integer,integer,jsonb)',
            pg_catalog.to_regprocedure(
                'admin.list_audit_events(text,uuid,text,text,text,uuid,timestamp with time zone,timestamp with time zone,integer,integer,jsonb)'
            )
        )
)
SELECT label
FROM required
WHERE resolved_oid IS NULL
ORDER BY label;
"@

    Write-Run "Validate live admin mutation/audit procedure signatures"

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $missingSignatures = & $psqlPath @baseArgs "-At" "-c", $signatureSql
        $signatureExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($signatureExitCode -ne 0) {
        throw "Procedure signature validation query failed with psql exit code $signatureExitCode."
    }

    $missing = @(
        $missingSignatures |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($missing.Count -gt 0) {
        Write-Fail "Live procedure contract does not match the write test harness."
        foreach ($signature in $missing) {
            Write-Host "       Missing: $signature"
        }
        exit 2
    }

    Write-Pass "Validate live admin mutation/audit procedure signatures"

    Write-Run "Execute admin user write/lifecycle regression tests"

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $psqlPath @baseArgs "-f", $SqlFile
        $testExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($testExitCode -ne 0) {
        throw "Admin user write/lifecycle regression tests failed with psql exit code $testExitCode."
    }

    Write-Pass "Execute admin user write/lifecycle regression tests"

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Pass "BrickTrackr admin user write/lifecycle verification passed."
    Write-Host "==============================================================================="
    exit 0
}
catch {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Fail $_.Exception.Message
    Write-Host "==============================================================================="
    exit 1
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
