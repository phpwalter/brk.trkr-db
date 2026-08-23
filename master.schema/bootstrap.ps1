Clear-Host

# ===============================================================================
# File:           bootstrap.ps1
# Project:        BrickTrackr
# Purpose:        Recreate the BrickTrackr PostgreSQL database from scratch
#                 and install the complete master schema.
# PostgreSQL:     16+
#
# Password handling
# -----------------
# Prompts once at launch.
# The password is not written to this file or printed to the console.
# PGPASSWORD is set only for this PowerShell process and inherited by psql.
# It is cleared in the finally block before the script exits.
# ===============================================================================

$ErrorActionPreference = "Stop"

# ===============================================================================
# CONFIGURATION
# ===============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BootstrapSql = Join-Path $ScriptDir "bootstrap.sql"

$PgHost = if ($env:PGHOST) { $env:PGHOST } else { "localhost" }
$PgPort = if ($env:PGPORT) { $env:PGPORT } else { "5432" }
$PgUser = if ($env:PGUSER) { $env:PGUSER } else { "root" }

$MaintenanceDb = "postgres"
$AppDb = "bricktrackr"


# ===============================================================================
# HELPERS
# ===============================================================================

function Write-Failure {
    param(
        [string]$Message,
        [int]$ExitCode = 1
    )

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " BrickTrackr bootstrap FAILED" -ForegroundColor Red
    Write-Host "==============================================================================="
    Write-Host ""
    Write-Host " $Message"
    Write-Host ""
    Write-Host " Exit code: $ExitCode"
    Write-Host ""

    return $ExitCode
}


function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database,

        [Parameter(Mandatory = $true)]
        [string[]]$AdditionalArguments
    )

    $Arguments = @(
        "-X",
        "-v", "ON_ERROR_STOP=1",
        "-h", $PgHost,
        "-p", $PgPort,
        "-U", $PgUser,
        "-d", $Database
    ) + $AdditionalArguments

    # PowerShell functions emit every unconsumed pipeline object as return data.
    # Send psql output directly to the host so callers receive ONLY the numeric
    # process exit code.
    & $PsqlExe @Arguments | Out-Host

    $PsqlExitCode = $LASTEXITCODE

    return [int]$PsqlExitCode
}


# ===============================================================================
# PRECHECKS
# ===============================================================================

$PsqlCommand = Get-Command "psql.exe" -ErrorAction SilentlyContinue

if (-not $PsqlCommand) {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " ERROR" -ForegroundColor Red
    Write-Host "==============================================================================="
    Write-Host ""
    Write-Host " psql.exe was not found in PATH."
    Write-Host ""
    Write-Host " Add the PostgreSQL bin directory to PATH and try again."
    Write-Host ""
    exit 10
}

$PsqlExe = $PsqlCommand.Source


if (-not (Test-Path -LiteralPath $BootstrapSql)) {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " ERROR" -ForegroundColor Red
    Write-Host "==============================================================================="
    Write-Host ""
    Write-Host " bootstrap.sql was not found:"
    Write-Host ""
    Write-Host "   $BootstrapSql"
    Write-Host ""
    exit 11
}


# ===============================================================================
# BANNER
# ===============================================================================

