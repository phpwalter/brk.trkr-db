<#
.SYNOPSIS
    Single entry point for the entire BrickTrackr test/verification suite.

.DESCRIPTION
    Strings together every verification step that exists in this repository,
    end to end, against one disposable database:

      1. Dependency manifest verification      (master.schema\tools\verify_dependencies.py)
      2. Disposable database provisioning      (DROP/CREATE via psql)
      3. Schema contract verification          (master.schema\tools\verify_schema_contract.py
                                                 --database --query-plans --lifecycle-viability)
      4. Stored procedure test suite           (master.schema\tools\run_stored_procedure_tests.py)
      5. Service account provisioning          (tools\create_db_service_accounts.ps1)
      6. Fixture identity seeding              (admin.create_user, persists for steps 7-9)
      7. Transaction context contract          (tools\test_transaction_context.ps1)
      8. Admin user read contract              (tools\test_admin_user_reads.ps1)
      9. Admin user write/lifecycle contract   (tools\test_admin_user_writes.ps1)

    Each step prints [RUN], then either [PASS] or [FAIL] with the reason. The
    suite stops at the first [FAIL] -- later steps do not run.

    The disposable database is dropped on a fully-passing run. On failure it
    is left in place (named in the failure output) for post-mortem inspection
    unless -DropOnFailure is supplied.

.PARAMETER Database
    Disposable database name. Must not be a database you care about --
    it is dropped and recreated. Defaults to "bricktrackr_verify_suite".

.NOTES
    File:    tools\run_full_verification_suite.ps1
    Version: 1.0.0

    PGPASSWORD must be set in the environment before running (same
    convention as master.schema\install_bricktrackr_greenfield.ps1). It is
    used only as the local Postgres superuser ("root" by default) password
    for provisioning; it is never written to disk.
#>

[CmdletBinding()]
param(
    [string]$HostName = "localhost",
    [int]$Port = 5432,
    [string]$Database = "bricktrackr_verify_suite",
    [string]$AdminUser = "root",
    [string]$PsqlExe = "psql",
    [string]$PythonExe = "python",
    [switch]$DropOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# This suite invokes several other repo .ps1 scripts (create_db_service_accounts.ps1,
# test_transaction_context.ps1, test_admin_user_reads.ps1, test_admin_user_writes.ps1).
# If the caller's machine has an execution policy stricter than RemoteSigned (e.g.
# AllSigned/Restricted), those unsigned local scripts fail to load. Scope the bypass
# to this process only -- it does not touch the machine/user-wide policy and reverts
# when this process exits.
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}
catch {
    # Some environments (e.g. Group Policy-locked machines) forbid changing the
    # policy even at process scope. Continue and let the actual step fail with
    # a clear reason if that turns out to matter.
}

function Write-Run  { param([string]$Message) Write-Host "[RUN ] $Message" }
function Write-Pass { param([string]$Message) Write-Host "[PASS] $Message" }
function Write-Fail { param([string]$Message) Write-Host "[FAIL] $Message" }

function Invoke-Step {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    Write-Run $Label
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Action
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode. See output above for the reason."
    }

    Write-Pass $Label
    Write-Host ""
}

