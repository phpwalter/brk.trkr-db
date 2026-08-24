# .\install_bricktrackr_greenfield.ps1 `
#    -Database bricktrackr `
#    -ForceRecreate


[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param(
    [string]$RepoRoot = "L:\var\www\Brk.Trkr\brk.trkr-db\master.schema",
    [string]$HostName = "localhost",
    [int]$Port = 5432,
    [string]$AdminUser = "root",
    [string]$Database = "bricktrackr",
    [switch]$ForceRecreate,
    [string]$PythonExe = "python",
    [string]$PsqlExe = "psql"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Hardcoded PostgreSQL credential, per request.
$PostgresPassword = "root"
$env:PGPASSWORD = $PostgresPassword
$env:PGUSER = $AdminUser

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

$RepoRoot = (Resolve-Path $RepoRoot).Path

Push-Location $RepoRoot
try {
    Write-Host "==> Verifying dependency contract"
    Invoke-Native -FilePath $PythonExe -Arguments @(
        ".\tools\verify_dependencies.py"
    )

    Write-Host "==> Checking PostgreSQL connection as user '$AdminUser'"

    $escapedDb = $Database.Replace("'", "''")

    $catalogArgs = @(
        "-h", $HostName,
        "-p", "$Port",
        "-U", $AdminUser,
        "-d", "postgres",
        "-Atqc",
        "SELECT 1 FROM pg_database WHERE datname='$escapedDb';"
    )

    $exists = & $PsqlExe @catalogArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query PostgreSQL catalog as user '$AdminUser'."
    }

    if ($exists -eq "1") {
        if (-not $ForceRecreate) {
            throw "Database '$Database' already exists. Re-run with -ForceRecreate only if this database is disposable."
        }

        if ($PSCmdlet.ShouldProcess($Database, "DROP DATABASE WITH FORCE")) {
            Write-Host "==> Dropping existing database '$Database'"

            Invoke-Native -FilePath $PsqlExe -Arguments @(
                "-h", $HostName,
                "-p", "$Port",
                "-U", $AdminUser,
                "-d", "postgres",
                "-v", "ON_ERROR_STOP=1",
                "-c", "DROP DATABASE ""$Database"" WITH (FORCE);"
            )
        }
    }

    if ($PSCmdlet.ShouldProcess($Database, "CREATE DATABASE UTF8 from template0")) {
        Write-Host "==> Creating clean database '$Database'"

        Invoke-Native -FilePath $PsqlExe -Arguments @(
            "-h", $HostName,
            "-p", "$Port",
            "-U", $AdminUser,
            "-d", "postgres",
            "-v", "ON_ERROR_STOP=1",
            "-c", "CREATE DATABASE ""$Database"" WITH TEMPLATE template0 ENCODING 'UTF8';"
        )
    }

    Write-Host "==> Bootstrapping BrickTrackr schema"

    Invoke-Native -FilePath $PsqlExe -Arguments @(
        "-h", $HostName,
        "-p", "$Port",
        "-U", $AdminUser,
        "-d", $Database,
        "-v", "ON_ERROR_STOP=1",
        "-f", ".\bootstrap.sql"
    )

    Write-Host "==> Running smoke checks"

    $sql = @"
DO `$`$
BEGIN
    IF to_regclass('import.source_runs') IS NULL THEN
        RAISE EXCEPTION 'Missing import.source_runs';
    END IF;

    IF to_regprocedure('import.complete_source_run(uuid,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Missing import.complete_source_run(uuid,jsonb)';
    END IF;

    IF to_regprocedure('import.fail_source_run(uuid,text)') IS NULL THEN
        RAISE EXCEPTION 'Missing import.fail_source_run(uuid,text)';
    END IF;
END
`$`$;

SELECT
    current_database() AS database_name,
    current_user AS install_user,
    to_regclass('import.source_runs') AS source_runs,
    to_regprocedure('import.complete_source_run(uuid,jsonb)') AS complete_source_run,
    to_regprocedure('import.fail_source_run(uuid,text)') AS fail_source_run;
"@

    Invoke-Native -FilePath $PsqlExe -Arguments @(
        "-h", $HostName,
        "-p", "$Port",
        "-U", $AdminUser,
        "-d", $Database,
        "-v", "ON_ERROR_STOP=1",
        "-c", $sql
    )

    Write-Host ""
    Write-Host "[PASS] BrickTrackr greenfield installation completed."
    Write-Host "Database: $Database"
    Write-Host "Admin user: $AdminUser"
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:PGUSER -ErrorAction SilentlyContinue
    Pop-Location
}