Write-Host ""
Write-Host "==============================================================================="
Write-Host " BrickTrackr PostgreSQL Fresh Database Bootstrap"
Write-Host "==============================================================================="
Write-Host ""
Write-Host " Host:          $PgHost"
Write-Host " Port:          $PgPort"
Write-Host " User:          $PgUser"
Write-Host " Maintenance:   $MaintenanceDb"
Write-Host " Application:   $AppDb"
Write-Host " Bootstrap SQL: $BootstrapSql"
Write-Host ""
Write-Host " WARNING:" -ForegroundColor Yellow
Write-Host " The database `"$AppDb`" will be deleted if it already exists."
Write-Host " All data currently stored in that database will be permanently removed."
Write-Host ""


# ===============================================================================
# PASSWORD - PROMPT ONCE
# ===============================================================================

$SecurePassword = Read-Host "Enter PostgreSQL password for '$PgUser'" -AsSecureString

if ($SecurePassword.Length -eq 0) {
    Write-Host ""
    Write-Host "[FAIL] Password was not supplied." -ForegroundColor Red
    exit 2
}

$PasswordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
    $SecurePassword
)

try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        $PasswordBstr
    )
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordBstr)
}

# psql/libpq will read this automatically for every connection made below.
$env:PGPASSWORD = $PlainPassword

# Remove the separate local plaintext copy immediately.
$PlainPassword = $null
$SecurePassword = $null


# ===============================================================================
# BOOTSTRAP
# ===============================================================================

$FinalExitCode = 0

try {

    # ---------------------------------------------------------------------------
    # Verify PostgreSQL connection
    # ---------------------------------------------------------------------------

    Write-Host "[PRECHECK] Testing PostgreSQL connection..."

    $ExitCode = Invoke-Psql `
        -Database $MaintenanceDb `
        -AdditionalArguments @(
            "-q",
            "-tAc", "SELECT 1;"
        )

    if ($ExitCode -ne 0) {
        $FinalExitCode = $ExitCode

        Write-Host ""
        Write-Host "==============================================================================="
        Write-Host " BrickTrackr bootstrap FAILED" -ForegroundColor Red
        Write-Host "==============================================================================="
        Write-Host ""
        Write-Host " Unable to connect to PostgreSQL."
        Write-Host ""
        Write-Host " Exit code: $ExitCode"
        Write-Host ""

        throw "BOOTSTRAP_EXIT_$ExitCode"
    }

    Write-Host "[PRECHECK] PostgreSQL connection successful." -ForegroundColor Green
    Write-Host ""


    # ---------------------------------------------------------------------------
    # Drop existing application database
    # ---------------------------------------------------------------------------

    Write-Host "[DATABASE] Dropping existing `"$AppDb`" database if present..."

    $DropSql = "DROP DATABASE IF EXISTS `"$AppDb`" WITH (FORCE);"

    $ExitCode = Invoke-Psql `
        -Database $MaintenanceDb `
        -AdditionalArguments @(
            "-c", $DropSql
        )

    if ($ExitCode -ne 0) {
        $FinalExitCode = $ExitCode

        Write-Host ""
        Write-Host "==============================================================================="
        Write-Host " BrickTrackr bootstrap FAILED" -ForegroundColor Red
        Write-Host "==============================================================================="
        Write-Host ""
        Write-Host " Unable to drop database `"$AppDb`"."
        Write-Host ""
        Write-Host " Exit code: $ExitCode"
        Write-Host ""

        throw "BOOTSTRAP_EXIT_$ExitCode"
    }

    Write-Host "[DATABASE] Existing database removed." -ForegroundColor Green
    Write-Host ""


    # ---------------------------------------------------------------------------
    # Create fresh application database
    # ---------------------------------------------------------------------------

    Write-Host "[DATABASE] Creating fresh `"$AppDb`" database..."

    $CreateSql = @"
CREATE DATABASE "$AppDb"
    WITH
    TEMPLATE = template0
    ENCODING = 'UTF8';
"@

    $ExitCode = Invoke-Psql `
        -Database $MaintenanceDb `
        -AdditionalArguments @(
            "-c", $CreateSql
        )

    if ($ExitCode -ne 0) {
        $FinalExitCode = $ExitCode

        Write-Host ""
        Write-Host "==============================================================================="
        Write-Host " BrickTrackr bootstrap FAILED" -ForegroundColor Red
        Write-Host "==============================================================================="
        Write-Host ""
        Write-Host " Unable to create database `"$AppDb`"."
        Write-Host ""
        Write-Host " Exit code: $ExitCode"
        Write-Host ""

        throw "BOOTSTRAP_EXIT_$ExitCode"
    }

    Write-Host "[DATABASE] Fresh database created." -ForegroundColor Green
    Write-Host ""
    Write-Host "[DATABASE] Verifying database encoding..."

    $EncodingSql = "SHOW server_encoding;"

    $EncodingOutput = & $PsqlExe `
        "-X" `
        "-v" "ON_ERROR_STOP=1" `
        "-h" $PgHost `
        "-p" $PgPort `
        "-U" $PgUser `
        "-d" $AppDb `
        "-tAc" $EncodingSql

    $EncodingExitCode = $LASTEXITCODE
    $DatabaseEncoding = ($EncodingOutput | Out-String).Trim()

    if ($EncodingExitCode -ne 0) {
        $FinalExitCode = $EncodingExitCode
        throw "Unable to verify database encoding."
    }

    if ($DatabaseEncoding -ne "UTF8") {
        $FinalExitCode = 12
        throw "Database encoding is '$DatabaseEncoding'; expected 'UTF8'."
    }

    Write-Host "[DATABASE] Encoding verified: UTF8." -ForegroundColor Green
    Write-Host ""



    # ---------------------------------------------------------------------------
    # Install master schema
    #
    # bootstrap.sql uses relative \ir paths, therefore psql must run with the
    # master-schema directory as the working directory.
    # ---------------------------------------------------------------------------

    Write-Host "==============================================================================="
    Write-Host " Installing BrickTrackr master schema"
    Write-Host "==============================================================================="
    Write-Host ""

    Push-Location -LiteralPath $ScriptDir

    try {
        $ExitCode = Invoke-Psql `
            -Database $AppDb `
            -AdditionalArguments @(
                "-f", "bootstrap.sql"
            )
    }
    finally {
        Pop-Location
    }

    if ($ExitCode -ne 0) {
        $FinalExitCode = $ExitCode

        Write-Host ""
        Write-Host "==============================================================================="
        Write-Host " BrickTrackr schema installation FAILED" -ForegroundColor Red
        Write-Host "==============================================================================="
        Write-Host ""
        Write-Host " Database:       $AppDb"
        Write-Host " psql exit code: $ExitCode"
        Write-Host ""
        Write-Host " The `"$AppDb`" database exists, but schema installation did not"
        Write-Host " complete successfully."
        Write-Host ""

        throw "BOOTSTRAP_EXIT_$ExitCode"
    }


    # ---------------------------------------------------------------------------
    # Success
    # ---------------------------------------------------------------------------

    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " BrickTrackr master schema v10.0 installed successfully." -ForegroundColor Green
    Write-Host "==============================================================================="
    Write-Host ""
    Write-Host " Database: $AppDb"
    Write-Host " Host:     $PgHost"
    Write-Host " Port:     $PgPort"
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host ""

    $FinalExitCode = 0
}
catch {
    if ($FinalExitCode -eq 0) {
        Write-Host ""
        Write-Host "==============================================================================="
        Write-Host " BrickTrackr bootstrap FAILED" -ForegroundColor Red
        Write-Host "==============================================================================="
        Write-Host ""
        Write-Host " $($_.Exception.Message)"
        Write-Host ""

        $FinalExitCode = 1
    }
}
finally {
    # ---------------------------------------------------------------------------
    # Credential cleanup
    # ---------------------------------------------------------------------------

    $env:PGPASSWORD = $null
    Remove-Variable PlainPassword -ErrorAction SilentlyContinue
    Remove-Variable SecurePassword -ErrorAction SilentlyContinue
}


exit $FinalExitCode