try {
    if ([string]::IsNullOrWhiteSpace($env:PGPASSWORD)) {
        throw "PGPASSWORD is not set. Supply the PostgreSQL admin ('$AdminUser') password through the process environment before running this suite."
    }
    $adminPassword = $env:PGPASSWORD

    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = Split-Path -Parent $scriptRoot
    $masterSchema = Join-Path $repoRoot "master.schema"
    $dsn = "postgresql://${AdminUser}:${adminPassword}@${HostName}:${Port}/${Database}"

    Write-Host "==============================================================================="
    Write-Host " BrickTrackr Full Verification Suite"
    Write-Host "==============================================================================="
    Write-Host "Repository: $repoRoot"
    Write-Host "Database:   $Database (disposable, will be dropped/recreated)"
    Write-Host "Host:Port:  ${HostName}:${Port}"
    Write-Host ""

    Invoke-Step "1/9 Dependency Manifest Verification" {
        & $PythonExe (Join-Path $masterSchema "tools\verify_dependencies.py")
    }

    Invoke-Step "2/9 Disposable Database Provisioning" {
        $env:PGPASSWORD = $adminPassword
        & $PsqlExe --no-password -h $HostName -p $Port -U $AdminUser -d postgres `
            -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS `"$Database`" WITH (FORCE);"
        if ($LASTEXITCODE -ne 0) { return }
        & $PsqlExe --no-password -h $HostName -p $Port -U $AdminUser -d postgres `
            -v ON_ERROR_STOP=1 -c "CREATE DATABASE `"$Database`" WITH TEMPLATE template0 ENCODING 'UTF8';"
    }

    Invoke-Step "3/9 Schema Contract Verification (bootstrap + static + query-plans + lifecycle-viability)" {
        & $PythonExe (Join-Path $masterSchema "tools\verify_schema_contract.py") `
            --database $dsn --query-plans --lifecycle-viability
    }

    Invoke-Step "4/9 Stored Procedure Test Suite" {
        & $PythonExe (Join-Path $masterSchema "tools\run_stored_procedure_tests.py") --database $dsn
    }

    Invoke-Step "5/9 Service Account Provisioning" {
        & (Join-Path $scriptRoot "create_db_service_accounts.ps1") `
            -DbHost $HostName -DbPort $Port -Database $Database `
            -AdminUser $AdminUser -AdminPassword $adminPassword
    }

    Invoke-Step "6/9 Fixture Identity Seeding" {
        # tools\test_transaction_context.ps1 just needs any existing identity.users
        # row, resolved dynamically through admin.list_users().
        $env:PGPASSWORD = "root"
        & $PsqlExe --no-password -h $HostName -p $Port -U "brktrkr_admin_login" -d $Database `
            -v ON_ERROR_STOP=1 -c @"
CALL admin.create_user(
    p_username     => 'bt_verify_suite_fixture',
    p_display_name => 'BrickTrackr Verify Suite Fixture',
    p_email        => 'bt-verify-suite-fixture@example.invalid',
    p_result       => NULL
);
"@
        if ($LASTEXITCODE -ne 0) { return }

        # tests\admin_user_reads.sql hardcodes a specific fixture
        # (user_id/username/email/status/management_type) rather than resolving
        # one dynamically, so it must be seeded as a direct table INSERT (no
        # admin.create_user path can force a specific user_id). The audit
        # trigger on identity.users requires an established request context,
        # and only brktrkr_owner has direct INSERT rights, so this runs as
        # brktrkr_migrator_login (SYSTEM actor class) with SET ROLE
        # brktrkr_owner, the same pattern tools\apply_migrations.py uses.
        $env:PGPASSWORD = "root"
        & $PsqlExe --no-password -h $HostName -p $Port -U "brktrkr_migrator_login" -d $Database `
            -v ON_ERROR_STOP=1 -c @"
SELECT app.set_request_context(NULL, app.uuid_v7(), 'run_full_verification_suite-seed', 'SYSTEM');
SET ROLE brktrkr_owner;
INSERT INTO identity.users
    (user_id, username, display_name, email, account_management_type, account_status, activated_at)
VALUES
    ('01a05226-ded3-7703-9107-5026a034a4ea', 'test.user2', 'Test User Two',
     'test.user2@example.com', 'MANAGED_CHILD', 'ACTIVE', now())
ON CONFLICT (user_id) DO NOTHING;
RESET ROLE;
"@
        $env:PGPASSWORD = $adminPassword
    }

    Invoke-Step "7/9 Transaction Context Contract" {
        & (Join-Path $scriptRoot "test_transaction_context.ps1") `
            -HostName $HostName -Port $Port -Database $Database
    }

    Invoke-Step "8/9 Admin User Read Contract" {
        & (Join-Path $scriptRoot "test_admin_user_reads.ps1") `
            -HostName $HostName -Port $Port -Database $Database
    }

    Invoke-Step "9/9 Admin User Write/Lifecycle Contract" {
        & (Join-Path $scriptRoot "test_admin_user_writes.ps1") `
            -HostName $HostName -Port $Port -Database $Database
    }

    Write-Host "==============================================================================="
    Write-Pass "BrickTrackr full verification suite passed (9/9 steps)."
    Write-Host "==============================================================================="

    # Child test scripts save/restore PGPASSWORD around their own connections;
    # re-assert it explicitly rather than trust it survived 9 steps intact.
    $env:PGPASSWORD = $adminPassword
    & $PsqlExe --no-password -h $HostName -p $Port -U $AdminUser -d postgres `
        -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS `"$Database`" WITH (FORCE);" | Out-Null
    exit 0
}
catch {
    Write-Host ""
    Write-Host "==============================================================================="
    Write-Fail $_.Exception.Message
    Write-Host "==============================================================================="

    if ($DropOnFailure) {
        Write-Host "Dropping disposable database '$Database' (-DropOnFailure was supplied)."
        $env:PGPASSWORD = $adminPassword
        & $PsqlExe --no-password -h $HostName -p $Port -U $AdminUser -d postgres `
            -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS `"$Database`" WITH (FORCE);" 2>&1 | Out-Null
    }
    else {
        Write-Host "Disposable database '$Database' was left in place for inspection."
    }

    exit 1
}
finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
