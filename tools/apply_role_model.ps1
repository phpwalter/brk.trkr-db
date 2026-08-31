<#
.SYNOPSIS
    Applies the BrickTrackr 1100_security model to an existing live database.

.DESCRIPTION
    Version 6.0.0

    This runner is for LIVE SECURITY RECONCILIATION only.

    It intentionally does NOT execute:
        master.schema\0000_bootstrap\0000_dependency_preflight.sql

    That preflight tracks greenfield file completion in a single psql session.
    A security-only maintenance run cannot satisfy "Complete ####_domain"
    markers from an earlier installation session.

    Instead this runner:
      1. Verifies required live database objects.
      2. Creates a pre-change pg_dump backup.
      3. Creates a transaction/session-local live-update preflight shim.
      4. Reconciles existing RLS policies before recreating them.
      5. Executes all 1100_security/*.sql files in one psql session.
      6. Verifies canonical capability roles.
      7. Runs create_db_service_accounts.ps1.
      8. Verifies canonical login roles.

.NOTES
    File:    tools\apply_role_model_update_v6.ps1
    Version: 6.0.0
#>

[CmdletBinding()]
param(
    [string]$DbHost = "localhost",
    [int]$DbPort = 5432,
    [string]$Database = "bricktrackr",
    [string]$AdminUser = "root",
    [string]$AdminPassword = "root"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$FileVersion = "6.0.0"

$ExpectedCapabilityRoles = @(
    "brktrkr_owner",
    "brktrkr_api",
    "brktrkr_import",
    "brktrkr_admin",
    "brktrkr_reporting",
    "brktrkr_migrator"
)

$ExpectedLoginRoles = @(
    "brktrkr_owner_login",
    "brktrkr_api_login",
    "brktrkr_import_login",
    "brktrkr_admin_login",
    "brktrkr_reporting_login",
    "brktrkr_migrator_login"
)

function Write-Section {
    param([Parameter(Mandatory=$true)][string]$Title)
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Host " $Title"
    Write-Host "==============================================================================="
}

function Write-Pass {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host "[PASS] $Message"
}

function Write-Fail {
    param([Parameter(Mandatory=$true)][string]$Message)
    Write-Host "[FAIL] $Message"
}

function Find-Executable {
    param([Parameter(Mandatory=$true)][string[]]$Names)

    foreach ($Name in $Names) {
        $Cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if ($Cmd) {
            return $Cmd.Source
        }
    }

    return $null
}

function Invoke-PsqlQuery {
    param(
        [Parameter(Mandatory=$true)][string]$Sql,
        [switch]$TuplesOnly
    )

    $Args = @(
        "-X",
        "-v", "ON_ERROR_STOP=1",
        "-h", $DbHost,
        "-p", "$DbPort",
        "-U", $AdminUser,
        "-d", $Database
    )

    if ($TuplesOnly) {
        $Args += @("-t", "-A")
    }

    $Output = $Sql | & $script:PsqlPath @Args 2>&1
    $Code = $LASTEXITCODE

    if ($Code -ne 0) {
        throw ($Output -join [Environment]::NewLine)
    }

    return $Output
}

function New-LivePreflightShim {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DestinationDirectory
    )

    $ShimFile = Join-Path $DestinationDirectory "__live_update_preflight.sql"

    $ShimSql = @'
\set ON_ERROR_STOP on

/*
===============================================================================
 File:    generated/__live_update_preflight.sql
 Version: 6.0.0
 Purpose: Live-maintenance shim for BrickTrackr 1100_security reconciliation.

 IMPORTANT:
   This shim is valid ONLY after the PowerShell runner has verified the live
   database prerequisites.

   The normal 0000_dependency_preflight.sql tracks completed installer files
   within the SAME psql session. That contract is correct for greenfield
   bootstrap but cannot represent prior domain completion during a targeted
   security maintenance run.
===============================================================================
*/

