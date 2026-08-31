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

function Invoke-Psql {
    param(
        [string[]]$Arguments,
        [string]$Description
    )

    Write-Run $Description

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        & $script:PsqlPath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "$Description failed with psql exit code $exitCode."
    }

    Write-Pass $Description
}

try {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptRoot

    if ([string]::IsNullOrWhiteSpace($SqlFile)) {
        $SqlFile = Join-Path $repoRoot "tests\admin_user_reads.sql"
    }
    elseif (-not [System.IO.Path]::IsPathRooted($SqlFile)) {
        $SqlFile = Join-Path $repoRoot $SqlFile
    }

    if (-not (Test-Path -LiteralPath $SqlFile -PathType Leaf)) {
        throw "SQL test file does not exist: $SqlFile"
    }

    $script:PsqlPath = Find-Psql

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Admin User Read Test"
    Write-Host "==============================================================================="
    Write-Host "Database: $HostName`:$Port/$Database"
    Write-Host "User:     $Username"
    Write-Host "psql:     $script:PsqlPath"
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
WITH expected(signature) AS (
    VALUES
        ('admin.get_user(uuid,jsonb)'),
        ('admin.get_user_by_username(text,jsonb)'),
        ('admin.get_user_by_email(text,jsonb)'),
        ('admin.list_users(identity.account_management_type,identity.account_status,text,boolean,integer,integer,jsonb)')
),
actual AS (
    SELECT p.oid::regprocedure::text AS signature
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'admin'
      AND p.prokind = 'p'
      AND p.proname IN (
          'get_user',
          'get_user_by_username',
          'get_user_by_email',
          'list_users'
      )
)
SELECT e.signature
FROM expected AS e
LEFT JOIN actual AS a
  ON a.signature = e.signature
WHERE a.signature IS NULL
ORDER BY e.signature;
"@

    Write-Run "Validate live admin read procedure signatures"

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $missingSignatures = & $script:PsqlPath @baseArgs "-At" "-c" $signatureSql
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
        Write-Fail "Live procedure contract does not match the test harness."
        foreach ($signature in $missing) {
            Write-Host "       Missing: $signature"
        }
        exit 2
    }

    Write-Pass "Validate live admin read procedure signatures"

    Invoke-Psql `
        -Arguments ($baseArgs + @("-f", $SqlFile)) `
        -Description "Execute admin user read regression tests"

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Pass "BrickTrackr admin user read verification passed."
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