CREATE OR REPLACE FUNCTION pg_temp.bt_preflight(
    p_file text,
    p_dependencies text[]
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE '[LIVE-PREFLIGHT] %', p_file;
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.bt_mark_completed(
    p_file text
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE '[LIVE-COMPLETE] %', p_file;
END;
$function$;

\echo '[PASS] Live-update preflight shim v6.0.0 installed.'
'@

    Set-Content -LiteralPath $ShimFile -Value $ShimSql -Encoding UTF8
    return $ShimFile
}

function New-PolicyDropFile {
    param(
        [Parameter(Mandatory=$true)]
        [System.IO.FileInfo]$SourceFile,

        [Parameter(Mandatory=$true)]
        [string]$DestinationDirectory
    )

    $SqlText = Get-Content -LiteralPath $SourceFile.FullName -Raw

    $Pattern = '(?ims)\bCREATE\s+POLICY\s+(?<policy>[A-Za-z_][A-Za-z0-9_$]*)\s+ON\s+(?<relation>(?:(?:"[^"]+")|[A-Za-z_][A-Za-z0-9_$]*)(?:\s*\.\s*(?:(?:"[^"]+")|[A-Za-z_][A-Za-z0-9_$]*))?)'

    $Matches = [regex]::Matches($SqlText, $Pattern)

    if ($Matches.Count -eq 0) {
        return $null
    }

    $Statements = New-Object System.Collections.Generic.List[string]
    $Seen = @{}

    foreach ($Match in $Matches) {
        $Policy = $Match.Groups["policy"].Value.Trim()
        $Relation = ($Match.Groups["relation"].Value -replace '\s*\.\s*', '.').Trim()
        $Key = "$Policy|$Relation"

        if (-not $Seen.ContainsKey($Key)) {
            $Seen[$Key] = $true
            $Statements.Add("DROP POLICY IF EXISTS $Policy ON $Relation;")
        }
    }

    if ($Statements.Count -eq 0) {
        return $null
    }

    $DropFile = Join-Path `
        $DestinationDirectory `
        ("__drop_policies_" + $SourceFile.BaseName + ".sql")

    $Lines = New-Object System.Collections.Generic.List[string]
    $Lines.Add("\set ON_ERROR_STOP on")
    $Lines.Add("")
    $Lines.Add("-- Generated by apply_role_model_update_v6.ps1")
    $Lines.Add("-- Generator version: 6.0.0")
    $Lines.Add("-- Drops only RLS POLICY objects recreated by the following source file.")
    $Lines.Add("-- No application table rows are deleted.")
    $Lines.Add("")

    foreach ($Statement in $Statements) {
        $Lines.Add($Statement)
    }

    Set-Content -LiteralPath $DropFile -Value $Lines -Encoding UTF8

    return [PSCustomObject]@{
        Path  = $DropFile
        Count = $Statements.Count
    }
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$MasterSchema = Join-Path $RepoRoot "master.schema"
$SecurityDir = Join-Path $MasterSchema "1100_security"
$ServiceAccountScript = Join-Path $PSScriptRoot "create_db_service_accounts.ps1"

$BackupDir = Join-Path $RepoRoot "backups"
$LogDir = Join-Path $RepoRoot "logs"
$TempRoot = Join-Path $RepoRoot ".tmp_role_model_update"

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupFile = Join-Path $BackupDir "bricktrackr_pre_role_model_v6_$Timestamp.dump"
$LogFile = Join-Path $LogDir "1100_security_update_v6_$Timestamp.log"
$TempDir = Join-Path $TempRoot "v6_$Timestamp"

$HadPgPassword = Test-Path Env:PGPASSWORD
$PreviousPgPassword = $env:PGPASSWORD

try {
    Write-Section "BrickTrackr Live Role/Security Update"
    Write-Host "[INFO] Runner version: $FileVersion"
    Write-Host "[INFO] Repository:     $RepoRoot"
    Write-Host "[INFO] PostgreSQL:     ${DbHost}:${DbPort}/${Database}"
    Write-Host "[INFO] Installer:      $AdminUser"
    Write-Host "[INFO] Mode:           LIVE RECONCILIATION"
    Write-Host "[INFO] Greenfield dependency preflight: DISABLED FOR THIS RUN"

    $script:PsqlPath = Find-Executable @("psql.exe", "psql")
    if (-not $script:PsqlPath) {
        throw "psql was not found in PATH."
    }

    $script:PgDumpPath = Find-Executable @("pg_dump.exe", "pg_dump")
    if (-not $script:PgDumpPath) {
        throw "pg_dump was not found in PATH."
    }

    if (-not (Test-Path -LiteralPath $SecurityDir -PathType Container)) {
        throw "Missing security directory: $SecurityDir"
    }

    if (-not (Test-Path -LiteralPath $ServiceAccountScript -PathType Leaf)) {
        throw "Missing service-account script: $ServiceAccountScript"
    }

    $SecurityFiles = @(
        Get-ChildItem -LiteralPath $SecurityDir -Filter "*.sql" -File |
        Sort-Object Name
    )

    if ($SecurityFiles.Count -eq 0) {
        throw "No SQL files found in $SecurityDir"
    }

    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

    $env:PGPASSWORD = $AdminPassword

    Write-Section "1. Verify PostgreSQL Connection"

    $ConnectionOutput = Invoke-PsqlQuery -Sql @"
SELECT
    current_database() AS database_name,
    session_user AS session_user,
    current_setting('server_version') AS server_version;
"@

    $ConnectionOutput | ForEach-Object { Write-Host $_ }
    Write-Pass "PostgreSQL connection successful."

    Write-Section "2. Verify Existing BrickTrackr Domain Prerequisites"

    $PrerequisiteSql = @"
DO `$verify_live_db`$
BEGIN
    IF pg_catalog.to_regclass('identity.users') IS NULL THEN
        RAISE EXCEPTION 'Required live table identity.users does not exist.';
    END IF;

    IF pg_catalog.to_regclass('collection.entries') IS NULL THEN
        RAISE EXCEPTION 'Required live table collection.entries does not exist.';
    END IF;

    IF pg_catalog.to_regclass('wanted.wishlists') IS NULL THEN
        RAISE EXCEPTION 'Required live table wanted.wishlists does not exist.';
    END IF;

    IF pg_catalog.to_regclass('moc.mocs') IS NULL THEN
        RAISE EXCEPTION 'Required live table moc.mocs does not exist.';
    END IF;

    IF pg_catalog.to_regclass('import.jobs') IS NULL THEN
        RAISE EXCEPTION 'Required live table import.jobs does not exist.';
    END IF;

    IF pg_catalog.to_regclass('audit.events') IS NULL THEN
        RAISE EXCEPTION 'Required live table audit.events does not exist.';
    END IF;

    IF pg_catalog.to_regclass('catalog.items') IS NULL THEN
        RAISE EXCEPTION 'Required live table catalog.items does not exist.';
    END IF;

    IF pg_catalog.to_regclass('marketplace.listings') IS NULL THEN
        RAISE EXCEPTION 'Required live table marketplace.listings does not exist.';
    END IF;

    IF pg_catalog.to_regclass('operations.notifications') IS NULL THEN
        RAISE EXCEPTION 'Required live table operations.notifications does not exist.';
    END IF;

    IF pg_catalog.to_regprocedure('identity.current_user_id()') IS NULL THEN
        RAISE EXCEPTION 'Required function identity.current_user_id() does not exist.';
    END IF;

    IF pg_catalog.to_regprocedure('identity.can_view_owner(uuid)') IS NULL
       AND NOT EXISTS (
           SELECT 1
           FROM pg_catalog.pg_proc p
           JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'identity'
             AND p.proname = 'can_view_owner'
       ) THEN
        RAISE EXCEPTION 'Required function identity.can_view_owner does not exist.';
    END IF;

    IF pg_catalog.to_regprocedure('identity.can_manage_owner(uuid)') IS NULL
       AND NOT EXISTS (
           SELECT 1
           FROM pg_catalog.pg_proc p
           JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'identity'
             AND p.proname = 'can_manage_owner'
       ) THEN
        RAISE EXCEPTION 'Required function identity.can_manage_owner does not exist.';
    END IF;
END;
`$verify_live_db`$;
"@

    $null = Invoke-PsqlQuery -Sql $PrerequisiteSql
    Write-Pass "Live BrickTrackr domain prerequisites verified."

    Write-Section "3. Create Pre-Change Backup"

    Write-Host "[RUN ] $BackupFile"

    & $script:PgDumpPath `
        -h $DbHost `
        -p "$DbPort" `
        -U $AdminUser `
        -d $Database `
        -Fc `
        -f $BackupFile 2>&1 |
        ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        throw "pg_dump failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
        throw "Backup file was not created."
    }

    $BackupInfo = Get-Item -LiteralPath $BackupFile
    if ($BackupInfo.Length -le 0) {
        throw "Backup file is empty."
    }

    Write-Pass "Backup created."
    Write-Host "[INFO] Size: $([Math]::Round($BackupInfo.Length / 1MB, 2)) MB"

    Write-Section "4. Build Live Security Execution Plan"

    $ExecutionFiles = New-Object System.Collections.Generic.List[string]

    $LiveShim = New-LivePreflightShim -DestinationDirectory $TempDir
    $ExecutionFiles.Add($LiveShim)
    Write-Host "[QUEUE] __live_update_preflight.sql v6.0.0"

    $PolicyCount = 0

    foreach ($File in $SecurityFiles) {
        if ($File.FullName -like "*0000_dependency_preflight.sql") {
            throw "Greenfield dependency preflight must never be queued in live-security mode."
        }

        $DropInfo = New-PolicyDropFile `
            -SourceFile $File `
            -DestinationDirectory $TempDir

        if ($null -ne $DropInfo) {
            $ExecutionFiles.Add($DropInfo.Path)
            $PolicyCount += $DropInfo.Count
            Write-Host "[QUEUE] $([System.IO.Path]::GetFileName($DropInfo.Path))"
        }

        $ExecutionFiles.Add($File.FullName)
        Write-Host "[QUEUE] $($File.Name)"
    }

    Write-Host "[INFO] Security files: $($SecurityFiles.Count)"
    Write-Host "[INFO] RLS policies prepared for reconciliation: $PolicyCount"

    if ((Get-Content -LiteralPath $LiveShim -Raw) -notmatch 'LIVE-PREFLIGHT') {
        throw "Generated live preflight shim failed self-verification."
    }

    Write-Pass "Live-maintenance preflight shim verified."

    Write-Section "5. Apply 1100_security"

    $PsqlArgs = @(
        "-X",
        "-h", $DbHost,
        "-p", "$DbPort",
        "-U", $AdminUser,
        "-d", $Database,
        "-v", "ON_ERROR_STOP=1"
    )

    foreach ($FilePath in $ExecutionFiles) {
        $PsqlArgs += @("-f", $FilePath)
    }

    Write-Host "[RUN ] Executing one live-maintenance psql session"
    Write-Host "[INFO] Log: $LogFile"

    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        & $script:PsqlPath @PsqlArgs 2>&1 |
            Tee-Object -FilePath $LogFile |
            ForEach-Object { Write-Host $_ }

        $SecurityExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    if ($SecurityExitCode -ne 0) {
        Write-Host ""
        Write-Fail "1100_security update failed with exit code $SecurityExitCode."
        Write-Host "[INFO] Log:    $LogFile"
        Write-Host "[INFO] Backup: $BackupFile"
        Write-Host ""
        Write-Host "[INFO] Last 120 log lines:"
        Get-Content -LiteralPath $LogFile -Tail 120 |
            ForEach-Object { Write-Host $_ }
        exit $SecurityExitCode
    }

    Write-Pass "All 1100_security files completed successfully."

    Write-Section "6. Verify Canonical Capability Roles"

    foreach ($Role in $ExpectedCapabilityRoles) {
        $Escaped = $Role.Replace("'", "''")
        $Check = Invoke-PsqlQuery `
            -Sql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='$Escaped' AND NOT rolcanlogin AND NOT rolbypassrls AND NOT rolsuper) THEN '1' ELSE '0' END;" `
            -TuplesOnly

        if (($Check | ForEach-Object { $_.ToString().Trim() }) -notcontains "1") {
            throw "Capability-role verification failed: $Role"
        }
    }

    Write-Pass "Six canonical capability roles verified."

    Write-Section "7. Create/Reconcile Service Login Accounts"

    & $ServiceAccountScript
    if ($LASTEXITCODE -ne 0) {
        throw "create_db_service_accounts.ps1 failed with exit code $LASTEXITCODE."
    }

    Write-Pass "Service-account script completed."

    Write-Section "8. Verify Service Login Roles"

    foreach ($Role in $ExpectedLoginRoles) {
        $Escaped = $Role.Replace("'", "''")
        $Check = Invoke-PsqlQuery `
            -Sql "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='$Escaped' AND rolcanlogin AND NOT rolbypassrls AND NOT rolsuper) THEN '1' ELSE '0' END;" `
            -TuplesOnly

        if (($Check | ForEach-Object { $_.ToString().Trim() }) -notcontains "1") {
            throw "Login-role verification failed: $Role"
        }
    }

    Write-Pass "Six service LOGIN roles verified."

    Write-Section "Live Role/Security Update Complete"

    Write-Pass "Live security reconciliation succeeded."
    Write-Pass "Greenfield dependency completion markers were not used."
    Write-Pass "Existing database prerequisites were verified before bypass."
    Write-Pass "RLS policy objects were reconciled."
    Write-Pass "Canonical capability/login roles verified."
    Write-Host "[INFO] Runner version: $FileVersion"
    Write-Host "[INFO] Backup: $BackupFile"
    Write-Host "[INFO] Log:    $LogFile"
}
catch {
    Write-Host ""
    Write-Fail "Unexpected error."
    Write-Host $_.Exception.Message

    if (Test-Path -LiteralPath $LogFile -PathType Leaf) {
        Write-Host "[INFO] Log: $LogFile"
    }

    if (Test-Path -LiteralPath $BackupFile -PathType Leaf) {
        Write-Host "[INFO] Backup: $BackupFile"
    }

    exit 1
}
finally {
    if ($HadPgPassword) {
        $env:PGPASSWORD = $PreviousPgPassword
    }
    else {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}
